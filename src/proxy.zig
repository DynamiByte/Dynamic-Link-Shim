// Runtime stub proxy DLL
const std = @import("std");
const bootstrap = @import("bootstrap.zig");
const cfg = @import("runtime_config");
const paths = @import("path.zig");
const win32 = @import("win32.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const EmbeddedDigest = [Sha256.digest_length]u8;
const LOAD_THREAD_STARTED: u32 = 1;
const EMBEDDED_HASH_READ_SIZE: usize = 64 * 1024;
const EXTRACT_IDLE: u32 = 0;
const EXTRACT_RUNNING: u32 = 1;
const EXTRACT_DONE: u32 = 2;
const EXTRACT_FAILED: u32 = 3;

const EmbeddedFileState = enum {
    current,
    stale_or_missing,
    failed,
};

var g_load_thread_started: u32 = 0;
var g_extract_state: u32 = EXTRACT_IDLE;
var g_forward_module: usize = 0;
var g_proxy_module: usize = 0;
var g_targets: [cfg.export_count]usize = [_]usize{0} ** cfg.export_count;
var g_last_error: win32.DWORD = 0;

pub export fn DllMain(hinstance: win32.HINSTANCE, reason: win32.DWORD, _: ?win32.LPVOID) callconv(.winapi) win32.BOOL {
    if (reason == win32.DLL_PROCESS_ATTACH) {
        const bootstrapped = cfg.bootstrap and bootstrap.alreadyAttempted();
        @atomicStore(usize, &g_proxy_module, @intFromPtr(hinstance), .release);
        _ = win32.DisableThreadLibraryCalls(@ptrCast(hinstance));
        if (shouldPreloadForwardModuleAtAttach(bootstrapped)) _ = forwardModule();
        if (@cmpxchgStrong(u32, &g_load_thread_started, 0, LOAD_THREAD_STARTED, .acq_rel, .acquire) == null) {
            if (shouldStartLoadThread()) {
                if (win32.CreateThread(null, 0, &loadThread, null, 0, null)) |thread| {
                    _ = win32.CloseHandle(thread);
                }
            }
        }
    }

    return win32.TRUE;
}

fn loadThread(_: ?*anyopaque) callconv(.winapi) win32.DWORD {
    bootstrap.exitIfMissing(proxyModule(), &ensureEmbeddedDlls);

    if (cfg.bootstrap and bootstrap.alreadyAttempted()) _ = bootstrap.waitForConfiguredDllsAlreadyLoaded(proxyModule());

    if (!ensureEmbeddedDlls()) return 0;

    _ = forwardModule();

    for (cfg.load, 0..) |load, idx| {
        _ = loadDll("load entry", cfg.load_text[idx], load);
    }

    if (cfg.autoload) autoloadFiles();

    return 0;
}

pub export fn dls_resolve_export(index: u32) callconv(.winapi) usize {
    if (index >= cfg.export_count) return @intFromPtr(&missingExport);

    bootstrap.exitIfMissing(proxyModule(), &ensureEmbeddedDlls);

    const export_index: usize = @intCast(index);
    const cached = @atomicLoad(usize, &g_targets[export_index], .acquire);
    if (cached != 0) return cached;

    const module = forwardModule() orelse return @intFromPtr(&missingExport);
    const proc = resolveProc(module, export_index) orelse return @intFromPtr(&missingExport);
    const address = @intFromPtr(proc);
    @atomicStore(usize, &g_targets[export_index], address, .release);
    return address;
}

fn forwardModule() ?win32.HMODULE {
    if (!ensureEmbeddedDlls()) return null;

    const cached = @atomicLoad(usize, &g_forward_module, .acquire);
    if (cached != 0) return @ptrFromInt(cached);

    var path_buf: [32768]u16 = undefined;
    const forward_path = runtimePath(cfg.forward, &path_buf) orelse {
        showLoadError("forward target", cfg.forward_text, 0);
        return null;
    };

    const module = win32.LoadLibraryW(forward_path) orelse {
        @atomicStore(win32.DWORD, &g_last_error, win32.GetLastError(), .release);
        showLoadError("forward target", cfg.forward_text, @atomicLoad(win32.DWORD, &g_last_error, .acquire));
        return null;
    };

    @atomicStore(usize, &g_forward_module, @intFromPtr(module), .release);
    return module;
}

fn resolveProc(module: win32.HMODULE, export_index: usize) ?*anyopaque {
    const proc = if (cfg.export_names[export_index]) |name|
        win32.GetProcAddress(module, name.ptr)
    else
        win32.GetProcAddress(module, @ptrFromInt(@as(usize, cfg.export_ordinals[export_index])));

    if (proc) |address| return address;

    @atomicStore(win32.DWORD, &g_last_error, win32.GetLastError(), .release);
    return null;
}

fn ensureEmbeddedDlls() bool {
    while (true) {
        switch (@atomicLoad(u32, &g_extract_state, .acquire)) {
            EXTRACT_DONE => return true,
            EXTRACT_FAILED => return false,
            EXTRACT_IDLE => {
                if (@cmpxchgStrong(u32, &g_extract_state, EXTRACT_IDLE, EXTRACT_RUNNING, .acq_rel, .acquire) == null) {
                    const ok = extractEmbeddedDlls();
                    @atomicStore(u32, &g_extract_state, if (ok) EXTRACT_DONE else EXTRACT_FAILED, .release);
                    return ok;
                }
            },
            EXTRACT_RUNNING => win32.Sleep(1),
            else => return false,
        }
    }
}

fn extractEmbeddedDlls() bool {
    for (cfg.embedded) |embedded| {
        if (!extractEmbeddedDll(embedded)) return false;
    }

    return true;
}

fn extractEmbeddedDll(embedded: cfg.EmbeddedDll) bool {
    var path_buf: [32768]u16 = undefined;
    const path = runtimePath(embedded.path, &path_buf) orelse {
        showExtractError(embedded.path_text, 0);
        return false;
    };

    if (win32.GetFileAttributesW(path) != win32.INVALID_FILE_ATTRIBUTES) {
        switch (embeddedFileState(path, embedded.bytes)) {
            .current => return true,
            .stale_or_missing => {},
            .failed => {
                showExtractError(embedded.path_text, @atomicLoad(win32.DWORD, &g_last_error, .acquire));
                return false;
            },
        }
    }

    return writeEmbeddedDll(path, embedded);
}

fn embeddedFileState(path: [*:0]const u16, bytes: []const u8) EmbeddedFileState {
    var existing_digest: EmbeddedDigest = undefined;
    const hash_code = hashFile(path, &existing_digest);
    if (hash_code != 0) {
        if (hash_code == win32.ERROR_FILE_NOT_FOUND or hash_code == win32.ERROR_PATH_NOT_FOUND) {
            return .stale_or_missing;
        }

        @atomicStore(win32.DWORD, &g_last_error, hash_code, .release);
        return .failed;
    }

    var expected_digest: EmbeddedDigest = undefined;
    var hasher = Sha256.init(.{});
    hasher.update(bytes);
    hasher.final(&expected_digest);

    return if (std.mem.eql(u8, &existing_digest, &expected_digest)) .current else .stale_or_missing;
}

fn hashFile(path: [*:0]const u16, digest: *EmbeddedDigest) win32.DWORD {
    const handle = win32.CreateFileW(
        path,
        win32.GENERIC_READ,
        win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
        null,
        win32.OPEN_EXISTING,
        win32.FILE_ATTRIBUTE_NORMAL,
        null,
    );

    if (handle == win32.INVALID_HANDLE_VALUE) return win32.GetLastError();
    defer _ = win32.CloseHandle(handle);

    var hasher = Sha256.init(.{});
    var buf: [EMBEDDED_HASH_READ_SIZE]u8 = undefined;

    while (true) {
        var read: win32.DWORD = 0;
        if (win32.ReadFile(handle, buf[0..].ptr, @intCast(buf.len), &read, null) == win32.FALSE) {
            return win32.GetLastError();
        }

        if (read == 0) break;
        const read_len: usize = @intCast(read);
        hasher.update(buf[0..read_len]);
    }

    hasher.final(digest);
    return 0;
}

fn writeEmbeddedDll(path: [*:0]const u16, embedded: cfg.EmbeddedDll) bool {
    const handle = win32.CreateFileW(
        path,
        win32.GENERIC_WRITE,
        0,
        null,
        win32.CREATE_ALWAYS,
        win32.FILE_ATTRIBUTE_NORMAL,
        null,
    );

    if (handle == win32.INVALID_HANDLE_VALUE) {
        const code = win32.GetLastError();
        @atomicStore(win32.DWORD, &g_last_error, code, .release);
        showExtractError(embedded.path_text, code);
        return false;
    }

    var remaining = embedded.bytes;
    while (remaining.len != 0) {
        const chunk_len = @min(remaining.len, @as(usize, std.math.maxInt(u32)));
        const chunk_size: win32.DWORD = @intCast(chunk_len);
        var written: win32.DWORD = 0;

        if (win32.WriteFile(handle, remaining.ptr, chunk_size, &written, null) == win32.FALSE or written != chunk_size) {
            const code = win32.GetLastError();
            _ = win32.CloseHandle(handle);
            _ = win32.DeleteFileW(path);
            @atomicStore(win32.DWORD, &g_last_error, code, .release);
            showExtractError(embedded.path_text, code);
            return false;
        }

        remaining = remaining[chunk_len..];
    }

    _ = win32.CloseHandle(handle);
    return true;
}

fn showExtractError(path: [:0]const u8, code: win32.DWORD) void {
    var message_buf: [512]u8 = undefined;
    const message = std.fmt.bufPrintZ(
        &message_buf,
        "DLS could not extract embedded DLL:\r\n{s}\r\n\r\nWin32 error: {d}",
        .{ path, code },
    ) catch "DLS could not extract an embedded DLL";

    _ = win32.MessageBoxA(null, message.ptr, "DLS extract failed", win32.MB_OK | win32.MB_ICONERROR);
}

fn loadDll(label: []const u8, path_text: [:0]const u8, path: [*:0]const u16) bool {
    var path_buf: [32768]u16 = undefined;
    const load_path = runtimePath(path, &path_buf) orelse {
        showLoadError(label, path_text, 0);
        return false;
    };

    if (win32.LoadLibraryW(load_path) != null) return true;

    showLoadError(label, path_text, win32.GetLastError());
    return false;
}

fn autoloadFiles() void {
    var dir_buf: [32768]u16 = undefined;
    const dir_len = paths.directory(proxyModule(), &dir_buf) orelse {
        showAutoloadError(0);
        return;
    };

    var pattern_buf: [32768]u16 = undefined;
    @memcpy(pattern_buf[0..dir_len], dir_buf[0..dir_len]);
    _ = appendAsciiUtf16Z(pattern_buf[0..], dir_len, "*.dls.dll") orelse {
        showAutoloadError(0);
        return;
    };

    var find_data: win32.WIN32_FIND_DATAW = undefined;
    const find = win32.FindFirstFileW(@ptrCast(pattern_buf[0..].ptr), &find_data);
    if (find == win32.INVALID_HANDLE_VALUE) {
        const code = win32.GetLastError();
        if (code != win32.ERROR_FILE_NOT_FOUND and code != win32.ERROR_PATH_NOT_FOUND) showAutoloadError(code);
        return;
    }
    defer _ = win32.FindClose(find);

    while (true) {
        if ((find_data.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY) == 0) {
            autoloadFile(dir_buf[0..dir_len], &find_data);
        }

        if (win32.FindNextFileW(find, &find_data) == win32.FALSE) {
            const code = win32.GetLastError();
            if (code != win32.ERROR_NO_MORE_FILES) showAutoloadError(code);
            return;
        }
    }
}

fn autoloadFile(dir: []const u16, find_data: *const win32.WIN32_FIND_DATAW) void {
    var path_buf: [32768]u16 = undefined;
    if (dir.len >= path_buf.len) {
        showAutoloadError(0);
        return;
    }

    @memcpy(path_buf[0..dir.len], dir);
    const name_len = utf16ArrayLen(find_data.cFileName[0..]);
    if (name_len == 0 or dir.len + name_len + 1 > path_buf.len) {
        showAutoloadError(0);
        return;
    }

    @memcpy(path_buf[dir.len..][0..name_len], find_data.cFileName[0..name_len]);
    path_buf[dir.len + name_len] = 0;

    if (win32.LoadLibraryW(@ptrCast(path_buf[0..].ptr)) == null) showAutoloadError(win32.GetLastError());
}

fn runtimePath(path: [*:0]const u16, buffer: *[32768]u16) ?[*:0]const u16 {
    if (!cfg.bootstrap) return path;
    return paths.resolve(proxyModule(), path, buffer);
}

fn proxyModule() ?win32.HMODULE {
    const module_raw = @atomicLoad(usize, &g_proxy_module, .acquire);
    return if (module_raw == 0) null else @ptrFromInt(module_raw);
}

fn utf16ArrayLen(path: []const u16) usize {
    var len: usize = 0;
    while (len < path.len and path[len] != 0) : (len += 1) {}
    return len;
}

fn appendAsciiUtf16Z(buffer: []u16, offset: usize, text: []const u8) ?usize {
    if (offset + text.len + 1 > buffer.len) return null;
    for (text, 0..) |ch, idx| buffer[offset + idx] = ch;
    buffer[offset + text.len] = 0;
    return offset + text.len;
}

fn shouldPreloadForwardModuleAtAttach(bootstrapped: bool) bool {
    return !cfg.bootstrap or bootstrapped;
}

fn shouldStartLoadThread() bool {
    return cfg.bootstrap or cfg.load.len != 0 or cfg.autoload;
}

fn showLoadError(label: []const u8, path: [:0]const u8, code: win32.DWORD) void {
    var message_buf: [512]u8 = undefined;
    const message = std.fmt.bufPrintZ(
        &message_buf,
        "DLS could not load {s} DLL:\r\n{s}\r\n\r\nWin32 error: {d}",
        .{ label, path, code },
    ) catch "DLS could not load a configured DLL";

    _ = win32.MessageBoxA(null, message.ptr, "DLS load failed", win32.MB_OK | win32.MB_ICONERROR);
}

fn showAutoloadError(code: win32.DWORD) void {
    var message_buf: [512]u8 = undefined;
    const message = std.fmt.bufPrintZ(
        &message_buf,
        "DLS could not load a .dls.dll beside the proxy.\r\n\r\nWin32 error: {d}",
        .{code},
    ) catch "DLS could not load a .dls.dll";

    _ = win32.MessageBoxA(null, message.ptr, "DLS load failed", win32.MB_OK | win32.MB_ICONERROR);
}

fn missingExport() callconv(.winapi) noreturn {
    const code = @atomicLoad(win32.DWORD, &g_last_error, .acquire);
    showLoadError("forward target export", cfg.forward_text, code);
    win32.ExitProcess(127);
}

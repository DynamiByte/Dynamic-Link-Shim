// Runtime stub proxy DLL
const std = @import("std");
const cfg = @import("runtime_config");
const win32 = @import("win32.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const EmbeddedDigest = [Sha256.digest_length]u8;
const LOAD_THREAD_STARTED: u32 = 1;
const BOOTSTRAP_STARTED: u32 = 1;
const BOOTSTRAP_RETRY_SLEEP_MS: win32.DWORD = 10;
const BOOTSTRAP_RETRY_COUNT: u32 = 1000;
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
var g_bootstrap_started: u32 = 0;
var g_extract_state: u32 = EXTRACT_IDLE;
var g_forward_module: usize = 0;
var g_proxy_module: usize = 0;
var g_targets: [cfg.export_count]usize = [_]usize{0} ** cfg.export_count;
var g_last_error: win32.DWORD = 0;

pub export fn DllMain(hinstance: win32.HINSTANCE, reason: win32.DWORD, _: ?win32.LPVOID) callconv(.winapi) win32.BOOL {
    if (reason == win32.DLL_PROCESS_ATTACH) {
        const bootstrapped = cfg.bootstrap and bootstrapAlreadyAttempted();
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
    bootstrapExitIfMissing();

    if (cfg.bootstrap and bootstrapAlreadyAttempted()) _ = waitForConfiguredDllsAlreadyLoaded();

    if (!ensureEmbeddedDlls()) return 0;

    _ = forwardModule();

    for (cfg.load, 0..) |load, idx| {
        _ = loadDll("load entry", cfg.load_text[idx], load);
    }

    return 0;
}

pub export fn dls_resolve_export(index: u32) callconv(.winapi) usize {
    if (index >= cfg.export_count) return @intFromPtr(&missingExport);

    bootstrapExitIfMissing();

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
    const forward_path = runtimePath(cfg.forward_to, &path_buf) orelse {
        showLoadError("forward target", cfg.forward_to_text, 0);
        return null;
    };

    const module = win32.LoadLibraryW(forward_path) orelse {
        @atomicStore(win32.DWORD, &g_last_error, win32.GetLastError(), .release);
        showLoadError("forward target", cfg.forward_to_text, @atomicLoad(win32.DWORD, &g_last_error, .acquire));
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

fn runtimePath(path: [*:0]const u16, buffer: *[32768]u16) ?[*:0]const u16 {
    if (!cfg.bootstrap) return path;
    return resolveRuntimePath(path, buffer);
}

fn resolveRuntimePath(path: [*:0]const u16, buffer: *[32768]u16) ?[*:0]const u16 {
    const module_raw = @atomicLoad(usize, &g_proxy_module, .acquire);
    if (module_raw == 0) return path;

    const module: win32.HMODULE = @ptrFromInt(module_raw);
    const module_len = win32.GetModuleFileNameW(module, buffer[0..].ptr, @intCast(buffer.len));
    if (module_len == 0 or module_len >= buffer.len) return null;

    var dir_len: usize = 0;
    var idx: usize = @intCast(module_len);
    while (idx != 0) {
        idx -= 1;
        if (buffer[idx] == '\\' or buffer[idx] == '/') {
            dir_len = idx + 1;
            break;
        }
    }

    const path_len = utf16Len(path);
    var name_start: usize = 0;
    idx = path_len;
    while (idx != 0) {
        idx -= 1;
        if (path[idx] == '\\' or path[idx] == '/') {
            name_start = idx + 1;
            break;
        }
    }

    const name_len = path_len - name_start;
    if (name_len == 0 or dir_len + name_len + 1 > buffer.len) return null;

    @memcpy(buffer[dir_len..][0..name_len], path[name_start..][0..name_len]);
    buffer[dir_len + name_len] = 0;
    return @ptrCast(buffer[0..].ptr);
}

fn utf16Len(path: [*:0]const u16) usize {
    var len: usize = 0;
    while (path[len] != 0) : (len += 1) {}
    return len;
}

fn bootstrapExitIfMissing() void {
    if (!cfg.bootstrap or configuredDllsAlreadyLoaded()) return;

    if (@cmpxchgStrong(u32, &g_bootstrap_started, 0, BOOTSTRAP_STARTED, .acq_rel, .acquire) != null) {
        while (true) win32.Sleep(100);
    }

    if (bootstrapAlreadyAttempted()) {
        return;
    }

    if (!ensureEmbeddedDlls()) {
        showBootstrapError("DLS could not prepare embedded DLLs for bootstrap");
        win32.ExitProcess(127);
    }

    if (startBootstrap()) win32.ExitProcess(0);
    showBootstrapError("DLS could not start the bootstrapped game process");
    win32.ExitProcess(127);
}

fn configuredDllsAlreadyLoaded() bool {
    for (cfg.load) |load| {
        var path_buf: [32768]u16 = undefined;
        const load_path = resolveRuntimePath(load, &path_buf) orelse return false;
        if (!moduleLoaded(load_path)) return false;
    }

    return true;
}

fn moduleLoaded(path: [*:0]const u16) bool {
    if (win32.GetModuleHandleW(path) != null) return true;

    const name = basenameUtf16Z(path);
    if (@intFromPtr(name) != @intFromPtr(path) and win32.GetModuleHandleW(name) != null) return true;

    return false;
}

fn basenameUtf16Z(path: [*:0]const u16) [*:0]const u16 {
    var start: usize = 0;
    var idx: usize = 0;
    while (path[idx] != 0) : (idx += 1) {
        if (path[idx] == '\\' or path[idx] == '/') start = idx + 1;
    }

    return @ptrCast(&path[start]);
}

fn shouldPreloadForwardModuleAtAttach(bootstrapped: bool) bool {
    return !cfg.bootstrap or bootstrapped;
}

fn shouldStartLoadThread() bool {
    return cfg.bootstrap or cfg.load.len != 0;
}

fn bootstrapAlreadyAttempted() bool {
    var name_buf: [128]u16 = undefined;
    const name = asciiToUtf16Z("DLS_BOOTSTRAPPED", name_buf[0..]) orelse return false;
    return win32.GetEnvironmentVariableW(name, null, 0) != 0;
}

fn waitForConfiguredDllsAlreadyLoaded() bool {
    var attempt: u32 = 0;
    while (attempt < BOOTSTRAP_RETRY_COUNT) : (attempt += 1) {
        if (configuredDllsAlreadyLoaded()) return true;
        win32.Sleep(BOOTSTRAP_RETRY_SLEEP_MS);
    }

    return configuredDllsAlreadyLoaded();
}

fn startBootstrap() bool {
    var exe_buf: [32768]u16 = undefined;
    const exe_len = win32.GetModuleFileNameW(null, exe_buf[0..].ptr, @intCast(exe_buf.len));
    if (exe_len == 0 or exe_len >= exe_buf.len) return false;
    exe_buf[@intCast(exe_len)] = 0;

    var cwd_buf: [32768]u16 = undefined;
    const cwd_len = win32.GetCurrentDirectoryW(@intCast(cwd_buf.len), cwd_buf[0..].ptr);
    if (cwd_len == 0 or cwd_len >= cwd_buf.len) return false;
    cwd_buf[@intCast(cwd_len)] = 0;

    var cmd_buf: [32768]u16 = undefined;
    _ = copyUtf16Z(win32.GetCommandLineW(), cmd_buf[0..]) orelse return false;

    const one = [_:0]u16{'1'};
    if (!setEnvUtf16("DLS_BOOTSTRAPPED", &one)) return false;

    var startup: win32.STARTUPINFOW = std.mem.zeroes(win32.STARTUPINFOW);
    startup.cb = @sizeOf(win32.STARTUPINFOW);
    var process_info: win32.PROCESS_INFORMATION = std.mem.zeroes(win32.PROCESS_INFORMATION);

    if (win32.CreateProcessW(
        @ptrCast(exe_buf[0..].ptr),
        @ptrCast(cmd_buf[0..].ptr),
        null,
        null,
        win32.FALSE,
        win32.CREATE_SUSPENDED,
        null,
        @ptrCast(cwd_buf[0..].ptr),
        &startup,
        &process_info,
    ) == win32.FALSE) {
        showBootstrapWin32Error("DLS could not create the bootstrapped game process", win32.GetLastError());
        return false;
    }

    var ok = true;
    for (cfg.load, 0..) |load, idx| {
        var path_buf: [32768]u16 = undefined;
        const load_path = resolveRuntimePath(load, &path_buf) orelse {
            ok = false;
            break;
        };

        if (!injectDllIntoProcess(process_info.hProcess, cfg.load_text[idx], load_path)) {
            ok = false;
            break;
        }
    }

    if (!ok) {
        _ = win32.TerminateProcess(process_info.hProcess, 127);
        _ = win32.CloseHandle(process_info.hThread);
        _ = win32.CloseHandle(process_info.hProcess);
        return false;
    }

    if (win32.ResumeThread(process_info.hThread) == win32.RESUME_FAILED) {
        const code = win32.GetLastError();
        _ = win32.TerminateProcess(process_info.hProcess, 127);
        _ = win32.CloseHandle(process_info.hThread);
        _ = win32.CloseHandle(process_info.hProcess);
        showBootstrapWin32Error("DLS could not resume the bootstrapped game process", code);
        return false;
    }

    _ = win32.CloseHandle(process_info.hThread);
    _ = win32.CloseHandle(process_info.hProcess);
    return true;
}

fn injectDllIntoProcess(process: win32.HANDLE, path_text: [:0]const u8, path: [*:0]const u16) bool {
    const byte_len = (utf16Len(path) + 1) * @sizeOf(u16);
    const remote_path = win32.VirtualAllocEx(
        process,
        null,
        byte_len,
        win32.MEM_COMMIT | win32.MEM_RESERVE,
        win32.PAGE_READWRITE,
    ) orelse {
        showLoadError("bootstrap load entry allocation", path_text, win32.GetLastError());
        return false;
    };
    defer _ = win32.VirtualFreeEx(process, remote_path, 0, win32.MEM_RELEASE);

    var written: win32.SIZE_T = 0;
    if (win32.WriteProcessMemory(process, remote_path, @ptrCast(path), byte_len, &written) == win32.FALSE or written != byte_len) {
        showLoadError("bootstrap load entry write", path_text, win32.GetLastError());
        return false;
    }

    const thread = win32.CreateRemoteThread(
        process,
        null,
        0,
        @ptrCast(&win32.LoadLibraryW),
        remote_path,
        0,
        null,
    ) orelse {
        showLoadError("bootstrap load entry thread", path_text, win32.GetLastError());
        return false;
    };

    const wait_result = win32.WaitForSingleObject(thread, win32.INFINITE);
    var exit_code: win32.DWORD = 0;
    const got_exit_code = win32.GetExitCodeThread(thread, &exit_code);
    _ = win32.CloseHandle(thread);

    if (wait_result != win32.WAIT_OBJECT_0) {
        const code = if (wait_result == win32.WAIT_FAILED) win32.GetLastError() else wait_result;
        showLoadError("bootstrap load entry wait", path_text, code);
        return false;
    }

    if (got_exit_code == win32.FALSE or exit_code == 0) {
        showLoadError("bootstrap load entry", path_text, 0);
        return false;
    }

    return true;
}

fn copyUtf16Z(source: [*:0]const u16, buffer: []u16) ?usize {
    const len = utf16Len(source);
    if (len + 1 > buffer.len) return null;
    @memcpy(buffer[0..len], source[0..len]);
    buffer[len] = 0;
    return len;
}

fn setEnvUtf16(name: []const u8, value: [*:0]const u16) bool {
    var name_buf: [128]u16 = undefined;
    const name_w = asciiToUtf16Z(name, name_buf[0..]) orelse return false;
    return win32.SetEnvironmentVariableW(name_w, value) != win32.FALSE;
}

fn asciiToUtf16Z(text: []const u8, buffer: []u16) ?[*:0]u16 {
    if (text.len + 1 > buffer.len) return null;

    for (text, 0..) |ch, idx| buffer[idx] = ch;
    buffer[text.len] = 0;
    return @ptrCast(buffer[0..].ptr);
}

fn showBootstrapError(text: [:0]const u8) void {
    _ = win32.MessageBoxA(null, text.ptr, "DLS bootstrap failed", win32.MB_OK | win32.MB_ICONERROR);
}

fn showBootstrapWin32Error(text: []const u8, code: win32.DWORD) void {
    var message_buf: [512]u8 = undefined;
    const message = std.fmt.bufPrintZ(
        &message_buf,
        "{s}\r\n\r\nWin32 error: {d}",
        .{ text, code },
    ) catch "DLS bootstrap failed";

    _ = win32.MessageBoxA(null, message.ptr, "DLS bootstrap failed", win32.MB_OK | win32.MB_ICONERROR);
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

fn missingExport() callconv(.winapi) noreturn {
    const code = @atomicLoad(win32.DWORD, &g_last_error, .acquire);
    showLoadError("forward target export", cfg.forward_to_text, code);
    win32.ExitProcess(127);
}

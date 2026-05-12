// Runtime stub proxy DLL
const std = @import("std");
const cfg = @import("runtime_config");
const win32 = @import("win32.zig");

const LOAD_THREAD_STARTED: u32 = 1;
const EXTRACT_IDLE: u32 = 0;
const EXTRACT_RUNNING: u32 = 1;
const EXTRACT_DONE: u32 = 2;
const EXTRACT_FAILED: u32 = 3;

var g_load_thread_started: u32 = 0;
var g_extract_state: u32 = EXTRACT_IDLE;
var g_forward_module: usize = 0;
var g_targets: [cfg.export_count]usize = [_]usize{0} ** cfg.export_count;
var g_last_error: win32.DWORD = 0;

pub export fn DllMain(hinstance: win32.HINSTANCE, reason: win32.DWORD, _: ?win32.LPVOID) callconv(.winapi) win32.BOOL {
    if (reason == win32.DLL_PROCESS_ATTACH) {
        _ = win32.DisableThreadLibraryCalls(@ptrCast(hinstance));
        if (@cmpxchgStrong(u32, &g_load_thread_started, 0, LOAD_THREAD_STARTED, .acq_rel, .acquire) == null) {
            if (win32.CreateThread(null, 0, &loadThread, null, 0, null)) |thread| {
                _ = win32.CloseHandle(thread);
            }
        }
    }

    return win32.TRUE;
}

fn loadThread(_: ?*anyopaque) callconv(.winapi) win32.DWORD {
    if (!ensureEmbeddedDlls()) return 0;

    _ = forwardModule();

    for (cfg.load, 0..) |load, idx| {
        _ = loadDll("load entry", cfg.load_text[idx], load);
    }

    return 0;
}

pub export fn dls_resolve_export(index: u32) callconv(.winapi) usize {
    if (index >= cfg.export_count) return @intFromPtr(&missingExport);

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

    const module = win32.LoadLibraryW(cfg.forward_to) orelse {
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
    if (win32.GetFileAttributesW(embedded.path) != win32.INVALID_FILE_ATTRIBUTES) return true;

    const handle = win32.CreateFileW(
        embedded.path,
        win32.GENERIC_WRITE,
        0,
        null,
        win32.CREATE_NEW,
        win32.FILE_ATTRIBUTE_NORMAL,
        null,
    );

    if (handle == win32.INVALID_HANDLE_VALUE) {
        const code = win32.GetLastError();
        if (code == win32.ERROR_FILE_EXISTS or code == win32.ERROR_ALREADY_EXISTS) return true;
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
            _ = win32.DeleteFileW(embedded.path);
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
    if (win32.LoadLibraryW(path) != null) return true;

    showLoadError(label, path_text, win32.GetLastError());
    return false;
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

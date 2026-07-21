const std = @import("std");
const cfg = @import("runtime_config");
const paths = @import("path.zig");
const win32 = @import("win32.zig");

const STARTED: u32 = 1;
const RETRY_SLEEP_MS: win32.DWORD = 10;
const RETRY_COUNT: u32 = 1000;

var g_started: u32 = 0;

pub fn exitIfMissing(proxy_module: ?win32.HMODULE, prepare_embedded: *const fn () bool) void {
    if (!cfg.bootstrap or configuredDllsAlreadyLoaded(proxy_module)) return;

    if (@cmpxchgStrong(u32, &g_started, 0, STARTED, .acq_rel, .acquire) != null) {
        while (true) win32.Sleep(100);
    }

    if (alreadyAttempted()) return;

    if (!prepare_embedded()) {
        showError("DLS could not prepare embedded DLLs for bootstrap");
        win32.ExitProcess(127);
    }

    if (start(proxy_module)) win32.ExitProcess(0);
    showError("DLS could not start the bootstrapped game process");
    win32.ExitProcess(127);
}

pub fn alreadyAttempted() bool {
    var name_buf: [128]u16 = undefined;
    const name = asciiToUtf16Z("DLS_BOOTSTRAPPED", name_buf[0..]) orelse return false;
    return win32.GetEnvironmentVariableW(name, null, 0) != 0;
}

pub fn waitForConfiguredDllsAlreadyLoaded(proxy_module: ?win32.HMODULE) bool {
    var attempt: u32 = 0;
    while (attempt < RETRY_COUNT) : (attempt += 1) {
        if (configuredDllsAlreadyLoaded(proxy_module)) return true;
        win32.Sleep(RETRY_SLEEP_MS);
    }

    return configuredDllsAlreadyLoaded(proxy_module);
}

fn configuredDllsAlreadyLoaded(proxy_module: ?win32.HMODULE) bool {
    for (cfg.load) |load| {
        var path_buf: [32768]u16 = undefined;
        const load_path = paths.resolve(proxy_module, load, &path_buf) orelse return false;
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
    var name_start: usize = 0;
    var idx: usize = 0;
    while (path[idx] != 0) : (idx += 1) {
        if (path[idx] == '\\' or path[idx] == '/') name_start = idx + 1;
    }

    return @ptrCast(&path[name_start]);
}

fn start(proxy_module: ?win32.HMODULE) bool {
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
        showWin32Error("DLS could not create the bootstrapped game process", win32.GetLastError());
        return false;
    }

    var ok = true;
    for (cfg.load, 0..) |load, idx| {
        var path_buf: [32768]u16 = undefined;
        const load_path = paths.resolve(proxy_module, load, &path_buf) orelse {
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
        showWin32Error("DLS could not resume the bootstrapped game process", code);
        return false;
    }

    _ = win32.CloseHandle(process_info.hThread);
    _ = win32.CloseHandle(process_info.hProcess);
    return true;
}

fn injectDllIntoProcess(process: win32.HANDLE, path_text: [:0]const u8, path: [*:0]const u16) bool {
    const byte_len = (paths.utf16Len(path) + 1) * @sizeOf(u16);
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
    const len = paths.utf16Len(source);
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

fn showError(text: [:0]const u8) void {
    _ = win32.MessageBoxA(null, text.ptr, "DLS bootstrap failed", win32.MB_OK | win32.MB_ICONERROR);
}

fn showWin32Error(text: []const u8, code: win32.DWORD) void {
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

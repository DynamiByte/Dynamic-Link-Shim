const std = @import("std");
const win32 = @import("win32.zig");

const EnvValue = struct {
    ptr: [*:0]u16,
    len: usize,
};

pub fn main() void {
    var pid_buf: [64]u16 = undefined;
    const pid_value = getEnv("DLS_BOOT_PID", &pid_buf) orelse std.process.exit(2);
    const pid = parseU32(pid_value) orelse std.process.exit(2);

    var exe_buf: [32768]u16 = undefined;
    const exe = getEnv("DLS_BOOT_EXE", &exe_buf) orelse std.process.exit(2);

    var cwd_buf: [32768]u16 = undefined;
    const cwd = getEnv("DLS_BOOT_CWD", &cwd_buf) orelse std.process.exit(2);

    var cmd_buf: [32768]u16 = undefined;
    const cmd = getEnv("DLS_BOOT_CMD", &cmd_buf) orelse std.process.exit(2);

    var count_buf: [64]u16 = undefined;
    const count_value = getEnv("DLS_BOOT_PATCH_COUNT", &count_buf) orelse std.process.exit(2);
    const patch_count = parseU32(count_value) orelse std.process.exit(2);

    if (win32.OpenProcess(win32.SYNCHRONIZE | win32.PROCESS_TERMINATE, win32.FALSE, pid)) |old_process| {
        _ = win32.TerminateProcess(old_process, 0);
        _ = win32.WaitForSingleObject(old_process, win32.INFINITE);
        _ = win32.CloseHandle(old_process);
    }

    var startup: win32.STARTUPINFOW = std.mem.zeroes(win32.STARTUPINFOW);
    startup.cb = @sizeOf(win32.STARTUPINFOW);
    var process_info: win32.PROCESS_INFORMATION = std.mem.zeroes(win32.PROCESS_INFORMATION);

    if (win32.CreateProcessW(
        exe.ptr,
        cmd.ptr,
        null,
        null,
        win32.FALSE,
        win32.CREATE_SUSPENDED,
        null,
        cwd.ptr,
        &startup,
        &process_info,
    ) == win32.FALSE) {
        std.process.exit(3);
    }

    var ok = true;
    var index: u32 = 0;
    while (index < patch_count) : (index += 1) {
        var patch_buf: [32768]u16 = undefined;
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "DLS_BOOT_PATCH_{d}", .{index}) catch {
            ok = false;
            break;
        };
        const patch = getEnv(name, &patch_buf) orelse {
            ok = false;
            break;
        };
        if (!injectLoadLibrary(process_info.hProcess, patch)) {
            ok = false;
            break;
        }
    }

    if (!ok) {
        _ = win32.TerminateProcess(process_info.hProcess, 127);
        _ = win32.CloseHandle(process_info.hThread);
        _ = win32.CloseHandle(process_info.hProcess);
        std.process.exit(4);
    }

    _ = win32.ResumeThread(process_info.hThread);
    _ = win32.CloseHandle(process_info.hThread);
    _ = win32.CloseHandle(process_info.hProcess);
}

fn injectLoadLibrary(process: win32.HANDLE, path: EnvValue) bool {
    const byte_len = (path.len + 1) * @sizeOf(u16);
    const remote = win32.VirtualAllocEx(
        process,
        null,
        byte_len,
        win32.MEM_COMMIT | win32.MEM_RESERVE,
        win32.PAGE_READWRITE,
    ) orelse return false;
    defer _ = win32.VirtualFreeEx(process, remote, 0, win32.MEM_RELEASE);

    var written: win32.SIZE_T = 0;
    if (win32.WriteProcessMemory(process, remote, @ptrCast(&path.ptr[0]), byte_len, &written) == win32.FALSE or written != byte_len) {
        return false;
    }

    const kernel32_name = [_:0]u16{ 'k', 'e', 'r', 'n', 'e', 'l', '3', '2', '.', 'd', 'l', 'l' };
    const kernel32 = win32.GetModuleHandleW(&kernel32_name) orelse return false;
    const load_library = win32.GetProcAddress(kernel32, "LoadLibraryW") orelse return false;

    const thread = win32.CreateRemoteThread(process, null, 0, load_library, remote, 0, null) orelse return false;
    const wait_result = win32.WaitForSingleObject(thread, win32.INFINITE);
    var exit_code: win32.DWORD = 0;
    const got_exit_code = win32.GetExitCodeThread(thread, &exit_code);
    _ = win32.CloseHandle(thread);

    return wait_result == win32.WAIT_OBJECT_0 and got_exit_code != win32.FALSE and exit_code != 0;
}

fn getEnv(name: []const u8, buffer: []u16) ?EnvValue {
    var name_buf: [128]u16 = undefined;
    const name_w = asciiToUtf16Z(name, &name_buf) orelse return null;
    const len = win32.GetEnvironmentVariableW(name_w, buffer.ptr, @intCast(buffer.len));
    if (len == 0 or len >= buffer.len) return null;
    buffer[@intCast(len)] = 0;
    return .{ .ptr = @ptrCast(buffer.ptr), .len = @intCast(len) };
}

fn parseU32(value: EnvValue) ?u32 {
    var result: u32 = 0;
    var idx: usize = 0;
    while (idx < value.len) : (idx += 1) {
        const ch = value.ptr[idx];
        if (ch < '0' or ch > '9') return null;
        result = std.math.mul(u32, result, 10) catch return null;
        result = std.math.add(u32, result, @intCast(ch - '0')) catch return null;
    }

    return result;
}

fn asciiToUtf16Z(text: []const u8, buffer: []u16) ?[*:0]u16 {
    if (text.len + 1 > buffer.len) return null;

    for (text, 0..) |ch, idx| buffer[idx] = ch;
    buffer[text.len] = 0;
    return @ptrCast(buffer.ptr);
}

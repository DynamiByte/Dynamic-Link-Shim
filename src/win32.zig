// Win32 surface
const std = @import("std");
const windows = std.os.windows;

pub const BOOL = windows.BOOL;
pub const DWORD = windows.DWORD;
pub const HANDLE = windows.HANDLE;
pub const HINSTANCE = windows.HINSTANCE;
pub const HMODULE = windows.HMODULE;
pub const HWND = windows.HWND;
pub const LPVOID = windows.LPVOID;
pub const SIZE_T = windows.SIZE_T;
pub const UINT = windows.UINT;

pub const DLL_PROCESS_ATTACH: DWORD = 1;
pub const MB_OK: u32 = 0x00000000;
pub const MB_ICONERROR: u32 = 0x00000010;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const CREATE_NEW: DWORD = 1;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x00000080;
pub const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;
pub const ERROR_FILE_EXISTS: DWORD = 80;
pub const ERROR_ALREADY_EXISTS: DWORD = 183;
pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;

fn winBool(value: bool) BOOL {
    return switch (@typeInfo(BOOL)) {
        .int => if (value) 1 else 0,
        .bool => value,
        .@"enum" => if (value) @enumFromInt(1) else @enumFromInt(0),
        else => @compileError("Unsupported Windows BOOL representation"),
    };
}

pub const FALSE: BOOL = winBool(false);
pub const TRUE: BOOL = winBool(true);

pub extern "kernel32" fn LoadLibraryW(lp_lib_file_name: [*:0]const u16) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn GetProcAddress(h_module: HMODULE, lp_proc_name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
pub extern "kernel32" fn ExitProcess(exit_code: UINT) callconv(.winapi) noreturn;
pub extern "kernel32" fn CloseHandle(h_object: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn DisableThreadLibraryCalls(h_lib_module: HMODULE) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateThread(
    lp_thread_attributes: ?*anyopaque,
    dw_stack_size: SIZE_T,
    lp_start_address: *const fn (?*anyopaque) callconv(.winapi) DWORD,
    lp_parameter: ?*anyopaque,
    dw_creation_flags: DWORD,
    lp_thread_id: ?*DWORD,
) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetFileAttributesW(lp_file_name: [*:0]const u16) callconv(.winapi) DWORD;
pub extern "kernel32" fn CreateFileW(
    lp_file_name: [*:0]const u16,
    dw_desired_access: DWORD,
    dw_share_mode: DWORD,
    lp_security_attributes: ?*anyopaque,
    dw_creation_disposition: DWORD,
    dw_flags_and_attributes: DWORD,
    h_template_file: ?HANDLE,
) callconv(.winapi) HANDLE;
pub extern "kernel32" fn WriteFile(
    h_file: HANDLE,
    lp_buffer: [*]const u8,
    n_number_of_bytes_to_write: DWORD,
    lp_number_of_bytes_written: ?*DWORD,
    lp_overlapped: ?*anyopaque,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn DeleteFileW(lp_file_name: [*:0]const u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn Sleep(dw_milliseconds: DWORD) callconv(.winapi) void;

pub extern "user32" fn MessageBoxA(
    hwnd: ?HWND,
    text: [*:0]const u8,
    caption: [*:0]const u8,
    typ: u32,
) callconv(.winapi) c_int;

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
pub const WORD = u16;

pub const DLL_PROCESS_ATTACH: DWORD = 1;
pub const MB_OK: u32 = 0x00000000;
pub const MB_ICONERROR: u32 = 0x00000010;
pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const FILE_SHARE_READ: DWORD = 0x00000001;
pub const FILE_SHARE_WRITE: DWORD = 0x00000002;
pub const FILE_SHARE_DELETE: DWORD = 0x00000004;
pub const CREATE_NEW: DWORD = 1;
pub const CREATE_ALWAYS: DWORD = 2;
pub const OPEN_EXISTING: DWORD = 3;
pub const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x00000010;
pub const FILE_ATTRIBUTE_NORMAL: DWORD = 0x00000080;
pub const CREATE_SUSPENDED: DWORD = 0x00000004;
pub const CREATE_UNICODE_ENVIRONMENT: DWORD = 0x00000400;
pub const MEM_COMMIT: DWORD = 0x00001000;
pub const MEM_RESERVE: DWORD = 0x00002000;
pub const MEM_RELEASE: DWORD = 0x00008000;
pub const PAGE_READWRITE: DWORD = 0x00000004;
pub const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;
pub const ERROR_FILE_NOT_FOUND: DWORD = 2;
pub const ERROR_PATH_NOT_FOUND: DWORD = 3;
pub const ERROR_NO_MORE_FILES: DWORD = 18;
pub const ERROR_FILE_EXISTS: DWORD = 80;
pub const ERROR_ALREADY_EXISTS: DWORD = 183;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_FAILED: DWORD = 0xFFFFFFFF;
pub const INFINITE: DWORD = 0xFFFFFFFF;
pub const RESUME_FAILED: DWORD = 0xFFFFFFFF;
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

pub const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?[*:0]u16,
    lpDesktop: ?[*:0]u16,
    lpTitle: ?[*:0]u16,
    dwX: DWORD,
    dwY: DWORD,
    dwXSize: DWORD,
    dwYSize: DWORD,
    dwXCountChars: DWORD,
    dwYCountChars: DWORD,
    dwFillAttribute: DWORD,
    dwFlags: DWORD,
    wShowWindow: WORD,
    cbReserved2: WORD,
    lpReserved2: ?*anyopaque,
    hStdInput: ?HANDLE,
    hStdOutput: ?HANDLE,
    hStdError: ?HANDLE,
};

pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

pub const FILETIME = extern struct {
    dwLowDateTime: DWORD,
    dwHighDateTime: DWORD,
};

pub const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: DWORD,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: DWORD,
    nFileSizeLow: DWORD,
    dwReserved0: DWORD,
    dwReserved1: DWORD,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};

pub extern "kernel32" fn GetModuleHandleW(lp_module_name: ?[*:0]const u16) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn GetModuleFileNameW(h_module: ?HMODULE, lp_filename: [*]u16, n_size: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
pub extern "kernel32" fn GetCurrentDirectoryW(n_buffer_length: DWORD, lp_buffer: [*]u16) callconv(.winapi) DWORD;
pub extern "kernel32" fn SetEnvironmentVariableW(lp_name: [*:0]const u16, lp_value: ?[*:0]const u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetEnvironmentVariableW(lp_name: [*:0]const u16, lp_buffer: ?[*]u16, n_size: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*]u16;
pub extern "kernel32" fn FreeEnvironmentStringsW(penv: [*]u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn CompareStringOrdinal(
    lp_string1: [*]const u16,
    cch_count1: i32,
    lp_string2: [*]const u16,
    cch_count2: i32,
    b_ignore_case: BOOL,
) callconv(.winapi) i32;
pub extern "kernel32" fn CreateProcessW(
    lp_application_name: ?[*:0]const u16,
    lp_command_line: ?[*:0]u16,
    lp_process_attributes: ?*anyopaque,
    lp_thread_attributes: ?*anyopaque,
    b_inherit_handles: BOOL,
    dw_creation_flags: DWORD,
    lp_environment: ?*anyopaque,
    lp_current_directory: ?[*:0]const u16,
    lp_startup_info: *STARTUPINFOW,
    lp_process_information: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn TerminateProcess(h_process: HANDLE, u_exit_code: UINT) callconv(.winapi) BOOL;
pub extern "kernel32" fn VirtualAllocEx(
    h_process: HANDLE,
    lp_address: ?*anyopaque,
    dw_size: SIZE_T,
    fl_allocation_type: DWORD,
    fl_protect: DWORD,
) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn VirtualFreeEx(
    h_process: HANDLE,
    lp_address: ?*anyopaque,
    dw_size: SIZE_T,
    dw_free_type: DWORD,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteProcessMemory(
    h_process: HANDLE,
    lp_base_address: *anyopaque,
    lp_buffer: *const anyopaque,
    n_size: SIZE_T,
    lp_number_of_bytes_written: ?*SIZE_T,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateRemoteThread(
    h_process: HANDLE,
    lp_thread_attributes: ?*anyopaque,
    dw_stack_size: SIZE_T,
    lp_start_address: *const anyopaque,
    lp_parameter: ?*anyopaque,
    dw_creation_flags: DWORD,
    lp_thread_id: ?*DWORD,
) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn WaitForSingleObject(h_handle: HANDLE, dw_milliseconds: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn GetExitCodeThread(h_thread: HANDLE, lp_exit_code: *DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn ResumeThread(h_thread: HANDLE) callconv(.winapi) DWORD;
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
pub extern "kernel32" fn FindFirstFileW(lp_file_name: [*:0]const u16, lp_find_file_data: *WIN32_FIND_DATAW) callconv(.winapi) HANDLE;
pub extern "kernel32" fn FindNextFileW(h_find_file: HANDLE, lp_find_file_data: *WIN32_FIND_DATAW) callconv(.winapi) BOOL;
pub extern "kernel32" fn FindClose(h_find_file: HANDLE) callconv(.winapi) BOOL;
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
pub extern "kernel32" fn ReadFile(
    h_file: HANDLE,
    lp_buffer: [*]u8,
    n_number_of_bytes_to_read: DWORD,
    lp_number_of_bytes_read: ?*DWORD,
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

const win32 = @import("win32.zig");

pub fn resolve(module: ?win32.HMODULE, path: [*:0]const u16, buffer: *[32768]u16) ?[*:0]const u16 {
    const proxy_module = module orelse return path;
    const dir_len = directory(proxy_module, buffer) orelse return null;

    const path_len = utf16Len(path);
    var name_start: usize = 0;
    var idx = path_len;
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

pub fn directory(module: ?win32.HMODULE, buffer: *[32768]u16) ?usize {
    const proxy_module = module orelse return null;
    const module_len = win32.GetModuleFileNameW(proxy_module, buffer[0..].ptr, @intCast(buffer.len));
    if (module_len == 0 or module_len >= buffer.len) return null;

    var idx: usize = @intCast(module_len);
    while (idx != 0) {
        idx -= 1;
        if (buffer[idx] == '\\' or buffer[idx] == '/') return idx + 1;
    }

    return 0;
}

pub fn utf16Len(path: [*:0]const u16) usize {
    var len: usize = 0;
    while (path[len] != 0) : (len += 1) {}
    return len;
}

const std = @import("std");
const pe = @import("pe.zig");

// DLS schema 1, little-endian:
//
//   00  char[4]  "DLS\0"
//   04  u16      schema
//   06  u16      header size
//   08  u32      file size
//   0C  u16      PE machine
//   0E  u16      flags
//   10  u32      ordinal base
//   14  u32      function count
//   18  u32      export count
//   1C  u32      export table offset
//   20  u32      export record size
//   24  u32      string table offset
//   28  u32      string table size
//   2C  u32      target DLL name offset
//   30  u32      internal DLL name offset, or zero
//   34  u8[12]   reserved
//
// Each export record is { u32 ordinal, u32 name offset, u32 kind }. The string
// table is 16-byte aligned and contains NUL-terminated bytes in reference order.
const magic = "DLS\x00";
const schema: u16 = 1;
const header_size: usize = 0x40;
const export_size: usize = 12;
const no_string: u32 = 0;
const maximum_size: usize = 64 * 1024 * 1024;

pub const Loaded = struct {
    target_name: []const u8,
    table: pe.ExportTable,

    pub fn deinit(self: Loaded, gpa: std.mem.Allocator) void {
        self.table.deinit(gpa);
    }
};

pub fn isPath(path: []const u8) bool {
    return endsWithIgnoreCase(path, ".dls");
}

pub fn encode(gpa: std.mem.Allocator, target_name: []const u8, table: pe.ExportTable) ![]u8 {
    try validateTargetName(target_name);
    try validateExports(table);
    if (table.exports.len > std.math.maxInt(u32)) return error.TooManyExports;

    const export_bytes = std.math.mul(usize, table.exports.len, export_size) catch return error.SurfaceTooLarge;
    const exports_end = std.math.add(usize, header_size, export_bytes) catch return error.SurfaceTooLarge;
    if (exports_end > maximum_size - 15) return error.SurfaceTooLarge;
    const strings_offset = alignForward(exports_end, 16);

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    try appendZeros(gpa, &bytes, strings_offset);

    const target_offset = try appendString(gpa, &bytes, target_name);
    const dll_offset = if (table.dll_name) |dll_name|
        if (std.mem.eql(u8, dll_name, target_name)) target_offset else try appendString(gpa, &bytes, dll_name)
    else
        no_string;

    for (table.exports, 0..) |export_item, idx| {
        const record = header_size + idx * export_size;
        const name_offset = if (export_item.name) |name| try appendString(gpa, &bytes, name) else no_string;
        writeU32(bytes.items, record, export_item.ordinal);
        writeU32(bytes.items, record + 4, name_offset);
        writeU32(bytes.items, record + 8, @intFromEnum(export_item.kind));
    }

    if (bytes.items.len > maximum_size or bytes.items.len > std.math.maxInt(u32)) return error.SurfaceTooLarge;
    const strings_size = bytes.items.len - strings_offset;

    @memcpy(bytes.items[0..magic.len], magic);
    writeU16(bytes.items, 0x04, schema);
    writeU16(bytes.items, 0x06, header_size);
    writeU32(bytes.items, 0x08, @intCast(bytes.items.len));
    writeU16(bytes.items, 0x0C, table.architecture.machine());
    writeU16(bytes.items, 0x0E, 0);
    writeU32(bytes.items, 0x10, table.ordinal_base);
    writeU32(bytes.items, 0x14, table.function_count);
    writeU32(bytes.items, 0x18, @intCast(table.exports.len));
    writeU32(bytes.items, 0x1C, header_size);
    writeU32(bytes.items, 0x20, export_size);
    writeU32(bytes.items, 0x24, @intCast(strings_offset));
    writeU32(bytes.items, 0x28, @intCast(strings_size));
    writeU32(bytes.items, 0x2C, target_offset);
    writeU32(bytes.items, 0x30, dll_offset);

    return bytes.toOwnedSlice(gpa);
}

pub fn loadFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Loaded {
    const file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.size > maximum_size) return error.SurfaceTooLarge;
    const bytes = try gpa.alloc(u8, @intCast(stat.size));
    defer gpa.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.Truncated;
    return parse(gpa, bytes);
}

pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Loaded {
    if (bytes.len > maximum_size) return error.SurfaceTooLarge;
    if (bytes.len < header_size) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return error.BadMagic;
    if (try readU16(bytes, 0x04) != schema) return error.UnsupportedSchema;
    if (try readU16(bytes, 0x06) != header_size) return error.BadHeaderSize;
    if (try readU32(bytes, 0x08) != bytes.len) return error.BadFileSize;
    if (try readU16(bytes, 0x0E) != 0) return error.UnsupportedFlags;
    if (!allZero(bytes[0x34..header_size])) return error.NonzeroReservedData;

    const architecture: pe.Architecture = switch (try readU16(bytes, 0x0C)) {
        0x014C => .x86,
        0x8664 => .x86_64,
        else => return error.UnsupportedMachine,
    };
    const ordinal_base = try readU32(bytes, 0x10);
    const function_count = try readU32(bytes, 0x14);
    const export_count = try readU32(bytes, 0x18);
    const exports_offset = try readU32(bytes, 0x1C);
    const record_size = try readU32(bytes, 0x20);
    const strings_offset = try readU32(bytes, 0x24);
    const strings_size = try readU32(bytes, 0x28);
    const target_offset = try readU32(bytes, 0x2C);
    const dll_offset = try readU32(bytes, 0x30);

    if (function_count == 0) return error.NoExports;
    if (export_count > function_count) return error.TooManyExports;
    if (record_size != export_size) return error.BadExportRecordSize;
    if (exports_offset != header_size) return error.BadExportOffset;

    const exports_len = std.math.mul(usize, export_count, export_size) catch return error.SurfaceTooLarge;
    const exports_end = std.math.add(usize, exports_offset, exports_len) catch return error.SurfaceTooLarge;
    const strings_end = std.math.add(usize, strings_offset, strings_size) catch return error.SurfaceTooLarge;
    if (exports_end > bytes.len or strings_offset != alignForward(exports_end, 16) or strings_end != bytes.len) return error.BadRange;
    if (!allZero(bytes[exports_end..strings_offset])) return error.NonzeroPadding;
    if (target_offset != strings_offset) return error.BadStringOrder;

    const storage = try gpa.dupe(u8, bytes[strings_offset..strings_end]);
    errdefer gpa.free(storage);
    const target_name = try stringAt(storage, strings_offset, target_offset, false);
    try validateTargetName(target_name.?);
    var next_string = try stringEnd(target_offset, target_name.?);
    const dll_name = try stringAt(storage, strings_offset, dll_offset, true);
    if (dll_name) |name| {
        if (dll_offset != target_offset) {
            if (dll_offset != next_string) return error.BadStringOrder;
            next_string = try stringEnd(dll_offset, name);
        }
    }

    const exports = try gpa.alloc(pe.Export, export_count);
    errdefer gpa.free(exports);

    const ordinal_end = std.math.add(u32, ordinal_base, function_count) catch return error.BadOrdinalRange;
    var previous_ordinal: ?u32 = null;
    for (exports, 0..) |*export_item, idx| {
        const record = @as(usize, exports_offset) + idx * export_size;
        const ordinal = try readU32(bytes, record);
        const name_offset = try readU32(bytes, record + 4);
        const kind_value = try readU32(bytes, record + 8);
        const kind: pe.ExportKind = switch (kind_value) {
            0 => .code,
            1 => .data,
            2 => .forwarder,
            3 => .unknown,
            else => return error.BadExportKind,
        };
        if (ordinal < ordinal_base or ordinal >= ordinal_end) return error.BadExportOrdinal;
        if (previous_ordinal) |previous| {
            if (ordinal <= previous) return error.UnsortedExports;
        }
        previous_ordinal = ordinal;

        const name = try stringAt(storage, strings_offset, name_offset, true);
        if (name) |value| {
            if (name_offset != next_string) return error.BadStringOrder;
            next_string = try stringEnd(name_offset, value);
        }

        export_item.* = .{
            .name = name,
            .ordinal = ordinal,
            .rva = 0,
            .kind = kind,
        };
    }
    if (next_string != bytes.len) return error.BadStringOrder;

    return .{
        .target_name = target_name.?,
        .table = .{
            .architecture = architecture,
            .ordinal_base = ordinal_base,
            .function_count = function_count,
            .dll_name = dll_name,
            .exports = exports,
            .name_storage = storage,
        },
    };
}

fn validateExports(table: pe.ExportTable) !void {
    if (table.function_count == 0) return error.NoExports;
    if (table.exports.len > table.function_count) return error.TooManyExports;
    const ordinal_end = std.math.add(u32, table.ordinal_base, table.function_count) catch return error.BadOrdinalRange;

    var previous: ?u32 = null;
    for (table.exports) |export_item| {
        if (export_item.ordinal < table.ordinal_base or export_item.ordinal >= ordinal_end) return error.BadExportOrdinal;
        if (previous) |ordinal| {
            if (export_item.ordinal <= ordinal) return error.UnsortedExports;
        }
        previous = export_item.ordinal;
    }
}

fn validateTargetName(name: []const u8) !void {
    if (name.len == 0) return error.EmptyTargetName;
    if (!endsWithIgnoreCase(name, ".dll")) return error.TargetMustBeDll;
    if (!std.mem.eql(u8, name, std.fs.path.basenameWindows(name))) return error.TargetMustBeBasename;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.StringContainsNul;
}

fn stringAt(storage: []const u8, strings_offset: u32, absolute_offset: u32, optional: bool) !?[]const u8 {
    if (absolute_offset == no_string) return if (optional) null else error.MissingString;
    if (absolute_offset < strings_offset) return error.BadStringOffset;
    const offset = @as(usize, absolute_offset - strings_offset);
    if (offset >= storage.len) return error.BadStringOffset;
    const end = std.mem.indexOfScalarPos(u8, storage, offset, 0) orelse return error.UnterminatedString;
    if (end == offset) return error.EmptyString;
    return storage[offset..end];
}

fn stringEnd(offset: u32, string: []const u8) !u32 {
    const end = std.math.add(usize, offset, string.len + 1) catch return error.SurfaceTooLarge;
    return std.math.cast(u32, end) orelse error.SurfaceTooLarge;
}

fn appendString(gpa: std.mem.Allocator, bytes: *std.ArrayList(u8), text: []const u8) !u32 {
    if (text.len == 0) return error.EmptyString;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.StringContainsNul;
    if (bytes.items.len > std.math.maxInt(u32)) return error.SurfaceTooLarge;
    const terminated_size = std.math.add(usize, text.len, 1) catch return error.SurfaceTooLarge;
    const new_size = std.math.add(usize, bytes.items.len, terminated_size) catch return error.SurfaceTooLarge;
    if (new_size > maximum_size) return error.SurfaceTooLarge;
    const offset: u32 = @intCast(bytes.items.len);
    try bytes.appendSlice(gpa, text);
    try bytes.append(gpa, 0);
    return offset;
}

fn appendZeros(gpa: std.mem.Allocator, bytes: *std.ArrayList(u8), count: usize) !void {
    const offset = bytes.items.len;
    try bytes.resize(gpa, offset + count);
    @memset(bytes.items[offset..], 0);
}

fn alignForward(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    if (text.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

fn readU16(bytes: []const u8, offset: usize) !u16 {
    if (offset + 2 > bytes.len) return error.Truncated;
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readU32(bytes: []const u8, offset: usize) !u32 {
    if (offset + 4 > bytes.len) return error.Truncated;
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

test "schema 1 round trip is canonical" {
    var exports = [_]pe.Export{
        .{ .name = "Alpha", .ordinal = 7, .rva = 0x1000, .kind = .code },
        .{ .name = null, .ordinal = 8, .rva = 0x2000, .kind = .data },
        .{ .name = "Omega", .ordinal = 10, .rva = 0x3000, .kind = .forwarder },
    };
    var unused_storage: [0]u8 = .{};
    const table: pe.ExportTable = .{
        .architecture = .x86_64,
        .ordinal_base = 7,
        .function_count = 4,
        .dll_name = "INTERNAL.dll",
        .exports = &exports,
        .name_storage = &unused_storage,
    };

    const bytes = try encode(std.testing.allocator, "Target.dll", table);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(magic, bytes[0..magic.len]);
    try std.testing.expectEqual(@as(u32, header_size), try readU32(bytes, 0x1C));
    try std.testing.expectEqual(@as(u32, @intCast(alignForward(header_size + exports.len * export_size, 16))), try readU32(bytes, 0x24));

    const loaded = try parse(std.testing.allocator, bytes);
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Target.dll", loaded.target_name);
    try std.testing.expectEqual(pe.Architecture.x86_64, loaded.table.architecture);
    try std.testing.expectEqual(@as(u32, 7), loaded.table.ordinal_base);
    try std.testing.expectEqual(@as(u32, 4), loaded.table.function_count);
    try std.testing.expectEqualStrings("INTERNAL.dll", loaded.table.dll_name.?);
    try std.testing.expectEqual(@as(usize, 3), loaded.table.exports.len);
    try std.testing.expectEqualStrings("Alpha", loaded.table.exports[0].name.?);
    try std.testing.expectEqual(@as(u32, 7), loaded.table.exports[0].ordinal);
    try std.testing.expectEqual(pe.ExportKind.code, loaded.table.exports[0].kind);
    try std.testing.expect(loaded.table.exports[1].name == null);
    try std.testing.expectEqual(pe.ExportKind.data, loaded.table.exports[1].kind);
    try std.testing.expectEqualStrings("Omega", loaded.table.exports[2].name.?);
    try std.testing.expectEqual(pe.ExportKind.forwarder, loaded.table.exports[2].kind);

    bytes[0x34] = 1;
    try std.testing.expectError(error.NonzeroReservedData, parse(std.testing.allocator, bytes));
}

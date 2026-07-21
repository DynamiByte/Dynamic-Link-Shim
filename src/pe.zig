// PE export parser
const std = @import("std");

const IMAGE_DOS_SIGNATURE: u16 = 0x5A4D;
const IMAGE_NT_SIGNATURE: u32 = 0x00004550;
const IMAGE_NT_OPTIONAL_HDR32_MAGIC: u16 = 0x10B;
const IMAGE_NT_OPTIONAL_HDR64_MAGIC: u16 = 0x20B;
const IMAGE_FILE_MACHINE_I386: u16 = 0x014C;
const IMAGE_FILE_MACHINE_AMD64: u16 = 0x8664;
const IMAGE_SCN_MEM_EXECUTE: u32 = 0x20000000;

pub const Architecture = enum {
    x86,
    x86_64,

    pub fn machine(self: Architecture) u16 {
        return switch (self) {
            .x86 => IMAGE_FILE_MACHINE_I386,
            .x86_64 => IMAGE_FILE_MACHINE_AMD64,
        };
    }
};

pub const ExportKind = enum {
    code,
    data,
    forwarder,
    unknown,
};

pub const Export = struct {
    name: ?[]const u8,
    ordinal: u32,
    rva: u32,
    kind: ExportKind,
};

pub const ExportTable = struct {
    architecture: Architecture,
    ordinal_base: u32,
    function_count: u32,
    dll_name: ?[]const u8,
    exports: []Export,
    name_storage: []u8,

    pub fn deinit(self: ExportTable, gpa: std.mem.Allocator) void {
        gpa.free(self.exports);
        gpa.free(self.name_storage);
    }
};

const Section = struct {
    virtual_address: u32,
    virtual_size: u32,
    raw_data_size: u32,
    raw_data_ptr: u32,
    characteristics: u32,
};

const ExportDirectory = struct {
    name_rva: u32,
    ordinal_base: u32,
    function_count: u32,
    name_count: u32,
    functions_rva: u32,
    names_rva: u32,
    ordinals_rva: u32,
};

const NameRef = struct {
    offset: usize,
    len: usize,
};

const PendingExport = struct {
    name: ?NameRef,
    ordinal: u32,
    rva: u32,
    kind: ExportKind,
};

const Source = union(enum) {
    bytes: []const u8,
    file: struct {
        handle: std.Io.File,
        io: std.Io,
        size: u64,
    },

    fn readAtMost(self: Source, buffer: []u8, offset: u64) !usize {
        return switch (self) {
            .bytes => |bytes| blk: {
                if (offset >= bytes.len) break :blk 0;
                const start: usize = @intCast(offset);
                const len = @min(buffer.len, bytes.len - start);
                @memcpy(buffer[0..len], bytes[start..][0..len]);
                break :blk len;
            },
            .file => |file| blk: {
                if (offset >= file.size) break :blk 0;
                const len: usize = @intCast(@min(@as(u64, buffer.len), file.size - offset));
                break :blk try file.handle.readPositionalAll(file.io, buffer[0..len], offset);
            },
        };
    }

    fn readExact(self: Source, buffer: []u8, offset: u64) !void {
        if (try self.readAtMost(buffer, offset) != buffer.len) return error.Truncated;
    }
};

pub fn parseExports(gpa: std.mem.Allocator, bytes: []const u8) !ExportTable {
    return parseSource(gpa, .{ .bytes = bytes });
}

pub fn parseExportsFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !ExportTable {
    const file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    return parseSource(gpa, .{ .file = .{ .handle = file, .io = io, .size = stat.size } });
}

fn parseSource(gpa: std.mem.Allocator, source: Source) !ExportTable {
    if (try readU16(source, 0) != IMAGE_DOS_SIGNATURE) return error.BadDosSignature;

    const pe = @as(usize, try readU32(source, 0x3C));
    if (try readU32(source, pe) != IMAGE_NT_SIGNATURE) return error.BadPeSignature;

    const coff = pe + 4;
    const machine = try readU16(source, coff);
    const section_count = try readU16(source, coff + 2);
    const optional_size = try readU16(source, coff + 16);
    const optional = coff + 20;
    const magic = try readU16(source, optional);

    const architecture: Architecture = switch (machine) {
        IMAGE_FILE_MACHINE_I386 => if (magic == IMAGE_NT_OPTIONAL_HDR32_MAGIC) .x86 else return error.MismatchedPeArchitecture,
        IMAGE_FILE_MACHINE_AMD64 => if (magic == IMAGE_NT_OPTIONAL_HDR64_MAGIC) .x86_64 else return error.MismatchedPeArchitecture,
        else => return error.UnsupportedMachine,
    };
    const data_dir_offset: usize = switch (architecture) {
        .x86 => 96,
        .x86_64 => 112,
    };

    const export_dir_rva = try readU32(source, optional + data_dir_offset);
    const export_dir_size = try readU32(source, optional + data_dir_offset + 4);
    if (export_dir_rva == 0 or export_dir_size == 0) return error.NoExports;

    const sections = try readSections(gpa, source, optional + optional_size, section_count);
    defer gpa.free(sections);

    const export_dir_offset = rvaToOffset(sections, export_dir_rva) orelse return error.BadExportDirectory;
    const dir = try readExportDirectory(source, export_dir_offset);
    if (dir.function_count == 0) return error.NoExports;

    const function_count = @as(usize, dir.function_count);
    const name_count = @as(usize, dir.name_count);
    const functions_offset = rvaToOffset(sections, dir.functions_rva) orelse return error.BadExportAddressTable;
    const names_offset = if (name_count == 0) 0 else rvaToOffset(sections, dir.names_rva) orelse return error.BadExportNameTable;
    const ordinals_offset = if (name_count == 0) 0 else rvaToOffset(sections, dir.ordinals_rva) orelse return error.BadExportOrdinalTable;

    const function_bytes = try readTable(gpa, source, functions_offset, function_count, 4);
    defer gpa.free(function_bytes);
    const name_bytes = if (name_count == 0) &.{} else try readTable(gpa, source, names_offset, name_count, 4);
    defer if (name_count != 0) gpa.free(name_bytes);
    const ordinal_bytes = if (name_count == 0) &.{} else try readTable(gpa, source, ordinals_offset, name_count, 2);
    defer if (name_count != 0) gpa.free(ordinal_bytes);

    const has_name = try gpa.alloc(bool, function_count);
    defer gpa.free(has_name);
    @memset(has_name, false);

    var names: std.ArrayList(u8) = .empty;
    errdefer names.deinit(gpa);
    var pending: std.ArrayList(PendingExport) = .empty;
    defer pending.deinit(gpa);

    for (0..name_count) |idx| {
        const ordinal_index = try readBufferU16(ordinal_bytes, idx * 2);
        if (ordinal_index >= function_count) return error.BadExportOrdinal;

        const function_rva = try readBufferU32(function_bytes, @as(usize, ordinal_index) * 4);
        if (function_rva == 0) continue;

        const name_rva = try readBufferU32(name_bytes, idx * 4);
        const name_offset = rvaToOffset(sections, name_rva) orelse return error.BadExportName;
        const name = try readCString(gpa, source, &names, name_offset);

        has_name[ordinal_index] = true;
        try pending.append(gpa, .{
            .name = name,
            .ordinal = dir.ordinal_base + ordinal_index,
            .rva = function_rva,
            .kind = classifyRva(sections, export_dir_rva, export_dir_size, function_rva),
        });
    }

    for (0..function_count) |idx| {
        if (has_name[idx]) continue;

        const function_rva = try readBufferU32(function_bytes, idx * 4);
        if (function_rva == 0) continue;

        try pending.append(gpa, .{
            .name = null,
            .ordinal = dir.ordinal_base + @as(u32, @intCast(idx)),
            .rva = function_rva,
            .kind = classifyRva(sections, export_dir_rva, export_dir_size, function_rva),
        });
    }

    const dll_name_ref = if (dir.name_rva == 0) null else blk: {
        const name_offset = rvaToOffset(sections, dir.name_rva) orelse return error.BadExportName;
        break :blk try readCString(gpa, source, &names, name_offset);
    };

    const name_storage = try names.toOwnedSlice(gpa);
    errdefer gpa.free(name_storage);
    const exports = try gpa.alloc(Export, pending.items.len);
    errdefer gpa.free(exports);

    for (pending.items, exports) |item, *export_item| {
        export_item.* = .{
            .name = if (item.name) |name| name_storage[name.offset..][0..name.len] else null,
            .ordinal = item.ordinal,
            .rva = item.rva,
            .kind = item.kind,
        };
    }
    std.sort.pdq(Export, exports, {}, exportLessThan);

    return .{
        .architecture = architecture,
        .ordinal_base = dir.ordinal_base,
        .function_count = dir.function_count,
        .dll_name = if (dll_name_ref) |name| name_storage[name.offset..][0..name.len] else null,
        .exports = exports,
        .name_storage = name_storage,
    };
}

fn readSections(gpa: std.mem.Allocator, source: Source, offset: usize, count: u16) ![]Section {
    const sections = try gpa.alloc(Section, count);
    errdefer gpa.free(sections);

    for (sections, 0..) |*section, idx| {
        var bytes: [40]u8 = undefined;
        try source.readExact(&bytes, offset + idx * bytes.len);
        section.* = .{
            .virtual_size = try readBufferU32(&bytes, 8),
            .virtual_address = try readBufferU32(&bytes, 12),
            .raw_data_size = try readBufferU32(&bytes, 16),
            .raw_data_ptr = try readBufferU32(&bytes, 20),
            .characteristics = try readBufferU32(&bytes, 36),
        };
    }

    return sections;
}

fn readExportDirectory(source: Source, offset: usize) !ExportDirectory {
    var bytes: [40]u8 = undefined;
    try source.readExact(&bytes, offset);
    return .{
        .name_rva = try readBufferU32(&bytes, 12),
        .ordinal_base = try readBufferU32(&bytes, 16),
        .function_count = try readBufferU32(&bytes, 20),
        .name_count = try readBufferU32(&bytes, 24),
        .functions_rva = try readBufferU32(&bytes, 28),
        .names_rva = try readBufferU32(&bytes, 32),
        .ordinals_rva = try readBufferU32(&bytes, 36),
    };
}

fn readTable(gpa: std.mem.Allocator, source: Source, offset: usize, count: usize, width: usize) ![]u8 {
    const len = std.math.mul(usize, count, width) catch return error.TableTooLarge;
    const bytes = try gpa.alloc(u8, len);
    errdefer gpa.free(bytes);
    try source.readExact(bytes, offset);
    return bytes;
}

fn readCString(gpa: std.mem.Allocator, source: Source, storage: *std.ArrayList(u8), offset: usize) !NameRef {
    const start = storage.items.len;
    var source_offset = @as(u64, offset);
    var buffer: [256]u8 = undefined;

    while (true) {
        const read = try source.readAtMost(&buffer, source_offset);
        if (read == 0) return error.Truncated;
        const bytes = buffer[0..read];
        if (std.mem.indexOfScalar(u8, bytes, 0)) |end| {
            try storage.appendSlice(gpa, bytes[0..end]);
            return .{ .offset = start, .len = storage.items.len - start };
        }
        try storage.appendSlice(gpa, bytes);
        source_offset += read;
    }
}

fn classifyRva(sections: []const Section, export_dir_rva: u32, export_dir_size: u32, rva: u32) ExportKind {
    const export_start = @as(u64, export_dir_rva);
    const export_end = export_start + export_dir_size;
    const value = @as(u64, rva);
    if (value >= export_start and value < export_end) return .forwarder;

    const section = sectionForRva(sections, rva) orelse return .unknown;
    if ((section.characteristics & IMAGE_SCN_MEM_EXECUTE) != 0) return .code;
    return .data;
}

fn sectionForRva(sections: []const Section, rva: u32) ?Section {
    for (sections) |section| {
        const size = @max(section.virtual_size, section.raw_data_size);
        if (size == 0) continue;

        const start = @as(u64, section.virtual_address);
        const end = start + size;
        const value = @as(u64, rva);
        if (value >= start and value < end) return section;
    }

    return null;
}

fn rvaToOffset(sections: []const Section, rva: u32) ?usize {
    for (sections) |section| {
        const size = @max(section.virtual_size, section.raw_data_size);
        if (size == 0) continue;

        const start = @as(u64, section.virtual_address);
        const end = start + size;
        const value = @as(u64, rva);
        if (value >= start and value < end) {
            return @as(usize, section.raw_data_ptr) + (rva - section.virtual_address);
        }
    }

    return null;
}

fn readU16(source: Source, offset: usize) !u16 {
    var bytes: [2]u8 = undefined;
    try source.readExact(&bytes, offset);
    return std.mem.readInt(u16, &bytes, .little);
}

fn readU32(source: Source, offset: usize) !u32 {
    var bytes: [4]u8 = undefined;
    try source.readExact(&bytes, offset);
    return std.mem.readInt(u32, &bytes, .little);
}

fn readBufferU16(bytes: []const u8, offset: usize) !u16 {
    if (offset + 2 > bytes.len) return error.Truncated;
    return std.mem.readInt(u16, bytes[offset..][0..2], .little);
}

fn readBufferU32(bytes: []const u8, offset: usize) !u32 {
    if (offset + 4 > bytes.len) return error.Truncated;
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn exportLessThan(_: void, left: Export, right: Export) bool {
    if (left.ordinal != right.ordinal) return left.ordinal < right.ordinal;
    return std.mem.lessThan(u8, left.name orelse "", right.name orelse "");
}

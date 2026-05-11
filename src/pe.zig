// PE export parser
const std = @import("std");

const IMAGE_DOS_SIGNATURE: u16 = 0x5A4D;
const IMAGE_NT_SIGNATURE: u32 = 0x00004550;
const IMAGE_NT_OPTIONAL_HDR32_MAGIC: u16 = 0x10B;
const IMAGE_NT_OPTIONAL_HDR64_MAGIC: u16 = 0x20B;
const IMAGE_SCN_MEM_EXECUTE: u32 = 0x20000000;

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
    bytes: []const u8 = &.{},
    machine: u16,
    ordinal_base: u32,
    function_count: u32,
    dll_name: ?[]const u8,
    exports: []Export,

    pub fn deinit(self: ExportTable, gpa: std.mem.Allocator) void {
        gpa.free(self.exports);
        gpa.free(self.bytes);
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

pub fn parseExports(gpa: std.mem.Allocator, bytes: []const u8) !ExportTable {
    if (try readU16(bytes, 0) != IMAGE_DOS_SIGNATURE) return error.BadDosSignature;

    const pe_offset = try readU32(bytes, 0x3C);
    const pe = @as(usize, pe_offset);
    if (try readU32(bytes, pe) != IMAGE_NT_SIGNATURE) return error.BadPeSignature;

    const coff = pe + 4;
    const machine = try readU16(bytes, coff);
    const section_count = try readU16(bytes, coff + 2);
    const optional_size = try readU16(bytes, coff + 16);
    const optional = coff + 20;
    const magic = try readU16(bytes, optional);

    const data_dir_offset: usize = switch (magic) {
        IMAGE_NT_OPTIONAL_HDR32_MAGIC => 96,
        IMAGE_NT_OPTIONAL_HDR64_MAGIC => 112,
        else => return error.UnsupportedOptionalHeader,
    };

    const export_dir_rva = try readU32(bytes, optional + data_dir_offset);
    const export_dir_size = try readU32(bytes, optional + data_dir_offset + 4);
    if (export_dir_rva == 0 or export_dir_size == 0) return error.NoExports;

    const sections_offset = optional + optional_size;
    const sections = try readSections(gpa, bytes, sections_offset, section_count);
    defer gpa.free(sections);

    const export_dir_offset = rvaToOffset(sections, export_dir_rva) orelse return error.BadExportDirectory;
    const dir = try readExportDirectory(bytes, export_dir_offset);
    if (dir.function_count == 0) return error.NoExports;

    const function_count = @as(usize, dir.function_count);
    const name_count = @as(usize, dir.name_count);
    const functions_offset = rvaToOffset(sections, dir.functions_rva) orelse return error.BadExportAddressTable;
    const names_offset = rvaToOffset(sections, dir.names_rva) orelse return error.BadExportNameTable;
    const ordinals_offset = rvaToOffset(sections, dir.ordinals_rva) orelse return error.BadExportOrdinalTable;

    var has_name = try gpa.alloc(bool, function_count);
    defer gpa.free(has_name);
    @memset(has_name, false);

    var exports: std.ArrayList(Export) = .empty;
    errdefer exports.deinit(gpa);

    for (0..name_count) |idx| {
        const name_rva = try readU32(bytes, names_offset + idx * 4);
        const name_offset = rvaToOffset(sections, name_rva) orelse return error.BadExportName;
        const name = try readCString(bytes, name_offset);
        const ordinal_index = try readU16(bytes, ordinals_offset + idx * 2);
        if (ordinal_index >= function_count) return error.BadExportOrdinal;

        const function_rva = try readU32(bytes, functions_offset + @as(usize, ordinal_index) * 4);
        if (function_rva == 0) continue;

        has_name[ordinal_index] = true;
        try exports.append(gpa, .{
            .name = name,
            .ordinal = dir.ordinal_base + ordinal_index,
            .rva = function_rva,
            .kind = classifyRva(sections, export_dir_rva, export_dir_size, function_rva),
        });
    }

    for (0..function_count) |idx| {
        if (has_name[idx]) continue;

        const function_rva = try readU32(bytes, functions_offset + idx * 4);
        if (function_rva == 0) continue;

        try exports.append(gpa, .{
            .name = null,
            .ordinal = dir.ordinal_base + @as(u32, @intCast(idx)),
            .rva = function_rva,
            .kind = classifyRva(sections, export_dir_rva, export_dir_size, function_rva),
        });
    }

    std.sort.pdq(Export, exports.items, {}, exportLessThan);

    const dll_name = if (dir.name_rva == 0) null else blk: {
        const name_offset = rvaToOffset(sections, dir.name_rva) orelse return error.BadExportName;
        break :blk try readCString(bytes, name_offset);
    };

    return .{
        .machine = machine,
        .ordinal_base = dir.ordinal_base,
        .function_count = dir.function_count,
        .dll_name = dll_name,
        .exports = try exports.toOwnedSlice(gpa),
    };
}

fn readSections(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    offset: usize,
    count: u16,
) ![]Section {
    const sections = try gpa.alloc(Section, count);
    errdefer gpa.free(sections);

    for (sections, 0..) |*section, idx| {
        const base = offset + idx * 40;
        section.* = .{
            .virtual_size = try readU32(bytes, base + 8),
            .virtual_address = try readU32(bytes, base + 12),
            .raw_data_size = try readU32(bytes, base + 16),
            .raw_data_ptr = try readU32(bytes, base + 20),
            .characteristics = try readU32(bytes, base + 36),
        };
    }

    return sections;
}

fn readExportDirectory(bytes: []const u8, offset: usize) !ExportDirectory {
    return .{
        .name_rva = try readU32(bytes, offset + 12),
        .ordinal_base = try readU32(bytes, offset + 16),
        .function_count = try readU32(bytes, offset + 20),
        .name_count = try readU32(bytes, offset + 24),
        .functions_rva = try readU32(bytes, offset + 28),
        .names_rva = try readU32(bytes, offset + 32),
        .ordinals_rva = try readU32(bytes, offset + 36),
    };
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

fn readCString(bytes: []const u8, offset: usize) ![]const u8 {
    if (offset >= bytes.len) return error.Truncated;
    const end = std.mem.indexOfScalarPos(u8, bytes, offset, 0) orelse return error.Truncated;
    return bytes[offset..end];
}

fn readU16(bytes: []const u8, offset: usize) !u16 {
    if (offset + 2 > bytes.len) return error.Truncated;
    return @as(u16, bytes[offset]) |
        (@as(u16, bytes[offset + 1]) << 8);
}

fn readU32(bytes: []const u8, offset: usize) !u32 {
    if (offset + 4 > bytes.len) return error.Truncated;
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn exportLessThan(_: void, left: Export, right: Export) bool {
    if (left.ordinal != right.ordinal) return left.ordinal < right.ordinal;
    return std.mem.lessThan(u8, left.name orelse "", right.name orelse "");
}

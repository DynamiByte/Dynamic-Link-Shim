// DLS generator and backend dispatcher
const std = @import("std");
const config = @import("config.zig");
const pe = @import("pe.zig");

const Mode = enum {
    generate,
    inspect,
    copy,
    prepare_input_dir,
    clean_generated,
};

const Args = struct {
    mode: Mode = .generate,
    config_path: []const u8 = "config.zon",
    overrides: config.Overrides = .{},
    emit_dll: ?[]const u8 = null,
    emit_def: ?[]const u8 = null,
    emit_runtime: ?[]const u8 = null,
    emit_asm: ?[]const u8 = null,
    copy_source: ?[]const u8 = null,
    copy_output_name: ?[]const u8 = null,
    copy_dir: ?[]const u8 = null,
    clean_dir: []const u8 = "generated",
    resolved_forward_to: ?[]const u8 = null,
};

const IDATA_RVA: u32 = 0x1000;
const FILE_ALIGN: usize = 0x200;
const VIRTUAL_ALIGN: usize = 0x1000;
const IMAGE_DOS_SIGNATURE: u16 = 0x5A4D;
const IMAGE_NT_SIGNATURE: u32 = 0x00004550;
const IMAGE_NT_OPTIONAL_HDR64_MAGIC: u16 = 0x20B;
const IMAGE_FILE_EXECUTABLE_IMAGE: u16 = 0x0002;
const IMAGE_FILE_LARGE_ADDRESS_AWARE: u16 = 0x0020;
const IMAGE_FILE_DLL: u16 = 0x2000;
const IMAGE_SUBSYSTEM_WINDOWS_GUI: u16 = 2;
const IMAGE_DLLCHARACTERISTICS_HIGH_ENTROPY_VA: u16 = 0x0020;
const IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE: u16 = 0x0040;
const IMAGE_DLLCHARACTERISTICS_NX_COMPAT: u16 = 0x0100;
const IMAGE_SCN_MEM_READ: u32 = 0x40000000;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try parseArgs(init.minimal.args.toSlice(init.arena.allocator()) catch |err|
        std.process.fatal("unable to read arguments: {t}", .{err}));

    switch (args.mode) {
        .generate => try generate(gpa, io, args),
        .inspect => try inspect(gpa, io, args),
        .copy => try copyBuiltDll(gpa, io, args),
        .prepare_input_dir => try prepareInputDir(gpa, io, args),
        .clean_generated => try cleanGenerated(io, args.clean_dir),
    }
}

fn parseArgs(argv: []const []const u8) !Args {
    var args = Args{};

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (std.mem.eql(u8, arg, "--config")) {
            args.config_path = takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--input")) {
            args.overrides.input = takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--forward-to")) {
            args.overrides.forward_to = takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--output")) {
            args.overrides.output = takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--load")) {
            args.overrides.load = takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--import") or std.mem.eql(u8, arg, "--load-import")) {
            args.overrides.load_import = takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--backend") or std.mem.eql(u8, arg, "--method")) {
            args.overrides.backend = parseBackend(takeValue(argv, &i, arg));
        } else if (std.mem.eql(u8, arg, "--copy-to")) {
            args.overrides.copy_to = takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--resolved-forward-to")) {
            args.resolved_forward_to = takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--emit-dll")) {
            args.emit_dll = takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--emit-def")) {
            args.emit_def = takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--emit-runtime")) {
            args.emit_runtime = takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--emit-asm")) {
            args.emit_asm = takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--inspect")) {
            args.mode = .inspect;
        } else if (std.mem.eql(u8, arg, "--copy")) {
            args.mode = .copy;
            args.copy_source = takeValue(argv, &i, arg);
            args.copy_output_name = takeValue(argv, &i, arg);
            args.copy_dir = takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--prepare-input-dir")) {
            args.mode = .prepare_input_dir;
        } else if (std.mem.eql(u8, arg, "--clean-generated")) {
            args.mode = .clean_generated;
            args.clean_dir = takeValue(argv, &i, arg);
        } else {
            std.process.fatal("unknown argument: {s}", .{arg});
        }
    }

    return args;
}

fn takeValue(argv: []const []const u8, index: *usize, name: []const u8) []const u8 {
    index.* += 1;
    if (index.* >= argv.len) std.process.fatal("{s} needs a value", .{name});
    return argv[index.*];
}

fn parseBackend(value: []const u8) config.Backend {
    return std.meta.stringToEnum(config.Backend, value) orelse
        std.process.fatal("unknown backend: {s}", .{value});
}

fn generate(gpa: std.mem.Allocator, io: std.Io, args: Args) !void {
    const cfg = try loadConfig(gpa, io, args);
    const forward_to = try resolveForwardTo(gpa, cfg, args);
    defer gpa.free(forward_to);
    const export_source = try resolveExportSource(gpa, io, cfg.input, forward_to);
    defer gpa.free(export_source);
    const table = try loadExports(gpa, io, export_source);
    defer table.deinit(gpa);

    if (args.emit_dll) |dll_path| {
        const bytes = try buildForwarderDll(gpa, cfg, forward_to, table);
        defer gpa.free(bytes);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dll_path, .data = bytes });
        return;
    }

    const def_path = args.emit_def orelse std.process.fatal("missing --emit-def", .{});
    const runtime_path = args.emit_runtime orelse std.process.fatal("missing --emit-runtime", .{});
    const asm_path = args.emit_asm orelse std.process.fatal("missing --emit-asm", .{});

    const def_text = try buildDef(gpa, cfg, table);
    defer gpa.free(def_text);
    const runtime_text = try buildRuntimeConfig(gpa, forward_to, cfg, table);
    defer gpa.free(runtime_text);
    const asm_text = try buildStubAsm(gpa, cfg, table);
    defer gpa.free(asm_text);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = def_path, .data = def_text });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = runtime_path, .data = runtime_text });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = asm_path, .data = asm_text });
}

fn inspect(gpa: std.mem.Allocator, io: std.Io, args: Args) !void {
    const cfg = try loadConfig(gpa, io, args);
    const forward_to = try resolveForwardTo(gpa, cfg, args);
    defer gpa.free(forward_to);
    const export_source = try resolveExportSource(gpa, io, cfg.input, forward_to);
    defer gpa.free(export_source);
    const table = try loadExports(gpa, io, export_source);
    defer table.deinit(gpa);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try out.writer.print("DLS export map\n", .{});
    try out.writer.print("backend: {s}\n", .{@tagName(cfg.backend)});
    try out.writer.print("input: {s}\n", .{cfg.input});
    try out.writer.print("forward_to: {s}\n", .{forward_to});
    try out.writer.print("exports_from: {s}\n", .{export_source});
    try out.writer.print("output: {s}\n", .{config.outputName(cfg)});
    try out.writer.print("exports: {d}\n\n", .{table.exports.len});

    for (table.exports) |export_item| {
        try out.writer.print("@{d} ", .{export_item.ordinal});
        if (export_item.name) |name| {
            try out.writer.print("{s}", .{name});
        } else {
            try out.writer.print("<ordinal-only>", .{});
        }

        if (unsupportedReason(cfg, export_item)) |reason| {
            try out.writer.print(" unsupported: {s}\n", .{reason});
            continue;
        }

        const target = try displayTarget(gpa, cfg, forward_to, export_item);
        defer gpa.free(target);
        try out.writer.print(" -> {s}\n", .{target});
    }

    try std.Io.File.stdout().writeStreamingAll(io, out.writer.buffered());
}

fn loadConfig(gpa: std.mem.Allocator, io: std.Io, args: Args) !config.Config {
    return config.loadFile(gpa, io, args.config_path, args.overrides) catch |err| {
        std.process.fatal("unable to load {s}: {t}", .{ args.config_path, err });
    };
}

fn resolveForwardTo(gpa: std.mem.Allocator, cfg: config.Config, args: Args) ![]const u8 {
    if (args.resolved_forward_to) |forward_to| return gpa.dupe(u8, forward_to);
    return config.forwardToName(gpa, cfg);
}

fn resolveExportSource(gpa: std.mem.Allocator, io: std.Io, input: []const u8, forward_to: []const u8) ![]const u8 {
    if (exists(io, input)) return gpa.dupe(u8, input);
    if (exists(io, forward_to)) return gpa.dupe(u8, forward_to);
    std.process.fatal("unable to find export source DLL: {s} or {s}", .{ input, forward_to });
}

fn loadExports(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !pe.ExportTable {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        gpa,
        .limited(512 * 1024 * 1024),
    ) catch |err| {
        std.process.fatal("unable to read export source DLL {s}: {t}", .{ path, err });
    };
    errdefer gpa.free(bytes);

    var table = pe.parseExports(gpa, bytes) catch |err| {
        std.process.fatal("unable to parse exports from {s}: {t}", .{ path, err });
    };
    table.bytes = bytes;
    return table;
}

fn buildForwarderDll(gpa: std.mem.Allocator, cfg: config.Config, forward_to: []const u8, table: pe.ExportTable) ![]u8 {
    const idata = try buildImportData(gpa, cfg);
    defer gpa.free(idata);
    const edata_rva = IDATA_RVA + @as(u32, @intCast(idata.len));
    const edata = try buildExportData(gpa, cfg, forward_to, table, edata_rva);
    defer gpa.free(edata);

    var rdata: std.ArrayList(u8) = .empty;
    defer rdata.deinit(gpa);
    try appendSlice(gpa, &rdata, idata);
    try appendSlice(gpa, &rdata, edata);
    try padTo(gpa, &rdata, FILE_ALIGN);

    const rdata_virtual_size = alignForward(rdata.items.len, VIRTUAL_ALIGN);
    var header = [_]u8{0} ** FILE_ALIGN;

    writeU16(header[0..], 0x00, IMAGE_DOS_SIGNATURE);
    writeU32(header[0..], 0x3C, 0x40);
    writeU32(header[0..], 0x40, IMAGE_NT_SIGNATURE);

    const coff = 0x44;
    writeU16(header[0..], coff + 0, table.machine);
    writeU16(header[0..], coff + 2, 1);
    writeU16(header[0..], coff + 16, 0xF0);
    writeU16(header[0..], coff + 18, IMAGE_FILE_EXECUTABLE_IMAGE | IMAGE_FILE_LARGE_ADDRESS_AWARE | IMAGE_FILE_DLL);

    const optional = coff + 20;
    writeU16(header[0..], optional + 0, IMAGE_NT_OPTIONAL_HDR64_MAGIC);
    writeU64(header[0..], optional + 24, 0x10000);
    writeU32(header[0..], optional + 32, 0x1000);
    writeU32(header[0..], optional + 36, @as(u32, @intCast(FILE_ALIGN)));
    writeU16(header[0..], optional + 40, 6);
    writeU16(header[0..], optional + 48, 5);
    writeU32(header[0..], optional + 56, IDATA_RVA + @as(u32, @intCast(rdata_virtual_size)));
    writeU32(header[0..], optional + 60, @as(u32, @intCast(FILE_ALIGN)));
    writeU16(header[0..], optional + 68, IMAGE_SUBSYSTEM_WINDOWS_GUI);
    writeU16(header[0..], optional + 70, IMAGE_DLLCHARACTERISTICS_HIGH_ENTROPY_VA | IMAGE_DLLCHARACTERISTICS_DYNAMIC_BASE | IMAGE_DLLCHARACTERISTICS_NX_COMPAT);
    writeU64(header[0..], optional + 72, 0x100000);
    writeU64(header[0..], optional + 80, 0x1000);
    writeU64(header[0..], optional + 88, 0x100000);
    writeU64(header[0..], optional + 96, 0x1000);
    writeU32(header[0..], optional + 108, 16);

    const data_directories = optional + 112;
    writeU32(header[0..], data_directories + 0, edata_rva);
    writeU32(header[0..], data_directories + 4, @as(u32, @intCast(edata.len)));
    if (idata.len != 0) {
        writeU32(header[0..], data_directories + 8, IDATA_RVA);
        writeU32(header[0..], data_directories + 12, @as(u32, @intCast(idata.len)));
    }

    const section = optional + 0xF0;
    @memcpy(header[section..][0..6], ".rdata");
    writeU32(header[0..], section + 8, @as(u32, @intCast(rdata_virtual_size)));
    writeU32(header[0..], section + 12, IDATA_RVA);
    writeU32(header[0..], section + 16, @as(u32, @intCast(rdata.items.len)));
    writeU32(header[0..], section + 20, @as(u32, @intCast(FILE_ALIGN)));
    writeU32(header[0..], section + 36, IMAGE_SCN_MEM_READ);

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    try appendSlice(gpa, &bytes, header[0..]);
    try appendSlice(gpa, &bytes, rdata.items);
    return bytes.toOwnedSlice(gpa);
}

fn buildImportData(gpa: std.mem.Allocator, cfg: config.Config) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    if (cfg.load.len == 0) return buf.toOwnedSlice(gpa);
    const load_import = cfg.load_import orelse std.process.fatal("pe_forwarder backend needs load_import when load entries are present", .{});

    _ = try appendZeros(gpa, &buf, (cfg.load.len + 1) * 20);

    for (cfg.load, 0..) |dll_name, idx| {
        const descriptor_offset = idx * 20;
        const ilt_offset = try appendZeros(gpa, &buf, 16);
        const iat_offset = try appendZeros(gpa, &buf, 16);
        const dll_offset = try appendCString(gpa, &buf, dll_name);
        try padTo(gpa, &buf, 2);

        const thunk_value = try importThunkValue(gpa, &buf, load_import);
        try padTo(gpa, &buf, 16);

        writeU64(buf.items, ilt_offset, thunk_value);
        writeU64(buf.items, iat_offset, thunk_value);
        writeU32(buf.items, descriptor_offset + 0, IDATA_RVA + @as(u32, @intCast(ilt_offset)));
        writeU32(buf.items, descriptor_offset + 12, IDATA_RVA + @as(u32, @intCast(dll_offset)));
        writeU32(buf.items, descriptor_offset + 16, IDATA_RVA + @as(u32, @intCast(iat_offset)));
    }

    return buf.toOwnedSlice(gpa);
}

fn importThunkValue(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), load_import: []const u8) !u64 {
    if (std.mem.startsWith(u8, load_import, "#")) {
        const ordinal = std.fmt.parseInt(u16, load_import[1..], 10) catch |err|
            std.process.fatal("unable to parse import ordinal {s}: {t}", .{ load_import, err });
        return @as(u64, ordinal) | (@as(u64, 1) << 63);
    }

    const hint_offset = try appendZeros(gpa, buf, 2);
    const name_offset = try appendCString(gpa, buf, load_import);
    _ = name_offset;
    return @as(u64, IDATA_RVA) + @as(u64, @intCast(hint_offset));
}

fn buildExportData(gpa: std.mem.Allocator, cfg: config.Config, forward_to: []const u8, table: pe.ExportTable, edata_rva: u32) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    const function_count = @as(usize, @intCast(table.function_count));
    const directory_offset = try appendZeros(gpa, &buf, 40);
    const eat_offset = try appendZeros(gpa, &buf, function_count * 4);

    var named_exports: std.ArrayList(pe.Export) = .empty;
    defer named_exports.deinit(gpa);
    var names_by_index = try gpa.alloc(?[]const u8, function_count);
    defer gpa.free(names_by_index);
    @memset(names_by_index, null);
    var skip_index = try gpa.alloc(bool, function_count);
    defer gpa.free(skip_index);
    @memset(skip_index, false);

    var unsupported_count: usize = 0;
    for (table.exports) |export_item| {
        const ordinal_index = export_item.ordinal - table.ordinal_base;
        if (ordinal_index >= table.function_count) continue;

        if (unsupportedReason(cfg, export_item)) |reason| {
            unsupported_count += 1;
            skip_index[@as(usize, @intCast(ordinal_index))] = true;
            if (cfg.forwarding.fail_on_unsupported) {
                printUnsupported(export_item, reason);
            } else {
                printSkipped(export_item, reason);
            }
            continue;
        }

        if (export_item.name) |name| {
            names_by_index[@as(usize, @intCast(ordinal_index))] = name;
            try named_exports.append(gpa, export_item);
        }
    }

    if (unsupported_count != 0 and cfg.forwarding.fail_on_unsupported) return error.UnsupportedExport;

    std.sort.pdq(pe.Export, named_exports.items, {}, exportNameLessThan);

    const name_ptrs_offset = try appendZeros(gpa, &buf, named_exports.items.len * 4);
    const ordinals_offset = try appendZeros(gpa, &buf, named_exports.items.len * 2);

    for (named_exports.items, 0..) |export_item, idx| {
        const name = export_item.name.?;
        const name_offset = try appendCString(gpa, &buf, name);
        const ordinal_index = export_item.ordinal - table.ordinal_base;
        writeU32(buf.items, name_ptrs_offset + idx * 4, edata_rva + @as(u32, @intCast(name_offset)));
        writeU16(buf.items, ordinals_offset + idx * 2, @as(u16, @intCast(ordinal_index)));
    }

    for (0..function_count) |idx| {
        if (skip_index[idx]) continue;
        const ordinal = table.ordinal_base + @as(u32, @intCast(idx));
        const target = if (names_by_index[idx]) |name|
            try std.fmt.allocPrint(gpa, "{s}.{s}", .{ forward_to, name })
        else blk: {
            if (!cfg.forwarding.include_ordinals) continue;
            break :blk try std.fmt.allocPrint(gpa, "{s}.#{d}", .{ forward_to, ordinal });
        };
        defer gpa.free(target);
        const target_offset = try appendCString(gpa, &buf, target);
        writeU32(buf.items, eat_offset + idx * 4, edata_rva + @as(u32, @intCast(target_offset)));
    }

    const dll_name = table.dll_name orelse config.outputName(cfg);
    const dll_name_offset = try appendCString(gpa, &buf, dll_name);
    try padTo(gpa, &buf, 16);

    writeU32(buf.items, directory_offset + 12, edata_rva + @as(u32, @intCast(dll_name_offset)));
    writeU32(buf.items, directory_offset + 16, table.ordinal_base);
    writeU32(buf.items, directory_offset + 20, table.function_count);
    writeU32(buf.items, directory_offset + 24, @as(u32, @intCast(named_exports.items.len)));
    writeU32(buf.items, directory_offset + 28, edata_rva + @as(u32, @intCast(eat_offset)));
    writeU32(buf.items, directory_offset + 32, edata_rva + @as(u32, @intCast(name_ptrs_offset)));
    writeU32(buf.items, directory_offset + 36, edata_rva + @as(u32, @intCast(ordinals_offset)));

    return buf.toOwnedSlice(gpa);
}

fn exportNameLessThan(_: void, left: pe.Export, right: pe.Export) bool {
    return std.mem.lessThan(u8, left.name.?, right.name.?);
}

fn buildDef(gpa: std.mem.Allocator, cfg: config.Config, table: pe.ExportTable) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try out.writer.print("LIBRARY ", .{});
    try writeDefString(&out.writer, config.outputName(cfg));
    try out.writer.print("\nEXPORTS\n", .{});

    var used_ordinals: std.ArrayList(u32) = .empty;
    defer used_ordinals.deinit(gpa);

    var unsupported_count: usize = 0;
    var stub_index: usize = 0;

    for (table.exports) |export_item| {
        if (unsupportedReason(cfg, export_item)) |reason| {
            unsupported_count += 1;
            if (cfg.forwarding.fail_on_unsupported) {
                printUnsupported(export_item, reason);
            } else {
                printSkipped(export_item, reason);
            }
            continue;
        }

        try out.writer.print("    ", .{});
        if (export_item.name) |name| {
            try writeDefString(&out.writer, name);
        } else {
            try out.writer.print("Ordinal_{d}", .{export_item.ordinal});
        }
        try out.writer.print("=dls_export_{d}", .{stub_index});

        if (cfg.forwarding.include_ordinals and !hasOrdinal(used_ordinals.items, export_item.ordinal)) {
            try out.writer.print(" @{d}", .{export_item.ordinal});
            try used_ordinals.append(gpa, export_item.ordinal);
        } else if (cfg.forwarding.include_ordinals and export_item.name != null) {
            std.debug.print("warning: leaving duplicate ordinal off export {s}\n", .{export_item.name.?});
        }

        if (export_item.name == null) try out.writer.print(" NONAME", .{});
        try out.writer.print("\n", .{});
        stub_index += 1;
    }

    if (unsupported_count != 0 and cfg.forwarding.fail_on_unsupported) {
        return error.UnsupportedExport;
    }

    return out.toOwnedSlice();
}

fn buildRuntimeConfig(gpa: std.mem.Allocator, forward_to: []const u8, cfg: config.Config, table: pe.ExportTable) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try out.writer.print("const forward_to_w = [_:0]u16{{", .{});
    try writeUtf16Values(&out.writer, forward_to, "forward_to");
    try out.writer.print("}};\n", .{});
    try out.writer.print("pub const forward_to: [*:0]const u16 = &forward_to_w;\n", .{});
    try out.writer.print("pub const forward_to_text: [:0]const u8 = ", .{});
    try writeZigString(&out.writer, forward_to);
    try out.writer.print(";\n\n", .{});

    try out.writer.print("pub const export_count: usize = {d};\n\n", .{supportedExportCount(cfg, table)});

    try out.writer.print("pub const export_names = [_]?[:0]const u8{{\n", .{});
    for (table.exports) |export_item| {
        if (unsupportedReason(cfg, export_item) != null) continue;

        try out.writer.print("    ", .{});
        if (export_item.name) |name| {
            try writeZigString(&out.writer, name);
        } else {
            try out.writer.print("null", .{});
        }
        try out.writer.print(",\n", .{});
    }
    try out.writer.print("}};\n\n", .{});

    try out.writer.print("pub const export_ordinals = [_]u16{{\n", .{});
    for (table.exports) |export_item| {
        if (unsupportedReason(cfg, export_item) != null) continue;
        try out.writer.print("    {d},\n", .{export_item.ordinal});
    }
    try out.writer.print("}};\n\n", .{});

    for (cfg.load, 0..) |load, idx| {
        try out.writer.print("const load_{d}_w = [_:0]u16{{", .{idx});
        try writeUtf16Values(&out.writer, load, "load entry");
        try out.writer.print("}};\n", .{});
    }

    try out.writer.print("pub const load = [_][*:0]const u16{{\n", .{});
    for (cfg.load, 0..) |_, idx| {
        try out.writer.print("    &load_{d}_w,\n", .{idx});
    }
    try out.writer.print("}};\n\n", .{});

    try out.writer.print("pub const load_text = [_][:0]const u8{{\n", .{});
    for (cfg.load) |load| {
        try out.writer.print("    ", .{});
        try writeZigString(&out.writer, load);
        try out.writer.print(",\n", .{});
    }
    try out.writer.print("}};\n", .{});

    return out.toOwnedSlice();
}

fn buildStubAsm(gpa: std.mem.Allocator, cfg: config.Config, table: pe.ExportTable) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try out.writer.print(
        \\.intel_syntax noprefix
        \\.text
        \\.extern dls_resolve_export
        \\
        \\
    , .{});

    var stub_index: usize = 0;
    for (table.exports) |export_item| {
        if (unsupportedReason(cfg, export_item) != null) continue;
        try writeStub(&out.writer, stub_index);
        stub_index += 1;
    }

    return out.toOwnedSlice();
}

fn writeStub(w: *std.Io.Writer, index: usize) !void {
    try w.print(
        \\.globl dls_export_{d}
        \\.def dls_export_{d}; .scl 2; .type 32; .endef
        \\dls_export_{d}:
        \\    sub rsp, 0x88
        \\    mov qword ptr [rsp + 0x20], rcx
        \\    mov qword ptr [rsp + 0x28], rdx
        \\    mov qword ptr [rsp + 0x30], r8
        \\    mov qword ptr [rsp + 0x38], r9
        \\    movdqu xmmword ptr [rsp + 0x40], xmm0
        \\    movdqu xmmword ptr [rsp + 0x50], xmm1
        \\    movdqu xmmword ptr [rsp + 0x60], xmm2
        \\    movdqu xmmword ptr [rsp + 0x70], xmm3
        \\    mov ecx, {d}
        \\    call dls_resolve_export
        \\    mov r11, rax
        \\    movdqu xmm0, xmmword ptr [rsp + 0x40]
        \\    movdqu xmm1, xmmword ptr [rsp + 0x50]
        \\    movdqu xmm2, xmmword ptr [rsp + 0x60]
        \\    movdqu xmm3, xmmword ptr [rsp + 0x70]
        \\    mov rcx, qword ptr [rsp + 0x20]
        \\    mov rdx, qword ptr [rsp + 0x28]
        \\    mov r8, qword ptr [rsp + 0x30]
        \\    mov r9, qword ptr [rsp + 0x38]
        \\    add rsp, 0x88
        \\    jmp r11
        \\
        \\
    , .{ index, index, index, index });
}

fn unsupportedReason(cfg: config.Config, export_item: pe.Export) ?[]const u8 {
    return switch (cfg.backend) {
        .runtime_stub => runtimeStubUnsupportedReason(cfg, export_item),
        .pe_forwarder => peForwarderUnsupportedReason(cfg, export_item),
    };
}

fn runtimeStubUnsupportedReason(cfg: config.Config, export_item: pe.Export) ?[]const u8 {
    if (export_item.kind == .unknown) return "export RVA is not in a known PE section";
    if (export_item.kind == .data) {
        return if (cfg.forwarding.include_data_exports)
            "data export cannot be represented by runtime_stub"
        else
            "data export";
    }
    if (export_item.name == null and !cfg.forwarding.include_ordinals) return "ordinal-only export";
    if (export_item.ordinal > std.math.maxInt(u16)) return "ordinal is too large for GetProcAddress";
    return null;
}

fn peForwarderUnsupportedReason(cfg: config.Config, export_item: pe.Export) ?[]const u8 {
    if (export_item.kind == .data and !cfg.forwarding.include_data_exports) return "data export";
    if (export_item.name == null and !cfg.forwarding.include_ordinals) return "ordinal-only export";
    if (export_item.ordinal > std.math.maxInt(u16)) return "ordinal is too large for a PE ordinal import";
    return null;
}

fn supportedExportCount(cfg: config.Config, table: pe.ExportTable) usize {
    var count: usize = 0;
    for (table.exports) |export_item| {
        if (unsupportedReason(cfg, export_item) == null) count += 1;
    }
    return count;
}

fn displayTarget(gpa: std.mem.Allocator, cfg: config.Config, forward_to: []const u8, export_item: pe.Export) ![]u8 {
    return switch (cfg.backend) {
        .runtime_stub => runtimeTarget(gpa, forward_to, export_item),
        .pe_forwarder => forwarderTarget(gpa, forward_to, export_item),
    };
}

fn runtimeTarget(gpa: std.mem.Allocator, forward_to: []const u8, export_item: pe.Export) ![]u8 {
    if (export_item.name) |name| {
        return std.fmt.allocPrint(gpa, "{s}!{s}", .{ forward_to, name });
    }

    return std.fmt.allocPrint(gpa, "{s}!#{d}", .{ forward_to, export_item.ordinal });
}

fn forwarderTarget(gpa: std.mem.Allocator, forward_to: []const u8, export_item: pe.Export) ![]u8 {
    if (export_item.name) |name| {
        return std.fmt.allocPrint(gpa, "{s}.{s}", .{ forward_to, name });
    }

    return std.fmt.allocPrint(gpa, "{s}.#{d}", .{ forward_to, export_item.ordinal });
}

fn hasOrdinal(values: []const u32, ordinal: u32) bool {
    for (values) |value| {
        if (value == ordinal) return true;
    }
    return false;
}

fn printUnsupported(export_item: pe.Export, reason: []const u8) void {
    if (export_item.name) |name| {
        std.debug.print("unsupported export @{d} {s}: {s}\n", .{ export_item.ordinal, name, reason });
    } else {
        std.debug.print("unsupported export @{d}: {s}\n", .{ export_item.ordinal, reason });
    }
}

fn printSkipped(export_item: pe.Export, reason: []const u8) void {
    if (export_item.name) |name| {
        std.debug.print("warning: skipping export @{d} {s}: {s}\n", .{ export_item.ordinal, name, reason });
    } else {
        std.debug.print("warning: skipping export @{d}: {s}\n", .{ export_item.ordinal, reason });
    }
}

fn writeDefString(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    for (text) |ch| {
        switch (ch) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            else => try w.writeByte(ch),
        }
    }
    try w.writeByte('"');
}

fn writeZigString(w: *std.Io.Writer, text: []const u8) !void {
    const hex = "0123456789abcdef";

    try w.writeByte('"');
    for (text) |ch| {
        switch (ch) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (ch < 32 or ch == 127) {
                    try w.writeAll("\\x");
                    try w.writeByte(hex[ch >> 4]);
                    try w.writeByte(hex[ch & 0x0F]);
                } else {
                    try w.writeByte(ch);
                }
            },
        }
    }
    try w.writeByte('"');
}

fn writeUtf16Values(w: *std.Io.Writer, text: []const u8, label: []const u8) !void {
    var i: usize = 0;
    var first = true;

    while (i < text.len) {
        const codepoint = decodeUtf8Codepoint(text, &i) catch
            std.process.fatal("invalid UTF-8 in {s}", .{label});

        if (codepoint <= 0xFFFF) {
            try writeUtf16Unit(w, &first, @as(u16, @intCast(codepoint)));
        } else {
            const value = codepoint - 0x10000;
            try writeUtf16Unit(w, &first, @as(u16, @intCast(0xD800 + (value >> 10))));
            try writeUtf16Unit(w, &first, @as(u16, @intCast(0xDC00 + (value & 0x3FF))));
        }
    }
}

fn decodeUtf8Codepoint(text: []const u8, index: *usize) !u21 {
    const b0 = text[index.*];

    if (b0 < 0x80) {
        index.* += 1;
        return b0;
    }

    if ((b0 & 0xE0) == 0xC0) {
        if (index.* + 1 >= text.len) return error.InvalidUtf8;
        const b1 = text[index.* + 1];
        if ((b1 & 0xC0) != 0x80) return error.InvalidUtf8;
        const value: u21 = (@as(u21, b0 & 0x1F) << 6) | @as(u21, b1 & 0x3F);
        if (value < 0x80) return error.InvalidUtf8;
        index.* += 2;
        return value;
    }

    if ((b0 & 0xF0) == 0xE0) {
        if (index.* + 2 >= text.len) return error.InvalidUtf8;
        const b1 = text[index.* + 1];
        const b2 = text[index.* + 2];
        if ((b1 & 0xC0) != 0x80 or (b2 & 0xC0) != 0x80) return error.InvalidUtf8;
        const value: u21 = (@as(u21, b0 & 0x0F) << 12) |
            (@as(u21, b1 & 0x3F) << 6) |
            @as(u21, b2 & 0x3F);
        if (value < 0x800 or (value >= 0xD800 and value <= 0xDFFF)) return error.InvalidUtf8;
        index.* += 3;
        return value;
    }

    if ((b0 & 0xF8) == 0xF0) {
        if (index.* + 3 >= text.len) return error.InvalidUtf8;
        const b1 = text[index.* + 1];
        const b2 = text[index.* + 2];
        const b3 = text[index.* + 3];
        if ((b1 & 0xC0) != 0x80 or (b2 & 0xC0) != 0x80 or (b3 & 0xC0) != 0x80) return error.InvalidUtf8;
        const value: u21 = (@as(u21, b0 & 0x07) << 18) |
            (@as(u21, b1 & 0x3F) << 12) |
            (@as(u21, b2 & 0x3F) << 6) |
            @as(u21, b3 & 0x3F);
        if (value < 0x10000 or value > 0x10FFFF) return error.InvalidUtf8;
        index.* += 4;
        return value;
    }

    return error.InvalidUtf8;
}

fn writeUtf16Unit(w: *std.Io.Writer, first: *bool, unit: u16) !void {
    if (!first.*) try w.writeAll(", ");
    first.* = false;
    try w.print("0x{x}", .{unit});
}

fn copyBuiltDll(gpa: std.mem.Allocator, io: std.Io, args: Args) !void {
    const source = args.copy_source orelse std.process.fatal("missing copy source", .{});
    const output_name = args.copy_output_name orelse std.process.fatal("missing copy output name", .{});
    const copy_dir = args.copy_dir orelse std.process.fatal("missing copy directory", .{});

    try std.Io.Dir.cwd().createDirPath(io, copy_dir);
    const dest_path = try std.fs.path.join(gpa, &.{ copy_dir, output_name });
    defer gpa.free(dest_path);

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, source, gpa, .limited(512 * 1024 * 1024));
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest_path, .data = bytes });
}

fn prepareInputDir(gpa: std.mem.Allocator, io: std.Io, args: Args) !void {
    const cfg = try loadConfig(gpa, io, args);
    const forward_to = try resolveForwardTo(gpa, cfg, args);
    defer gpa.free(forward_to);

    if (std.ascii.eqlIgnoreCase(cfg.input, forward_to)) {
        std.process.fatal("input and forward_to resolve to the same path: {s}", .{cfg.input});
    }

    if (exists(io, forward_to)) return;
    if (!exists(io, cfg.input)) {
        std.process.fatal("input DLL is missing and forward_to does not exist: {s}", .{cfg.input});
    }

    std.Io.Dir.rename(.cwd(), cfg.input, .cwd(), forward_to, io) catch |err| {
        std.process.fatal("unable to rename {s} to {s}: {t}", .{ cfg.input, forward_to, err });
    };
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => std.process.fatal("unable to access {s}: {t}", .{ path, err }),
    };
    return true;
}

fn cleanGenerated(io: std.Io, dir: []const u8) !void {
    try std.Io.Dir.cwd().deleteTree(io, dir);
}

fn appendZeros(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), count: usize) !usize {
    const offset = buf.items.len;
    try buf.resize(gpa, offset + count);
    @memset(buf.items[offset..], 0);
    return offset;
}

fn appendSlice(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), bytes: []const u8) !void {
    const offset = buf.items.len;
    try buf.resize(gpa, offset + bytes.len);
    @memcpy(buf.items[offset..][0..bytes.len], bytes);
}

fn appendCString(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), text: []const u8) !usize {
    const offset = buf.items.len;
    try appendSlice(gpa, buf, text);
    try buf.append(gpa, 0);
    return offset;
}

fn padTo(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), alignment: usize) !void {
    _ = try appendZeros(gpa, buf, alignForward(buf.items.len, alignment) - buf.items.len);
}

fn alignForward(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

fn writeU16(buf: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, buf[offset..][0..2], value, .little);
}

fn writeU32(buf: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, buf[offset..][0..4], value, .little);
}

fn writeU64(buf: []u8, offset: usize, value: u64) void {
    std.mem.writeInt(u64, buf[offset..][0..8], value, .little);
}

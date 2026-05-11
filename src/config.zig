// DLS config surface
const std = @import("std");

pub const Backend = enum {
    runtime_stub,
    pe_forwarder,
};

pub const Forwarding = struct {
    include_ordinals: bool = true,
    include_data_exports: bool = false,
    fail_on_unsupported: bool = true,
};

pub const Config = struct {
    input: []const u8,
    forward_to: ?[]const u8 = null,
    output: ?[]const u8 = null,
    load: []const []const u8 = &.{},
    load_import: ?[]const u8 = "#1",
    copy_to: ?[]const u8 = null,
    backend: Backend = .runtime_stub,
    forwarding: Forwarding = .{},
};

pub const Overrides = struct {
    input: ?[]const u8 = null,
    forward_to: ?[]const u8 = null,
    output: ?[]const u8 = null,
    load: ?[]const u8 = null,
    load_import: ?[]const u8 = null,
    copy_to: ?[]const u8 = null,
    backend: ?Backend = null,
};

pub fn loadFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    overrides: Overrides,
) !Config {
    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(1024 * 1024),
        .of(u8),
        0,
    );
    defer gpa.free(source);

    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(gpa);

    var parsed = std.zon.parse.fromSliceAlloc(Config, gpa, source, &diag, .{}) catch |err| {
        if (err == error.ParseZon) std.debug.print("{s}: {f}", .{ path, &diag });
        return err;
    };

    try applyOverrides(gpa, &parsed, overrides);
    try validate(parsed);
    return parsed;
}

fn applyOverrides(gpa: std.mem.Allocator, cfg: *Config, overrides: Overrides) !void {
    if (overrides.input) |value| cfg.input = value;
    if (overrides.forward_to) |value| cfg.forward_to = value;
    if (overrides.output) |value| cfg.output = value;
    if (overrides.load_import) |value| cfg.load_import = value;
    if (overrides.copy_to) |value| cfg.copy_to = value;
    if (overrides.backend) |value| cfg.backend = value;

    if (overrides.load) |value| {
        if (value.len == 0) {
            cfg.load = &.{};
        } else {
            const items = try gpa.alloc([]const u8, 1);
            items[0] = value;
            cfg.load = items;
        }
    }
}

fn validate(cfg: Config) !void {
    if (cfg.input.len == 0) return error.EmptyInput;
    if (cfg.forward_to) |forward_to| {
        if (forward_to.len == 0) return error.EmptyForwardTo;
    } else if (!endsWithIgnoreCase(cfg.input, ".dll")) {
        return error.InputMustBeDllForDefaultForwardTo;
    }

    const resolved_output = outputName(cfg);
    if (resolved_output.len == 0) return error.EmptyOutput;
    if (!endsWithIgnoreCase(resolved_output, ".dll")) return error.OutputMustBeDll;

    if (cfg.load_import) |load_import| {
        if (load_import.len == 0) return error.EmptyLoadImport;
    }

    for (cfg.load) |load| {
        if (load.len == 0) return error.EmptyLoadEntry;
    }
}

pub fn outputName(cfg: Config) []const u8 {
    return cfg.output orelse std.fs.path.basenameWindows(cfg.input);
}

pub fn inputDirectory(cfg: Config) []const u8 {
    return std.fs.path.dirnameWindows(cfg.input) orelse ".";
}

pub fn forwardToName(gpa: std.mem.Allocator, cfg: Config) ![]const u8 {
    if (cfg.forward_to) |forward_to| return gpa.dupe(u8, forward_to);
    if (!endsWithIgnoreCase(cfg.input, ".dll")) return error.InputMustBeDllForDefaultForwardTo;
    return std.fmt.allocPrint(gpa, "{s}.og.dll", .{cfg.input[0 .. cfg.input.len - 4]});
}

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    if (text.len < suffix.len) return false;

    const start = text.len - suffix.len;
    for (suffix, 0..) |suffix_ch, idx| {
        if (std.ascii.toLower(text[start + idx]) != std.ascii.toLower(suffix_ch)) return false;
    }

    return true;
}

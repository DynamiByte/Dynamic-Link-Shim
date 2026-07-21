// DLS config surface
const std = @import("std");

pub const Method = enum {
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
    forward: ?[]const u8 = null,
    output: ?[]const u8 = null,
    load: []const []const u8 = &.{},
    autoload: bool = false,
    load_import: ?[]const u8 = "#1",
    copy_to: ?[]const u8 = null,
    output_pair: bool = false,
    embed_dlls: bool = false,
    bootstrap: bool = false,
    method: Method = .runtime_stub,
    forwarding: Forwarding = .{},
};

pub const Overrides = struct {
    input: ?[]const u8 = null,
    forward: ?[]const u8 = null,
    output: ?[]const u8 = null,
    load: ?[]const []const u8 = null,
    autoload: ?bool = null,
    load_import: ?[]const u8 = null,
    copy_to: ?[]const u8 = null,
    output_pair: ?bool = null,
    embed_dlls: ?bool = null,
    bootstrap: ?bool = null,
    method: ?Method = null,
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
    if (overrides.forward) |value| cfg.forward = value;
    if (overrides.output) |value| cfg.output = value;
    if (overrides.autoload) |value| cfg.autoload = value;
    if (overrides.load_import) |value| cfg.load_import = value;
    if (overrides.copy_to) |value| cfg.copy_to = value;
    if (overrides.output_pair) |value| cfg.output_pair = value;
    if (overrides.embed_dlls) |value| cfg.embed_dlls = value;
    if (overrides.bootstrap) |value| cfg.bootstrap = value;
    if (overrides.method) |value| cfg.method = value;

    _ = gpa;
    if (overrides.load) |value| cfg.load = value;
}

fn validate(cfg: Config) !void {
    if (cfg.input.len == 0) return error.EmptyInput;
    if (cfg.forward) |forward| {
        if (forward.len == 0) return error.EmptyForward;
    } else if (!endsWithIgnoreCase(cfg.input, ".dll")) {
        return error.InputMustBeDllForDefaultForward;
    }

    const resolved_output = outputName(cfg);
    if (resolved_output.len == 0) return error.EmptyOutput;
    if (!endsWithIgnoreCase(resolved_output, ".dll")) return error.OutputMustBeDll;

    if (cfg.load_import) |load_import| {
        if (load_import.len == 0) return error.EmptyLoadImport;
    }

    if (cfg.bootstrap and cfg.method != .runtime_stub) return error.BootstrapNeedsRuntimeStub;
    if (cfg.autoload and cfg.method != .runtime_stub) return error.AutoloadNeedsRuntimeStub;
    if (cfg.bootstrap and cfg.load.len == 0) return error.BootstrapNeedsLoadEntry;

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

pub fn forwardName(gpa: std.mem.Allocator, cfg: Config) ![]const u8 {
    if (cfg.forward) |forward| return gpa.dupe(u8, forward);
    if (!endsWithIgnoreCase(cfg.input, ".dll")) return error.InputMustBeDllForDefaultForward;
    return std.fmt.allocPrint(gpa, "{s}.og.dll", .{cfg.input[0 .. cfg.input.len - 4]});
}

pub fn embeddedRuntimeName(path: []const u8) []const u8 {
    return std.fs.path.basenameWindows(path);
}

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    if (text.len < suffix.len) return false;

    const start = text.len - suffix.len;
    for (suffix, 0..) |suffix_ch, idx| {
        if (std.ascii.toLower(text[start + idx]) != std.ascii.toLower(suffix_ch)) return false;
    }

    return true;
}

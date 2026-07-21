// DLS build graph
const std = @import("std");
const builtin = @import("builtin");
const config = @import("src/config.zig");
const surface = @import("src/surface.zig");

const WindowsAbi = enum {
    native,
    msvc,
    gnu,
};

const TargetDefaults = struct {
    target: std.Target.Query,
    dll_abi: WindowsAbi,
};

const CliOptions = struct {
    config_path: ?[]const u8 = null,
    overrides: config.Overrides = .{},
    copy_to_input_dir: bool = false,
};

const default_windows_arch: std.Target.Cpu.Arch = .x86_64;

fn defaultTargets() TargetDefaults {
    var defaults = TargetDefaults{
        .target = .{
            .cpu_arch = default_windows_arch,
            .os_tag = .windows,
            .abi = .gnu,
        },
        .dll_abi = .gnu,
    };

    if (builtin.os.tag == .windows) {
        defaults.target = .{};
        defaults.dll_abi = .native;
    }

    return defaults;
}

fn windowsAbiTarget(abi: WindowsAbi) ?std.Target.Abi {
    return switch (abi) {
        .native => null,
        .msvc => .msvc,
        .gnu => .gnu,
    };
}

fn resolveWindowsArtifactTarget(
    b: *std.Build,
    base_target: std.Build.ResolvedTarget,
    abi: WindowsAbi,
) std.Build.ResolvedTarget {
    const target_abi = windowsAbiTarget(abi) orelse return base_target;
    const os_tag = base_target.query.os_tag orelse base_target.result.os.tag;
    if (os_tag != .windows) return base_target;

    var query = base_target.query;
    if (query.cpu_arch == null and query.os_tag == null) {
        query.cpu_arch = default_windows_arch;
    }
    query.os_tag = query.os_tag orelse os_tag;
    query.abi = target_abi;
    query.glibc_version = null;
    query.android_api_level = null;
    return b.resolveTargetQuery(query);
}

fn addGeneratorArgs(
    run: *std.Build.Step.Run,
    config_path: []const u8,
    overrides: config.Overrides,
) void {
    run.addArg("--config");
    run.addArg(config_path);

    if (overrides.input) |value| {
        run.addArg("--input");
        run.addArg(value);
    }

    if (overrides.backing) |value| {
        run.addArg("--backing");
        run.addArg(value);
    }

    if (overrides.forward) |value| {
        run.addArg("--forward");
        run.addArg(value);
    }

    if (overrides.output) |value| {
        run.addArg("--output");
        run.addArg(value);
    }

    if (overrides.load) |values| {
        for (values) |value| {
            run.addArg("--load");
            run.addArg(value);
        }
    }

    if (overrides.load_import) |value| {
        run.addArg("--import");
        run.addArg(value);
    }

    if (overrides.autoload == true) run.addArg("--autoload");

    if (overrides.copy_to) |value| {
        run.addArg("--copy-to");
        run.addArg(value);
    }

    if (overrides.output_pair == true) run.addArg("--output-pair");

    if (overrides.embed_dlls == true) run.addArg("--embed-dlls");

    if (overrides.bootstrap == true) run.addArg("--bootstrap");

    if (overrides.method) |value| {
        run.addArg("--method");
        run.addArg(@tagName(value));
    }
}

fn loadBuildConfig(
    b: *std.Build,
    config_path: []const u8,
    overrides: config.Overrides,
) config.Config {
    return config.loadFile(b.allocator, b.graph.io, config_path, overrides) catch |err| {
        std.process.fatal("unable to load {s}: {t}", .{ config_path, err });
    };
}

fn readValue(args: []const []const u8, index: *usize, name: []const u8) []const u8 {
    index.* += 1;
    if (index.* >= args.len) {
        std.process.fatal("{s} needs a value", .{name});
    }
    return args[index.*];
}

fn parseForwardedArgs(allocator: std.mem.Allocator, args: ?[]const []const u8) CliOptions {
    const values = args orelse return .{};
    var parsed = CliOptions{};

    var i: usize = 0;
    while (i < values.len) : (i += 1) {
        const arg = values[i];

        if (std.mem.eql(u8, arg, "--config")) {
            parsed.config_path = readValue(values, &i, arg);
        } else if (std.mem.eql(u8, arg, "--input")) {
            parsed.overrides.input = readValue(values, &i, arg);
        } else if (std.mem.eql(u8, arg, "--backing")) {
            parsed.overrides.backing = readValue(values, &i, arg);
        } else if (std.mem.eql(u8, arg, "--forward")) {
            parsed.overrides.forward = readValue(values, &i, arg);
        } else if (std.mem.eql(u8, arg, "--output")) {
            parsed.overrides.output = readValue(values, &i, arg);
        } else if (std.mem.eql(u8, arg, "--load")) {
            appendLoad(allocator, &parsed, readValue(values, &i, arg));
        } else if (std.mem.eql(u8, arg, "--import")) {
            parsed.overrides.load_import = readValue(values, &i, arg);
        } else if (std.mem.eql(u8, arg, "--autoload")) {
            parsed.overrides.autoload = true;
        } else if (std.mem.eql(u8, arg, "--copy-to")) {
            parsed.overrides.copy_to = readValue(values, &i, arg);
        } else if (std.mem.eql(u8, arg, "--copy-to-input-dir")) {
            parsed.copy_to_input_dir = true;
        } else if (std.mem.eql(u8, arg, "--output-pair")) {
            parsed.overrides.output_pair = true;
        } else if (std.mem.eql(u8, arg, "--embed-dlls")) {
            parsed.overrides.embed_dlls = true;
        } else if (std.mem.eql(u8, arg, "--bootstrap")) {
            parsed.overrides.bootstrap = true;
        } else {
            std.process.fatal("unknown DLS argument: {s}", .{arg});
        }
    }

    return parsed;
}

fn appendLoad(allocator: std.mem.Allocator, parsed: *CliOptions, value: []const u8) void {
    const old = parsed.overrides.load orelse &.{};
    const next = allocator.alloc([]const u8, old.len + 1) catch |err|
        std.process.fatal("unable to store --load value: {t}", .{err});
    @memcpy(next[0..old.len], old);
    next[old.len] = value;
    parsed.overrides.load = next;
}

fn pathExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => std.process.fatal("unable to access {s}: {t}", .{ path, err }),
    };
    return true;
}

fn addEmbeddedDllImports(
    b: *std.Build,
    module: *std.Build.Module,
    app_config: config.Config,
    export_source_name: []const u8,
) void {
    if (!app_config.embed_dlls) return;

    addEmbeddedDllImport(b, module, 0, export_source_name);
    for (app_config.load, 0..) |load, idx| {
        addEmbeddedDllImport(b, module, idx + 1, load);
    }
}

fn addEmbeddedDllImport(
    b: *std.Build,
    module: *std.Build.Module,
    index: usize,
    source_path: []const u8,
) void {
    if (!pathExists(b.graph.io, source_path)) {
        std.process.fatal("embedded DLL source does not exist: {s}", .{source_path});
    }

    module.addAnonymousImport(b.fmt("dls_embed_{d}", .{index}), .{
        .root_source_file = .{ .cwd_relative = source_path },
    });
}

pub const Method = config.Method;
pub const Forwarding = config.Forwarding;

pub const Load = struct {
    name: []const u8,
    source: ?std.Build.LazyPath = null,
};

pub const ProxyOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode = .ReleaseSmall,
    input: []const u8,
    export_source: std.Build.LazyPath,
    backing_source: ?std.Build.LazyPath = null,
    forward: ?[]const u8 = null,
    output: ?[]const u8 = null,
    method: Method = .runtime_stub,
    load: []const Load = &.{},
    autoload: bool = false,
    load_import: ?[]const u8 = "#1",
    output_pair: bool = false,
    embed_dlls: bool = false,
    bootstrap: bool = false,
    forwarding: Forwarding = .{},
};

pub const Proxy = struct {
    dll: std.Build.LazyPath,
    compile: ?*std.Build.Step.Compile,
    output_name: []const u8,
    backing: ?std.Build.LazyPath,
    backing_name: ?[]const u8,
};

pub fn addProxy(
    b: *std.Build,
    dependency: *std.Build.Dependency,
    options: ProxyOptions,
) Proxy {
    if (options.target.result.os.tag != .windows) {
        std.process.fatal("DLS builds Windows DLLs; select a Windows target", .{});
    }
    if (options.target.result.cpu.arch != .x86_64) {
        std.process.fatal("DLS currently supports x86_64 Windows only", .{});
    }
    if (options.embed_dlls and options.method != .runtime_stub) {
        std.process.fatal("embedded DLL extraction needs the runtime_stub method", .{});
    }
    if (options.bootstrap and options.method != .runtime_stub) {
        std.process.fatal("bootstrap needs the runtime_stub method", .{});
    }
    if (options.autoload and options.method != .runtime_stub) {
        std.process.fatal("autoload needs the runtime_stub method", .{});
    }

    const load_names = b.allocator.alloc([]const u8, options.load.len) catch @panic("OOM");
    for (options.load, load_names) |load, *name| name.* = load.name;

    const app_config: config.Config = .{
        .input = options.input,
        .forward = options.forward,
        .output = options.output,
        .load = load_names,
        .autoload = options.autoload,
        .load_import = options.load_import,
        .output_pair = options.output_pair,
        .embed_dlls = options.embed_dlls,
        .bootstrap = options.bootstrap,
        .method = options.method,
        .forwarding = options.forwarding,
    };
    const config_file = writeProxyConfig(b, app_config);
    const output_name = config.outputName(app_config);
    const forward_name = config.forwardName(b.allocator, app_config) catch |err|
        std.process.fatal("unable to resolve forward: {t}", .{err});
    const backing_name = std.fs.path.basenameWindows(forward_name);
    const backing_source = options.backing_source orelse options.export_source;
    const runtime_forward = if (options.output_pair or options.embed_dlls or options.bootstrap) backing_name else forward_name;

    const generator = b.addExecutable(.{
        .name = "dls-generate",
        .root_module = b.createModule(.{
            .root_source_file = dependency.path("src/generator.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSmall,
        }),
    });

    const generate = b.addRunArtifact(generator);
    generate.addArg("--config");
    generate.addFileArg(config_file);
    generate.addArg("--resolved-forward");
    generate.addArg(runtime_forward);
    generate.addArg("--export-source");
    generate.addFileArg(options.export_source);

    if (options.method == .pe_forwarder) {
        generate.addArg("--emit-dll");
        const dll = generate.addOutputFileArg(output_name);
        return .{
            .dll = dll,
            .compile = null,
            .output_name = output_name,
            .backing = if (options.output_pair) backing_source else null,
            .backing_name = if (options.output_pair) backing_name else null,
        };
    }

    generate.addArg("--emit-def");
    const def_file = generate.addOutputFileArg("proxy.def");
    generate.addArg("--emit-runtime");
    const runtime_config = generate.addOutputFileArg("runtime_config.zig");
    generate.addArg("--emit-asm");
    const stub_asm = generate.addOutputFileArg("runtime_stubs.s");

    const runtime_module = b.createModule(.{
        .root_source_file = runtime_config,
        .target = options.target,
        .optimize = options.optimize,
    });
    if (options.embed_dlls) {
        addEmbeddedDllImportPath(b, runtime_module, 0, backing_source);
        for (options.load, 0..) |load, idx| {
            const source = load.source orelse std.process.fatal("embedded load entry needs a source: {s}", .{load.name});
            addEmbeddedDllImportPath(b, runtime_module, idx + 1, source);
        }
    }

    const dll = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "DLS",
        .root_module = b.createModule(.{
            .root_source_file = dependency.path("src/proxy.zig"),
            .target = options.target,
            .optimize = options.optimize,
        }),
        .win32_module_definition = def_file,
    });
    dll.root_module.addImport("runtime_config", runtime_module);
    dll.root_module.linkSystemLibrary("kernel32", .{});
    dll.root_module.linkSystemLibrary("user32", .{});
    dll.root_module.addAssemblyFile(stub_asm);
    dll.dll_export_fns = false;

    return .{
        .dll = dll.getEmittedBin(),
        .compile = dll,
        .output_name = output_name,
        .backing = if (options.output_pair) backing_source else null,
        .backing_name = if (options.output_pair) backing_name else null,
    };
}

fn writeProxyConfig(b: *std.Build, app_config: config.Config) std.Build.LazyPath {
    var out: std.Io.Writer.Allocating = .init(b.allocator);
    defer out.deinit();
    std.zon.stringify.serialize(app_config, .{}, &out.writer) catch @panic("OOM");
    const contents = out.toOwnedSlice() catch @panic("OOM");
    return b.addWriteFiles().add("dls-config.zon", contents);
}

fn addEmbeddedDllImportPath(
    b: *std.Build,
    module: *std.Build.Module,
    index: usize,
    source: std.Build.LazyPath,
) void {
    module.addAnonymousImport(b.fmt("dls_embed_{d}", .{index}), .{ .root_source_file = source });
}

fn applySurfaceDefaults(
    b: *std.Build,
    config_path: []const u8,
    overrides: *config.Overrides,
    initial: config.Config,
) config.Config {
    if (!surface.isPath(initial.input)) return initial;

    const loaded = surface.loadFile(b.allocator, b.graph.io, initial.input) catch |err|
        std.process.fatal("unable to read export surface {s}: {t}", .{ initial.input, err });
    defer loaded.deinit(b.allocator);

    var changed = false;
    if (initial.output == null) {
        overrides.output = b.allocator.dupe(u8, loaded.target_name) catch @panic("OOM");
        changed = true;
    }
    if (initial.forward == null) {
        const target = loaded.target_name;
        overrides.forward = std.fmt.allocPrint(b.allocator, "{s}.og.dll", .{target[0 .. target.len - 4]}) catch @panic("OOM");
        changed = true;
    }

    return if (changed) loadBuildConfig(b, config_path, overrides.*) else initial;
}

pub fn build(b: *std.Build) void {
    if (b.dep_prefix.len != 0) return;

    const defaults = defaultTargets();
    const base_target = b.standardTargetOptions(.{ .default_target = defaults.target });
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Build optimization mode") orelse .ReleaseSmall;
    const dll_windows_abi = b.option(WindowsAbi, "dll-abi", "Windows ABI for the output DLL") orelse defaults.dll_abi;
    const dll_target = resolveWindowsArtifactTarget(b, base_target, dll_windows_abi);

    if (dll_target.result.os.tag != .windows) {
        std.process.fatal("DLS builds Windows DLLs; select a Windows target", .{});
    }

    const cli_options = parseForwardedArgs(b.allocator, b.args);
    const config_path = cli_options.config_path orelse "config.zon";
    if (cli_options.copy_to_input_dir and cli_options.overrides.copy_to != null) {
        std.process.fatal("use --copy-to or --copy-to-input-dir, not both", .{});
    }

    var overrides = cli_options.overrides;
    if (b.option(config.Method, "method", "Proxy generation method")) |value| {
        overrides.method = value;
    }
    var app_config = applySurfaceDefaults(b, config_path, &overrides, loadBuildConfig(b, config_path, overrides));
    const input_is_surface = surface.isPath(app_config.input);
    if (cli_options.copy_to_input_dir and app_config.output_pair) {
        std.process.fatal("use --output-pair or --copy-to-input-dir, not both", .{});
    }
    if (cli_options.copy_to_input_dir and app_config.embed_dlls) {
        std.process.fatal("use --embed-dlls or --copy-to-input-dir, not both", .{});
    }
    if (app_config.embed_dlls and app_config.method == .pe_forwarder) {
        std.process.fatal("embedded DLL extraction needs the runtime_stub method", .{});
    }
    if (app_config.bootstrap and app_config.method == .pe_forwarder) {
        std.process.fatal("bootstrap needs the runtime_stub method", .{});
    }
    if (cli_options.copy_to_input_dir and input_is_surface) {
        std.process.fatal("copy-to-input-dir needs the original input DLL, not a .dls surface", .{});
    }
    if (cli_options.copy_to_input_dir) {
        app_config.copy_to = config.inputDirectory(app_config);
        overrides.copy_to = app_config.copy_to;
    }

    const output_name = config.outputName(app_config);
    const forward_name = config.forwardName(b.allocator, app_config) catch |err| {
        std.process.fatal("unable to resolve forward: {t}", .{err});
    };
    const export_source_name = if (input_is_surface)
        app_config.input
    else if (cli_options.copy_to_input_dir)
        forward_name
    else if (pathExists(b.graph.io, forward_name))
        forward_name
    else if (pathExists(b.graph.io, app_config.input))
        app_config.input
    else
        std.process.fatal("unable to find export source DLL: {s} or {s}", .{ app_config.input, forward_name });
    const backing_source_name: ?[]const u8 = app_config.backing orelse if (input_is_surface) null else export_source_name;
    if ((app_config.output_pair or app_config.embed_dlls) and backing_source_name == null) {
        std.process.fatal("output-pair and embed-dlls need --backing when input is a .dls surface", .{});
    }
    if (backing_source_name) |backing| {
        if (!pathExists(b.graph.io, backing)) std.process.fatal("unable to find backing DLL: {s}", .{backing});
    }
    const backing_output_name = std.fs.path.basenameWindows(forward_name);
    const runtime_forward_name = if (app_config.output_pair or app_config.embed_dlls or app_config.bootstrap) backing_output_name else forward_name;

    const generator = b.addExecutable(.{
        .name = "dls-generate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/generator.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSmall,
        }),
    });

    if (!input_is_surface) {
        const surface_name = config.surfaceName(b.allocator, app_config) catch |err|
            std.process.fatal("unable to resolve surface output: {t}", .{err});
        const compile_surface = b.addRunArtifact(generator);
        addGeneratorArgs(compile_surface, config_path, overrides);
        compile_surface.addArg("--export-source");
        compile_surface.addArg(export_source_name);
        compile_surface.addArg("--emit-surface");
        const surface_output = compile_surface.addOutputFileArg(surface_name);
        const install_surface = b.addInstallFileWithDir(surface_output, .bin, surface_name);
        const surface_step = b.step("surface", "Compile the configured input DLL export surface");
        surface_step.dependOn(&install_surface.step);
    }

    const prepare_input_dir = if (cli_options.copy_to_input_dir) blk: {
        const prepare = b.addRunArtifact(generator);
        addGeneratorArgs(prepare, config_path, overrides);
        prepare.addArg("--resolved-forward");
        prepare.addArg(forward_name);
        prepare.addArg("--prepare-input-dir");
        break :blk prepare;
    } else null;

    if (app_config.method == .pe_forwarder) {
        const generate = b.addRunArtifact(generator);
        if (prepare_input_dir) |prepare| generate.step.dependOn(&prepare.step);
        addGeneratorArgs(generate, config_path, overrides);
        generate.addArg("--resolved-forward");
        generate.addArg(runtime_forward_name);
        generate.addArg("--export-source");
        generate.addArg(export_source_name);
        generate.addArg("--emit-dll");
        const dll_output = generate.addOutputFileArg(output_name);

        const install_dll = b.addInstallFileWithDir(dll_output, .bin, output_name);
        b.getInstallStep().dependOn(&install_dll.step);
        if (app_config.output_pair) {
            const install_backing = b.addInstallFileWithDir(.{ .cwd_relative = backing_source_name.? }, .bin, backing_output_name);
            b.getInstallStep().dependOn(&install_backing.step);
        }

        if (app_config.copy_to) |copy_to| {
            const copy = b.addRunArtifact(generator);
            copy.addArg("--copy");
            copy.addFileArg(dll_output);
            copy.addArg(output_name);
            copy.addArg(copy_to);
            b.getInstallStep().dependOn(&copy.step);

            if (app_config.output_pair) {
                const copy_backing = b.addRunArtifact(generator);
                copy_backing.addArg("--copy");
                copy_backing.addArg(backing_source_name.?);
                copy_backing.addArg(backing_output_name);
                copy_backing.addArg(copy_to);
                b.getInstallStep().dependOn(&copy_backing.step);
            }
        }
    } else {
        if (dll_target.result.cpu.arch != .x86_64) {
            std.process.fatal("DLS runtime_stub currently supports x86_64 Windows only", .{});
        }

        const generate = b.addRunArtifact(generator);
        if (prepare_input_dir) |prepare| generate.step.dependOn(&prepare.step);
        addGeneratorArgs(generate, config_path, overrides);
        generate.addArg("--resolved-forward");
        generate.addArg(runtime_forward_name);
        generate.addArg("--export-source");
        generate.addArg(export_source_name);
        generate.addArg("--emit-def");
        const def_file = generate.addOutputFileArg("proxy.def");
        generate.addArg("--emit-runtime");
        const runtime_config = generate.addOutputFileArg("runtime_config.zig");
        generate.addArg("--emit-asm");
        const stub_asm = generate.addOutputFileArg("runtime_stubs.s");

        const runtime_module = b.createModule(.{
            .root_source_file = runtime_config,
            .target = dll_target,
            .optimize = optimize,
        });
        addEmbeddedDllImports(b, runtime_module, app_config, backing_source_name orelse export_source_name);

        const dll = b.addLibrary(.{
            .linkage = .dynamic,
            .name = "DLS",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/proxy.zig"),
                .target = dll_target,
                .optimize = optimize,
            }),
            .win32_module_definition = def_file,
        });
        dll.root_module.addImport("runtime_config", runtime_module);
        dll.root_module.linkSystemLibrary("kernel32", .{});
        dll.root_module.linkSystemLibrary("user32", .{});
        dll.root_module.addAssemblyFile(stub_asm);
        dll.dll_export_fns = false;

        const install_dll = b.addInstallFileWithDir(dll.getEmittedBin(), .bin, output_name);
        b.getInstallStep().dependOn(&install_dll.step);
        if (app_config.output_pair) {
            const install_backing = b.addInstallFileWithDir(.{ .cwd_relative = backing_source_name.? }, .bin, backing_output_name);
            b.getInstallStep().dependOn(&install_backing.step);
        }

        if (app_config.copy_to) |copy_to| {
            const copy = b.addRunArtifact(generator);
            copy.addArg("--copy");
            copy.addFileArg(dll.getEmittedBin());
            copy.addArg(output_name);
            copy.addArg(copy_to);
            b.getInstallStep().dependOn(&copy.step);

            if (app_config.output_pair) {
                const copy_backing = b.addRunArtifact(generator);
                copy_backing.addArg("--copy");
                copy_backing.addArg(backing_source_name.?);
                copy_backing.addArg(backing_output_name);
                copy_backing.addArg(copy_to);
                b.getInstallStep().dependOn(&copy_backing.step);
            }
        }
    }

    const inspect = b.step("inspect", "Print the configured DLL or .dls export map");
    const inspect_run = b.addRunArtifact(generator);
    addGeneratorArgs(inspect_run, config_path, overrides);
    inspect_run.addArg("--resolved-forward");
    inspect_run.addArg(runtime_forward_name);
    inspect_run.addArg("--export-source");
    inspect_run.addArg(export_source_name);
    inspect_run.addArg("--inspect");
    inspect.dependOn(&inspect_run.step);

    const clean_generated = b.step("clean-generated", "Remove generated files emitted outside zig-cache");
    const clean_run = b.addRunArtifact(generator);
    clean_run.addArg("--clean-generated");
    clean_run.addArg("generated");
    clean_generated.dependOn(&clean_run.step);
}

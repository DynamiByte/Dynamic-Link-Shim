// DLS build graph
const std = @import("std");
const builtin = @import("builtin");
const config = @import("src/config.zig");

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

    if (overrides.forward_to) |value| {
        run.addArg("--forward-to");
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

    if (overrides.copy_to) |value| {
        run.addArg("--copy-to");
        run.addArg(value);
    }

    if (overrides.output_pair) |value| {
        run.addArg(if (value) "--output-pair" else "--no-output-pair");
    }

    if (overrides.embed_dlls) |value| {
        run.addArg(if (value) "--embed-dlls" else "--no-embed-dlls");
    }

    if (overrides.bootstrap) |value| {
        run.addArg(if (value) "--bootstrap" else "--no-bootstrap");
    }

    if (overrides.backend) |value| {
        run.addArg("--backend");
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
        } else if (std.mem.eql(u8, arg, "--forward-to") or std.mem.eql(u8, arg, "--forward_to")) {
            parsed.overrides.forward_to = readValue(values, &i, arg);
        } else if (std.mem.eql(u8, arg, "--output")) {
            parsed.overrides.output = readValue(values, &i, arg);
        } else if (std.mem.eql(u8, arg, "--load")) {
            appendLoad(allocator, &parsed, readValue(values, &i, arg));
        } else if (std.mem.eql(u8, arg, "--import") or std.mem.eql(u8, arg, "--load-import") or std.mem.eql(u8, arg, "--load_import")) {
            parsed.overrides.load_import = readValue(values, &i, arg);
        } else if (std.mem.eql(u8, arg, "--copy-to") or std.mem.eql(u8, arg, "--copy_to")) {
            parsed.overrides.copy_to = readValue(values, &i, arg);
        } else if (std.mem.eql(u8, arg, "--copy-to-input-dir")) {
            parsed.copy_to_input_dir = true;
        } else if (std.mem.eql(u8, arg, "--output-pair")) {
            parsed.overrides.output_pair = true;
        } else if (std.mem.eql(u8, arg, "--no-output-pair")) {
            parsed.overrides.output_pair = false;
        } else if (std.mem.eql(u8, arg, "--embed") or std.mem.eql(u8, arg, "--embed-dlls") or std.mem.eql(u8, arg, "--embed_dlls")) {
            parsed.overrides.embed_dlls = true;
        } else if (std.mem.eql(u8, arg, "--no-embed") or std.mem.eql(u8, arg, "--no-embed-dlls") or std.mem.eql(u8, arg, "--no-embed_dlls")) {
            parsed.overrides.embed_dlls = false;
        } else if (std.mem.eql(u8, arg, "--bootstrap")) {
            parsed.overrides.bootstrap = true;
        } else if (std.mem.eql(u8, arg, "--no-bootstrap")) {
            parsed.overrides.bootstrap = false;
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

pub fn build(b: *std.Build) void {
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
    if (b.option(config.Backend, "backend", "Proxy generation backend")) |value| {
        overrides.backend = value;
    }
    var app_config = loadBuildConfig(b, config_path, overrides);
    if (cli_options.copy_to_input_dir and app_config.output_pair) {
        std.process.fatal("use --output-pair or --copy-to-input-dir, not both", .{});
    }
    if (cli_options.copy_to_input_dir and app_config.embed_dlls) {
        std.process.fatal("use --embed-dlls or --copy-to-input-dir, not both", .{});
    }
    if (app_config.embed_dlls and app_config.backend == .pe_forwarder) {
        std.process.fatal("embedded DLL extraction needs the runtime_stub backend", .{});
    }
    if (app_config.bootstrap and app_config.backend == .pe_forwarder) {
        std.process.fatal("bootstrap needs the runtime_stub backend", .{});
    }
    if (cli_options.copy_to_input_dir) {
        app_config.copy_to = config.inputDirectory(app_config);
        overrides.copy_to = app_config.copy_to;
    }

    const output_name = config.outputName(app_config);
    const forward_to_name = config.forwardToName(b.allocator, app_config) catch |err| {
        std.process.fatal("unable to resolve forward_to: {t}", .{err});
    };
    const export_source_name = if (cli_options.copy_to_input_dir)
        forward_to_name
    else if (pathExists(b.graph.io, forward_to_name))
        forward_to_name
    else if (pathExists(b.graph.io, app_config.input))
        app_config.input
    else
        std.process.fatal("unable to find export source DLL: {s} or {s}", .{ app_config.input, forward_to_name });
    const backing_output_name = std.fs.path.basenameWindows(forward_to_name);
    const runtime_forward_to_name = if (app_config.output_pair or app_config.embed_dlls or app_config.bootstrap) backing_output_name else forward_to_name;

    const generator = b.addExecutable(.{
        .name = "dls-generate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/generator.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSmall,
        }),
    });

    const prepare_input_dir = if (cli_options.copy_to_input_dir) blk: {
        const prepare = b.addRunArtifact(generator);
        addGeneratorArgs(prepare, config_path, overrides);
        prepare.addArg("--resolved-forward-to");
        prepare.addArg(forward_to_name);
        prepare.addArg("--prepare-input-dir");
        break :blk prepare;
    } else null;

    if (app_config.backend == .pe_forwarder) {
        const generate = b.addRunArtifact(generator);
        if (prepare_input_dir) |prepare| generate.step.dependOn(&prepare.step);
        addGeneratorArgs(generate, config_path, overrides);
        generate.addArg("--resolved-forward-to");
        generate.addArg(runtime_forward_to_name);
        generate.addArg("--export-source");
        generate.addArg(export_source_name);
        generate.addArg("--emit-dll");
        const dll_output = generate.addOutputFileArg(output_name);

        const install_dll = b.addInstallFileWithDir(dll_output, .bin, output_name);
        b.getInstallStep().dependOn(&install_dll.step);
        if (app_config.output_pair) {
            const install_backing = b.addInstallFileWithDir(.{ .cwd_relative = export_source_name }, .bin, backing_output_name);
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
                copy_backing.addArg(export_source_name);
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
        generate.addArg("--resolved-forward-to");
        generate.addArg(runtime_forward_to_name);
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
        addEmbeddedDllImports(b, runtime_module, app_config, export_source_name);

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
            const install_backing = b.addInstallFileWithDir(.{ .cwd_relative = export_source_name }, .bin, backing_output_name);
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
                copy_backing.addArg(export_source_name);
                copy_backing.addArg(backing_output_name);
                copy_backing.addArg(copy_to);
                b.getInstallStep().dependOn(&copy_backing.step);
            }
        }
    }

    const inspect = b.step("inspect", "Parse the configured input DLL and print the export map");
    const inspect_run = b.addRunArtifact(generator);
    addGeneratorArgs(inspect_run, config_path, overrides);
    inspect_run.addArg("--resolved-forward-to");
    inspect_run.addArg(runtime_forward_to_name);
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

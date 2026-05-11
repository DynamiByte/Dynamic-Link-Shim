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

    if (overrides.load) |value| {
        run.addArg("--load");
        run.addArg(value);
    }

    if (overrides.load_import) |value| {
        run.addArg("--import");
        run.addArg(value);
    }

    if (overrides.copy_to) |value| {
        run.addArg("--copy-to");
        run.addArg(value);
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

fn parseBackend(value: []const u8) config.Backend {
    return std.meta.stringToEnum(config.Backend, value) orelse
        std.process.fatal("unknown backend: {s}", .{value});
}

fn parseForwardedArgs(args: ?[]const []const u8) CliOptions {
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
            parsed.overrides.load = readValue(values, &i, arg);
        } else if (std.mem.eql(u8, arg, "--import") or std.mem.eql(u8, arg, "--load-import") or std.mem.eql(u8, arg, "--load_import")) {
            parsed.overrides.load_import = readValue(values, &i, arg);
        } else if (std.mem.eql(u8, arg, "--backend") or std.mem.eql(u8, arg, "--method")) {
            parsed.overrides.backend = parseBackend(readValue(values, &i, arg));
        } else if (std.mem.eql(u8, arg, "--copy-to") or std.mem.eql(u8, arg, "--copy_to")) {
            parsed.overrides.copy_to = readValue(values, &i, arg);
        } else if (std.mem.eql(u8, arg, "--copy-to-input-dir")) {
            parsed.copy_to_input_dir = true;
        } else {
            std.process.fatal("unknown DLS argument: {s}", .{arg});
        }
    }

    return parsed;
}

fn chooseOverride(d_option: ?[]const u8, cli_option: ?[]const u8) ?[]const u8 {
    return cli_option orelse d_option;
}

fn chooseBackend(d_option: ?config.Backend, cli_option: ?config.Backend) ?config.Backend {
    return cli_option orelse d_option;
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

    const cli_options = parseForwardedArgs(b.args);
    const config_path = cli_options.config_path orelse
        (b.option([]const u8, "config", "Config file") orelse "config.zon");
    const copy_to_option = chooseOverride(
        b.option([]const u8, "copy_to", "Override config output copy directory"),
        cli_options.overrides.copy_to,
    );
    if (cli_options.copy_to_input_dir and copy_to_option != null) {
        std.process.fatal("use --copy-to or --copy-to-input-dir, not both", .{});
    }

    var overrides = config.Overrides{
        .input = chooseOverride(b.option([]const u8, "input", "Override config input DLL"), cli_options.overrides.input),
        .forward_to = chooseOverride(b.option([]const u8, "forward_to", "Override config forward target"), cli_options.overrides.forward_to),
        .output = chooseOverride(b.option([]const u8, "output", "Override config output DLL name"), cli_options.overrides.output),
        .load = chooseOverride(b.option([]const u8, "load", "Override config load list with one DLL"), cli_options.overrides.load),
        .load_import = chooseOverride(b.option([]const u8, "import", "Override config load import"), cli_options.overrides.load_import),
        .copy_to = copy_to_option,
        .backend = chooseBackend(b.option(config.Backend, "backend", "Proxy generation backend"), cli_options.overrides.backend),
    };
    var app_config = loadBuildConfig(b, config_path, overrides);
    if (cli_options.copy_to_input_dir) {
        app_config.copy_to = config.inputDirectory(app_config);
        overrides.copy_to = app_config.copy_to;
    }

    const output_name = config.outputName(app_config);
    const forward_to_name = config.forwardToName(b.allocator, app_config) catch |err| {
        std.process.fatal("unable to resolve forward_to: {t}", .{err});
    };

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
        generate.addArg(forward_to_name);
        generate.addArg("--emit-dll");
        const dll_output = generate.addOutputFileArg(output_name);

        const install_dll = b.addInstallFileWithDir(dll_output, .bin, output_name);
        b.getInstallStep().dependOn(&install_dll.step);

        if (app_config.copy_to) |copy_to| {
            const copy = b.addRunArtifact(generator);
            copy.addArg("--copy");
            copy.addFileArg(dll_output);
            copy.addArg(output_name);
            copy.addArg(copy_to);
            b.getInstallStep().dependOn(&copy.step);
        }
    } else {
        if (dll_target.result.cpu.arch != .x86_64) {
            std.process.fatal("DLS runtime_stub currently supports x86_64 Windows only", .{});
        }

        const generate = b.addRunArtifact(generator);
        if (prepare_input_dir) |prepare| generate.step.dependOn(&prepare.step);
        addGeneratorArgs(generate, config_path, overrides);
        generate.addArg("--resolved-forward-to");
        generate.addArg(forward_to_name);
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

        if (app_config.copy_to) |copy_to| {
            const copy = b.addRunArtifact(generator);
            copy.addArg("--copy");
            copy.addFileArg(dll.getEmittedBin());
            copy.addArg(output_name);
            copy.addArg(copy_to);
            b.getInstallStep().dependOn(&copy.step);
        }
    }

    const inspect = b.step("inspect", "Parse the configured input DLL and print the export map");
    const inspect_run = b.addRunArtifact(generator);
    addGeneratorArgs(inspect_run, config_path, overrides);
    inspect_run.addArg("--resolved-forward-to");
    inspect_run.addArg(forward_to_name);
    inspect_run.addArg("--inspect");
    inspect.dependOn(&inspect_run.step);

    const clean_generated = b.step("clean-generated", "Remove generated files emitted outside zig-cache");
    const clean_run = b.addRunArtifact(generator);
    clean_run.addArg("--clean-generated");
    clean_run.addArg("generated");
    clean_generated.dependOn(&clean_run.step);
}

const std = @import("std");
const zzdoc = @import("zzdoc");

/// Must be kept in sync with git tags
const comlink_version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 1 };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pie = b.option(bool, "pie", "Build a Position Independent Executable") orelse false;

    // manpages
    {
        var man_step = zzdoc.addManpageStep(b, .{
            .root_doc_dir = b.path("docs/"),
        });

        const install_step = man_step.addInstallStep(.{});
        b.default_step.dependOn(&install_step.step);
    }

    const ziglua_dep = b.dependency("ziglua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua54,
    });

    const tls_dep = b.dependency("tls", .{
        .target = target,
        .optimize = optimize,
    });

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
        .libxev = false,
    });

    const zeit_dep = b.dependency("zeit", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "comlink",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.pie = pie;

    const opts = b.addOptions();
    const version_string = version(b) catch |err| {
        std.debug.print("{}", .{err});
        @compileError("couldn't get version");
    };
    opts.addOption([]const u8, "version", version_string);

    exe.root_module.addOptions("build_options", opts);
    exe.root_module.addImport("tls", tls_dep.module("tls"));
    exe.root_module.addImport("ziglua", ziglua_dep.module("ziglua"));
    exe.root_module.addImport("vaxis", vaxis_dep.module("vaxis"));
    exe.root_module.addImport("zeit", zeit_dep.module("zeit"));

    b.installArtifact(exe);
    b.installFile("docs/comlink.lua", "share/comlink/lua/comlink.lua");
    b.installFile("contrib/comlink.desktop", "share/applications/comlink.desktop");

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_unit_tests.root_module.addImport("vaxis", vaxis_dep.module("vaxis"));
    exe_unit_tests.root_module.addImport("tls", tls_dep.module("tls"));
    exe_unit_tests.root_module.addImport("zeit", zeit_dep.module("zeit"));
    exe_unit_tests.root_module.addImport("ziglua", ziglua_dep.module("ziglua"));

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

fn version(b: *std.Build) ![]const u8 {
    if (!std.process.can_spawn) {
        std.debug.print("error: version info cannot be retrieved from git. Zig version must be provided using -Dversion-string\n", .{});
        std.process.exit(1);
    }
    const version_string = b.fmt("v{d}.{d}.{d}", .{ comlink_version.major, comlink_version.minor, comlink_version.patch });

    var code: u8 = undefined;
    const git_describe_untrimmed = b.runAllowFail(&[_][]const u8{
        "git",
        "-C",
        b.build_root.path orelse ".",
        "describe",
        "--tags",
        "--abbrev=9",
    }, &code, .Ignore) catch {
        return version_string;
    };
    if (!std.mem.startsWith(u8, git_describe_untrimmed, version_string)) {
        std.debug.print("error: tagged version does not match internal version\n", .{});
        std.process.exit(1);
    }
    return std.mem.trim(u8, git_describe_untrimmed, " \n\r");
}

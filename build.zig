const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigzag = b.dependency("zigzag", .{
        .target = target,
        .optimize = optimize,
    });

    const zig_rpc = b.dependency("zig_rpc", .{
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addModule("nexdev_cli", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.addImport("zigzag", zigzag.module("zigzag"));
    lib.addImport("zig_rpc", zig_rpc.module("zig_rpc"));

    const exe = b.addExecutable(.{
        .name = "nexdev_cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("nexdev_cli", lib);
    exe.root_module.addImport("zigzag", zigzag.module("zigzag"));
    exe.root_module.addImport("zig_rpc", zig_rpc.module("zig_rpc"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib_tests = b.addTest(.{
        .root_module = lib,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

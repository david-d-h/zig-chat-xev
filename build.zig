const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libxev = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    }).module("xev");

    const server_exe = b.addExecutable(.{
        .name = "server",
        .root_source_file = b.path("server.zig"),
        .optimize = optimize,
        .target = target,
    });
    server_exe.root_module.addImport("xev", libxev);
    b.installArtifact(server_exe);

    const run_server_exe = b.addRunArtifact(server_exe);
    const run_server_step = b.step("run-server", "Spawn a server instance");
    run_server_step.dependOn(&run_server_exe.step);

    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("server.zig"),
        .target = target,
    });
    unit_tests.root_module.addImport("xev", libxev);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);
}

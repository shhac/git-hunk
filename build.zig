const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version_option = b.option([]const u8, "version", "Version string") orelse "0.7.0";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version_option);

    const exe = b.addExecutable(.{
        .name = "git-hunk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", build_options);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run git-hunk");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const test_step = b.step("test", "Run unit tests");
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_tests.step);

    const integration_step = b.step("test-integration", "Run integration tests (requires git)");
    const bin_path = b.getInstallPath(.bin, "git-hunk");
    const run_integration = b.addSystemCommand(&.{ "bash", "tests/run-all.sh", bin_path });
    run_integration.step.dependOn(b.getInstallStep());
    integration_step.dependOn(&run_integration.step);
}

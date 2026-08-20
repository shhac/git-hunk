const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version_option = b.option([]const u8, "version", "Version string") orelse zon.version;
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

    const fuzz_exe = b.addExecutable(.{
        .name = "fuzz-driver",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz_driver.zig"),
            .target = target,
            // Safety checks on, but fast enough for millions of iterations.
            .optimize = .ReleaseSafe,
        }),
    });
    const fuzz_step = b.step("fuzz", "Brute-force fuzz the diff parser (args: iterations seed)");
    const run_fuzz = b.addRunArtifact(fuzz_exe);
    if (b.args) |args| run_fuzz.addArgs(args);
    fuzz_step.dependOn(&run_fuzz.step);
    // Install alongside the run so parallel campaigns can invoke zig-out/bin/fuzz-driver directly.
    fuzz_step.dependOn(&b.addInstallArtifact(fuzz_exe, .{}).step);

    const gen_docs = b.addExecutable(.{
        .name = "gen-docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_docs.zig"),
            .target = b.resolveTargetQuery(.{}),
            .optimize = .Debug,
        }),
    });
    gen_docs.root_module.addImport("spec", b.createModule(.{
        .root_source_file = b.path("src/spec.zig"),
        .target = b.resolveTargetQuery(.{}),
        .optimize = .Debug,
    }));
    const docs_step = b.step("docs", "Regenerate man page sections and check doc/completion drift (-- --check for CI)");
    const run_docs = b.addRunArtifact(gen_docs);
    run_docs.addArg(b.build_root.path orelse ".");
    run_docs.addArg(version_option);
    if (b.args) |args| run_docs.addArgs(args);
    // Doc targets change out-of-band; never cache this run.
    run_docs.has_side_effects = true;
    docs_step.dependOn(&run_docs.step);

    const integration_step = b.step("test-integration", "Run integration tests (requires git)");
    const bin_path = b.getInstallPath(.bin, "git-hunk");
    const run_integration = b.addSystemCommand(&.{ "bash", "tests/run-all.sh", bin_path });
    run_integration.step.dependOn(b.getInstallStep());
    integration_step.dependOn(&run_integration.step);
}

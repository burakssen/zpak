const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zpak_mod = b.addModule("zpak", .{
        .root_source_file = b.path("src/zpak/zpak.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lz4_dep = b.dependency("lz4", .{
        .target = target,
        .optimize = optimize,
    });

    zpak_mod.linkLibrary(lz4_dep.artifact("lz4"));
    zpak_mod.linkSystemLibrary("zstd", .{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("zpak", zpak_mod);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zpak",
        .root_module = zpak_mod,
    });

    b.installArtifact(lib);

    const exe = b.addExecutable(.{
        .name = "zpak",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "../docs",
    });

    const docs_step = b.step("docs", "Install docs into zig-out/docs");
    docs_step.dependOn(&install_docs.step);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const zpak_unit_tests = b.addTest(.{
        .root_module = zpak_mod,
    });

    const run_zpak_unit_tests = b.addRunArtifact(zpak_unit_tests);

    const exe_unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_zpak_unit_tests.step);
    test_step.dependOn(&run_exe_unit_tests.step);
}

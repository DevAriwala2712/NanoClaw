const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const app_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .single_threaded = false,
        .strip = optimize != .Debug,
    });

    const exe = b.addExecutable(.{
        .name = "nanoclaw-next",
        .root_module = app_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run NanoClaw-Next");
    run_step.dependOn(&run_cmd.step);

    const rel_optimize: std.builtin.OptimizeMode = .ReleaseSmall;

    const release_x86_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .x86_64,
            .os_tag = .linux,
            .abi = .musl,
        }),
        .optimize = rel_optimize,
        .single_threaded = false,
        .strip = true,
    });

    const release_x86 = b.addExecutable(.{
        .name = "nanoclaw-next-x86_64",
        .root_module = release_x86_module,
    });
    b.installArtifact(release_x86);

    const release_pi_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .aarch64,
            .os_tag = .linux,
            .abi = .musl,
        }),
        .optimize = rel_optimize,
        .single_threaded = false,
        .strip = true,
    });

    const release_pi = b.addExecutable(.{
        .name = "nanoclaw-next-aarch64",
        .root_module = release_pi_module,
    });
    b.installArtifact(release_pi);

    const release_x86_step = b.step("release-x86", "Build static release binary for x86_64-linux-musl");
    release_x86_step.dependOn(&release_x86.step);

    const release_pi_step = b.step("release-pi", "Build static release binary for aarch64-linux-musl (Pi 5)");
    release_pi_step.dependOn(&release_pi.step);
}

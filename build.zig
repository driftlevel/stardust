const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const main_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "stardust",
        .root_module = main_mod,
    });

    const run_cmd = b.addRunArtifact(exe);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const dev_exe = b.addExecutable(.{
        .name = "stardust",
        .root_module = main_mod,
    });
    const dev_step = b.step("dev", "Development with debug optimizations");
    dev_step.dependOn(&b.addRunArtifact(dev_exe).step);
}

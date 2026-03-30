const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Resolve the yaml dependency once; all modules share it
    const yaml = b.dependency("yaml", .{
        .target = target,
        .optimize = optimize,
    });
    const yaml_mod = yaml.module("yaml");

    // Resolve the vaxis dependency (SSH admin TUI)
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    const vaxis_mod = vaxis_dep.module("vaxis");

    // Optional: path to a directory containing libssh.a (and its static deps)
    // for cross-compilation targets where pkg-config cannot find the right library.
    // Example: -Dlibssh_lib_dir=./libssh-sysroot/aarch64
    // When omitted, falls back to pkg-config / system library paths.
    const libssh_lib_dir = b.option(
        []const u8,
        "libssh_lib_dir",
        "Directory containing libssh.a for cross-compilation (bypasses pkg-config)",
    );

    const main_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("yaml", yaml_mod);
    main_mod.addImport("vaxis", vaxis_mod);

    // Run step
    const exe = b.addExecutable(.{
        .name = "stardust",
        .root_module = main_mod,
    });
    // Prefer static libssh for the production binary (scratch Docker image has no .so).
    // Falls back to dynamic if libssh.a is not found on the host.
    // On Arch: no libssh.a by default — build from source or use AUR.
    // On Alpine: apk add libssh-static provides libssh.a (used in CI).
    // On Ubuntu/Debian: libssh-dev includes libssh.a.
    linkLibssh(exe, libssh_lib_dir);
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Dev step (debug optimizations)
    const dev_mod = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = .Debug,
    });
    dev_mod.addImport("yaml", yaml_mod);
    dev_mod.addImport("vaxis", vaxis_mod);
    const dev_exe = b.addExecutable(.{
        .name = "stardust-dev",
        .root_module = dev_mod,
    });
    linkLibssh(dev_exe, libssh_lib_dir);
    const dev_step = b.step("dev", "Run with debug optimizations");
    dev_step.dependOn(&b.addRunArtifact(dev_exe).step);

    // Test step
    const unit_tests = b.addTest(.{
        .root_module = main_mod,
    });
    linkLibssh(unit_tests, libssh_lib_dir);
    if (b.option([]const u8, "test_filter", "Filter tests by name")) |f| {
        // Allocate on the build arena so the slice outlives the build() function frame.
        const filter_slice = b.allocator.dupe([]const u8, &.{f}) catch @panic("OOM");
        unit_tests.filters = filter_slice;
    }
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // Check step (type-check without emitting a binary)
    const check_exe = b.addExecutable(.{
        .name = "check",
        .root_module = main_mod,
    });
    linkLibssh(check_exe, libssh_lib_dir);
    const check_step = b.step("check", "Type-check the codebase");
    check_step.dependOn(&check_exe.step);
}

/// Link libssh and its static dependencies.
///
/// When `lib_dir` is provided (cross-compilation path), we add an explicit
/// library search path and bypass pkg-config — pkg-config on the build host
/// can only find the host-arch glibc-linked library, which is wrong for musl
/// cross-compilation targets.  The directory must contain libssh.a and the
/// transitive static deps (libssl.a, libcrypto.a, libz.a) extracted from
/// Alpine's libssh-static package for the target architecture.
///
/// When `lib_dir` is null, pkg-config discovers everything automatically,
/// which is correct for native builds (dev workstation, CI test runner).
fn linkLibssh(step: *std.Build.Step.Compile, lib_dir: ?[]const u8) void {
    if (lib_dir) |d| {
        step.addLibraryPath(.{ .cwd_relative = d });
        // Bypass pkg-config; explicitly name libssh and its static deps.
        // Alpine's libssh-static links against OpenSSL and zlib.
        inline for (.{ "ssh", "ssl", "crypto", "z" }) |lib| {
            step.linkSystemLibrary2(lib, .{
                .preferred_link_mode = .static,
                .use_pkg_config = .no,
            });
        }
    } else {
        step.linkSystemLibrary2("ssh", .{ .preferred_link_mode = .static });
    }
    step.linkLibC();
}

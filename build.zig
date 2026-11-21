const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "shotlet",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // libc is needed only for dlopen(libpipewire); everything else
            // talks wire protocols directly
            .link_libc = true,
        }),
    });
    addGnomeExtension(b, exe.root_module);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run shotlet");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    addGnomeExtension(b, tests.root_module);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    // end-to-end suite: shotlet driven by a virtual keyboard and pointer in
    // a private headless GNOME session (tools/e2e.sh skips without one)
    const drive = b.addExecutable(.{
        .name = "shotlet-drive",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/e2e/drive.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "shotlet", .module = b.createModule(.{
                .root_source_file = b.path("src/testkit.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }) }},
        }),
    });
    const droptarget = b.addExecutable(.{
        .name = "shotlet-droptarget",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/e2e/droptarget.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "shotlet", .module = b.createModule(.{
                .root_source_file = b.path("src/testkit.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }) }},
        }),
    });
    // compiled with the tests so they cannot rot unnoticed
    test_step.dependOn(&drive.step);
    test_step.dependOn(&droptarget.step);
    const run_e2e = b.addSystemCommand(&.{"tools/e2e.sh"});
    run_e2e.addArtifactArg(exe);
    run_e2e.addArtifactArg(drive);
    run_e2e.step.dependOn(&b.addInstallArtifact(droptarget, .{}).step);
    run_e2e.addPassthruArgs();
    run_e2e.has_side_effects = true;
    const e2e_step = b.step("e2e", "Run the end-to-end suite (private headless GNOME session)");
    e2e_step.dependOn(&run_e2e.step);
    const drive_step = b.step("e2e-driver", "Install the e2e input driver (zig-out/bin/shotlet-drive)");
    drive_step.dependOn(&b.addInstallArtifact(drive, .{}).step);
    drive_step.dependOn(&b.addInstallArtifact(droptarget, .{}).step);
}

/// The GNOME Shell extension ships inside the binary, for
/// `shotlet gnome-integration install`.
fn addGnomeExtension(b: *std.Build, m: *std.Build.Module) void {
    const dir = "gnome-extension/shotlet@midnattsol.github.io/";
    m.addAnonymousImport("gnome_ext_js", .{ .root_source_file = b.path(dir ++ "extension.js") });
    m.addAnonymousImport("gnome_ext_metadata", .{ .root_source_file = b.path(dir ++ "metadata.json") });
}

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
    const options = b.addOptions();
    options.addOption([]const u8, "version", @import("build.zig.zon").version);
    exe.root_module.addOptions("build_options", options);
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
    tests.root_module.addOptions("build_options", options);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
    addSizeChecks(b, test_step);

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
    // the container suite's input driver (wlroots and KWin)
    const wldrive = b.addExecutable(.{
        .name = "shotlet-wldrive",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/container/wldrive.zig"),
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
    test_step.dependOn(&wldrive.step);
    const run_e2e = b.addSystemCommand(&.{"tools/e2e.sh"});
    run_e2e.addArtifactArg(exe);
    run_e2e.addArtifactArg(drive);
    run_e2e.addArtifactArg(droptarget);
    run_e2e.addPassthruArgs();
    run_e2e.has_side_effects = true;
    const e2e_step = b.step("e2e", "Run the end-to-end suite (private headless GNOME session)");
    e2e_step.dependOn(&run_e2e.step);
    // the same kind of suite on wlroots (sway, labwc) and KWin, each in a
    // throwaway container (tools/container/run.sh skips without docker or
    // podman)
    const run_ctr = b.addSystemCommand(&.{"tools/container/run.sh"});
    run_ctr.addArg("--bins");
    run_ctr.addArtifactArg(exe);
    run_ctr.addArtifactArg(wldrive);
    run_ctr.addArtifactArg(droptarget);
    run_ctr.addPassthruArgs();
    run_ctr.has_side_effects = true;
    const ctr_step = b.step("e2e-container", "Run the end-to-end suite on sway, labwc and KWin in containers");
    ctr_step.dependOn(&run_ctr.step);
    const drive_step = b.step("e2e-driver", "Install the e2e input driver (zig-out/bin/shotlet-drive)");
    drive_step.dependOn(&b.addInstallArtifact(drive, .{}).step);
    drive_step.dependOn(&b.addInstallArtifact(droptarget, .{}).step);
    drive_step.dependOn(&b.addInstallArtifact(wldrive, .{}).step);
}

/// The GNOME Shell extension ships inside the binary, for
/// `shotlet gnome-integration install`.
fn addGnomeExtension(b: *std.Build, m: *std.Build.Module) void {
    const dir = "gnome-extension/shotlet@midnattsol.github.io/";
    m.addAnonymousImport("gnome_ext_js", .{ .root_source_file = b.path(dir ++ "extension.js") });
    m.addAnonymousImport("gnome_ext_recorder_js", .{ .root_source_file = b.path(dir ++ "recorder.js") });
    m.addAnonymousImport("gnome_ext_windows_js", .{ .root_source_file = b.path(dir ++ "windows.js") });
    m.addAnonymousImport("gnome_ext_metadata", .{ .root_source_file = b.path(dir ++ "metadata.json") });
    // the capture modes' modules (imported by extension.js)
    for ([_][]const u8{ "modes", "windowpick", "scroll", "util" }) |name| {
        m.addAnonymousImport(b.fmt("gnome_ext_{s}_js", .{name}), .{ .root_source_file = b.path(b.fmt("{s}{s}.js", .{ dir, name })) });
    }
    m.addAnonymousImport("gnome_ext_schema", .{ .root_source_file = b.path(dir ++ "schemas/org.gnome.shell.extensions.shotlet.gschema.xml") });
    // compiled with glib-compile-schemas and committed: the extension
    // directory is copied as is (GNOME Shell does not compile schemas)
    m.addAnonymousImport("gnome_ext_schema_compiled", .{ .root_source_file = b.path(dir ++ "schemas/gschemas.compiled") });
}

/// `check-size` fails when a source file outgrows the line limit (files
/// still over it are allowlisted in tools/size-allowlist.txt and may only
/// shrink); `test` runs it too. `long-fns` lists overlong functions.
fn addSizeChecks(b: *std.Build, test_step: *std.Build.Step) void {
    const check = b.addSystemCommand(&.{ "sh", "tools/check-size.sh" });
    check.setName("check-size.sh");
    check.setCwd(b.path("."));
    check.has_side_effects = true;
    b.step("check-size", "Fail when a source file grows past 600 lines").dependOn(&check.step);
    test_step.dependOn(&check.step);

    const fns = b.addSystemCommand(&.{ "sh", "tools/long-fns.sh" });
    fns.setName("long-fns.sh");
    fns.setCwd(b.path("."));
    fns.addPassthruArgs();
    fns.has_side_effects = true;
    b.step("long-fns", "List functions longer than 80 lines (a report, never fails)").dependOn(&fns.step);
}

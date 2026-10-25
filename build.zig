const std = @import("std");
fn linkGtk(step: *std.Build.Step.Compile) void {
    step.linkLibC();
    step.linkSystemLibrary("gtk+-3.0");
    step.linkSystemLibrary("json-glib-1.0");
}
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const panel = b.addSharedLibrary(.{ .name = "waybar-gnome", .root_source_file = b.path("waybar-gnome.zig"), .target = target, .optimize = optimize });
    linkGtk(panel);
    b.installArtifact(panel);
    const apps = b.addExecutable(.{ .name = "desktop-apps", .root_source_file = b.path("desktop-apps.zig"), .target = target, .optimize = optimize });
    apps.linkLibC();
    apps.linkSystemLibrary("gtk+-3.0");
    apps.linkSystemLibrary("gio-unix-2.0");
    b.installArtifact(apps);
    const apps_fixture = b.addExecutable(.{ .name = "desktop-apps-fixture", .root_source_file = b.path("tests/desktop-apps-fixture.zig"), .target = target, .optimize = optimize });
    const apps_module = b.createModule(.{ .root_source_file = b.path("desktop-apps.zig"), .target = target, .optimize = optimize });
    apps_module.link_libc = true;
    apps_module.linkSystemLibrary("gtk+-3.0", .{});
    apps_module.linkSystemLibrary("gio-unix-2.0", .{});
    apps_fixture.root_module.addImport("apps", apps_module);
    b.installArtifact(apps_fixture);
    for ([_][]const u8{ "waybar-codex", "waybar-panel" }) |name| {
        const exe = b.addExecutable(.{ .name = name, .root_source_file = b.path(b.fmt("{s}.zig", .{name})), .target = target, .optimize = optimize });
        exe.linkLibC();
        exe.linkSystemLibrary("libcurl");
        b.installArtifact(exe);
    }
    const gtk_fixture = b.addExecutable(.{ .name = "waybar-power-fixture", .root_source_file = b.path("tests/waybar-power-fixture.zig"), .target = target, .optimize = optimize });
    linkGtk(gtk_fixture);
    const module = b.createModule(.{ .root_source_file = b.path("waybar-gnome.zig"), .target = target, .optimize = optimize });
    module.linkSystemLibrary("gtk+-3.0", .{});
    module.linkSystemLibrary("json-glib-1.0", .{});
    module.link_libc = true;
    gtk_fixture.root_module.addImport("panel", module);
    b.installArtifact(gtk_fixture);
    const switcher = b.addExecutable(.{ .name = "labwc-switcher-fixture", .root_source_file = b.path("tests/labwc-switcher-fixture.zig"), .target = target, .optimize = optimize });
    linkGtk(switcher);
    switcher.linkSystemLibrary("wayland-client");
    b.installArtifact(switcher);
    const checker = b.addExecutable(.{ .name = "check-labwc-switcher", .root_source_file = b.path("check-labwc-switcher.zig"), .target = target, .optimize = optimize });
    checker.linkLibC();
    b.installArtifact(checker);
    const tests = b.addTest(.{ .root_source_file = b.path("desktop-tests.zig"), .target = target, .optimize = optimize });
    tests.linkLibC();
    tests.linkSystemLibrary("libcurl");
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run data parsing and allowance tests");
    test_step.dependOn(&run_tests.step);
}

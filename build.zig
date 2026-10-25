const std = @import("std");
fn bindings(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, headers: []const u8, libraries: []const []const u8) *std.Build.Module {
    const header = b.addWriteFiles().add("bindings.h", headers);
    const translated = b.addTranslateC(.{ .root_source_file = header, .target = target, .optimize = optimize });
    for (libraries) |name| translated.linkSystemLibrary(name, .{});
    return translated.createModule();
}
fn linkGtk(step: *std.Build.Step.Compile) void {
    step.root_module.link_libc = true;
    step.root_module.linkSystemLibrary("gtk+-3.0", .{});
    step.root_module.linkSystemLibrary("json-glib-1.0", .{});
}
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const gtk = bindings(b, target, optimize, "#include <gtk/gtk.h>\n#include <json-glib/json-glib.h>\n#include <math.h>\n#include <signal.h>\n#include <string.h>\n", &.{ "gtk+-3.0", "json-glib-1.0" });
    const apps_gtk = bindings(b, target, optimize, "#include <gtk/gtk.h>\n#include <gio/gdesktopappinfo.h>\n", &.{ "gtk+-3.0", "gio-unix-2.0" });
    const wayland_gtk = bindings(b, target, optimize, "#include <gtk/gtk.h>\n#include <gdk/gdkwayland.h>\n", &.{ "gtk+-3.0", "wayland-client" });
    const libc = bindings(b, target, optimize, "#define _GNU_SOURCE\n#include <time.h>\n#include <unistd.h>\n#include <poll.h>\n#include <stdio.h>\n#include <errno.h>\n#include <stdlib.h>\n#include <fcntl.h>\n#include <sys/wait.h>\n", &.{});
    const curl = bindings(b, target, optimize, "#include <curl/curl.h>\n", &.{"libcurl"});
    const panel_gtk = bindings(b, target, optimize, "#include <gtk/gtk.h>\n#include <json-glib/json-glib.h>\n#include <gtk-layer-shell.h>\n#include <glib-unix.h>\n#include <math.h>\n#include <signal.h>\n#include <string.h>\n", &.{ "gtk+-3.0", "json-glib-1.0", "gtk-layer-shell-0" });
    const panel = b.addExecutable(.{ .name = "desktop-panel", .root_module = b.createModule(.{ .root_source_file = b.path("desktop-panel.zig"), .target = target, .optimize = optimize }) });
    linkGtk(panel);
    panel.root_module.linkSystemLibrary("gtk-layer-shell-0", .{});
    panel.root_module.addImport("gtk", panel_gtk);
    b.installArtifact(panel);
    const osd = b.addExecutable(.{ .name = "desktop-osd", .root_module = b.createModule(.{ .root_source_file = b.path("desktop-osd.zig"), .target = target, .optimize = optimize }) });
    osd.root_module.link_libc = true;
    osd.root_module.linkSystemLibrary("gtk+-3.0", .{});
    osd.root_module.linkSystemLibrary("gtk-layer-shell-0", .{});
    osd.root_module.addImport("gtk", panel_gtk);
    b.installArtifact(osd);
    const osd_tests = b.addTest(.{ .root_module = osd.root_module });
    const apps = b.addExecutable(.{ .name = "desktop-apps", .root_module = b.createModule(.{ .root_source_file = b.path("desktop-apps.zig"), .target = target, .optimize = optimize }) });
    apps.root_module.link_libc = true;
    apps.root_module.linkSystemLibrary("gtk+-3.0", .{});
    apps.root_module.linkSystemLibrary("gio-unix-2.0", .{});
    apps.root_module.addImport("gtk", apps_gtk);
    b.installArtifact(apps);
    const apps_fixture = b.addExecutable(.{ .name = "desktop-apps-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-apps-fixture.zig"), .target = target, .optimize = optimize }) });
    const apps_module = b.createModule(.{ .root_source_file = b.path("desktop-apps.zig"), .target = target, .optimize = optimize });
    apps_module.link_libc = true;
    apps_module.linkSystemLibrary("gtk+-3.0", .{});
    apps_module.linkSystemLibrary("gio-unix-2.0", .{});
    apps_module.addImport("gtk", apps_gtk);
    apps_fixture.root_module.addImport("apps", apps_module);
    b.installArtifact(apps_fixture);
    for ([_][]const u8{ "waybar-codex", "waybar-panel" }) |name| {
        const exe = b.addExecutable(.{ .name = name, .root_module = b.createModule(.{ .root_source_file = b.path(b.fmt("{s}.zig", .{name})), .target = target, .optimize = optimize }) });
        exe.root_module.link_libc = true;
        exe.root_module.linkSystemLibrary("libcurl", .{});
        exe.root_module.addImport("libc", libc);
        exe.root_module.addImport("curl", curl);
        b.installArtifact(exe);
    }
    const gtk_fixture = b.addExecutable(.{ .name = "waybar-power-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/waybar-power-fixture.zig"), .target = target, .optimize = optimize }) });
    linkGtk(gtk_fixture);
    const module = b.createModule(.{ .root_source_file = b.path("desktop-widgets.zig"), .target = target, .optimize = optimize });
    module.linkSystemLibrary("gtk+-3.0", .{});
    module.linkSystemLibrary("json-glib-1.0", .{});
    module.link_libc = true;
    module.addImport("gtk", gtk);
    gtk_fixture.root_module.addImport("panel", module);
    b.installArtifact(gtk_fixture);
    const switcher = b.addExecutable(.{ .name = "labwc-switcher-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/labwc-switcher-fixture.zig"), .target = target, .optimize = optimize }) });
    linkGtk(switcher);
    switcher.root_module.linkSystemLibrary("wayland-client", .{});
    switcher.root_module.addImport("gtk", wayland_gtk);
    b.installArtifact(switcher);
    const checker = b.addExecutable(.{ .name = "check-labwc-switcher", .root_module = b.createModule(.{ .root_source_file = b.path("check-labwc-switcher.zig"), .target = target, .optimize = optimize }) });
    checker.root_module.link_libc = true;
    checker.root_module.addImport("libc", libc);
    b.installArtifact(checker);
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("desktop-tests.zig"), .target = target, .optimize = optimize }) });
    tests.root_module.link_libc = true;
    tests.root_module.linkSystemLibrary("libcurl", .{});
    tests.root_module.addImport("libc", libc);
    tests.root_module.addImport("curl", curl);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run data parsing and allowance tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&b.addRunArtifact(osd_tests).step);
}

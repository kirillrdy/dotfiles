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
}
pub fn build(b: *std.Build) void {
    b.installDirectory(.{ .source_dir = b.path("desktop-icons"), .install_dir = .prefix, .install_subdir = "share/icons/hicolor/scalable/status" });
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const libc = b.createModule(.{ .root_source_file = b.path("desktop-libc.zig"), .target = target, .optimize = optimize });
    const power_c = libc;
    const power_module = b.createModule(.{ .root_source_file = b.path("desktop-power.zig"), .target = target, .optimize = optimize });
    power_module.link_libc = true;
    power_module.addImport("libc", power_c);
    const power = b.addExecutable(.{ .name = "desktop-power", .root_module = power_module });
    b.step("power", "Build the on-demand power profile helper").dependOn(&b.addInstallArtifact(power, .{}).step);
    const power_fixture = b.addExecutable(.{ .name = "desktop-power-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-power-fixture.zig"), .target = target, .optimize = optimize }) });
    power_fixture.root_module.addImport("power", power_module);
    power_fixture.root_module.addImport("libc", power_c);
    b.step("test-power", "Check power profiles against isolated sysfs fixtures").dependOn(&b.addRunArtifact(power_fixture).step);
    const greeter_c = libc;
    const gtk = b.createModule(.{ .root_source_file = b.path("desktop-gtk.zig"), .target = target, .optimize = optimize });
    const protocols = b.createModule(.{ .root_source_file = b.path("desktop-protocols.zig"), .target = target, .optimize = optimize });
    protocols.addImport("gtk", gtk);
    var protocol_references: [7]std.Build.LazyPath = undefined;
    const libc_reference = bindings(b, target, optimize, "#define _GNU_SOURCE\n#include <unistd.h>\n#include <stdlib.h>\n#include <signal.h>\n#include <termios.h>\n#include <poll.h>\n#include <errno.h>\n#include <fcntl.h>\n#include <time.h>\n#include <stdio.h>\n#include <sys/socket.h>\n#include <sys/un.h>\n#include <sys/prctl.h>\n#include <sys/wait.h>\n#include <dirent.h>\n#include <sys/file.h>\n#include <sys/mman.h>\n#include <pwd.h>\n", &.{});
    const libc_abi = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-libc-abi.zig"), .target = target, .optimize = optimize }) });
    libc_abi.root_module.addImport("api", libc);
    libc_abi.root_module.addImport("reference", libc_reference);
    libc_abi.root_module.link_libc = true;
    b.step("test-libc-abi", "Verify POSIX declarations and constants against system headers").dependOn(&b.addRunArtifact(libc_abi).step);
    const greeter_module = b.createModule(.{ .root_source_file = b.path("desktop-greeter.zig"), .target = target, .optimize = optimize });
    greeter_module.link_libc = true;
    greeter_module.addImport("libc", greeter_c);
    const greeter = b.addExecutable(.{ .name = "desktop-greeter", .root_module = greeter_module });
    b.step("greeter", "Build the terminal greetd login screen").dependOn(&b.addInstallArtifact(greeter, .{}).step);
    const apps_gtk = gtk;
    const wayland_gtk = gtk;
    const panel_gtk = gtk;
    const panel = b.addExecutable(.{ .name = "desktop-panel", .root_module = b.createModule(.{ .root_source_file = b.path("desktop-panel.zig"), .target = target, .optimize = optimize }) });
    linkGtk(panel);
    panel.root_module.linkSystemLibrary("gtk-layer-shell-0", .{});
    panel.root_module.addImport("gtk", panel_gtk);
    panel.root_module.addImport("power", power_module);
    const settings_module = b.createModule(.{ .root_source_file = b.path("desktop-settings.zig"), .target = target, .optimize = optimize });
    settings_module.link_libc = true;
    settings_module.linkSystemLibrary("gtk+-3.0", .{});
    settings_module.addImport("gtk", gtk);
    const settings_tests = b.addTest(.{ .root_module = settings_module });
    const settings_fixture = b.addExecutable(.{ .name = "desktop-settings-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-settings-fixture.zig"), .target = target, .optimize = optimize }) });
    settings_fixture.root_module.addImport("settings", settings_module);
    const settings_check = b.step("test-settings", "Exercise settings against isolated sound and network backends (requires a display)");
    settings_check.dependOn(&b.addRunArtifact(settings_fixture).step);
    const askpass_gtk = gtk;
    const askpass_module = b.createModule(.{ .root_source_file = b.path("desktop-askpass.zig"), .target = target, .optimize = optimize });
    askpass_module.link_libc = true;
    askpass_module.linkSystemLibrary("gtk+-3.0", .{});
    askpass_module.addImport("gtk", askpass_gtk);
    askpass_module.addImport("libc", libc);
    const askpass = b.addExecutable(.{ .name = "desktop-askpass", .root_module = askpass_module });
    const askpass_fixture = b.addExecutable(.{ .name = "desktop-askpass-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-askpass-fixture.zig"), .target = target, .optimize = optimize }) });
    askpass_fixture.root_module.addImport("askpass", askpass_module);
    askpass_fixture.root_module.addImport("libc", libc);
    const run_askpass_fixture = b.addRunArtifact(askpass_fixture);
    run_askpass_fixture.addArtifactArg(askpass);
    b.step("test-askpass", "Check the SSH askpass dialog and protocol (requires a display)").dependOn(&run_askpass_fixture.step);
    const polkit_gtk = gtk;
    const polkit_module = b.createModule(.{ .root_source_file = b.path("desktop-polkit.zig"), .target = target, .optimize = optimize });
    polkit_module.link_libc = true;
    polkit_module.linkSystemLibrary("gtk+-3.0", .{});
    polkit_module.linkSystemLibrary("polkit-agent-1", .{});
    polkit_module.linkSystemLibrary("polkit-gobject-1", .{});
    polkit_module.addImport("gtk", polkit_gtk);
    polkit_module.addImport("libc", libc);
    const polkit_exe = b.addExecutable(.{ .name = "desktop-polkit", .root_module = polkit_module });
    const polkit_fixture = b.addExecutable(.{ .name = "desktop-polkit-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-polkit-fixture.zig"), .target = target, .optimize = optimize }) });
    polkit_fixture.root_module.addImport("polkit", polkit_module);
    const run_polkit_fixture = b.addRunArtifact(polkit_fixture);
    run_polkit_fixture.addArtifactArg(polkit_exe);
    b.step("test-polkit", "Check the PolicyKit authentication agent dialog and interactions (requires a display)").dependOn(&run_polkit_fixture.step);
    const wlr_protocols = b.graph.environ_map.get("WLR_PROTOCOLS_DIR") orelse "/usr/share/wlr-protocols";
    const sc_xml: std.Build.LazyPath = .{ .cwd_relative = b.fmt("{s}/unstable/wlr-screencopy-unstable-v1.xml", .{wlr_protocols}) };
    const sc_code_cmd = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    sc_code_cmd.addFileArg(sc_xml);
    const sc_code = sc_code_cmd.addOutputFileArg("wlr-screencopy-unstable-v1.c");
    const dc_xml: std.Build.LazyPath = .{ .cwd_relative = b.fmt("{s}/unstable/wlr-data-control-unstable-v1.xml", .{wlr_protocols}) };
    const dc_code_cmd = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    dc_code_cmd.addFileArg(dc_xml);
    const dc_code = dc_code_cmd.addOutputFileArg("wlr-data-control-unstable-v1.c");
    const sc_gtk = gtk;
    const sc_module = b.createModule(.{ .root_source_file = b.path("desktop-screenshot.zig"), .target = target, .optimize = optimize });
    sc_module.link_libc = true;
    sc_module.linkSystemLibrary("gtk+-3.0", .{});
    sc_module.linkSystemLibrary("gtk-layer-shell-0", .{});
    sc_module.linkSystemLibrary("wayland-client", .{});
    sc_module.linkSystemLibrary("cairo", .{});
    sc_module.addImport("protocols", protocols);
    protocol_references[0] = sc_code;
    protocol_references[1] = dc_code;
    sc_module.addImport("gtk", sc_gtk);
    sc_module.addImport("libc", libc);
    const sc_exe = b.addExecutable(.{ .name = "desktop-screenshot", .root_module = sc_module });
    const sc_fixture = b.addExecutable(.{ .name = "desktop-screenshot-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-screenshot-fixture.zig"), .target = target, .optimize = optimize }) });
    sc_fixture.root_module.addImport("screenshot", sc_module);
    const run_sc_fixture = b.addRunArtifact(sc_fixture);
    run_sc_fixture.addArtifactArg(sc_exe);
    b.step("test-screenshot", "Check screenshot CLI parsing, buffers, PNG encoding and overlay (requires a display)").dependOn(&run_sc_fixture.step);
    const wallpaper = b.addExecutable(.{ .name = "desktop-wallpaper", .root_module = b.createModule(.{ .root_source_file = b.path("desktop-wallpaper.zig"), .target = target, .optimize = optimize }) });
    wallpaper.root_module.link_libc = true;
    wallpaper.root_module.linkSystemLibrary("gtk+-3.0", .{});
    wallpaper.root_module.linkSystemLibrary("gtk-layer-shell-0", .{});
    wallpaper.root_module.addImport("gtk", panel_gtk);
    const wallpaper_tests = b.addTest(.{ .root_module = wallpaper.root_module });
    const osd = b.addExecutable(.{ .name = "desktop-osd", .root_module = b.createModule(.{ .root_source_file = b.path("desktop-osd.zig"), .target = target, .optimize = optimize }) });
    osd.root_module.link_libc = true;
    osd.root_module.linkSystemLibrary("gtk+-3.0", .{});
    osd.root_module.linkSystemLibrary("gtk-layer-shell-0", .{});
    osd.root_module.addImport("gtk", panel_gtk);
    const osd_tests = b.addTest(.{ .root_module = osd.root_module });
    const notifications = b.addExecutable(.{ .name = "desktop-notifications", .root_module = b.createModule(.{ .root_source_file = b.path("desktop-notifications.zig"), .target = target, .optimize = optimize }) });
    linkGtk(notifications);
    notifications.root_module.linkSystemLibrary("gtk-layer-shell-0", .{});
    notifications.root_module.addImport("gtk", panel_gtk);
    const apps = b.addExecutable(.{ .name = "desktop-apps", .root_module = b.createModule(.{ .root_source_file = b.path("desktop-apps.zig"), .target = target, .optimize = optimize }) });
    apps.root_module.link_libc = true;
    apps.root_module.linkSystemLibrary("gtk+-3.0", .{});
    apps.root_module.linkSystemLibrary("gio-unix-2.0", .{});
    apps.root_module.addImport("gtk", apps_gtk);
    const overview = b.addExecutable(.{ .name = "desktop-overview", .root_module = b.createModule(.{ .root_source_file = b.path("desktop-overview.zig"), .target = target, .optimize = optimize }) });
    overview.root_module.link_libc = true;
    overview.root_module.linkSystemLibrary("gtk+-3.0", .{});
    overview.root_module.linkSystemLibrary("gio-unix-2.0", .{});
    overview.root_module.linkSystemLibrary("gtk-layer-shell-0", .{});
    overview.root_module.linkSystemLibrary("wayland-client", .{});
    const session = b.addExecutable(.{ .name = "desktop-zig", .root_module = b.createModule(.{ .root_source_file = b.path("desktop-zig.zig"), .target = target, .optimize = optimize }) });
    const overview_header = b.addWriteFiles().add("overview-bindings.h", "#define _GNU_SOURCE\n#include <gtk/gtk.h>\n#include <gio/gdesktopappinfo.h>\n#include <gtk-layer-shell.h>\n#include <glib-unix.h>\n#include <signal.h>\n#include <wayland-client.h>\n#include <gdk/gdkwayland.h>\n#define POLKIT_AGENT_I_KNOW_API_IS_SUBJECT_TO_CHANGE 1\n#include <polkit/polkit.h>\n#include <polkitagent/polkitagent.h>\n");
    const overview_c = b.addTranslateC(.{ .root_source_file = overview_header, .target = target, .optimize = optimize });
    for ([_][]const u8{ "gtk+-3.0", "gio-unix-2.0", "gtk-layer-shell-0", "wayland-client", "polkit-agent-1", "polkit-gobject-1" }) |name| overview_c.linkSystemLibrary(name, .{});
    const protocol_dir = b.graph.environ_map.get("WAYLAND_PROTOCOLS_DIR") orelse "/usr/share/wayland-protocols";
    for ([_][]const u8{ "ext-foreign-toplevel-list", "ext-image-capture-source", "ext-image-copy-capture", "desktop-overview" }, 0..) |name, protocol_index| {
        const xml: std.Build.LazyPath = if (std.mem.eql(u8, name, "desktop-overview")) b.path("desktop-overview-v1.xml") else .{ .cwd_relative = b.fmt("{s}/staging/{s}/{s}-v1.xml", .{ protocol_dir, name, name }) };
        const code_command = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        code_command.addFileArg(xml);
        const code = code_command.addOutputFileArg(b.fmt("{s}-v1.c", .{name}));
        protocol_references[protocol_index + 2] = code;
    }
    const overview_gtk = gtk;
    const abi_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-gtk-abi.zig"), .target = target, .optimize = optimize }) });
    abi_tests.root_module.addImport("api", gtk);
    abi_tests.root_module.addImport("reference", overview_c.createModule());
    abi_tests.root_module.link_libc = true;
    b.step("test-gtk-abi", "Verify explicit toolkit declarations against the installed C headers").dependOn(&b.addRunArtifact(abi_tests).step);
    const overview_apps = b.createModule(.{ .root_source_file = b.path("desktop-apps.zig"), .target = target, .optimize = optimize });
    overview_apps.addImport("gtk", overview_gtk);
    overview.root_module.addImport("gtk", overview_gtk);
    overview.root_module.addImport("apps", overview_apps);
    overview.root_module.addImport("libc", libc);
    session.root_module.link_libc = true;
    for ([_][]const u8{ "gtk+-3.0", "gio-unix-2.0", "gtk-layer-shell-0", "wayland-client", "polkit-agent-1", "polkit-gobject-1" }) |name| session.root_module.linkSystemLibrary(name, .{});
    session.root_module.addImport("gtk", overview_gtk);
    session.root_module.addImport("apps", overview_apps);
    session.root_module.addImport("power", power_module);
    session.root_module.addImport("greeter", greeter_module);
    session.root_module.addImport("libc", libc);
    session.root_module.addImport("protocols", protocols);
    overview.root_module.addImport("protocols", protocols);
    b.installArtifact(session);
    b.step("shell", "Build the unified desktop shell").dependOn(&b.addInstallArtifact(session, .{}).step);
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
        exe.root_module.addImport("libc", libc);
    }
    const gtk_fixture = b.addExecutable(.{ .name = "waybar-power-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/waybar-power-fixture.zig"), .target = target, .optimize = optimize }) });
    linkGtk(gtk_fixture);
    const module = b.createModule(.{ .root_source_file = b.path("desktop-widgets.zig"), .target = target, .optimize = optimize });
    module.linkSystemLibrary("gtk+-3.0", .{});
    module.link_libc = true;
    module.addImport("gtk", gtk);
    module.addImport("power", power_module);
    gtk_fixture.root_module.addImport("panel", module);
    gtk_fixture.root_module.addImport("power", power_module);
    b.step("test-power-menu", "Check power profile controls and panel popups (requires a display)").dependOn(&b.addRunArtifact(gtk_fixture).step);
    b.installArtifact(gtk_fixture);
    const switcher = b.addExecutable(.{ .name = "labwc-switcher-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/labwc-switcher-fixture.zig"), .target = target, .optimize = optimize }) });
    linkGtk(switcher);
    switcher.root_module.linkSystemLibrary("wayland-client", .{});
    switcher.root_module.addImport("gtk", wayland_gtk);
    b.installArtifact(switcher);
    const pointer_xml: std.Build.LazyPath = .{ .cwd_relative = b.fmt("{s}/unstable/wlr-virtual-pointer-unstable-v1.xml", .{b.graph.environ_map.get("WLR_PROTOCOLS_DIR") orelse "/usr/share/wlr-protocols"}) };
    const pointer_code_command = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    pointer_code_command.addFileArg(pointer_xml);
    const pointer_code = pointer_code_command.addOutputFileArg("virtual-pointer.c");
    const pointer_api = b.createModule(.{ .root_source_file = b.path("desktop-virtual-pointer.zig"), .target = target, .optimize = optimize });
    pointer_api.addImport("gtk", gtk);
    const pointer = b.addExecutable(.{ .name = "desktop-pointer-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-pointer-fixture.zig"), .target = target, .optimize = optimize }) });
    pointer.root_module.link_libc = true;
    pointer.root_module.linkSystemLibrary("wayland-client", .{});
    pointer.root_module.addImport("protocols", protocols);
    protocol_references[6] = pointer_code;
    pointer.root_module.addImport("gtk", gtk);
    pointer.root_module.addImport("virtual-pointer", pointer_api);
    b.installArtifact(pointer);
    const checker = b.addExecutable(.{ .name = "check-labwc-switcher", .root_module = b.createModule(.{ .root_source_file = b.path("check-labwc-switcher.zig"), .target = target, .optimize = optimize }) });
    checker.root_module.link_libc = true;
    checker.root_module.addImport("libc", libc);
    b.installArtifact(checker);
    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("desktop-tests.zig"), .target = target, .optimize = optimize }) });
    tests.root_module.link_libc = true;
    tests.root_module.addImport("libc", libc);
    const run_tests = b.addRunArtifact(tests);
    const http_module = b.createModule(.{ .root_source_file = b.path("desktop-http.zig"), .target = target, .optimize = optimize });
    const http_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-http.zig"), .target = target, .optimize = optimize }) });
    http_tests.root_module.link_libc = true;
    http_tests.root_module.addImport("http", http_module);
    const run_http_tests = b.addRunArtifact(http_tests);
    b.step("test-http", "Check HTTP headers, body limits, redirects and timeouts against a local server").dependOn(&run_http_tests.step);
    const pointer_transport = b.createModule(.{ .root_source_file = b.path("tests/desktop-pointer-transport.zig"), .target = target, .optimize = optimize });
    pointer_transport.addImport("real-gtk", gtk);
    const pointer_test_api = b.createModule(.{ .root_source_file = b.path("desktop-virtual-pointer.zig"), .target = target, .optimize = optimize });
    pointer_test_api.addImport("gtk", pointer_transport);
    const pointer_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-virtual-pointer.zig"), .target = target, .optimize = optimize }) });
    pointer_tests.root_module.addImport("transport", pointer_transport);
    pointer_tests.root_module.addImport("pointer-api", pointer_test_api);
    const run_pointer_tests = b.addRunArtifact(pointer_tests);
    b.step("test-virtual-pointer", "Check virtual pointer protocol requests without a compositor").dependOn(&run_pointer_tests.step);
    const protocol_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-protocols.zig"), .target = target, .optimize = optimize }) });
    protocol_tests.root_module.addImport("protocols", protocols);
    protocol_tests.root_module.addImport("gtk", gtk);
    protocol_tests.root_module.link_libc = true;
    protocol_tests.root_module.linkSystemLibrary("wayland-client", .{});
    // Rename reference symbols so the C and Zig implementations can be
    // compared in the same process, including cross-protocol type pointers.
    const protocol_names = [_][]const u8{
        "zwlr_screencopy_manager_v1_interface",
        "zwlr_screencopy_frame_v1_interface",
        "zwlr_data_control_manager_v1_interface",
        "zwlr_data_control_device_v1_interface",
        "zwlr_data_control_source_v1_interface",
        "zwlr_data_control_offer_v1_interface",
        "ext_foreign_toplevel_list_v1_interface",
        "ext_foreign_toplevel_handle_v1_interface",
        "ext_image_capture_source_v1_interface",
        "ext_output_image_capture_source_manager_v1_interface",
        "ext_foreign_toplevel_image_capture_source_manager_v1_interface",
        "ext_image_copy_capture_manager_v1_interface",
        "ext_image_copy_capture_session_v1_interface",
        "ext_image_copy_capture_frame_v1_interface",
        "ext_image_copy_capture_cursor_session_v1_interface",
        "dotfiles_overview_v1_interface",
        "zwlr_virtual_pointer_v1_interface",
        "zwlr_virtual_pointer_manager_v1_interface",
    };
    var reference_flags: [protocol_names.len][]const u8 = undefined;
    for (protocol_names, &reference_flags) |name, *flag| flag.* = b.fmt("-D{s}=reference_{s}", .{ name, name });
    for (protocol_references) |code| protocol_tests.root_module.addCSourceFile(.{ .file = code, .flags = &reference_flags });
    const run_protocol_tests = b.addRunArtifact(protocol_tests);
    b.step("test-protocols", "Compare native Wayland metadata with the protocol generator").dependOn(&run_protocol_tests.step);
    const test_step = b.step("test", "Run data parsing and allowance tests");
    test_step.dependOn(&run_protocol_tests.step);
    test_step.dependOn(&run_pointer_tests.step);
    test_step.dependOn(&run_http_tests.step);
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&b.addRunArtifact(osd_tests).step);
    test_step.dependOn(&b.addRunArtifact(wallpaper_tests).step);
    test_step.dependOn(&b.addRunArtifact(settings_tests).step);
}

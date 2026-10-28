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
    const session = b.addExecutable(.{ .name = "desktop-zig", .root_module = b.createModule(.{ .root_source_file = b.path("desktop-zig.zig"), .target = target, .optimize = optimize }) });
    const runtime_options = b.addOptions();
    for ([_][]const u8{ "POWER_HELPER", "POWER_PKEXEC", "PIXBUF_LOADERS", "SOUND_FILE", "DATA_DIRS" }) |name| {
        runtime_options.addOption(?[]const u8, name, b.graph.environ_map.get(b.fmt("DESKTOP_RUNTIME_{s}", .{name})));
    }
    const runtime = b.createModule(.{ .root_source_file = b.path("desktop-runtime.zig"), .target = target, .optimize = optimize });
    runtime.addOptions("options", runtime_options);
    runtime.link_libc = true;
    const runtime_tests = b.addTest(.{ .root_module = runtime });
    b.step("test-runtime", "Check native launcher environment setup").dependOn(&b.addRunArtifact(runtime_tests).step);
    session.root_module.addImport("runtime", runtime);
    const libc = b.createModule(.{ .root_source_file = b.path("desktop-libc.zig"), .target = target, .optimize = optimize });
    const power_c = libc;
    const power_module = b.createModule(.{ .root_source_file = b.path("desktop-power.zig"), .target = target, .optimize = optimize });
    power_module.link_libc = true;
    power_module.addImport("libc", power_c);
    const power_fixture = b.addExecutable(.{ .name = "desktop-power-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-power-fixture.zig"), .target = target, .optimize = optimize }) });
    power_fixture.root_module.addImport("power", power_module);
    power_fixture.root_module.addImport("libc", power_c);
    b.step("test-power", "Check power profiles against isolated sysfs fixtures").dependOn(&b.addRunArtifact(power_fixture).step);
    const greeter_c = libc;
    const gtk = b.createModule(.{ .root_source_file = b.path("desktop-gtk.zig"), .target = target, .optimize = optimize });
    const network_api = b.createModule(.{ .root_source_file = b.path("desktop-network-api.zig"), .target = target, .optimize = optimize });
    network_api.addImport("gtk", gtk);
    const network = b.createModule(.{ .root_source_file = b.path("desktop-network.zig"), .target = target, .optimize = optimize });
    network.addImport("gtk", gtk);
    network.addImport("network-api", network_api);
    network.link_libc = true;
    network.linkSystemLibrary("gio-2.0", .{});
    const network_tests = b.addTest(.{ .root_module = network });
    const network_abi = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-gtk-abi.zig"), .target = target, .optimize = optimize }) });
    network_abi.root_module.addImport("api", network_api);
    network_abi.root_module.addImport("reference", bindings(b, target, optimize, "#include <gio/gio.h>\n", &.{"gio-2.0"}));
    network_abi.root_module.link_libc = true;
    const network_check = b.step("test-network", "Check native NetworkManager state and GIO ABI");
    network_check.dependOn(&b.addRunArtifact(network_tests).step);
    network_check.dependOn(&b.addRunArtifact(network_abi).step);
    const audio_api = b.createModule(.{ .root_source_file = b.path("desktop-audio-api.zig"), .target = target, .optimize = optimize });
    audio_api.addImport("gtk", gtk);
    const audio = b.createModule(.{ .root_source_file = b.path("desktop-audio.zig"), .target = target, .optimize = optimize });
    audio.addImport("gtk", gtk);
    audio.addImport("libc", libc);
    audio.addImport("audio-api", audio_api);
    audio.link_libc = true;
    for ([_][]const u8{ "wireplumber-0.5", "libpipewire-0.3" }) |name| audio.linkSystemLibrary(name, .{});
    audio.addImport("pipewire", bindings(b, target, optimize, "#include <pipewire/pipewire.h>\n#include <spa/param/audio/format.h>\n", &.{"libpipewire-0.3"}));
    const audio_tests = b.addTest(.{ .root_module = audio });
    const audio_reference = bindings(b, target, optimize, "#include <wp/wp.h>\n", &.{"wireplumber-0.5"});
    const audio_abi = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-gtk-abi.zig"), .target = target, .optimize = optimize }) });
    audio_abi.root_module.addImport("api", audio_api);
    audio_abi.root_module.addImport("reference", audio_reference);
    audio_abi.root_module.link_libc = true;
    const audio_check = b.step("test-audio", "Check native audio targets and the WirePlumber ABI");
    audio_check.dependOn(&b.addRunArtifact(audio_tests).step);
    audio_check.dependOn(&b.addRunArtifact(audio_abi).step);
    const battery = b.createModule(.{ .root_source_file = b.path("desktop-battery.zig"), .target = target, .optimize = optimize });
    battery.addImport("gtk", gtk);
    battery.link_libc = true;
    battery.linkSystemLibrary("gio-2.0", .{});
    const battery_tests = b.addTest(.{ .root_module = battery });
    b.step("test-battery", "Check native battery state and presentation").dependOn(&b.addRunArtifact(battery_tests).step);
    const backlight = b.createModule(.{ .root_source_file = b.path("desktop-backlight.zig"), .target = target, .optimize = optimize });
    backlight.addImport("gtk", gtk);
    backlight.addImport("libc", libc);
    backlight.link_libc = true;
    backlight.linkSystemLibrary("gtk+-3.0", .{});
    const backlight_tests = b.addTest(.{ .root_module = backlight });
    b.step("test-backlight", "Check native backlight limits and rounding").dependOn(&b.addRunArtifact(backlight_tests).step);
    const backlight_fixture = b.addExecutable(.{ .name = "desktop-backlight-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("desktop-backlight-fixture.zig"), .target = target, .optimize = optimize }) });
    backlight_fixture.root_module.addImport("gtk", gtk);
    backlight_fixture.root_module.addImport("backlight", backlight);
    backlight_fixture.root_module.addImport("battery", battery);
    backlight_fixture.root_module.addImport("audio", audio);
    backlight_fixture.root_module.addImport("network", network);
    backlight_fixture.root_module.link_libc = true;
    backlight_fixture.root_module.linkSystemLibrary("gtk+-3.0", .{});
    backlight_fixture.root_module.linkSystemLibrary("gtk-layer-shell-0", .{});
    b.installArtifact(backlight_fixture);
    b.step("backlight-fixture", "Build native backlight integration fixture").dependOn(&b.addInstallArtifact(backlight_fixture, .{}).step);
    const protocols = b.createModule(.{ .root_source_file = b.path("desktop-protocols.zig"), .target = target, .optimize = optimize });
    protocols.addImport("gtk", gtk);
    var protocol_references: [10]std.Build.LazyPath = undefined;
    const libc_reference = bindings(b, target, optimize, "#define _GNU_SOURCE\n#include <unistd.h>\n#include <stdlib.h>\n#include <signal.h>\n#include <termios.h>\n#include <poll.h>\n#include <errno.h>\n#include <fcntl.h>\n#include <time.h>\n#include <stdio.h>\n#include <sys/socket.h>\n#include <sys/un.h>\n#include <sys/prctl.h>\n#include <sys/wait.h>\n#include <dirent.h>\n#include <sys/file.h>\n#include <sys/mman.h>\n#include <pwd.h>\n#include <sys/statvfs.h>\n", &.{});
    const libc_abi = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-libc-abi.zig"), .target = target, .optimize = optimize }) });
    libc_abi.root_module.addImport("api", libc);
    libc_abi.root_module.addImport("reference", libc_reference);
    libc_abi.root_module.link_libc = true;
    b.step("test-libc-abi", "Verify POSIX declarations and constants against system headers").dependOn(&b.addRunArtifact(libc_abi).step);
    const greeter_module = b.createModule(.{ .root_source_file = b.path("desktop-greeter.zig"), .target = target, .optimize = optimize });
    greeter_module.link_libc = true;
    greeter_module.addImport("libc", greeter_c);
    const apps_gtk = gtk;
    const wayland_gtk = gtk;
    const panel_gtk = gtk;
    const quick_module = b.createModule(.{ .root_source_file = b.path("desktop-quick-settings.zig"), .target = target, .optimize = optimize });
    quick_module.addImport("gtk", gtk);
    quick_module.addImport("battery", battery);
    quick_module.addImport("audio", audio);
    quick_module.addImport("network", network);
    quick_module.addImport("backlight", backlight);
    quick_module.addImport("libc", libc);
    const panel_data = b.createModule(.{ .root_source_file = b.path("waybar-panel.zig"), .target = target, .optimize = optimize });
    panel_data.addImport("battery", battery);
    panel_data.addImport("audio", audio);
    panel_data.addImport("network", network);
    panel_data.addImport("libc", libc);
    const battery_fixture = b.addExecutable(.{ .name = "desktop-battery-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-battery-fixture.zig"), .target = target, .optimize = optimize }) });
    battery_fixture.root_module.addImport("gtk", gtk);
    battery_fixture.root_module.addImport("battery", battery);
    battery_fixture.root_module.addImport("quick", quick_module);
    battery_fixture.root_module.addImport("panel-data", panel_data);
    linkGtk(battery_fixture);
    b.installArtifact(battery_fixture);
    b.step("battery-fixture", "Build the native battery and quick-settings fixture").dependOn(&b.addInstallArtifact(battery_fixture, .{}).step);
    const settings_module = b.createModule(.{ .root_source_file = b.path("desktop-settings.zig"), .target = target, .optimize = optimize });
    settings_module.link_libc = true;
    settings_module.linkSystemLibrary("gtk+-3.0", .{});
    settings_module.addImport("gtk", gtk);
    settings_module.addImport("audio", audio);
    settings_module.addImport("network", network);
    const audio_fixture = b.addExecutable(.{ .name = "desktop-audio-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-audio-fixture.zig"), .target = target, .optimize = optimize }) });
    audio_fixture.root_module.addImport("gtk", gtk);
    audio_fixture.root_module.addImport("audio", audio);
    audio_fixture.root_module.addImport("network", network);
    audio_fixture.root_module.addImport("quick", quick_module);
    linkGtk(audio_fixture);
    b.installArtifact(audio_fixture);
    b.step("audio-fixture", "Build the isolated native audio integration fixture").dependOn(&b.addInstallArtifact(audio_fixture, .{}).step);
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
    const askpass_fixture = b.addExecutable(.{ .name = "desktop-askpass-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-askpass-fixture.zig"), .target = target, .optimize = optimize }) });
    askpass_fixture.root_module.addImport("askpass", askpass_module);
    askpass_fixture.root_module.addImport("libc", libc);
    const run_askpass_fixture = b.addRunArtifact(askpass_fixture);
    run_askpass_fixture.addArtifactArg(session);
    b.step("test-askpass", "Check the SSH askpass dialog and protocol (requires a display)").dependOn(&run_askpass_fixture.step);
    const polkit_gtk = gtk;
    const polkit_module = b.createModule(.{ .root_source_file = b.path("desktop-polkit.zig"), .target = target, .optimize = optimize });
    polkit_module.link_libc = true;
    polkit_module.linkSystemLibrary("gtk+-3.0", .{});
    polkit_module.linkSystemLibrary("polkit-agent-1", .{});
    polkit_module.linkSystemLibrary("polkit-gobject-1", .{});
    polkit_module.addImport("gtk", polkit_gtk);
    polkit_module.addImport("libc", libc);
    const polkit_fixture = b.addExecutable(.{ .name = "desktop-polkit-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-polkit-fixture.zig"), .target = target, .optimize = optimize }) });
    polkit_fixture.root_module.addImport("polkit", polkit_module);
    const run_polkit_fixture = b.addRunArtifact(polkit_fixture);
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
    const sc_fixture = b.addExecutable(.{ .name = "desktop-screenshot-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-screenshot-fixture.zig"), .target = target, .optimize = optimize }) });
    sc_fixture.root_module.addImport("screenshot", sc_module);
    const run_sc_fixture = b.addRunArtifact(sc_fixture);
    b.step("test-screenshot", "Check screenshot CLI parsing, buffers, PNG encoding and overlay (requires a display)").dependOn(&run_sc_fixture.step);
    const wallpaper = b.createModule(.{ .root_source_file = b.path("desktop-wallpaper.zig"), .target = target, .optimize = optimize });
    wallpaper.link_libc = true;
    wallpaper.linkSystemLibrary("gtk+-3.0", .{});
    wallpaper.linkSystemLibrary("gtk-layer-shell-0", .{});
    wallpaper.addImport("gtk", panel_gtk);
    const wallpaper_tests = b.addTest(.{ .root_module = wallpaper });
    const osd = b.createModule(.{ .root_source_file = b.path("desktop-osd.zig"), .target = target, .optimize = optimize });
    osd.link_libc = true;
    osd.linkSystemLibrary("gtk+-3.0", .{});
    osd.linkSystemLibrary("gtk-layer-shell-0", .{});
    osd.addImport("gtk", panel_gtk);
    const osd_tests = b.addTest(.{ .root_module = osd });
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
    const lock_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    lock_code.addFileArg(.{ .cwd_relative = b.fmt("{s}/staging/ext-session-lock/ext-session-lock-v1.xml", .{protocol_dir}) });
    protocol_references[7] = lock_code.addOutputFileArg("ext-session-lock-v1.c");
    const idle_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    idle_code.addFileArg(.{ .cwd_relative = b.fmt("{s}/staging/ext-idle-notify/ext-idle-notify-v1.xml", .{protocol_dir}) });
    protocol_references[8] = idle_code.addOutputFileArg("ext-idle-notify-v1.c");
    const output_code = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    output_code.addFileArg(.{ .cwd_relative = b.fmt("{s}/unstable/wlr-output-management-unstable-v1.xml", .{b.graph.environ_map.get("WLR_PROTOCOLS_DIR") orelse "/usr/share/wlr-protocols"}) });
    protocol_references[9] = output_code.addOutputFileArg("wlr-output-management-v1.c");
    const output_module = b.createModule(.{ .root_source_file = b.path("desktop-output.zig"), .target = target, .optimize = optimize });
    output_module.addImport("gtk", gtk);
    output_module.addImport("protocols", protocols);
    output_module.link_libc = true;
    for ([_][]const u8{ "gtk+-3.0", "gio-unix-2.0", "wayland-client" }) |name| output_module.linkSystemLibrary(name, .{});
    session.root_module.addImport("output", output_module);
    const output_tests = b.addTest(.{ .root_module = output_module });
    b.step("test-output", "Check output scaling arguments and fixed point limits").dependOn(&b.addRunArtifact(output_tests).step);
    const idle_module = b.createModule(.{ .root_source_file = b.path("desktop-idle.zig"), .target = target, .optimize = optimize });
    idle_module.addImport("gtk", gtk);
    idle_module.addImport("libc", libc);
    idle_module.addImport("protocols", protocols);
    idle_module.link_libc = true;
    for ([_][]const u8{ "gtk+-3.0", "gio-unix-2.0", "wayland-client" }) |name| idle_module.linkSystemLibrary(name, .{});
    const idle_fixture = b.addExecutable(.{ .name = "desktop-idle-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-idle-fixture.zig"), .target = target, .optimize = optimize }) });
    idle_fixture.root_module.addImport("idle", idle_module);
    idle_fixture.root_module.addImport("gtk", gtk);
    b.installArtifact(idle_fixture);
    b.step("idle-fixture", "Build the isolated idle and sleep coordination fixture").dependOn(&b.addInstallArtifact(idle_fixture, .{}).step);
    const lock_auth = b.createModule(.{ .root_source_file = b.path("desktop-lock-auth.zig"), .target = target, .optimize = optimize });
    lock_auth.link_libc = true;
    lock_auth.linkSystemLibrary("pam", .{});
    const lock_module = b.createModule(.{ .root_source_file = b.path("desktop-lock.zig"), .target = target, .optimize = optimize });
    lock_module.addImport("gtk", gtk);
    lock_module.addImport("libc", libc);
    lock_module.addImport("protocols", protocols);
    lock_module.addImport("lock-auth", lock_auth);
    lock_module.link_libc = true;
    for ([_][]const u8{ "gtk+-3.0", "wayland-client", "xkbcommon" }) |name| lock_module.linkSystemLibrary(name, .{});
    session.root_module.addImport("lock", lock_module);
    const auth_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-lock-auth.zig"), .target = target, .optimize = optimize }) });
    auth_tests.root_module.addImport("auth", lock_auth);
    const fixture_auth = b.createModule(.{ .root_source_file = b.path("tests/desktop-lock-fake-auth.zig"), .target = target, .optimize = optimize });
    const fixture_lock = b.createModule(.{ .root_source_file = b.path("desktop-lock.zig"), .target = target, .optimize = optimize });
    fixture_lock.addImport("gtk", gtk);
    fixture_lock.addImport("libc", libc);
    fixture_lock.addImport("protocols", protocols);
    fixture_lock.addImport("lock-auth", fixture_auth);
    fixture_lock.link_libc = true;
    for ([_][]const u8{ "gtk+-3.0", "wayland-client", "xkbcommon" }) |name| fixture_lock.linkSystemLibrary(name, .{});
    const lock_fixture = b.addExecutable(.{ .name = "desktop-lock-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-lock-fixture.zig"), .target = target, .optimize = optimize }) });
    lock_fixture.root_module.addImport("lock", fixture_lock);
    b.installArtifact(lock_fixture);
    b.step("lock-fixture", "Build the isolated session lock fixture").dependOn(&b.addInstallArtifact(lock_fixture, .{}).step);
    const lock_tests = b.addTest(.{ .root_module = lock_module });
    const lock_check = b.step("test-lock", "Check password editing, erasure, and PAM conversations");
    lock_check.dependOn(&b.addRunArtifact(lock_tests).step);
    lock_check.dependOn(&b.addRunArtifact(auth_tests).step);
    const overview_gtk = gtk;
    const abi_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-gtk-abi.zig"), .target = target, .optimize = optimize }) });
    abi_tests.root_module.addImport("api", gtk);
    abi_tests.root_module.addImport("reference", overview_c.createModule());
    abi_tests.root_module.link_libc = true;
    b.step("test-gtk-abi", "Verify explicit toolkit declarations against the installed C headers").dependOn(&b.addRunArtifact(abi_tests).step);
    const overview_apps = b.createModule(.{ .root_source_file = b.path("desktop-apps.zig"), .target = target, .optimize = optimize });
    overview_apps.addImport("gtk", overview_gtk);
    session.root_module.link_libc = true;
    for ([_][]const u8{ "gtk+-3.0", "gio-unix-2.0", "gtk-layer-shell-0", "wayland-client", "polkit-agent-1", "polkit-gobject-1" }) |name| session.root_module.linkSystemLibrary(name, .{});
    session.root_module.addImport("gtk", overview_gtk);
    session.root_module.addImport("apps", overview_apps);
    session.root_module.addImport("power", power_module);
    session.root_module.addImport("greeter", greeter_module);
    session.root_module.addImport("libc", libc);
    session.root_module.addImport("protocols", protocols);
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
    tests.root_module.addImport("battery", battery);
    tests.root_module.addImport("audio", audio);
    tests.root_module.addImport("network", network);
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
        "zwlr_output_manager_v1_interface",
        "zwlr_output_head_v1_interface",
        "zwlr_output_mode_v1_interface",
        "zwlr_output_configuration_v1_interface",
        "zwlr_output_configuration_head_v1_interface",
        "ext_idle_notifier_v1_interface",
        "ext_idle_notification_v1_interface",
        "ext_session_lock_manager_v1_interface",
        "ext_session_lock_v1_interface",
        "ext_session_lock_surface_v1_interface",
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
    for ([_]*std.Build.Module{ osd, session.root_module, module }) |root| {
        root.addImport("backlight", backlight);
        root.addImport("battery", battery);
        root.addImport("audio", audio);
        root.addImport("network", network);
    }
    const network_fixture = b.addExecutable(.{ .name = "desktop-network-fixture", .root_module = b.createModule(.{ .root_source_file = b.path("desktop-network-fixture.zig"), .target = target, .optimize = optimize }) });
    for ([_]*std.Build.Module{network_fixture.root_module}) |root| {
        root.addImport("gtk", gtk);
        root.addImport("network", network);
        root.addImport("audio", audio);
        root.addImport("battery", battery);
        root.addImport("backlight", backlight);
    }
    linkGtk(network_fixture);
    b.step("network-fixture", "Build isolated NetworkManager integration driver").dependOn(&b.addInstallArtifact(network_fixture, .{}).step);
    const session_fixture = b.addTest(.{
        .name = "desktop-session-fixture",
        .root_module = b.createModule(.{ .root_source_file = b.path("desktop-session-fixture.zig"), .target = target, .optimize = optimize }),
    });
    session_fixture.root_module.addImport("gtk", gtk);
    session_fixture.root_module.addImport("network", network);
    session_fixture.root_module.addImport("audio", audio);
    session_fixture.root_module.addImport("battery", battery);
    session_fixture.root_module.addImport("backlight", backlight);
    linkGtk(session_fixture);
    b.step("session-fixture", "Build private logind action and lifecycle tests").dependOn(&b.addInstallArtifact(session_fixture, .{}).step);
    // Run only through the private D-Bus/PipeWire/Xvfb memory fixture.
    const memory_tests = b.addTest(.{
        .name = "desktop-memory-tests",
        .root_module = b.createModule(.{ .root_source_file = b.path("desktop-memory-tests.zig"), .target = target, .optimize = optimize }),
        .filters = &.{"memory:"},
    });
    memory_tests.root_module.link_libc = true;
    memory_tests.root_module.linkSystemLibrary("gtk+-3.0", .{});
    memory_tests.root_module.linkSystemLibrary("pangoft2", .{});
    memory_tests.root_module.linkSystemLibrary("gtk-layer-shell-0", .{});
    memory_tests.root_module.addImport("gtk", gtk);
    memory_tests.root_module.addImport("libc", libc);
    memory_tests.root_module.addImport("audio", audio);
    memory_tests.root_module.addImport("network", network);
    memory_tests.root_module.addImport("battery", battery);
    memory_tests.root_module.addImport("backlight", backlight);
    memory_tests.root_module.addImport("power", power_module);
    b.step("memory-tests", "Build leak-checking lifecycle tests for the isolated memory fixture").dependOn(&b.addInstallArtifact(memory_tests, .{}).step);
    const test_step = b.step("test", "Run data parsing and allowance tests");
    test_step.dependOn(&b.addRunArtifact(runtime_tests).step);
    test_step.dependOn(&b.addRunArtifact(audio_tests).step);
    test_step.dependOn(&b.addRunArtifact(audio_abi).step);
    test_step.dependOn(network_check);
    test_step.dependOn(&b.addRunArtifact(battery_tests).step);
    test_step.dependOn(&b.addRunArtifact(output_tests).step);
    test_step.dependOn(&b.addRunArtifact(backlight_tests).step);
    test_step.dependOn(&b.addRunArtifact(lock_tests).step);
    test_step.dependOn(&b.addRunArtifact(auth_tests).step);
    test_step.dependOn(&run_protocol_tests.step);
    test_step.dependOn(&run_pointer_tests.step);
    test_step.dependOn(&run_http_tests.step);
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&b.addRunArtifact(osd_tests).step);
    test_step.dependOn(&b.addRunArtifact(wallpaper_tests).step);
    test_step.dependOn(&b.addRunArtifact(settings_tests).step);
}

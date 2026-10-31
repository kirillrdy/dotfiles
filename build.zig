const std = @import("std");
fn bindings(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, headers: []const u8, libraries: []const []const u8) *std.Build.Module {
    const header = b.addWriteFiles().add("bindings.h", headers);
    const translated = b.addTranslateC(.{ .root_source_file = header, .target = target, .optimize = optimize });
    for (libraries) |name| translated.linkSystemLibrary(name, .{});
    return translated.createModule();
}
fn protocolCode(b: *std.Build, xml: std.Build.LazyPath, output: []const u8) std.Build.LazyPath {
    const command = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    command.addFileArg(xml);
    return command.addOutputFileArg(output);
}
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const desktop = b.createModule(.{
        .root_source_file = b.path("desktop-zig.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    for ([_][]const u8{ "gtk+-3.0", "gio-unix-2.0", "gtk-layer-shell-0", "wayland-client", "libpipewire-0.3", "pam", "xkbcommon", "pangoft2" }) |name| desktop.linkSystemLibrary(name, .{});
    const options = b.addOptions();
    for ([_][]const u8{ "POWER_HELPER", "POWER_PKEXEC", "PIXBUF_LOADERS", "SOUND_FILE", "DATA_DIRS" }) |name| {
        options.addOption(?[]const u8, name, b.graph.environ_map.get(b.fmt("DESKTOP_RUNTIME_{s}", .{name})));
    }
    desktop.addOptions("options", options);
    desktop.addImport("posix", bindings(b, target, optimize, "#define _GNU_SOURCE\n#include <unistd.h>\n#include <fcntl.h>\n#include <errno.h>\n#include <sys/stat.h>\n#include <sys/file.h>\n#include <sys/random.h>\n#include <stdlib.h>\n#include <sys/prctl.h>\n#include <sys/mman.h>\n#include <pwd.h>\n#include <grp.h>\n#include <sys/wait.h>\n#include <sys/socket.h>\n#include <security/pam_appl.h>\n#include <security/pam_modules.h>\n", &.{"pam"}));
    desktop.addImport("pipewire", bindings(b, target, optimize, "#include <pipewire/pipewire.h>\n#include <pipewire/extensions/metadata.h>\n#include <spa/param/audio/format.h>\n#include <spa/param/video/format.h>\n#include <spa/param/buffers.h>\n#include <spa/param/props.h>\n#include <spa/param/route.h>\n", &.{"libpipewire-0.3"}));
    const compositor_headers = b.addWriteFiles();
    const layer_header = b.addSystemCommand(&.{ "wayland-scanner", "server-header" });
    const wlr_dir = b.graph.environ_map.get("WLR_PROTOCOLS_DIR") orelse "/usr/share/wlr-protocols";
    layer_header.addFileArg(.{ .cwd_relative = b.fmt("{s}/unstable/wlr-layer-shell-unstable-v1.xml", .{wlr_dir}) });
    _ = compositor_headers.addCopyFile(layer_header.addOutputFileArg("wlr-layer-shell-unstable-v1-protocol.h"), "wlr-layer-shell-unstable-v1-protocol.h");
    const compositor = b.addTranslateC(.{ .root_source_file = b.path("desktop-compositor.h"), .target = target, .optimize = optimize });
    compositor.addIncludePath(compositor_headers.getDirectory());
    for ([_][]const u8{ "wlroots-0.20", "wayland-server", "xkbcommon", "libinput", "libdrm", "pixman-1" }) |name| {
        compositor.linkSystemLibrary(name, .{});
        desktop.linkSystemLibrary(name, .{});
    }
    desktop.addImport("compositor-abi", compositor.createModule());
    const session = b.addExecutable(.{ .name = "desktop-zig", .root_module = desktop });
    b.installArtifact(session);
    b.installDirectory(.{ .source_dir = b.path("desktop-icons"), .install_dir = .prefix, .install_subdir = "share/icons/hicolor/scalable/status" });
    b.step("shell", "Build the desktop shell").dependOn(&b.addInstallArtifact(session, .{}).step);

    // Zig collects tests from files in the root module, not imported modules.
    // Compile the same production files with the same dependencies in one test root.
    const test_module = b.createModule(.{ .root_source_file = b.path("desktop-test-runner.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for (desktop.import_table.keys(), desktop.import_table.values()) |name, dependency| test_module.addImport(name, dependency);
    test_module.link_objects.appendSlice(b.graph.arena, desktop.link_objects.items) catch @panic("OOM");
    const tests = b.addTest(.{ .name = "desktop-tests", .root_module = test_module });
    const test_step = b.step("test", "Run unit, ABI, protocol and widget checks (requires Wayland)");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_module.addImport("gtk-reference", bindings(b, target, optimize, "#define _GNU_SOURCE\n#include <gtk/gtk.h>\n#include <gtk/gtkunixprint.h>\n#include <gio/gdesktopappinfo.h>\n#include <gtk-layer-shell.h>\n#include <glib-unix.h>\n#include <signal.h>\n#include <wayland-client.h>\n#include <gdk/gdkwayland.h>\n", &.{ "gtk+-unix-print-3.0", "gio-unix-2.0", "gtk-layer-shell-0", "wayland-client" }));
    test_module.addImport("libc-reference", bindings(b, target, optimize, "#define _GNU_SOURCE\n#include <unistd.h>\n#include <stdlib.h>\n#include <signal.h>\n#include <termios.h>\n#include <poll.h>\n#include <errno.h>\n#include <fcntl.h>\n#include <time.h>\n#include <stdio.h>\n#include <sys/socket.h>\n#include <linux/netlink.h>\n#include <sys/un.h>\n#include <sys/prctl.h>\n#include <sys/wait.h>\n#include <dirent.h>\n#include <sys/file.h>\n#include <sys/mman.h>\n#include <pwd.h>\n#include <sys/statvfs.h>\n", &.{}));
    const protocol_dir = b.graph.environ_map.get("WAYLAND_PROTOCOLS_DIR") orelse "/usr/share/wayland-protocols";
    const wlr_protocols = b.graph.environ_map.get("WLR_PROTOCOLS_DIR") orelse "/usr/share/wlr-protocols";
    const decoration_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-decoration-fixture.zig"), .target = target, .optimize = optimize, .link_libc = true });
    decoration_module.linkSystemLibrary("wayland-client", .{});
    const decoration_headers = b.addWriteFiles();
    for ([_][]const u8{ "stable/xdg-shell/xdg-shell.xml", "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml" }, [_][]const u8{ "xdg-shell", "xdg-decoration" }) |xml, name| {
        const source: std.Build.LazyPath = .{ .cwd_relative = b.fmt("{s}/{s}", .{ protocol_dir, xml }) };
        const header = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
        header.addFileArg(source);
        const filename = b.fmt("{s}-client-protocol.h", .{name});
        _ = decoration_headers.addCopyFile(header.addOutputFileArg(filename), filename);
        decoration_module.addCSourceFile(.{ .file = protocolCode(b, source, b.fmt("{s}-client-protocol.c", .{name})) });
    }
    const decoration_bindings = b.addTranslateC(.{
        .root_source_file = decoration_headers.add("bindings.h", "#include <wayland-client.h>\n#include \"xdg-shell-client-protocol.h\"\n#include \"xdg-decoration-client-protocol.h\"\n"),
        .target = target,
        .optimize = optimize,
    });
    decoration_bindings.addIncludePath(decoration_headers.getDirectory());
    decoration_bindings.linkSystemLibrary("wayland-client", .{});
    decoration_module.addImport("decoration-client", decoration_bindings.createModule());
    const decoration_fixture = b.addExecutable(.{ .name = "desktop-decoration-fixture", .root_module = decoration_module });
    b.step("compositor-fixture", "Build compositor protocol test clients").dependOn(&b.addInstallArtifact(decoration_fixture, .{}).step);
    const protocol_names = [_][]const u8{
        "zxdg_output_manager_v1_interface",
        "zxdg_output_v1_interface",
        "zwlr_layer_shell_v1_interface",
        "zwlr_layer_surface_v1_interface",
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
    const protocol_files = [_]std.Build.LazyPath{
        .{ .cwd_relative = b.fmt("{s}/unstable/xdg-output/xdg-output-unstable-v1.xml", .{protocol_dir}) },
        .{ .cwd_relative = b.fmt("{s}/unstable/wlr-layer-shell-unstable-v1.xml", .{wlr_protocols}) },
        .{ .cwd_relative = b.fmt("{s}/stable/xdg-shell/xdg-shell.xml", .{protocol_dir}) },
        .{ .cwd_relative = b.fmt("{s}/unstable/wlr-screencopy-unstable-v1.xml", .{wlr_protocols}) },
        .{ .cwd_relative = b.fmt("{s}/unstable/wlr-data-control-unstable-v1.xml", .{wlr_protocols}) },
        .{ .cwd_relative = b.fmt("{s}/staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml", .{protocol_dir}) },
        .{ .cwd_relative = b.fmt("{s}/staging/ext-image-capture-source/ext-image-capture-source-v1.xml", .{protocol_dir}) },
        .{ .cwd_relative = b.fmt("{s}/staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml", .{protocol_dir}) },
        b.path("desktop-overview-v1.xml"),
        .{ .cwd_relative = b.fmt("{s}/unstable/wlr-virtual-pointer-unstable-v1.xml", .{wlr_protocols}) },
        .{ .cwd_relative = b.fmt("{s}/staging/ext-session-lock/ext-session-lock-v1.xml", .{protocol_dir}) },
        .{ .cwd_relative = b.fmt("{s}/staging/ext-idle-notify/ext-idle-notify-v1.xml", .{protocol_dir}) },
        .{ .cwd_relative = b.fmt("{s}/unstable/wlr-output-management-unstable-v1.xml", .{wlr_protocols}) },
    };
    for (protocol_files, 0..) |xml, i| {
        // Reference symbols are used only by the test binary.
        tests.root_module.addCSourceFile(.{ .file = protocolCode(b, xml, b.fmt("protocol-{d}.c", .{i})), .flags = &reference_flags });
    }

    const Fixture = struct { name: []const u8, source: []const u8, step: []const u8, install: bool = false, run: bool = false, library: bool = false, test_runner: bool = false };
    const fixtures = [_]Fixture{
        .{ .name = "desktop-wallpaper-fixture", .source = "tests/desktop-wallpaper-fixture.zig", .step = "wallpaper-fixture" },
        .{ .name = "desktop-compositor-fixture", .source = "tests/desktop-compositor-fixture.zig", .step = "compositor-fixture" },
        .{ .name = "pam_desktop_secrets", .source = "desktop-secrets-pam.zig", .step = "secrets-pam", .install = true, .library = true },
        .{ .name = "desktop-secrets-pam-fixture", .source = "tests/desktop-secrets-pam-fixture.zig", .step = "secrets-pam-fixture" },
        .{ .name = "desktop_secrets_test_token", .source = "tests/desktop-secrets-pam-token.zig", .step = "secrets-pam-fixture", .library = true },
        .{ .name = "desktop-secrets-fixture", .source = "tests/desktop-secrets-fixture.zig", .step = "secrets-fixture" },
        .{ .name = "desktop-portal-fixture", .source = "tests/desktop-portal-fixture.zig", .step = "portal-fixture" },
        .{ .name = "desktop-portal-chooser-fixture", .source = "tests/desktop-portal-chooser-fixture.zig", .step = "portal-chooser-fixture" },
        .{ .name = "desktop-portal-print-fixture", .source = "tests/desktop-portal-print-fixture.zig", .step = "portal-print-fixture" },
        .{ .name = "desktop-portal-video-fixture", .source = "tests/desktop-portal-video-fixture.zig", .step = "portal-video-fixture" },
        .{ .name = "desktop-pointer-fixture", .source = "tests/desktop-pointer-fixture.zig", .step = "pointer-fixture", .install = true },
        .{ .name = "desktop-battery-fixture", .source = "tests/desktop-battery-fixture.zig", .step = "battery-fixture", .install = true },
        .{ .name = "desktop-audio-fixture", .source = "tests/desktop-audio-fixture.zig", .step = "audio-fixture", .install = true },
        .{ .name = "desktop-backlight-fixture", .source = "desktop-backlight-fixture.zig", .step = "backlight-fixture", .install = true },
        .{ .name = "desktop-network-fixture", .source = "desktop-network-fixture.zig", .step = "network-fixture" },
        .{ .name = "desktop-idle-fixture", .source = "tests/desktop-idle-fixture.zig", .step = "idle-fixture", .install = true },
        .{ .name = "desktop-lock-fixture", .source = "tests/desktop-lock-fixture.zig", .step = "lock-fixture", .install = true },
        .{ .name = "desktop-apps-fixture", .source = "tests/desktop-apps-fixture.zig", .step = "apps-fixture", .install = true, .run = true },
        .{ .name = "waybar-power-fixture", .source = "tests/waybar-power-fixture.zig", .step = "widgets-fixture", .install = true, .run = true },
        .{ .name = "labwc-switcher-fixture", .source = "tests/labwc-switcher-fixture.zig", .step = "switcher-fixture", .install = true },
        .{ .name = "desktop-settings-fixture", .source = "tests/desktop-settings-fixture.zig", .step = "settings-fixture", .run = true },
        .{ .name = "desktop-askpass-fixture", .source = "tests/desktop-askpass-fixture.zig", .step = "askpass-fixture", .run = true },
        .{ .name = "desktop-polkit-fixture", .source = "tests/desktop-polkit-fixture.zig", .step = "polkit-fixture", .run = true },
        .{ .name = "desktop-polkit-agent-fixture", .source = "tests/desktop-polkit-agent-fixture.zig", .step = "polkit-agent-fixture" },
        .{ .name = "desktop-screenshot-fixture", .source = "tests/desktop-screenshot-fixture.zig", .step = "screenshot-fixture", .run = true },
        .{ .name = "desktop-session-fixture", .source = "desktop-session-fixture.zig", .step = "session-fixture", .test_runner = true },
        .{ .name = "desktop-memory-tests", .source = "desktop-memory-tests.zig", .step = "memory-tests", .test_runner = true },
    };
    const capture = b.step("portal-capture-fixtures", "Build the capture protocol test clients");
    for (fixtures) |fixture| {
        const module = b.createModule(.{ .root_source_file = b.path(fixture.source), .target = target, .optimize = optimize });
        module.addImport("desktop", desktop);
        const artifact = if (fixture.library)
            b.addLibrary(.{ .name = fixture.name, .root_module = module, .linkage = .dynamic })
        else if (fixture.test_runner)
            b.addTest(.{ .name = fixture.name, .root_module = module, .filters = if (std.mem.eql(u8, fixture.step, "memory-tests")) &.{"memory:"} else &.{"session:"} })
        else
            b.addExecutable(.{ .name = fixture.name, .root_module = module });
        if (fixture.install) b.installArtifact(artifact);
        const step = if (b.top_level_steps.get(fixture.step)) |existing| &existing.step else b.step(fixture.step, "Build isolated test client");
        step.dependOn(&b.addInstallArtifact(artifact, .{}).step);
        if (std.mem.eql(u8, fixture.step, "portal-fixture") or std.mem.eql(u8, fixture.step, "portal-video-fixture") or std.mem.eql(u8, fixture.step, "pointer-fixture")) capture.dependOn(&b.addInstallArtifact(artifact, .{}).step);
        if (fixture.run) {
            const run = b.addRunArtifact(artifact);
            if (std.mem.eql(u8, fixture.step, "askpass-fixture")) run.addArtifactArg(session);
            test_step.dependOn(&run.step);
        }
    }
}

const std = @import("std");
fn bindings(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize, headers: []const u8, libraries: []const []const u8) *std.Build.Module {
    const header = b.addWriteFiles().add("bindings.h", headers);
    const translated = b.addTranslateC(.{ .root_source_file = header, .target = target, .optimize = optimize });
    for (libraries) |name| translated.linkSystemLibrary(name, .{});
    return translated.createModule();
}
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_bin = b.option([]const u8, "test-bin", "Fixture installation directory relative to the prefix") orelse "bin";
    const fixture_install: std.Build.Step.InstallArtifact.Options = .{ .dest_dir = .{ .override = .{ .custom = test_bin } } };
    const desktop = b.createModule(.{
        .root_source_file = b.path("desktop-zig.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Wayland clients use the native wire runtime; only the compositor links libwayland (server).
    for ([_][]const u8{ "libpipewire-0.3", "pam", "xkbcommon", "freetype2", "harfbuzz", "fontconfig" }) |name| desktop.linkSystemLibrary(name, .{});
    const text_c = bindings(b, target, optimize, "#include <ft2build.h>\n#include FT_FREETYPE_H\n#include FT_MULTIPLE_MASTERS_H\n#include FT_SYNTHESIS_H\n#include <hb.h>\n#include <hb-ft.h>\n#include <fontconfig/fontconfig.h>\n", &.{ "freetype2", "harfbuzz", "fontconfig" });
    desktop.addImport("text-c", text_c);
    const protocol_dir = b.graph.environ_map.get("WAYLAND_PROTOCOLS_DIR") orelse "/usr/share/wayland-protocols";
    const wlr_protocols = b.graph.environ_map.get("WLR_PROTOCOLS_DIR") orelse "/usr/share/wlr-protocols";
    const protocol_files = [_]std.Build.LazyPath{
        .{ .cwd_relative = b.fmt("{s}/unstable/xdg-output/xdg-output-unstable-v1.xml", .{protocol_dir}) },
        .{ .cwd_relative = b.fmt("{s}/stable/xdg-shell/xdg-shell.xml", .{protocol_dir}) },
        .{ .cwd_relative = b.fmt("{s}/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml", .{protocol_dir}) },
        .{ .cwd_relative = b.fmt("{s}/unstable/xdg-foreign/xdg-foreign-unstable-v2.xml", .{protocol_dir}) },
        .{ .cwd_relative = b.fmt("{s}/unstable/wlr-layer-shell-unstable-v1.xml", .{wlr_protocols}) },
        .{ .cwd_relative = b.fmt("{s}/unstable/wlr-screencopy-unstable-v1.xml", .{wlr_protocols}) },
        .{ .cwd_relative = b.fmt("{s}/unstable/wlr-data-control-unstable-v1.xml", .{wlr_protocols}) },
        .{ .cwd_relative = b.fmt("{s}/staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml", .{protocol_dir}) },
        .{ .cwd_relative = b.fmt("{s}/staging/ext-image-capture-source/ext-image-capture-source-v1.xml", .{protocol_dir}) },
        .{ .cwd_relative = b.fmt("{s}/staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml", .{protocol_dir}) },
        b.path("desktop-overview-v1.xml"),
        .{ .cwd_relative = b.fmt("{s}/staging/xdg-activation/xdg-activation-v1.xml", .{protocol_dir}) },
        .{ .cwd_relative = b.fmt("{s}/unstable/text-input/text-input-unstable-v3.xml", .{protocol_dir}) },
        .{ .cwd_relative = b.fmt("{s}/staging/cursor-shape/cursor-shape-v1.xml", .{protocol_dir}) },
        .{ .cwd_relative = b.fmt("{s}/unstable/tablet/tablet-unstable-v2.xml", .{protocol_dir}) },
        .{ .cwd_relative = b.fmt("{s}/unstable/wlr-virtual-pointer-unstable-v1.xml", .{wlr_protocols}) },
        .{ .cwd_relative = b.fmt("{s}/staging/ext-session-lock/ext-session-lock-v1.xml", .{protocol_dir}) },
        .{ .cwd_relative = b.fmt("{s}/staging/ext-idle-notify/ext-idle-notify-v1.xml", .{protocol_dir}) },
        .{ .cwd_relative = b.fmt("{s}/unstable/wlr-output-management-unstable-v1.xml", .{wlr_protocols}) },
    };
    // Native Wayland client: the wire runtime plus typed bindings for every protocol used.
    const wire = b.createModule(.{ .root_source_file = b.path("desktop-wire.zig"), .target = target, .optimize = optimize, .link_libc = true });
    const wayland_generator = b.addExecutable(.{ .name = "wayland-zig", .root_module = b.createModule(.{ .root_source_file = b.path("tools/wayland-zig.zig"), .target = b.graph.host, .optimize = optimize }) });
    const client_command = b.addRunArtifact(wayland_generator);
    const client_source = client_command.addOutputFileArg("wayland-client.zig");
    client_command.addFileArg(.{ .cwd_relative = b.graph.environ_map.get("WAYLAND_XML") orelse "/usr/share/wayland/wayland.xml" });
    for (protocol_files) |xml| client_command.addFileArg(xml);
    const wayland_client = b.createModule(.{ .root_source_file = client_source, .target = target, .optimize = optimize });
    wayland_client.addImport("wayland-wire", wire);
    desktop.addImport("wayland-wire", wire);
    desktop.addImport("wayland-client", wayland_client);
    // The compositor serves dotfiles_overview_v1 through libwayland-server's wl_interface metadata.
    const server_command = b.addRunArtifact(wayland_generator);
    server_command.addArg("--libwayland");
    const server_source = server_command.addOutputFileArg("wayland-server-protocols.zig");
    server_command.addFileArg(b.path("desktop-overview-v1.xml"));
    desktop.addImport("wayland-server-protocols", b.createModule(.{ .root_source_file = server_source, .target = target, .optimize = optimize }));
    // Unicode case folding and normalization tables, generated from the UCD.
    const ucd = b.graph.environ_map.get("UNICODE_DATA_DIR") orelse "/usr/share/unicode";
    const unicode_generator = b.addExecutable(.{ .name = "unicode-tables", .root_module = b.createModule(.{ .root_source_file = b.path("tools/unicode-tables.zig"), .target = b.graph.host, .optimize = optimize }) });
    const unicode_command = b.addRunArtifact(unicode_generator);
    for ([_][]const u8{ "UnicodeData.txt", "CaseFolding.txt", "DerivedNormalizationProps.txt" }) |name| unicode_command.addFileArg(.{ .cwd_relative = b.fmt("{s}/{s}", .{ ucd, name }) });
    const unicode_tables = b.createModule(.{ .root_source_file = unicode_command.addOutputFileArg("unicode-tables.zig"), .target = target, .optimize = optimize });
    desktop.addImport("unicode-tables", unicode_tables);
    // Native D-Bus client runtime, independent of GLib.
    const dbus = b.createModule(.{ .root_source_file = b.path("desktop-dbus.zig"), .target = target, .optimize = optimize, .link_libc = true });
    desktop.addImport("dbus", dbus);
    const integration_tests = b.option(bool, "integration-tests", "Include system and Wayland integration tests") orelse false;
    const options = b.addOptions();
    options.addOption(bool, "integration_tests", integration_tests);
    for ([_][]const u8{ "POWER_HELPER", "POWER_PKEXEC", "SOUND_FILE", "CODEX_ICON", "DATA_DIRS" }) |name| {
        options.addOption(?[]const u8, name, b.graph.environ_map.get(b.fmt("DESKTOP_RUNTIME_{s}", .{name})));
    }
    desktop.addOptions("options", options);
    desktop.addImport("pam", bindings(b, target, optimize, "#include <security/pam_appl.h>\n#include <security/pam_modules.h>\n", &.{"pam"}));
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
    const test_module = b.createModule(.{ .root_source_file = b.path("desktop-tests.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for (desktop.import_table.keys(), desktop.import_table.values()) |name, dependency| test_module.addImport(name, dependency);
    test_module.link_objects.appendSlice(b.graph.arena, desktop.link_objects.items) catch @panic("OOM");
    const tests = b.addTest(.{ .name = "desktop-tests", .root_module = test_module, .filters = if (integration_tests) &.{"integration:"} else &.{} });
    b.step("test-binary", "Build tests for execution in a NixOS VM").dependOn(&b.addInstallArtifact(tests, fixture_install).step);
    const test_step = b.step("test", "Run unit, ABI and protocol checks");
    const unit_run = b.addRunArtifact(tests);
    test_step.dependOn(&unit_run.step);
    // The wire runtime is its own module, so its tests need their own root.
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "desktop-wire-tests", .root_module = wire })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "desktop-dbus-tests", .root_module = dbus })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .name = "wayland-zig-tests", .root_module = wayland_generator.root_module })).step);
    test_module.addImport("libc-reference", bindings(b, target, optimize, "#define _GNU_SOURCE\n#include <unistd.h>\n#include <stdlib.h>\n#include <signal.h>\n#include <termios.h>\n#include <poll.h>\n#include <errno.h>\n#include <fcntl.h>\n#include <time.h>\n#include <stdio.h>\n#include <sys/stat.h>\n#include <sys/random.h>\n#include <sys/socket.h>\n#include <linux/netlink.h>\n#include <sys/un.h>\n#include <sys/prctl.h>\n#include <sys/wait.h>\n#include <dirent.h>\n#include <sys/file.h>\n#include <sys/mman.h>\n#include <pwd.h>\n#include <grp.h>\n#include <sys/statvfs.h>\n", &.{}));

    const fixtures_module = b.createModule(.{ .root_source_file = b.path("tests/desktop-fixtures.zig"), .target = target, .optimize = optimize });
    fixtures_module.addImport("desktop", desktop);
    const desktop_fixture = b.addExecutable(.{ .name = "desktop-fixture", .root_module = fixtures_module });
    const install_fixture = b.addInstallArtifact(desktop_fixture, fixture_install);
    b.getInstallStep().dependOn(&install_fixture.step);
    b.step("fixtures", "Build multi-call test fixture binary").dependOn(&install_fixture.step);
    for ([_]struct { name: []const u8, source: []const u8, step: []const u8, library: bool = false }{
        .{ .name = "pam_desktop_secrets", .source = "desktop-secrets-pam.zig", .step = "secrets-pam", .library = true },
        .{ .name = "desktop_secrets_test_token", .source = "tests/desktop-secrets-pam-token.zig", .step = "secrets-pam-fixture", .library = true },
        .{ .name = "desktop-session-fixture", .source = "tests/desktop-session-fixture.zig", .step = "session-fixture" },
        .{ .name = "desktop-memory-tests", .source = "tests/desktop-memory-tests.zig", .step = "memory-tests" },
    }) |target_spec| {
        const module = b.createModule(.{ .root_source_file = b.path(target_spec.source), .target = target, .optimize = optimize });
        module.addImport("desktop", desktop);
        const artifact = if (target_spec.library)
            b.addLibrary(.{ .name = target_spec.name, .root_module = module, .linkage = .dynamic })
        else
            b.addTest(.{ .name = target_spec.name, .root_module = module, .filters = if (std.mem.eql(u8, target_spec.step, "memory-tests")) &.{"memory:"} else &.{"session:"} });
        const install = b.addInstallArtifact(artifact, if (target_spec.library) .{} else fixture_install);
        if (target_spec.library) b.getInstallStep().dependOn(&install.step);
        const step = if (b.top_level_steps.get(target_spec.step)) |existing| &existing.step else b.step(target_spec.step, "Build isolated test client");
        step.dependOn(&install.step);
    }
}

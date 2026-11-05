//! Isolated desktop-entry, native-control and launch integration checks.
const std = @import("std");
const apps = @import("desktop").apps;
const c = apps.c;
const assert = std.debug.assert;
const cast = c.__zig.cast;
extern fn gtk_widget_draw(*c.GtkWidget, *c.cairo_t) void;
extern fn cairo_surface_write_to_png(*c.cairo_surface_t, [*:0]const u8) c_int;
fn eq(actual: [*c]const u8, expected: []const u8) void {
    assert(std.mem.eql(u8, std.mem.span(actual), expected));
}
fn pump() void {
    const end = @divTrunc(c.g_get_monotonic_time(), 1000) + 100;
    while (@divTrunc(c.g_get_monotonic_time(), 1000) < end) {
        while (c.g_main_context_iteration(null, 0) != 0) {}
        c.g_usleep(1000);
    }
}
fn firstName(launcher: *apps.Launcher) [*c]const u8 {
    return launcher.first().?.name;
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 3 and std.mem.eql(u8, args[1], "--record")) {
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = "launched" });
        return;
    }
    // GLib can cache XDG paths in library constructors, before main. Re-exec
    // with the isolated paths already in the environment.
    if (c.g_getenv("DESKTOP_APPS_FIXTURE_ROOT") == null) {
        const root = c.g_dir_make_tmp("desktop-apps-XXXXXX", null);
        assert(root != null);
        defer c.g_free(root);
        defer std.Io.Dir.cwd().deleteTree(init.io, std.mem.span(root)) catch {};
        var env = try init.minimal.environ.createMap(a);
        for ([_][]const u8{ "DESKTOP_APPS_FIXTURE_ROOT", "XDG_DATA_HOME", "XDG_DATA_DIRS", "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS", "XDG_CACHE_HOME" }) |key| try env.put(key, std.mem.span(root));
        try env.put("XDG_CURRENT_DESKTOP", "labwc:wlroots");
        try env.put("LANGUAGE", "C");
        var child = try std.process.spawn(init.io, .{ .argv = &.{try std.process.executablePathAlloc(init.io, a)}, .environ_map = &env });
        const term = try child.wait(init.io);
        if (term != .exited or term.exited != 0) return error.FixtureFailed;
        return;
    }
    const base = c.g_getenv("DESKTOP_APPS_FIXTURE_ROOT").?;
    const applications = try std.fmt.allocPrint(a, "{s}/applications", .{base});
    try std.Io.Dir.createDirAbsolute(init.io, applications, .default_dir);
    const theme = try std.fmt.allocPrint(a, "{s}/icons/hicolor", .{base});
    const icon_directory = try std.fmt.allocPrint(a, "{s}/scalable/apps", .{theme});
    try std.Io.Dir.cwd().createDirPath(init.io, icon_directory);
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = try std.fmt.allocPrint(a, "{s}/index.theme", .{theme}),
        .data = "[Icon Theme]\nName=Fixture\nDirectories=scalable/apps\n[scalable/apps]\nSize=96\nMinSize=1\nMaxSize=512\nType=Scalable\nContext=Applications\n",
    });
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = try std.fmt.allocPrint(a, "{s}/desktop-apps-fixture-icon.svg", .{icon_directory}),
        .data = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"96\" height=\"96\"><rect width=\"96\" height=\"96\" fill=\"red\"/></svg>",
    });
    const fixtures = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "a", .text = "Name=A Text Editor\n" },
        .{ .name = "b", .text = "Name=Text Editor\n" },
        .{ .name = "c", .text = "Name=Straße\n" },
        .{ .name = "d", .text = "Name=Café\n" },
        .{ .name = "hidden", .text = "Name=Hidden\nHidden=true\n" },
        .{ .name = "nodisplay", .text = "Name=Invisible\nNoDisplay=true\n" },
        .{ .name = "only", .text = "Name=GNOME only\nOnlyShowIn=GNOME;\n" },
        .{ .name = "not", .text = "Name=Not labwc\nNotShowIn=labwc;\n" },
        .{ .name = "try", .text = "Name=Missing executable\nTryExec=/nonexistent-desktop-apps-fixture\n" },
    };
    for (fixtures) |fixture| {
        try std.Io.Dir.cwd().writeFile(init.io, .{
            .sub_path = try std.fmt.allocPrint(a, "{s}/{s}.desktop", .{ applications, fixture.name }),
            .data = try std.fmt.allocPrint(a, "[Desktop Entry]\nType=Application\nExec=/proc/self/exe\nComment=unrelated description\n{s}", .{fixture.text}),
        });
    }
    c.gtk_init(null, null);
    if (c.g_getenv("DESKTOP_APPS_ICON_PATH")) |path| c.gtk_icon_theme_append_search_path(c.gtk_icon_theme_get_default(), path);
    var icon_error: [*c]c.GError = null;
    const svg = c.gtk_icon_theme_load_icon(c.gtk_icon_theme_get_default(), "desktop-apps-fixture-icon", 96, c.GTK_ICON_LOOKUP_FORCE_SIZE, &icon_error);
    if (icon_error != null) std.debug.print("SVG icon failed: {s}\n", .{icon_error.*.message});
    assert(svg != null and icon_error == null);
    defer c.g_object_unref(svg);
    assert(c.gdk_pixbuf_get_width(svg) == 96 and c.gdk_pixbuf_get_height(svg) == 96);
    var launcher = apps.Launcher.init(null);
    defer launcher.deinit();
    assert(c.gtk_window_get_decorated(cast(c.GtkWindow, launcher.window)) == 0);
    launcher.bind();
    try launcher.load();
    // Nix's patched GIO also searches installed profiles outside XDG_DATA_DIRS.
    var fixture_count: usize = 0;
    for (launcher.entries.items) |item| {
        const filename = c.g_desktop_app_info_get_filename(@ptrCast(item.info));
        if (std.mem.startsWith(u8, std.mem.span(filename), applications)) fixture_count += 1;
    }
    assert(fixture_count == 4);
    launcher.present();
    pump();
    try launcher.setSearch("EDITOR");
    eq(firstName(&launcher), "A Text Editor");
    try launcher.setSearch("text");
    eq(firstName(&launcher), "Text Editor");
    try launcher.setSearch("STRASSE");
    eq(firstName(&launcher), "Straße");
    try launcher.setSearch("Cafe\xcc\x81");
    eq(firstName(&launcher), "Café");
    for ([_][*:0]const u8{ "unrelated", "/proc/self/exe", "txed", "missing" }) |query| {
        try launcher.setSearch(std.mem.span(query));
        assert(launcher.first() == null);
        assert(launcher.visible.items.len == 0);
    }
    launcher.present();
    pump();
    assert(launcher.visible.items.len > 0);
    eq(launcher.searchText(), "");

    // Paging and keyboard selection must stay on valid results, including the
    // last partial page. Exercise actual native input-method commits as well.
    for (0..30) |index| {
        const key = c.g_key_file_new();
        defer c.g_key_file_unref(key);
        const source = try std.fmt.allocPrintSentinel(a, "[Desktop Entry]\nType=Application\nName=Paged fixture {d:0>2}\nExec=true\n", .{index}, 0);
        assert(c.g_key_file_load_from_data(key, source, source.len, 0, null) != 0);
        const info = c.g_desktop_app_info_new_from_keyfile(key).?;
        try launcher.add(@ptrCast(info));
        c.g_object_unref(info);
    }
    try launcher.setSearch("Paged fixture");
    pump();
    try std.testing.expectEqual(@as(usize, 30), launcher.visible.items.len);
    launcher.focusGrid();
    pump();
    var navigation = apps.KeyEvent{ .event_type = c.GDK_KEY_PRESS, .window = null, .send_event = 1, .time = 0, .state = 0, .keyval = 0xff56 };
    assert(apps.keyPress(launcher.window, &navigation, &launcher) != 0);
    try std.testing.expectEqual(@as(usize, 1), launcher.page);
    try std.testing.expectEqual(@as(usize, 24), launcher.selected);
    navigation.keyval = 0xff57; // End
    _ = apps.keyPress(launcher.window, &navigation, &launcher);
    try std.testing.expectEqual(@as(usize, 29), launcher.selected);
    navigation.keyval = c.GDK_KEY_Right;
    _ = apps.keyPress(launcher.window, &navigation, &launcher);
    try std.testing.expectEqual(@as(usize, 29), launcher.selected);
    navigation.keyval = 0xff50; // Home
    _ = apps.keyPress(launcher.window, &navigation, &launcher);
    assert(launcher.page == 0 and launcher.selected == 0);
    try launcher.setSearch("Paged fixture 29");
    assert(launcher.page == 0 and launcher.visible.items.len == 1);
    launcher.present();
    pump();
    // A headless compositor may have no keyboard device/focus yet.
    launcher.search_input.?.focus(true);
    c.g_signal_emit_by_name(launcher.search_input.?.im, "commit", @as([*:0]const u8, "東京"));
    eq(launcher.searchText(), "東京");
    assert(launcher.visible.items.len == 0);
    try launcher.reload();
    launcher.present();
    pump();

    // Verify desktop Exec quoting/field expansion for terminal applications.
    const keyfile = c.g_key_file_new();
    defer c.g_key_file_unref(keyfile);
    const data = "[Desktop Entry]\nType=Application\nName=Terminal Fixture\nIcon=utilities-terminal\nTerminal=true\nExec=/proc/self/exe \"two words\" %c %i %% %F %u\n";
    assert(c.g_key_file_load_from_data(keyfile, data, data.len, 0, null) != 0);
    const terminal = c.g_desktop_app_info_new_from_keyfile(keyfile).?;
    defer c.g_object_unref(terminal);
    const argv = try apps.terminalArgs(a, terminal);
    const expected = [_][]const u8{ "ghostty", "-e", "/proc/self/exe", "two words", "Terminal Fixture", "--icon", "utilities-terminal", "%" };
    assert(argv.items.len == expected.len + 1 and argv.items[expected.len] == null);
    for (argv.items[0..expected.len], expected) |actual, want| eq(actual.?, want);

    // A failed launch must leave the grid visible and show an actionable error.
    const failing = c.g_app_info_create_from_commandline("/nonexistent-desktop-apps-fixture", "Broken", 0, null).?;
    defer c.g_object_unref(failing);
    assert(!launcher.launch(failing));
    assert(c.gtk_widget_get_visible(launcher.window) != 0);
    assert(c.gtk_widget_get_visible(@ptrCast(launcher.message)) != 0);
    assert(launcher.status.len != 0);

    // Exercise Escape and repeat activation, including clearing a stale query.
    var escape = apps.KeyEvent{ .event_type = c.GDK_KEY_PRESS, .window = null, .send_event = 1, .time = 0, .state = 0, .keyval = c.GDK_KEY_Escape };
    assert(apps.keyPress(launcher.window, &escape, &launcher) != 0);
    assert(c.gtk_widget_get_visible(launcher.window) == 0);
    var state: ?apps.Launcher = null;
    defer if (state) |*instance| instance.deinit();
    apps.activate(null, &state);
    const window = state.?.window;
    assert(c.gtk_widget_get_visible(window) != 0);
    try state.?.setSearch("stale");
    apps.activate(null, &state);
    assert(c.gtk_widget_get_visible(window) == 0);
    apps.activate(null, &state);
    assert(state.?.window == window and c.gtk_widget_get_visible(window) != 0);
    eq(state.?.searchText(), "");
    c.gtk_widget_hide(window);

    launcher.present();
    const marker = try std.fmt.allocPrint(a, "{s}/launched", .{base});
    const executable = c.g_shell_quote((try a.dupeSentinel(u8, try std.process.executablePathAlloc(init.io, a), 0)).ptr);
    defer c.g_free(executable);
    const quoted_marker = c.g_shell_quote((try a.dupeSentinel(u8, marker, 0)).ptr);
    defer c.g_free(quoted_marker);
    const command = try std.fmt.allocPrintSentinel(a, "{s} --record {s}", .{ executable, quoted_marker }, 0);
    const success = c.g_app_info_create_from_commandline(command, "Launch fixture", 0, null).?;
    defer c.g_object_unref(success);
    assert(launcher.launch(success));
    assert(c.gtk_widget_get_visible(launcher.window) == 0);
    const deadline = @divTrunc(c.g_get_monotonic_time(), 1000) + 5000;
    while (@divTrunc(c.g_get_monotonic_time(), 1000) < deadline) {
        if (std.Io.Dir.openFileAbsolute(init.io, marker, .{})) |file| {
            file.close(init.io);
            break;
        } else |_| {}
        pump();
    }
    const recorded = try std.Io.Dir.cwd().readFileAlloc(init.io, marker, a, .limited(1024));
    eq((try a.dupeSentinel(u8, recorded, 0)).ptr, "launched");

    // Render a screenshot when explicitly requested for visual inspection.
    if (c.g_getenv("DESKTOP_APPS_SCREENSHOT")) |path| {
        launcher.present();
        pump();
        const scale = @max(1, c.gtk_widget_get_scale_factor(launcher.window));
        const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, c.gtk_widget_get_allocated_width(launcher.window) * scale, c.gtk_widget_get_allocated_height(launcher.window) * scale).?;
        defer c.cairo_surface_destroy(surface);
        c.cairo_surface_set_device_scale(surface, @floatFromInt(scale), @floatFromInt(scale));
        const cr = c.cairo_create(surface).?;
        defer c.cairo_destroy(cr);
        gtk_widget_draw(launcher.window, cr);
        assert(cairo_surface_write_to_png(surface, path) == 0);
    }
    std.debug.print("desktop-apps: discovery, Unicode search, IME, paging, keyboard selection, terminal argv and launch lifecycle passed\n", .{});
}

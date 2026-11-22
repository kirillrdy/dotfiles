//! Isolated desktop-entry, native-control and launch integration checks.
const std = @import("std");
const apps = @import("desktop").apps;
const c = apps.c;
const assert = std.debug.assert;
const cast = c.__zig.cast;
fn eq(actual: [*c]const u8, expected: []const u8) void {
    assert(std.mem.eql(u8, std.mem.span(actual), expected));
}
fn pump() void {
    const end = @divTrunc(c.__zig.monotonicTime(), 1000) + 100;
    while (@divTrunc(c.__zig.monotonicTime(), 1000) < end) {
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
    if (c.__zig.getenv("DESKTOP_APPS_FIXTURE_ROOT") == null) {
        const root = c.g_dir_make_tmp("desktop-apps-XXXXXX", null);
        assert(root != null);
        defer c.g_free(root);
        defer std.Io.Dir.cwd().deleteTree(init.io, std.mem.span(root)) catch {};
        var env = try init.minimal.environ.createMap(a);
        for ([_][]const u8{ "DESKTOP_APPS_FIXTURE_ROOT", "XDG_DATA_HOME", "XDG_DATA_DIRS", "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS", "XDG_CACHE_HOME" }) |key| try env.put(key, std.mem.span(root));
        try env.put("XDG_CURRENT_DESKTOP", "wlroots");
        try env.put("LANGUAGE", "C");
        var child = try std.process.spawn(init.io, .{ .argv = &.{try std.process.executablePathAlloc(init.io, a)}, .environ_map = &env });
        const term = try child.wait(init.io);
        if (term != .exited or term.exited != 0) return error.FixtureFailed;
        return;
    }
    const base = c.__zig.getenv("DESKTOP_APPS_FIXTURE_ROOT").?;
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
        .{ .name = "not", .text = "Name=Not wlroots\nNotShowIn=wlroots;\n" },
        .{ .name = "try", .text = "Name=Missing executable\nTryExec=/nonexistent-desktop-apps-fixture\n" },
    };
    for (fixtures) |fixture| {
        try std.Io.Dir.cwd().writeFile(init.io, .{
            .sub_path = try std.fmt.allocPrint(a, "{s}/{s}.desktop", .{ applications, fixture.name }),
            .data = try std.fmt.allocPrint(a, "[Desktop Entry]\nType=Application\nExec=/proc/self/exe\nComment=unrelated description\n{s}", .{fixture.text}),
        });
    }
    const svg = c.__icons.load(init.gpa, "desktop-apps-fixture-icon", 96, 1, null).?;
    defer c.__icons.free(init.gpa, svg);
    assert(svg.width == 96 and svg.height == 96);
    var launcher = apps.Launcher.init(init.gpa);
    defer launcher.deinit();
    launcher.bind();
    try launcher.load();
    // Nix's patched GIO also searches installed profiles outside XDG_DATA_DIRS.
    var fixture_count: usize = 0;
    for (launcher.entries.items) |item| {
        const filename = item.info.filename orelse continue;
        if (std.mem.startsWith(u8, filename, applications)) fixture_count += 1;
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
        const source = try std.fmt.allocPrint(a, "[Desktop Entry]\nType=Application\nName=Paged fixture {d:0>2}\nExec=true\n", .{index});
        const info = (try apps.App.parse(init.gpa, source, "", null)).?;
        try launcher.add(info);
        info.unref();
    }
    try launcher.setSearch("Paged fixture");
    pump();
    try std.testing.expectEqual(@as(usize, 30), launcher.visible.items.len);
    launcher.focusGrid();
    pump();
    var navigation = apps.KeyEvent{ .state = 0, .keyval = 0xff56 };
    assert(apps.keyPress(&launcher, &navigation));
    try std.testing.expectEqual(@as(usize, 1), launcher.page);
    try std.testing.expectEqual(@as(usize, 24), launcher.selected);
    navigation.keyval = 0xff57; // End
    _ = apps.keyPress(&launcher, &navigation);
    try std.testing.expectEqual(@as(usize, 29), launcher.selected);
    navigation.keyval = c.__zig.keys.Right;
    _ = apps.keyPress(&launcher, &navigation);
    try std.testing.expectEqual(@as(usize, 29), launcher.selected);
    navigation.keyval = 0xff50; // Home
    _ = apps.keyPress(&launcher, &navigation);
    assert(launcher.page == 0 and launcher.selected == 0);
    try launcher.setSearch("Paged fixture 29");
    assert(launcher.page == 0 and launcher.visible.items.len == 1);
    launcher.present();
    pump();
    // A headless compositor may have no keyboard device/focus yet.
    launcher.search_input.?.focus(true);
    launcher.search_input.?.preedit("とうきょう", 15);
    eq(launcher.searchText(), "");
    try launcher.search_input.?.insert("東京");
    eq(launcher.searchText(), "東京");
    assert(launcher.visible.items.len == 0);
    try launcher.reload();
    launcher.present();
    pump();

    // Verify desktop Exec quoting/field expansion for terminal applications.
    const data = "[Desktop Entry]\nType=Application\nName=Terminal Fixture\nIcon=utilities-terminal\nTerminal=true\nExec=/proc/self/exe \"two words\" %c %i %% %F %u\n";
    const terminal = (try apps.App.parse(init.gpa, data, "terminal-fixture.desktop", null)).?;
    defer terminal.unref();
    const argv = try terminal.launchArgs(a);
    const expected = [_][]const u8{ "ghostty", "-e", "/proc/self/exe", "two words", "Terminal Fixture", "--icon", "utilities-terminal", "%" };
    assert(argv.len == expected.len);
    for (argv, expected) |actual, want| eq(actual, want);

    // A failed launch must leave the grid visible and show an actionable error.
    const failing = try apps.App.fromCommandLine(init.gpa, "/nonexistent-desktop-apps-fixture", "Broken");
    defer failing.unref();
    assert(!launcher.launch(failing));
    assert(launcher.visible_window);
    assert(launcher.status.len != 0);

    // Exercise Escape and repeat activation, including clearing a stale query.
    var escape = apps.KeyEvent{ .state = 0, .keyval = c.__zig.keys.Escape };
    assert(apps.keyPress(&launcher, &escape));
    assert(!launcher.visible_window);
    var state: ?apps.Launcher = null;
    defer if (state) |*instance| instance.deinit();
    apps.activate(init.gpa, &state);
    const window = state.?.host.?.surface.?;
    assert(state.?.visible_window);
    try state.?.setSearch("stale");
    apps.activate(init.gpa, &state);
    assert(!state.?.visible_window);
    apps.activate(init.gpa, &state);
    assert(state.?.host.?.surface.? == window and state.?.visible_window);
    eq(state.?.searchText(), "");
    state.?.hide();

    launcher.present();
    const marker = try std.fmt.allocPrint(a, "{s}/launched", .{base});
    var command: std.ArrayList(u8) = .empty;
    try apps.appinfo.shellQuote(a, &command, try std.process.executablePathAlloc(init.io, a));
    try command.appendSlice(a, " --record ");
    try apps.appinfo.shellQuote(a, &command, marker);
    const success = try apps.App.fromCommandLine(init.gpa, command.items, "Launch fixture");
    defer success.unref();
    assert(launcher.launch(success));
    assert(!launcher.visible_window);
    const deadline = @divTrunc(c.__zig.monotonicTime(), 1000) + 5000;
    while (@divTrunc(c.__zig.monotonicTime(), 1000) < deadline) {
        if (std.Io.Dir.openFileAbsolute(init.io, marker, .{})) |file| {
            file.close(init.io);
            break;
        } else |_| {}
        pump();
    }
    const recorded = try std.Io.Dir.cwd().readFileAlloc(init.io, marker, a, .limited(1024));
    eq((try a.dupeSentinel(u8, recorded, 0)).ptr, "launched");

    // Render a screenshot when explicitly requested for visual inspection.
    if (c.__zig.getenv("DESKTOP_APPS_SCREENSHOT")) |path| {
        launcher.present();
        pump();
        const host = launcher.host.?;
        const scale = host.surface.?.output.scale;
        const width = host.surface.?.width * scale;
        const height = host.surface.?.height * scale;
        const pixels = std.heap.page_allocator.alloc(u32, width * height) catch @panic("out of memory");
        defer std.heap.page_allocator.free(pixels);
        @memset(pixels, 0);
        apps.Host.draw(host, .{ .pixels = pixels, .width = width, .height = height });
        const encoded = @import("desktop").png.encode(std.heap.page_allocator, .{ .pixels = std.mem.sliceAsBytes(pixels), .width = width, .height = height, .stride = width * 4, .alpha = true }) catch @panic("PNG encoding failed");
        defer std.heap.page_allocator.free(encoded);
        const file = std.c.fopen(path, "wb") orelse @panic("cannot write screenshot");
        defer _ = std.c.fclose(file);
        assert(std.c.fwrite(encoded.ptr, 1, encoded.len, file) == encoded.len);
    }
    std.debug.print("desktop-apps: discovery, Unicode search, IME, paging, keyboard selection, terminal argv and launch lifecycle passed\n", .{});
}

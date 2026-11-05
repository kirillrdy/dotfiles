//! GNOME application grid with native pixels, GIO discovery and GTK hosting.
const std = @import("std");
pub const c = @import("desktop-gtk.zig");
// GTK event unions contain C bitfields that Zig 0.14 cannot translate.
pub const KeyEvent = extern struct {
    event_type: c_int,
    window: ?*anyopaque,
    send_event: i8,
    time: u32,
    state: c_uint,
    keyval: c_uint,
};
const cast = c.__zig.cast;
fn connect(widget: anytype, signal: [*:0]const u8, callback: anytype, data: anytype) void {
    _ = c.g_signal_connect_data(widget, signal, @ptrCast(callback), data, null, 0);
}
const raster = @import("desktop-raster.zig");
const shaping = @import("desktop-text.zig");
const input = @import("desktop-password-entry.zig");
const view = @import("desktop-apps-view.zig");
const allocator = std.heap.c_allocator;
pub const style =
    \\window#desktop-apps { background: #222226; color: #fafafb; }
;

// Normalize before matching so composed/decomposed names and Unicode casing agree.
pub fn fold(text: [*c]const u8) [*c]u8 {
    const lower = c.g_utf8_casefold(text, -1);
    defer c.g_free(lower);
    return c.g_utf8_normalize(lower, -1, c.G_NORMALIZE_ALL_COMPOSE);
}
pub fn rank(name: [*c]const u8, query: [*c]const u8) u8 {
    const n = std.mem.span(name);
    const q = std.mem.span(query);
    return if (std.mem.startsWith(u8, n, q)) 0 else if (std.mem.indexOf(u8, n, q) != null) 1 else 2;
}
// GIO's terminal fallback does not consistently include Ghostty. Expand desktop
// field codes into argv directly, preserving quoting without invoking a shell.
pub fn terminalArgs(a: std.mem.Allocator, info: *c.GDesktopAppInfo) !std.array_list.Managed(?[*:0]const u8) {
    const command = c.g_app_info_get_commandline(@ptrCast(info));
    if (command == null) return error.MissingCommand;
    var argc: c_int = 0;
    var argv: [*c][*c]u8 = null;
    var err: [*c]c.GError = null;
    if (c.g_shell_parse_argv(command, &argc, &argv, &err) == 0) {
        if (err != null) c.g_error_free(err);
        return error.InvalidCommand;
    }
    defer c.g_strfreev(argv);
    var args = std.array_list.Managed(?[*:0]const u8).init(a);
    try args.appendSlice(&.{ "ghostty", "-e" });
    for (argv[0..@intCast(argc)]) |argument| {
        const text = std.mem.span(argument);
        if (std.mem.eql(u8, text, "%i")) {
            const icon = c.g_desktop_app_info_get_string(info, "Icon");
            defer c.g_free(icon);
            if (icon != null and icon[0] != 0) try args.appendSlice(&.{ "--icon", (try a.dupeSentinel(u8, std.mem.span(icon), 0)).ptr });
            continue;
        }
        var expanded = std.array_list.Managed(u8).init(a);
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] != '%') {
                try expanded.append(text[i]);
                continue;
            }
            i += 1;
            if (i == text.len) return error.InvalidFieldCode;
            switch (text[i]) {
                '%' => try expanded.append('%'),
                'c' => try expanded.appendSlice(std.mem.span(c.g_app_info_get_name(@ptrCast(info)))),
                'k' => {
                    const filename = c.g_desktop_app_info_get_filename(info);
                    if (filename != null) try expanded.appendSlice(std.mem.span(filename));
                },
                // No files/URIs are supplied when launching from the grid.
                'f', 'F', 'u', 'U', 'd', 'D', 'n', 'N', 'v', 'm' => {},
                else => return error.InvalidFieldCode,
            }
        }
        if (expanded.items.len > 0 or text.len == 0) try args.append((try a.dupeSentinel(u8, expanded.items, 0)).ptr);
    }
    try args.append(null);
    return args;
}
pub const Entry = struct {
    info: *c.GAppInfo,
    name: [*c]const u8,
    folded: [*c]u8,
    tile: view.Tile = .{},
};

pub const Launcher = struct {
    window: *c.GtkWidget,
    layout: *c.GtkWidget,
    results: *c.GtkWidget,
    search: *c.GtkWidget,
    grid: *c.GtkWidget,
    message: *c.GtkWidget,
    search_input: ?*input.Entry = null,
    entries: std.array_list.Managed(*Entry),
    visible: std.array_list.Managed(*Entry),
    query: [*c]u8,
    renderer: shaping.Renderer = .{},
    search_view: view.Search = .{},
    geometry: view.Grid = view.Grid.init(1040, 600),
    selected: usize = 0,
    page: usize = 0,
    hover: ?usize = null,
    pressed: ?usize = null,
    search_focus: bool = true,
    search_hover: bool = false,
    search_hash: u64 = 0,
    search_offset: f64 = 0,
    status: [:0]u8,
    on_search: ?*const fn (?*anyopaque) void = null,
    search_context: ?*anyopaque = null,
    wheel: f64 = 0,
    wheel_time: u32 = 0,

    pub fn init(application: ?*c.GtkApplication) Launcher {
        const window = (if (application) |app| c.gtk_application_window_new(app) else c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL)).?;
        c.gtk_widget_set_name(window, "desktop-apps");
        c.gtk_window_set_title(cast(c.GtkWindow, window), "Applications");
        c.gtk_window_set_decorated(cast(c.GtkWindow, window), 0);
        c.gtk_window_set_skip_taskbar_hint(cast(c.GtkWindow, window), 1);
        c.gtk_window_set_skip_pager_hint(cast(c.GtkWindow, window), 1);
        c.gtk_window_set_default_size(cast(c.GtkWindow, window), 1040, 720);
        c.gtk_window_maximize(cast(c.GtkWindow, window));
        const provider = c.gtk_css_provider_new();
        defer c.g_object_unref(provider);
        _ = c.gtk_css_provider_load_from_data(provider, style, style.len, null);
        c.gtk_style_context_add_provider_for_screen(c.gtk_widget_get_screen(window), @ptrCast(provider), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
        const layout = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0).?;
        c.gtk_container_add(cast(c.GtkContainer, window), layout);
        const search = c.gtk_drawing_area_new().?;
        c.gtk_widget_set_can_focus(search, 1);
        c.gtk_widget_set_size_request(search, 370, 37);
        c.gtk_widget_set_halign(search, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_margin_top(search, 12);
        c.gtk_widget_set_margin_bottom(search, 6);
        c.gtk_box_pack_start(cast(c.GtkBox, layout), search, 0, 0, 0);
        const grid = c.gtk_drawing_area_new().?;
        c.gtk_widget_set_can_focus(grid, 1);
        c.gtk_box_pack_start(cast(c.GtkBox, layout), grid, 1, 1, 0);
        const message = c.gtk_drawing_area_new().?;
        c.gtk_widget_set_size_request(message, -1, 64);
        c.gtk_widget_set_no_show_all(message, 1);
        c.gtk_box_pack_end(cast(c.GtkBox, layout), message, 0, 0, 0);
        return .{ .window = window, .layout = layout, .results = grid, .search = search, .grid = grid, .message = message, .entries = .init(allocator), .visible = .init(allocator), .query = fold(""), .status = allocator.dupeSentinel(u8, "", 0) catch @panic("out of memory") };
    }
    // Bind after init: input-method callbacks retain this stable address.
    pub fn bind(self: *Launcher) void {
        self.bindControls();
        connect(self.window, "key-press-event", &keyPress, self);
        connect(self.window, "key-release-event", &keyRelease, self);
    }
    pub fn bindControls(self: *Launcher) void {
        self.search_input = input.Entry.create(self.search, &inputChanged, self) catch @panic("out of memory");
        self.search_input.?.makePublic();
        for ([_]*c.GtkWidget{ self.search, self.grid }) |widget| {
            c.gtk_widget_add_events(widget, c.GDK_BUTTON_PRESS_MASK | c.GDK_BUTTON_RELEASE_MASK | c.GDK_POINTER_MOTION_MASK | c.GDK_LEAVE_NOTIFY_MASK | c.GDK_FOCUS_CHANGE_MASK | c.GDK_SCROLL_MASK | c.GDK_SMOOTH_SCROLL_MASK);
            connect(widget, "draw", &draw, self);
            connect(widget, "button-press-event", &press, self);
            connect(widget, "button-release-event", &release, self);
            connect(widget, "motion-notify-event", &motion, self);
            connect(widget, "leave-notify-event", &leave, self);
            connect(widget, "focus-in-event", &focusChanged, self);
            connect(widget, "focus-out-event", &focusChanged, self);
        }
        connect(self.grid, "scroll-event", &scroll, self);
        connect(self.grid, "size-allocate", &allocated, self);
        connect(self.search, "key-press-event", &searchKey, self);
        connect(self.search, "key-release-event", &searchKeyRelease, self);
        connect(self.window, "hide", &hidden, self);
        connect(self.message, "draw", &draw, self);
    }
    pub fn deinit(self: *Launcher) void {
        for ([_]*c.GtkWidget{ self.window, self.search, self.grid, self.message }) |widget|
            _ = c.g_signal_handlers_disconnect_matched(widget, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
        if (self.search_input) |entry_input| entry_input.destroy();
        c.gtk_widget_destroy(self.window);
        self.freeEntries();
        self.entries.deinit();
        self.visible.deinit();
        self.renderer.deinit();
        self.search_view.deinit();
        allocator.free(self.status);
        c.g_free(self.query);
    }
    fn freeEntries(self: *Launcher) void {
        self.visible.clearRetainingCapacity();
        for (self.entries.items) |item| {
            item.tile.deinit();
            c.g_object_unref(item.info);
            c.g_free(item.folded);
            allocator.destroy(item);
        }
        self.entries.clearRetainingCapacity();
    }
    pub fn reload(self: *Launcher) !void {
        self.freeEntries();
        try self.load();
    }
    pub fn add(self: *Launcher, info: *c.GAppInfo) !void {
        if (c.g_app_info_should_show(info) == 0) return;
        const item = try allocator.create(Entry);
        errdefer allocator.destroy(item);
        item.* = .{ .info = @ptrCast(c.g_object_ref(info)), .name = c.g_app_info_get_display_name(info), .folded = fold(c.g_app_info_get_display_name(info)) };
        errdefer {
            c.g_object_unref(item.info);
            c.g_free(item.folded);
        }
        try self.entries.append(item);
    }
    pub fn load(self: *Launcher) !void {
        const all = c.g_app_info_get_all();
        defer c.g_list_free_full(all, c.g_object_unref);
        var node = all;
        while (node != null) : (node = node.*.next) try self.add(cast(c.GAppInfo, node.*.data));
        self.refresh();
    }
    pub fn first(self: *Launcher) ?*Entry {
        return if (self.visible.items.len > 0) self.visible.items[0] else null;
    }
    pub fn searchText(self: *const Launcher) [:0]const u8 {
        return if (self.search_input) |entry_input| entry_input.buffer.valueZ() else "";
    }
    pub fn setSearch(self: *Launcher, value: []const u8) !void {
        const entry_input = self.search_input orelse return error.NotBound;
        // Validate before clearing, so a rejected update preserves the query.
        var buffer: input.Buffer = .{};
        try buffer.insert(value);
        entry_input.clear();
        try entry_input.insert(value);
    }
    pub fn setMessage(self: *Launcher, value: []const u8) void {
        const owned = allocator.dupeSentinel(u8, value, 0) catch return;
        allocator.free(self.status);
        self.status = owned;
        c.gtk_widget_set_visible(self.message, @intFromBool(value.len != 0));
        c.gtk_widget_queue_draw(self.message);
    }
    pub fn refresh(self: *Launcher) void {
        c.g_free(self.query);
        self.query = fold(self.searchText());
        self.visible.clearRetainingCapacity();
        for (self.entries.items) |item| if (rank(item.folded, self.query) < 2) {
            self.visible.append(item) catch @panic("out of memory");
        };
        std.mem.sort(*Entry, self.visible.items, self.query, struct {
            fn less(query: [*c]u8, left: *Entry, right: *Entry) bool {
                const l = rank(left.folded, query);
                const r = rank(right.folded, query);
                return if (l != r) l < r else c.g_utf8_collate(left.name, right.name) < 0;
            }
        }.less);
        self.page = 0;
        self.selected = 0;
        self.hover = null;
        self.pressed = null;
        self.setMessage("");
        c.gtk_widget_queue_draw(self.grid);
    }
    pub fn focusGrid(self: *Launcher) void {
        self.search_focus = false;
        self.search_input.?.focus(false);
        c.gtk_widget_grab_focus(self.grid);
        c.gtk_widget_queue_draw(self.grid);
    }
    pub fn present(self: *Launcher) void {
        self.setSearch("") catch {};
        c.gtk_widget_show_all(self.window);
        self.refresh();
        self.search_focus = true;
        c.gtk_widget_grab_focus(self.search);
        c.gtk_window_present(cast(c.GtkWindow, self.window));
    }
    fn pageCount(self: *const Launcher) usize {
        return @max(1, std.math.divCeil(usize, self.visible.items.len, self.geometry.capacity()) catch unreachable);
    }
    pub fn changePage(self: *Launcher, direction: i32) void {
        const target = @as(i64, @intCast(self.page)) + direction;
        if (target < 0 or target >= self.pageCount()) return;
        self.page = @intCast(target);
        self.selected = self.page * self.geometry.capacity();
        self.hover = null;
        self.pressed = null;
        c.gtk_widget_queue_draw(self.grid);
    }
    pub fn launch(self: *Launcher, info: *c.GAppInfo) bool {
        const context = c.gdk_display_get_app_launch_context(c.gtk_widget_get_display(self.window));
        defer c.g_object_unref(context);
        c.gdk_app_launch_context_set_timestamp(context, c.gtk_get_current_event_time());
        var err: [*c]c.GError = null;
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        var ok = false;
        const desktop = cast(c.GDesktopAppInfo, info);
        if (c.g_type_check_instance_is_a(cast(c.GTypeInstance, info), c.g_desktop_app_info_get_type()) != 0 and
            c.g_desktop_app_info_get_filename(desktop) != null and c.g_desktop_app_info_get_boolean(desktop, "Terminal") != 0)
        {
            if (terminalArgs(arena.allocator(), desktop)) |args| {
                const directory = c.g_desktop_app_info_get_string(desktop, "Path");
                defer c.g_free(directory);
                ok = c.g_spawn_async(if (directory != null and directory[0] != 0) directory else null, @ptrCast(args.items.ptr), null, c.G_SPAWN_SEARCH_PATH, null, null, null, &err) != 0;
            } else |_| {}
        } else {
            ok = c.g_app_info_launch(info, null, cast(c.GAppLaunchContext, context), &err) != 0;
        }
        if (ok) {
            c.gtk_widget_hide(self.window);
        } else {
            self.setMessage(if (err != null) std.mem.span(err.*.message) else "Could not launch application");
        }
        if (err != null) c.g_error_free(err);
        return ok;
    }
};
fn inputChanged(data: ?*anyopaque) void {
    const self = cast(Launcher, data);
    const hash = std.hash.Wyhash.hash(0, self.searchText());
    if (self.search_hash != hash) {
        self.search_hash = hash;
        self.refresh();
        if (self.on_search) |callback| callback(self.search_context);
    }
    c.gtk_widget_queue_draw(self.search);
}
fn focusChanged(widget: *c.GtkWidget, _: *c.GdkEvent, data: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast(Launcher, data);
    self.search_focus = c.gtk_widget_has_focus(self.search) != 0;
    self.search_input.?.focus(self.search_focus);
    self.pressed = null;
    c.gtk_widget_queue_draw(widget);
    c.gtk_widget_queue_draw(self.grid);
    c.gtk_widget_queue_draw(self.search);
    return 0;
}
fn hidden(_: *c.GtkWidget, data: ?*anyopaque) callconv(.c) void {
    const self = cast(Launcher, data);
    self.search_input.?.focus(false);
    self.pressed = null;
    self.hover = null;
}
fn allocated(_: *c.GtkWidget, allocation: *c.GtkAllocation, data: ?*anyopaque) callconv(.c) void {
    const self = cast(Launcher, data);
    self.geometry = view.Grid.init(@intCast(@max(1, allocation.width)), @intCast(@max(1, allocation.height)));
    self.page = self.selected / self.geometry.capacity();
    self.hover = null;
    self.pressed = null;
}
fn searchKey(_: *c.GtkWidget, event: *c.GdkEvent, data: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast(Launcher, data);
    if (self.search_input.?.filter(event)) return 1;
    var symbol: c.guint = 0;
    var modifiers: c.GdkModifierType = 0;
    _ = c.gdk_event_get_keyval(event, &symbol);
    _ = c.gdk_event_get_state(event, &modifiers);
    // Navigation and Escape bubble to the containing overview.
    if (symbol == c.GDK_KEY_Escape or symbol == c.GDK_KEY_Down or symbol == c.GDK_KEY_Return or symbol == c.GDK_KEY_KP_Enter or symbol == 0xff09) return 0;
    return @intFromBool(enterKey(self, symbol, modifiers));
}
fn enterKey(self: *Launcher, symbol: u32, modifiers: c.GdkModifierType) bool {
    const entry_input = self.search_input.?;
    if (entry_input.key(symbol, modifiers)) return true;
    const unicode = c.gdk_keyval_to_unicode(symbol);
    if (modifiers & (c.GDK_CONTROL_MASK | c.GDK_MOD1_MASK | c.GDK_SUPER_MASK) != 0 or unicode < 32 or unicode == 127) return false;
    var bytes: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(unicode), &bytes) catch return false;
    entry_input.insert(bytes[0..len]) catch {};
    return true;
}
fn searchKeyRelease(_: *c.GtkWidget, event: *c.GdkEvent, data: ?*anyopaque) callconv(.c) c.gboolean {
    return @intFromBool(cast(Launcher, data).search_input.?.filter(event));
}
pub fn keyRelease(_: ?*c.GtkWidget, event: *KeyEvent, data: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast(Launcher, data);
    if (self.search_focus) return @intFromBool(self.search_input.?.filter(@ptrCast(event)));
    return 0;
}
pub fn keyPress(_: ?*c.GtkWidget, event: *KeyEvent, data: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast(Launcher, data);
    const symbol = event.keyval;
    if (symbol == c.GDK_KEY_Escape) {
        c.gtk_widget_hide(self.window);
        return 1;
    }
    if (symbol == c.GDK_KEY_Return or symbol == c.GDK_KEY_KP_Enter) {
        if (self.selected < self.visible.items.len) _ = self.launch(self.visible.items[self.selected].info);
        return 1;
    }
    if (symbol == 0xff56 or symbol == 0xff55) {
        self.changePage(if (symbol == 0xff56) 1 else -1);
        return 1;
    }
    if (symbol == 0xff09 or symbol == 0xfe20) {
        if (self.search_focus and symbol == 0xff09 and event.state & c.GDK_SHIFT_MASK == 0) self.focusGrid() else {
            c.gtk_widget_grab_focus(self.search);
            self.search_focus = true;
            self.search_input.?.focus(true);
        }
        return 1;
    }
    if (self.search_focus and symbol == c.GDK_KEY_Down) {
        self.focusGrid();
        return 1;
    }
    if (!self.search_focus and self.visible.items.len > 0) {
        const cols: i64 = @intCast(self.geometry.columns);
        const delta: i64 = if (symbol == c.GDK_KEY_Left) -1 else if (symbol == c.GDK_KEY_Right) 1 else if (symbol == c.GDK_KEY_Up) -cols else if (symbol == c.GDK_KEY_Down) cols else 0;
        if (delta != 0 or symbol == 0xff50 or symbol == 0xff57) {
            const next: i64 = if (symbol == 0xff50) 0 else if (symbol == 0xff57) @intCast(self.visible.items.len - 1) else @as(i64, @intCast(self.selected)) + delta;
            if (next < 0 and symbol == c.GDK_KEY_Up) {
                c.gtk_widget_grab_focus(self.search);
                self.search_focus = true;
                self.search_input.?.focus(true);
            } else self.selected = @intCast(std.math.clamp(next, 0, @as(i64, @intCast(self.visible.items.len - 1))));
            self.page = self.selected / self.geometry.capacity();
            self.hover = null;
            c.gtk_widget_queue_draw(self.grid);
            return 1;
        }
    }
    if (event.state & (c.GDK_CONTROL_MASK | c.GDK_MOD1_MASK | c.GDK_SUPER_MASK) == 0 and (symbol == c.GDK_KEY_BackSpace or c.gdk_keyval_to_unicode(symbol) >= 32)) {
        self.search_focus = true;
        c.gtk_widget_grab_focus(self.search);
        self.search_input.?.focus(true);
        if (self.search_input.?.filter(@ptrCast(event))) return 1;
        return @intFromBool(enterKey(self, symbol, event.state));
    }
    return 0;
}
fn press(widget: *c.GtkWidget, event: *c.GdkEventButton, data: ?*anyopaque) callconv(.c) c.gboolean {
    if (event.button != 1) return 0;
    const self = cast(Launcher, data);
    if (widget == self.search) {
        c.gtk_widget_grab_focus(self.search);
        self.search_focus = true;
        self.search_input.?.focus(true);
        if (event.x > @as(f64, @floatFromInt(c.gtk_widget_get_allocated_width(self.search))) - 32 and self.searchText().len > 0) {
            self.setSearch("") catch {};
        } else {
            self.search_input.?.buffer.cursor = searchPoint(self, event.x);
            if (event.state & c.GDK_SHIFT_MASK == 0) self.search_input.?.buffer.anchor = self.search_input.?.buffer.cursor;
            self.search_input.?.revision += 1;
            self.search_input.?.dragging = true;
            inputChanged(self);
        }
    } else {
        self.focusGrid();
        const g = self.geometry;
        if (event.y > g.height - 40) {
            const count = self.pageCount();
            const x = (g.width - @as(f64, @floatFromInt(count * 34))) / 2;
            const index: i64 = @intFromFloat(@floor((event.x - x) / 34));
            if (index >= 0 and index < count) self.changePage(@intCast(index - @as(i64, @intCast(self.page))));
        } else if (event.x < g.width * 0.1) self.changePage(-1) else if (event.x >= g.width * 0.9) self.changePage(1) else if (g.hit(event.x, event.y)) |slot| {
            const index = self.page * g.capacity() + slot;
            if (index < self.visible.items.len) {
                self.selected = index;
                self.pressed = index;
            }
        }
    }
    c.gtk_widget_queue_draw(widget);
    return 1;
}
fn release(widget: *c.GtkWidget, event: *c.GdkEventButton, data: ?*anyopaque) callconv(.c) c.gboolean {
    if (event.button != 1) return 0;
    const self = cast(Launcher, data);
    self.search_input.?.dragging = false;
    const pressed = self.pressed;
    self.pressed = null;
    if (widget == self.grid) if (self.geometry.hit(event.x, event.y)) |slot| {
        const index = self.page * self.geometry.capacity() + slot;
        if (pressed == index and index < self.visible.items.len) _ = self.launch(self.visible.items[index].info);
    };
    c.gtk_widget_queue_draw(widget);
    return 1;
}
fn motion(widget: *c.GtkWidget, event: *c.GdkEventMotion, data: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast(Launcher, data);
    if (widget == self.search) {
        self.search_hover = true;
        if (self.search_input.?.dragging) {
            self.search_input.?.buffer.cursor = searchPoint(self, event.x);
            self.search_input.?.revision += 1;
            inputChanged(self);
        }
    } else {
        const slot = self.geometry.hit(event.x, event.y);
        const index = if (slot) |i| self.page * self.geometry.capacity() + i else self.visible.items.len;
        self.hover = if (index < self.visible.items.len) index else null;
        c.gtk_widget_set_tooltip_text(self.grid, if (self.hover) |i| self.visible.items[i].name else null);
    }
    c.gtk_widget_queue_draw(widget);
    return 1;
}
fn leave(widget: *c.GtkWidget, _: *c.GdkEvent, data: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast(Launcher, data);
    if (widget == self.search) self.search_hover = false else self.hover = null;
    c.gtk_widget_queue_draw(widget);
    return 0;
}
fn scroll(_: *c.GtkWidget, event: *c.GdkEvent, data: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast(Launcher, data);
    var direction: c.GdkScrollDirection = 0;
    if (c.gdk_event_get_scroll_direction(event, &direction) == 0) return 0;
    if (direction == 4) {
        var x: f64 = 0;
        var y: f64 = 0;
        _ = c.gdk_event_get_scroll_deltas(event, &x, &y);
        const time: u32 = @truncate(@as(u64, @intCast(@divTrunc(c.g_get_monotonic_time(), 1000))));
        if (time -% self.wheel_time > 200) self.wheel = 0;
        self.wheel_time = time;
        self.wheel += if (@abs(x) > @abs(y)) x else y;
        if (@abs(self.wheel) >= 1) {
            self.changePage(if (self.wheel > 0) 1 else -1);
            self.wheel = 0;
        }
    } else self.changePage(if (direction == 1 or direction == 3) 1 else -1);
    return 1;
}
fn searchPoint(self: *Launcher, x: f64) usize {
    // Use shaped prefix advances, so proportional fonts and CJK hit correctly.
    const value = self.searchText();
    var previous: f64 = 0;
    var offset: usize = 0;
    while (offset < value.len) {
        const next = offset + (std.unicode.utf8ByteSequenceLength(value[offset]) catch 1);
        const advance = view.measure(&self.renderer, value[0..next], 1) catch previous;
        if (x - 41 + self.search_offset < (previous + advance) / 2) return offset;
        previous = advance;
        offset = next;
    }
    return value.len;
}
fn draw(widget: *c.GtkWidget, cr: *c.cairo_t, data: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast(Launcher, data);
    const width: u32 = @intCast(@max(1, c.gtk_widget_get_allocated_width(widget)));
    const height: u32 = @intCast(@max(1, c.gtk_widget_get_allocated_height(widget)));
    const scale: u32 = @intCast(@max(1, c.gtk_widget_get_scale_factor(widget)));
    const image = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, @intCast(width * scale), @intCast(height * scale));
    defer c.cairo_surface_destroy(image);
    if (c.cairo_surface_status(image) != 0) return 1;
    const pixels: [*]u32 = @ptrCast(@alignCast(c.cairo_image_surface_get_data(image)));
    const target: raster.Buffer = .{ .pixels = pixels[0 .. width * height * scale * scale], .width = width * scale, .height = height * scale };
    @memset(target.pixels, 0xff222226);
    if (widget == self.search) {
        view.paintSearch(target, scale, &self.renderer, &self.search_view, self.search_input.?, self.search_hover, &self.search_offset) catch {};
    } else if (widget == self.message) {
        view.centerText(target, scale, &self.renderer, self.status, 0xb6b6b9) catch {};
    } else {
        const canvas: raster.Canvas = .{ .target = target, .scale = @floatFromInt(scale) };
        if (self.visible.items.len == 0) view.centerText(target, scale, &self.renderer, "No applications found", 0xb6b6b9) catch {};
        const start = self.page * self.geometry.capacity();
        const end = @min(self.visible.items.len, start + self.geometry.capacity());
        for (start..@max(start, end)) |i| {
            const item = self.visible.items[i];
            const focused = c.gtk_widget_has_focus(self.grid) != 0 and self.selected == i;
            // GNOME marks the default search result selected while the entry
            // retains focus; the keyboard focus ring belongs to the grid only.
            const selected = self.search_focus and self.query[0] != 0 and self.selected == i;
            item.tile.paint(canvas, scale, &self.renderer, item.name, c.g_app_info_get_icon(item.info), self.geometry.tile(i - start), self.geometry.icon_size, self.hover == i, focused, selected, self.pressed == i) catch {};
        }
        view.paintPages(canvas, self.geometry, self.page, self.pageCount());
    }
    c.cairo_surface_mark_dirty(image);
    c.cairo_surface_set_device_scale(image, @floatFromInt(scale), @floatFromInt(scale));
    c.cairo_set_source_surface(cr, image, 0, 0);
    c.cairo_paint(cr);
    return 1;
}
pub fn activate(app: ?*c.GtkApplication, data: ?*anyopaque) callconv(.c) void {
    const state = cast(?Launcher, data);
    if (state.* == null) {
        state.* = Launcher.init(app);
        state.*.?.bind();
        // Closing the window hides it; repeated activation toggles one instance.
        connect(state.*.?.window, "delete-event", &close, null);
    }
    const self = &state.*.?;
    if (c.gtk_widget_get_visible(self.window) != 0) {
        c.gtk_widget_hide(self.window);
    } else {
        self.reload() catch |err| std.log.err("loading applications: {s}", .{@errorName(err)});
        self.present();
    }
}
fn close(widget: ?*c.GtkWidget, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) c.gboolean {
    c.gtk_widget_hide(widget);
    return 1;
}

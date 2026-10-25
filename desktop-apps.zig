//! Minimal GNOME-style application grid, using the desktop's GTK/GIO stack.
const std = @import("std");
pub const c = @import("gtk");
// GTK event unions contain C bitfields that Zig 0.14 cannot translate.
pub const KeyEvent = extern struct {
    event_type: c_int,
    window: ?*anyopaque,
    send_event: i8,
    time: u32,
    state: c_uint,
    keyval: c_uint,
};
extern fn gtk_widget_event(widget: *c.GtkWidget, event: *anyopaque) c.gboolean;
fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}
fn connect(widget: anytype, signal: [*:0]const u8, callback: anytype, data: anytype) void {
    _ = c.g_signal_connect_data(widget, signal, @ptrCast(callback), data, null, 0);
}
pub const style =
    \\window#desktop-apps { background: #2e2e33; color: white; font-family: "Adwaita Sans"; font-size: 11pt; }
    \\#desktop-apps entry { background: #45454b; color: white; border: 1px solid rgba(255,255,255,0.12); border-radius: 999px; padding: 12px 20px; min-width: 280px; box-shadow: none; }
    \\#desktop-apps entry:focus { border-color: #78aeed; }
    \\#desktop-apps flowboxchild { background: transparent; color: white; border: none; border-radius: 24px; padding: 16px; outline: none; }
    \\#desktop-apps flowboxchild:hover, #desktop-apps flowboxchild:selected { background: rgba(255,255,255,0.10); }
    \\#desktop-apps flowboxchild:focus { box-shadow: inset 0 0 0 2px #78aeed; }
    \\#desktop-apps flowboxchild:active { background: rgba(255,255,255,0.18); }
    \\#desktop-apps scrolledwindow, #desktop-apps viewport { background: transparent; border: none; }
    \\#desktop-apps .message { color: #b6b6b9; padding: 24px; }
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
const Entry = struct {
    info: *c.GAppInfo,
    name: [*c]const u8,
    folded: [*c]u8,
};
fn entry(child: *c.GtkFlowBoxChild) *Entry {
    return cast(Entry, c.g_object_get_data(@ptrCast(child), "entry"));
}

pub const Launcher = struct {
    window: *c.GtkWidget,
    layout: *c.GtkWidget,
    results: *c.GtkWidget,
    search: *c.GtkEntry,
    grid: *c.GtkFlowBox,
    empty: *c.GtkWidget,
    message: *c.GtkLabel,
    entries: std.array_list.Managed(*Entry),
    query: [*c]u8,

    pub fn init(application: ?*c.GtkApplication) Launcher {
        const window = if (application) |app| c.gtk_application_window_new(app) else c.gtk_window_new(c.GTK_WINDOW_TOPLEVEL);
        c.gtk_widget_set_name(window, "desktop-apps");
        c.gtk_window_set_title(cast(c.GtkWindow, window), "Applications");
        c.gtk_window_set_decorated(cast(c.GtkWindow, window), 0);
        c.gtk_window_set_skip_taskbar_hint(cast(c.GtkWindow, window), 1);
        c.gtk_window_set_skip_pager_hint(cast(c.GtkWindow, window), 1);
        c.gtk_window_set_default_size(cast(c.GtkWindow, window), 1040, 720);
        c.gtk_window_maximize(cast(c.GtkWindow, window));
        const provider = c.gtk_css_provider_new();
        defer c.g_object_unref(provider);
        var css_error: [*c]c.GError = null;
        if (c.gtk_css_provider_load_from_data(provider, style, style.len, &css_error) == 0) {
            std.log.err("launcher CSS: {s}", .{css_error.*.message});
            c.g_error_free(css_error);
        }
        c.gtk_style_context_add_provider_for_screen(c.gtk_widget_get_screen(window), @ptrCast(provider), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
        const layout = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_container_add(cast(c.GtkContainer, window), layout);
        const search = c.gtk_search_entry_new();
        c.gtk_entry_set_placeholder_text(cast(c.GtkEntry, search), "Type to search");
        c.gtk_widget_set_halign(search, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_margin_top(search, 32);
        c.gtk_widget_set_margin_bottom(search, 32);
        c.gtk_box_pack_start(cast(c.GtkBox, layout), search, 0, 0, 0);
        const scroll = c.gtk_scrolled_window_new(null, null);
        c.gtk_scrolled_window_set_policy(cast(c.GtkScrolledWindow, scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_box_pack_start(cast(c.GtkBox, layout), scroll, 1, 1, 0);
        const content = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_halign(content, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_margin_start(content, 24);
        c.gtk_widget_set_margin_end(content, 24);
        c.gtk_container_add(cast(c.GtkContainer, scroll), content);
        const grid = c.gtk_flow_box_new();
        c.gtk_flow_box_set_homogeneous(cast(c.GtkFlowBox, grid), 1);
        c.gtk_flow_box_set_min_children_per_line(cast(c.GtkFlowBox, grid), 1);
        c.gtk_flow_box_set_max_children_per_line(cast(c.GtkFlowBox, grid), 6);
        c.gtk_flow_box_set_column_spacing(cast(c.GtkFlowBox, grid), 24);
        c.gtk_flow_box_set_row_spacing(cast(c.GtkFlowBox, grid), 24);
        c.gtk_flow_box_set_selection_mode(cast(c.GtkFlowBox, grid), c.GTK_SELECTION_SINGLE);
        c.gtk_flow_box_set_activate_on_single_click(cast(c.GtkFlowBox, grid), 1);
        c.gtk_flow_box_set_vadjustment(cast(c.GtkFlowBox, grid), c.gtk_scrolled_window_get_vadjustment(cast(c.GtkScrolledWindow, scroll)));
        c.gtk_box_pack_start(cast(c.GtkBox, content), grid, 0, 0, 0);
        const empty = c.gtk_label_new("No applications found");
        c.gtk_style_context_add_class(c.gtk_widget_get_style_context(empty), "message");
        c.gtk_widget_set_no_show_all(empty, 1);
        c.gtk_box_pack_start(cast(c.GtkBox, content), empty, 0, 0, 0);
        const message = c.gtk_label_new("");
        c.gtk_label_set_line_wrap(cast(c.GtkLabel, message), 1);
        c.gtk_style_context_add_class(c.gtk_widget_get_style_context(message), "message");
        c.gtk_widget_set_no_show_all(message, 1);
        c.gtk_box_pack_end(cast(c.GtkBox, layout), message, 0, 0, 0);
        return .{ .window = window.?, .layout = layout.?, .results = scroll.?, .search = cast(c.GtkEntry, search), .grid = cast(c.GtkFlowBox, grid), .empty = empty.?, .message = cast(c.GtkLabel, message), .entries = std.array_list.Managed(*Entry).init(std.heap.c_allocator), .query = fold("") };
    }

    // Bind after init: callbacks retain this stable address.
    pub fn bind(self: *Launcher) void {
        self.bindControls();
        connect(self.window, "key-press-event", &keyPress, self);
    }
    pub fn bindControls(self: *Launcher) void {
        c.gtk_flow_box_set_filter_func(self.grid, filter, self, null);
        c.gtk_flow_box_set_sort_func(self.grid, sort, self, null);
        connect(self.search, "changed", &changed, self);
        connect(self.search, "activate", &searchActivate, self);
        connect(self.grid, "child-activated", &activateChild, self);
    }
    pub fn deinit(self: *Launcher) void {
        c.gtk_widget_destroy(self.window);
        self.freeEntries();
        self.entries.deinit();
        c.g_free(self.query);
    }
    fn freeEntries(self: *Launcher) void {
        for (self.entries.items) |item| {
            c.g_object_unref(item.info);
            c.g_free(item.folded);
            std.heap.c_allocator.destroy(item);
        }
        self.entries.clearRetainingCapacity();
    }
    pub fn reload(self: *Launcher) !void {
        const children = c.gtk_container_get_children(@ptrCast(self.grid));
        defer c.g_list_free(children);
        var node = children;
        while (node != null) : (node = node.*.next) c.gtk_widget_destroy(@ptrCast(@alignCast(node.*.data)));
        self.freeEntries();
        try self.load();
    }
    pub fn add(self: *Launcher, info: *c.GAppInfo) !void {
        if (c.g_app_info_should_show(info) == 0) return;
        const item = try std.heap.c_allocator.create(Entry);
        errdefer std.heap.c_allocator.destroy(item);
        item.* = .{ .info = @ptrCast(c.g_object_ref(info)), .name = c.g_app_info_get_display_name(info), .folded = fold(c.g_app_info_get_display_name(info)) };
        errdefer {
            c.g_object_unref(item.info);
            c.g_free(item.folded);
        }
        try self.entries.append(item);
        const child = c.gtk_flow_box_child_new();
        c.g_object_set_data(@ptrCast(child), "entry", item);
        const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 12);
        const icon = c.g_app_info_get_icon(info);
        const image = if (icon != null) c.gtk_image_new_from_gicon(icon, c.GTK_ICON_SIZE_DIALOG) else c.gtk_image_new_from_icon_name("application-x-executable", c.GTK_ICON_SIZE_DIALOG);
        c.gtk_image_set_pixel_size(cast(c.GtkImage, image), 96);
        c.gtk_box_pack_start(cast(c.GtkBox, box), image, 0, 0, 0);
        const label = c.gtk_label_new(item.name);
        c.gtk_label_set_max_width_chars(cast(c.GtkLabel, label), 14);
        c.gtk_label_set_width_chars(cast(c.GtkLabel, label), 14);
        c.gtk_label_set_ellipsize(cast(c.GtkLabel, label), c.PANGO_ELLIPSIZE_END);
        c.gtk_box_pack_start(cast(c.GtkBox, box), label, 0, 0, 0);
        c.gtk_widget_set_tooltip_text(child, item.name);
        c.gtk_container_add(cast(c.GtkContainer, child), box);
        c.gtk_flow_box_insert(self.grid, child, -1);
    }
    pub fn load(self: *Launcher) !void {
        const apps = c.g_app_info_get_all();
        defer c.g_list_free_full(apps, @ptrCast(&c.g_object_unref));
        var node = apps;
        while (node != null) : (node = node.*.next) try self.add(cast(c.GAppInfo, node.*.data));
    }
    pub fn first(self: *Launcher) ?*c.GtkFlowBoxChild {
        var i: c_int = 0;
        while (c.gtk_flow_box_get_child_at_index(self.grid, i)) |child| : (i += 1) {
            if (rank(entry(child).folded, self.query) < 2) return child;
        }
        return null;
    }
    pub fn refresh(self: *Launcher) void {
        c.g_free(self.query);
        self.query = fold(c.gtk_entry_get_text(self.search));
        c.gtk_flow_box_invalidate_filter(self.grid);
        c.gtk_flow_box_invalidate_sort(self.grid);
        c.gtk_flow_box_unselect_all(self.grid);
        if (self.first()) |child| c.gtk_flow_box_select_child(self.grid, child);
        c.gtk_widget_set_visible(self.empty, @intFromBool(self.first() == null));
        c.gtk_widget_hide(@ptrCast(self.message));
    }
    pub fn present(self: *Launcher) void {
        c.gtk_entry_set_text(self.search, "");
        c.gtk_widget_show_all(self.window);
        self.refresh();
        c.gtk_widget_grab_focus(@ptrCast(self.search));
        c.gtk_window_present(cast(c.GtkWindow, self.window));
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
            c.gtk_label_set_text(self.message, if (err != null) err.*.message else "Could not launch application");
            c.gtk_widget_show(@ptrCast(self.message));
        }
        if (err != null) c.g_error_free(err);
        return ok;
    }
};
fn filter(child: ?*c.GtkFlowBoxChild, data: ?*anyopaque) callconv(.c) c.gboolean {
    return @intFromBool(rank(entry(child.?).folded, cast(Launcher, data).query) < 2);
}
fn sort(a: ?*c.GtkFlowBoxChild, b: ?*c.GtkFlowBoxChild, data: ?*anyopaque) callconv(.c) c_int {
    const query = cast(Launcher, data).query;
    const left = entry(a.?);
    const right = entry(b.?);
    const delta = @as(c_int, rank(left.folded, query)) - @as(c_int, rank(right.folded, query));
    return if (delta != 0) delta else c.g_utf8_collate(left.name, right.name);
}
fn changed(_: ?*c.GtkEditable, data: ?*anyopaque) callconv(.c) void {
    cast(Launcher, data).refresh();
}
fn searchActivate(_: ?*c.GtkEntry, data: ?*anyopaque) callconv(.c) void {
    const self = cast(Launcher, data);
    if (self.first()) |child| _ = self.launch(entry(child).info);
}
fn activateChild(_: ?*c.GtkFlowBox, child: ?*c.GtkFlowBoxChild, data: ?*anyopaque) callconv(.c) void {
    _ = cast(Launcher, data).launch(entry(child.?).info);
}
pub fn keyPress(_: ?*c.GtkWidget, event: *KeyEvent, data: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast(Launcher, data);
    if (event.*.keyval == c.GDK_KEY_Escape) {
        c.gtk_widget_hide(self.window);
        return 1;
    }
    const searching = c.gtk_widget_has_focus(@ptrCast(self.search)) != 0;
    if (searching and event.*.keyval == c.GDK_KEY_Down) {
        if (self.first()) |child| c.gtk_widget_grab_focus(@ptrCast(child));
        return 1;
    }
    if (!searching and event.*.state & (c.GDK_CONTROL_MASK | c.GDK_MOD1_MASK | c.GDK_SUPER_MASK) == 0 and
        (event.*.keyval == c.GDK_KEY_BackSpace or c.gdk_keyval_to_unicode(event.*.keyval) >= 32))
    {
        c.gtk_widget_grab_focus(@ptrCast(self.search));
        _ = gtk_widget_event(@ptrCast(self.search), event);
        return 1;
    }
    return 0;
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
pub fn main() void {
    // Also provides a stable Wayland app_id for compositor window rules.
    c.g_set_prgname("org.dotfiles.DesktopApps");
    const app = c.gtk_application_new("org.dotfiles.DesktopApps", c.G_APPLICATION_DEFAULT_FLAGS);
    defer c.g_object_unref(app);
    var state: ?Launcher = null;
    defer if (state) |*self| self.deinit();
    connect(app, "activate", &activate, &state);
    const status = c.g_application_run(@ptrCast(app), 0, null);
    if (status != 0) std.process.exit(@intCast(status));
}

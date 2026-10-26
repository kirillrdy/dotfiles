//! Activities: live window previews, workspace navigation, search and app grid.
const std = @import("std");
comptime {
    _ = @import("protocols");
}
const apps = @import("apps");
const capture = @import("desktop-capture.zig");
const c = capture.c;
const a = std.heap.page_allocator;
fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}
fn connect(widget: anytype, signal: [*:0]const u8, callback: anytype, data: anytype) void {
    _ = c.g_signal_connect_data(widget, signal, @ptrCast(callback), data, null, 0);
}
const Rect = capture.Rect;
const style =
    \\window#desktop-apps { background: #222226; color: white; }
    \\#desktop-apps entry { min-width: 352px; min-height: 19px; padding: 8px; border: 1px solid transparent; border-radius: 999px; background: #404045; font-size: 14.666px; }
    \\#desktop-apps entry:focus { border-color: #78aeed; }
    \\#desktop-apps .overview-dash { background: #38383b; border-radius: 28px; padding: 12px 10px; }
    \\#desktop-apps .overview-dash button { min-width: 76px; min-height: 76px; margin: 0 2px; padding: 0; background: transparent; color: white; border: none; border-radius: 20px; box-shadow: none; text-shadow: none; }
    \\#desktop-apps .overview-dash separator { min-width: 1px; background: rgba(255,255,255,0.1); margin: 6px 4px; }
    \\#desktop-apps .overview-dash button:hover, #desktop-apps .overview-dash button:checked { background: rgba(255,255,255,0.1); }
    \\#desktop-apps .overview-dash button:focus { box-shadow: inset 0 0 0 2px #78aeed; }
;

const Overview = struct {
    launcher: apps.Launcher,
    client: ?*capture.Client = null,
    strip: *c.GtkWidget,
    stage: *c.GtkWidget,
    dash: *c.GtkWidget,
    wallpaper: ?*c.GdkPixbuf,
    timer: c.guint = 0,
    tick_count: u32 = 0,
    apps_mode: bool = false,
    selected: usize = 0,
    hover: ?usize = null,
    drag: ?*capture.Window = null,
    drag_x: f64 = 0,
    drag_y: f64 = 0,
    dragging: bool = false,
    started: i64 = 0,
    dash_hash: u64 = 0,
    workspace_from: f64 = 0,
    workspace_target: u32 = 0,
    workspace_started: i64 = 0,
    workspace_rect: Rect = .{},
    monitor: c.GdkRectangle = .{ .x = 0, .y = 0, .width = 1728, .height = 1080 },

    fn create(application: *c.GtkApplication, path: [*:0]const u8) *Overview {
        const self = a.create(Overview) catch @panic("out of memory");
        self.* = .{ .launcher = apps.Launcher.init(application), .strip = c.gtk_drawing_area_new().?, .stage = c.gtk_drawing_area_new().?, .dash = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0).?, .wallpaper = c.gdk_pixbuf_new_from_file(path, null) };
        const l = &self.launcher;
        l.bindControls();
        const window = cast(c.GtkWindow, l.window);
        c.gtk_window_unmaximize(window);
        c.gtk_window_set_title(window, "Activities");
        c.gtk_layer_init_for_window(window);
        c.gtk_layer_set_namespace(window, "desktop-overview");
        c.gtk_layer_set_layer(window, c.GTK_LAYER_SHELL_LAYER_OVERLAY);
        c.gtk_layer_set_exclusive_zone(window, 0);
        c.gtk_layer_set_keyboard_mode(window, c.GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE);
        for ([_]c.GtkLayerShellEdge{ c.GTK_LAYER_SHELL_EDGE_TOP, c.GTK_LAYER_SHELL_EDGE_BOTTOM, c.GTK_LAYER_SHELL_EDGE_LEFT, c.GTK_LAYER_SHELL_EDGE_RIGHT }) |edge| c.gtk_layer_set_anchor(window, edge, 1);
        const provider = c.gtk_css_provider_new();
        _ = c.gtk_css_provider_load_from_data(provider, style, style.len, null);
        c.gtk_style_context_add_provider_for_screen(c.gtk_widget_get_screen(l.window), cast(c.GtkStyleProvider, provider), c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1);
        c.g_object_unref(provider);
        c.gtk_widget_set_margin_top(@ptrCast(l.search), 12);
        c.gtk_widget_set_margin_bottom(@ptrCast(l.search), 6);
        c.gtk_widget_set_size_request(self.strip, -1, 64);
        c.gtk_box_pack_start(cast(c.GtkBox, l.layout), self.strip, 0, 0, 0);
        c.gtk_box_reorder_child(cast(c.GtkBox, l.layout), self.strip, 1);
        c.gtk_widget_set_margin_top(self.stage, 9);
        c.gtk_widget_set_can_focus(self.stage, 1);
        c.gtk_widget_set_margin_bottom(self.stage, 21);
        c.gtk_box_pack_start(cast(c.GtkBox, l.layout), self.stage, 1, 1, 0);
        c.gtk_box_reorder_child(cast(c.GtkBox, l.layout), self.stage, 2);
        c.gtk_widget_set_halign(self.dash, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_margin_bottom(self.dash, 12);
        c.gtk_style_context_add_class(c.gtk_widget_get_style_context(self.dash), "overview-dash");
        c.gtk_box_pack_end(cast(c.GtkBox, l.layout), self.dash, 0, 0, 0);
        c.gtk_widget_add_events(self.stage, c.GDK_BUTTON_PRESS_MASK | c.GDK_BUTTON_RELEASE_MASK | c.GDK_POINTER_MOTION_MASK | c.GDK_LEAVE_NOTIFY_MASK | c.GDK_SCROLL_MASK | c.GDK_SMOOTH_SCROLL_MASK);
        c.gtk_widget_add_events(self.strip, c.GDK_BUTTON_PRESS_MASK | c.GDK_SCROLL_MASK | c.GDK_SMOOTH_SCROLL_MASK);
        connect(self.stage, "draw", &drawStage, self);
        connect(self.strip, "draw", &drawStrip, self);
        connect(self.stage, "motion-notify-event", &motion, self);
        connect(self.stage, "leave-notify-event", &leave, self);
        connect(self.stage, "button-press-event", &press, self);
        connect(self.stage, "button-release-event", &release, self);
        connect(self.strip, "button-press-event", &workspaceClick, self);
        connect(self.stage, "scroll-event", &scroll, self);
        connect(self.strip, "scroll-event", &scroll, self);
        connect(l.search, "changed", &searchChanged, self);
        connect(l.search, "stop-search", &escape, self);
        connect(l.window, "key-press-event", &key, self);
        connect(l.window, "key-release-event", &keyRelease, self);
        connect(l.window, "hide", &hidden, self);
        connect(l.window, "delete-event", &closeWindow, self);
        self.client = capture.Client.create(self, &changed) catch null;
        return self;
    }
    fn destroy(self: *Overview) void {
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        self.timer = 0;
        if (self.client) |client| client.destroy();
        self.client = null;
        self.launcher.deinit();
        if (self.wallpaper) |image| c.g_object_unref(image);
        a.destroy(self);
    }
    fn present(self: *Overview) void {
        if (self.timer == 0) self.timer = c.g_timeout_add(33, &tick, self);
        if (self.client == null) self.client = capture.Client.create(self, &changed) catch null;
        const display = c.gdk_display_get_default();
        const seat = c.gdk_display_get_default_seat(display);
        var x: c_int = 0;
        var y: c_int = 0;
        c.gdk_device_get_position(c.gdk_seat_get_pointer(seat), null, &x, &y);
        const monitor = c.gdk_display_get_monitor_at_point(display, x, y);
        c.gdk_monitor_get_geometry(monitor, &self.monitor);
        c.gtk_layer_set_monitor(cast(c.GtkWindow, self.launcher.window), monitor);
        self.apps_mode = false;
        self.selected = 0;
        self.hover = null;
        self.launcher.reload() catch |err| std.log.err("loading applications: {s}", .{@errorName(err)});
        c.gtk_flow_box_set_max_children_per_line(self.launcher.grid, @intCast(@max(1, @divTrunc(self.monitor.width - 160, 170))));
        c.gtk_entry_set_text(self.launcher.search, "");
        self.started = c.g_get_monotonic_time();
        if (self.client) |client| {
            client.visible(true);
            client.refresh();
            client.tick();
        }
        self.rebuildDash();
        c.gtk_widget_show_all(self.launcher.window);
        self.updateMode();
        c.gtk_widget_grab_focus(self.stage);
        c.gtk_window_present(cast(c.GtkWindow, self.launcher.window));
    }
    fn updateMode(self: *Overview) void {
        const searching = c.gtk_entry_get_text(self.launcher.search)[0] != 0;
        c.gtk_widget_set_visible(self.launcher.results, @intFromBool(self.apps_mode or searching));
        c.gtk_widget_set_visible(self.stage, @intFromBool(!self.apps_mode and !searching));
        c.gtk_widget_hide(@ptrCast(self.launcher.message));
        if (self.client == null or !self.client.?.connected) {
            c.gtk_label_set_text(self.launcher.message, "The Activities overview requires the updated Labwc compositor. Log out and back in after switching the configuration.");
            c.gtk_widget_show(@ptrCast(self.launcher.message));
        }
    }
    fn rebuildDash(self: *Overview) void {
        const children = c.gtk_container_get_children(cast(c.GtkContainer, self.dash));
        defer c.g_list_free(children);
        var child = children;
        while (child != null) : (child = child.*.next) c.gtk_widget_destroy(cast(c.GtkWidget, child.*.data));
        var favorites: [*c][*c]u8 = null;
        if (c.g_settings_schema_source_get_default()) |source| {
            if (c.g_settings_schema_source_lookup(source, "org.gnome.shell", 1)) |schema| {
                defer c.g_settings_schema_unref(schema);
                if (c.g_settings_schema_has_key(schema, "favorite-apps") != 0) {
                    const settings = c.g_settings_new_full(schema, null, null);
                    defer c.g_object_unref(settings);
                    favorites = c.g_settings_get_strv(settings, "favorite-apps");
                }
            }
        }
        defer c.g_strfreev(favorites);
        var favorite_index: usize = 0;
        while (favorites != null and favorites[favorite_index] != null) : (favorite_index += 1) {
            const id = favorites[favorite_index];
            const info = c.g_desktop_app_info_new(id) orelse continue;
            defer c.g_object_unref(info);
            var running: ?*capture.Window = null;
            if (self.client) |client| for (client.windows.items) |window| if (matchesApp(window.app_id, id)) {
                running = window;
                break;
            };
            self.appendDash(@ptrCast(info), running);
        }
        var separated = favorites == null or favorites[0] == null;
        if (self.client) |client| for (client.windows.items, 0..) |window, i| {
            var duplicate = false;
            for (client.windows.items[0..i]) |previous| if (c.g_strcmp0(previous.app_id, window.app_id) == 0) {
                duplicate = true;
                break;
            };
            favorite_index = 0;
            while (favorites != null and favorites[favorite_index] != null) : (favorite_index += 1) if (matchesApp(window.app_id, favorites[favorite_index])) {
                duplicate = true;
                break;
            };
            if (!duplicate) {
                if (!separated) {
                    const separator = c.gtk_separator_new(c.GTK_ORIENTATION_VERTICAL);
                    c.gtk_box_pack_start(cast(c.GtkBox, self.dash), separator, 0, 0, 0);
                    separated = true;
                }
                self.appendDash(null, window);
            }
        };
        const show_apps = c.gtk_button_new();
        const icon = c.gtk_image_new_from_icon_name("view-app-grid-symbolic", c.GTK_ICON_SIZE_DIALOG);
        c.gtk_image_set_pixel_size(cast(c.GtkImage, icon), 64);
        c.gtk_container_add(cast(c.GtkContainer, show_apps), icon);
        c.gtk_widget_set_tooltip_text(show_apps, "Show Applications");
        connect(show_apps, "clicked", &toggleApps, self);
        c.gtk_box_pack_end(cast(c.GtkBox, self.dash), show_apps, 0, 0, 0);
        c.gtk_widget_show_all(self.dash);
    }
    fn appendDash(self: *Overview, info: ?*c.GAppInfo, window: ?*capture.Window) void {
        const button = c.gtk_button_new();
        c.gtk_widget_set_tooltip_text(button, if (info != null) c.g_app_info_get_display_name(info) else if (window) |w| w.title else "Application");
        const box = c.gtk_overlay_new();
        const image = if (window) |w| c.gtk_image_new_from_pixbuf(w.icon) else c.gtk_image_new_from_gicon(c.g_app_info_get_icon(info), c.GTK_ICON_SIZE_DIALOG);
        c.gtk_image_set_pixel_size(cast(c.GtkImage, image), 64);
        c.gtk_widget_set_halign(image, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_valign(image, c.GTK_ALIGN_CENTER);
        c.gtk_container_add(cast(c.GtkContainer, box), image);
        if (window != null) {
            const dot = c.gtk_drawing_area_new();
            c.gtk_widget_set_size_request(dot, 5, 5);
            c.gtk_widget_set_halign(dot, c.GTK_ALIGN_CENTER);
            c.gtk_widget_set_valign(dot, c.GTK_ALIGN_END);
            connect(dot, "draw", &drawRunningDot, self);
            c.gtk_overlay_add_overlay(cast(c.GtkOverlay, box), dot);
            c.gtk_overlay_set_overlay_pass_through(cast(c.GtkOverlay, box), dot, 1);
        }
        c.gtk_container_add(cast(c.GtkContainer, button), box);
        if (window) |w| c.g_object_set_data_full(cast(c.GObject, button), "window-id", c.g_strdup(w.id), &c.g_free);
        if (info) |app| c.g_object_set_data_full(cast(c.GObject, button), "app-info", c.g_object_ref(app), &c.g_object_unref);
        connect(button, "clicked", &dashActivate, self);
        c.gtk_box_pack_start(cast(c.GtkBox, self.dash), button, 0, 0, 0);
    }
    fn drawRunningDot(_: *c.GtkWidget, cr: *c.cairo_t, _: c.gpointer) callconv(.c) c.gboolean {
        c.cairo_arc(cr, 2.5, 2.5, 2.5, 0, 2 * std.math.pi);
        c.cairo_set_source_rgb(cr, 1, 1, 1);
        c.cairo_fill(cr);
        return 1;
    }
    fn changed(data: ?*anyopaque) void {
        const self = cast(Overview, data);
        c.gtk_widget_queue_draw(self.stage);
        c.gtk_widget_queue_draw(self.strip);
        if (self.client) |client| {
            if (client.current != self.workspace_target) {
                self.workspace_from = self.workspacePosition();
                self.workspace_target = client.current;
                self.workspace_started = c.g_get_monotonic_time();
            }
            if (self.drag) |drag| {
                var found = false;
                for (client.windows.items) |window| if (window == drag) {
                    found = true;
                    break;
                };
                if (!found) {
                    self.drag = null;
                    self.dragging = false;
                }
            }
            if (self.selected >= client.windows.items.len or (client.windows.items[self.selected].workspace != client.current and !client.windows.items[self.selected].sticky)) {
                self.selected = 0;
                for (client.windows.items, 0..) |window, i| if (window.workspace == client.current or window.sticky) {
                    self.selected = i;
                    break;
                };
            }
            var hash = std.hash.Wyhash.init(0);
            for (client.windows.items) |window| {
                if (window.id != null) hash.update(std.mem.span(window.id));
                if (window.app_id != null) hash.update(std.mem.span(window.app_id));
            }
            const value = hash.final();
            if (value != self.dash_hash) {
                self.dash_hash = value;
                self.rebuildDash();
            }
        }
    }
    fn tick(data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Overview, data);
        if (c.gtk_widget_get_visible(self.launcher.window) == 0) return 1;
        self.tick_count +%= 1;
        if (self.client) |client| {
            if (self.tick_count % 8 == 0) client.refresh();
            client.tick();
        }
        return 1;
    }
    fn hidden(_: *c.GtkWidget, data: c.gpointer) callconv(.c) void {
        const self = cast(Overview, data);
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        self.timer = 0;
        if (self.client) |client| client.visible(false);
    }
    fn closeWindow(widget: *c.GtkWidget, _: ?*anyopaque, _: c.gpointer) callconv(.c) c.gboolean {
        c.gtk_widget_hide(widget);
        return 1;
    }
    fn searchChanged(_: ?*c.GtkEditable, data: c.gpointer) callconv(.c) void {
        cast(Overview, data).updateMode();
    }
    fn escape(_: ?*c.GtkSearchEntry, data: c.gpointer) callconv(.c) void {
        const self = cast(Overview, data);
        if (c.gtk_entry_get_text(self.launcher.search)[0] != 0) c.gtk_entry_set_text(self.launcher.search, "") else if (self.apps_mode) {
            self.apps_mode = false;
            self.updateMode();
        } else c.gtk_widget_hide(self.launcher.window);
        if (!self.apps_mode and c.gtk_widget_get_visible(self.launcher.window) != 0) c.gtk_widget_grab_focus(self.stage);
    }
    fn toggleApps(_: *c.GtkButton, data: c.gpointer) callconv(.c) void {
        const self = cast(Overview, data);
        self.apps_mode = !self.apps_mode;
        c.gtk_entry_set_text(self.launcher.search, "");
        self.updateMode();
        if (self.apps_mode) {
            if (self.launcher.first()) |child| c.gtk_widget_grab_focus(@ptrCast(child));
        } else c.gtk_widget_grab_focus(self.stage);
    }
    fn dashActivate(button: *c.GtkButton, data: c.gpointer) callconv(.c) void {
        const self = cast(Overview, data);
        const id: [*c]const u8 = @ptrCast(c.g_object_get_data(cast(c.GObject, button), "window-id"));
        if (id != null) if (self.client) |client| for (client.windows.items) |window| if (c.g_strcmp0(window.id, id) == 0) {
            client.activate(window);
            c.gtk_widget_hide(self.launcher.window);
            return;
        };
        if (c.g_object_get_data(cast(c.GObject, button), "app-info")) |info| _ = self.launcher.launch(cast(c.GAppInfo, info));
    }
    fn key(_: ?*c.GtkWidget, event: *apps.KeyEvent, data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Overview, data);
        if (event.keyval == c.GDK_KEY_Escape) {
            escape(null, data);
            return 1;
        }
        if (event.keyval == c.GDK_KEY_Page_Up or event.keyval == c.GDK_KEY_Page_Down or (event.state & c.GDK_CONTROL_MASK != 0 and (event.keyval == c.GDK_KEY_Left or event.keyval == c.GDK_KEY_Right))) {
            const direction: i32 = if (event.keyval == c.GDK_KEY_Page_Up or event.keyval == c.GDK_KEY_Left) -1 else 1;
            if (event.state & c.GDK_SHIFT_MASK != 0) {
                if (self.client) |client| {
                    const target = @as(i64, client.current) + direction;
                    if (self.selected < client.windows.items.len and target >= 0 and target < client.count) client.move(client.windows.items[self.selected], @intCast(target));
                }
            } else self.stepWorkspace(direction);
            return 1;
        }
        if (!self.apps_mode and c.gtk_entry_get_text(self.launcher.search)[0] == 0) {
            if (event.keyval == c.GDK_KEY_Return or event.keyval == c.GDK_KEY_KP_Enter) {
                if (self.client) |client| if (self.selected < client.windows.items.len and (client.windows.items[self.selected].workspace == client.current or client.windows.items[self.selected].sticky)) {
                    client.activate(client.windows.items[self.selected]);
                    c.gtk_widget_hide(self.launcher.window);
                };
                return 1;
            }
            const direction: i32 = if (event.keyval == c.GDK_KEY_Left or event.keyval == c.GDK_KEY_Up) -1 else if (event.keyval == c.GDK_KEY_Right or event.keyval == c.GDK_KEY_Down) 1 else 0;
            if (direction != 0) {
                self.selectNext(direction);
                return 1;
            }
        }
        return apps.keyPress(null, event, &self.launcher);
    }
    fn keyRelease(_: ?*c.GtkWidget, event: *apps.KeyEvent, data: c.gpointer) callconv(.c) c.gboolean {
        if (event.keyval == c.GDK_KEY_Super_L or event.keyval == c.GDK_KEY_Super_R) {
            c.gtk_widget_hide(cast(Overview, data).launcher.window);
            return 1;
        }
        return 0;
    }
    fn selectNext(self: *Overview, direction: i32) void {
        const client = self.client orelse return;
        const count = client.windows.items.len;
        if (count == 0) return;
        var index = @min(self.selected, count - 1);
        for (0..count) |_| {
            index = if (direction > 0) (index + 1) % count else (index + count - 1) % count;
            const window = client.windows.items[index];
            if (window.workspace == client.current or window.sticky) {
                self.selected = index;
                self.hover = index;
                break;
            }
        }
        c.gtk_widget_queue_draw(self.stage);
    }
    fn stepWorkspace(self: *Overview, direction: i32) void {
        const client = self.client orelse return;
        const index = @as(i64, client.current) + direction;
        if (index >= 0 and index < client.count) {
            client.switchWorkspace(@intCast(index));
            self.started = c.g_get_monotonic_time() - 250000;
            self.hover = null;
        }
    }
    fn scroll(_: *c.GtkWidget, event: *c.GdkEvent, data: c.gpointer) callconv(.c) c.gboolean {
        var direction: c.GdkScrollDirection = 0;
        if (c.gdk_event_get_scroll_direction(event, &direction) != 0) cast(Overview, data).stepWorkspace(if (direction == c.GDK_SCROLL_UP or direction == c.GDK_SCROLL_LEFT) -1 else 1);
        return 1;
    }
    fn workspaceAt(self: *Overview, x: f64) ?u32 {
        const client = self.client orelse return null;
        const left = (@as(f64, @floatFromInt(c.gtk_widget_get_allocated_width(self.strip))) - @as(f64, @floatFromInt(client.count)) * 72 + 6) / 2;
        const index = @floor((x - left + 3) / 72);
        if (index < 0 or index >= @as(f64, @floatFromInt(client.count))) return null;
        return @intFromFloat(index);
    }
    fn workspaceClick(_: *c.GtkWidget, event: *c.GdkEventButton, data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Overview, data);
        if (self.workspaceAt(event.x)) |index| if (self.client) |client| client.switchWorkspace(index);
        return 1;
    }
    fn hit(self: *Overview, x: f64, y: f64) ?usize {
        const client = self.client orelse return null;
        for (client.windows.items, 0..) |w, i| {
            if (w.workspace != client.current and !w.sticky) continue;
            const r = w.target;
            if (x >= r.x - 16 and x <= r.x + r.w + 16 and y >= r.y - 16 and y <= r.y + r.h + 16) return i;
        }
        return null;
    }
    fn motion(_: *c.GtkWidget, event: *c.GdkEventMotion, data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Overview, data);
        self.hover = self.hit(event.x, event.y);
        if (self.drag != null and (@abs(event.x - self.drag_x) > 8 or @abs(event.y - self.drag_y) > 8)) self.dragging = true;
        c.gtk_widget_queue_draw(self.stage);
        return 1;
    }
    fn leave(_: *c.GtkWidget, _: *c.GdkEventCrossing, data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Overview, data);
        if (!self.dragging) self.hover = null;
        c.gtk_widget_queue_draw(self.stage);
        return 0;
    }
    fn press(_: *c.GtkWidget, event: *c.GdkEventButton, data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Overview, data);
        self.drag = if (self.hit(event.x, event.y)) |i| self.client.?.windows.items[i] else null;
        self.drag_x = event.x;
        self.drag_y = event.y;
        self.dragging = false;
        return 1;
    }
    fn release(_: *c.GtkWidget, event: *c.GdkEventButton, data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Overview, data);
        const client = self.client orelse return 1;
        defer {
            self.drag = null;
            self.dragging = false;
        }
        if (self.drag) |window| {
            const r = window.target;
            if (self.dragging) {
                if (event.y < 0) if (self.workspaceAt(event.x)) |index| client.move(window, index);
            } else if (event.button == 2 or (event.x > r.x + r.w - 16 and event.y < r.y + 16)) client.close(window) else if (event.button == 1) {
                client.activate(window);
                c.gtk_widget_hide(self.launcher.window);
            }
        } else if (event.button == 1) {
            if (event.x > self.workspace_rect.x + self.workspace_rect.w + 50) self.stepWorkspace(1) else if (event.x < self.workspace_rect.x - 50) self.stepWorkspace(-1) else c.gtk_widget_hide(self.launcher.window);
        }
        return 1;
    }
    fn drawStrip(widget: *c.GtkWidget, cr: *c.cairo_t, data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Overview, data);
        const client = self.client orelse return 1;
        const width: f64 = @floatFromInt(c.gtk_widget_get_allocated_width(widget));
        const left = (width - @as(f64, @floatFromInt(client.count)) * 72 + 6) / 2;
        for (0..client.count) |i| {
            const x = left + @as(f64, @floatFromInt(i)) * 72;
            const rect = Rect{ .x = x, .y = 19, .w = 66, .h = 40 };
            if (i == client.current) {
                rounded(cr, .{ .x = x - 3, .y = 16, .w = 72, .h = 46 }, 8);
                c.cairo_set_source_rgb(cr, 0.208, 0.518, 0.894);
                c.cairo_fill(cr);
            }
            rounded(cr, rect, 3);
            c.cairo_set_source_rgb(cr, 70.0 / 255.0, 70.0 / 255.0, 78.0 / 255.0);
            c.cairo_fill(cr);
            for (client.windows.items) |window| {
                if (window.workspace != i and !window.sticky) continue;
                const g = window.geometry;
                const sx = 66 / @as(f64, @floatFromInt(self.monitor.width));
                const sy = 40 / @as(f64, @floatFromInt(self.monitor.height - 32));
                const r = Rect{ .x = x + (g.x - @as(f64, @floatFromInt(self.monitor.x))) * sx, .y = 19 + (g.y - @as(f64, @floatFromInt(self.monitor.y + 32))) * sy, .w = g.w * sx, .h = g.h * sy };
                c.cairo_save(cr);
                c.cairo_rectangle(cr, x, 19, 66, 40);
                c.cairo_clip(cr);
                drawImage(cr, window.image, r, 1);
                c.cairo_restore(cr);
            }
        }
        return 1;
    }
    fn workspacePosition(self: *Overview) f64 {
        const t = std.math.clamp(@as(f64, @floatFromInt(c.g_get_monotonic_time() - self.workspace_started)) / 250000, 0, 1);
        const ease = 1 - (1 - t) * (1 - t) * (1 - t);
        return self.workspace_from + (@as(f64, @floatFromInt(self.workspace_target)) - self.workspace_from) * ease;
    }
    fn drawStage(widget: *c.GtkWidget, cr: *c.cairo_t, data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Overview, data);
        const client = self.client orelse return 1;
        const width: f64 = @floatFromInt(c.gtk_widget_get_allocated_width(widget));
        const height: f64 = @floatFromInt(c.gtk_widget_get_allocated_height(widget));
        const scale = @min(width * 0.73 / @as(f64, @floatFromInt(self.monitor.width)), (height - 24) / @as(f64, @floatFromInt(self.monitor.height - 32)));
        const base = Rect{ .x = (width - @as(f64, @floatFromInt(self.monitor.width)) * scale) / 2, .y = 12, .w = @as(f64, @floatFromInt(self.monitor.width)) * scale, .h = @as(f64, @floatFromInt(self.monitor.height - 32)) * scale };
        self.workspace_rect = base;
        const t = std.math.clamp(@as(f64, @floatFromInt(c.g_get_monotonic_time() - self.started)) / 250000, 0, 1);
        const ease = 1 - (1 - t) * (1 - t) * (1 - t);
        const position = self.workspacePosition();
        for (0..client.count) |i| {
            const offset = @as(f64, @floatFromInt(i)) - position;
            const ratio = 1 - 0.06 * @min(1, @abs(offset));
            var background = Rect{ .x = width / 2 + offset * (base.w + 64) - base.w * ratio / 2, .y = 12 + (base.h - base.h * ratio) / 2, .w = base.w * ratio, .h = base.h * ratio };
            if (background.x > width or background.x + background.w < 0) continue;
            if (i == client.current and t < 1) {
                background.x *= ease;
                background.y = -128 + (background.y + 128) * ease;
                background.w = width + (background.w - width) * ease;
                background.h = @as(f64, @floatFromInt(self.monitor.height - 32)) + (background.h - @as(f64, @floatFromInt(self.monitor.height - 32))) * ease;
            }
            self.drawWorkspace(cr, background);
            self.drawWindows(cr, client, @intCast(i), background, height, ratio, if (i == client.current) ease else 1);
        }
        if (t < 1 or c.g_get_monotonic_time() - self.workspace_started < 250000) c.gtk_widget_queue_draw(widget);
        return 1;
    }
    fn drawWindows(self: *Overview, cr: *c.cairo_t, client: *capture.Client, workspace_index: u32, background: Rect, height: f64, ratio: f64, ease: f64) void {
        var count: usize = 0;
        for (client.windows.items) |window| if (window.workspace == workspace_index or window.sticky) {
            count += 1;
        };
        if (count == 0) return;
        const columns: usize = @intFromFloat(@ceil(@sqrt(@as(f64, @floatFromInt(count)))));
        const rows = (count + columns - 1) / columns;
        const cell_w = (background.w - 168 * ratio - @as(f64, @floatFromInt(columns - 1)) * 32 * ratio) / @as(f64, @floatFromInt(columns));
        const cell_h = (height * ratio - @as(f64, @floatFromInt(rows - 1)) * 32 * ratio) / @as(f64, @floatFromInt(rows));
        var position: usize = 0;
        for (client.windows.items, 0..) |window, index| {
            if (window.workspace != workspace_index and !window.sticky) continue;
            const row = position / columns;
            const col = position % columns;
            const in_row = @min(columns, count - row * columns);
            const factor = @min(cell_w / window.geometry.w, cell_h / window.geometry.h);
            const w = window.geometry.w * factor;
            const h = window.geometry.h * factor;
            const x = background.x + 84 * ratio + (@as(f64, @floatFromInt(columns - in_row)) * (cell_w + 32 * ratio)) / 2 + @as(f64, @floatFromInt(col)) * (cell_w + 32 * ratio) + (cell_w - w) / 2;
            const y = (height - height * ratio) / 2 + @as(f64, @floatFromInt(row)) * (cell_h + 32 * ratio) + (cell_h - h) / 2;
            if (workspace_index == client.current) window.target = .{ .x = x, .y = y, .w = w, .h = h };
            const start = Rect{ .x = window.geometry.x - @as(f64, @floatFromInt(self.monitor.x)), .y = window.geometry.y - @as(f64, @floatFromInt(self.monitor.y + 160)), .w = window.geometry.w, .h = window.geometry.h };
            const r = Rect{ .x = start.x + (x - start.x) * ease, .y = start.y + (y - start.y) * ease, .w = start.w + (w - start.w) * ease, .h = start.h + (h - start.h) * ease };
            rounded(cr, .{ .x = r.x - 3, .y = r.y - 2, .w = r.w + 6, .h = r.h + 8 }, 9);
            c.cairo_set_source_rgba(cr, 0, 0, 0, 0.3);
            c.cairo_fill(cr);
            c.cairo_save(cr);
            rounded(cr, r, 8);
            c.cairo_clip(cr);
            drawImage(cr, window.image, r, 1);
            c.cairo_restore(cr);
            if (workspace_index == client.current and self.hover == index) {
                rounded(cr, r, 8);
                c.cairo_set_source_rgb(cr, 1, 1, 1);
                c.cairo_set_line_width(cr, 2);
                c.cairo_stroke(cr);
                c.cairo_arc(cr, r.x + r.w, r.y, 16, 0, 2 * std.math.pi);
                c.cairo_set_source_rgb(cr, 0.3, 0.3, 0.33);
                c.cairo_fill(cr);
                c.cairo_set_source_rgb(cr, 1, 1, 1);
                c.cairo_set_line_width(cr, 2);
                c.cairo_move_to(cr, r.x + r.w - 4, r.y - 4);
                c.cairo_line_to(cr, r.x + r.w + 4, r.y + 4);
                c.cairo_move_to(cr, r.x + r.w + 4, r.y - 4);
                c.cairo_line_to(cr, r.x + r.w - 4, r.y + 4);
                c.cairo_stroke(cr);
            }
            if (window.icon) |icon| {
                c.cairo_save(cr);
                c.cairo_translate(cr, r.x + r.w / 2 - 32, r.y + r.h - 44);
                c.cairo_scale(cr, 64 / @as(f64, @floatFromInt(c.gdk_pixbuf_get_width(icon))), 64 / @as(f64, @floatFromInt(c.gdk_pixbuf_get_height(icon))));
                c.gdk_cairo_set_source_pixbuf(cr, icon, 0, 0);
                c.cairo_paint_with_alpha(cr, ease);
                c.cairo_restore(cr);
            }
            position += 1;
        }
    }
    fn drawWorkspace(self: *Overview, cr: *c.cairo_t, r: Rect) void {
        c.cairo_save(cr);
        defer c.cairo_restore(cr);
        rounded(cr, r, 30);
        c.cairo_clip(cr);
        c.cairo_set_source_rgb(cr, 0.015, 0.235, 0.53);
        c.cairo_paint(cr);
        if (self.wallpaper) |image| {
            const iw: f64 = @floatFromInt(c.gdk_pixbuf_get_width(image));
            const ih: f64 = @floatFromInt(c.gdk_pixbuf_get_height(image));
            const scale = @max(r.w / iw, r.h / ih);
            c.cairo_translate(cr, r.x + (r.w - iw * scale) / 2, r.y + (r.h - ih * scale) / 2);
            c.cairo_scale(cr, scale, scale);
            c.gdk_cairo_set_source_pixbuf(cr, image, 0, 0);
            c.cairo_paint(cr);
        }
    }
};
fn matchesApp(app_id: [*c]const u8, desktop_id: [*c]const u8) bool {
    if (app_id == null or desktop_id == null) return false;
    const id = std.mem.span(desktop_id);
    const app = std.mem.span(app_id);
    return std.mem.eql(u8, app, id) or (std.mem.endsWith(u8, id, ".desktop") and std.mem.eql(u8, app, id[0 .. id.len - 8]));
}
fn rounded(cr: *c.cairo_t, r: Rect, radius: f64) void {
    const rad = @max(0, @min(radius, @min(r.w, r.h) / 2));
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, r.x + r.w - rad, r.y + rad, rad, -std.math.pi / 2.0, 0);
    c.cairo_arc(cr, r.x + r.w - rad, r.y + r.h - rad, rad, 0, std.math.pi / 2.0);
    c.cairo_arc(cr, r.x + rad, r.y + r.h - rad, rad, std.math.pi / 2.0, std.math.pi);
    c.cairo_arc(cr, r.x + rad, r.y + rad, rad, std.math.pi, 1.5 * std.math.pi);
    c.cairo_close_path(cr);
}
fn drawImage(cr: *c.cairo_t, image: ?*c.cairo_surface_t, r: Rect, opacity: f64) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_translate(cr, r.x, r.y);
    if (image) |surface| {
        c.cairo_scale(cr, r.w / @as(f64, @floatFromInt(c.cairo_image_surface_get_width(surface))), r.h / @as(f64, @floatFromInt(c.cairo_image_surface_get_height(surface))));
        c.cairo_set_source_surface(cr, surface, 0, 0);
        c.cairo_paint_with_alpha(cr, opacity);
    } else {
        c.cairo_rectangle(cr, 0, 0, r.w, r.h);
        c.cairo_set_source_rgb(cr, 0.3, 0.3, 0.33);
        c.cairo_fill(cr);
    }
}

pub const State = struct { overview: ?*Overview = null, wallpaper: [*:0]const u8 };
pub fn activate(app: *c.GtkApplication, data: c.gpointer) callconv(.c) void {
    const state = cast(State, data);
    if (state.overview == null) state.overview = Overview.create(app, state.wallpaper);
    const self = state.overview.?;
    if (c.gtk_widget_get_visible(self.launcher.window) != 0) c.gtk_widget_hide(self.launcher.window) else self.present();
}
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const args = try init.minimal.args.toSlice(arena.allocator());
    if (args.len != 2) {
        std.debug.print("Usage: desktop-overview WALLPAPER\n", .{});
        return error.InvalidArguments;
    }
    _ = c.g_setenv("GDK_BACKEND", "wayland", 1);
    c.g_set_prgname("org.dotfiles.DesktopOverview");
    const app = c.gtk_application_new("org.dotfiles.DesktopOverview", c.G_APPLICATION_DEFAULT_FLAGS).?;
    defer c.g_object_unref(app);
    var state = State{ .wallpaper = (try arena.allocator().dupeSentinel(u8, args[1], 0)).ptr };
    defer if (state.overview) |self| self.destroy();
    connect(app, "activate", &activate, &state);
    const status = c.g_application_run(cast(c.GApplication, app), 0, null);
    if (status != 0) std.process.exit(@intCast(status));
}

pub fn deinit(state: *State) void {
    if (state.overview) |self| self.destroy();
    state.overview = null;
}

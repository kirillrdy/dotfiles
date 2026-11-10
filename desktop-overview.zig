//! Activities: live window previews, workspace navigation, search and app grid.
const wire = @import("desktop-surface.zig");
const std = @import("std");
comptime {
    _ = @import("desktop-protocols.zig");
}
const apps = @import("desktop-apps.zig");
const capture = @import("desktop-capture.zig");
const native_dash = @import("desktop-dash-view.zig");
const raster = @import("desktop-raster.zig");
const view = @import("desktop-overview-view.zig");
const animation = @import("desktop-overview-animation.zig");
const c = capture.c;
const a = std.heap.page_allocator;
const cast = c.__zig.cast;
const Rect = capture.Rect;
const Part = enum { search, grid, stage, strip, dash, tooltip };
const Pointer = struct { x: f64, y: f64, button: u32 = 1 };

const Overview = struct {
    launcher: apps.Launcher,
    client: ?*capture.Client = null,
    native: *wire.Client,
    surface: ?*wire.Surface,
    strip: apps.Region = .{ .y = 55, .width = 1728, .height = 64 },
    stage: apps.Region = .{ .y = 128, .width = 1728, .height = 787 },
    search: apps.Region = .{ .y = 12, .width = 370, .height = 37 },
    grid: apps.Region = .{ .y = 119, .width = 1728, .height = 817 },
    dash: apps.Region = .{ .width = 0, .height = 0 },
    tooltip: apps.Region = .{ .width = 0, .height = 0 },
    tooltip_visible: bool = false,
    focus_part: Part = .stage,
    pointer_part: ?Part = null,
    pressed_part: ?Part = null,
    modifiers: u32 = 0,
    painting: bool = false,
    animating: bool = false,
    repaint_source: c.guint = 0,
    dash_view: native_dash.View = .{},
    tooltip_timer: c.guint = 0,
    wallpaper: ?*c.cairo_surface_t,
    timer: c.guint = 0,
    tick_count: u32 = 0,
    apps_mode: bool = false,
    selected: usize = 0,
    hover: ?usize = null,
    drag: ?*capture.Window = null,
    drag_x: f64 = 0,
    drag_y: f64 = 0,
    dragging: bool = false,
    transition: animation.Transition = .{},
    progress: f64 = 0,
    dash_hash: u64 = 0,
    workspace_from: f64 = 0,
    workspace_target: u32 = 0,
    workspace_started: i64 = 0,
    workspace_rect: Rect = .{},
    monitor: c.GdkRectangle = .{ .x = 0, .y = 0, .width = 1728, .height = 1080 },

    fn create(_: *c.GtkApplication, path: [*:0]const u8) *Overview {
        const self = a.create(Overview) catch @panic("out of memory");
        const native = wire.Client.createInteractive(.{ .added = &outputAdded, .removed = &outputRemoved }, self) catch @panic("native overview connection");
        if (native.outputs.items.len == 0) @panic("overview needs an output");
        var wallpaper: ?*c.cairo_surface_t = null;
        if (c.gdk_pixbuf_new_from_file(path, null)) |pixbuf| {
            defer c.g_object_unref(pixbuf);
            wallpaper = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, c.gdk_pixbuf_get_width(pixbuf), c.gdk_pixbuf_get_height(pixbuf));
            const cr = c.cairo_create(wallpaper);
            defer c.cairo_destroy(cr);
            c.gdk_cairo_set_source_pixbuf(cr, pixbuf, 0, 0);
            c.cairo_paint(cr);
        }
        self.* = .{ .launcher = apps.Launcher.init(null), .native = native, .surface = null, .wallpaper = wallpaper };
        self.surface = self.createSurface(native.outputs.items[0]) catch @panic("native overview surface");
        self.launcher.bindControls();
        self.launcher.owner = self;
        self.launcher.redraw_fn = &redraw;
        self.launcher.hidden_fn = &hidden;
        self.launcher.hide_requested_fn = &hideRequested;
        self.launcher.on_search = &searchChanged;
        self.launcher.search_context = self;
        self.client = capture.Client.create(self, &changed) catch null;
        native.start() catch @panic("native overview input");
        return self;
    }
    fn destroy(self: *Overview) void {
        if (self.repaint_source != 0) _ = c.g_source_remove(self.repaint_source);
        self.repaint_source = 0;
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        self.timer = 0;
        if (self.client) |client| client.destroy();
        self.client = null;
        self.hideTooltip();
        self.native.destroy();
        self.launcher.deinit();
        self.dash_view.deinit();
        if (self.wallpaper) |image| c.cairo_surface_destroy(image);
        a.destroy(self);
    }
    fn present(self: *Overview) void {
        if (self.surface == null) return;
        if (self.launcher.visible_window) {
            if (!self.transition.shown) {
                self.transition.setShown(true, c.g_get_monotonic_time());
                if (self.client) |client| client.visible(true);
                self.focusPart(.stage);
                self.redrawSelf();
            }
            return;
        }
        if (self.timer == 0) self.timer = c.g_timeout_add(33, &tick, self);
        if (self.client == null) self.client = capture.Client.create(self, &changed) catch null;
        // GDK still supplies global pointer coordinates for choosing an output.
        // All overview surfaces and their input live on our native connection.
        const display = c.gdk_display_get_default();
        const seat = c.gdk_display_get_default_seat(display);
        var x: c_int = 0;
        var y: c_int = 0;
        c.gdk_device_get_position(c.gdk_seat_get_pointer(seat), null, &x, &y);
        for (self.native.outputs.items) |output| if (x >= output.x and y >= output.y and x < output.x + output.width() and y < output.y + output.height()) {
            self.surface.?.output = output;
            break;
        };
        const output = self.surface.?.output;
        self.monitor = .{ .x = output.x, .y = output.y, .width = output.width(), .height = output.height() };
        self.apps_mode = false;
        self.selected = 0;
        self.hover = null;
        self.launcher.reload() catch |err| std.log.err("loading applications: {s}", .{@errorName(err)});
        self.launcher.setSearch("") catch {};
        self.transition.setShown(true, c.g_get_monotonic_time());
        if (self.client) |client| {
            client.visible(true);
            client.refresh();
            client.captureMissing();
        }
        self.rebuildDash();
        self.launcher.visible_window = true;
        self.updateMode();
        self.focusPart(.stage);
        self.surface.?.show() catch |err| std.log.err("overview: {s}", .{@errorName(err)});
    }
    fn updateMode(self: *Overview) void {
        self.dash_view.apps_mode = self.apps_mode;
        self.redrawSelf();
        if (self.client == null or !self.client.?.connected) {
            self.launcher.setMessage("The Activities overview requires the updated desktop compositor. Log out and back in after switching the configuration.");
        }
    }
    fn rebuildDash(self: *Overview) void {
        self.hideTooltip();
        self.dash_view.clear();
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
                    self.dash_view.separator = self.dash_view.items.items.len;
                    separated = true;
                }
                self.appendDash(null, window);
            }
        };
        self.dash_view.add("Show Applications", null, null, null) catch @panic("out of memory");
        self.dash_view.items.items[self.dash_view.items.items.len - 1].show_apps = true;
        self.dash_view.relayout(@intCast(@max(1, self.monitor.width)), @intCast(@max(1, self.monitor.height)));
        self.redrawSelf();
    }
    fn appendDash(self: *Overview, info: ?*c.GAppInfo, window: ?*capture.Window) void {
        var app = info;
        if (app == null) if (window) |w| {
            for (self.launcher.entries.items) |candidate| if (matchesApp(w.app_id, c.g_app_info_get_id(candidate.info))) {
                app = candidate.info;
                break;
            };
        };
        const title: [*c]const u8 = if (app) |application| c.g_app_info_get_display_name(application) else if (window) |w| w.title else "Application";
        self.dash_view.add(std.mem.span(title), app, if (window) |w| @ptrCast(w.id) else null, if (window) |w| w.icon else null) catch @panic("out of memory");
    }
    fn hideTooltip(self: *Overview) void {
        if (self.tooltip_timer != 0) _ = c.g_source_remove(self.tooltip_timer);
        self.tooltip_timer = 0;
        self.tooltip_visible = false;
    }
    fn showTooltip(data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Overview, data);
        self.tooltip_timer = 0;
        const index = self.dash_view.hover orelse if (self.dash_view.keyboard_focus) self.dash_view.focus else return 0;
        if (index >= self.dash_view.items.items.len) return 0;
        const scale = self.surface.?.output.scale;
        self.dash_view.prepareTooltip(index, scale) catch return 0;
        const mask = self.dash_view.tooltip_mask.?;
        const width = @divTrunc(mask.logical_width, scale) + 26;
        const height = @divTrunc(mask.logical_height, scale) + 14;
        const rect = self.dash_view.layout.item(index);
        const stage_width: f64 = @floatFromInt(self.surface.?.width);
        const left = (stage_width - @as(f64, @floatFromInt(self.dash_view.layout.width))) / 2 + rect.x + rect.width / 2 - @as(f64, @floatFromInt(width)) / 2;
        self.tooltip = .{ .x = std.math.clamp(left, 8, @max(8, stage_width - @as(f64, @floatFromInt(width)) - 8)), .y = @as(f64, @floatFromInt(self.surface.?.height)) - @as(f64, @floatFromInt(self.dash_view.layout.height + 8 + height)), .width = width, .height = height };
        self.tooltip_visible = true;
        self.redrawSelf();
        return 0;
    }
    fn dashPress(_: ?*anyopaque, event: *Pointer, data: c.gpointer) callconv(.c) c.gboolean {
        if (event.button != 1) return 0;
        const self = cast(Overview, data);
        self.hideTooltip();
        self.focusPart(.dash);
        self.dash_view.keyboard_focus = false;
        self.dash_view.pressed = self.dash_view.layout.hit(event.x, event.y);
        self.redrawSelf();
        return 1;
    }
    fn dashRelease(_: ?*anyopaque, event: *Pointer, data: c.gpointer) callconv(.c) c.gboolean {
        if (event.button != 1) return 0;
        const self = cast(Overview, data);
        const pressed = self.dash_view.pressed;
        self.dash_view.pressed = null;
        if (pressed) |index| if (self.dash_view.layout.hit(event.x, event.y) == index) self.activateDash(index);
        self.redrawSelf();
        return 1;
    }

    fn hoverDash(self: *Overview, x: f64, y: f64) void {
        const index = self.dash_view.layout.hit(x, y);
        if (index != self.dash_view.hover) {
            self.hideTooltip();
            self.dash_view.hover = index;
            if (index != null) self.tooltip_timer = c.g_timeout_add(300, &showTooltip, self);
            self.redrawSelf();
        }
    }
    fn dashLeave(_: ?*anyopaque, _: ?*Pointer, data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Overview, data);
        self.hideTooltip();
        self.dash_view.hover = null;
        if (self.dash_view.keyboard_focus) self.tooltip_timer = c.g_timeout_add(300, &showTooltip, self);
        self.redrawSelf();
        return 0;
    }

    fn changed(data: ?*anyopaque) void {
        const self = cast(Overview, data);
        defer self.redrawSelf();
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
        if (!self.launcher.visible_window) return 1;
        // Existing previews are sufficient during the short transition. Avoid
        // capture readbacks competing with high-refresh animation frames.
        const now = c.g_get_monotonic_time();
        if (self.transition.active(now) or !self.transition.shown or now - self.workspace_started < 250000) return 1;
        self.tick_count +%= 1;
        if (self.client) |client| {
            if (self.tick_count % 8 == 0) client.refresh();
            client.tick();
        }
        return 1;
    }
    fn hideRequested(data: ?*anyopaque) bool {
        const self = cast(Overview, data);
        // App-grid/search transitions are separate from the window picker.
        if (self.apps_mode or self.launcher.searchText().len != 0 or self.surface == null or self.surface.?.role == null) return false;
        const now = c.g_get_monotonic_time();
        if (!self.transition.shown) return self.transition.active(now);
        if (self.transition.value(now) == 0) return false;
        self.transition.setShown(false, now);
        self.hideTooltip();
        self.hover = null;
        self.drag = null;
        self.dragging = false;
        self.launcher.search_input.?.focus(false);
        if (self.client) |client| client.visible(false);
        self.redrawSelf();
        return true;
    }
    fn hidden(data: ?*anyopaque) void {
        const self = cast(Overview, data);
        self.transition.setShown(false, c.g_get_monotonic_time());
        self.transition.finish();
        self.hideTooltip();
        self.dash_view.hover = null;
        self.dash_view.pressed = null;
        self.dash_view.keyboard_focus = false;
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        self.timer = 0;
        if (self.repaint_source != 0) _ = c.g_source_remove(self.repaint_source);
        self.repaint_source = 0;
        if (self.client) |client| client.visible(false);
        if (self.surface) |surface| surface.hide();
    }
    fn searchChanged(data: ?*anyopaque) void {
        cast(Overview, data).updateMode();
    }
    fn escape(_: ?*anyopaque, data: c.gpointer) callconv(.c) void {
        const self = cast(Overview, data);
        if (self.launcher.searchText().len != 0) self.launcher.setSearch("") catch {} else if (self.apps_mode) {
            self.apps_mode = false;
            self.updateMode();
        } else self.launcher.hide();
        if (!self.apps_mode and self.launcher.visible_window) self.focusPart(.stage);
    }
    fn toggleApps(self: *Overview) void {
        self.apps_mode = !self.apps_mode;
        self.launcher.setSearch("") catch {};
        self.updateMode();
        if (self.apps_mode) {
            self.focusPart(.grid);
        } else self.focusPart(.stage);
    }
    fn activateDash(self: *Overview, index: usize) void {
        if (index >= self.dash_view.items.items.len) return;
        self.hideTooltip();
        const item = self.dash_view.items.items[index];
        if (item.show_apps) {
            self.toggleApps();
            return;
        }
        if (item.window_id) |id| if (self.client) |client| for (client.windows.items) |window| if (c.g_strcmp0(window.id, id) == 0) {
            client.activate(window);
            self.launcher.hide();
            return;
        };
        if (item.app) |app| _ = self.launcher.launch(app);
    }
    fn key(_: ?*anyopaque, event: *apps.KeyEvent, data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Overview, data);
        if (event.keyval == c.GDK_KEY_Escape) {
            escape(null, data);
            return 1;
        }
        const dash_focused = self.focus_part == .dash;
        const window_mode = !self.apps_mode and self.launcher.searchText().len == 0;
        if (event.keyval == 0xff09 or event.keyval == 0xfe20) {
            const backwards = event.keyval == 0xfe20 or event.state & c.GDK_SHIFT_MASK != 0;
            const search_focused = self.focus_part == .search;
            if ((search_focused and backwards) or (!search_focused and !dash_focused and !backwards)) {
                self.hideTooltip();
                self.focusPart(.dash);
                self.dash_view.keyboard_focus = true;
            } else if ((dash_focused and backwards) or (search_focused and !backwards)) {
                if (window_mode) self.focusPart(.stage) else self.focusPart(.grid);
            } else self.focusPart(.search);
            if (self.focus_part == .dash) {
                self.hideTooltip();
                self.tooltip_timer = c.g_timeout_add(300, &showTooltip, self);
            }
            self.redrawSelf();
            return 1;
        }
        if (dash_focused) {
            switch (event.keyval) {
                c.GDK_KEY_Left, c.GDK_KEY_Right => self.dash_view.navigate(if (event.keyval == c.GDK_KEY_Left) -1 else 1),
                0xff50 => {
                    self.dash_view.focus = 0;
                    self.dash_view.keyboard_focus = true;
                },
                0xff57 => {
                    self.dash_view.focus = self.dash_view.items.items.len -| 1;
                    self.dash_view.keyboard_focus = true;
                },
                c.GDK_KEY_Return, c.GDK_KEY_KP_Enter, 0x20 => self.activateDash(self.dash_view.focus),
                c.GDK_KEY_Up => {
                    if (window_mode) self.focusPart(.stage) else self.focusPart(.grid);
                },
                else => return apps.keyPress(null, event, &self.launcher),
            }
            self.hideTooltip();
            if (self.dash_view.keyboard_focus and self.focus_part == .dash)
                self.tooltip_timer = c.g_timeout_add(300, &showTooltip, self);
            self.redrawSelf();
            return 1;
        }
        if ((window_mode and (event.keyval == c.GDK_KEY_Page_Up or event.keyval == c.GDK_KEY_Page_Down)) or (event.state & c.GDK_CONTROL_MASK != 0 and (event.keyval == c.GDK_KEY_Left or event.keyval == c.GDK_KEY_Right))) {
            const direction: i32 = if (event.keyval == c.GDK_KEY_Page_Up or event.keyval == c.GDK_KEY_Left) -1 else 1;
            if (event.state & c.GDK_SHIFT_MASK != 0) {
                if (self.client) |client| {
                    const target = @as(i64, client.current) + direction;
                    if (self.selected < client.windows.items.len and target >= 0 and target < client.count) client.move(client.windows.items[self.selected], @intCast(target));
                }
            } else self.stepWorkspace(direction);
            return 1;
        }
        if (!self.apps_mode and self.launcher.searchText().len == 0) {
            if (event.keyval == c.GDK_KEY_Return or event.keyval == c.GDK_KEY_KP_Enter) {
                if (self.client) |client| if (self.selected < client.windows.items.len and (client.windows.items[self.selected].workspace == client.current or client.windows.items[self.selected].sticky)) {
                    client.activate(client.windows.items[self.selected]);
                    self.launcher.hide();
                };
                return 1;
            }
            const direction: i32 = if (event.keyval == c.GDK_KEY_Left or event.keyval == c.GDK_KEY_Up) -1 else if (event.keyval == c.GDK_KEY_Right or event.keyval == c.GDK_KEY_Down) 1 else 0;
            if (direction != 0) {
                self.selectNext(direction);
                return 1;
            }
        }
        return self.launcherKey(event);
    }
    fn keyRelease(_: ?*anyopaque, event: *apps.KeyEvent, data: c.gpointer) callconv(.c) c.gboolean {
        if (event.keyval == c.GDK_KEY_Super_L or event.keyval == c.GDK_KEY_Super_R) {
            const self = cast(Overview, data);
            if (self.transition.shown) self.launcher.hide() else self.present();
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
        self.redrawSelf();
    }
    fn stepWorkspace(self: *Overview, direction: i32) void {
        const client = self.client orelse return;
        const index = @as(i64, client.current) + direction;
        if (index >= 0 and index < client.count) {
            client.switchWorkspace(@intCast(index));
            self.transition.finish();
            self.hover = null;
        }
    }
    fn workspaceAt(self: *Overview, x: f64) ?u32 {
        const client = self.client orelse return null;
        const left = (@as(f64, @floatFromInt(self.strip.width)) - @as(f64, @floatFromInt(client.count)) * 72 + 6) / 2;
        const index = @floor((x - left + 3) / 72);
        if (index < 0 or index >= @as(f64, @floatFromInt(client.count))) return null;
        return @intFromFloat(index);
    }
    fn workspaceClick(_: ?*anyopaque, event: *Pointer, data: c.gpointer) callconv(.c) c.gboolean {
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
    fn motion(_: ?*anyopaque, event: *Pointer, data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Overview, data);
        self.hover = self.hit(event.x, event.y);
        if (self.drag != null and (@abs(event.x - self.drag_x) > 8 or @abs(event.y - self.drag_y) > 8)) self.dragging = true;
        self.redrawSelf();
        return 1;
    }

    fn press(_: ?*anyopaque, event: *Pointer, data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Overview, data);
        self.drag = if (self.hit(event.x, event.y)) |i| self.client.?.windows.items[i] else null;
        self.drag_x = event.x;
        self.drag_y = event.y;
        self.dragging = false;
        return 1;
    }
    fn release(_: ?*anyopaque, event: *Pointer, data: c.gpointer) callconv(.c) c.gboolean {
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
                self.launcher.hide();
            }
        } else if (event.button == 1) {
            if (event.x > self.workspace_rect.x + self.workspace_rect.w + 50) self.stepWorkspace(1) else if (event.x < self.workspace_rect.x - 50) self.stepWorkspace(-1) else self.launcher.hide();
        }
        return 1;
    }
    fn createSurface(self: *Overview, output: *wire.Output) !*wire.Surface {
        const surface = try wire.Surface.createPixels(output, .{ .namespace = "desktop-overview", .layer = 3, .anchors = wire.top | wire.bottom | wire.left | wire.right, .keyboard = .exclusive, .exclusive_zone = 0, .interactive = true, .cursor = .arrow, .clear_buffer = false }, &paint, self);
        surface.close = &closed;
        surface.next_frame = &nextFrame;
        surface.render_scale = &renderScale;
        surface.input = .{ .symbol = &symbol, .text = &inputText, .motion = &inputMotion, .button = &inputButton, .scroll = &inputScroll, .leave = &inputLeave, .focus = &inputFocus, .surrounding = &surrounding, .preedit = &preedit, .commit = &commit, .delete = &delete };
        return surface;
    }
    fn nextFrame(data: ?*anyopaque, surface: *wire.Surface, _: u32) bool {
        const self = cast(Overview, data);
        if (self.launcher.visible_window and !self.transition.shown and self.progress == 0) {
            self.launcher.hide();
            return false;
        }
        // The last animated paint requests one more frame, which finishes the
        // transition and restores full-quality filtering before going idle.
        return self.launcher.visible_window and (self.animating or surface.buffer_scale != renderScale(data, surface));
    }
    fn renderScale(data: ?*anyopaque, surface: *wire.Surface) u32 {
        const self = cast(Overview, data);
        const now = c.g_get_monotonic_time();
        // Fractional outputs otherwise render at the next integer scale (for
        // example 2x buffers on a 1.625x display). Keep motion inexpensive, then
        // restore native text/icon detail on the final compositor-paced frame.
        if (!self.apps_mode and self.launcher.searchText().len == 0 and (self.transition.active(now) or !self.transition.shown or now - self.workspace_started < 250000)) return 1;
        return surface.output.scale;
    }
    fn outputAdded(data: ?*anyopaque, output: *wire.Output) void {
        const self = cast(Overview, data);
        if (self.surface == null) self.surface = self.createSurface(output) catch null;
    }
    fn outputRemoved(data: ?*anyopaque, output: *wire.Output) void {
        const self = cast(Overview, data);
        const surface = self.surface orelse return;
        if (surface.output != output) return;
        self.transition.setShown(false, c.g_get_monotonic_time());
        self.transition.finish();
        self.launcher.hide();
        for (self.native.outputs.items) |candidate| if (candidate != output) {
            surface.output = candidate;
            return;
        };
        self.surface = null;
    }
    fn closed(data: ?*anyopaque) void {
        cast(Overview, data).launcher.hide();
    }
    fn redraw(data: ?*anyopaque) void {
        cast(Overview, data).redrawSelf();
    }
    fn redrawSelf(self: *Overview) void {
        for (self.native.seats.items) |seat| if (seat.text_input) |value| value.update();
        if (!self.painting and self.launcher.visible_window and self.repaint_source == 0) self.repaint_source = c.g_idle_add(&repaint, self);
    }
    fn repaint(data: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast(Overview, data);
        self.repaint_source = 0;
        if (self.launcher.visible_window) if (self.surface) |surface| surface.redraw();
        return 0;
    }
    fn focusPart(self: *Overview, part: Part) void {
        self.focus_part = part;
        self.dash_view.keyboard_focus = part == .dash;
        self.launcher.search_focus = part == .search;
        self.launcher.search_input.?.focus(part == .search);
        self.redrawSelf();
    }
    fn launcherKey(self: *Overview, event: *apps.KeyEvent) c.gboolean {
        const handled = apps.keyPress(null, event, &self.launcher);
        if (handled != 0) {
            if (self.launcher.search_focus) self.focusPart(.search) else if (self.apps_mode or self.launcher.searchText().len != 0) self.focusPart(.grid);
        }
        return handled;
    }
    fn symbol(data: ?*anyopaque, _: *wire.Surface, value: u32, modifiers: u32, pressed: bool) bool {
        const self = cast(Overview, data);
        if (!self.transition.shown) {
            if (!pressed and (value == c.GDK_KEY_Super_L or value == c.GDK_KEY_Super_R)) self.present();
            return true;
        }
        self.modifiers = modifiers;
        var event: apps.KeyEvent = .{ .keyval = value, .state = modifiers };
        return if (pressed) key(null, &event, data) != 0 else keyRelease(null, &event, data) != 0;
    }
    fn inputText(data: ?*anyopaque, _: *wire.Surface, value: []const u8) void {
        const self = cast(Overview, data);
        if (!self.transition.shown) return;
        self.focusPart(.search);
        self.launcher.text(value);
    }
    fn inputFocus(data: ?*anyopaque, _: *wire.Surface, focused: bool) void {
        const self = cast(Overview, data);
        self.launcher.search_input.?.focus(focused and self.transition.shown and self.focus_part == .search);
    }
    fn surrounding(data: ?*anyopaque, _: *wire.Surface) ?@import("desktop-input.zig").TextState {
        const self = cast(Overview, data);
        if (!self.transition.shown) return null;
        return apps.textState(&self.launcher, self.search);
    }
    fn preedit(data: ?*anyopaque, _: *wire.Surface, value: []const u8, cursor: i32) void {
        const self = cast(Overview, data);
        if (self.transition.shown) self.launcher.search_input.?.preedit(value, cursor);
    }
    fn commit(data: ?*anyopaque, _: *wire.Surface, value: []const u8) void {
        const self = cast(Overview, data);
        if (self.transition.shown) self.launcher.search_input.?.insert(value) catch {};
    }
    fn delete(data: ?*anyopaque, _: *wire.Surface, before: u32, after: u32) void {
        const self = cast(Overview, data);
        if (self.transition.shown) self.launcher.search_input.?.deleteSurrounding(before, after);
    }
    fn partRegion(self: *Overview, part: Part) apps.Region {
        return switch (part) {
            .search => self.search,
            .grid => self.grid,
            .strip => self.strip,
            .stage => self.stage,
            .dash => self.dash,
            .tooltip => self.tooltip,
        };
    }
    fn partAt(self: *Overview, x: f64, y: f64) Part {
        if (self.search.contains(x, y)) return .search;
        if (self.strip.contains(x, y)) return .strip;
        if (self.dash.contains(x, y)) return .dash;
        return if (self.apps_mode or self.launcher.searchText().len != 0) .grid else .stage;
    }
    fn inputLeave(data: ?*anyopaque, _: *wire.Surface) void {
        const self = cast(Overview, data);
        self.pointer_part = null;
        self.hover = null;
        self.launcher.hover = null;
        self.launcher.search_hover = false;
        _ = dashLeave(null, null, data);
        self.redrawSelf();
    }
    fn inputMotion(data: ?*anyopaque, _: *wire.Surface, x: f64, y: f64) void {
        const self = cast(Overview, data);
        if (!self.transition.shown) return;
        const current = if (self.pressed_part) |part| part else self.partAt(x, y);
        if (self.pointer_part != current) {
            if (self.pointer_part == .dash) _ = dashLeave(null, null, data);
            self.launcher.hover = null;
            self.launcher.search_hover = false;
            self.hover = null;
        }
        self.pointer_part = current;
        const region = self.partRegion(current);
        var event: Pointer = .{ .x = x - region.x, .y = y - region.y };
        switch (current) {
            .stage => {
                _ = motion(null, &event, data);
            },
            .dash => self.hoverDash(event.x, event.y),
            .search => apps.motion(&self.launcher, .search, event.x, event.y),
            .grid => apps.motion(&self.launcher, .grid, event.x, event.y),
            else => {},
        }
        self.redrawSelf();
    }
    fn inputButton(data: ?*anyopaque, _: *wire.Surface, code: u32, down: bool, x: f64, y: f64) void {
        const self = cast(Overview, data);
        if (!self.transition.shown) return;
        const current = self.pressed_part orelse self.partAt(x, y);
        if (down) self.pressed_part = current else self.pressed_part = null;
        const region = self.partRegion(current);
        var event: Pointer = .{ .x = x - region.x, .y = y - region.y, .button = switch (code) {
            272 => 1,
            273 => 3,
            274 => 2,
            else => return,
        } };
        switch (current) {
            .stage => {
                self.focusPart(.stage);
                if (down) {
                    _ = press(null, &event, data);
                } else {
                    _ = release(null, &event, data);
                }
            },
            .dash => {
                if (down) {
                    _ = dashPress(null, &event, data);
                } else {
                    _ = dashRelease(null, &event, data);
                }
            },
            .strip => {
                if (down) {
                    _ = workspaceClick(null, &event, data);
                }
            },
            .search, .grid => if (event.button == 1) {
                self.focusPart(current);
                const part: apps.Part = if (current == .search) .search else .grid;
                if (down) apps.press(&self.launcher, part, event.x, event.y, self.modifiers) else apps.release(&self.launcher, part, event.x, event.y);
            },
            else => {},
        }
        self.redrawSelf();
    }
    fn inputScroll(data: ?*anyopaque, _: *wire.Surface, _: u32, amount: f64) void {
        const self = cast(Overview, data);
        if (!self.transition.shown) return;
        if (self.apps_mode or self.launcher.searchText().len != 0) apps.scroll(&self.launcher, amount) else if (@abs(amount) >= 1) self.stepWorkspace(if (amount > 0) 1 else -1);
    }
    fn paint(data: ?*anyopaque, target: wire.Pixels) void {
        const self = cast(Overview, data);
        self.painting = true;
        self.progress = self.transition.value(c.g_get_monotonic_time());
        self.animating = self.progress != (if (self.transition.shown) @as(f64, 1) else 0);
        defer self.painting = false;
        const scale = self.surface.?.buffer_scale;
        const width = target.width / scale;
        const height = target.height / scale;
        self.search.x = (@as(f64, @floatFromInt(width)) - 370) / 2;
        const footer = self.dash_view.layout.height;
        self.dash = .{ .x = (@as(f64, @floatFromInt(width)) - @as(f64, @floatFromInt(self.dash_view.layout.width))) / 2, .y = @floatFromInt(height -| footer), .width = self.dash_view.layout.width, .height = footer };
        const status: u32 = if (self.launcher.status.len > 0) 64 else 0;
        self.stage = .{ .y = 128, .width = width, .height = height -| (128 + 21 + footer + status) };
        self.strip.width = width;
        self.grid = .{ .y = 119, .width = width, .height = height -| (119 + footer + status) };
        self.launcher.geometry = @import("desktop-apps-view.zig").Grid.init(width, @max(1, self.grid.height));
        self.launcher.page = self.launcher.selected / self.launcher.geometry.capacity();
        @memset(target.pixels, 0xff222226);
        apps.paintRegion(target, scale, self.search, .{ &self.launcher, apps.Part.search }, apps.paintPart);
        apps.paintRegionInPlace(target, scale, self.strip, .{ self, Part.strip }, paintPart);
        apps.paintRegion(target, scale, self.dash, .{ self, Part.dash }, paintPart);
        if (self.apps_mode or self.launcher.searchText().len != 0) {
            apps.paintRegion(target, scale, self.grid, .{ &self.launcher, apps.Part.grid }, apps.paintPart);
        } else if (self.progress < 1 or !self.transition.shown) {
            // The desktop zooms over the entire viewport, revealing the search,
            // thumbnails and dash as it shrinks, rather than clipping at the
            // window-picker allocation from the first frame.
            self.paintStage(.{ .target = target, .scale = @floatFromInt(scale), .origin = .{ .x = 0, .y = self.stage.y } }, @floatFromInt(width), @floatFromInt(self.stage.height));
        } else apps.paintRegionInPlace(target, scale, self.stage, .{ self, Part.stage }, paintPart);
        if (self.tooltip_visible) apps.paintRegion(target, scale, self.tooltip, .{ self, Part.tooltip }, paintPart);
        if (status > 0) apps.paintRegion(target, scale, .{ .y = @floatFromInt(height -| (footer + status)), .width = width, .height = status }, .{ &self.launcher, apps.Part.message }, apps.paintPart);
    }
    fn paintPart(context: struct { *Overview, Part }, target: raster.Buffer, scale: u32) void {
        const self = context[0];
        const canvas: raster.Canvas = .{ .target = target, .scale = @floatFromInt(scale) };
        switch (context[1]) {
            .strip => self.paintStrip(canvas, @as(f64, @floatFromInt(target.width)) / canvas.scale),
            .stage => self.paintStage(canvas, @as(f64, @floatFromInt(target.width)) / canvas.scale, @as(f64, @floatFromInt(target.height)) / canvas.scale),
            .dash => self.dash_view.paint(target, scale) catch {},
            .tooltip => self.dash_view.paintTooltip(target, scale),
            else => {},
        }
    }
    fn paintStrip(self: *Overview, canvas: raster.Canvas, width: f64) void {
        const client = self.client orelse return;
        const now = c.g_get_monotonic_time();
        const animated = self.transition.active(now) or !self.transition.shown or now - self.workspace_started < 250000;
        const left = (width - @as(f64, @floatFromInt(client.count)) * 72 + 6) / 2;
        for (0..client.count) |i| {
            const x = left + @as(f64, @floatFromInt(i)) * 72;
            const rect = Rect{ .x = x, .y = 19, .w = 66, .h = 40 };
            if (i == client.current) {
                canvas.draw(&.{(raster.Rect{ .x = x - 3, .y = 16, .width = 72, .height = 46 }).shape(8)}, .{ .red = 0.208, .green = 0.518, .blue = 0.894 });
            }
            canvas.draw(&.{pixelRect(rect).shape(3)}, raster.Color.rgb(0x46464e, 1));
            for (client.windows.items) |window| {
                if (window.workspace != i and !window.sticky) continue;
                const g = window.geometry;
                const sx = 66 / @as(f64, @floatFromInt(self.monitor.width));
                const sy = 40 / @as(f64, @floatFromInt(self.monitor.height - 32));
                const r = Rect{ .x = x + (g.x - @as(f64, @floatFromInt(self.monitor.x))) * sx, .y = 19 + (g.y - @as(f64, @floatFromInt(self.monitor.y + 32))) * sy, .w = g.w * sx, .h = g.h * sy };
                view.miniature(canvas, if (window.image) |image| image.view() else null, pixelRect(r), pixelRect(rect), animated);
            }
        }
    }
    fn workspacePosition(self: *Overview) f64 {
        const t = std.math.clamp(@as(f64, @floatFromInt(c.g_get_monotonic_time() - self.workspace_started)) / 250000, 0, 1);
        const ease = 1 - (1 - t) * (1 - t) * (1 - t);
        return self.workspace_from + (@as(f64, @floatFromInt(self.workspace_target)) - self.workspace_from) * ease;
    }
    fn paintStage(self: *Overview, canvas: raster.Canvas, width: f64, height: f64) void {
        const client = self.client orelse return;
        if (width <= 0 or height <= 24) return;
        const scale = @min(width * 0.73 / @as(f64, @floatFromInt(self.monitor.width)), (height - 24) / @as(f64, @floatFromInt(self.monitor.height - 32)));
        const base = Rect{ .x = (width - @as(f64, @floatFromInt(self.monitor.width)) * scale) / 2, .y = 12, .w = @as(f64, @floatFromInt(self.monitor.width)) * scale, .h = @as(f64, @floatFromInt(self.monitor.height - 32)) * scale };
        self.workspace_rect = base;
        const ease = self.progress;
        const position = self.workspacePosition();
        const moving = self.animating or position != @as(f64, @floatFromInt(self.workspace_target));
        const animated = moving or !self.transition.shown;
        self.animating = moving;
        for (0..client.count) |i| {
            const offset = @as(f64, @floatFromInt(i)) - position;
            const ratio = 1 - 0.06 * @min(1, @abs(offset));
            const full_height: f64 = @floatFromInt(self.monitor.height - 32);
            const start = Rect{ .x = width / 2 + offset * (width + 64) - width * ratio / 2, .y = -128 + (full_height - full_height * ratio) / 2, .w = width * ratio, .h = full_height * ratio };
            const background = Rect{
                .x = start.x + (width / 2 + offset * (base.w + 64) - base.w * ratio / 2 - start.x) * ease,
                .y = start.y + (12 + (base.h - base.h * ratio) / 2 - start.y) * ease,
                .w = start.w + (base.w * ratio - start.w) * ease,
                .h = start.h + (base.h * ratio - start.h) * ease,
            };
            if (background.x > width or background.x + background.w < 0) continue;
            view.workspaceProgress(canvas, pixelRect(background), self.wallpaper, ease, animated);
            self.drawWindows(canvas, client, @intCast(i), background, height, ratio, if (i == client.current) ease else 1, animated);
        }
    }
    fn drawWindows(self: *Overview, canvas: raster.Canvas, client: *capture.Client, workspace_index: u32, background: Rect, height: f64, ratio: f64, ease: f64, animated: bool) void {
        if (background.w <= 168 * ratio or height <= 0) return;
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
            // GNOME first projects the desktop geometry into the moving
            // workspace, then interpolates that clone into the picker layout.
            // Composing both transforms keeps windows attached to the zoom.
            const sx = background.w / @as(f64, @floatFromInt(self.monitor.width));
            const sy = background.h / @as(f64, @floatFromInt(self.monitor.height - 32));
            const start = Rect{
                .x = background.x + (window.geometry.x - @as(f64, @floatFromInt(self.monitor.x))) * sx,
                .y = background.y + (window.geometry.y - @as(f64, @floatFromInt(self.monitor.y + 32))) * sy,
                .w = window.geometry.w * sx,
                .h = window.geometry.h * sy,
            };
            const r = Rect{ .x = start.x + (x - start.x) * ease, .y = start.y + (y - start.y) * ease, .w = start.w + (w - start.w) * ease, .h = start.h + (h - start.h) * ease };
            view.window(canvas, pixelRect(r), if (window.image) |image| image.view() else null, window.icon, workspace_index == client.current and self.hover == index, ease, animated);
            position += 1;
        }
    }
};
fn matchesApp(app_id: [*c]const u8, desktop_id: [*c]const u8) bool {
    if (app_id == null or desktop_id == null) return false;
    const id = std.mem.span(desktop_id);
    const app = std.mem.span(app_id);
    return std.mem.eql(u8, app, id) or (std.mem.endsWith(u8, id, ".desktop") and std.mem.eql(u8, app, id[0 .. id.len - 8]));
}
fn pixelRect(rect: Rect) raster.Rect {
    return .{ .x = rect.x, .y = rect.y, .width = rect.w, .height = rect.h };
}

pub const State = struct { overview: ?*Overview = null, wallpaper: [*:0]const u8 };
pub fn activate(app: *c.GtkApplication, data: c.gpointer) callconv(.c) void {
    const state = cast(State, data);
    if (state.overview == null) state.overview = Overview.create(app, state.wallpaper);
    const self = state.overview.?;
    if (self.launcher.visible_window and self.transition.shown) self.launcher.hide() else self.present();
}
pub fn deinit(state: *State) void {
    if (state.overview) |self| self.destroy();
    state.overview = null;
}

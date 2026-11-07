//! Freedesktop notification service with GNOME banners and persistent history.
const native = @import("desktop-surface.zig");
const banner = @import("desktop-notification-banner.zig");
const std = @import("std");
const view = banner;
const c = @import("desktop-gtk.zig");
const allocator = std.heap.page_allocator;
const cast = c.__zig.cast;
const path = "/org/freedesktop/Notifications";
const name = "org.freedesktop.Notifications";
const control = "org.dotfiles.Notifications";
const xml =
    \\<node><interface name="org.freedesktop.Notifications">
    \\<method name="GetCapabilities"><arg type="as" direction="out"/></method>
    \\<method name="GetServerInformation"><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/><arg type="s" direction="out"/></method>
    \\<method name="Notify"><arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="as" direction="in"/><arg type="a{sv}" direction="in"/><arg type="i" direction="in"/><arg type="u" direction="out"/></method>
    \\<method name="CloseNotification"><arg type="u" direction="in"/></method>
    \\<signal name="NotificationClosed"><arg type="u"/><arg type="u"/></signal>
    \\<signal name="ActionInvoked"><arg type="u"/><arg type="s"/></signal>
    \\</interface><interface name="org.dotfiles.Notifications">
    \\<method name="List"><arg type="s" direction="out"/></method>
    \\<method name="Dismiss"><arg type="u" direction="in"/></method>
    \\<method name="Activate"><arg type="u" direction="in"/><arg type="s" direction="in"/></method>
    \\<method name="Clear"/>
    \\<method name="CalendarOpen"><arg type="b" direction="in"/></method>
    \\<signal name="Changed"/>
    \\</interface></node>
;
const Notice = struct {
    arena: std.heap.ArenaAllocator,
    id: u32,
    app: [:0]const u8,
    title: [:0]const u8,
    body: [:0]const u8,
    icon: [:0]const u8,
    sender: [:0]const u8,
    actions: []view.Action,
    created: i64,
    image: ?*c.GdkPixbuf = null,
    critical: bool = false,
    transient: bool = false,
    resident: bool = false,
    pending: bool = true,

    fn destroy(self: *Notice) void {
        if (self.image != null) c.g_object_unref(self.image);
        self.arena.deinit();
        allocator.destroy(self);
    }
    fn data(self: *Notice) view.Data {
        return .{ .id = self.id, .app = self.app, .title = self.title, .body = self.body, .icon = self.icon, .image = self.image, .actions = self.actions, .created = self.created };
    }
};
const Server = struct {
    connection: ?*c.GDBusConnection = null,
    node: *c.GDBusNodeInfo,
    registrations: [2]c.guint = .{ 0, 0 },
    owned: bool = false,
    notices: std.ArrayList(*Notice) = .empty,
    next_id: u32 = 1,
    active: ?*Notice = null,
    card: ?banner.View = null,
    client: ?*native.Client = null,
    surface: ?*native.Surface = null,
    theme: banner.Theme = .{},
    timer: c.guint = 0,
    hovered: bool = false,
    calendar_open: bool = false,

    fn start(self: *Server) !void {
        self.client = try native.Client.createInteractive(.{ .added = &outputAdded, .removed = &outputRemoved, .changed = &outputChanged }, self);
        errdefer {
            self.client.?.destroy();
            self.client = null;
        }
        try self.client.?.start();
    }
    fn outputAdded(data: ?*anyopaque, _: *native.Output) void {
        const self = cast(Server, data);
        if (self.active != null and self.surface == null) self.present() catch |err| std.log.err("notification output: {s}", .{@errorName(err)});
    }
    fn outputRemoved(data: ?*anyopaque, output: *native.Output) void {
        const self = cast(Server, data);
        if (self.surface) |surface| if (surface.output == output) {
            surface.destroy();
            self.surface = null;
            self.resetHover();
            // The registry callback runs before the removed output is erased.
            for (self.client.?.outputs.items) |other| if (other != output) {
                self.map(other) catch |err| std.log.err("notification output: {s}", .{@errorName(err)});
                break;
            };
        };
    }
    fn outputChanged(data: ?*anyopaque, output: *native.Output) void {
        const self = cast(Server, data);
        if (self.surface) |surface| if (surface.output == output) self.layout() catch |err| std.log.err("notification layout: {s}", .{@errorName(err)});
    }
    fn present(self: *Server) !void {
        const client = self.client orelse return;
        if (client.outputs.items.len == 0) return;
        // Match GDK's primary monitor when available, then use the first output.
        var output = client.outputs.items[0];
        const display = c.gdk_display_get_default();
        if (c.gdk_display_get_primary_monitor(display)) |monitor| {
            var geometry: c.GdkRectangle = undefined;
            c.gdk_monitor_get_geometry(monitor, &geometry);
            for (client.outputs.items) |candidate| if (candidate.x == geometry.x and candidate.y == geometry.y) {
                output = candidate;
                break;
            };
        }
        try self.map(output);
    }
    fn map(self: *Server, output: *native.Output) !void {
        const notice = self.active orelse return;
        if (self.card == null) self.card = banner.View.init(notice.data(), self.theme, 529);
        const surface = try native.Surface.createPixels(output, .{
            .namespace = "desktop-notifications",
            .layer = 3,
            .anchors = native.top,
            .interactive = true,
            .cursor = .arrow,
            .exclusive_zone = 0,
        }, &paint, self);
        errdefer surface.destroy();
        self.surface = surface;
        errdefer self.surface = null;
        surface.input = .{ .motion = &motion, .leave = &left, .button = &button };
        try self.layout();
        try surface.show();
    }
    fn layout(self: *Server) !void {
        const surface = self.surface orelse return;
        const card = if (self.card) |*card| card else return;
        const width: u32 = @intCast(std.math.clamp(surface.output.width(), 160, 529));
        if (card.width != width) {
            card.width = width;
            card.scale = 0;
        }
        try card.prepare(surface.output.scale);
        surface.setLayout(card.width, card.height, -4, 0);
        surface.redraw();
    }
    fn paint(data: ?*anyopaque, buffer: native.Pixels) void {
        const self = cast(Server, data);
        if (self.card) |*card| card.paint(buffer);
    }
    fn motion(data: ?*anyopaque, surface: *native.Surface, x: f64, y: f64) void {
        const self = cast(Server, data);
        const card = if (self.card) |*card| card else return;
        const target = card.hit(x, y);
        if (card.hover != target) {
            card.hover = target;
            surface.redraw();
        }
        self.hovered = true;
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        self.timer = 0;
    }
    fn button(data: ?*anyopaque, surface: *native.Surface, code: u32, pressed: bool, x: f64, y: f64) void {
        if (code != 272) return;
        const self = cast(Server, data);
        const card = if (self.card) |*card| card else return;
        const target = card.hit(x, y);
        if (pressed) {
            card.pressed = target;
            surface.redraw();
            return;
        }
        const was_pressed = card.pressed;
        card.pressed = .none;
        surface.redraw();
        if (was_pressed != target) return;
        const id = card.notice.id;
        switch (target) {
            .close => self.close(id, 2),
            .card => activate(self, id, "default"),
            .expand => {
                card.toggle();
                self.layout() catch |err| std.log.err("notification expansion: {s}", .{@errorName(err)});
            },
            .action0, .action1, .action2 => {
                const index = @backingInt(target) - @backingInt(banner.Target.action0);
                if (card.action_keys[index]) |key| activate(self, id, key);
            },
            .none => {},
        }
    }
    fn find(self: *Server, id: u32) ?*Notice {
        for (self.notices.items) |notice| if (notice.id == id) return notice;
        return null;
    }
    fn changed(self: *Server) void {
        _ = c.g_dbus_connection_emit_signal(self.connection, null, path, control, "Changed", null, null);
    }
    fn hide(self: *Server) void {
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        self.timer = 0;
        self.active = null;
        if (self.surface) |surface| surface.destroy();
        self.surface = null;
        if (self.card) |*card| card.deinit();
        self.card = null;
        self.hovered = false;
    }
    fn showNext(self: *Server) void {
        if (self.active != null or self.calendar_open) return;
        var next: ?*Notice = null;
        for (self.notices.items) |notice| {
            if (!notice.pending) continue;
            if (next == null or notice.critical) next = notice;
            if (notice.critical) break;
        }
        const notice = next orelse return;
        notice.pending = false;
        self.active = notice;
        self.present() catch |err| std.log.err("notification banner: {s}", .{@errorName(err)});
        if (!notice.critical) self.timer = c.g_timeout_add(4000, &expired, self);
    }
    fn close(self: *Server, id: u32, reason: u32) void {
        for (self.notices.items, 0..) |notice, i| if (notice.id == id) {
            if (self.active == notice) self.hide();
            _ = c.g_dbus_connection_emit_signal(self.connection, notice.sender, path, name, "NotificationClosed", c.g_variant_new("(uu)", id, reason), null);
            _ = self.notices.orderedRemove(i);
            notice.destroy();
            self.changed();
            self.showNext();
            return;
        };
    }
    fn activate(data: ?*anyopaque, id: u32, key: [:0]const u8) void {
        const self = cast(Server, data);
        const notice = self.find(id) orelse return;
        var exists = false;
        for (notice.actions) |action| if (std.mem.eql(u8, action.key, key)) {
            exists = true;
            break;
        };
        if (exists) _ = c.g_dbus_connection_emit_signal(self.connection, notice.sender, path, name, "ActionInvoked", c.g_variant_new("(us)", id, key.ptr), null);
        if (!notice.resident) self.close(id, 2);
    }
    fn expired(data: c.gpointer) callconv(.c) c.gboolean {
        const self = cast(Server, data);
        self.timer = 0;
        if (self.hovered) return 0;
        const notice = self.active orelse return 0;
        if (notice.transient) self.close(notice.id, 1) else {
            self.hide();
            self.showNext();
        }
        return 0;
    }
    fn left(data: ?*anyopaque, surface: *native.Surface) void {
        const self = cast(Server, data);
        // Another seat can still be pointing at this banner.
        for (surface.client.seats.items) |seat| if (seat.pointer_focus == surface) return;
        if (self.card) |*card| {
            card.hover = .none;
            card.pressed = .none;
            surface.redraw();
        }
        self.resetHover();
    }
    fn resetHover(self: *Server) void {
        self.hovered = false;
        if (self.active) |notice| if (!notice.critical) {
            if (self.timer != 0) _ = c.g_source_remove(self.timer);
            self.timer = c.g_timeout_add(200, &expired, self);
        };
    }
    fn deinit(self: *Server) void {
        self.hide();
        if (self.client) |client| client.destroy();
        for (self.notices.items) |notice| notice.destroy();
        self.notices.deinit(allocator);
        if (self.connection != null) {
            for (self.registrations) |id| {
                if (id != 0) _ = c.g_dbus_connection_unregister_object(self.connection, id);
            }
        }
    }
    fn notify(self: *Server, sender: [*:0]const u8, parameters: *c.GVariant) !u32 {
        const notice = try allocator.create(Notice);
        notice.* = .{ .arena = std.heap.ArenaAllocator.init(allocator), .id = 0, .app = "", .title = "", .body = "", .icon = "", .sender = "", .actions = &.{}, .created = @divTrunc(c.g_get_real_time(), 1000000) };
        errdefer notice.destroy();
        const a = notice.arena.allocator();
        notice.app = try stringField(a, parameters, 0, 150);
        notice.icon = try stringField(a, parameters, 2, 4096);
        if (notice.icon.len == 0) notice.icon = "application-x-executable-symbolic";
        notice.title = try stringField(a, parameters, 3, 150);
        notice.body = try stringField(a, parameters, 4, 850);
        notice.sender = try a.dupeSentinel(u8, std.mem.span(sender), 0);
        const replace = c.g_variant_get_child_value(parameters, 1);
        defer c.g_variant_unref(replace);
        const old_id = c.g_variant_get_uint32(replace);
        const hints = c.g_variant_get_child_value(parameters, 6).?;
        defer c.g_variant_unref(hints);
        notice.critical = hintByte(hints, "urgency") == 2;
        notice.transient = hintBool(hints, "transient");
        notice.resident = hintBool(hints, "resident");
        if (c.g_variant_lookup_value(hints, "desktop-entry", variantType("s"))) |entry| {
            defer c.g_variant_unref(entry);
            const id = try std.fmt.allocPrintSentinel(a, "{s}.desktop", .{std.mem.span(c.g_variant_get_string(entry, null))}, 0);
            if (c.g_desktop_app_info_new(id)) |info| {
                defer c.g_object_unref(info);
                notice.app = try a.dupeSentinel(u8, std.mem.span(c.g_app_info_get_display_name(@ptrCast(info))), 0);
                if (c.g_desktop_app_info_get_string(info, "Icon")) |icon| {
                    defer c.g_free(icon);
                    notice.icon = try a.dupeSentinel(u8, std.mem.span(icon), 0);
                }
            }
        }
        notice.image = imageHint(hints);
        const actions = c.g_variant_get_child_value(parameters, 5).?;
        defer c.g_variant_unref(actions);
        const count = @min(c.g_variant_n_children(actions), 64);
        notice.actions = try a.alloc(view.Action, count / 2);
        for (notice.actions, 0..) |*action, i| action.* = .{ .key = try stringField(a, actions, i * 2, 128), .label = try stringField(a, actions, i * 2 + 1, 150) };
        if (self.find(old_id)) |old| if (std.mem.eql(u8, old.sender, std.mem.span(sender))) {
            notice.id = old.id;
            const was_active = self.active == old;
            if (was_active) self.hide();
            for (self.notices.items) |*item| if (item.* == old) {
                item.* = notice;
                break;
            };
            old.destroy();
            if (self.calendar_open or (!notice.critical and !@import("desktop-quick-settings.zig").bannersEnabled())) notice.pending = false;
            self.changed();
            self.showNext();
            return notice.id;
        };
        while (self.next_id == 0 or self.find(self.next_id) != null) self.next_id +%= 1;
        notice.id = self.next_id;
        self.next_id +%= 1;
        if (self.notices.items.len >= 100) self.close(self.notices.items[0].id, 1);
        try self.notices.append(allocator, notice);
        if (self.calendar_open or (!notice.critical and !@import("desktop-quick-settings.zig").bannersEnabled())) notice.pending = false;
        if (notice.critical and self.active != null and !self.active.?.critical) self.hide();
        self.changed();
        self.showNext();
        return notice.id;
    }
    fn list(self: *Server) ![:0]u8 {
        const Record = struct { id: u32, app: []const u8, title: []const u8, body: []const u8, icon: []const u8, created: i64, actions: []view.Action };
        const records = try allocator.alloc(Record, self.notices.items.len);
        defer allocator.free(records);
        for (records, self.notices.items) |*record, notice| record.* = .{ .id = notice.id, .app = notice.app, .title = notice.title, .body = notice.body, .icon = notice.icon, .created = notice.created, .actions = notice.actions };
        const json = try std.json.Stringify.valueAlloc(allocator, records, .{});
        defer allocator.free(json);
        return allocator.dupeSentinel(u8, json, 0);
    }
};
fn stringField(a: std.mem.Allocator, value: *c.GVariant, index: usize, limit: usize) ![:0]const u8 {
    const child = c.g_variant_get_child_value(value, index);
    defer c.g_variant_unref(child);
    const text = c.g_variant_get_string(child, null);
    const count: usize = @intCast(@max(0, c.g_utf8_strlen(text, -1)));
    const end = c.g_utf8_offset_to_pointer(text, @intCast(@min(count, limit)));
    const result = try a.dupeSentinel(u8, text[0..@intCast(@intFromPtr(end) - @intFromPtr(text))], 0);
    for (result) |*ch| if (ch.* == '\n' or ch.* == '\r') {
        ch.* = ' ';
    };
    return result;
}
fn variantType(comptime signature: [:0]const u8) *const c.GVariantType {
    return @ptrCast(signature.ptr);
}
fn hintBool(hints: *c.GVariant, key: [*:0]const u8) bool {
    const value = c.g_variant_lookup_value(hints, key, variantType("b")) orelse return false;
    defer c.g_variant_unref(value);
    return c.g_variant_get_boolean(value) != 0;
}
fn hintByte(hints: *c.GVariant, key: [*:0]const u8) u8 {
    const value = c.g_variant_lookup_value(hints, key, variantType("y")) orelse return 1;
    defer c.g_variant_unref(value);
    return c.g_variant_get_byte(value);
}
fn imageHint(hints: *c.GVariant) ?*c.GdkPixbuf {
    for ([_][*:0]const u8{ "image-data", "image_data", "icon_data" }) |key| {
        const tuple = c.g_variant_lookup_value(hints, key, variantType("(iiibiiay)")) orelse continue;
        defer c.g_variant_unref(tuple);
        var values: [7]?*c.GVariant = undefined;
        for (&values, 0..) |*value, i| value.* = c.g_variant_get_child_value(tuple, i);
        defer for (values) |value| c.g_variant_unref(value);
        const width = c.g_variant_get_int32(values[0]);
        const height = c.g_variant_get_int32(values[1]);
        const stride = c.g_variant_get_int32(values[2]);
        const alpha = c.g_variant_get_boolean(values[3]) != 0;
        const bits = c.g_variant_get_int32(values[4]);
        const channels = c.g_variant_get_int32(values[5]);
        if (width <= 0 or height <= 0 or width > 4096 or height > 4096 or bits != 8 or channels != @as(c_int, if (alpha) 4 else 3) or stride < width * channels) return null;
        var length: c.gsize = 0;
        const bytes: [*]const u8 = @ptrCast(c.g_variant_get_fixed_array(values[6], &length, 1) orelse return null);
        const row: usize = @intCast(width * channels);
        if (length < @as(usize, @intCast(stride)) * @as(usize, @intCast(height - 1)) + row) return null;
        const pixbuf = c.gdk_pixbuf_new(c.GDK_COLORSPACE_RGB, @intFromBool(alpha), 8, width, height) orelse return null;
        const pixels = c.gdk_pixbuf_get_pixels(pixbuf);
        const dest_stride: usize = @intCast(c.gdk_pixbuf_get_rowstride(pixbuf));
        for (0..@intCast(height)) |y| @memcpy(pixels[y * dest_stride ..][0..row], bytes[y * @as(usize, @intCast(stride)) ..][0..row]);
        return pixbuf;
    }
    if (c.g_variant_lookup_value(hints, "image-path", variantType("s"))) |image| {
        defer c.g_variant_unref(image);
        const value = c.g_variant_get_string(image, null);
        const file = if (c.g_str_has_prefix(value, "file://") != 0) c.g_filename_from_uri(value, null, null) else c.g_strdup(value);
        defer c.g_free(file);
        if (file != null and c.g_path_is_absolute(file) != 0) return c.gdk_pixbuf_new_from_file_at_scale(file, 48, 48, 1, null);
    }
    return null;
}
fn method(_: ?*c.GDBusConnection, sender: [*c]const u8, _: [*c]const u8, interface: [*c]const u8, member: [*c]const u8, parameters: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation, data: c.gpointer) callconv(.c) void {
    const self = cast(Server, data);
    if (c.g_strcmp0(interface, control) == 0) {
        if (c.g_strcmp0(member, "List") == 0) {
            const json = self.list() catch {
                c.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.NoMemory", "Cannot serialize notifications");
                return;
            };
            defer allocator.free(json);
            c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(s)", json.ptr));
            return;
        } else if (c.g_strcmp0(member, "Clear") == 0) {
            while (self.notices.items.len > 0) self.close(self.notices.items[0].id, 2);
        } else if (c.g_strcmp0(member, "CalendarOpen") == 0) {
            const value = c.g_variant_get_child_value(parameters, 0);
            defer c.g_variant_unref(value);
            self.calendar_open = c.g_variant_get_boolean(value) != 0;
            if (self.calendar_open) {
                self.hide();
                for (self.notices.items) |notice| notice.pending = false;
            }
        } else {
            const value = c.g_variant_get_child_value(parameters, 0);
            defer c.g_variant_unref(value);
            const id = c.g_variant_get_uint32(value);
            if (c.g_strcmp0(member, "Dismiss") == 0) self.close(id, 2) else if (c.g_strcmp0(member, "Activate") == 0) {
                const key = c.g_variant_get_child_value(parameters, 1);
                defer c.g_variant_unref(key);
                Server.activate(self, id, std.mem.span(c.g_variant_get_string(key, null)));
            }
        }
        c.g_dbus_method_invocation_return_value(invocation, null);
    } else if (c.g_strcmp0(member, "Notify") == 0) {
        const id = self.notify(std.mem.span(sender), parameters.?) catch {
            c.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.NoMemory", "Cannot create notification");
            return;
        };
        c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(u)", id));
    } else if (c.g_strcmp0(member, "GetCapabilities") == 0) {
        const capabilities = [_:null]?[*:0]const u8{ "body", "body-markup", "actions", "icon-static", "persistence" };
        c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(@as)", c.g_variant_new_strv(@ptrCast(&capabilities), -1)));
    } else if (c.g_strcmp0(member, "GetServerInformation") == 0) {
        c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(ssss)", @as([*:0]const u8, "Desktop Notifications"), @as([*:0]const u8, "dotfiles"), @as([*:0]const u8, "0.1"), @as([*:0]const u8, "1.2")));
    } else if (c.g_strcmp0(member, "CloseNotification") == 0) {
        const value = c.g_variant_get_child_value(parameters, 0);
        defer c.g_variant_unref(value);
        const id = c.g_variant_get_uint32(value);
        if (self.find(id)) |notice| if (c.g_strcmp0(notice.sender, sender) == 0) self.close(id, 3);
        c.g_dbus_method_invocation_return_value(invocation, null);
    }
}
const vtable = c.GDBusInterfaceVTable{ .method_call = &method, .get_property = null, .set_property = null, .padding = @splat(null) };
fn acquired(connection: ?*c.GDBusConnection, _: [*c]const u8, data: c.gpointer) callconv(.c) void {
    const self = cast(Server, data);
    self.connection = connection;
    for (0..2) |i| self.registrations[i] = c.g_dbus_connection_register_object(connection, path, self.node.interfaces[i], &vtable, self, null, null);
}
fn owned(_: ?*c.GDBusConnection, _: [*c]const u8, data: c.gpointer) callconv(.c) void {
    cast(Server, data).owned = true;
}
pub const Service = struct {
    server: Server,
    node: *c.GDBusNodeInfo,
    owner: c.guint = 0,

    pub fn create() !*Service {
        const self = try allocator.create(Service);
        errdefer allocator.destroy(self);
        const node = c.g_dbus_node_info_new_for_xml(xml, null) orelse return error.InvalidInterface;
        errdefer c.g_dbus_node_info_unref(node);
        self.* = .{ .server = .{ .node = node }, .node = node };
        try self.server.start();
        self.owner = c.g_bus_own_name(c.G_BUS_TYPE_SESSION, name, c.G_BUS_NAME_OWNER_FLAGS_NONE, &acquired, &owned, &serviceLost, &self.server, null);
        return self;
    }

    pub fn isOwned(self: *Service) bool {
        return self.server.owned;
    }

    pub fn destroy(self: *Service) void {
        c.g_bus_unown_name(self.owner);
        self.server.deinit();
        c.g_dbus_node_info_unref(self.node);
        allocator.destroy(self);
    }
};

fn serviceLost(_: ?*c.GDBusConnection, _: [*c]const u8, data: c.gpointer) callconv(.c) void {
    cast(Server, data).owned = false;
    if (c.g_application_get_default()) |app| c.g_application_quit(app) else c.gtk_main_quit();
}

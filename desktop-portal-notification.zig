//! Translate portal notifications directly to the shell's notification service.
const std = @import("std");
const c = @import("gtk");
const fdo = "org.freedesktop.Notifications";
const object_path = "/org/freedesktop/Notifications";
fn eq(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}
fn lookup(dict: ?*c.GVariant, key: [*:0]const u8, signature: [*:0]const u8) ?*c.GVariant {
    return c.g_variant_lookup_value(dict, key, @ptrCast(signature));
}
fn child(value: ?*c.GVariant, index: usize) ?*c.GVariant {
    return c.g_variant_get_child_value(value, index);
}
fn text(value: ?*c.GVariant) [*:0]const u8 {
    return if (value == null) "" else c.g_variant_get_string(value, null);
}
fn builder(signature: [*:0]const u8) *c.GVariantBuilder {
    return c.g_variant_builder_new(@ptrCast(signature)).?;
}
const Notice = struct {
    service: *Service,
    owner: [:0]u8,
    app: [:0]u8,
    key: [:0]u8,
    id: u32 = 0,
    pending: bool = false,
    removed: bool = false,
    current: ?*c.GVariant = null,
    next: ?*c.GVariant = null,
    fn destroy(self: *Notice) void {
        if (self.current != null) c.g_variant_unref(self.current);
        if (self.next != null) c.g_variant_unref(self.next);
        const allocator = self.service.allocator;
        allocator.free(self.owner);
        allocator.free(self.app);
        allocator.free(self.key);
        allocator.destroy(self);
    }
};
const Send = struct { notice: *Notice, contents: *c.GVariant, generation: u64 };
pub const Service = struct {
    allocator: std.mem.Allocator,
    connection: *c.GDBusConnection,
    cancel: *c.GCancellable,
    notices: std.ArrayList(*Notice) = .empty,
    subscriptions: [3]c.guint,
    generation: u64 = 0,
    callbacks: usize = 0,
    stopping: bool = false,

    pub fn create(allocator: std.mem.Allocator, connection: *c.GDBusConnection) !*Service {
        const self = try allocator.create(Service);
        self.* = .{ .allocator = allocator, .connection = connection, .cancel = c.g_cancellable_new().?, .subscriptions = undefined };
        self.subscriptions = .{
            c.g_dbus_connection_signal_subscribe(connection, fdo, fdo, "ActionInvoked", object_path, null, 0, &actionInvoked, self, null),
            c.g_dbus_connection_signal_subscribe(connection, fdo, fdo, "NotificationClosed", object_path, null, 0, &closed, self, null),
            c.g_dbus_connection_signal_subscribe(connection, "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", fdo, 0, &ownerChanged, self, null),
        };
        return self;
    }
    pub fn destroy(self: *Service) void {
        self.stopping = true;
        for (self.subscriptions) |id| c.g_dbus_connection_signal_unsubscribe(self.connection, id);
        c.g_cancellable_cancel(self.cancel);
        while (self.callbacks != 0) _ = c.g_main_context_iteration(null, 1);
        for (self.notices.items) |notice| {
            self.closeId(notice.id);
            notice.destroy();
        }
        self.notices.deinit(self.allocator);
        c.g_object_unref(self.cancel);
        self.allocator.destroy(self);
    }
    fn closeId(self: *Service, id: u32) void {
        if (id != 0) c.g_dbus_connection_call(self.connection, fdo, object_path, fdo, "CloseNotification", c.g_variant_new("(u)", id), @ptrCast(@as([*:0]const u8, "()")), 0, 1000, null, null, null);
    }
    fn collect(self: *Service, notice: *Notice) void {
        if (!notice.removed or notice.pending or self.stopping) return;
        for (self.notices.items, 0..) |item, index| if (notice == item) {
            _ = self.notices.swapRemove(index);
            break;
        };
        notice.destroy();
    }
    pub fn add(self: *Service, owner: [:0]const u8, app: [:0]const u8, key: [:0]const u8, contents: *c.GVariant) !void {
        if (key.len > 512) return error.InvalidNotificationId;
        var record: ?*Notice = null;
        for (self.notices.items) |notice| if (eq(notice.owner, owner) and eq(notice.key, key)) {
            record = notice;
            break;
        };
        if (record == null) {
            if (self.notices.items.len >= 128) return error.TooManyNotifications;
            const notice = try self.allocator.create(Notice);
            errdefer self.allocator.destroy(notice);
            const owned = try self.allocator.dupeSentinel(u8, owner, 0);
            errdefer self.allocator.free(owned);
            const app_id = try self.allocator.dupeSentinel(u8, app, 0);
            errdefer self.allocator.free(app_id);
            const id = try self.allocator.dupeSentinel(u8, key, 0);
            errdefer self.allocator.free(id);
            notice.* = .{ .service = self, .owner = owned, .app = app_id, .key = id };
            try self.notices.append(self.allocator, notice);
            record = notice;
        }
        const notice = record.?;
        notice.removed = false;
        if (notice.next != null) c.g_variant_unref(notice.next);
        notice.next = c.g_variant_ref(contents);
        try self.sendNext(notice);
    }
    pub fn remove(self: *Service, owner: []const u8, key: []const u8) void {
        for (self.notices.items) |notice| if (eq(notice.owner, owner) and eq(notice.key, key)) {
            notice.removed = true;
            if (notice.next != null) c.g_variant_unref(notice.next);
            notice.next = null;
            self.closeId(notice.id);
            self.collect(notice);
            return;
        };
    }
    fn icon(self: *Service, contents: ?*c.GVariant, hints: *c.GVariantBuilder) ![:0]u8 {
        const value = lookup(contents, "icon", "(sv)");
        defer if (value != null) c.g_variant_unref(value);
        if (value) |serialized| {
            const gicon = c.g_icon_deserialize(serialized);
            defer if (gicon != null) c.g_object_unref(gicon);
            if (gicon != null and c.g_type_check_instance_is_a(@ptrCast(@alignCast(gicon)), c.g_bytes_icon_get_type()) != 0) {
                const stream = c.g_memory_input_stream_new_from_bytes(c.g_bytes_icon_get_bytes(gicon));
                defer if (stream != null) c.g_object_unref(stream);
                const pixbuf = c.gdk_pixbuf_new_from_stream_at_scale(stream, 128, 128, 1, null, null);
                defer if (pixbuf != null) c.g_object_unref(pixbuf);
                if (pixbuf != null) {
                    const width = c.gdk_pixbuf_get_width(pixbuf);
                    const height = c.gdk_pixbuf_get_height(pixbuf);
                    const stride = c.gdk_pixbuf_get_rowstride(pixbuf);
                    const channels = c.gdk_pixbuf_get_n_channels(pixbuf);
                    const bytes = @as(usize, @intCast((height - 1) * stride + width * channels));
                    const data = c.g_variant_new_fixed_array(@ptrCast(@as([*:0]const u8, "y")), c.gdk_pixbuf_get_pixels(pixbuf), bytes, 1);
                    c.g_variant_builder_add(hints, "{sv}", @as([*:0]const u8, "image-data"), c.g_variant_new("(iiibii@ay)", width, height, stride, c.gdk_pixbuf_get_has_alpha(pixbuf), c.gdk_pixbuf_get_bits_per_sample(pixbuf), channels, data));
                }
            } else if (gicon != null) {
                const string = c.g_icon_to_string(gicon);
                defer if (string != null) c.g_free(string);
                if (string != null) return self.allocator.dupeSentinel(u8, std.mem.span(string), 0);
            }
        }
        return self.allocator.dupeSentinel(u8, "", 0);
    }
    fn sendNext(self: *Service, notice: *Notice) !void {
        if (notice.pending or notice.removed or self.stopping or notice.next == null) return;
        const send = try self.allocator.create(Send);
        errdefer self.allocator.destroy(send);
        send.* = .{ .notice = notice, .contents = notice.next.?, .generation = self.generation };
        const contents = send.contents;
        const title = lookup(contents, "title", "s");
        defer if (title != null) c.g_variant_unref(title);
        const body = lookup(contents, "body", "s");
        defer if (body != null) c.g_variant_unref(body);
        const priority = lookup(contents, "priority", "s");
        defer if (priority != null) c.g_variant_unref(priority);
        const hints = builder("a{sv}");
        defer c.g_variant_builder_unref(hints);
        const urgency: c_uint = if (eq(std.mem.span(text(priority)), "urgent") or eq(std.mem.span(text(priority)), "high")) 2 else if (eq(std.mem.span(text(priority)), "low")) 0 else 1;
        c.g_variant_builder_add(hints, "{sv}", @as([*:0]const u8, "urgency"), c.g_variant_new("y", urgency));
        c.g_variant_builder_add(hints, "{sv}", @as([*:0]const u8, "desktop-entry"), c.g_variant_new("s", notice.app.ptr));
        const icon_name = try self.icon(contents, hints);
        defer self.allocator.free(icon_name);
        const actions = builder("as");
        defer c.g_variant_builder_unref(actions);
        c.g_variant_builder_add(actions, "s", @as([*:0]const u8, "default"));
        c.g_variant_builder_add(actions, "s", @as([*:0]const u8, ""));
        const buttons = lookup(contents, "buttons", "aa{sv}");
        defer if (buttons != null) c.g_variant_unref(buttons);
        if (buttons != null) for (0..@min(c.g_variant_n_children(buttons), 16)) |index| {
            const button = child(buttons, index);
            defer c.g_variant_unref(button);
            const label = lookup(button, "label", "s");
            defer if (label != null) c.g_variant_unref(label);
            var buffer: [32]u8 = undefined;
            const key = try std.fmt.bufPrintSentinel(&buffer, "button{d}", .{index}, 0);
            c.g_variant_builder_add(actions, "s", key.ptr);
            c.g_variant_builder_add(actions, "s", text(label));
        };
        const escaped = c.g_markup_escape_text(text(body), -1);
        defer c.g_free(escaped);
        const params = c.g_variant_new("(susss@as@a{sv}i)", notice.app.ptr, notice.id, icon_name.ptr, text(title), escaped, c.g_variant_builder_end(actions), c.g_variant_builder_end(hints), @as(c_int, -1));
        notice.next = null;
        notice.pending = true;
        self.callbacks += 1;
        c.g_dbus_connection_call(self.connection, fdo, object_path, fdo, "Notify", params, @ptrCast(@as([*:0]const u8, "(u)")), 0, 10000, self.cancel, &sent, send);
    }
    fn sent(_: [*c]c.GObject, result: ?*c.GAsyncResult, data: ?*anyopaque) callconv(.c) void {
        const send = cast(Send, data);
        const notice = send.notice;
        const self = notice.service;
        const reply = c.g_dbus_connection_call_finish(self.connection, result, null);
        defer if (reply != null) c.g_variant_unref(reply);
        self.callbacks -= 1;
        notice.pending = false;
        if (send.generation != self.generation) {
            c.g_variant_unref(send.contents);
            notice.removed = true;
            notice.id = 0;
        } else if (reply != null) {
            const id = child(reply, 0);
            defer c.g_variant_unref(id);
            notice.id = c.g_variant_get_uint32(id);
            if (notice.current != null) c.g_variant_unref(notice.current);
            notice.current = send.contents;
        } else {
            c.g_variant_unref(send.contents);
            notice.removed = true;
        }
        self.allocator.destroy(send);
        if (notice.removed or self.stopping) self.closeId(notice.id) else self.sendNext(notice) catch {
            notice.removed = true;
            self.closeId(notice.id);
        };
        self.collect(notice);
    }
    fn ownerChanged(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, params: ?*c.GVariant, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Service, data);
        const old = child(params, 1);
        defer c.g_variant_unref(old);
        if (std.mem.span(text(old)).len == 0) return;
        self.generation +%= 1;
        var index: usize = 0;
        while (index < self.notices.items.len) {
            const notice = self.notices.items[index];
            notice.id = 0;
            notice.removed = true;
            self.collect(notice);
            if (index < self.notices.items.len and self.notices.items[index] == notice) index += 1;
        }
    }
    fn closed(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, params: ?*c.GVariant, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Service, data);
        const id = child(params, 0);
        defer c.g_variant_unref(id);
        for (self.notices.items) |notice| if (notice.id == c.g_variant_get_uint32(id)) {
            notice.removed = true;
            self.collect(notice);
            return;
        };
    }
    fn actionInvoked(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, params: ?*c.GVariant, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Service, data);
        const id = child(params, 0);
        defer c.g_variant_unref(id);
        const key = child(params, 1);
        defer c.g_variant_unref(key);
        const action_key = std.mem.span(text(key));
        for (self.notices.items) |notice| if (!notice.removed and notice.current != null and notice.id == c.g_variant_get_uint32(id)) {
            var button: ?*c.GVariant = null;
            var action: ?*c.GVariant = null;
            var target: ?*c.GVariant = null;
            defer if (button != null) c.g_variant_unref(button);
            defer if (action != null) c.g_variant_unref(action);
            defer if (target != null) c.g_variant_unref(target);
            if (eq(action_key, "default")) {
                action = lookup(notice.current, "default-action", "s");
                target = c.g_variant_lookup_value(notice.current, "default-action-target", null);
            } else if (std.mem.startsWith(u8, action_key, "button")) {
                const index = std.fmt.parseInt(usize, action_key[6..], 10) catch return;
                const buttons = lookup(notice.current, "buttons", "aa{sv}");
                defer if (buttons != null) c.g_variant_unref(buttons);
                if (buttons == null or index >= @min(c.g_variant_n_children(buttons), 16)) return;
                button = child(buttons, index);
                action = lookup(button, "action", "s");
                target = c.g_variant_lookup_value(button, "target", null);
                if (action == null) return;
            } else return;
            const arguments = builder("av");
            defer c.g_variant_builder_unref(arguments);
            if (target != null) c.g_variant_builder_add(arguments, "v", target);
            const name = if (action != null) text(action) else @as([*:0]const u8, "default");
            const name_text = std.mem.span(name);
            const app_path = std.fmt.allocPrintSentinel(self.allocator, "/{s}", .{notice.app}, 0) catch return;
            defer self.allocator.free(app_path);
            for (app_path) |*ch| {
                if (ch.* == '.') ch.* = '/';
                if (ch.* == '-') ch.* = '_';
            }
            if (std.mem.startsWith(u8, name_text, "app.")) {
                c.g_dbus_connection_call(self.connection, notice.app, app_path, "org.freedesktop.Application", "ActivateAction", c.g_variant_new("(s@av@a{sv})", name + 4, c.g_variant_builder_end(arguments), c.g_variant_new_array(@ptrCast(@as([*:0]const u8, "{sv}")), null, 0)), null, 0, 1000, null, null, null);
                return;
            }
            c.g_dbus_connection_call(self.connection, notice.app, app_path, "org.freedesktop.Application", "Activate", c.g_variant_new("(@a{sv})", c.g_variant_new_array(@ptrCast(@as([*:0]const u8, "{sv}")), null, 0)), null, 0, 1000, null, null, null);
            _ = c.g_dbus_connection_emit_signal(self.connection, notice.owner, "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Notification", "ActionInvoked", c.g_variant_new("(ss@av)", notice.key.ptr, name, c.g_variant_builder_end(arguments)), null);
            return;
        };
    }
};

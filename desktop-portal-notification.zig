//! Translate portal notifications directly to the shell's notification service.
const std = @import("std");
const c = @import("desktop-glib.zig");
const dbus = @import("dbus");
const bridge = @import("desktop-dbus-gvariant.zig");
const fdo = "org.freedesktop.Notifications";
const object_path = "/org/freedesktop/Notifications";
const eq = c.__zig.eq;
const lookup = c.__zig.variant.lookup;
const child = c.g_variant_get_child_value;
fn text(value: ?*c.GVariant) [*:0]const u8 {
    return if (value == null) "" else c.g_variant_get_string(value, null);
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
const Send = struct { notice: *Notice, contents: *c.GVariant, generation: u64, serial: u32 = 0 };
const Hints = bridge.Dict;
pub const Service = struct {
    allocator: std.mem.Allocator,
    connection: *dbus.Connection,
    notices: std.ArrayList(*Notice) = .empty,
    /// Notify calls awaiting their reply.
    sends: std.ArrayList(*Send) = .empty,
    subscriptions: [3]u32 = .{ 0, 0, 0 },
    generation: u64 = 0,
    stopping: bool = false,

    pub fn create(allocator: std.mem.Allocator, connection: *dbus.Connection) !*Service {
        const self = try allocator.create(Service);
        self.* = .{ .allocator = allocator, .connection = connection };
        errdefer self.destroy();
        self.subscriptions[0] = try connection.subscribe(fdo, fdo, "ActionInvoked", object_path, &actionInvoked, self);
        self.subscriptions[1] = try connection.subscribe(fdo, fdo, "NotificationClosed", object_path, &closed, self);
        self.subscriptions[2] = try connection.subscribeArg0("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", fdo, &ownerChanged, self);
        return self;
    }
    pub fn destroy(self: *Service) void {
        self.stopping = true;
        for (self.subscriptions) |id| if (id != 0) self.connection.unsubscribe(id);
        // Cancelled calls never answer; their notifications are closed below if they got an id.
        for (self.sends.items) |send| {
            self.connection.cancel(send.serial);
            send.notice.pending = false;
            c.g_variant_unref(send.contents);
            self.allocator.destroy(send);
        }
        self.sends.deinit(self.allocator);
        for (self.notices.items) |notice| {
            self.closeId(notice.id);
            notice.destroy();
        }
        self.notices.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    fn closeId(self: *Service, id: u32) void {
        if (id != 0) self.connection.send(.{ .destination = fdo, .path = object_path, .interface = fdo, .member = "CloseNotification" }, .{id}) catch {};
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
    /// Adds an `image-data` hint for a bytes icon, or returns a themed icon name.
    fn icon(arena: std.mem.Allocator, contents: ?*c.GVariant, hints: *std.ArrayList(Hints.Entry)) ![]const u8 {
        const value = lookup(contents, "icon", "(sv)");
        defer if (value != null) c.g_variant_unref(value);
        const serialized = value orelse return "";
        const gicon = c.g_icon_deserialize(serialized);
        defer if (gicon != null) c.g_object_unref(gicon);
        if (gicon != null and c.g_type_check_instance_is_a(@ptrCast(@alignCast(gicon)), c.g_bytes_icon_get_type()) != 0) {
            const stream = c.g_memory_input_stream_new_from_bytes(c.g_bytes_icon_get_bytes(gicon));
            defer if (stream != null) c.g_object_unref(stream);
            const decode = @import("desktop-decode.zig");
            if (if (stream) |input| decode.stream(input, 128) else null) |image| {
                defer decode.free(image);
                const rgba = try image.straightRgba(arena);
                const width: i32 = @intCast(image.width);
                // (iiibiiay): width, height, stride, alpha, bits per sample, channels, pixels.
                const fields = try arena.dupe(dbus.Value, &.{ .{ .int32 = width }, .{ .int32 = @intCast(image.height) }, .{ .int32 = width * 4 }, .{ .boolean = true }, .{ .int32 = 8 }, .{ .int32 = 4 }, .{ .bytes = rgba } });
                try hints.append(arena, .{ .key = "image-data", .value = .{ .structure = fields } });
            }
        } else if (gicon != null) {
            const string = c.g_icon_to_string(gicon);
            defer if (string != null) c.g_free(string);
            if (string != null) return arena.dupe(u8, std.mem.span(string));
        }
        return "";
    }
    fn sendNext(self: *Service, notice: *Notice) !void {
        if (notice.pending or notice.removed or self.stopping or notice.next == null) return;
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const temporary = arena.allocator();
        const contents = notice.next.?;
        const title = lookup(contents, "title", "s");
        defer if (title != null) c.g_variant_unref(title);
        const body = lookup(contents, "body", "s");
        defer if (body != null) c.g_variant_unref(body);
        const priority = lookup(contents, "priority", "s");
        defer if (priority != null) c.g_variant_unref(priority);
        const level = std.mem.span(text(priority));
        const urgency: u8 = if (eq(level, "urgent") or eq(level, "high")) 2 else if (eq(level, "low")) 0 else 1;
        var hints: std.ArrayList(Hints.Entry) = .empty;
        try hints.append(temporary, .{ .key = "urgency", .value = .{ .byte = urgency } });
        try hints.append(temporary, .{ .key = "desktop-entry", .value = .{ .string = notice.app } });
        const icon_name = try icon(temporary, contents, &hints);
        var actions: std.ArrayList([]const u8) = .empty;
        try actions.appendSlice(temporary, &.{ "default", "" });
        const buttons = lookup(contents, "buttons", "aa{sv}");
        defer if (buttons != null) c.g_variant_unref(buttons);
        if (buttons != null) for (0..@min(c.g_variant_n_children(buttons), 16)) |index| {
            const button = child(buttons, index);
            defer c.g_variant_unref(button);
            const label = lookup(button, "label", "s");
            defer if (label != null) c.g_variant_unref(label);
            try actions.append(temporary, try std.fmt.allocPrint(temporary, "button{d}", .{index}));
            try actions.append(temporary, try temporary.dupe(u8, std.mem.span(text(label))));
        };
        const escaped = c.g_markup_escape_text(text(body), -1);
        defer c.g_free(escaped);
        const send = try self.allocator.create(Send);
        errdefer self.allocator.destroy(send);
        send.* = .{ .notice = notice, .contents = contents, .generation = self.generation };
        try self.sends.ensureUnusedCapacity(self.allocator, 1);
        send.serial = try self.connection.call(.{ .destination = fdo, .path = object_path, .interface = fdo, .member = "Notify" }, .{ @as([]const u8, notice.app), notice.id, icon_name, std.mem.span(text(title)), std.mem.span(@as([*:0]const u8, escaped)), @as([]const []const u8, actions.items), Hints{ .entries = hints.items }, @as(i32, -1) }, 10000, &sent, send);
        self.sends.appendAssumeCapacity(send);
        notice.next = null;
        notice.pending = true;
    }
    fn sent(data: ?*anyopaque, reply: dbus.Reply) void {
        const send: *Send = @ptrCast(@alignCast(data));
        const notice = send.notice;
        const self = notice.service;
        for (self.sends.items, 0..) |item, index| if (item == send) {
            _ = self.sends.swapRemove(index);
            break;
        };
        notice.pending = false;
        const id: ?u32 = switch (reply) {
            .ok => |message| if (message.read(struct { u32 })) |value| value[0] else |_| null,
            .failed => null,
        };
        if (send.generation != self.generation) {
            c.g_variant_unref(send.contents);
            notice.removed = true;
            notice.id = 0;
        } else if (id) |value| {
            notice.id = value;
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
    fn ownerChanged(data: ?*anyopaque, message: *const dbus.Message) void {
        const self: *Service = @ptrCast(@alignCast(data));
        const args = message.read(struct { []const u8, []const u8, []const u8 }) catch return;
        if (args[1].len == 0) return;
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
    fn closed(data: ?*anyopaque, message: *const dbus.Message) void {
        const self: *Service = @ptrCast(@alignCast(data));
        const id = (message.read(struct { u32, u32 }) catch return)[0];
        for (self.notices.items) |notice| if (notice.id == id) {
            notice.removed = true;
            self.collect(notice);
            return;
        };
    }
    fn actionInvoked(data: ?*anyopaque, message: *const dbus.Message) void {
        const self: *Service = @ptrCast(@alignCast(data));
        const args = message.read(struct { u32, []const u8 }) catch return;
        const id = args[0];
        const action_key = args[1];
        for (self.notices.items) |notice| if (!notice.removed and notice.current != null and notice.id == id) {
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
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            var parameter: [1]dbus.Value = undefined;
            var arguments: []const dbus.Value = &.{};
            if (target) |value| {
                parameter[0] = bridge.fromVariant(arena.allocator(), c.g_variant_ref(value).?) catch return;
                arguments = &parameter;
            }
            const name = if (action != null) std.mem.span(text(action)) else "default";
            const app_path = std.fmt.allocPrint(arena.allocator(), "/{s}", .{notice.app}) catch return;
            for (app_path) |*ch| {
                if (ch.* == '.') ch.* = '/';
                if (ch.* == '-') ch.* = '_';
            }
            const application: dbus.Connection.Call = .{ .destination = notice.app, .path = app_path, .interface = "org.freedesktop.Application", .member = "Activate" };
            const empty: Hints = .{ .entries = &.{} };
            if (std.mem.startsWith(u8, name, "app.")) {
                var activate = application;
                activate.member = "ActivateAction";
                self.connection.send(activate, .{ name[4..], arguments, empty }) catch {};
                return;
            }
            self.connection.send(application, .{empty}) catch {};
            self.connection.emitTo(notice.owner, "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Notification", "ActionInvoked", .{ @as([]const u8, notice.key), name, arguments }) catch {};
            return;
        };
    }
};

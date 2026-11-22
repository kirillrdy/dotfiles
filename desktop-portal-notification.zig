//! Translate portal notifications directly to the shell's notification service.
const std = @import("std");
const c = @import("desktop-glib.zig");
const dbus = @import("dbus");
const fdo = "org.freedesktop.Notifications";
const object_path = "/org/freedesktop/Notifications";
const eq = c.__zig.eq;
const Dict = dbus.Dict([]const u8, dbus.Value);
/// An owned copy of a notification's `a{sv}` contents.
const Contents = struct {
    arena: std.heap.ArenaAllocator,
    dict: Dict,
    fn create(allocator: std.mem.Allocator, dict: Dict) !*Contents {
        const self = try allocator.create(Contents);
        self.* = .{ .arena = .init(allocator), .dict = undefined };
        errdefer {
            self.arena.deinit();
            allocator.destroy(self);
        }
        self.dict = try @import("desktop-portal-options.zig").clone(self.arena.allocator(), dict);
        return self;
    }
    fn destroy(self: *Contents) void {
        const allocator = self.arena.child_allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }
    fn get(self: *const Contents, key: []const u8, signature: []const u8) ?dbus.Value {
        return lookup(self.dict.entries, key, signature);
    }
};
/// A dictionary value of the given type, or null when missing or of another type.
fn lookup(entries: []const Dict.Entry, key: []const u8, signature: []const u8) ?dbus.Value {
    for (entries) |entry| if (eq(entry.key, key)) {
        var buffer: [256]u8 = undefined;
        const actual = entry.value.signatureInto(&buffer) catch return null;
        return if (eq(actual, signature)) entry.value else null;
    };
    return null;
}
/// A value from an `a{sv}` given as a Value.
fn lookupValue(dict: dbus.Value, key: []const u8, signature: []const u8) ?dbus.Value {
    const items = switch (dict) {
        .array => |array| array.items,
        else => return null,
    };
    for (items) |item| if (eq(item.dict_entry[0].string, key)) {
        const value = item.dict_entry[1].variant.*;
        var buffer: [256]u8 = undefined;
        const actual = value.signatureInto(&buffer) catch return null;
        return if (eq(actual, signature)) value else null;
    };
    return null;
}
fn string(value: ?dbus.Value) []const u8 {
    return if (value) |v| v.string else "";
}
const Notice = struct {
    service: *Service,
    owner: [:0]u8,
    app: [:0]u8,
    key: [:0]u8,
    id: u32 = 0,
    pending: bool = false,
    removed: bool = false,
    current: ?*Contents = null,
    next: ?*Contents = null,
    fn destroy(self: *Notice) void {
        if (self.current) |value| value.destroy();
        if (self.next) |value| value.destroy();
        const allocator = self.service.allocator;
        allocator.free(self.owner);
        allocator.free(self.app);
        allocator.free(self.key);
        allocator.destroy(self);
    }
};
const Send = struct { notice: *Notice, contents: *Contents, generation: u64, serial: u32 = 0 };
const Hints = Dict;
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
            send.contents.destroy();
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
    pub fn add(self: *Service, owner: [:0]const u8, app: [:0]const u8, key: [:0]const u8, contents: Dict) !void {
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
        const copy = try Contents.create(self.allocator, contents);
        notice.removed = false;
        if (notice.next) |old| old.destroy();
        notice.next = copy;
        try self.sendNext(notice);
    }
    pub fn remove(self: *Service, owner: []const u8, key: []const u8) void {
        for (self.notices.items) |notice| if (eq(notice.owner, owner) and eq(notice.key, key)) {
            notice.removed = true;
            if (notice.next) |old| old.destroy();
            notice.next = null;
            self.closeId(notice.id);
            self.collect(notice);
            return;
        };
    }
    /// Adds an `image-data` hint for a bytes icon, or returns an icon name or file path.
    /// Icons are serialized GIcons: `('themed', <as>)`, `('file', <s>)` or `('bytes', <ay>)`.
    fn icon(arena: std.mem.Allocator, contents: *const Contents, hints: *std.ArrayList(Hints.Entry)) ![]const u8 {
        const value = contents.get("icon", "(sv)") orelse return "";
        const kind = value.structure[0].string;
        const data = value.structure[1].variant.*;
        if (eq(kind, "themed")) {
            const names = switch (data) {
                .array => |array| if (eq(array.element, "s")) array.items else return "",
                else => return "",
            };
            return if (names.len > 0) arena.dupe(u8, names[0].string) else "";
        }
        if (eq(kind, "file")) {
            const uri = switch (data) {
                .string => |text| text,
                else => return "",
            };
            if (!std.mem.startsWith(u8, uri, "file://")) return "";
            const path = try arena.dupe(u8, uri["file://".len..]);
            return std.Uri.percentDecodeInPlace(path);
        }
        if (eq(kind, "bytes")) {
            const encoded = switch (data) {
                .bytes => |bytes| bytes,
                else => return "",
            };
            const decode = @import("desktop-decode.zig");
            const image = decode.bytes(arena, encoded, 128) orelse return "";
            defer decode.free(arena, image);
            const rgba = try image.straightRgba(arena);
            const width: i32 = @intCast(image.width);
            // (iiibiiay): width, height, stride, alpha, bits per sample, channels, pixels.
            const fields = try arena.dupe(dbus.Value, &.{ .{ .int32 = width }, .{ .int32 = @intCast(image.height) }, .{ .int32 = width * 4 }, .{ .boolean = true }, .{ .int32 = 8 }, .{ .int32 = 4 }, .{ .bytes = rgba } });
            try hints.append(arena, .{ .key = "image-data", .value = .{ .structure = fields } });
        }
        return "";
    }
    fn sendNext(self: *Service, notice: *Notice) !void {
        if (notice.pending or notice.removed or self.stopping or notice.next == null) return;
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const temporary = arena.allocator();
        const contents = notice.next.?;
        const level = string(contents.get("priority", "s"));
        const urgency: u8 = if (eq(level, "urgent") or eq(level, "high")) 2 else if (eq(level, "low")) 0 else 1;
        var hints: std.ArrayList(Hints.Entry) = .empty;
        try hints.append(temporary, .{ .key = "urgency", .value = .{ .byte = urgency } });
        try hints.append(temporary, .{ .key = "desktop-entry", .value = .{ .string = notice.app } });
        const icon_name = try icon(temporary, contents, &hints);
        var actions: std.ArrayList([]const u8) = .empty;
        try actions.appendSlice(temporary, &.{ "default", "" });
        if (contents.get("buttons", "aa{sv}")) |buttons| for (buttons.array.items[0..@min(buttons.array.items.len, 16)], 0..) |button, index| {
            try actions.append(temporary, try std.fmt.allocPrint(temporary, "button{d}", .{index}));
            try actions.append(temporary, string(lookupValue(button, "label", "s")));
        };
        // The body is plain text; the notification server reads markup.
        var escaped: std.ArrayList(u8) = .empty;
        try @import("desktop-command.zig").escapeMarkup(temporary, &escaped, std.mem.sliceTo(string(contents.get("body", "s")), 0));
        const send = try self.allocator.create(Send);
        errdefer self.allocator.destroy(send);
        send.* = .{ .notice = notice, .contents = contents, .generation = self.generation };
        try self.sends.ensureUnusedCapacity(self.allocator, 1);
        send.serial = try self.connection.call(.{ .destination = fdo, .path = object_path, .interface = fdo, .member = "Notify" }, .{ @as([]const u8, notice.app), notice.id, icon_name, string(contents.get("title", "s")), @as([]const u8, escaped.items), @as([]const []const u8, actions.items), Hints{ .entries = hints.items }, @as(i32, -1) }, 10000, &sent, send);
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
            send.contents.destroy();
            notice.removed = true;
            notice.id = 0;
        } else if (id) |value| {
            notice.id = value;
            if (notice.current) |old| old.destroy();
            notice.current = send.contents;
        } else {
            send.contents.destroy();
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
            const current = notice.current.?;
            var action: ?dbus.Value = null;
            var target: ?dbus.Value = null;
            if (eq(action_key, "default")) {
                action = current.get("default-action", "s");
                for (current.dict.entries) |entry| if (eq(entry.key, "default-action-target")) {
                    target = entry.value;
                };
            } else if (std.mem.startsWith(u8, action_key, "button")) {
                const index = std.fmt.parseInt(usize, action_key[6..], 10) catch return;
                const buttons = (current.get("buttons", "aa{sv}") orelse return).array.items;
                if (index >= @min(buttons.len, 16)) return;
                const button = buttons[index];
                action = lookupValue(button, "action", "s") orelse return;
                for (button.array.items) |item| if (eq(item.dict_entry[0].string, "target")) {
                    target = item.dict_entry[1].variant.*;
                };
            } else return;
            var arena: std.heap.ArenaAllocator = .init(self.allocator);
            defer arena.deinit();
            var parameter: [1]dbus.Value = undefined;
            var arguments: []const dbus.Value = &.{};
            if (target) |value| {
                parameter[0] = value;
                arguments = &parameter;
            }
            const name = if (action) |value| value.string else "default";
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

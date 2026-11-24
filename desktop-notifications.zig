//! Freedesktop notification service with GNOME banners and persistent history.
const native = @import("desktop-surface.zig");
const banner = @import("desktop-notification-banner.zig");
const std = @import("std");
const view = banner;
const decode = @import("desktop-decode.zig");
const mainloop = @import("desktop-loop.zig");
const util = @import("desktop-util.zig");
const dbus = @import("dbus");
const loop = @import("desktop-dbus-loop.zig");
const cast = util.cast;
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
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    id: u32,
    app: [:0]const u8,
    title: [:0]const u8,
    body: [:0]const u8,
    icon: [:0]const u8,
    sender: [:0]const u8,
    actions: []view.Action,
    created: i64,
    image: ?decode.Image = null,
    critical: bool = false,
    transient: bool = false,
    resident: bool = false,
    pending: bool = true,

    fn destroy(self: *Notice) void {
        if (self.image) |image| decode.free(self.allocator, image);
        self.arena.deinit();
        self.allocator.destroy(self);
    }
    fn data(self: *Notice) view.Data {
        return .{ .id = self.id, .app = self.app, .title = self.title, .body = self.body, .icon = self.icon, .image = self.image, .actions = self.actions, .created = self.created };
    }
};
const Server = struct {
    allocator: std.mem.Allocator,
    /// The shared session connection, once the service has registered its objects.
    connection: ?*dbus.Connection = null,
    registrations: [2]u32 = .{ 0, 0 },
    owned: bool = false,
    notices: std.ArrayList(*Notice) = .empty,
    next_id: u32 = 1,
    active: ?*Notice = null,
    card: ?banner.View = null,
    client: ?*native.Client = null,
    surface: ?*native.Surface = null,
    theme: banner.Theme = .{},
    timer: u32 = 0,
    hovered: bool = false,
    calendar_open: bool = false,

    fn start(self: *Server) !void {
        self.client = try native.Client.createInteractive(self.allocator, .{ .added = &outputAdded, .removed = &outputRemoved, .changed = &outputChanged }, self);
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
        try self.map(client.outputs.items[0]);
    }
    fn map(self: *Server, output: *native.Output) !void {
        const notice = self.active orelse return;
        if (self.card == null) self.card = banner.View.init(self.allocator, notice.data(), self.theme, 529);
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
        if (self.timer != 0) _ = mainloop.remove(self.timer);
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
        if (self.connection) |connection| connection.emit(path, control, "Changed", .{}) catch {};
    }
    fn hide(self: *Server) void {
        if (self.timer != 0) _ = mainloop.remove(self.timer);
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
        if (!notice.critical) self.timer = mainloop.timeout(4000, self, expired);
    }
    fn close(self: *Server, id: u32, reason: u32) void {
        for (self.notices.items, 0..) |notice, i| if (notice.id == id) {
            if (self.active == notice) self.hide();
            if (self.connection) |connection| connection.emitTo(notice.sender, path, name, "NotificationClosed", .{ id, reason }) catch {};
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
        if (exists) if (self.connection) |connection| connection.emitTo(notice.sender, path, name, "ActionInvoked", .{ id, @as([]const u8, key) }) catch {};
        if (!notice.resident) self.close(id, 2);
    }
    fn expired(self: *Server) bool {
        self.timer = 0;
        if (self.hovered) return false;
        const notice = self.active orelse return false;
        if (notice.transient) self.close(notice.id, 1) else {
            self.hide();
            self.showNext();
        }
        return false;
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
            if (self.timer != 0) _ = mainloop.remove(self.timer);
            self.timer = mainloop.timeout(200, self, expired);
        };
    }
    fn deinit(self: *Server) void {
        self.hide();
        if (self.client) |client| client.destroy();
        for (self.notices.items) |notice| notice.destroy();
        self.notices.deinit(self.allocator);
        if (self.connection) |connection| {
            for (self.registrations) |id| {
                if (id != 0) connection.unregister(id);
            }
        }
    }
    fn notify(self: *Server, sender: []const u8, args: NotifyArgs) !u32 {
        const notice = try self.allocator.create(Notice);
        notice.* = .{ .allocator = self.allocator, .arena = std.heap.ArenaAllocator.init(self.allocator), .id = 0, .app = "", .title = "", .body = "", .icon = "", .sender = "", .actions = &.{}, .created = @divTrunc(util.realTime(), 1000000) };
        errdefer notice.destroy();
        const a = notice.arena.allocator();
        notice.app = try clip(a, args[0], 150);
        notice.icon = try clip(a, args[2], 4096);
        if (notice.icon.len == 0) notice.icon = "application-x-executable-symbolic";
        notice.title = try clip(a, args[3], 150);
        notice.body = try clip(a, args[4], 850);
        notice.sender = try a.dupeSentinel(u8, sender, 0);
        const old_id = args[1];
        const hints = args[6];
        notice.critical = hintByte(hints, "urgency") == 2;
        notice.transient = hintBool(hints, "transient");
        notice.resident = hintBool(hints, "resident");
        if (hintString(hints, "desktop-entry")) |entry| {
            const id = try std.fmt.allocPrintSentinel(a, "{s}.desktop", .{entry}, 0);
            if (@import("desktop-appinfo.zig").lookup(self.allocator, id)) |info| {
                defer info.unref();
                notice.app = try a.dupeSentinel(u8, info.display_name, 0);
                if (info.icon_value) |icon| notice.icon = try a.dupeSentinel(u8, icon, 0);
            }
        }
        notice.image = imageHint(self.allocator, hints);
        const actions = args[5][0..@min(args[5].len, 64)];
        notice.actions = try a.alloc(view.Action, actions.len / 2);
        for (notice.actions, 0..) |*action, i| action.* = .{ .key = try clip(a, actions[i * 2], 128), .label = try clip(a, actions[i * 2 + 1], 150) };
        if (self.find(old_id)) |old| if (std.mem.eql(u8, old.sender, sender)) {
            notice.id = old.id;
            const was_active = self.active == old;
            if (was_active) self.hide();
            for (self.notices.items) |*item| if (item.* == old) {
                item.* = notice;
                break;
            };
            old.destroy();
            if (self.calendar_open or (!notice.critical and !@import("desktop-quick-settings.zig").bannersEnabled(self.allocator))) notice.pending = false;
            self.changed();
            self.showNext();
            return notice.id;
        };
        while (self.next_id == 0 or self.find(self.next_id) != null) self.next_id +%= 1;
        notice.id = self.next_id;
        self.next_id +%= 1;
        if (self.notices.items.len >= 100) self.close(self.notices.items[0].id, 1);
        try self.notices.append(self.allocator, notice);
        if (self.calendar_open or (!notice.critical and !@import("desktop-quick-settings.zig").bannersEnabled(self.allocator))) notice.pending = false;
        if (notice.critical and self.active != null and !self.active.?.critical) self.hide();
        self.changed();
        self.showNext();
        return notice.id;
    }
    fn list(self: *Server) ![:0]u8 {
        const Record = struct { id: u32, app: []const u8, title: []const u8, body: []const u8, icon: []const u8, created: i64, actions: []view.Action };
        const records = try self.allocator.alloc(Record, self.notices.items.len);
        defer self.allocator.free(records);
        for (records, self.notices.items) |*record, notice| record.* = .{ .id = notice.id, .app = notice.app, .title = notice.title, .body = notice.body, .icon = notice.icon, .created = notice.created, .actions = notice.actions };
        const json = try std.json.Stringify.valueAlloc(self.allocator, records, .{});
        defer self.allocator.free(json);
        return self.allocator.dupeSentinel(u8, json, 0);
    }
};
const Hints = dbus.Dict([]const u8, dbus.Value);
/// Notify's arguments: app, replaces, icon, summary, body, actions, hints, timeout.
const NotifyArgs = struct { []const u8, u32, []const u8, []const u8, []const u8, []const []const u8, Hints, i32 };
/// Copies at most `limit` characters, with line breaks flattened to spaces.
fn clip(a: std.mem.Allocator, text: []const u8, limit: usize) ![:0]const u8 {
    var end: usize = 0;
    var count: usize = 0;
    while (end < text.len and count < limit) : (count += 1) end += std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
    const result = try a.dupeSentinel(u8, text[0..@min(end, text.len)], 0);
    for (result) |*ch| if (ch.* == '\n' or ch.* == '\r') {
        ch.* = ' ';
    };
    return result;
}
fn hint(hints: Hints, key: []const u8) ?dbus.Value {
    for (hints.entries) |entry| if (std.mem.eql(u8, entry.key, key)) return entry.value;
    return null;
}
fn hintBool(hints: Hints, key: []const u8) bool {
    return switch (hint(hints, key) orelse return false) {
        .boolean => |value| value,
        else => false,
    };
}
fn hintByte(hints: Hints, key: []const u8) u8 {
    return switch (hint(hints, key) orelse return 1) {
        .byte => |value| value,
        else => 1,
    };
}
fn hintString(hints: Hints, key: []const u8) ?[]const u8 {
    return switch (hint(hints, key) orelse return null) {
        .string => |value| value,
        else => null,
    };
}
fn imageHint(a: std.mem.Allocator, hints: Hints) ?decode.Image {
    for ([_][]const u8{ "image-data", "image_data", "icon_data" }) |key| {
        // (iiibiiay): width, height, stride, alpha, bits per sample, channels, pixels.
        const fields = switch (hint(hints, key) orelse continue) {
            .structure => |value| value,
            else => continue,
        };
        if (fields.len != 7) continue;
        const width = switch (fields[0]) {
            .int32 => |v| v,
            else => continue,
        };
        const height = switch (fields[1]) {
            .int32 => |v| v,
            else => continue,
        };
        const stride = switch (fields[2]) {
            .int32 => |v| v,
            else => continue,
        };
        const alpha = switch (fields[3]) {
            .boolean => |v| v,
            else => continue,
        };
        const bits = switch (fields[4]) {
            .int32 => |v| v,
            else => continue,
        };
        const channels = switch (fields[5]) {
            .int32 => |v| v,
            else => continue,
        };
        const bytes = switch (fields[6]) {
            .bytes => |v| v,
            else => continue,
        };
        if (width <= 0 or height <= 0 or width > 4096 or height > 4096 or bits != 8 or channels != @as(i32, if (alpha) 4 else 3) or stride < width * channels) return null;
        const row: usize = @intCast(width * channels);
        if (bytes.len < @as(usize, @intCast(stride)) * @as(usize, @intCast(height - 1)) + row) return null;
        return decode.Image.normalize(a, .{ .pixels = bytes, .width = @intCast(width), .height = @intCast(height), .stride = @intCast(stride), .format = if (alpha) .rgba else .rgb }) catch null;
    }
    const value = hintString(hints, "image-path") orelse return null;
    const files = @import("desktop-paths.zig");
    const file = (if (std.mem.startsWith(u8, value, "file://")) files.pathFromUri(a, value) else a.dupeSentinel(u8, value, 0) catch null) orelse return null;
    defer a.free(file);
    if (std.fs.path.isAbsolute(file)) return @import("desktop-decode.zig").file(a, file, 48);
    return null;
}
fn method(data: ?*anyopaque, message: *const dbus.Message) void {
    const self = cast(Server, data);
    const connection = self.connection.?;
    const interface = message.interface orelse name;
    const member = message.member orelse "";
    const sender = message.sender orelse "";
    const eq = std.mem.eql;
    if (eq(u8, interface, control)) {
        if (eq(u8, member, "List")) {
            const json = self.list() catch return connection.replyError(message, "org.freedesktop.DBus.Error.NoMemory", "Cannot serialize notifications") catch {};
            defer self.allocator.free(json);
            return connection.reply(message, .{@as([]const u8, json)}) catch {};
        } else if (eq(u8, member, "Clear")) {
            while (self.notices.items.len > 0) self.close(self.notices.items[0].id, 2);
        } else if (eq(u8, member, "CalendarOpen")) {
            self.calendar_open = (message.read(struct { bool }) catch return)[0];
            if (self.calendar_open) {
                self.hide();
                for (self.notices.items) |notice| notice.pending = false;
            }
        } else if (eq(u8, member, "Dismiss")) {
            self.close((message.read(struct { u32 }) catch return)[0], 2);
        } else if (eq(u8, member, "Activate")) {
            const args = message.read(struct { u32, []const u8 }) catch return;
            const key = self.allocator.dupeSentinel(u8, args[1], 0) catch return;
            defer self.allocator.free(key);
            Server.activate(self, args[0], key);
        }
        return connection.reply(message, .{}) catch {};
    }
    if (eq(u8, member, "Notify")) {
        const args = message.read(NotifyArgs) catch return connection.replyError(message, "org.freedesktop.DBus.Error.InvalidArgs", "Invalid notification") catch {};
        const id = self.notify(sender, args) catch return connection.replyError(message, "org.freedesktop.DBus.Error.NoMemory", "Cannot create notification") catch {};
        connection.reply(message, .{id}) catch {};
    } else if (eq(u8, member, "GetCapabilities")) {
        const capabilities: []const []const u8 = &.{ "body", "body-markup", "actions", "icon-static", "persistence" };
        connection.reply(message, .{capabilities}) catch {};
    } else if (eq(u8, member, "GetServerInformation")) {
        connection.reply(message, .{ "Desktop Notifications", "dotfiles", "0.1", "1.2" }) catch {};
    } else if (eq(u8, member, "CloseNotification")) {
        const id = (message.read(struct { u32 }) catch return)[0];
        if (self.find(id)) |notice| if (eq(u8, notice.sender, sender)) self.close(id, 3);
        connection.reply(message, .{}) catch {};
    }
}
/// Called when another process takes the notification name; the shell quits, as before.
pub var on_lost: ?*const fn () void = null;
pub const Service = struct {
    server: Server,
    introspection: dbus.Introspection,
    source: ?*loop.Source = null,
    lost_subscription: u32 = 0,

    pub fn create(allocator: std.mem.Allocator) !*Service {
        const self = try allocator.create(Service);
        errdefer allocator.destroy(self);
        var introspection = try dbus.Introspection.parse(allocator, xml);
        errdefer introspection.deinit();
        self.* = .{ .server = .{ .allocator = allocator }, .introspection = introspection };
        errdefer {
            self.server.deinit();
            if (self.source) |source| loop.release(source);
        }
        try self.server.start();
        const source = loop.acquire(allocator, .session) catch return error.NoSessionBus;
        self.source = source;
        const connection = source.connection;
        self.server.connection = connection;
        for (self.introspection.interfaces, 0..) |*info, i| self.server.registrations[i] = try connection.exportObject(path, info, &method, null, &self.server);
        self.lost_subscription = try connection.subscribeArg0("org.freedesktop.DBus", "org.freedesktop.DBus", "NameLost", "/org/freedesktop/DBus", name, &lost, self);
        // Like g_bus_own_name without flags: wait in the queue if another daemon owns the name.
        const code = connection.requestName(name, 0) catch 0;
        self.server.owned = code == 1;
        if (!self.server.owned) std.log.warn("notifications: {s} is owned by another process", .{name});
        return self;
    }

    pub fn isOwned(self: *Service) bool {
        return self.server.owned;
    }

    pub fn destroy(self: *Service) void {
        if (self.source) |source| {
            const connection = source.connection;
            if (self.lost_subscription != 0) connection.unsubscribe(self.lost_subscription);
            if (self.server.owned) connection.send(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "ReleaseName" }, .{name}) catch {};
        }
        self.server.deinit();
        if (self.source) |source| loop.release(source);
        self.introspection.deinit();
        self.server.allocator.destroy(self);
    }
    fn lost(data: ?*anyopaque, _: *const dbus.Message) void {
        const self: *Service = @ptrCast(@alignCast(data));
        self.server.owned = false;
        if (on_lost) |quit| quit();
    }
};

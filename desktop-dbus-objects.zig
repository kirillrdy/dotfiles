//! A client for `org.freedesktop.DBus.ObjectManager`, like GDBusObjectManagerClient:
//! it follows the service's owner, mirrors its objects and their properties, and
//! reports changes.
const std = @import("std");
const dbus = @import("dbus");

pub const Event = union(enum) {
    /// The service gained or lost its owner; all objects were dropped.
    owner,
    /// Objects or interfaces were added or removed.
    objects,
    properties,
    /// A signal from an interface passed to `forward`.
    signal: struct { path: []const u8, interface: []const u8, member: []const u8 },
};
pub const Handler = *const fn (context: ?*anyopaque, event: Event) void;

pub const Interface = struct {
    name: []u8,
    /// Holds the property values; replaced whole when properties change.
    arena: *std.heap.ArenaAllocator,
    properties: []const Values.Entry = &.{},

    pub fn property(self: *const Interface, key: []const u8) ?dbus.Value {
        for (self.properties) |entry| if (std.mem.eql(u8, entry.key, key)) return entry.value;
        return null;
    }
};
pub const Object = struct {
    path: []u8,
    interfaces: std.ArrayList(Interface) = .empty,

    pub fn interface(self: *Object, name: []const u8) ?*Interface {
        for (self.interfaces.items) |*item| if (std.mem.eql(u8, item.name, name)) return item;
        return null;
    }
};

const Values = dbus.Dict([]const u8, dbus.Value);
const Interfaces = dbus.Dict([]const u8, Values);
const Managed = dbus.Dict(dbus.ObjectPath, Interfaces);

pub const Manager = struct {
    allocator: std.mem.Allocator,
    connection: *dbus.Connection,
    name: []u8,
    root: []u8,
    handler: Handler,
    context: ?*anyopaque,
    watcher: ?*dbus.NameWatcher = null,
    owner: ?[]u8 = null,
    objects: std.ArrayList(*Object) = .empty,
    subscriptions: std.ArrayList(u32) = .empty,
    /// The pending GetManagedObjects call.
    serial: u32 = 0,

    pub fn create(allocator: std.mem.Allocator, connection: *dbus.Connection, name: []const u8, root: []const u8, handler: Handler, context: ?*anyopaque) !*Manager {
        const self = try allocator.create(Manager);
        self.* = .{ .allocator = allocator, .connection = connection, .name = &.{}, .root = &.{}, .handler = handler, .context = context };
        errdefer self.destroy();
        self.name = try allocator.dupe(u8, name);
        self.root = try allocator.dupe(u8, root);
        const manager = "org.freedesktop.DBus.ObjectManager";
        try self.subscriptions.append(allocator, try connection.subscribe(name, manager, "InterfacesAdded", root, &added, self));
        try self.subscriptions.append(allocator, try connection.subscribe(name, manager, "InterfacesRemoved", root, &removed, self));
        try self.subscriptions.append(allocator, try connection.subscribe(name, "org.freedesktop.DBus.Properties", "PropertiesChanged", null, &changed, self));
        self.watcher = try dbus.NameWatcher.create(connection, name, &appeared, &vanished, self);
        return self;
    }
    pub fn destroy(self: *Manager) void {
        if (self.watcher) |watcher| watcher.destroy();
        if (self.serial != 0) self.connection.cancel(self.serial);
        for (self.subscriptions.items) |id| self.connection.unsubscribe(id);
        self.subscriptions.deinit(self.allocator);
        self.clear();
        self.objects.deinit(self.allocator);
        if (self.owner) |owner| self.allocator.free(owner);
        self.allocator.free(self.root);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }
    /// Reports signals of `interface` from the service's objects as `Event.signal`.
    pub fn forward(self: *Manager, name: []const u8) !void {
        try self.subscriptions.ensureUnusedCapacity(self.allocator, 1);
        self.subscriptions.appendAssumeCapacity(try self.connection.subscribe(self.name, name, null, null, &signalled, self));
    }
    pub fn object(self: *Manager, path: []const u8) ?*Object {
        for (self.objects.items) |item| if (std.mem.eql(u8, item.path, path)) return item;
        return null;
    }
    pub fn interface(self: *Manager, path: []const u8, name: []const u8) ?*Interface {
        return (self.object(path) orelse return null).interface(name);
    }

    fn clear(self: *Manager) void {
        for (self.objects.items) |item| self.freeObject(item);
        self.objects.clearRetainingCapacity();
    }
    fn freeObject(self: *Manager, item: *Object) void {
        for (item.interfaces.items) |entry| self.freeInterface(entry);
        item.interfaces.deinit(self.allocator);
        self.allocator.free(item.path);
        self.allocator.destroy(item);
    }
    fn freeInterface(self: *Manager, entry: Interface) void {
        entry.arena.deinit();
        self.allocator.destroy(entry.arena);
        self.allocator.free(entry.name);
    }

    fn appeared(context: ?*anyopaque, owner: []const u8) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        self.reset();
        self.owner = self.allocator.dupe(u8, owner) catch null;
        self.serial = self.connection.call(.{ .destination = self.name, .path = self.root, .interface = "org.freedesktop.DBus.ObjectManager", .member = "GetManagedObjects" }, .{}, 25000, &listed, self) catch 0;
        self.handler(self.context, .owner);
    }
    fn vanished(context: ?*anyopaque) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        self.reset();
        self.handler(self.context, .owner);
    }
    fn reset(self: *Manager) void {
        if (self.serial != 0) self.connection.cancel(self.serial);
        self.serial = 0;
        self.clear();
        if (self.owner) |owner| self.allocator.free(owner);
        self.owner = null;
    }
    fn listed(context: ?*anyopaque, reply: dbus.Reply) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        self.serial = 0;
        const message = switch (reply) {
            .ok => |message| message,
            .failed => |failure| return std.log.warn("objects: {s} GetManagedObjects failed: {s}", .{ self.name, failure.text }),
        };
        const managed = (message.read(struct { Managed }) catch return)[0];
        for (managed.entries) |entry| self.add(entry.key.value, entry.value) catch {};
        self.handler(self.context, .objects);
    }
    fn added(context: ?*anyopaque, message: *const dbus.Message) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        if (self.owner == null) return;
        const args = message.read(struct { dbus.ObjectPath, Interfaces }) catch return;
        self.add(args[0].value, args[1]) catch {};
        self.handler(self.context, .objects);
    }
    fn add(self: *Manager, path: []const u8, interfaces: Interfaces) !void {
        const item = self.object(path) orelse blk: {
            const created = try self.allocator.create(Object);
            errdefer self.allocator.destroy(created);
            created.* = .{ .path = try self.allocator.dupe(u8, path) };
            errdefer self.allocator.free(created.path);
            try self.objects.append(self.allocator, created);
            break :blk created;
        };
        for (interfaces.entries) |entry| {
            const fresh = try self.copy(entry.value.entries);
            if (item.interface(entry.key)) |existing| {
                existing.arena.deinit();
                self.allocator.destroy(existing.arena);
                existing.arena = fresh.arena;
                existing.properties = fresh.properties;
                continue;
            }
            const name = self.allocator.dupe(u8, entry.key) catch {
                fresh.arena.deinit();
                self.allocator.destroy(fresh.arena);
                return error.OutOfMemory;
            };
            item.interfaces.append(self.allocator, .{ .name = name, .arena = fresh.arena, .properties = fresh.properties }) catch {
                self.allocator.free(name);
                fresh.arena.deinit();
                self.allocator.destroy(fresh.arena);
                return error.OutOfMemory;
            };
        }
    }
    /// Deep-copies properties into a new arena, as message storage is short-lived.
    fn copy(self: *Manager, entries: []const Values.Entry) !struct { arena: *std.heap.ArenaAllocator, properties: []const Values.Entry } {
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(self.allocator);
        errdefer {
            arena.deinit();
            self.allocator.destroy(arena);
        }
        const properties = try arena.allocator().alloc(Values.Entry, entries.len);
        for (properties, entries) |*out, entry| out.* = .{ .key = try arena.allocator().dupe(u8, entry.key), .value = try entry.value.clone(arena.allocator()) };
        return .{ .arena = arena, .properties = properties };
    }
    fn removed(context: ?*anyopaque, message: *const dbus.Message) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        const args = message.read(struct { dbus.ObjectPath, []const []const u8 }) catch return;
        const item = self.object(args[0].value) orelse return;
        for (args[1]) |name| {
            for (item.interfaces.items, 0..) |entry, i| if (std.mem.eql(u8, entry.name, name)) {
                self.freeInterface(entry);
                _ = item.interfaces.orderedRemove(i);
                break;
            };
        }
        if (item.interfaces.items.len == 0) {
            for (self.objects.items, 0..) |other, i| if (other == item) {
                _ = self.objects.orderedRemove(i);
                break;
            };
            self.freeObject(item);
        }
        self.handler(self.context, .objects);
    }
    fn changed(context: ?*anyopaque, message: *const dbus.Message) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        const args = message.read(struct { []const u8, Values, []const []const u8 }) catch return;
        const entry = self.interface(message.path orelse return, args[0]) orelse return;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const old = Values{ .entries = entry.properties };
        var merged: std.ArrayList(Values.Entry) = .empty;
        for (old.entries) |value| {
            const replaced = for (args[1].entries) |update| {
                if (std.mem.eql(u8, update.key, value.key)) break true;
            } else for (args[2]) |key| {
                if (std.mem.eql(u8, key, value.key)) break true;
            } else false;
            if (!replaced) merged.append(arena.allocator(), value) catch return;
        }
        merged.appendSlice(arena.allocator(), args[1].entries) catch return;
        const fresh = self.copy(merged.items) catch return;
        entry.arena.deinit();
        self.allocator.destroy(entry.arena);
        entry.arena = fresh.arena;
        entry.properties = fresh.properties;
        self.handler(self.context, .properties);
    }
    fn signalled(context: ?*anyopaque, message: *const dbus.Message) void {
        const self: *Manager = @ptrCast(@alignCast(context));
        self.handler(self.context, .{ .signal = .{ .path = message.path orelse "", .interface = message.interface orelse "", .member = message.member orelse "" } });
    }
};

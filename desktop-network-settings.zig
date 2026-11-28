//! NetworkManager connection settings (`a{sa{sv}}`): groups of named values.
//! Shared by reference between state snapshots, editors and pending saves.
const std = @import("std");
const dbus = @import("dbus");

/// The wire form, as sent to and read from NetworkManager.
pub const Wire = dbus.Dict([]const u8, Properties);
pub const Properties = dbus.Dict([]const u8, dbus.Value);

pub const Property = struct { key: []const u8, value: dbus.Value };
pub const Group = struct {
    name: []const u8,
    properties: std.ArrayList(Property) = .empty,

    pub fn get(self: *const Group, key: []const u8) ?dbus.Value {
        for (self.properties.items) |item| if (std.mem.eql(u8, item.key, key)) return item.value;
        return null;
    }
};

pub const Settings = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    groups: std.ArrayList(Group) = .empty,
    refs: usize = 1,

    pub fn create(allocator: std.mem.Allocator) !*Settings {
        const self = try allocator.create(Settings);
        self.* = .{ .allocator = allocator, .arena = .init(allocator) };
        return self;
    }
    /// Copies settings read from a message.
    pub fn fromWire(allocator: std.mem.Allocator, source: Wire) !*Settings {
        const self = try create(allocator);
        errdefer self.unref();
        for (source.entries) |entry| {
            _ = try self.ensureGroup(entry.key);
            for (entry.value.entries) |property| try self.put(entry.key, property.key, property.value);
        }
        return self;
    }
    pub fn ref(self: *Settings) *Settings {
        self.refs += 1;
        return self;
    }
    pub fn unref(self: *Settings) void {
        self.refs -= 1;
        if (self.refs > 0) return;
        const allocator = self.allocator;
        self.arena.deinit();
        allocator.destroy(self);
    }
    pub fn group(self: *Settings, name: []const u8) ?*Group {
        for (self.groups.items) |*item| if (std.mem.eql(u8, item.name, name)) return item;
        return null;
    }
    pub fn ensureGroup(self: *Settings, name: []const u8) !*Group {
        if (self.group(name)) |existing| return existing;
        try self.groups.append(self.arena.allocator(), .{ .name = try self.arena.allocator().dupe(u8, name) });
        return &self.groups.items[self.groups.items.len - 1];
    }
    pub fn get(self: *Settings, group_name: []const u8, key: []const u8) ?dbus.Value {
        return (self.group(group_name) orelse return null).get(key);
    }
    /// The string at `group_name.key`, or "" when missing or of another type.
    pub fn text(self: *Settings, group_name: []const u8, key: []const u8) []const u8 {
        return switch (self.get(group_name, key) orelse return "") {
            .string => |value| value,
            else => "",
        };
    }
    /// The bytes at `group_name.key`, or "" when missing or of another type.
    pub fn bytes(self: *Settings, group_name: []const u8, key: []const u8) []const u8 {
        return switch (self.get(group_name, key) orelse return "") {
            .bytes => |value| value,
            else => "",
        };
    }
    /// Sets a property to a copy of `value`, adding the group when needed.
    pub fn put(self: *Settings, group_name: []const u8, key: []const u8, value: dbus.Value) !void {
        const target = try self.ensureGroup(group_name);
        const copy = try value.clone(self.arena.allocator());
        for (target.properties.items) |*item| if (std.mem.eql(u8, item.key, key)) {
            item.value = copy;
            return;
        };
        try target.properties.append(self.arena.allocator(), .{ .key = try self.arena.allocator().dupe(u8, key), .value = copy });
    }
    pub fn remove(self: *Settings, group_name: []const u8, key: []const u8) void {
        const target = self.group(group_name) orelse return;
        for (target.properties.items, 0..) |item, i| if (std.mem.eql(u8, item.key, key)) {
            _ = target.properties.orderedRemove(i);
            return;
        };
    }
    /// The wire form; it borrows from `self` and allocates its tables from `arena`.
    pub fn wire(self: *Settings, arena: std.mem.Allocator) !Wire {
        const entries = try arena.alloc(Wire.Entry, self.groups.items.len);
        for (entries, self.groups.items) |*entry, item| {
            const properties = try arena.alloc(Properties.Entry, item.properties.items.len);
            for (properties, item.properties.items) |*out, property| out.* = .{ .key = property.key, .value = property.value };
            entry.* = .{ .key = item.name, .value = .{ .entries = properties } };
        }
        return .{ .entries = entries };
    }
};

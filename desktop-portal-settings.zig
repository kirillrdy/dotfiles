//! Portal settings read directly from the desktop's GSettings schemas.
const std = @import("std");
const mainloop = @import("desktop-loop.zig");
const util = @import("desktop-util.zig");
const dbus = @import("dbus");
const Settings = @import("desktop-gsettings.zig").Settings;
const schemas = [_][:0]const u8{
    "org.gnome.desktop.a11y",           "org.gnome.desktop.a11y.interface",
    "org.gnome.desktop.calendar",       "org.gnome.desktop.input-sources",
    "org.gnome.desktop.interface",      "org.gnome.desktop.peripherals.mouse",
    "org.gnome.desktop.privacy",        "org.gnome.desktop.sound",
    "org.gnome.desktop.wm.preferences", "org.gnome.settings-daemon.plugins.xsettings",
};
const appearance = "org.freedesktop.appearance";
const fontconfig = "org.gnome.fontconfig";
const eq = util.eq;
const cast = util.cast;
const Bundle = struct {
    service: *Service,
    name: [:0]const u8,
    settings: *Settings,
};
pub const Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    connection: *dbus.Connection,
    bundles: std.ArrayList(*Bundle) = .empty,
    fonts: ?*@import("desktop-watch.zig").Watcher = null,
    serial: i32 = 0,
    timer: u32 = 0,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, connection: *dbus.Connection) !*Service {
        const self = try allocator.create(Service);
        self.* = .{ .allocator = allocator, .io = io, .connection = connection };
        errdefer self.destroy();
        for (schemas) |name| {
            const settings = Settings.open(allocator, io, name, null) orelse continue;
            const bundle = allocator.create(Bundle) catch |err| {
                settings.close();
                return err;
            };
            bundle.* = .{ .service = self, .name = name, .settings = settings };
            self.bundles.append(allocator, bundle) catch |err| {
                settings.close();
                allocator.destroy(bundle);
                return err;
            };
            try settings.watch(&changed, bundle);
        }
        // Font changes invalidate fontconfig caches in clients.
        if (@import("desktop-watch.zig").Watcher.create(allocator, io, &fontsChanged, self)) |watcher| {
            self.fonts = watcher;
            try watcher.watch("/etc/fonts");
            if (std.c.getenv("HOME")) |home| {
                const directory = try std.fmt.allocPrint(allocator, "{s}/.fonts", .{home});
                defer allocator.free(directory);
                try watcher.watch(directory);
            }
            const fonts = try std.fmt.allocPrint(allocator, "{s}/fonts", .{@import("desktop-paths.zig").dataHome()});
            defer allocator.free(fonts);
            try watcher.watch(fonts);
        } else |_| {}
        return self;
    }
    pub fn destroy(self: *Service) void {
        if (self.timer != 0) _ = mainloop.remove(self.io, self.timer);
        if (self.fonts) |watcher| watcher.destroy();
        for (self.bundles.items) |bundle| {
            bundle.settings.close();
            self.allocator.destroy(bundle);
        }
        self.bundles.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    fn emit(self: *Service, namespace: []const u8, key: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const value = (self.read(arena.allocator(), namespace, key) catch return) orelse return;
        self.connection.emit("/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "SettingChanged", .{ namespace, key, value }) catch {};
    }
    fn changed(data: ?*anyopaque, key: []const u8) void {
        const bundle = cast(Bundle, data);
        bundle.service.emit(bundle.name, key);
        if (eq(bundle.name, "org.gnome.desktop.interface") and eq(key, "color-scheme")) bundle.service.emit(appearance, "color-scheme");
        if (eq(bundle.name, "org.gnome.desktop.a11y.interface") and eq(key, "high-contrast")) bundle.service.emit(appearance, "contrast");
    }
    fn fontsChanged(data: ?*anyopaque) void {
        const self = cast(Service, data);
        if (self.timer == 0) self.timer = mainloop.timeout(self.io, 100, self, fontsSettled);
    }
    fn fontsSettled(self: *Service) bool {
        self.timer = 0;
        self.serial +%= 1;
        self.emit(fontconfig, "serial");
        return false;
    }
    /// A setting's value, allocated from `arena`; null for unknown settings.
    pub fn read(self: *Service, arena: std.mem.Allocator, namespace: []const u8, key: []const u8) !?dbus.Value {
        if (eq(namespace, fontconfig)) return if (eq(key, "serial")) .{ .int32 = self.serial } else null;
        if (eq(namespace, appearance)) {
            if (eq(key, "color-scheme")) {
                for (self.bundles.items) |bundle| if (eq(bundle.name, "org.gnome.desktop.interface") and bundle.settings.hasKey("color-scheme")) return .{ .uint32 = @intCast(bundle.settings.enumeration("color-scheme")) };
                return .{ .uint32 = 0 };
            }
            if (eq(key, "contrast")) {
                for (self.bundles.items) |bundle| if (eq(bundle.name, "org.gnome.desktop.a11y.interface") and bundle.settings.hasKey("high-contrast")) return .{ .uint32 = @intFromBool(bundle.settings.boolean("high-contrast")) };
                return .{ .uint32 = 0 };
            }
            return null;
        }
        for (self.bundles.items) |bundle| if (eq(bundle.name, namespace)) return bundle.settings.get(arena, key);
        return null;
    }
    fn matches(namespace: []const u8, patterns: []const []const u8) bool {
        if (patterns.len == 0) return true;
        for (patterns) |pattern| {
            if (pattern.len == 0 or eq(pattern, namespace)) return true;
            if (std.mem.endsWith(u8, pattern, "*") and std.mem.startsWith(u8, namespace, pattern[0 .. pattern.len - 1])) return true;
        }
        return false;
    }
    const Values = dbus.Dict([]const u8, dbus.Value);
    const Namespaces = dbus.Dict([]const u8, Values);
    /// Every setting in the namespaces matching `patterns`, allocated from `arena`.
    pub fn readAll(self: *Service, arena: std.mem.Allocator, patterns: []const []const u8) !Namespaces {
        var namespaces: std.ArrayList(Namespaces.Entry) = .empty;
        for (self.bundles.items) |bundle| {
            if (!matches(bundle.name, patterns)) continue;
            var values: std.ArrayList(Values.Entry) = .empty;
            for (try bundle.settings.keys(arena)) |key| {
                const value = try self.read(arena, bundle.name, key) orelse continue;
                try values.append(arena, .{ .key = key, .value = value });
            }
            try namespaces.append(arena, .{ .key = bundle.name, .value = .{ .entries = values.items } });
        }
        if (matches(appearance, patterns)) {
            var values: std.ArrayList(Values.Entry) = .empty;
            inline for (.{ "color-scheme", "contrast" }) |key| try values.append(arena, .{ .key = key, .value = (try self.read(arena, appearance, key)).? });
            try namespaces.append(arena, .{ .key = appearance, .value = .{ .entries = values.items } });
        }
        if (matches(fontconfig, patterns)) {
            const values = try arena.dupe(Values.Entry, &.{.{ .key = "serial", .value = .{ .int32 = self.serial } }});
            try namespaces.append(arena, .{ .key = fontconfig, .value = .{ .entries = values } });
        }
        return .{ .entries = namespaces.items };
    }
    /// Answers Read, ReadOne and ReadAll.
    pub fn call(self: *Service, method: []const u8, message: *const dbus.Message) !void {
        const connection = self.connection;
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        if (eq(method, "ReadAll")) {
            const patterns = (try message.read(struct { []const []const u8 }))[0];
            return connection.reply(message, .{try self.readAll(arena.allocator(), patterns)});
        }
        const args = try message.read(struct { []const u8, []const u8 });
        const key = args[1];
        const value = try self.read(arena.allocator(), args[0], key) orelse return connection.replyError(message, "org.freedesktop.portal.Error.NotFound", "Requested setting not found");
        // The deprecated Read wraps the value in a second variant.
        if (eq(method, "Read")) return connection.reply(message, .{dbus.Value{ .variant = &value }});
        try connection.reply(message, .{value});
    }
};

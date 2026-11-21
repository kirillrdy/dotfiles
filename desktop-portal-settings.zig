//! Portal settings read directly from the desktop's GSettings schemas.
const std = @import("std");
const c = @import("desktop-glib.zig");
const dbus = @import("dbus");
const bridge = @import("desktop-dbus-gvariant.zig");
const schemas = [_][:0]const u8{
    "org.gnome.desktop.a11y",           "org.gnome.desktop.a11y.interface",
    "org.gnome.desktop.calendar",       "org.gnome.desktop.input-sources",
    "org.gnome.desktop.interface",      "org.gnome.desktop.peripherals.mouse",
    "org.gnome.desktop.privacy",        "org.gnome.desktop.sound",
    "org.gnome.desktop.wm.preferences", "org.gnome.settings-daemon.plugins.xsettings",
};
const appearance = "org.freedesktop.appearance";
const fontconfig = "org.gnome.fontconfig";
const eq = c.__zig.eq;
const cast = c.__zig.cast;
const Bundle = struct {
    service: *Service,
    name: [:0]const u8,
    schema: *c.GSettingsSchema,
    settings: *c.GSettings,
};
pub const Service = struct {
    allocator: std.mem.Allocator,
    connection: *dbus.Connection,
    bundles: std.ArrayList(*Bundle) = .empty,
    monitors: std.ArrayList(*c.GFileMonitor) = .empty,
    serial: i32 = 0,
    timer: c.guint = 0,

    pub fn create(allocator: std.mem.Allocator, connection: *dbus.Connection) !*Service {
        const self = try allocator.create(Service);
        self.* = .{ .allocator = allocator, .connection = connection };
        errdefer self.destroy();
        const source = c.g_settings_schema_source_get_default();
        if (source != null) for (schemas) |name| {
            const schema = c.g_settings_schema_source_lookup(source, name, 1) orelse continue;
            const bundle = allocator.create(Bundle) catch |err| {
                c.g_settings_schema_unref(schema);
                return err;
            };
            bundle.* = .{ .service = self, .name = name, .schema = schema, .settings = c.g_settings_new_full(schema, null, null) };
            self.bundles.append(allocator, bundle) catch |err| {
                c.g_object_unref(bundle.settings);
                c.g_settings_schema_unref(schema);
                allocator.destroy(bundle);
                return err;
            };
            _ = c.g_signal_connect_data(bundle.settings, "changed", @ptrCast(&changed), bundle, null, 0);
        };
        try self.watch("/etc/fonts");
        if (c.__zig.getenv("HOME")) |home| {
            const directory = try std.fmt.allocPrintSentinel(allocator, "{s}/.fonts", .{home}, 0);
            defer allocator.free(directory);
            try self.watch(directory);
        }
        const data = c.g_get_user_data_dir();
        const fonts = try std.fmt.allocPrintSentinel(allocator, "{s}/fonts", .{data}, 0);
        defer allocator.free(fonts);
        try self.watch(fonts);
        return self;
    }
    pub fn destroy(self: *Service) void {
        if (self.timer != 0) _ = c.g_source_remove(self.timer);
        for (self.monitors.items) |monitor| {
            _ = c.g_signal_handlers_disconnect_matched(monitor, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
            _ = c.g_file_monitor_cancel(monitor);
            c.g_object_unref(monitor);
        }
        for (self.bundles.items) |bundle| {
            _ = c.g_signal_handlers_disconnect_matched(bundle.settings, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, bundle);
            c.g_object_unref(bundle.settings);
            c.g_settings_schema_unref(bundle.schema);
            self.allocator.destroy(bundle);
        }
        self.bundles.deinit(self.allocator);
        self.monitors.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    fn watch(self: *Service, directory: [*:0]const u8) !void {
        const file = c.g_file_new_for_path(directory);
        defer c.g_object_unref(file);
        const monitor = c.g_file_monitor_directory(file, 0, null, null) orelse return;
        errdefer c.g_object_unref(monitor);
        try self.monitors.append(self.allocator, monitor);
        _ = c.g_signal_connect_data(monitor, "changed", @ptrCast(&fontsChanged), self, null, 0);
    }
    fn emit(self: *Service, namespace: []const u8, key: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const key_z = arena.allocator().dupeSentinel(u8, key, 0) catch return;
        const value = (self.read(arena.allocator(), namespace, key_z) catch return) orelse return;
        self.connection.emit("/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "SettingChanged", .{ namespace, key, value }) catch {};
    }
    fn changed(_: *c.GSettings, key: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const bundle = cast(Bundle, data);
        bundle.service.emit(bundle.name, std.mem.span(key));
        if (eq(bundle.name, "org.gnome.desktop.interface") and eq(std.mem.span(key), "color-scheme")) bundle.service.emit(appearance, "color-scheme");
        if (eq(bundle.name, "org.gnome.desktop.a11y.interface") and eq(std.mem.span(key), "high-contrast")) bundle.service.emit(appearance, "contrast");
    }
    fn fontsChanged(_: *c.GFileMonitor, _: ?*c.GFile, _: ?*c.GFile, _: c_uint, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Service, data);
        if (self.timer == 0) self.timer = c.g_timeout_add(100, &fontsSettled, self);
    }
    fn fontsSettled(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Service, data);
        self.timer = 0;
        self.serial +%= 1;
        self.emit(fontconfig, "serial");
        return 0;
    }
    /// A setting's value, allocated from `arena`; null for unknown settings.
    pub fn read(self: *Service, arena: std.mem.Allocator, namespace: []const u8, key: [*:0]const u8) !?dbus.Value {
        if (eq(namespace, fontconfig)) return if (eq(std.mem.span(key), "serial")) .{ .int32 = self.serial } else null;
        if (eq(namespace, appearance)) {
            if (eq(std.mem.span(key), "color-scheme")) {
                for (self.bundles.items) |bundle| if (eq(bundle.name, "org.gnome.desktop.interface") and c.g_settings_schema_has_key(bundle.schema, "color-scheme") != 0) return .{ .uint32 = @intCast(c.g_settings_get_enum(bundle.settings, "color-scheme")) };
                return .{ .uint32 = 0 };
            }
            if (eq(std.mem.span(key), "contrast")) {
                for (self.bundles.items) |bundle| if (eq(bundle.name, "org.gnome.desktop.a11y.interface") and c.g_settings_schema_has_key(bundle.schema, "high-contrast") != 0) return .{ .uint32 = @intFromBool(c.g_settings_get_boolean(bundle.settings, "high-contrast") != 0) };
                return .{ .uint32 = 0 };
            }
            return null;
        }
        // GSettings hands out GVariants; this is where they become D-Bus values.
        for (self.bundles.items) |bundle| if (eq(bundle.name, namespace) and c.g_settings_schema_has_key(bundle.schema, key) != 0) return try bridge.fromVariant(arena, c.g_settings_get_value(bundle.settings, key).?);
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
            const keys = c.g_settings_schema_list_keys(bundle.schema);
            defer c.g_strfreev(keys);
            var i: usize = 0;
            while (keys[i] != null) : (i += 1) {
                const value = try self.read(arena, bundle.name, keys[i]) orelse continue;
                try values.append(arena, .{ .key = try arena.dupe(u8, std.mem.span(keys[i])), .value = value });
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
        const key = try arena.allocator().dupeSentinel(u8, args[1], 0);
        const value = try self.read(arena.allocator(), args[0], key) orelse return connection.replyError(message, "org.freedesktop.portal.Error.NotFound", "Requested setting not found");
        // The deprecated Read wraps the value in a second variant.
        if (eq(method, "Read")) return connection.reply(message, .{dbus.Value{ .variant = &value }});
        try connection.reply(message, .{value});
    }
};

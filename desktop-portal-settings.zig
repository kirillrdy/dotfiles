//! Portal settings read directly from the desktop's GSettings schemas.
const std = @import("std");
const c = @import("desktop-gtk.zig");
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
fn builder(signature: [*:0]const u8) *c.GVariantBuilder {
    return c.g_variant_builder_new(@ptrCast(signature)).?;
}
const Bundle = struct {
    service: *Service,
    name: [:0]const u8,
    schema: *c.GSettingsSchema,
    settings: *c.GSettings,
};
pub const Service = struct {
    allocator: std.mem.Allocator,
    connection: *c.GDBusConnection,
    bundles: std.ArrayList(*Bundle) = .empty,
    monitors: std.ArrayList(*c.GFileMonitor) = .empty,
    serial: i32 = 0,
    timer: c.guint = 0,

    pub fn create(allocator: std.mem.Allocator, connection: *c.GDBusConnection) !*Service {
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
        const home = c.g_getenv("HOME");
        if (home != null) {
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
    fn emit(self: *Service, namespace: [*:0]const u8, key: [*:0]const u8, value: ?*c.GVariant) void {
        const owned = c.g_variant_take_ref(value);
        defer c.g_variant_unref(owned);
        _ = c.g_dbus_connection_emit_signal(self.connection, null, "/org/freedesktop/portal/desktop", "org.freedesktop.portal.Settings", "SettingChanged", c.g_variant_new("(ssv)", namespace, key, owned), null);
    }
    fn changed(_: *c.GSettings, key: [*:0]const u8, data: ?*anyopaque) callconv(.c) void {
        const bundle = cast(Bundle, data);
        bundle.service.emit(bundle.name, key, c.g_settings_get_value(bundle.settings, key));
        if (eq(bundle.name, "org.gnome.desktop.interface") and eq(std.mem.span(key), "color-scheme")) bundle.service.emit(appearance, "color-scheme", bundle.service.read(appearance, "color-scheme"));
        if (eq(bundle.name, "org.gnome.desktop.a11y.interface") and eq(std.mem.span(key), "high-contrast")) bundle.service.emit(appearance, "contrast", bundle.service.read(appearance, "contrast"));
    }
    fn fontsChanged(_: *c.GFileMonitor, _: ?*c.GFile, _: ?*c.GFile, _: c_uint, data: ?*anyopaque) callconv(.c) void {
        const self = cast(Service, data);
        if (self.timer == 0) self.timer = c.g_timeout_add(100, &fontsSettled, self);
    }
    fn fontsSettled(data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Service, data);
        self.timer = 0;
        self.serial +%= 1;
        self.emit(fontconfig, "serial", c.g_variant_new("i", self.serial));
        return 0;
    }
    pub fn read(self: *Service, namespace: []const u8, key: [*:0]const u8) ?*c.GVariant {
        if (eq(namespace, fontconfig)) return if (eq(std.mem.span(key), "serial")) c.g_variant_new("i", self.serial) else null;
        if (eq(namespace, appearance)) {
            if (eq(std.mem.span(key), "color-scheme")) {
                for (self.bundles.items) |bundle| if (eq(bundle.name, "org.gnome.desktop.interface") and c.g_settings_schema_has_key(bundle.schema, "color-scheme") != 0) return c.g_variant_new("u", @as(c_uint, @intCast(c.g_settings_get_enum(bundle.settings, "color-scheme"))));
                return c.g_variant_new("u", @as(c_uint, 0));
            }
            if (eq(std.mem.span(key), "contrast")) {
                for (self.bundles.items) |bundle| if (eq(bundle.name, "org.gnome.desktop.a11y.interface") and c.g_settings_schema_has_key(bundle.schema, "high-contrast") != 0) return c.g_variant_new("u", @as(c_uint, @intFromBool(c.g_settings_get_boolean(bundle.settings, "high-contrast") != 0)));
                return c.g_variant_new("u", @as(c_uint, 0));
            }
            return null;
        }
        for (self.bundles.items) |bundle| if (eq(bundle.name, namespace) and c.g_settings_schema_has_key(bundle.schema, key) != 0) return c.g_settings_get_value(bundle.settings, key);
        return null;
    }
    fn matches(namespace: []const u8, patterns: ?*c.GVariant) bool {
        const count = c.g_variant_n_children(patterns);
        if (count == 0) return true;
        for (0..count) |index| {
            const value = c.g_variant_get_child_value(patterns, index);
            defer c.g_variant_unref(value);
            const pattern = std.mem.span(c.g_variant_get_string(value, null));
            if (pattern.len == 0 or eq(pattern, namespace)) return true;
            if (std.mem.endsWith(u8, pattern, "*") and std.mem.startsWith(u8, namespace, pattern[0 .. pattern.len - 1])) return true;
        }
        return false;
    }
    pub fn readAll(self: *Service, patterns: ?*c.GVariant) ?*c.GVariant {
        const outer = builder("a{sa{sv}}");
        defer c.g_variant_builder_unref(outer);
        for (self.bundles.items) |bundle| {
            if (!matches(bundle.name, patterns)) continue;
            const inner = builder("a{sv}");
            defer c.g_variant_builder_unref(inner);
            const keys = c.g_settings_schema_list_keys(bundle.schema);
            defer c.g_strfreev(keys);
            var i: usize = 0;
            while (keys[i] != null) : (i += 1) {
                const value = self.read(bundle.name, keys[i]);
                defer c.g_variant_unref(c.g_variant_take_ref(value));
                c.g_variant_builder_add(inner, "{sv}", keys[i], value);
            }
            c.g_variant_builder_add(outer, "{s@a{sv}}", bundle.name.ptr, c.g_variant_builder_end(inner));
        }
        if (matches(appearance, patterns)) {
            const inner = builder("a{sv}");
            defer c.g_variant_builder_unref(inner);
            inline for (.{ "color-scheme", "contrast" }) |key| {
                const value = c.g_variant_take_ref(self.read(appearance, key));
                defer c.g_variant_unref(value);
                c.g_variant_builder_add(inner, "{sv}", @as([*:0]const u8, key), value);
            }
            c.g_variant_builder_add(outer, "{s@a{sv}}", @as([*:0]const u8, appearance), c.g_variant_builder_end(inner));
        }
        if (matches(fontconfig, patterns)) {
            const inner = builder("a{sv}");
            defer c.g_variant_builder_unref(inner);
            c.g_variant_builder_add(inner, "{sv}", @as([*:0]const u8, "serial"), c.g_variant_new("i", self.serial));
            c.g_variant_builder_add(outer, "{s@a{sv}}", @as([*:0]const u8, fontconfig), c.g_variant_builder_end(inner));
        }
        return c.g_variant_builder_end(outer);
    }
    pub fn call(self: *Service, method: []const u8, params: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation) void {
        const namespace = c.g_variant_get_child_value(params, 0);
        defer c.g_variant_unref(namespace);
        if (eq(method, "ReadAll")) {
            c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(@a{sa{sv}})", self.readAll(namespace)));
            return;
        }
        const key = c.g_variant_get_child_value(params, 1);
        defer c.g_variant_unref(key);
        const value = self.read(std.mem.span(c.g_variant_get_string(namespace, null)), c.g_variant_get_string(key, null));
        if (value == null) {
            c.g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.portal.Error.NotFound", "Requested setting not found");
            return;
        }
        const owned = c.g_variant_take_ref(value);
        defer c.g_variant_unref(owned);
        if (eq(method, "Read")) {
            const wrapped = c.g_variant_take_ref(c.g_variant_new("v", owned));
            defer c.g_variant_unref(wrapped);
            c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(v)", wrapped));
        } else c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(v)", owned));
    }
};

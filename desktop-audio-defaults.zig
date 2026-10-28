//! Default audio devices through PipeWire metadata, without a client plugin.
const std = @import("std");
const c = @import("gtk");
const w = @import("audio-api");
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;

const Device = struct { name: []const u8 };
fn decode(bytes: []const u8) !std.json.Parsed(Device) {
    // Metadata comes from another client; bound parser allocations.
    if (bytes.len > 64 * 1024) return error.InvalidDefaultDevice;
    return std.json.parseFromSlice(Device, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}
fn encode(name: []const u8) ![:0]u8 {
    const json = try std.json.Stringify.valueAlloc(a, Device{ .name = name }, .{});
    defer a.free(json);
    return a.dupeSentinel(u8, json, 0);
}

pub const Defaults = struct {
    manager: ?*w.WpObjectManager = null,
    metadata: ?*w.WpMetadata = null,
    callback: *const fn (?*anyopaque) void,
    data: ?*anyopaque,

    pub fn connect(self: *Defaults, core: *w.WpCore) bool {
        self.manager = w.wp_object_manager_new() orelse return false;
        w.wp_object_manager_add_interest(self.manager, w.wp_metadata_get_type(), w.WP_CONSTRAINT_TYPE_PW_GLOBAL_PROPERTY, @as([*:0]const u8, "metadata.name"), @as([*:0]const u8, "=s"), @as([*:0]const u8, "default"), @as(?*anyopaque, null));
        w.wp_object_manager_request_object_features(self.manager, w.wp_metadata_get_type(), w.WP_OBJECT_FEATURES_ALL);
        _ = c.g_signal_connect_data(self.manager, "objects-changed", @ptrCast(&objectsChanged), self, null, 0);
        w.wp_core_install_object_manager(core, self.manager);
        return true;
    }
    fn clearMetadata(self: *Defaults) void {
        if (self.metadata) |metadata| {
            _ = c.g_signal_handlers_disconnect_matched(metadata, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
            c.g_object_unref(metadata);
        }
        self.metadata = null;
    }
    pub fn disconnect(self: *Defaults) void {
        self.clearMetadata();
        if (self.manager) |manager| {
            _ = c.g_signal_handlers_disconnect_matched(manager, c.G_SIGNAL_MATCH_DATA, 0, 0, null, null, self);
            c.g_object_unref(manager);
        }
        self.manager = null;
    }
    fn objectsChanged(_: ?*w.WpObjectManager, data: ?*anyopaque) callconv(.c) void {
        const self: *Defaults = @ptrCast(@alignCast(data.?));
        self.clearMetadata();
        if (w.wp_object_manager_new_iterator(self.manager)) |iterator| {
            defer w.wp_iterator_unref(iterator);
            var value = std.mem.zeroes(c.GValue);
            if (w.wp_iterator_next(iterator, &value) != 0) {
                defer c.g_value_unset(&value);
                self.metadata = @ptrCast(c.g_object_ref(w.g_value_get_object(&value)));
                _ = c.g_signal_connect_data(self.metadata, "changed", @ptrCast(&metadataChanged), self, null, 0);
            }
        }
        self.callback(self.data);
    }
    fn metadataChanged(_: ?*w.WpMetadata, subject: u32, key: [*c]const u8, _: [*c]const u8, _: [*c]const u8, data: ?*anyopaque) callconv(.c) void {
        if (subject != 0) return;
        if (key != null and !std.mem.eql(u8, std.mem.span(key), "default.audio.sink") and !std.mem.eql(u8, std.mem.span(key), "default.audio.source")) return;
        const self: *Defaults = @ptrCast(@alignCast(data.?));
        self.callback(self.data);
    }
    pub fn id(self: *Defaults, nodes: ?*w.WpObjectManager, output: bool) u32 {
        const invalid = std.math.maxInt(u32);
        const metadata = self.metadata orelse return invalid;
        var kind: [*c]const u8 = null;
        const json = w.wp_metadata_find(metadata, 0, if (output) "default.audio.sink" else "default.audio.source", &kind);
        if (json == null or kind == null or !std.mem.eql(u8, std.mem.span(kind), "Spa:String:JSON")) return invalid;
        const device = decode(std.mem.span(json)) catch return invalid;
        defer device.deinit();
        const iterator = w.wp_object_manager_new_iterator(nodes) orelse return invalid;
        defer w.wp_iterator_unref(iterator);
        var value = std.mem.zeroes(c.GValue);
        while (w.wp_iterator_next(iterator, &value) != 0) {
            defer c.g_value_unset(&value);
            const object: *w.WpPipewireObject = @ptrCast(w.g_value_get_object(&value) orelse continue);
            const name = w.wp_pipewire_object_get_property(object, "node.name");
            const class = w.wp_pipewire_object_get_property(object, "media.class");
            if (name != null and class != null and std.mem.eql(u8, std.mem.span(name), device.value.name) and std.mem.eql(u8, std.mem.span(class), if (output) "Audio/Sink" else "Audio/Source")) return w.wp_proxy_get_bound_id(@ptrCast(object));
        }
        return invalid;
    }
    pub fn set(self: *Defaults, output: bool, name: []const u8) bool {
        const metadata = self.metadata orelse return false;
        const json = encode(name) catch return false;
        defer a.free(json);
        w.wp_metadata_set(metadata, 0, if (output) "default.configured.audio.sink" else "default.configured.audio.source", "Spa:String:JSON", json.ptr);
        return true;
    }
};

test "default device metadata handles escaping, unknown fields and invalid names" {
    const name = "speakers \"USB\" \\ output\n日本語";
    const json = try encode(name);
    defer a.free(json);
    const device = try decode(json);
    defer device.deinit();
    try std.testing.expectEqualStrings(name, device.value.name);
    const extra = try decode("{\"other\":42,\"name\":\"sink\"}");
    defer extra.deinit();
    try std.testing.expectEqualStrings("sink", extra.value.name);
    try std.testing.expectError(error.MissingField, decode("{}"));
    try std.testing.expectError(error.UnexpectedToken, decode("{\"name\":42}"));
    try std.testing.expectError(error.InvalidDefaultDevice, decode(&@as([65537]u8, @splat(' '))));
}

//! Audio control through cached PipeWire Props and device Route parameters.
const std = @import("std");
const c = @import("gtk");
const w = @import("audio-api");
const p = @import("pipewire");
const end: ?*anyopaque = null;

fn find(manager: ?*w.WpObjectManager, id: u32) ?*w.WpPipewireObject {
    const iterator = w.wp_object_manager_new_iterator(manager) orelse return null;
    defer w.wp_iterator_unref(iterator);
    var value = std.mem.zeroes(c.GValue);
    while (w.wp_iterator_next(iterator, &value) != 0) {
        defer c.g_value_unset(&value);
        const object: *w.WpPipewireObject = @ptrCast(w.g_value_get_object(&value) orelse continue);
        if (w.wp_proxy_get_bound_id(@ptrCast(object)) == id) return @ptrCast(c.g_object_ref(object));
    }
    return null;
}

pub const Control = struct {
    object: *w.WpPipewireObject,
    route: ?struct { index: i32, device: i32 } = null,
    channels: [64]f32 = @splat(0),
    count: u32 = 0,
    scalar: f32 = 1,
    muted: bool = false,

    pub fn deinit(self: *Control) void {
        c.g_object_unref(self.object);
    }
    fn fill(self: *Control, props: *w.WpSpaPod) bool {
        var mute: c.gboolean = 0;
        var volumes: ?*w.WpSpaPod = null;
        const valid = w.wp_spa_pod_get_object(props, null, @as([*:0]const u8, "mute"), @as([*:0]const u8, "b"), &mute, @as([*:0]const u8, "channelVolumes"), @as([*:0]const u8, "P"), &volumes, end) != 0;
        defer if (volumes) |pod| w.wp_spa_pod_unref(pod);
        if (!valid) return false;
        const raw: *const p.spa_pod = @ptrCast(@alignCast(w.wp_spa_pod_get_spa_pod(volumes) orelse return false));
        if (raw.type != p.SPA_TYPE_Array or raw.size < @sizeOf(p.spa_pod_array_body)) return false;
        const array: *const p.spa_pod_array = @ptrCast(raw);
        if (array.body.child.type != p.SPA_TYPE_Float or array.body.child.size != @sizeOf(f32)) return false;
        const bytes = raw.size - @sizeOf(p.spa_pod_array_body);
        if (bytes % @sizeOf(f32) != 0 or bytes / @sizeOf(f32) > self.channels.len) return false;
        self.count = @intCast(bytes / @sizeOf(f32));
        const values: [*]const f32 = @ptrFromInt(@intFromPtr(raw) + @sizeOf(p.spa_pod_array));
        @memcpy(self.channels[0..self.count], values[0..self.count]);
        self.scalar = 1;
        _ = w.wp_spa_pod_get_object(props, null, @as([*:0]const u8, "volume"), @as([*:0]const u8, "?f"), &self.scalar, end);
        for (self.channels[0..self.count]) |v| if (!std.math.isFinite(v) or v < 0) return false;
        if (!std.math.isFinite(self.scalar) or self.scalar < 0) return false;
        self.muted = mute != 0;
        return true;
    }
    pub fn percent(self: *const Control) f64 {
        // Keep the desktop's existing first-channel, cubic volume scale.
        const linear: f64 = if (self.count > 0) self.channels[0] else self.scalar;
        return @min(std.math.cbrt(linear) * 100, 100);
    }
    fn scaled(self: *const Control, percent_value: f64) [64]f32 {
        const value = std.math.clamp(percent_value, 0, 100) / 100;
        const linear = value * value * value;
        var result = self.channels;
        for (result[0..self.count]) |*channel| {
            // Preserve relative channel levels. At silence there is no balance
            // to recover, so start all channels at the requested level.
            channel.* = @floatCast(if (self.channels[0] > 0) @as(f64, channel.*) / self.channels[0] * linear else linear);
        }
        return result;
    }
    fn parameter(self: *const Control, percent_value: ?f64, mute: ?bool) ?*w.WpSpaPod {
        const builder = w.wp_spa_pod_builder_new_object("Spa:Pod:Object:Param:Props", "Props") orelse return null;
        defer w.wp_spa_pod_builder_unref(builder);
        if (percent_value) |value| {
            const channels = self.scaled(value);
            if (self.count > 0) {
                w.wp_spa_pod_builder_add(builder, @as([*:0]const u8, "channelVolumes"), @as([*:0]const u8, "a"), @as(c_int, @sizeOf(f32)), @as(c_uint, p.SPA_TYPE_Float), self.count, &channels, end);
            } else {
                const fraction = std.math.clamp(value, 0, 100) / 100;
                w.wp_spa_pod_builder_add(builder, @as([*:0]const u8, "volume"), @as([*:0]const u8, "f"), fraction * fraction * fraction, end);
            }
        }
        if (mute) |value| w.wp_spa_pod_builder_add(builder, @as([*:0]const u8, "mute"), @as([*:0]const u8, "b"), @as(c_int, @intFromBool(value)), end);
        const props = w.wp_spa_pod_builder_end(builder) orelse return null;
        if (self.route) |route| {
            defer w.wp_spa_pod_unref(props);
            return w.wp_spa_pod_new_object("Spa:Pod:Object:Param:Route", "Route", @as([*:0]const u8, "index"), @as([*:0]const u8, "i"), route.index, @as([*:0]const u8, "device"), @as([*:0]const u8, "i"), route.device, @as([*:0]const u8, "props"), @as([*:0]const u8, "P"), props, @as([*:0]const u8, "save"), @as([*:0]const u8, "b"), @as(c_int, 1), end);
        }
        return props;
    }
    pub fn write(self: *Control, percent_value: ?f64, mute: ?bool) bool {
        const param = self.parameter(percent_value, mute) orelse return false;
        // set_param takes ownership of the pod, including on failure.
        return w.wp_pipewire_object_set_param(self.object, if (self.route != null) "Route" else "Props", 0, param) != 0;
    }
};

pub fn read(manager: ?*w.WpObjectManager, id: u32) ?Control {
    const node = find(manager, id) orelse return null;
    defer c.g_object_unref(node);
    const device_id = w.wp_pipewire_object_get_property(node, "device.id");
    const profile = w.wp_pipewire_object_get_property(node, "card.profile.device");
    if (device_id != null and profile != null) route: {
        const device_number = std.fmt.parseInt(u32, std.mem.span(device_id), 10) catch break :route;
        const profile_number = std.fmt.parseInt(i32, std.mem.span(profile), 10) catch break :route;
        const device = find(manager, device_number) orelse break :route;
        defer c.g_object_unref(device);
        const iterator = w.wp_pipewire_object_enum_params_sync(device, "Route", null) orelse break :route;
        defer w.wp_iterator_unref(iterator);
        var value = std.mem.zeroes(c.GValue);
        while (w.wp_iterator_next(iterator, &value) != 0) {
            defer c.g_value_unset(&value);
            const pod: *w.WpSpaPod = @ptrCast(w.g_value_get_boxed(&value) orelse continue);
            var index: i32 = -1;
            var route_device: i32 = -1;
            var props: ?*w.WpSpaPod = null;
            const ok = w.wp_spa_pod_get_object(pod, null, @as([*:0]const u8, "index"), @as([*:0]const u8, "i"), &index, @as([*:0]const u8, "device"), @as([*:0]const u8, "i"), &route_device, @as([*:0]const u8, "props"), @as([*:0]const u8, "P"), &props, end);
            defer if (props) |param| w.wp_spa_pod_unref(param);
            if (ok == 0 or route_device != profile_number) continue;
            var control = Control{ .object = device, .route = .{ .index = index, .device = route_device } };
            if (props != null and control.fill(props.?)) {
                _ = c.g_object_ref(device);
                return control;
            }
        }
    }
    const iterator = w.wp_pipewire_object_enum_params_sync(node, "Props", null) orelse return null;
    defer w.wp_iterator_unref(iterator);
    var value = std.mem.zeroes(c.GValue);
    while (w.wp_iterator_next(iterator, &value) != 0) {
        defer c.g_value_unset(&value);
        const pod: *w.WpSpaPod = @ptrCast(w.g_value_get_boxed(&value) orelse continue);
        var control = Control{ .object = node };
        if (control.fill(pod)) {
            _ = c.g_object_ref(node);
            return control;
        }
    }
    return null;
}

test "cubic volume conversion preserves channel balance and silence" {
    var control = Control{ .object = undefined, .channels = @splat(0), .count = 2 };
    control.channels[0] = 0.125;
    control.channels[1] = 0.015625;
    try std.testing.expectApproxEqAbs(@as(f64, 50), control.percent(), 0.0001);
    const channels = control.scaled(100);
    try std.testing.expectApproxEqAbs(@as(f32, 1), channels[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.125), channels[1], 0.0001);
    control.channels = @splat(0);
    const silence = control.scaled(50);
    try std.testing.expectApproxEqAbs(@as(f32, 0.125), silence[0], 0.0001);
    try std.testing.expectEqual(silence[0], silence[1]);
}

test "Props and saved device Route parameters carry cubic channel levels and mute" {
    var control = Control{ .object = undefined, .channels = @splat(0.125), .count = 2 };
    const props = control.parameter(25, true) orelse return error.NoProps;
    defer w.wp_spa_pod_unref(props);
    var decoded = Control{ .object = undefined };
    try std.testing.expect(decoded.fill(props));
    try std.testing.expect(decoded.muted);
    try std.testing.expectApproxEqAbs(@as(f64, 25), decoded.percent(), 0.0001);
    control.route = .{ .index = 7, .device = 3 };
    const route = control.parameter(75, false) orelse return error.NoRoute;
    defer w.wp_spa_pod_unref(route);
    var index: i32 = -1;
    var device: i32 = -1;
    var save: c.gboolean = 0;
    var nested: ?*w.WpSpaPod = null;
    defer if (nested) |pod| w.wp_spa_pod_unref(pod);
    try std.testing.expect(w.wp_spa_pod_get_object(route, null, @as([*:0]const u8, "index"), @as([*:0]const u8, "i"), &index, @as([*:0]const u8, "device"), @as([*:0]const u8, "i"), &device, @as([*:0]const u8, "save"), @as([*:0]const u8, "b"), &save, @as([*:0]const u8, "props"), @as([*:0]const u8, "P"), &nested, end) != 0);
    try std.testing.expectEqual(@as(i32, 7), index);
    try std.testing.expectEqual(@as(i32, 3), device);
    try std.testing.expect(save != 0);
    try std.testing.expect(decoded.fill(nested.?));
    try std.testing.expect(!decoded.muted);
    try std.testing.expectApproxEqAbs(@as(f64, 75), decoded.percent(), 0.0001);
}

test "unusable channel parameters are rejected" {
    const builder = w.wp_spa_pod_builder_new_object("Spa:Pod:Object:Param:Props", "Props").?;
    defer w.wp_spa_pod_builder_unref(builder);
    const channels = [_]f32{std.math.nan(f32)};
    w.wp_spa_pod_builder_add(builder, @as([*:0]const u8, "mute"), @as([*:0]const u8, "b"), @as(c_int, 0), @as([*:0]const u8, "channelVolumes"), @as([*:0]const u8, "a"), @as(c_int, @sizeOf(f32)), @as(c_uint, p.SPA_TYPE_Float), @as(c_uint, 1), &channels, end);
    const props = w.wp_spa_pod_builder_end(builder).?;
    defer w.wp_spa_pod_unref(props);
    var control = Control{ .object = undefined };
    try std.testing.expect(!control.fill(props));
}

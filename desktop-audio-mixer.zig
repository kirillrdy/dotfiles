//! Audio control through cached PipeWire Props and device Route parameters.
const std = @import("std");
const c = @import("gtk");
const w = @import("audio-api");
const p = @import("pipewire");
const Pod = @import("desktop-audio-pod.zig");
fn view(pod: *w.WpSpaPod) ?Pod.View {
    const raw: *const p.spa_pod = @ptrCast(@alignCast(w.wp_spa_pod_get_spa_pod(pod) orelse return null));
    if (raw.size > 1024 * 1024 - 8) return null;
    const bytes: [*]const u8 = @ptrCast(raw);
    return Pod.View.init(bytes[0 .. @sizeOf(p.spa_pod) + raw.size]) catch null;
}

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
    fn fill(self: *Control, props: Pod.View) bool {
        const object = props.object(p.SPA_TYPE_OBJECT_Props) catch return false;
        const mute = object.property(p.SPA_PROP_mute) orelse return false;
        const muted = mute.boolean() catch return false;
        var scalar: f32 = 1;
        const volume = object.property(p.SPA_PROP_volume);
        if (volume) |value| scalar = value.float() catch return false;
        if (!std.math.isFinite(scalar) or scalar < 0) return false;
        var channels: [64]f32 = @splat(0);
        var count: u32 = 0;
        if (object.property(p.SPA_PROP_channelVolumes)) |value| {
            const values = value.floats() catch return false;
            if (values.len > channels.len) return false;
            for (values) |v| if (!std.math.isFinite(v) or v < 0) return false;
            count = @intCast(values.len);
            @memcpy(channels[0..count], values);
        }
        if (count == 0 and volume == null) return false;
        self.channels = channels;
        self.count = count;
        self.scalar = scalar;
        self.muted = muted;
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
        var props_bytes: [512]u8 align(8) = undefined;
        var props = Pod.Builder.init(&props_bytes, p.SPA_TYPE_OBJECT_Props, p.SPA_PARAM_Props) catch return null;
        if (percent_value) |value| {
            if (!std.math.isFinite(value) or self.count > self.channels.len) return null;
            if (self.count > 0) {
                const channels = self.scaled(value);
                for (channels[0..self.count]) |channel| if (!std.math.isFinite(channel) or channel < 0) return null;
                props.floats(p.SPA_PROP_channelVolumes, channels[0..self.count]) catch return null;
            } else {
                const fraction = std.math.clamp(value, 0, 100) / 100;
                props.float(p.SPA_PROP_volume, @floatCast(fraction * fraction * fraction)) catch return null;
            }
        }
        if (mute) |value| props.boolean(p.SPA_PROP_mute, value) catch return null;
        var route_bytes: [768]u8 align(8) = undefined;
        var raw = props.view();
        if (self.route) |route| {
            var builder = Pod.Builder.init(&route_bytes, p.SPA_TYPE_OBJECT_ParamRoute, p.SPA_PARAM_Route) catch return null;
            builder.integer(p.SPA_PARAM_ROUTE_index, route.index) catch return null;
            builder.integer(p.SPA_PARAM_ROUTE_device, route.device) catch return null;
            builder.object(p.SPA_PARAM_ROUTE_props, raw) catch return null;
            builder.boolean(p.SPA_PARAM_ROUTE_save, true) catch return null;
            raw = builder.view();
        }
        const wrapped = w.wp_spa_pod_new_wrap_const(@ptrCast(@alignCast(raw.bytes.ptr))) orelse return null;
        defer w.wp_spa_pod_unref(wrapped);
        // set_param consumes its wrapper. Copy before the stack buffers expire.
        return w.wp_spa_pod_copy(wrapped);
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
            const raw = view(pod) orelse continue;
            const route_object = raw.object(p.SPA_TYPE_OBJECT_ParamRoute) catch continue;
            const index = (route_object.property(p.SPA_PARAM_ROUTE_index) orelse continue).integer() catch continue;
            const route_device = (route_object.property(p.SPA_PARAM_ROUTE_device) orelse continue).integer() catch continue;
            const props = route_object.property(p.SPA_PARAM_ROUTE_props) orelse continue;
            if (index < 0 or route_device != profile_number) continue;
            var control = Control{ .object = device, .route = .{ .index = index, .device = route_device } };
            if (control.fill(props)) {
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
        if (control.fill(view(pod) orelse continue)) {
            _ = c.g_object_ref(node);
            return control;
        }
    }
    return null;
}

// Independent WirePlumber encoding/parsing is retained only as a test oracle.
const end: ?*anyopaque = null;
const Reference = struct {
    const Builder = opaque {};
    extern fn wp_spa_pod_get_object(?*w.WpSpaPod, [*c][*c]const u8, ...) c.gboolean;
    extern fn wp_spa_pod_builder_new_object([*c]const u8, [*c]const u8) ?*Builder;
    extern fn wp_spa_pod_builder_add(?*Builder, ...) void;
    extern fn wp_spa_pod_builder_end(?*Builder) ?*w.WpSpaPod;
    extern fn wp_spa_pod_builder_unref(?*Builder) void;
};
comptime {
    _ = Pod;
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
    try std.testing.expect(decoded.fill(view(props).?));
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
    try std.testing.expect(Reference.wp_spa_pod_get_object(route, null, @as([*:0]const u8, "index"), @as([*:0]const u8, "i"), &index, @as([*:0]const u8, "device"), @as([*:0]const u8, "i"), &device, @as([*:0]const u8, "save"), @as([*:0]const u8, "b"), &save, @as([*:0]const u8, "props"), @as([*:0]const u8, "P"), &nested, end) != 0);
    try std.testing.expectEqual(@as(i32, 7), index);
    try std.testing.expectEqual(@as(i32, 3), device);
    try std.testing.expect(save != 0);
    try std.testing.expect(decoded.fill(view(nested.?).?));
    try std.testing.expect(!decoded.muted);
    try std.testing.expectApproxEqAbs(@as(f64, 75), decoded.percent(), 0.0001);
}

test "unusable channel parameters are rejected" {
    const builder = Reference.wp_spa_pod_builder_new_object("Spa:Pod:Object:Param:Props", "Props").?;
    defer Reference.wp_spa_pod_builder_unref(builder);
    const channels = [_]f32{std.math.nan(f32)};
    Reference.wp_spa_pod_builder_add(builder, @as([*:0]const u8, "mute"), @as([*:0]const u8, "b"), @as(c_int, 0), @as([*:0]const u8, "channelVolumes"), @as([*:0]const u8, "a"), @as(c_int, @sizeOf(f32)), @as(c_uint, p.SPA_TYPE_Float), @as(c_uint, 1), &channels, end);
    const props = Reference.wp_spa_pod_builder_end(builder).?;
    defer w.wp_spa_pod_unref(props);
    var control = Control{ .object = undefined };
    try std.testing.expect(!control.fill(view(props).?));
}

test "native reader accepts independent scalar-only Props and encoder preserves scalar control" {
    const builder = Reference.wp_spa_pod_builder_new_object("Spa:Pod:Object:Param:Props", "Props").?;
    defer Reference.wp_spa_pod_builder_unref(builder);
    Reference.wp_spa_pod_builder_add(builder, @as([*:0]const u8, "volume"), @as([*:0]const u8, "f"), @as(f64, 0.125), @as([*:0]const u8, "mute"), @as([*:0]const u8, "b"), @as(c_int, 1), end);
    const props = Reference.wp_spa_pod_builder_end(builder).?;
    defer w.wp_spa_pod_unref(props);
    var control = Control{ .object = undefined };
    try std.testing.expect(control.fill(view(props).?));
    try std.testing.expectEqual(@as(u32, 0), control.count);
    try std.testing.expectApproxEqAbs(@as(f64, 50), control.percent(), 0.0001);
    try std.testing.expect(control.muted);
    const written = control.parameter(75, false).?;
    defer w.wp_spa_pod_unref(written);
    var volume: f32 = 0;
    var mute: c.gboolean = 1;
    try std.testing.expect(Reference.wp_spa_pod_get_object(written, null, @as([*:0]const u8, "volume"), @as([*:0]const u8, "f"), &volume, @as([*:0]const u8, "mute"), @as([*:0]const u8, "b"), &mute, end) != 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.421875), volume, 0.000001);
    try std.testing.expectEqual(@as(c.gboolean, 0), mute);
}

test "native Props reader bounds arrays and leaves prior state intact on invalid input" {
    var bytes: [512]u8 align(8) = undefined;
    var builder = try Pod.Builder.init(&bytes, p.SPA_TYPE_OBJECT_Props, p.SPA_PARAM_Props);
    try builder.boolean(p.SPA_PROP_mute, true);
    try builder.floats(p.SPA_PROP_channelVolumes, &@as([64]f32, @splat(0.125)));
    var control = Control{ .object = undefined };
    try std.testing.expect(control.fill(builder.view()));
    try std.testing.expectEqual(@as(u32, 64), control.count);
    for ([_]f32{ -1, std.math.inf(f32), std.math.nan(f32) }) |invalid| {
        builder = try Pod.Builder.init(&bytes, p.SPA_TYPE_OBJECT_Props, p.SPA_PARAM_Props);
        try builder.boolean(p.SPA_PROP_mute, false);
        try builder.floats(p.SPA_PROP_channelVolumes, &.{invalid});
        try std.testing.expect(!control.fill(builder.view()));
        try std.testing.expect(control.muted and control.count == 64);
    }
    builder = try Pod.Builder.init(&bytes, p.SPA_TYPE_OBJECT_Props, p.SPA_PARAM_Props);
    try builder.boolean(p.SPA_PROP_mute, false);
    try builder.integer(p.SPA_PROP_channelVolumes, 1);
    try std.testing.expect(!control.fill(builder.view()));
    control.count = 65;
    try std.testing.expect(control.parameter(50, null) == null);
}

//! Audio control through cached PipeWire Props and device Route parameters.
const std = @import("std");
const c = @import("gtk");
const p = @import("pipewire");
const Pod = @import("audio-pod");
const Registry = @import("desktop-audio-registry.zig").Registry;
const Object = @import("desktop-audio-registry.zig").Object;
const Parameter = struct {
    props: [512]u8 align(8) = undefined,
    route: [768]u8 align(8) = undefined,
};

pub const Control = struct {
    object: *Object,
    route: ?struct { index: i32, device: i32 } = null,
    channels: [64]f32 = @splat(0),
    count: u32 = 0,
    scalar: f32 = 1,
    muted: bool = false,

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
    fn parameter(self: *const Control, buffer: *Parameter, percent_value: ?f64, mute: ?bool) ?Pod.View {
        var props = Pod.Builder.init(&buffer.props, p.SPA_TYPE_OBJECT_Props, p.SPA_PARAM_Props) catch return null;
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
        var raw = props.view();
        if (self.route) |route| {
            var builder = Pod.Builder.init(&buffer.route, p.SPA_TYPE_OBJECT_ParamRoute, p.SPA_PARAM_Route) catch return null;
            builder.integer(p.SPA_PARAM_ROUTE_index, route.index) catch return null;
            builder.integer(p.SPA_PARAM_ROUTE_device, route.device) catch return null;
            builder.object(p.SPA_PARAM_ROUTE_props, raw) catch return null;
            builder.boolean(p.SPA_PARAM_ROUTE_save, true) catch return null;
            raw = builder.view();
        }
        return raw;
    }
    pub fn write(self: *Control, percent_value: ?f64, mute: ?bool) bool {
        var buffer: Parameter = .{};
        return self.object.set(self.parameter(&buffer, percent_value, mute) orelse return false);
    }
};

pub fn read(registry: *Registry, id: u32) ?Control {
    const node = registry.find(id) orelse return null;
    if (node.kind != .node) return null;
    const device_id = node.property("device.id");
    const profile = node.property("card.profile.device");
    if (device_id != null and profile != null) route: {
        const device_number = std.fmt.parseInt(u32, std.mem.span(device_id), 10) catch break :route;
        const profile_number = std.fmt.parseInt(i32, std.mem.span(profile), 10) catch break :route;
        const device = registry.find(device_number) orelse break :route;
        if (device.kind != .device) break :route;
        for (device.params.items) |param| {
            const raw = Pod.View.init(param.bytes) catch continue;
            const route_object = raw.object(p.SPA_TYPE_OBJECT_ParamRoute) catch continue;
            const index = (route_object.property(p.SPA_PARAM_ROUTE_index) orelse continue).integer() catch continue;
            const route_device = (route_object.property(p.SPA_PARAM_ROUTE_device) orelse continue).integer() catch continue;
            const props = route_object.property(p.SPA_PARAM_ROUTE_props) orelse continue;
            if (index < 0 or route_device != profile_number) continue;
            var control = Control{ .object = device, .route = .{ .index = index, .device = route_device } };
            if (control.fill(props)) return control;
        }
    }
    for (node.params.items) |param| {
        var control = Control{ .object = node };
        if (control.fill(Pod.View.init(param.bytes) catch continue)) return control;
    }
    return null;
}
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
    var buffer: Parameter = .{};
    const props = control.parameter(&buffer, 25, true) orelse return error.NoProps;
    var decoded = Control{ .object = undefined };
    try std.testing.expect(decoded.fill(props));
    try std.testing.expect(decoded.muted);
    try std.testing.expectApproxEqAbs(@as(f64, 25), decoded.percent(), 0.0001);
    control.route = .{ .index = 7, .device = 3 };
    const route = control.parameter(&buffer, 75, false) orelse return error.NoRoute;
    const object = try route.object(p.SPA_TYPE_OBJECT_ParamRoute);
    try std.testing.expectEqual(@as(u32, p.SPA_PARAM_Route), object.id());
    try std.testing.expectEqual(@as(i32, 7), try object.property(p.SPA_PARAM_ROUTE_index).?.integer());
    try std.testing.expectEqual(@as(i32, 3), try object.property(p.SPA_PARAM_ROUTE_device).?.integer());
    try std.testing.expect(try object.property(p.SPA_PARAM_ROUTE_save).?.boolean());
    try std.testing.expect(decoded.fill(object.property(p.SPA_PARAM_ROUTE_props).?));
    try std.testing.expect(!decoded.muted);
    try std.testing.expectApproxEqAbs(@as(f64, 75), decoded.percent(), 0.0001);
}

test "native reader accepts scalar-only Props from C layouts" {
    const Scalar = extern struct { property: p.spa_pod_prop, value: u32, padding: u32 = 0 };
    const Props = extern struct { header: p.spa_pod, body: p.spa_pod_object_body, volume: Scalar, mute: Scalar };
    var props: Props = .{
        .header = .{ .size = @sizeOf(Props) - 8, .type = p.SPA_TYPE_Object },
        .body = .{ .type = p.SPA_TYPE_OBJECT_Props, .id = p.SPA_PARAM_Props },
        .volume = .{ .property = .{ .key = p.SPA_PROP_volume, .flags = 0, .value = .{ .size = 4, .type = p.SPA_TYPE_Float } }, .value = @bitCast(@as(f32, 0.125)) },
        .mute = .{ .property = .{ .key = p.SPA_PROP_mute, .flags = 0, .value = .{ .size = 4, .type = p.SPA_TYPE_Bool } }, .value = 1 },
    };
    var control = Control{ .object = undefined };
    try std.testing.expect(control.fill(try Pod.View.init(std.mem.asBytes(&props))));
    try std.testing.expectEqual(@as(u32, 0), control.count);
    try std.testing.expectApproxEqAbs(@as(f64, 50), control.percent(), 0.0001);
    try std.testing.expect(control.muted);
    var buffer: Parameter = .{};
    const written = control.parameter(&buffer, 75, false).?;
    const raw: *const p.spa_pod_object = @ptrCast(@alignCast(written.bytes.ptr));
    try std.testing.expectEqual(@as(u32, p.SPA_TYPE_OBJECT_Props), raw.body.type);
    const field: *const Scalar = @ptrCast(@alignCast(written.bytes[@sizeOf(p.spa_pod_object)..].ptr));
    try std.testing.expectEqual(@as(u32, p.SPA_PROP_volume), field.property.key);
    try std.testing.expectEqual(@as(u32, p.SPA_TYPE_Float), field.property.value.type);
    try std.testing.expectApproxEqAbs(@as(f32, 0.421875), @as(f32, @bitCast(field.value)), 0.000001);
    props.volume.value = @bitCast(std.math.nan(f32));
    try std.testing.expect(!control.fill(try Pod.View.init(std.mem.asBytes(&props))));
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
    var buffer: Parameter = .{};
    try std.testing.expect(control.parameter(&buffer, 50, null) == null);
}

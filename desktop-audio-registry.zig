//! PipeWire registry, parameter cache and round trips on the GLib main thread.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const p = @import("pipewire");
const Pod = @import("desktop-audio-pod.zig");
const defaults = @import("desktop-audio-defaults.zig");
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
var initialized = false;
const cast = c.__zig.cast;
fn iface(object: anytype) *p.spa_interface {
    return cast(p.spa_interface, object);
}
fn methods(comptime T: type, object: anytype) *const T {
    return @ptrCast(@alignCast(iface(object).cb.funcs));
}
fn text(value: [*c]const u8) ?[]const u8 {
    return if (value == null) null else std.mem.span(value);
}
fn eq(left: [*c]const u8, right: []const u8) bool {
    return left != null and std.mem.eql(u8, std.mem.span(left), right);
}
fn unhook(hook: *p.spa_hook) void {
    if (hook.link.next != null and hook.link.prev != null) p.spa_hook_remove(hook);
    hook.* = std.mem.zeroes(p.spa_hook);
}
pub const Kind = enum { node, device, metadata };
pub const Param = struct { index: u32, bytes: []u8 };
pub const Object = struct {
    registry: *Registry,
    id: u32,
    kind: Kind,
    proxy: *anyopaque,
    hook: p.spa_hook = std.mem.zeroes(p.spa_hook),
    properties: *p.pw_properties,
    params: std.ArrayList(Param) = .empty,
    param_flags: ?u32 = null,
    names: defaults.Defaults = .{},

    pub fn property(self: *const Object, key: [*:0]const u8) [*c]const u8 {
        return p.pw_properties_get(self.properties, key);
    }
    fn clearParams(self: *Object) void {
        for (self.params.items) |param| a.free(param.bytes);
        self.params.clearRetainingCapacity();
    }
    fn destroy(self: *Object) void {
        unhook(&self.hook);
        p.pw_proxy_destroy(@ptrCast(self.proxy));
        p.pw_properties_free(self.properties);
        self.clearParams();
        self.params.deinit(a);
        self.names.deinit();
        a.destroy(self);
    }
    pub fn set(self: *Object, value: Pod.View) bool {
        const raw: *const p.spa_pod = @ptrCast(@alignCast(value.bytes.ptr));
        const id: u32 = if (self.kind == .device) p.SPA_PARAM_Route else p.SPA_PARAM_Props;
        return if (self.kind == .device)
            methods(p.pw_device_methods, self.proxy).set_param.?(iface(self.proxy).cb.data, id, 0, raw) >= 0
        else
            methods(p.pw_node_methods, self.proxy).set_param.?(iface(self.proxy).cb.data, id, 0, raw) >= 0;
    }
    fn nodeInfo(data: ?*anyopaque, info: [*c]const p.pw_node_info) callconv(.c) void {
        const self = cast(Object, data);
        if (info.*.props != null) _ = p.pw_properties_update(self.properties, info.*.props);
        if (info.*.change_mask & p.PW_NODE_CHANGE_MASK_PARAMS != 0) self.changedParams(info.*.params, info.*.n_params);
        self.registry.changed();
    }
    fn deviceInfo(data: ?*anyopaque, info: [*c]const p.pw_device_info) callconv(.c) void {
        const self = cast(Object, data);
        if (info.*.props != null) _ = p.pw_properties_update(self.properties, info.*.props);
        if (info.*.change_mask & p.PW_DEVICE_CHANGE_MASK_PARAMS != 0) self.changedParams(info.*.params, info.*.n_params);
        self.registry.changed();
    }
    fn changedParams(self: *Object, params: [*c]const p.spa_param_info, count: u32) void {
        var flags: ?u32 = null;
        for (0..count) |i| if (params[i].id == @as(u32, if (self.kind == .device) p.SPA_PARAM_Route else p.SPA_PARAM_Props)) {
            flags = params[i].flags;
            break;
        };
        if (self.param_flags != flags) self.clearParams();
        self.param_flags = flags;
    }
    fn parameter(data: ?*anyopaque, _: c_int, id: u32, index: u32, _: u32, pod: [*c]const p.spa_pod) callconv(.c) void {
        const self = cast(Object, data);
        if (pod == null or pod.*.size > 1024 * 1024 - 8) return;
        if (id != @as(u32, if (self.kind == .device) p.SPA_PARAM_Route else p.SPA_PARAM_Props)) return;
        const bytes: [*]const u8 = @ptrCast(pod);
        const length = @sizeOf(p.spa_pod) + @as(usize, pod.*.size);
        _ = Pod.View.init(bytes[0..length]) catch return;
        const copy = a.dupe(u8, bytes[0..length]) catch return;
        for (self.params.items) |*param| if (param.index == index) {
            a.free(param.bytes);
            param.bytes = copy;
            self.registry.changed();
            return;
        };
        if (self.params.items.len >= 256) {
            a.free(copy);
            return;
        }
        self.params.append(a, .{ .index = index, .bytes = copy }) catch {
            a.free(copy);
            return;
        };
        self.registry.changed();
    }
    fn metadata(data: ?*anyopaque, subject: u32, key: [*c]const u8, kind: [*c]const u8, value: [*c]const u8) callconv(.c) c_int {
        const self = cast(Object, data);
        if (self.names.update(subject, text(key), text(kind), text(value))) self.registry.changed();
        return 0;
    }
};
const node_events: p.pw_node_events = .{ .version = p.PW_VERSION_NODE_EVENTS, .info = &Object.nodeInfo, .param = &Object.parameter };
const device_events: p.pw_device_events = .{ .version = p.PW_VERSION_DEVICE_EVENTS, .info = &Object.deviceInfo, .param = &Object.parameter };
const metadata_events: p.pw_metadata_events = .{ .version = p.PW_VERSION_METADATA_EVENTS, .property = &Object.metadata };
pub const Registry = struct {
    callback: *const fn (?*anyopaque) void,
    data: ?*anyopaque,
    loop: *p.pw_loop,
    context: ?*p.pw_context = null,
    core: ?*p.pw_core = null,
    proxy: ?*p.pw_registry = null,
    core_hook: p.spa_hook = std.mem.zeroes(p.spa_hook),
    registry_hook: p.spa_hook = std.mem.zeroes(p.spa_hook),
    objects: std.ArrayList(*Object) = .empty,
    barriers: std.ArrayList(struct { sequence: c_int, ticket: u64 }) = .empty,
    next_ticket: u64 = 0,
    completed: u64 = 0,
    initial: u64 = 0,
    source: c.guint = 0,
    sequence: c_int = 0,
    ready: bool = false,
    failed: bool = false,
    pub fn create(callback: *const fn (?*anyopaque) void, data: ?*anyopaque) !*Registry {
        if (!initialized) {
            p.pw_init(null, null);
            initialized = true;
        }
        const self = try a.create(Registry);
        errdefer a.destroy(self);
        const loop = p.pw_loop_new(null) orelse return error.AudioLoopUnavailable;
        self.* = .{ .callback = callback, .data = data, .loop = loop };
        const control = loop.*.control;
        methods(p.spa_loop_control_methods, control).enter.?(iface(control).cb.data);
        errdefer self.deinit();
        self.context = p.pw_context_new(loop, null, 0) orelse return error.AudioContextUnavailable;
        self.core = p.pw_context_connect(self.context, null, 0) orelse return error.AudioDisconnected;
        _ = methods(p.pw_core_methods, self.core).add_listener.?(iface(self.core).cb.data, &self.core_hook, &core_events, self);
        self.proxy = methods(p.pw_core_methods, self.core).get_registry.?(iface(self.core).cb.data, p.PW_VERSION_REGISTRY, 0) orelse return error.AudioRegistryUnavailable;
        _ = methods(p.pw_registry_methods, self.proxy).add_listener.?(iface(self.proxy).cb.data, &self.registry_hook, &registry_events, self);
        self.initial = self.sync() orelse return error.AudioSyncFailed;
        const fd = methods(p.spa_loop_control_methods, control).get_fd.?(iface(control).cb.data);
        if (fd < 0) return error.AudioLoopUnavailable;
        self.source = c.g_unix_fd_add(fd, c.G_IO_IN | c.G_IO_ERR | c.G_IO_HUP, &dispatch, self);
        return self;
    }
    fn deinit(self: *Registry) void {
        if (self.source != 0) _ = c.g_source_remove(self.source);
        for (self.objects.items) |object| object.destroy();
        self.objects.deinit(a);
        self.barriers.deinit(a);
        unhook(&self.registry_hook);
        if (self.proxy) |proxy| p.pw_proxy_destroy(@ptrCast(proxy));
        unhook(&self.core_hook);
        if (self.core) |core| _ = p.pw_core_disconnect(core);
        if (self.context) |context| p.pw_context_destroy(context);
        const control = self.loop.*.control;
        methods(p.spa_loop_control_methods, control).leave.?(iface(control).cb.data);
        p.pw_loop_destroy(self.loop);
    }
    pub fn destroy(self: *Registry) void {
        self.deinit();
        a.destroy(self);
    }
    fn changed(self: *Registry) void {
        self.callback(self.data);
    }
    pub fn find(self: *Registry, id: u32) ?*Object {
        for (self.objects.items) |object| if (object.id == id) return object;
        return null;
    }
    pub fn defaultName(self: *Registry, output: bool) ?[]const u8 {
        for (self.objects.items) |object| if (object.kind == .metadata) {
            if (object.names.name(output)) |name| return name;
        };
        return null;
    }
    pub fn setDefault(self: *Registry, output: bool, name: []const u8) bool {
        for (self.objects.items) |object| if (object.kind == .metadata) {
            const json = defaults.encode(name) catch return false;
            defer a.free(json);
            return methods(p.pw_metadata_methods, object.proxy).set_property.?(iface(object.proxy).cb.data, 0, if (output) "default.configured.audio.sink" else "default.configured.audio.source", "Spa:String:JSON", json) >= 0;
        };
        return false;
    }
    pub fn sync(self: *Registry) ?u64 {
        const core = self.core orelse return null;
        const sequence = methods(p.pw_core_methods, core).sync.?(iface(core).cb.data, p.PW_ID_CORE, self.sequence);
        if (sequence < 0) return null;
        self.sequence = sequence;
        self.next_ticket += 1;
        self.barriers.append(a, .{ .sequence = sequence, .ticket = self.next_ticket }) catch return null;
        return self.next_ticket;
    }
    fn dispatch(_: c_int, condition: c.GIOCondition, data: ?*anyopaque) callconv(.c) c_int {
        const self = cast(Registry, data);
        const control = self.loop.*.control;
        if (condition & (c.G_IO_ERR | c.G_IO_HUP) != 0 or methods(p.spa_loop_control_methods, control).iterate.?(iface(control).cb.data, 0) < 0) self.failed = true;
        if (self.failed) {
            self.source = 0;
            self.changed();
            return 0;
        }
        return 1;
    }
    fn done(data: ?*anyopaque, id: u32, sequence: c_int) callconv(.c) void {
        if (id != p.PW_ID_CORE) return;
        const self = cast(Registry, data);
        for (self.barriers.items) |barrier| if (barrier.sequence == sequence) {
            self.completed = @max(self.completed, barrier.ticket);
            break;
        };
        var i: usize = 0;
        while (i < self.barriers.items.len) {
            if (self.barriers.items[i].ticket <= self.completed) _ = self.barriers.orderedRemove(i) else i += 1;
        }
        if (!self.ready and self.completed >= self.initial) {
            self.ready = true;
            self.changed();
        }
    }
    fn ping(data: ?*anyopaque, id: u32, sequence: c_int) callconv(.c) void {
        const self = cast(Registry, data);
        _ = methods(p.pw_core_methods, self.core).pong.?(iface(self.core).cb.data, id, sequence);
    }
    fn failure(data: ?*anyopaque, id: u32, _: c_int, res: c_int, _: [*c]const u8) callconv(.c) void {
        const self = cast(Registry, data);
        if (id == p.PW_ID_CORE or res == -32 or res == -104) {
            self.failed = true;
            self.changed();
        }
    }
    fn global(data: ?*anyopaque, id: u32, _: u32, kind_name: [*c]const u8, version: u32, properties: [*c]const p.spa_dict) callconv(.c) void {
        const self = cast(Registry, data);
        const kind: Kind = if (eq(kind_name, p.PW_TYPE_INTERFACE_Node)) .node else if (eq(kind_name, p.PW_TYPE_INTERFACE_Device)) .device else if (eq(kind_name, p.PW_TYPE_INTERFACE_Metadata)) .metadata else return;
        const props = p.pw_properties_new_dict(properties) orelse return;
        if (self.objects.items.len >= 4096 or (kind == .metadata and !eq(p.pw_properties_get(props, "metadata.name"), "default"))) {
            p.pw_properties_free(props);
            return;
        }
        const proxy = methods(p.pw_registry_methods, self.proxy).bind.?(iface(self.proxy).cb.data, id, kind_name, @min(version, @as(u32, 3)), 0) orelse {
            p.pw_properties_free(props);
            return;
        };
        const object = a.create(Object) catch {
            p.pw_proxy_destroy(@ptrCast(proxy));
            p.pw_properties_free(props);
            return;
        };
        object.* = .{ .registry = self, .id = id, .kind = kind, .proxy = proxy, .properties = props };
        self.objects.append(a, object) catch {
            object.destroy();
            return;
        };
        switch (kind) {
            .node => {
                _ = methods(p.pw_node_methods, proxy).add_listener.?(iface(proxy).cb.data, &object.hook, &node_events, object);
                var ids = [_]u32{p.SPA_PARAM_Props};
                _ = methods(p.pw_node_methods, proxy).subscribe_params.?(iface(proxy).cb.data, &ids, 1);
            },
            .device => {
                _ = methods(p.pw_device_methods, proxy).add_listener.?(iface(proxy).cb.data, &object.hook, &device_events, object);
                var ids = [_]u32{p.SPA_PARAM_Route};
                _ = methods(p.pw_device_methods, proxy).subscribe_params.?(iface(proxy).cb.data, &ids, 1);
            },
            .metadata => _ = methods(p.pw_metadata_methods, proxy).add_listener.?(iface(proxy).cb.data, &object.hook, &metadata_events, object),
        }
        if (self.sync()) |ticket| {
            if (!self.ready) self.initial = ticket;
        }
        self.changed();
    }
    fn removed(data: ?*anyopaque, id: u32) callconv(.c) void {
        const self = cast(Registry, data);
        for (self.objects.items, 0..) |object, index| if (object.id == id) {
            _ = self.objects.orderedRemove(index);
            object.destroy();
            self.changed();
            return;
        };
    }
};
const core_events: p.pw_core_events = .{ .version = p.PW_VERSION_CORE_EVENTS, .done = &Registry.done, .ping = &Registry.ping, .@"error" = &Registry.failure };
const registry_events: p.pw_registry_events = .{ .version = p.PW_VERSION_REGISTRY_EVENTS, .global = &Registry.global, .global_remove = &Registry.removed };

test "unrelated parameter changes preserve Props while serial changes invalidate it" {
    var object = Object{ .registry = undefined, .id = 42, .kind = .node, .proxy = undefined, .properties = undefined, .param_flags = p.SPA_PARAM_INFO_READ };
    defer object.params.deinit(a);
    defer object.clearParams();
    try object.params.append(a, .{ .index = 0, .bytes = try a.dupe(u8, "cached") });
    var params = [_]p.spa_param_info{
        .{ .id = p.SPA_PARAM_Props, .flags = p.SPA_PARAM_INFO_READ },
        .{ .id = p.SPA_PARAM_Format, .flags = p.SPA_PARAM_INFO_READ | p.SPA_PARAM_INFO_SERIAL },
    };
    object.changedParams(&params, params.len);
    try std.testing.expectEqual(@as(usize, 1), object.params.items.len);
    params[0].flags |= p.SPA_PARAM_INFO_SERIAL;
    object.changedParams(&params, params.len);
    try std.testing.expectEqual(@as(usize, 0), object.params.items.len);
}
test "core barriers complete only matching round trips and release earlier tickets" {
    var registry = Registry{ .callback = undefined, .data = null, .loop = undefined, .ready = true };
    defer registry.barriers.deinit(a);
    try registry.barriers.append(a, .{ .sequence = 100, .ticket = 1 });
    try registry.barriers.append(a, .{ .sequence = 101, .ticket = 2 });
    try registry.barriers.append(a, .{ .sequence = 103, .ticket = 3 });
    Registry.done(&registry, p.PW_ID_CORE, 99);
    try std.testing.expectEqual(@as(u64, 0), registry.completed);
    Registry.done(&registry, p.PW_ID_CORE, 101);
    try std.testing.expectEqual(@as(u64, 2), registry.completed);
    try std.testing.expectEqual(@as(usize, 1), registry.barriers.items.len);
    Registry.done(&registry, p.PW_ID_CORE, 100);
    try std.testing.expectEqual(@as(u64, 2), registry.completed);
}

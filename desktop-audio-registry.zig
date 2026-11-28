//! PipeWire registry, parameter cache and round trips on the main thread,
//! over the native protocol client in desktop-pipewire.zig.
const std = @import("std");
const mainloop = @import("desktop-loop.zig");
const spa = @import("desktop-spa.zig");
const wire = @import("desktop-pipewire.zig");
const Pod = @import("desktop-audio-pod.zig");
const defaults = @import("desktop-audio-defaults.zig");

pub const Kind = enum { node, device, metadata };
pub const Param = struct { index: u32, bytes: []u8 };
pub const ParamInfo = struct { id: u32, flags: u32 };

/// Global properties, updated from info events; a null value removes a key.
pub const Properties = struct {
    entries: std.ArrayList(struct { key: [:0]u8, value: [:0]u8 }) = .empty,

    fn get(self: *const Properties, key: []const u8) ?[:0]const u8 {
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.key, key)) return entry.value;
        return null;
    }
    fn update(self: *Properties, a: std.mem.Allocator, dict: *wire.Dict) !void {
        while (try dict.next()) |item| {
            const existing = for (self.entries.items, 0..) |entry, i| {
                if (std.mem.eql(u8, entry.key, item.key)) break i;
            } else null;
            if (item.value) |value| {
                const copy = try a.dupeSentinel(u8, value, 0);
                if (existing) |i| {
                    a.free(self.entries.items[i].value);
                    self.entries.items[i].value = copy;
                } else {
                    errdefer a.free(copy);
                    if (self.entries.items.len >= 1024) return error.Protocol;
                    const key = try a.dupeSentinel(u8, item.key, 0);
                    errdefer a.free(key);
                    try self.entries.append(a, .{ .key = key, .value = copy });
                }
            } else if (existing) |i| {
                const entry = self.entries.orderedRemove(i);
                a.free(entry.key);
                a.free(entry.value);
            }
        }
    }
    fn deinit(self: *Properties, a: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            a.free(entry.key);
            a.free(entry.value);
        }
        self.entries.deinit(a);
    }
};

pub const Object = struct {
    allocator: std.mem.Allocator,
    registry: *Registry,
    id: u32,
    kind: Kind,
    proxy: u32,
    properties: Properties = .{},
    params: std.ArrayList(Param) = .empty,
    param_flags: ?u32 = null,
    names: defaults.Defaults = .{},
    running: bool = false,

    pub fn property(self: *const Object, key: [*:0]const u8) [*c]const u8 {
        return if (self.properties.get(std.mem.span(key))) |value| value.ptr else null;
    }
    fn paramId(self: *const Object) u32 {
        return if (self.kind == .device) spa.SPA_PARAM_Route else spa.SPA_PARAM_Props;
    }
    fn clearParams(self: *Object) void {
        for (self.params.items) |param| self.allocator.free(param.bytes);
        self.params.clearRetainingCapacity();
    }
    fn destroy(self: *Object) void {
        self.properties.deinit(self.allocator);
        self.clearParams();
        self.params.deinit(self.allocator);
        self.names.deinit(self.allocator);
        self.allocator.destroy(self);
    }
    pub fn set(self: *Object, value: Pod.View) bool {
        const connection = self.registry.connection orelse return false;
        const message = connection.begin();
        message.id(self.paramId());
        message.int(0);
        message.pod(value.bytes);
        _ = connection.end(self.proxy, if (self.kind == .device) spa.PW_DEVICE_METHOD_SET_PARAM else spa.PW_NODE_METHOD_SET_PARAM) catch {
            self.registry.fail();
            return false;
        };
        return true;
    }
    fn enumParams(self: *Object) void {
        const connection = self.registry.connection orelse return;
        const message = connection.begin();
        message.int(0);
        message.id(self.paramId());
        message.int(0);
        message.int(std.math.maxInt(i32));
        message.none();
        // Node and device share the enum_params opcode.
        _ = connection.end(self.proxy, spa.PW_NODE_METHOD_ENUM_PARAMS) catch self.registry.fail();
    }
    fn info(self: *Object, body: *wire.Reader) wire.Error!void {
        var mask: u64 = undefined;
        var props_bit: u64 = undefined;
        var params_bit: u64 = undefined;
        if (self.kind == .node) {
            _ = try body.uint(); // id
            _ = try body.int(); // max input ports
            _ = try body.int(); // max output ports
            mask = @bitCast(try body.long());
            _ = try body.int(); // input ports
            _ = try body.int(); // output ports
            const state: i32 = @bitCast(try body.id());
            _ = try body.string(); // error
            if (mask & spa.PW_NODE_CHANGE_MASK_STATE != 0) self.running = state == spa.PW_NODE_STATE_RUNNING;
            props_bit = spa.PW_NODE_CHANGE_MASK_PROPS;
            params_bit = spa.PW_NODE_CHANGE_MASK_PARAMS;
        } else {
            _ = try body.uint(); // id
            mask = @bitCast(try body.long());
            props_bit = spa.PW_DEVICE_CHANGE_MASK_PROPS;
            params_bit = spa.PW_DEVICE_CHANGE_MASK_PARAMS;
        }
        var dict = try body.dict();
        if (mask & props_bit != 0) self.properties.update(self.allocator, &dict) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.Protocol;
        var params = try body.structure();
        const count = try params.int();
        if (count < 0 or count > 256) return error.Protocol;
        var infos: [256]ParamInfo = undefined;
        for (infos[0..@intCast(count)]) |*entry| entry.* = .{ .id = try params.id(), .flags = try params.uint() };
        if (mask & params_bit != 0 and self.changedParams(infos[0..@intCast(count)])) self.enumParams();
        self.registry.changed();
    }
    fn changedParams(self: *Object, params: []const ParamInfo) bool {
        var flags: ?u32 = null;
        for (params) |param| if (param.id == self.paramId()) {
            flags = param.flags;
            break;
        };
        const changed = self.param_flags != flags;
        if (changed) self.clearParams();
        self.param_flags = flags;
        return changed and flags != null and (flags.? & spa.SPA_PARAM_INFO_READ) != 0;
    }
    fn parameter(self: *Object, body: *wire.Reader) wire.Error!void {
        _ = try body.int(); // seq
        const id = try body.id();
        const index = try body.uint();
        _ = try body.uint(); // next
        const pod = try body.raw();
        // raw() has already checked the header with Pod.View.init.
        if (id != self.paramId()) return;
        const copy = try self.allocator.dupe(u8, pod);
        for (self.params.items) |*param| if (param.index == index) {
            self.allocator.free(param.bytes);
            param.bytes = copy;
            self.registry.changed();
            return;
        };
        if (self.params.items.len >= 256) {
            self.allocator.free(copy);
            return;
        }
        self.params.append(self.allocator, .{ .index = index, .bytes = copy }) catch {
            self.allocator.free(copy);
            return error.OutOfMemory;
        };
        self.registry.changed();
    }
    fn metadata(self: *Object, body: *wire.Reader) wire.Error!void {
        const subject = try body.uint();
        const key = try body.string();
        const kind = try body.string();
        const value = try body.string();
        if (self.names.update(self.allocator, subject, key, kind, value)) self.registry.changed();
    }
    fn event(self: *Object, opcode: u8, body: *wire.Reader) wire.Error!void {
        switch (self.kind) {
            .node, .device => switch (opcode) {
                spa.PW_NODE_EVENT_INFO => try self.info(body),
                spa.PW_NODE_EVENT_PARAM => try self.parameter(body),
                else => {},
            },
            .metadata => if (opcode == spa.PW_METADATA_EVENT_PROPERTY) try self.metadata(body),
        }
    }
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    callback: *const fn (?*anyopaque) void,
    data: ?*anyopaque,
    connection: ?*wire.Connection = null,
    proxy: u32 = 0,
    objects: std.ArrayList(*Object) = .empty,
    barriers: std.ArrayList(struct { sequence: c_int, ticket: u64 }) = .empty,
    next_ticket: u64 = 0,
    completed: u64 = 0,
    initial: u64 = 0,
    source: u32 = 0,
    ready: bool = false,
    failed: bool = false,

    pub fn create(a: std.mem.Allocator, io: std.Io, callback: *const fn (?*anyopaque) void, data: ?*anyopaque) !*Registry {
        const self = try a.create(Registry);
        self.* = .{ .allocator = a, .io = io, .callback = callback, .data = data };
        errdefer self.destroy();
        const connection = wire.Connection.connect(a, &.{ .{ "application.name", "desktop-zig" }, .{ "media.category", "Manager" } }) catch return error.AudioDisconnected;
        self.connection = connection;
        self.proxy = connection.newId();
        const message = connection.begin();
        message.int(spa.PW_VERSION_REGISTRY);
        message.uint(self.proxy);
        _ = connection.end(spa.PW_ID_CORE, spa.PW_CORE_METHOD_GET_REGISTRY) catch return error.AudioRegistryUnavailable;
        self.initial = self.sync() orelse return error.AudioSyncFailed;
        self.source = mainloop.watch(io, connection.fd, mainloop.IN | mainloop.ERR | mainloop.HUP, self, dispatch);
        return self;
    }
    pub fn destroy(self: *Registry) void {
        if (self.source != 0) _ = mainloop.remove(self.io, self.source);
        for (self.objects.items) |object| object.destroy();
        self.objects.deinit(self.allocator);
        self.barriers.deinit(self.allocator);
        if (self.connection) |connection| connection.destroy();
        self.allocator.destroy(self);
    }
    fn changed(self: *Registry) void {
        self.callback(self.data);
    }
    fn fail(self: *Registry) void {
        self.failed = true;
    }
    pub fn find(self: *Registry, id: u32) ?*Object {
        for (self.objects.items) |object| if (object.id == id) return object;
        return null;
    }
    fn byProxy(self: *Registry, proxy: u32) ?*Object {
        for (self.objects.items) |object| if (object.proxy == proxy) return object;
        return null;
    }
    pub fn defaultName(self: *Registry, output: bool) ?[]const u8 {
        for (self.objects.items) |object| if (object.kind == .metadata) {
            if (object.names.name(output)) |name| return name;
        };
        return null;
    }
    pub fn setDefault(self: *Registry, output: bool, name: []const u8) bool {
        const connection = self.connection orelse return false;
        for (self.objects.items) |object| if (object.kind == .metadata) {
            const json = defaults.encode(self.allocator, name) catch return false;
            defer self.allocator.free(json);
            const message = connection.begin();
            message.int(0);
            message.string(if (output) "default.configured.audio.sink" else "default.configured.audio.source");
            message.string("Spa:String:JSON");
            message.string(json);
            _ = connection.end(object.proxy, spa.PW_METADATA_METHOD_SET_PROPERTY) catch {
                self.fail();
                return false;
            };
            return true;
        };
        return false;
    }
    /// Starts a round trip; the ticket completes once every earlier request is processed.
    pub fn sync(self: *Registry) ?u64 {
        const connection = self.connection orelse return null;
        // libpipewire marks sync sequences as asynchronous results.
        const sequence: c_int = @bitCast(0x40000000 | (connection.sequence & 0x3fffffff));
        const message = connection.begin();
        message.int(spa.PW_ID_CORE);
        message.int(sequence);
        _ = connection.end(spa.PW_ID_CORE, spa.PW_CORE_METHOD_SYNC) catch {
            self.fail();
            return null;
        };
        self.next_ticket += 1;
        self.barriers.append(self.allocator, .{ .sequence = sequence, .ticket = self.next_ticket }) catch return null;
        return self.next_ticket;
    }
    fn dispatch(self: *Registry, _: c_int, condition: u32) bool {
        self.receive(condition) catch {
            self.failed = true;
        };
        if (self.failed) {
            self.source = 0;
            self.changed();
            return false;
        }
        return true;
    }
    fn receive(self: *Registry, condition: u32) wire.Error!void {
        const connection = self.connection.?;
        try connection.read();
        while (try connection.next()) |message| {
            var body = message.body;
            if (message.id == spa.PW_ID_CORE) {
                try self.core(message.opcode, &body);
            } else if (message.id == self.proxy) {
                try self.registryEvent(message.opcode, &body);
            } else if (self.byProxy(message.id)) |object| {
                try object.event(message.opcode, &body);
            }
            if (self.failed) return;
        }
        if (condition & (mainloop.ERR | mainloop.HUP) != 0) return error.ConnectionClosed;
    }
    fn core(self: *Registry, opcode: u8, body: *wire.Reader) wire.Error!void {
        switch (opcode) {
            spa.PW_CORE_EVENT_DONE => {
                const id = try body.uint();
                self.done(id, try body.int());
            },
            spa.PW_CORE_EVENT_PING => {
                const id = try body.int();
                const sequence = try body.int();
                const connection = self.connection.?;
                const message = connection.begin();
                message.int(id);
                message.int(sequence);
                _ = try connection.end(spa.PW_ID_CORE, spa.PW_CORE_METHOD_PONG);
            },
            spa.PW_CORE_EVENT_ERROR => {
                const id = try body.uint();
                _ = try body.int(); // seq
                const res = try body.int();
                if (id == spa.PW_ID_CORE or res == -32 or res == -104) self.failed = true;
            },
            spa.PW_CORE_EVENT_REMOVE_ID => {
                const id = try body.uint();
                // Normally global_remove already dropped the object. A proxy the
                // server destroys first (a failed bind) is dead: drop it, so a
                // new proxy reusing the id is not mistaken for it.
                for (self.objects.items, 0..) |object, index| if (object.proxy == id) {
                    _ = self.objects.orderedRemove(index);
                    object.destroy();
                    self.changed();
                    break;
                };
                self.connection.?.releaseId(id);
            },
            else => {},
        }
    }
    fn done(self: *Registry, id: u32, sequence: c_int) void {
        if (id != spa.PW_ID_CORE) return;
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
    fn registryEvent(self: *Registry, opcode: u8, body: *wire.Reader) wire.Error!void {
        switch (opcode) {
            spa.PW_REGISTRY_EVENT_GLOBAL => {
                const id = try body.uint();
                _ = try body.uint(); // permissions
                const kind_name = try body.string() orelse return error.Protocol;
                const version = try body.uint();
                var dict = try body.dict();
                try self.global(id, kind_name, version, &dict);
            },
            spa.PW_REGISTRY_EVENT_GLOBAL_REMOVE => {
                const id = try body.uint();
                // The server destroys our proxy and later sends remove_id for it.
                for (self.objects.items, 0..) |object, index| if (object.id == id) {
                    _ = self.objects.orderedRemove(index);
                    object.destroy();
                    self.changed();
                    return;
                };
            },
            else => {},
        }
    }
    fn global(self: *Registry, id: u32, kind_name: []const u8, version: u32, dict: *wire.Dict) wire.Error!void {
        const kind: Kind = if (std.mem.eql(u8, kind_name, spa.PW_TYPE_INTERFACE_Node)) .node else if (std.mem.eql(u8, kind_name, spa.PW_TYPE_INTERFACE_Device)) .device else if (std.mem.eql(u8, kind_name, spa.PW_TYPE_INTERFACE_Metadata)) .metadata else return;
        if (self.objects.items.len >= 4096) return;
        const connection = self.connection.?;
        const object = try self.allocator.create(Object);
        object.* = .{ .allocator = self.allocator, .registry = self, .id = id, .kind = kind, .proxy = 0 };
        object.properties.update(self.allocator, dict) catch |err| {
            object.destroy();
            return if (err == error.OutOfMemory) error.OutOfMemory else error.Protocol;
        };
        if (kind == .metadata and !std.mem.eql(u8, object.properties.get("metadata.name") orelse "", "default")) {
            object.destroy();
            return;
        }
        self.objects.append(self.allocator, object) catch {
            object.destroy();
            return error.OutOfMemory;
        };
        object.proxy = connection.newId();
        var message = connection.begin();
        message.uint(id);
        message.string(kind_name);
        message.uint(@min(version, 3));
        message.uint(object.proxy);
        _ = try connection.end(self.proxy, spa.PW_REGISTRY_METHOD_BIND);
        if (kind != .metadata) {
            message = connection.begin();
            message.ids(&.{object.paramId()});
            // Node and device share the subscribe_params opcode.
            _ = try connection.end(object.proxy, spa.PW_NODE_METHOD_SUBSCRIBE_PARAMS);
        }
        if (self.sync()) |ticket| {
            if (!self.ready) self.initial = ticket;
        }
        self.changed();
    }
};

test "unrelated parameter changes preserve Props while serial changes invalidate it" {
    const a = std.testing.allocator;
    var object = Object{ .allocator = a, .registry = undefined, .id = 42, .kind = .node, .proxy = 2, .param_flags = spa.SPA_PARAM_INFO_READ };
    defer object.params.deinit(a);
    defer object.clearParams();
    try object.params.append(a, .{ .index = 0, .bytes = try a.dupe(u8, "cached") });
    var params = [_]ParamInfo{
        .{ .id = spa.SPA_PARAM_Props, .flags = spa.SPA_PARAM_INFO_READ },
        .{ .id = 4, .flags = spa.SPA_PARAM_INFO_READ | spa.SPA_PARAM_INFO_SERIAL },
    };
    try std.testing.expect(!object.changedParams(&params));
    try std.testing.expectEqual(@as(usize, 1), object.params.items.len);
    params[0].flags |= spa.SPA_PARAM_INFO_SERIAL;
    try std.testing.expect(object.changedParams(&params));
    try std.testing.expectEqual(@as(usize, 0), object.params.items.len);
}
test "core barriers complete only matching round trips and release earlier tickets" {
    const a = std.testing.allocator;
    var registry = Registry{ .allocator = a, .io = std.testing.io, .callback = undefined, .data = null, .ready = true };
    defer registry.barriers.deinit(a);
    try registry.barriers.append(a, .{ .sequence = 100, .ticket = 1 });
    try registry.barriers.append(a, .{ .sequence = 101, .ticket = 2 });
    try registry.barriers.append(a, .{ .sequence = 103, .ticket = 3 });
    registry.done(spa.PW_ID_CORE, 99);
    try std.testing.expectEqual(@as(u64, 0), registry.completed);
    registry.done(spa.PW_ID_CORE, 101);
    try std.testing.expectEqual(@as(u64, 2), registry.completed);
    try std.testing.expectEqual(@as(usize, 1), registry.barriers.items.len);
    registry.done(spa.PW_ID_CORE, 100);
    try std.testing.expectEqual(@as(u64, 2), registry.completed);
}

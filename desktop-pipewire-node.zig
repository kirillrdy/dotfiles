//! A PipeWire node exported over the native protocol, without libpipewire.
//!
//! The node is a "client-node": the server owns its graph object, allocates
//! buffers in shared memory, and wakes it through an eventfd each cycle. The
//! client maps that memory, answers format negotiation, fills output buffers,
//! and then signals the nodes that depend on it through their activation
//! records (shared counters and eventfds), as libpipewire's remote-node does.
//! A node may also drive the graph, starting each cycle itself.
//!
//! All protocol and processing work runs on one thread per node; other
//! threads only read its published state and ask it to start a cycle.
const std = @import("std");
const spa = @import("desktop-spa.zig");
const wire = @import("desktop-pipewire.zig");
const libc = @import("desktop-libc.zig");
const Pod = @import("desktop-audio-pod.zig");

const invalid = spa.PW_ID_ANY;

pub const State = enum(u8) { connecting, paused, streaming, failed, finished };

/// One output port: its properties and the formats it offers.
pub const PortSpec = struct {
    properties: []const [2][]const u8,
    /// A complete EnumFormat object POD.
    enum_format: []const u8,
};

/// A mapped output buffer for one cycle. Setting `chunk.size` above zero
/// publishes it to the port's peers.
pub const Buffer = struct { data: []u8, chunk: *spa.spa_chunk };

pub const Cycle = struct {
    /// Samples (or ticks) in this cycle and the graph rate.
    duration: u64,
    rate: u32,
    /// One buffer per port, or null while the port has no buffers or peers.
    buffers: []?Buffer,
    /// Set by the handler once it has nothing more to play; the node then
    /// leaves the graph after this cycle.
    finished: bool = false,
};

pub const Handler = struct {
    context: *anyopaque,
    /// The server chose `format` for `port`. Writes the port's Buffers
    /// parameter into `out` and returns it, or returns null to reject.
    format: *const fn (context: *anyopaque, port: u32, format: []const u8, out: []align(8) u8) ?[]const u8,
    /// Fills output buffers. Runs on the node thread.
    process: *const fn (context: *anyopaque, cycle: *Cycle) void,
};

const Activation = spa.pw_node_activation;
const not_triggered = 0;
const triggered = 1;
const awake = 2;
const finished_status = 3;
const inactive = 4;
const activation_flag_async = 1 << 1;
const pending_sync_bit = 1 << 1;

const Mapping = struct {
    base: []align(std.heap.page_size_min) u8,
    bytes: []u8,

    fn create(fd: c_int, offset: u32, size: u32) !Mapping {
        if (size == 0) return error.InvalidMemory;
        const page = std.heap.pageSize();
        const start = offset - offset % page;
        const length = std.mem.alignForward(usize, offset - start + size, page);
        const address = libc.mmap(null, length, 3, 1, fd, @intCast(start)); // PROT_READ|PROT_WRITE, MAP_SHARED
        if (address == null or @intFromPtr(address) == std.math.maxInt(usize)) return error.InvalidMemory;
        const base: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(address));
        return .{ .base = base[0..length], .bytes = base[offset - start ..][0..size] };
    }
    fn destroy(self: Mapping) void {
        _ = libc.munmap(self.base.ptr, self.base.len);
    }
};

const Memory = struct { id: u32, fd: c_int };
const Target = struct { id: u32, fd: c_int, map: Mapping };
const Mix = struct { id: u32, map: ?Mapping = null };
const PortBuffer = struct { meta: Mapping, data_map: ?Mapping, data: []u8, chunk: *spa.spa_chunk };
const Port = struct {
    spec: PortSpec,
    format: ?[]u8 = null,
    buffers_param: ?[]u8 = null,
    buffers: std.ArrayList(PortBuffer) = .empty,
    mixes: std.ArrayList(Mix) = .empty,
    next: usize = 0,
};

pub const Node = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    connection: *wire.Connection,
    proxy: u32,
    handler: Handler,
    driver: bool,
    ports: []Port,
    thread: ?std.Thread = null,
    wake: [2]c_int = .{ -1, -1 },
    /// Published to other threads.
    global_id: std.atomic.Value(u32) = .init(invalid),
    state: std.atomic.Value(State) = .init(.connecting),
    // Owned by the node thread.
    memory: std.ArrayList(Memory) = .empty,
    activation: ?Mapping = null,
    readfd: c_int = -1,
    writefd: c_int = -1,
    position: ?Mapping = null,
    clock: ?Mapping = null,
    targets: std.ArrayList(Target) = .empty,
    running: bool = false,
    scratch: [4096]u8 align(8) = undefined,
    /// The node's stream format, and its Props serial flag.
    format: ?[]const u8 = null,
    props_serial: bool = false,

    pub const Options = struct {
        /// The node's properties (media class, name, ...). Driver nodes set
        /// `node.driver` and start cycles with `trigger`.
        properties: []const [2][]const u8,
        ports: []const PortSpec,
        /// The node's own EnumFormat, describing its ports as one stream.
        /// The session manager reads it to decide how to link audio nodes.
        format: ?[]const u8 = null,
    };

    /// Creates the node in the server and starts its thread.
    pub fn create(a: std.mem.Allocator, options: Options, handler: Handler) !*Node {
        const properties = options.properties;
        const self = try a.create(Node);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .arena = .init(a), .connection = undefined, .proxy = 0, .handler = handler, .driver = false, .ports = &.{} };
        errdefer self.arena.deinit();
        const arena = self.arena.allocator();
        self.ports = try arena.alloc(Port, options.ports.len);
        for (options.ports, self.ports) |spec, *port| port.* = .{ .spec = .{ .properties = try copyProperties(arena, spec.properties), .enum_format = try arena.dupe(u8, spec.enum_format) } };
        for (properties) |entry| {
            if (std.mem.eql(u8, entry[0], "node.driver")) self.driver = std.mem.eql(u8, entry[1], "true");
        }
        if (libc.pipe2(&self.wake, 0o2000000 | 0o4000) != 0) return error.PipeWireUnavailable; // O_CLOEXEC | O_NONBLOCK
        errdefer for (self.wake) |fd| {
            _ = libc.close(fd);
        };
        self.connection = wire.Connection.connect(a, &.{ .{ "application.name", "desktop-zig" }, .{ "client.api", "native" } }) catch return error.PipeWireUnavailable;
        errdefer self.connection.destroy();
        self.proxy = self.connection.newId();
        try self.announce(properties, options.format);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    /// Leaves the graph, stops the thread and releases everything.
    pub fn destroy(self: *Node) void {
        if (self.thread) |thread| {
            _ = libc.write(self.wake[1], "q", 1);
            thread.join();
        }
        self.release();
        self.connection.destroy();
        for (self.wake) |fd| _ = libc.close(fd);
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    /// Asks a driving node to start a graph cycle. Callable from any thread.
    pub fn trigger(self: *Node) void {
        _ = libc.write(self.wake[1], "t", 1);
    }

    fn copyProperties(arena: std.mem.Allocator, properties: []const [2][]const u8) ![]const [2][]const u8 {
        const copy = try arena.alloc([2][]const u8, properties.len);
        for (properties, copy) |entry, *dest| dest.* = .{ try arena.dupe(u8, entry[0]), try arena.dupe(u8, entry[1]) };
        return copy;
    }

    fn announce(self: *Node, properties: []const [2][]const u8, format: ?[]const u8) !void {
        const connection = self.connection;
        var create_object = connection.begin();
        create_object.string("client-node");
        create_object.string(spa.PW_TYPE_INTERFACE_ClientNode);
        create_object.int(spa.PW_VERSION_CLIENT_NODE);
        dictionary(create_object, properties);
        create_object.uint(self.proxy);
        _ = try connection.end(spa.PW_ID_CORE, spa.PW_CORE_METHOD_CREATE_OBJECT);
        if (format) |value| self.format = try self.arena.allocator().dupe(u8, value);
        try self.updateNode(properties, true);
        for (self.ports, 0..) |*port, index| try self.updatePort(port, @intCast(index));
        var active = connection.begin();
        active.boolean(true);
        _ = try connection.end(self.proxy, spa.PW_CLIENT_NODE_METHOD_SET_ACTIVE);
    }

    /// Sends the node's parameters and info. A node with a stream format also
    /// has (empty) Props: session managers wait for Props to change after
    /// configuring an adapter's ports, and this node's ports are fixed.
    fn updateNode(self: *Node, properties: []const [2][]const u8, initial: bool) !void {
        var props: [16]u8 align(8) = undefined;
        const props_param = (Pod.Builder.init(&props, spa.SPA_TYPE_OBJECT_Props, spa.SPA_PARAM_Props) catch unreachable).view().bytes;
        const update = self.connection.begin();
        update.int(spa.PW_CLIENT_NODE_UPDATE_PARAMS | spa.PW_CLIENT_NODE_UPDATE_INFO);
        if (self.format) |value| {
            update.int(2);
            update.pod(value);
            update.pod(props_param);
        } else update.int(0);
        update.beginStruct();
        update.int(0);
        update.uint(@intCast(self.ports.len));
        update.long(if (initial) spa.SPA_NODE_CHANGE_MASK_FLAGS | spa.SPA_NODE_CHANGE_MASK_PROPS | spa.SPA_NODE_CHANGE_MASK_PARAMS else spa.SPA_NODE_CHANGE_MASK_PARAMS);
        update.long(spa.SPA_NODE_FLAG_RT);
        items(update, if (initial) properties else &.{});
        if (self.format != null) {
            update.int(2);
            update.id(spa.SPA_PARAM_EnumFormat);
            update.int(spa.SPA_PARAM_INFO_READ);
            update.id(spa.SPA_PARAM_Props);
            update.int(spa.SPA_PARAM_INFO_READ | @as(i32, if (self.props_serial) spa.SPA_PARAM_INFO_SERIAL else 0));
        } else update.int(0);
        update.endStruct();
        _ = try self.connection.end(self.proxy, spa.PW_CLIENT_NODE_METHOD_UPDATE);
    }

    /// Sends a port's parameters and info, as they stand.
    fn updatePort(self: *Node, port: *Port, index: u32) !void {
        var io: [64]u8 align(8) = undefined;
        const io_param = paramIO(&io);
        var message = self.connection.begin();
        message.int(spa.SPA_DIRECTION_OUTPUT);
        message.uint(index);
        message.int(spa.PW_CLIENT_NODE_PORT_UPDATE_PARAMS | spa.PW_CLIENT_NODE_PORT_UPDATE_INFO);
        const count: i32 = 2 + @as(i32, @intFromBool(port.format != null)) + @as(i32, @intFromBool(port.buffers_param != null));
        message.int(count);
        message.pod(port.spec.enum_format);
        message.pod(io_param);
        if (port.format) |format| message.pod(format);
        if (port.buffers_param) |buffers| message.pod(buffers);
        message.beginStruct();
        message.long(spa.SPA_PORT_CHANGE_MASK_FLAGS | spa.SPA_PORT_CHANGE_MASK_RATE | spa.SPA_PORT_CHANGE_MASK_PROPS | spa.SPA_PORT_CHANGE_MASK_PARAMS);
        message.long(0);
        message.int(0);
        message.int(1);
        items(message, port.spec.properties);
        message.int(4);
        message.id(spa.SPA_PARAM_EnumFormat);
        message.int(spa.SPA_PARAM_INFO_READ);
        message.id(spa.SPA_PARAM_IO);
        message.int(spa.SPA_PARAM_INFO_READ);
        message.id(spa.SPA_PARAM_Format);
        message.int(if (port.format != null) spa.SPA_PARAM_INFO_READWRITE else spa.SPA_PARAM_INFO_WRITE);
        message.id(spa.SPA_PARAM_Buffers);
        message.int(if (port.buffers_param != null) spa.SPA_PARAM_INFO_READ else 0);
        message.endStruct();
        _ = try self.connection.end(self.proxy, spa.PW_CLIENT_NODE_METHOD_PORT_UPDATE);
    }

    fn run(self: *Node) void {
        const quit = if (self.loop()) |_| unreachable else |err| switch (err) {
            error.Quit => true,
            error.Finished => blk: {
                self.state.store(.finished, .release);
                break :blk false;
            },
            else => blk: {
                self.state.store(.failed, .release);
                break :blk false;
            },
        };
        // A node that stopped on its own leaves the graph at once, rather than
        // staying registered with nobody servicing it until destroy.
        if (quit) return;
        self.leave();
        // Wait for destroy so that published state stays valid until then.
        while (true) {
            var poll = [_]libc.pollfd{.{ .fd = self.wake[0], .events = 1, .revents = 0 }};
            if (libc.poll(&poll, 1, -1) < 0) continue;
            var byte: [16]u8 = undefined;
            const count = libc.read(self.wake[0], &byte, byte.len);
            if (count > 0 and std.mem.indexOfScalar(u8, byte[0..@intCast(count)], 'q') != null) return;
        }
    }

    fn loop(self: *Node) !void {
        while (true) {
            var polls = [3]libc.pollfd{
                .{ .fd = self.wake[0], .events = 1, .revents = 0 },
                .{ .fd = self.connection.fd, .events = 1, .revents = 0 },
                .{ .fd = if (self.running) self.readfd else -1, .events = 1, .revents = 0 },
            };
            if (libc.poll(&polls, polls.len, -1) < 0) {
                if (std.c._errno().* == 4) continue;
                return error.IoFailed;
            }
            if (polls[2].revents & 1 != 0) {
                var count: u64 = 0;
                if (libc.read(self.readfd, &count, 8) == 8) try self.processNode(nanoseconds());
            }
            if (polls[0].revents & 1 != 0) {
                var bytes: [16]u8 = undefined;
                const count = libc.read(self.wake[0], &bytes, bytes.len);
                if (count > 0) for (bytes[0..@intCast(count)]) |byte| switch (byte) {
                    'q' => return error.Quit,
                    't' => try self.startCycle(),
                    else => {},
                };
            }
            if (polls[1].revents & 1 != 0) {
                try self.connection.read();
                while (try self.connection.next()) |message| {
                    var body = message.body;
                    if (message.id == spa.PW_ID_CORE) try self.core(message.opcode, &body) else if (message.id == self.proxy) try self.event(message.opcode, &body);
                }
            } else if (polls[1].revents & (8 | 16 | 32) != 0) return error.ConnectionClosed;
        }
    }

    fn core(self: *Node, opcode: u8, body: *wire.Reader) !void {
        switch (opcode) {
            spa.PW_CORE_EVENT_PING => {
                const id = try body.int();
                const sequence = try body.int();
                const message = self.connection.begin();
                message.int(id);
                message.int(sequence);
                _ = try self.connection.end(spa.PW_ID_CORE, spa.PW_CORE_METHOD_PONG);
            },
            spa.PW_CORE_EVENT_ERROR => {
                const id = try body.uint();
                if (id == spa.PW_ID_CORE or id == self.proxy) return error.ServerError;
            },
            spa.PW_CORE_EVENT_REMOVE_ID => {
                const id = try body.uint();
                if (id == self.proxy) return error.ConnectionClosed;
                self.connection.releaseId(id);
            },
            spa.PW_CORE_EVENT_BOUND_ID, spa.PW_CORE_EVENT_BOUND_PROPS => {
                const id = try body.uint();
                const global = try body.uint();
                if (id == self.proxy) {
                    self.global_id.store(global, .release);
                    if (self.state.load(.acquire) == .connecting) self.state.store(.paused, .release);
                }
            },
            spa.PW_CORE_EVENT_ADD_MEM => {
                const id = try body.uint();
                _ = try body.id(); // type: the descriptor is mapped whatever it is
                const fd = try self.connection.takeFd(try body.fd());
                self.removeMemory(id);
                self.memory.append(self.allocator, .{ .id = id, .fd = fd }) catch {
                    _ = libc.close(fd);
                    return error.OutOfMemory;
                };
            },
            spa.PW_CORE_EVENT_REMOVE_MEM => self.removeMemory(try body.uint()),
            else => {},
        }
    }

    fn event(self: *Node, opcode: u8, body: *wire.Reader) !void {
        switch (opcode) {
            spa.PW_CLIENT_NODE_EVENT_TRANSPORT => {
                const readfd = try self.connection.takeFd(try body.fd());
                const writefd = self.connection.takeFd(try body.fd()) catch |err| {
                    _ = libc.close(readfd);
                    return err;
                };
                self.closeTransport();
                self.readfd = readfd;
                self.writefd = writefd;
                const map = try self.mapMemory(try body.uint(), try body.uint(), try body.uint(), @sizeOf(Activation));
                self.activation = map;
                const activation = self.own();
                if (activation.server_version < 1) return error.UnsupportedServer;
                activation.client_version = 1;
                activation.active_driver_id = self.currentPosition().clock.id;
            },
            spa.PW_CLIENT_NODE_EVENT_SET_PARAM => {
                // The ports are fixed, so a port configuration is accepted as
                // is; announcing new Props tells the sender it took effect.
                if (try body.id() != spa.SPA_PARAM_PortConfig or self.format == null) return;
                self.props_serial = !self.props_serial;
                try self.updateNode(&.{}, false);
            },
            spa.PW_CLIENT_NODE_EVENT_SET_IO => {
                const id = try body.id();
                const memory = try body.uint();
                const offset = try body.uint();
                const size = try body.uint();
                const slot = switch (id) {
                    spa.SPA_IO_Position => &self.position,
                    spa.SPA_IO_Clock => &self.clock,
                    else => return,
                };
                if (slot.*) |old| old.destroy();
                slot.* = null;
                if (memory != invalid) slot.* = try self.mapMemory(memory, offset, size, if (id == spa.SPA_IO_Position) @sizeOf(spa.spa_io_position) else @sizeOf(spa.spa_io_clock));
                if (self.activation != null) self.own().active_driver_id = self.currentPosition().clock.id;
            },
            spa.PW_CLIENT_NODE_EVENT_COMMAND => {
                const command = try body.object() orelse return error.Protocol;
                if (get(command[8..]) != spa.SPA_TYPE_COMMAND_Node) return;
                switch (get(command[12..])) {
                    spa.SPA_NODE_COMMAND_Start => self.start(),
                    spa.SPA_NODE_COMMAND_Pause, spa.SPA_NODE_COMMAND_Suspend => self.stop(),
                    else => {},
                }
            },
            spa.PW_CLIENT_NODE_EVENT_PORT_SET_PARAM => {
                const port = try self.findPort(try body.uint(), try body.uint());
                const id = try body.id();
                _ = try body.int();
                if (id == spa.SPA_PARAM_Format) try self.setFormat(port, try body.object());
            },
            spa.PW_CLIENT_NODE_EVENT_PORT_USE_BUFFERS => {
                const port = try self.findPort(try body.uint(), try body.uint());
                _ = try body.uint(); // mix: output buffers belong to the port
                _ = try body.int();
                try self.useBuffers(port, body);
            },
            spa.PW_CLIENT_NODE_EVENT_PORT_SET_IO => {
                const port = try self.findPort(try body.uint(), try body.uint());
                const mix = try body.uint();
                const id = try body.id();
                const memory = try body.uint();
                const offset = try body.uint();
                const size = try body.uint();
                if (id != spa.SPA_IO_Buffers and id != spa.SPA_IO_AsyncBuffers) return;
                const entry = try self.mixEntry(port, mix);
                if (entry.map) |old| old.destroy();
                entry.map = null;
                if (memory != invalid) entry.map = try self.mapMemory(memory, offset, size, @sizeOf(spa.spa_io_buffers));
            },
            spa.PW_CLIENT_NODE_EVENT_SET_ACTIVATION => {
                const id = try body.uint();
                const index = try body.fd();
                const memory = try body.uint();
                const offset = try body.uint();
                const size = try body.uint();
                self.removeTarget(id);
                if (memory == invalid) return;
                const fd = try self.connection.takeFd(index);
                const map = self.mapMemory(memory, offset, size, @sizeOf(Activation)) catch |err| {
                    _ = libc.close(fd);
                    return err;
                };
                self.targets.append(self.allocator, .{ .id = id, .fd = fd, .map = map }) catch {
                    map.destroy();
                    _ = libc.close(fd);
                    return error.OutOfMemory;
                };
            },
            spa.PW_CLIENT_NODE_EVENT_PORT_SET_MIX_INFO => {
                const port = try self.findPort(try body.uint(), try body.uint());
                const mix = try body.uint();
                if (try body.uint() != invalid) {
                    _ = try self.mixEntry(port, mix);
                } else for (port.mixes.items, 0..) |entry, index| if (entry.id == mix) {
                    if (entry.map) |map| map.destroy();
                    _ = port.mixes.swapRemove(index);
                    break;
                };
            },
            else => {},
        }
    }

    fn findPort(self: *Node, direction: u32, index: u32) !*Port {
        if (direction != spa.SPA_DIRECTION_OUTPUT or index >= self.ports.len) return error.Protocol;
        return &self.ports[index];
    }

    fn mixEntry(self: *Node, port: *Port, id: u32) !*Mix {
        for (port.mixes.items) |*entry| if (entry.id == id) return entry;
        try port.mixes.append(self.allocator, .{ .id = id });
        return &port.mixes.items[port.mixes.items.len - 1];
    }

    fn setFormat(self: *Node, port: *Port, format: ?[]const u8) !void {
        clearBuffers(port);
        const arena = self.arena.allocator();
        port.format = null;
        port.buffers_param = null;
        if (format) |value| {
            const index: u32 = @intCast(port - self.ports.ptr);
            const buffers = self.handler.format(self.handler.context, index, value, &self.scratch) orelse return error.FormatRejected;
            port.format = try arena.dupe(u8, value);
            port.buffers_param = try arena.dupe(u8, buffers);
        }
        try self.updatePort(port, @intCast(port - self.ports.ptr));
    }

    fn useBuffers(self: *Node, port: *Port, body: *wire.Reader) !void {
        clearBuffers(port);
        errdefer clearBuffers(port);
        const count = try body.uint();
        if (count > 64) return error.Protocol;
        for (0..count) |_| {
            const meta = try self.mapMemory(try body.uint(), try body.uint(), try body.uint(), 16);
            var buffer: PortBuffer = .{ .meta = meta, .data_map = null, .data = &.{}, .chunk = undefined };
            errdefer meta.destroy();
            const metas = try body.uint();
            if (metas > 16) return error.Protocol;
            var offset: usize = 0;
            for (0..metas) |_| {
                _ = try body.id();
                offset += std.mem.alignForward(usize, try body.uint(), 8);
            }
            const datas = try body.uint();
            if (datas == 0 or datas > 16 or offset + datas * @sizeOf(spa.spa_chunk) > meta.bytes.len) return error.Protocol;
            buffer.chunk = @ptrCast(@alignCast(meta.bytes[offset..].ptr));
            for (0..datas) |index| {
                const kind = try body.id();
                const data = try body.uint();
                _ = try body.int(); // flags
                const map_offset = try body.uint();
                const max_size = try body.uint();
                if (index > 0) continue;
                switch (kind) {
                    spa.SPA_DATA_MemPtr => {
                        if (data > meta.bytes.len or max_size > meta.bytes.len - data) return error.Protocol;
                        buffer.data = meta.bytes[data..][0..max_size];
                    },
                    spa.SPA_DATA_MemId => {
                        const map = try self.mapMemory(data, map_offset, max_size, 1);
                        buffer.data_map = map;
                        buffer.data = map.bytes;
                    },
                    else => return error.UnsupportedBuffer,
                }
            }
            port.buffers.append(self.allocator, buffer) catch {
                if (buffer.data_map) |map| map.destroy();
                return error.OutOfMemory;
            };
        }
        port.next = 0;
    }

    fn clearBuffers(port: *Port) void {
        for (port.buffers.items) |buffer| {
            if (buffer.data_map) |map| map.destroy();
            buffer.meta.destroy();
        }
        port.buffers.clearRetainingCapacity();
    }

    fn mapMemory(self: *Node, id: u32, offset: u32, size: u32, minimum: usize) !Mapping {
        if (size < minimum) return error.Protocol;
        for (self.memory.items) |entry| if (entry.id == id) return Mapping.create(entry.fd, offset, size);
        return error.UnknownMemory;
    }

    fn removeMemory(self: *Node, id: u32) void {
        for (self.memory.items, 0..) |entry, index| if (entry.id == id) {
            _ = libc.close(entry.fd);
            _ = self.memory.swapRemove(index);
            return;
        };
    }

    fn removeTarget(self: *Node, id: u32) void {
        for (self.targets.items, 0..) |target, index| if (target.id == id) {
            target.map.destroy();
            _ = libc.close(target.fd);
            _ = self.targets.swapRemove(index);
            return;
        };
    }

    fn closeTransport(self: *Node) void {
        self.running = false;
        if (self.activation) |map| map.destroy();
        self.activation = null;
        for ([_]*c_int{ &self.readfd, &self.writefd }) |fd| if (fd.* >= 0) {
            _ = libc.close(fd.*);
            fd.* = -1;
        };
    }

    fn release(self: *Node) void {
        for (self.ports) |*value| {
            clearBuffers(value);
            for (value.mixes.items) |entry| if (entry.map) |map| map.destroy();
            value.mixes.deinit(self.allocator);
            value.buffers.deinit(self.allocator);
        }
        while (self.targets.items.len > 0) self.removeTarget(self.targets.items[0].id);
        self.targets.deinit(self.allocator);
        for ([_]*?Mapping{ &self.position, &self.clock }) |slot| if (slot.*) |map| {
            map.destroy();
            slot.* = null;
        };
        self.closeTransport();
        for (self.memory.items) |entry| _ = libc.close(entry.fd);
        self.memory.deinit(self.allocator);
    }

    /// Leaves the graph without waiting for destroy: closing the socket
    /// makes the server remove the node and stop scheduling it.
    fn leave(self: *Node) void {
        self.stop();
        _ = std.c.shutdown(self.connection.fd, 2);
    }

    fn own(self: *Node) *Activation {
        return @ptrCast(@alignCast(self.activation.?.bytes.ptr));
    }

    /// The driver's position, or this node's own until the server assigns one.
    fn currentPosition(self: *Node) *spa.spa_io_position {
        if (self.position) |map| return @ptrCast(@alignCast(map.bytes.ptr));
        return &self.own().position;
    }

    fn driving(self: *Node) bool {
        if (!self.driver or self.activation == null) return false;
        const clock: *spa.spa_io_clock = if (self.clock) |map| @ptrCast(@alignCast(map.bytes.ptr)) else &self.own().position.clock;
        return self.currentPosition().clock.id == clock.id;
    }

    fn start(self: *Node) void {
        if (self.activation == null or self.running) return;
        var count: u64 = 0;
        _ = libc.read(self.readfd, &count, 8);
        @atomicStore(u32, &self.own().status, finished_status, .seq_cst);
        self.running = true;
        self.state.store(.streaming, .release);
    }

    fn stop(self: *Node) void {
        if (!self.running) return;
        self.running = false;
        const old = @atomicRmw(u32, &self.own().status, .Xchg, inactive, .seq_cst);
        // Peers still count on this node in the current cycle.
        if (old <= awake) self.triggerTargets(nanoseconds());
        if (self.state.load(.acquire) == .streaming) self.state.store(.paused, .release);
    }

    /// The node's eventfd fired: process this cycle, then wake dependants.
    fn processNode(self: *Node, now: u64) !void {
        const activation = self.own();
        if (@cmpxchgStrong(u32, &activation.status, triggered, awake, .seq_cst, .seq_cst) != null) return;
        activation.awake_time = now;
        _ = @atomicRmw(u32, &activation.bits, .And, ~@as(u32, pending_sync_bit), .seq_cst);
        const driving_now = self.driving();
        // A driver's own wakeup ends the cycle it started: there is nothing to produce.
        var done = false;
        const status: i32 = if (driving_now) spa.SPA_STATUS_NEED_DATA else self.produce(&done);
        activation.state[0].status = status;
        const end = nanoseconds();
        const was_awake = @cmpxchgStrong(u32, &activation.status, awake, finished_status, .seq_cst, .seq_cst) == null;
        activation.finish_time = end;
        if (!driving_now and was_awake) self.triggerTargets(end);
        if (done) return error.Finished;
    }

    /// Starts a cycle as the graph's driver.
    fn startCycle(self: *Node) !void {
        if (!self.running or !self.driving()) return;
        const activation = self.own();
        const now = nanoseconds();
        // An unfinished previous cycle is completed before the next starts.
        while (true) {
            const old = @atomicLoad(u32, &activation.status, .seq_cst);
            if (old == finished_status) break;
            if (@cmpxchgStrong(u32, &activation.status, old, triggered, .seq_cst, .seq_cst) == null) {
                try self.processNode(now);
                break;
            }
        }
        var done = false;
        _ = self.produce(&done);
        const id = activation.position.clock.id;
        var pending: i32 = 0;
        for (self.targets.items) |target| {
            const peer: *Activation = @ptrCast(@alignCast(target.map.bytes.ptr));
            peer.driver_id = id;
            while (true) {
                @atomicStore(i32, &peer.state[0].pending, @atomicLoad(i32, &peer.state[0].required, .seq_cst), .seq_cst);
                if (peer.active_driver_id != peer.driver_id) break;
                const old = @atomicLoad(u32, &peer.status, .seq_cst);
                if (old == inactive) break;
                if (@cmpxchgStrong(u32, &peer.status, old, not_triggered, .seq_cst, .seq_cst) != null) continue;
                if (peer.flags & activation_flag_async == 0) pending += 1;
                break;
            }
        }
        @atomicStore(i32, &activation.state[0].pending, pending, .seq_cst);
        const clock = &activation.position.clock;
        clock.nsec = now;
        clock.position +%= clock.duration;
        clock.cycle +%= 1;
        self.triggerTargets(now);
        if (done) return error.Finished;
    }

    fn triggerTargets(self: *Node, now: u64) void {
        for (self.targets.items) |target| {
            const peer: *Activation = @ptrCast(@alignCast(target.map.bytes.ptr));
            if (@atomicRmw(i32, &peer.state[0].pending, .Sub, 1, .seq_cst) != 1) continue;
            if (@cmpxchgStrong(u32, &peer.status, not_triggered, triggered, .seq_cst, .seq_cst) != null) continue;
            peer.signal_time = now;
            const one: u64 = 1;
            _ = libc.write(target.fd, &one, 8);
        }
    }

    /// Lets the handler fill one buffer per port and publishes those it filled.
    fn produce(self: *Node, done: *bool) i32 {
        const position = self.currentPosition();
        var buffers: [8]?Buffer = @splat(null);
        const count = @min(self.ports.len, buffers.len);
        var chosen: [8]usize = undefined;
        for (self.ports[0..count], 0..) |*value, index| {
            if (value.buffers.items.len == 0 or value.mixes.items.len == 0) continue;
            // Each buffer is valid for a cycle; rotate so peers never see a buffer being rewritten.
            chosen[index] = value.next % value.buffers.items.len;
            value.next = chosen[index] + 1;
            const buffer = value.buffers.items[chosen[index]];
            buffer.chunk.* = .{ .offset = 0, .size = 0, .stride = 0, .flags = 0 };
            buffers[index] = .{ .data = buffer.data, .chunk = buffer.chunk };
        }
        var cycle: Cycle = .{ .duration = position.clock.duration, .rate = position.clock.rate.denom, .buffers = buffers[0..count] };
        self.handler.process(self.handler.context, &cycle);
        done.* = cycle.finished;
        var status: i32 = spa.SPA_STATUS_NEED_DATA;
        const parity = position.clock.cycle & 1;
        for (self.ports[0..count], buffers[0..count], 0..) |*value, buffer, index| {
            const filled = buffer orelse continue;
            if (filled.chunk.size == 0) continue;
            status = spa.SPA_STATUS_HAVE_DATA;
            for (value.mixes.items) |entry| {
                const map = entry.map orelse continue;
                // Async links have two slots; the output side writes the one
                // the input side reads in the next cycle.
                const slot: usize = if (map.bytes.len >= 2 * @sizeOf(spa.spa_io_buffers)) parity ^ 1 else 0;
                const io: *spa.spa_io_buffers = @ptrCast(@alignCast(map.bytes[slot * @sizeOf(spa.spa_io_buffers) ..].ptr));
                @atomicStore(u32, &io.buffer_id, @intCast(chosen[index]), .seq_cst);
                @atomicStore(i32, &io.status, spa.SPA_STATUS_HAVE_DATA, .seq_cst);
            }
        }
        return status;
    }
};

fn get(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], @import("builtin").cpu.arch.endian());
}

fn nanoseconds() u64 {
    var now: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

fn dictionary(message: *wire.Writer, entries: []const [2][]const u8) void {
    message.beginStruct();
    message.int(@intCast(entries.len));
    for (entries) |entry| {
        message.string(entry[0]);
        message.string(entry[1]);
    }
    message.endStruct();
}

/// Dictionary items inline in an info struct: a count, then key/value pairs.
fn items(message: *wire.Writer, entries: []const [2][]const u8) void {
    message.int(@intCast(entries.len));
    for (entries) |entry| {
        message.string(entry[0]);
        message.string(entry[1]);
    }
}

/// Output ports exchange buffers through a spa_io_buffers area.
fn paramIO(bytes: *align(8) [64]u8) []const u8 {
    var builder = Pod.Builder.init(bytes, spa.SPA_TYPE_OBJECT_ParamIO, spa.SPA_PARAM_IO) catch unreachable;
    builder.identifier(spa.SPA_PARAM_IO_id, spa.SPA_IO_Buffers) catch unreachable;
    builder.integer(spa.SPA_PARAM_IO_size, @sizeOf(spa.spa_io_buffers)) catch unreachable;
    return builder.view().bytes;
}

comptime {
    // Layout of PipeWire's private activation record (src/pipewire/private.h, 1.x).
    std.debug.assert(@sizeOf(Activation) == 2312);
    std.debug.assert(@offsetOf(Activation, "client_version") == 540);
    std.debug.assert(@offsetOf(Activation, "position") == 560);
    std.debug.assert(@offsetOf(Activation, "command") == 2304);
}

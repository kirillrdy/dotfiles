//! PipeWire's native protocol over its Unix socket, without libpipewire.
//! Each message is a 16-byte header (object id, opcode and size, sequence,
//! descriptor count) followed by a SPA Struct POD. Descriptors sent with a
//! message arrive as ancillary data and are referenced by index from its body.
const std = @import("std");
const spa = @import("desktop-spa.zig");
const Pod = @import("desktop-audio-pod.zig");
const endian = @import("builtin").cpu.arch.endian();

pub const Error = error{ ConnectionFailed, ConnectionClosed, IoFailed, Protocol, OutOfMemory };

const max_message = 1024 * 1024;

pub const Message = struct { id: u32, opcode: u8, body: Reader, fds: []c_int };

pub const Connection = struct {
    allocator: std.mem.Allocator,
    fd: c_int,
    sequence: u32 = 0,
    /// Next id never used; freed ids are reused last-in first-out, as the
    /// server's id map requires.
    next_id: u32 = 2,
    free_ids: std.ArrayList(u32) = .empty,
    in: std.ArrayList(u8) = .empty,
    /// Bytes of `in` belonging to the message last returned by `next`.
    consumed: usize = 0,
    /// Received descriptors not yet claimed by a message, in arrival order.
    fds: std.ArrayList(c_int) = .empty,
    /// Descriptors of the message last returned by `next`; those not taken
    /// are closed when the next message is returned.
    message_fds: std.ArrayList(c_int) = .empty,
    /// The server closed the socket.
    closed: bool = false,
    out: Writer,

    /// Connects like libpipewire: $PIPEWIRE_REMOTE (default pipewire-0) in
    /// $PIPEWIRE_RUNTIME_DIR or $XDG_RUNTIME_DIR, then says hello as a client.
    pub fn connect(a: std.mem.Allocator, properties: []const [2][]const u8) Error!*Connection {
        const name: []const u8 = if (std.c.getenv("PIPEWIRE_REMOTE")) |value| std.mem.span(value) else "pipewire-0";
        var address: SockaddrUn = .{};
        if (name.len > 0 and name[0] == '/') {
            if (name.len >= address.path.len) return error.ConnectionFailed;
            @memcpy(address.path[0..name.len], name);
        } else {
            const runtime = std.c.getenv("PIPEWIRE_RUNTIME_DIR") orelse std.c.getenv("XDG_RUNTIME_DIR") orelse return error.ConnectionFailed;
            _ = std.fmt.bufPrint(&address.path, "{s}/{s}", .{ std.mem.span(runtime), name }) catch return error.ConnectionFailed;
        }
        const fd = std.c.socket(1, 1 | 0o2000000, 0); // AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC
        if (fd < 0) return error.ConnectionFailed;
        if (std.c.connect(fd, @ptrCast(&address), @sizeOf(SockaddrUn)) != 0) {
            _ = std.c.close(fd);
            return error.ConnectionFailed;
        }
        // From here the connection owns the socket.
        const self = fromFd(a, fd) catch |err| {
            _ = std.c.close(fd);
            return err;
        };
        errdefer self.destroy();
        var hello = self.begin();
        hello.int(spa.PW_VERSION_CORE);
        _ = try self.end(spa.PW_ID_CORE, spa.PW_CORE_METHOD_HELLO);
        var update = self.begin();
        update.beginStruct();
        update.int(@intCast(properties.len));
        for (properties) |entry| {
            update.string(entry[0]);
            update.string(entry[1]);
        }
        update.endStruct();
        _ = try self.end(1, spa.PW_CLIENT_METHOD_UPDATE_PROPERTIES);
        return self;
    }

    pub fn fromFd(a: std.mem.Allocator, fd: c_int) Error!*Connection {
        const self = try a.create(Connection);
        self.* = .{ .allocator = a, .fd = fd, .out = .{ .allocator = a } };
        return self;
    }

    pub fn destroy(self: *Connection) void {
        _ = std.c.close(self.fd);
        self.closeMessageFds();
        for (self.fds.items) |fd| _ = std.c.close(fd);
        self.fds.deinit(self.allocator);
        self.message_fds.deinit(self.allocator);
        self.free_ids.deinit(self.allocator);
        self.in.deinit(self.allocator);
        self.out.bytes.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// A client id for a new proxy.
    pub fn newId(self: *Connection) u32 {
        if (self.free_ids.pop()) |id| return id;
        defer self.next_id += 1;
        return self.next_id;
    }

    /// The server released `id` (Core remove_id); it may be reused.
    pub fn releaseId(self: *Connection, id: u32) void {
        if (id < 2 or id >= self.next_id) return;
        for (self.free_ids.items) |free| if (free == id) return;
        self.free_ids.append(self.allocator, id) catch {};
    }

    /// Starts a message body; its fields go in the returned top-level Struct.
    pub fn begin(self: *Connection) *Writer {
        self.out.reset();
        self.out.beginStruct();
        return &self.out;
    }

    /// Sends the message begun with `begin`, blocking until it is written.
    /// Returns the message sequence number.
    pub fn end(self: *Connection, id: u32, opcode: u8) Error!u32 {
        self.out.endStruct();
        if (self.out.failed) return error.OutOfMemory;
        const body = self.out.bytes.items;
        if (body.len > 0xffffff) return error.Protocol;
        var header: [16]u8 = undefined;
        put(header[0..4], id);
        put(header[4..8], (@as(u32, opcode) << 24) | @as(u32, @intCast(body.len)));
        put(header[8..12], self.sequence);
        put(header[12..16], 0);
        const sequence = self.sequence;
        self.sequence +%= 1;
        try self.write(&header);
        try self.write(body);
        return sequence;
    }

    fn write(self: *Connection, bytes: []const u8) Error!void {
        var rest = bytes;
        while (rest.len > 0) {
            const sent = std.c.send(self.fd, rest.ptr, rest.len, 0x4000); // MSG_NOSIGNAL
            if (sent < 0) {
                if (std.c._errno().* == 4) continue; // EINTR
                return error.IoFailed;
            }
            rest = rest[@intCast(sent)..];
        }
    }

    /// Claims descriptor `index` of the current message; the caller then owns it.
    pub fn takeFd(self: *Connection, index: i64) Error!c_int {
        if (index < 0 or index >= self.message_fds.items.len) return error.Protocol;
        const fd = self.message_fds.items[@intCast(index)];
        if (fd < 0) return error.Protocol;
        self.message_fds.items[@intCast(index)] = -1;
        return fd;
    }

    fn closeMessageFds(self: *Connection) void {
        for (self.message_fds.items) |fd| {
            if (fd >= 0) _ = std.c.close(fd);
        }
        self.message_fds.clearRetainingCapacity();
    }

    /// Reads what the socket holds without blocking, queueing any descriptors.
    /// After the server closes the socket, messages already received are still
    /// returned by `next`; the following read reports the closed connection.
    pub fn read(self: *Connection) Error!void {
        if (self.closed) return error.ConnectionClosed;
        while (true) {
            if (self.in.items.len > 4 * max_message) return error.Protocol;
            try self.in.ensureUnusedCapacity(self.allocator, 64 * 1024);
            const spare = self.in.unusedCapacitySlice();
            var iov = [_]std.posix.iovec{.{ .base = spare.ptr, .len = spare.len }};
            var control: [16 + 28 * 4]u8 align(8) = undefined;
            var header: std.c.msghdr = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &control, .controllen = control.len, .flags = 0 };
            const received = std.c.recvmsg(self.fd, &header, 0x40 | 0x40000000); // MSG_DONTWAIT | MSG_CMSG_CLOEXEC
            if (received < 0) switch (std.c._errno().*) {
                4 => continue,
                11 => return,
                else => return error.IoFailed,
            };
            try self.queueFds(control[0..header.controllen]);
            // Lost descriptors would shift every later message's descriptors.
            if (header.flags & 0x8 != 0) return error.Protocol; // MSG_CTRUNC
            if (received == 0) {
                self.closed = true;
                if (self.in.items.len > self.consumed) return;
                return error.ConnectionClosed;
            }
            self.in.items.len += @intCast(received);
        }
    }

    /// The next complete message already read. Its body and descriptors are
    /// valid until the next call.
    pub fn next(self: *Connection) Error!?Message {
        self.closeMessageFds();
        if (self.consumed > 0) {
            const rest = self.in.items.len - self.consumed;
            std.mem.copyForwards(u8, self.in.items[0..rest], self.in.items[self.consumed..]);
            self.in.items.len = rest;
            self.consumed = 0;
        }
        const data = self.in.items;
        if (data.len < 16) return null;
        const word = get(data[4..8]);
        const size: usize = word & 0xffffff;
        if (data.len < 16 + size) return null;
        // Descriptors arrive with the first byte of their message, so once the
        // whole message is read, all of its descriptors are queued.
        const count = get(data[12..16]);
        if (count > self.fds.items.len) return error.Protocol;
        try self.message_fds.appendSlice(self.allocator, self.fds.items[0..count]);
        std.mem.copyForwards(c_int, self.fds.items, self.fds.items[count..]);
        self.fds.items.len -= count;
        self.consumed = 16 + size;
        // A footer POD may follow the body; only the first POD is the message.
        return .{ .id = get(data[0..4]), .opcode = @intCast(word >> 24), .body = try Reader.init(data[16..][0..size]), .fds = self.message_fds.items };
    }

    /// Queues SCM_RIGHTS descriptors. On failure, every one received is closed.
    fn queueFds(self: *Connection, control: []const u8) Error!void {
        var failed = false;
        var offset: usize = 0;
        while (offset + 16 <= control.len) {
            const len = std.mem.readInt(usize, control[offset..][0..8], endian);
            if (len < 16 or offset + len > control.len) break;
            if (std.mem.readInt(i32, control[offset + 8 ..][0..4], endian) == 1 and std.mem.readInt(i32, control[offset + 12 ..][0..4], endian) == 1) {
                var at = offset + 16;
                while (at + 4 <= offset + len) : (at += 4) {
                    const fd = std.mem.readInt(i32, control[at..][0..4], endian);
                    if (failed or self.fds.items.len >= 256) {
                        failed = true;
                        _ = std.c.close(fd);
                    } else self.fds.append(self.allocator, fd) catch {
                        failed = true;
                        _ = std.c.close(fd);
                    };
                }
            }
            offset += std.mem.alignForward(usize, len, 8);
        }
        if (failed) return error.Protocol;
    }
};

const SockaddrUn = extern struct {
    family: u16 = 1,
    path: [108]u8 = @splat(0),
};

const get = Pod.word;
const put = Pod.put;

/// Builds a POD: each value is a {size, type} header and a body padded to 8 bytes.
pub const Writer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    open: [8]usize = undefined,
    depth: usize = 0,
    failed: bool = false,

    fn reset(self: *Writer) void {
        self.bytes.clearRetainingCapacity();
        self.depth = 0;
        self.failed = false;
    }
    fn append(self: *Writer, bytes: []const u8) void {
        self.bytes.appendSlice(self.allocator, bytes) catch {
            self.failed = true;
        };
    }
    fn pad(self: *Writer) void {
        const padding = std.mem.alignForward(usize, self.bytes.items.len, 8) - self.bytes.items.len;
        self.append((@as([8]u8, @splat(0)))[0..padding]);
    }
    fn value(self: *Writer, kind: u32, body: []const u8) void {
        var header: [8]u8 = undefined;
        put(header[0..4], @intCast(body.len));
        put(header[4..8], kind);
        self.append(&header);
        self.append(body);
        self.pad();
    }
    pub fn beginStruct(self: *Writer) void {
        if (self.depth == self.open.len) {
            self.failed = true;
            return;
        }
        self.open[self.depth] = self.bytes.items.len;
        self.depth += 1;
        self.value(spa.SPA_TYPE_Struct, &.{});
    }
    pub fn endStruct(self: *Writer) void {
        if (self.depth == 0 or self.failed) {
            self.failed = true;
            return;
        }
        self.depth -= 1;
        const start = self.open[self.depth];
        put(self.bytes.items[start..][0..4], @intCast(self.bytes.items.len - start - 8));
    }
    fn scalar(self: *Writer, kind: u32, word: u32) void {
        var body: [4]u8 = undefined;
        put(&body, word);
        self.value(kind, &body);
    }
    pub fn int(self: *Writer, number: i32) void {
        self.scalar(spa.SPA_TYPE_Int, @bitCast(number));
    }
    pub fn uint(self: *Writer, number: u32) void {
        self.scalar(spa.SPA_TYPE_Int, number);
    }
    pub fn id(self: *Writer, number: u32) void {
        self.scalar(spa.SPA_TYPE_Id, number);
    }
    pub fn long(self: *Writer, number: i64) void {
        var body: [8]u8 = undefined;
        std.mem.writeInt(i64, &body, number, endian);
        self.value(spa.SPA_TYPE_Long, &body);
    }
    pub fn string(self: *Writer, text: ?[]const u8) void {
        const bytes = text orelse return self.value(spa.SPA_TYPE_None, &.{});
        var header: [8]u8 = undefined;
        put(header[0..4], @intCast(bytes.len + 1));
        put(header[4..8], spa.SPA_TYPE_String);
        self.append(&header);
        self.append(bytes);
        self.append(&.{0});
        self.pad();
    }
    pub fn boolean(self: *Writer, flag: bool) void {
        self.scalar(spa.SPA_TYPE_Bool, @intFromBool(flag));
    }
    pub fn none(self: *Writer) void {
        self.value(spa.SPA_TYPE_None, &.{});
    }
    pub fn ids(self: *Writer, values: []const u32) void {
        var header: [8]u8 = undefined;
        put(header[0..4], @intCast(8 + values.len * 4));
        put(header[4..8], spa.SPA_TYPE_Array);
        self.append(&header);
        var child: [8]u8 = undefined;
        put(child[0..4], 4);
        put(child[4..8], spa.SPA_TYPE_Id);
        self.append(&child);
        for (values) |entry| {
            var body: [4]u8 = undefined;
            put(&body, entry);
            self.append(&body);
        }
        self.pad();
    }
    /// Appends a complete POD (header included).
    pub fn pod(self: *Writer, bytes: []const u8) void {
        self.append(bytes);
        self.pad();
    }
};

/// Reads the fields of a Struct POD in order, validating every size.
pub const Reader = struct {
    rest: []const u8,

    pub fn init(bytes: []const u8) Error!Reader {
        const whole = try podBytes(bytes);
        if (get(whole[4..8]) != spa.SPA_TYPE_Struct) return error.Protocol;
        return .{ .rest = whole[8..] };
    }
    /// The next POD with its header; advances past its padding.
    pub fn raw(self: *Reader) Error![]const u8 {
        const whole = try podBytes(self.rest);
        const padded = std.mem.alignForward(usize, whole.len, 8);
        self.rest = self.rest[@min(padded, self.rest.len)..];
        return whole;
    }
    fn typed(self: *Reader, kind: u32, size: usize) Error![]const u8 {
        const whole = try self.raw();
        if (get(whole[4..8]) != kind or whole.len - 8 < size) return error.Protocol;
        return whole[8..];
    }
    pub fn int(self: *Reader) Error!i32 {
        return @bitCast(get(try self.typed(spa.SPA_TYPE_Int, 4)));
    }
    pub fn uint(self: *Reader) Error!u32 {
        return get(try self.typed(spa.SPA_TYPE_Int, 4));
    }
    pub fn id(self: *Reader) Error!u32 {
        return get(try self.typed(spa.SPA_TYPE_Id, 4));
    }
    pub fn long(self: *Reader) Error!i64 {
        return std.mem.readInt(i64, (try self.typed(spa.SPA_TYPE_Long, 8))[0..8], endian);
    }
    /// A descriptor's index in the message's descriptor list.
    pub fn fd(self: *Reader) Error!i64 {
        return std.mem.readInt(i64, (try self.typed(spa.SPA_TYPE_Fd, 8))[0..8], endian);
    }
    pub fn boolean(self: *Reader) Error!bool {
        return get(try self.typed(spa.SPA_TYPE_Bool, 4)) != 0;
    }
    /// An Object POD with its header, or null for a None POD.
    pub fn object(self: *Reader) Error!?[]const u8 {
        const whole = try self.raw();
        return switch (get(whole[4..8])) {
            spa.SPA_TYPE_None => null,
            spa.SPA_TYPE_Object => if (whole.len >= 16) whole else error.Protocol,
            else => error.Protocol,
        };
    }
    /// A String, or null for a None POD.
    pub fn string(self: *Reader) Error!?[:0]const u8 {
        const whole = try self.raw();
        const kind = get(whole[4..8]);
        if (kind == spa.SPA_TYPE_None) return null;
        const body = whole[8..];
        if (kind != spa.SPA_TYPE_String or body.len == 0 or body[body.len - 1] != 0) return error.Protocol;
        const text = body[0 .. body.len - 1];
        if (std.mem.indexOfScalar(u8, text, 0) != null) return error.Protocol;
        return body[0 .. body.len - 1 :0];
    }
    pub fn structure(self: *Reader) Error!Reader {
        return Reader.init(try self.raw());
    }
    /// A dictionary as PipeWire sends it: Struct(Int count, (String key, String value)*).
    pub fn dict(self: *Reader) Error!Dict {
        var inner = try self.structure();
        const count = try inner.int();
        if (count < 0 or count > 4096) return error.Protocol;
        return .{ .reader = inner, .count = @intCast(count) };
    }
};

pub const Dict = struct {
    reader: Reader,
    count: u32,
    pub fn next(self: *Dict) Error!?struct { key: [:0]const u8, value: ?[:0]const u8 } {
        if (self.count == 0) return null;
        self.count -= 1;
        const key = try self.reader.string() orelse return error.Protocol;
        return .{ .key = key, .value = try self.reader.string() };
    }
};

/// The bytes of the POD at the start of `bytes`, header included and padding excluded.
fn podBytes(bytes: []const u8) Error![]const u8 {
    return (Pod.View.init(bytes) catch return error.Protocol).bytes;
}

test "messages round-trip through the native framing and POD encoding" {
    const a = std.testing.allocator;
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(1, 1 | 0o2000000, 0, &fds));
    const client = try Connection.fromFd(a, fds[0]);
    defer client.destroy();
    const server = try Connection.fromFd(a, fds[1]);
    defer server.destroy();

    var message = client.begin();
    message.int(-7);
    message.id(spa.SPA_PARAM_Props);
    message.long(1 << 40);
    message.string("node.name");
    message.string(null);
    message.ids(&.{ spa.SPA_PARAM_Props, spa.SPA_PARAM_Route });
    message.beginStruct();
    message.int(1);
    message.string("media.class");
    message.string("Audio/Sink");
    message.endStruct();
    const sequence = try client.end(9, 3);
    try std.testing.expectEqual(@as(u32, 0), sequence);

    try server.read();
    var received = (try server.next()).?;
    try std.testing.expectEqual(@as(u32, 9), received.id);
    try std.testing.expectEqual(@as(u8, 3), received.opcode);
    try std.testing.expectEqual(@as(i32, -7), try received.body.int());
    try std.testing.expectEqual(@as(u32, spa.SPA_PARAM_Props), try received.body.id());
    try std.testing.expectEqual(@as(i64, 1 << 40), try received.body.long());
    try std.testing.expectEqualStrings("node.name", (try received.body.string()).?);
    try std.testing.expect(try received.body.string() == null);
    const array = try received.body.raw();
    try std.testing.expectEqual(@as(u32, spa.SPA_TYPE_Array), get(array[4..8]));
    try std.testing.expectEqual(@as(u32, spa.SPA_PARAM_Route), get(array[20..24]));
    var dict = try received.body.dict();
    const entry = (try dict.next()).?;
    try std.testing.expectEqualStrings("media.class", entry.key);
    try std.testing.expectEqualStrings("Audio/Sink", entry.value.?);
    try std.testing.expect(try dict.next() == null);
    try std.testing.expectError(error.Protocol, received.body.int());
    try std.testing.expect(try server.next() == null);
}

test "readers reject truncated and mistyped PODs" {
    var bytes: [24]u8 align(8) = @splat(0);
    put(bytes[0..4], 16);
    put(bytes[4..8], spa.SPA_TYPE_Struct);
    put(bytes[8..12], 4);
    put(bytes[12..16], spa.SPA_TYPE_Int);
    var reader = try Reader.init(&bytes);
    try std.testing.expectError(error.Protocol, reader.string());
    try std.testing.expectError(error.Protocol, Reader.init(bytes[0..20]));
    put(bytes[8..12], 64);
    reader = try Reader.init(&bytes);
    try std.testing.expectError(error.Protocol, reader.int());
    put(bytes[4..8], spa.SPA_TYPE_Int);
    try std.testing.expectError(error.Protocol, Reader.init(&bytes));
}

test "freed ids are reused last-in first-out after the server releases them" {
    const a = std.testing.allocator;
    const connection = try Connection.fromFd(a, -1);
    defer {
        connection.fd = -1;
        connection.destroy();
    }
    try std.testing.expectEqual(@as(u32, 2), connection.newId());
    try std.testing.expectEqual(@as(u32, 3), connection.newId());
    try std.testing.expectEqual(@as(u32, 4), connection.newId());
    connection.releaseId(3);
    connection.releaseId(2);
    connection.releaseId(9);
    try std.testing.expectEqual(@as(u32, 2), connection.newId());
    try std.testing.expectEqual(@as(u32, 3), connection.newId());
    try std.testing.expectEqual(@as(u32, 5), connection.newId());
}

/// Sends one message with `passed` descriptors attached, as the server does.
fn sendWithFds(fd: c_int, id: u32, opcode: u8, body: []const u8, passed: []const c_int, claimed: usize) !void {
    var header: [16]u8 = undefined;
    put(header[0..4], id);
    put(header[4..8], (@as(u32, opcode) << 24) | @as(u32, @intCast(body.len)));
    put(header[8..12], 0);
    put(header[12..16], @intCast(claimed));
    var control: [16 + 4 * 4]u8 align(8) = @splat(0);
    std.mem.writeInt(usize, control[0..8], 16 + 4 * passed.len, endian);
    std.mem.writeInt(i32, control[8..12], 1, endian); // SOL_SOCKET
    std.mem.writeInt(i32, control[12..16], 1, endian); // SCM_RIGHTS
    for (passed, 0..) |value, index| std.mem.writeInt(i32, control[16 + 4 * index ..][0..4], value, endian);
    var iov = [_]std.posix.iovec_const{ .{ .base = &header, .len = header.len }, .{ .base = body.ptr, .len = body.len } };
    const length = if (passed.len == 0) 0 else std.mem.alignForward(usize, 16 + 4 * passed.len, 8);
    const message: std.c.msghdr_const = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 2, .control = if (length == 0) null else &control, .controllen = @intCast(length), .flags = 0 };
    if (std.c.sendmsg(fd, &message, 0) != header.len + body.len) return error.IoFailed;
}

test "descriptors belong to the message that carries them and are closed unless taken" {
    const a = std.testing.allocator;
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(1, 1 | 0o2000000, 0, &fds));
    const client = try Connection.fromFd(a, fds[0]);
    defer client.destroy();
    var writer: Writer = .{ .allocator = a };
    defer writer.bytes.deinit(a);
    var pipe: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&pipe));
    defer for (pipe) |end| {
        _ = std.c.close(end);
    };
    // add_mem-like: an id and a descriptor index; then a message without descriptors.
    writer.beginStruct();
    writer.uint(7);
    var index: [8]u8 = undefined;
    std.mem.writeInt(i64, &index, 1, endian);
    writer.value(spa.SPA_TYPE_Fd, &index);
    writer.endStruct();
    try sendWithFds(fds[1], 0, 6, writer.bytes.items, &pipe, 2);
    writer.reset();
    writer.beginStruct();
    writer.uint(8);
    writer.endStruct();
    try sendWithFds(fds[1], 0, 7, writer.bytes.items, &.{}, 0);
    // Claims a descriptor that never arrived.
    try sendWithFds(fds[1], 0, 7, writer.bytes.items, &.{}, 1);

    try client.read();
    var first = (try client.next()).?;
    try std.testing.expectEqual(@as(usize, 2), first.fds.len);
    try std.testing.expectEqual(@as(u32, 7), try first.body.uint());
    const taken = try client.takeFd(try first.body.fd());
    defer _ = std.c.close(taken);
    const untaken = first.fds[0];
    try std.testing.expectError(error.Protocol, client.takeFd(1));
    try std.testing.expectError(error.Protocol, client.takeFd(2));
    try std.testing.expectEqual(@as(isize, 1), std.c.write(taken, "x", 1));

    var second = (try client.next()).?;
    try std.testing.expectEqual(@as(usize, 0), second.fds.len);
    try std.testing.expectEqual(@as(u32, 8), try second.body.uint());
    // The first message's unclaimed descriptor was closed with it.
    try std.testing.expectEqual(@as(c_int, -1), std.c.fcntl(untaken, 1));
    try std.testing.expectError(error.Protocol, client.next());
    _ = std.c.close(fds[1]);
}

test "messages sent just before the server closes are still delivered" {
    const a = std.testing.allocator;
    var fds: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(1, 1 | 0o2000000, 0, &fds));
    const client = try Connection.fromFd(a, fds[0]);
    defer client.destroy();
    const server = try Connection.fromFd(a, fds[1]);
    var message = server.begin();
    message.int(-32);
    _ = try server.end(spa.PW_ID_CORE, spa.PW_CORE_EVENT_ERROR);
    server.destroy();
    try client.read();
    var last = (try client.next()).?;
    try std.testing.expectEqual(@as(i32, -32), try last.body.int());
    try std.testing.expect(try client.next() == null);
    try std.testing.expectError(error.ConnectionClosed, client.read());
}

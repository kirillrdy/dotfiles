//! A native D-Bus client: bus addresses, SASL EXTERNAL, marshalling and asynchronous calls.
//!
//! Values are encoded from Zig types chosen at compile time: integers, bool,
//! f64, strings ([]const u8), `ObjectPath`, `Signature`, `Bytes`, slices
//! (arrays), structs and tuples (structures), `Dict` and the dynamic `Value`
//! (variants). The runtime has no GLib dependency; callers drive it from any
//! event loop through `getFd`, `readAndDispatch` and `expire`.
const std = @import("std");

pub const Bus = enum { session, system };
pub const ObjectPath = struct { value: []const u8 };
pub const Signature = struct { value: []const u8 };
/// A byte array (`ay`); plain `[]const u8` is a string.
pub const Bytes = struct { value: []const u8 };
/// A Unix file descriptor (`h`). Sent descriptors are duplicated; received ones belong to the caller.
pub const Fd = struct { value: i32 };

/// A dictionary (`a{KV}`) as an ordered list of entries.
pub fn Dict(comptime K: type, comptime V: type) type {
    return struct {
        entries: []const Entry,
        pub const Entry = struct { key: K, value: V };
        pub const dbus_dict = true;
    };
}

/// A dynamically typed value, used for variants (`v`) and anything decoded without a static type.
pub const Value = union(enum) {
    byte: u8,
    boolean: bool,
    int16: i16,
    uint16: u16,
    int32: i32,
    uint32: u32,
    int64: i64,
    uint64: u64,
    double: f64,
    string: []const u8,
    object_path: []const u8,
    signature: []const u8,
    fd: i32,
    /// A byte array (`ay`), kept as one slice rather than a Value per byte.
    bytes: []const u8,
    /// Items share one element signature; dictionaries hold `dict_entry` items.
    array: struct { element: []const u8, items: []const Value },
    structure: []const Value,
    dict_entry: *const [2]Value,
    variant: *const Value,

    /// The value's D-Bus type signature, written into `buffer`.
    pub fn signatureInto(self: Value, buffer: []u8) error{NoSpaceLeft}![]const u8 {
        var writer: std.Io.Writer = .fixed(buffer);
        self.writeSignature(&writer) catch return error.NoSpaceLeft;
        return writer.buffered();
    }
    fn writeSignature(self: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .byte => try writer.writeByte('y'),
            .boolean => try writer.writeByte('b'),
            .int16 => try writer.writeByte('n'),
            .uint16 => try writer.writeByte('q'),
            .int32 => try writer.writeByte('i'),
            .uint32 => try writer.writeByte('u'),
            .int64 => try writer.writeByte('x'),
            .uint64 => try writer.writeByte('t'),
            .double => try writer.writeByte('d'),
            .string => try writer.writeByte('s'),
            .object_path => try writer.writeByte('o'),
            .signature => try writer.writeByte('g'),
            .fd => try writer.writeByte('h'),
            .bytes => try writer.writeAll("ay"),
            .array => |array| {
                try writer.writeByte('a');
                try writer.writeAll(array.element);
            },
            .structure => |fields| {
                try writer.writeByte('(');
                for (fields) |field| try field.writeSignature(writer);
                try writer.writeByte(')');
            },
            .dict_entry => |entry| {
                try writer.writeByte('{');
                try entry[0].writeSignature(writer);
                try entry[1].writeSignature(writer);
                try writer.writeByte('}');
            },
            .variant => try writer.writeByte('v'),
        }
    }

    /// A deep copy whose storage comes from `allocator` (an arena is the intended use).
    pub fn clone(self: Value, allocator: std.mem.Allocator) error{OutOfMemory}!Value {
        return switch (self) {
            .string => |v| .{ .string = try allocator.dupe(u8, v) },
            .object_path => |v| .{ .object_path = try allocator.dupe(u8, v) },
            .signature => |v| .{ .signature = try allocator.dupe(u8, v) },
            .bytes => |v| .{ .bytes = try allocator.dupe(u8, v) },
            .array => |array| blk: {
                const items = try allocator.alloc(Value, array.items.len);
                for (items, array.items) |*out, item| out.* = try item.clone(allocator);
                break :blk .{ .array = .{ .element = try allocator.dupe(u8, array.element), .items = items } };
            },
            .structure => |fields| blk: {
                const items = try allocator.alloc(Value, fields.len);
                for (items, fields) |*out, item| out.* = try item.clone(allocator);
                break :blk .{ .structure = items };
            },
            .dict_entry => |entry| blk: {
                const copy = try allocator.create([2]Value);
                copy.* = .{ try entry[0].clone(allocator), try entry[1].clone(allocator) };
                break :blk .{ .dict_entry = copy };
            },
            .variant => |inner| blk: {
                const copy = try allocator.create(Value);
                copy.* = try inner.clone(allocator);
                break :blk .{ .variant = copy };
            },
            else => self,
        };
    }

    /// Looks up `key` in an `a{sv}`-style dictionary, unwrapping the variant.
    pub fn lookup(self: Value, key: []const u8) ?Value {
        const array = switch (self) {
            .array => |value| value,
            .variant => |inner| return inner.lookup(key),
            else => return null,
        };
        for (array.items) |item| switch (item) {
            .dict_entry => |entry| switch (entry[0]) {
                .string => |name| if (std.mem.eql(u8, name, key)) return switch (entry[1]) {
                    .variant => |inner| inner.*,
                    else => entry[1],
                },
                else => {},
            },
            else => {},
        };
        return null;
    }
};

fn isString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |array| array.child == u8,
                else => false,
            },
            .many, .c => p.child == u8 and p.sentinel() != null,
        },
        else => false,
    };
}
fn stringSlice(value: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(value)).pointer.size) {
        .slice, .one => value,
        .many, .c => std.mem.span(value),
    };
}

/// The D-Bus signature for a Zig type, computed at compile time.
pub fn signatureOf(comptime T: type) []const u8 {
    return comptime computeSignature(T);
}
fn computeSignature(comptime T: type) []const u8 {
    if (T == bool) return "b";
    if (T == u8) return "y";
    if (T == i16) return "n";
    if (T == u16) return "q";
    if (T == i32) return "i";
    if (T == u32) return "u";
    if (T == i64) return "x";
    if (T == u64) return "t";
    if (T == f64) return "d";
    if (T == ObjectPath) return "o";
    if (T == Signature) return "g";
    if (T == Bytes) return "ay";
    if (T == Fd) return "h";
    if (T == Value) return "v";
    if (isString(T)) return "s";
    switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice) return "a" ++ computeSignature(p.child),
        .@"struct" => |info| {
            if (@hasDecl(T, "dbus_dict")) {
                const entry = @typeInfo(T.Entry).@"struct".field_types;
                return "a{" ++ computeSignature(entry[0]) ++ computeSignature(entry[1]) ++ "}";
            }
            var result: []const u8 = "(";
            for (info.field_types) |field| result = result ++ computeSignature(field);
            return result ++ ")";
        },
        else => {},
    }
    @compileError("no D-Bus signature for " ++ @typeName(T));
}

/// The signature of a message body: the concatenated signatures of a tuple's fields.
pub fn bodySignature(comptime Args: type) []const u8 {
    return comptime blk: {
        var result: []const u8 = "";
        for (@typeInfo(Args).@"struct".field_types) |field| result = result ++ computeSignature(field);
        break :blk result;
    };
}

fn alignment(code: u8) usize {
    return switch (code) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 's', 'o', 'a', 'h' => 4,
        'x', 't', 'd', '(', '{' => 8,
        else => 1,
    };
}

/// Appends D-Bus-encoded data; positions are relative to the message start.
pub const Writer = struct {
    bytes: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    fds: std.ArrayList(i32) = .empty,

    /// Frees the buffers after zeroing them, since message bodies may carry secrets.
    pub fn deinit(self: *Writer) void {
        std.crypto.secureZero(u8, self.bytes.allocatedSlice());
        self.bytes.deinit(self.allocator);
        self.fds.deinit(self.allocator);
    }
    fn pad(self: *Writer, to: usize) !void {
        const target = std.mem.alignForward(usize, self.bytes.items.len, to);
        try self.bytes.appendNTimes(self.allocator, 0, target - self.bytes.items.len);
    }
    fn int(self: *Writer, comptime T: type, value: T) !void {
        try self.pad(@sizeOf(T));
        var raw: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &raw, value, .little);
        try self.bytes.appendSlice(self.allocator, &raw);
    }
    fn string(self: *Writer, value: []const u8) !void {
        if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidMessage;
        try self.int(u32, @intCast(value.len));
        try self.bytes.appendSlice(self.allocator, value);
        try self.bytes.append(self.allocator, 0);
    }
    fn signature(self: *Writer, value: []const u8) !void {
        if (value.len > 255) return error.InvalidMessage;
        try self.bytes.append(self.allocator, @intCast(value.len));
        try self.bytes.appendSlice(self.allocator, value);
        try self.bytes.append(self.allocator, 0);
    }
    /// Writes an array whose elements align to `element_align`, calling `body` for the contents.
    fn array(self: *Writer, element_align: usize, context: anytype, comptime body: fn (@TypeOf(context), *Writer) anyerror!void) !void {
        try self.pad(4);
        const length_at = self.bytes.items.len;
        try self.int(u32, 0);
        try self.pad(element_align);
        const start = self.bytes.items.len;
        try body(context, self);
        const length = self.bytes.items.len - start;
        if (length > 64 * 1024 * 1024) return error.InvalidMessage;
        std.mem.writeInt(u32, self.bytes.items[length_at..][0..4], @intCast(length), .little);
    }

    pub fn put(self: *Writer, value: anytype) anyerror!void {
        const T = @TypeOf(value);
        if (T == bool) return self.int(u32, @intFromBool(value));
        if (T == u8) return self.bytes.append(self.allocator, value);
        if (T == i16 or T == u16 or T == i32 or T == u32 or T == i64 or T == u64) return self.int(T, value);
        if (T == f64) return self.int(u64, @bitCast(value));
        if (T == ObjectPath) {
            if (!isObjectPath(value.value)) return error.InvalidMessage;
            return self.string(value.value);
        }
        if (T == Signature) return self.signature(value.value);
        if (T == Fd) {
            try self.int(u32, @intCast(self.fds.items.len));
            return self.fds.append(self.allocator, value.value);
        }
        // A Value fills a variant position: its own signature, then its contents.
        if (T == Value) return self.putValue(.{ .variant = &value });
        if (T == Bytes) return self.array(1, value.value, struct {
            fn body(bytes: []const u8, w: *Writer) anyerror!void {
                try w.bytes.appendSlice(w.allocator, bytes);
            }
        }.body);
        if (comptime isString(T)) return self.string(stringSlice(value));
        switch (@typeInfo(T)) {
            .pointer => |p| if (p.size == .slice) return self.array(alignment(signatureOf(p.child)[0]), value, struct {
                fn body(items: T, w: *Writer) anyerror!void {
                    for (items) |item| try w.put(item);
                }
            }.body),
            .@"struct" => |info| {
                if (@hasDecl(T, "dbus_dict")) return self.array(8, value.entries, struct {
                    fn body(entries: []const T.Entry, w: *Writer) anyerror!void {
                        for (entries) |entry| {
                            try w.pad(8);
                            try w.put(entry.key);
                            try w.put(entry.value);
                        }
                    }
                }.body);
                try self.pad(8);
                inline for (info.field_names) |name| try self.put(@field(value, name));
                return;
            },
            else => {},
        }
        @compileError("cannot encode " ++ @typeName(T));
    }
    fn putValue(self: *Writer, value: Value) anyerror!void {
        switch (value) {
            .byte => |v| try self.put(v),
            .boolean => |v| try self.put(v),
            .int16 => |v| try self.put(v),
            .uint16 => |v| try self.put(v),
            .int32 => |v| try self.put(v),
            .uint32 => |v| try self.put(v),
            .int64 => |v| try self.put(v),
            .uint64 => |v| try self.put(v),
            .double => |v| try self.put(v),
            .string => |v| try self.string(v),
            .object_path => |v| try self.put(ObjectPath{ .value = v }),
            .signature => |v| try self.signature(v),
            .fd => |v| try self.put(Fd{ .value = v }),
            .bytes => |v| try self.put(Bytes{ .value = v }),
            .array => |list| try self.array(alignment(if (list.element.len > 0) list.element[0] else 'y'), list.items, struct {
                fn body(items: []const Value, w: *Writer) anyerror!void {
                    for (items) |item| try w.putValue(item);
                }
            }.body),
            .structure => |fields| {
                try self.pad(8);
                for (fields) |field| try self.putValue(field);
            },
            .dict_entry => |entry| {
                try self.pad(8);
                try self.putValue(entry[0]);
                try self.putValue(entry[1]);
            },
            .variant => |inner| {
                var buffer: [256]u8 = undefined;
                try self.signature(try inner.signatureInto(&buffer));
                try self.putValue(inner.*);
            },
        }
    }
};

/// Decodes D-Bus data; strings and byte arrays point into the message.
pub const Reader = struct {
    bytes: []const u8,
    position: usize = 0,
    arena: std.mem.Allocator,
    fds: []const i32 = &.{},
    depth: u32 = 0,

    fn skipPadding(self: *Reader, to: usize) !void {
        const target = std.mem.alignForward(usize, self.position, to);
        if (target > self.bytes.len) return error.InvalidMessage;
        for (self.bytes[self.position..target]) |byte| if (byte != 0) return error.InvalidMessage;
        self.position = target;
    }
    fn int(self: *Reader, comptime T: type) !T {
        try self.skipPadding(@sizeOf(T));
        if (self.position + @sizeOf(T) > self.bytes.len) return error.InvalidMessage;
        defer self.position += @sizeOf(T);
        return std.mem.readInt(T, self.bytes[self.position..][0..@sizeOf(T)], .little);
    }
    fn string(self: *Reader) ![]const u8 {
        const len = try self.int(u32);
        if (self.position + len + 1 > self.bytes.len or self.bytes[self.position + len] != 0) return error.InvalidMessage;
        defer self.position += len + 1;
        const text = self.bytes[self.position..][0..len];
        if (std.mem.indexOfScalar(u8, text, 0) != null or !std.unicode.utf8ValidateSlice(text)) return error.InvalidMessage;
        return text;
    }
    fn signature(self: *Reader) ![]const u8 {
        if (self.position >= self.bytes.len) return error.InvalidMessage;
        const len = self.bytes[self.position];
        if (self.position + 1 + len + 1 > self.bytes.len or self.bytes[self.position + 1 + len] != 0) return error.InvalidMessage;
        defer self.position += 1 + len + 1;
        return self.bytes[self.position + 1 ..][0..len];
    }
    /// Returns the end offset of an array after skipping to its first element.
    fn arrayStart(self: *Reader, element_align: usize) !usize {
        const length = try self.int(u32);
        if (length > 64 * 1024 * 1024) return error.InvalidMessage;
        try self.skipPadding(element_align);
        const end = self.position + length;
        if (end > self.bytes.len) return error.InvalidMessage;
        return end;
    }

    pub fn get(self: *Reader, comptime T: type) anyerror!T {
        if (T == bool) {
            const raw = try self.int(u32);
            if (raw > 1) return error.InvalidMessage;
            return raw == 1;
        }
        if (T == u8) {
            if (self.position >= self.bytes.len) return error.InvalidMessage;
            defer self.position += 1;
            return self.bytes[self.position];
        }
        if (T == i16 or T == u16 or T == i32 or T == u32 or T == i64 or T == u64) return self.int(T);
        if (T == f64) return @bitCast(try self.int(u64));
        if (T == []const u8) return self.string();
        if (T == ObjectPath) return .{ .value = try self.string() };
        if (T == Signature) return .{ .value = try self.signature() };
        if (T == Fd) {
            const index = try self.int(u32);
            if (index >= self.fds.len) return error.InvalidMessage;
            return .{ .value = self.fds[index] };
        }
        if (T == Bytes) {
            const end = try self.arrayStart(1);
            defer self.position = end;
            return .{ .value = self.bytes[self.position..end] };
        }
        if (T == Value) {
            const code = try self.signature();
            return self.value(code);
        }
        switch (@typeInfo(T)) {
            .pointer => |p| if (p.size == .slice) {
                const end = try self.arrayStart(alignment(signatureOf(p.child)[0]));
                var items: std.ArrayList(p.child) = .empty;
                while (self.position < end) try items.append(self.arena, try self.get(p.child));
                if (self.position != end) return error.InvalidMessage;
                return items.items;
            },
            .@"struct" => |info| {
                if (@hasDecl(T, "dbus_dict")) {
                    const fields = @typeInfo(T.Entry).@"struct".field_types;
                    const end = try self.arrayStart(8);
                    var entries: std.ArrayList(T.Entry) = .empty;
                    while (self.position < end) {
                        try self.skipPadding(8);
                        const key = try self.get(fields[0]);
                        try entries.append(self.arena, .{ .key = key, .value = try self.get(fields[1]) });
                    }
                    if (self.position != end) return error.InvalidMessage;
                    return .{ .entries = entries.items };
                }
                try self.skipPadding(8);
                var result: T = undefined;
                inline for (info.field_names, info.field_types) |name, Field| @field(result, name) = try self.get(Field);
                return result;
            },
            else => {},
        }
        @compileError("cannot decode " ++ @typeName(T));
    }

    /// Decodes one complete type described by `code`.
    fn value(self: *Reader, code: []const u8) anyerror!Value {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > 64) return error.InvalidMessage;
        if (try completeType(code, 0) != code.len) return error.InvalidMessage;
        return switch (code[0]) {
            'y' => .{ .byte = try self.get(u8) },
            'b' => .{ .boolean = try self.get(bool) },
            'n' => .{ .int16 = try self.get(i16) },
            'q' => .{ .uint16 = try self.get(u16) },
            'i' => .{ .int32 = try self.get(i32) },
            'u' => .{ .uint32 = try self.get(u32) },
            'x' => .{ .int64 = try self.get(i64) },
            't' => .{ .uint64 = try self.get(u64) },
            'd' => .{ .double = try self.get(f64) },
            's' => .{ .string = try self.string() },
            'o' => .{ .object_path = try self.string() },
            'g' => .{ .signature = try self.signature() },
            'h' => .{ .fd = (try self.get(Fd)).value },
            'v' => blk: {
                const inner = try self.arena.create(Value);
                inner.* = try self.get(Value);
                break :blk .{ .variant = inner };
            },
            'a' => blk: {
                if (code.len == 2 and code[1] == 'y') break :blk .{ .bytes = (try self.get(Bytes)).value };
                const element = code[1..];
                const end = try self.arrayStart(alignment(element[0]));
                var items: std.ArrayList(Value) = .empty;
                while (self.position < end) try items.append(self.arena, try self.value(element));
                if (self.position != end) return error.InvalidMessage;
                break :blk .{ .array = .{ .element = element, .items = items.items } };
            },
            '(' => blk: {
                try self.skipPadding(8);
                var fields: std.ArrayList(Value) = .empty;
                var at: usize = 1;
                while (code[at] != ')') {
                    const next = try completeType(code, at);
                    try fields.append(self.arena, try self.value(code[at..next]));
                    at = next;
                }
                break :blk .{ .structure = fields.items };
            },
            '{' => blk: {
                try self.skipPadding(8);
                const key_end = try completeType(code, 1);
                const value_end = try completeType(code, key_end);
                const entry = try self.arena.create([2]Value);
                entry[0] = try self.value(code[1..key_end]);
                entry[1] = try self.value(code[key_end..value_end]);
                break :blk .{ .dict_entry = entry };
            },
            else => error.InvalidMessage,
        };
    }
};

/// Whether `path` is a valid object path: `/` or `/`-separated non-empty [A-Za-z0-9_] elements.
pub fn isObjectPath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    if (path.len == 1) return true;
    if (path[path.len - 1] == '/') return false;
    var previous: u8 = '/';
    for (path[1..]) |ch| {
        if (ch == '/') {
            if (previous == '/') return false;
        } else if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
        previous = ch;
    }
    return true;
}

test "object paths follow the D-Bus rules" {
    for ([_][]const u8{ "/", "/a", "/ca/desrt/dconf/Writer/user", "/a_b/C9" }) |valid| try std.testing.expect(isObjectPath(valid));
    for ([_][]const u8{ "", "a", "/a/", "//a", "/a//b", "/desktop-zig", "/a.b" }) |invalid| try std.testing.expect(!isObjectPath(invalid));
}

/// Whether `signature` is exactly one complete type, such as `a{sv}`.
pub fn isSingleType(signature: []const u8) bool {
    if (signature.len == 0 or signature.len > 255 or signature[0] == '{') return false;
    return (completeType(signature, 0) catch return false) == signature.len;
}

/// The end index of the single complete type starting at `start` in `code`.
fn completeType(code: []const u8, start: usize) !usize {
    if (start >= code.len) return error.InvalidMessage;
    switch (code[start]) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'h', 'v' => return start + 1,
        'a' => return completeType(code, start + 1),
        '(' => {
            var at = start + 1;
            while (at < code.len and code[at] != ')') at = try completeType(code, at);
            if (at >= code.len or at == start + 1) return error.InvalidMessage;
            return at + 1;
        },
        '{' => {
            const key = try completeType(code, start + 1);
            const item = try completeType(code, key);
            if (item >= code.len or code[item] != '}') return error.InvalidMessage;
            return item + 1;
        },
        else => return error.InvalidMessage,
    }
}

pub const Kind = enum(u8) { method_call = 1, method_return = 2, @"error" = 3, signal = 4, _ };
pub const no_reply_expected: u8 = 0x1;

/// A decoded message; slices point into its arena and stay valid during dispatch.
pub const Message = struct {
    kind: Kind,
    flags: u8 = 0,
    serial: u32 = 0,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    signature: []const u8 = "",
    body: []const u8 = "",
    fds: []const i32 = &.{},
    arena: std.mem.Allocator,

    /// Decodes the body as the tuple or struct `T`, whose fields must match the signature.
    pub fn read(self: *const Message, comptime T: type) !T {
        if (!std.mem.eql(u8, self.signature, bodySignature(T))) return error.UnexpectedSignature;
        var reader: Reader = .{ .bytes = self.body, .arena = self.arena, .fds = self.fds };
        var result: T = undefined;
        inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types) |name, Field| @field(result, name) = try reader.get(Field);
        if (reader.position != self.body.len) return error.InvalidMessage;
        return result;
    }
    /// Decodes every argument dynamically, whatever the signature.
    pub fn values(self: *const Message) ![]const Value {
        var reader: Reader = .{ .bytes = self.body, .arena = self.arena, .fds = self.fds };
        var result: std.ArrayList(Value) = .empty;
        var at: usize = 0;
        while (at < self.signature.len) {
            const next = try completeType(self.signature, at);
            try result.append(self.arena, try reader.value(self.signature[at..next]));
            at = next;
        }
        if (reader.position != self.body.len) return error.InvalidMessage;
        return result.items;
    }
    /// The first string argument, as error replies carry their description there.
    pub fn errorText(self: *const Message) []const u8 {
        if (!std.mem.startsWith(u8, self.signature, "s")) return "";
        var reader: Reader = .{ .bytes = self.body, .arena = self.arena };
        return reader.string() catch "";
    }
};

/// A message body whose arguments are only known at run time, encoded value by value.
pub const Body = struct { values: []const Value };
/// Encodes a complete message with `args` (a tuple) as its body.
pub fn encode(allocator: std.mem.Allocator, header: Message, args: anytype) !Writer {
    var body: Writer = .{ .allocator = allocator };
    defer body.deinit();
    const dynamic = @TypeOf(args) == Body;
    var signature_buffer: [256]u8 = undefined;
    var signature: []const u8 = undefined;
    if (dynamic) {
        var writer: std.Io.Writer = .fixed(&signature_buffer);
        for (args.values) |value| {
            value.writeSignature(&writer) catch return error.InvalidMessage;
            try body.putValue(value);
        }
        signature = writer.buffered();
    } else {
        inline for (@typeInfo(@TypeOf(args)).@"struct".field_names) |name| try body.put(@field(args, name));
        signature = comptime bodySignature(@TypeOf(args));
    }
    var message: Writer = .{ .allocator = allocator };
    errdefer message.deinit();
    try message.bytes.appendSlice(allocator, &.{ 'l', @intFromEnum(header.kind), header.flags, 1 });
    try message.int(u32, @intCast(body.bytes.items.len));
    try message.int(u32, header.serial);
    const Field = struct { code: u8, value: Value };
    var fields: [9]Field = undefined;
    var count: usize = 0;
    if (header.path) |v| {
        // The bus disconnects senders of invalid messages, so refuse them here.
        if (!isObjectPath(v)) return error.InvalidMessage;
        addField(&fields, &count, 1, .{ .object_path = v });
    }
    if (header.interface) |v| addField(&fields, &count, 2, .{ .string = v });
    if (header.member) |v| addField(&fields, &count, 3, .{ .string = v });
    if (header.error_name) |v| addField(&fields, &count, 4, .{ .string = v });
    if (header.reply_serial) |v| addField(&fields, &count, 5, .{ .uint32 = v });
    if (header.destination) |v| addField(&fields, &count, 6, .{ .string = v });
    if (signature.len > 0) addField(&fields, &count, 8, .{ .signature = signature });
    if (body.fds.items.len > 0) addField(&fields, &count, 9, .{ .uint32 = @intCast(body.fds.items.len) });
    try message.array(8, fields[0..count], struct {
        fn write(items: []const Field, w: *Writer) anyerror!void {
            for (items) |field| {
                try w.pad(8);
                try w.bytes.append(w.allocator, field.code);
                try w.putValue(.{ .variant = &field.value });
            }
        }
    }.write);
    try message.pad(8);
    try message.bytes.appendSlice(allocator, body.bytes.items);
    try message.fds.appendSlice(allocator, body.fds.items);
    return message;
}
fn addField(fields: anytype, count: *usize, code: u8, value: Value) void {
    fields[count.*] = .{ .code = code, .value = value };
    count.* += 1;
}

/// Parses one complete message. With `fds` null, descriptor accounting is skipped (header-only use).
pub fn parse(arena: std.mem.Allocator, bytes: []const u8, fds: ?[]const i32) !Message {
    if (bytes.len < 16 or bytes[0] != 'l' or bytes[3] != 1) return error.InvalidMessage;
    var reader: Reader = .{ .bytes = bytes, .position = 4, .arena = arena };
    const body_length = try reader.int(u32);
    var message: Message = .{ .kind = @enumFromInt(bytes[1]), .flags = bytes[2], .serial = try reader.int(u32), .arena = arena };
    const end = try reader.arrayStart(8);
    var unix_fds: u32 = 0;
    while (reader.position < end) {
        try reader.skipPadding(8);
        const code = try reader.get(u8);
        const field = try reader.get(Value);
        switch (code) {
            1 => message.path = switch (field) {
                .object_path => |v| v,
                else => return error.InvalidMessage,
            },
            2, 3, 4, 6, 7 => {
                const text = switch (field) {
                    .string => |v| v,
                    else => return error.InvalidMessage,
                };
                switch (code) {
                    2 => message.interface = text,
                    3 => message.member = text,
                    4 => message.error_name = text,
                    6 => message.destination = text,
                    else => message.sender = text,
                }
            },
            5 => message.reply_serial = switch (field) {
                .uint32 => |v| v,
                else => return error.InvalidMessage,
            },
            8 => message.signature = switch (field) {
                .signature => |v| v,
                else => return error.InvalidMessage,
            },
            9 => unix_fds = switch (field) {
                .uint32 => |v| v,
                else => return error.InvalidMessage,
            },
            else => {},
        }
    }
    try reader.skipPadding(8);
    if (reader.position + body_length != bytes.len) return error.InvalidMessage;
    message.body = bytes[reader.position..];
    if (fds) |available| {
        if (unix_fds > available.len) return error.InvalidMessage;
        message.fds = available[0..unix_fds];
    }
    return message;
}

/// The total length of the message starting at `bytes`, once its fixed header is available.
fn messageLength(bytes: []const u8) !?usize {
    if (bytes.len < 16) return null;
    if (bytes[0] != 'l') return error.InvalidMessage;
    const body: usize = std.mem.readInt(u32, bytes[4..8], .little);
    const fields: usize = std.mem.readInt(u32, bytes[12..16], .little);
    if (body > 128 * 1024 * 1024 or fields > 64 * 1024 * 1024) return error.InvalidMessage;
    return std.mem.alignForward(usize, 16 + fields, 8) + body;
}

/// The outcome of a method call, valid for the duration of the callback.
pub const Reply = union(enum) {
    ok: *const Message,
    /// A D-Bus error, or a local one such as a timeout or a closed connection.
    failed: struct { name: []const u8, text: []const u8 },
};
pub const ReplyHandler = *const fn (context: ?*anyopaque, reply: Reply) void;
pub const MessageHandler = *const fn (context: ?*anyopaque, message: *const Message) void;

const Pending = struct { serial: u32, deadline: i64, handler: ReplyHandler, context: ?*anyopaque };
const Subscription = struct { id: u32, handler: MessageHandler, context: ?*anyopaque, sender: ?[]u8, interface: ?[]u8, member: ?[]u8, path: ?[]u8, arg0: ?[]u8 = null, rule: []u8 };
/// A method call held for a later answer (see `Connection.hold`).
pub const Invocation = struct {
    serial: u32,
    flags: u8,
    sender: ?[]u8,

    fn message(self: *const Invocation) Message {
        return .{ .kind = .method_call, .serial = self.serial, .flags = self.flags, .sender = self.sender, .arena = undefined };
    }
    /// Frees the invocation without answering, e.g. when the connection is closing.
    pub fn release(self: *Invocation, allocator: std.mem.Allocator) void {
        if (self.sender) |sender| allocator.free(sender);
        self.sender = null;
    }
};

/// Reads a property for `Properties.Get`/`GetAll`; values may use `arena`. Null means unavailable.
pub const PropertyGetter = *const fn (context: ?*anyopaque, path: []const u8, interface: []const u8, property: []const u8, arena: std.mem.Allocator) ?Value;
/// Answers Properties.Set; returns null on success or the D-Bus error to reply with.
pub const PropertySetter = *const fn (context: ?*anyopaque, path: []const u8, interface: []const u8, property: []const u8, value: Value) ?Failure;
pub const Failure = struct { name: []const u8, text: []const u8 };
const Export = struct {
    id: u32,
    path: []u8,
    interface: []u8,
    handler: ?MessageHandler,
    context: ?*anyopaque,
    /// From introspection XML: enables argument checks, introspection and properties.
    info: ?*const InterfaceInfo = null,
    get: ?PropertyGetter = null,
    set: ?PropertySetter = null,
};
/// The current unique owner of a well-known name used as a signal sender filter.
/// Signals carry unique sender names, so filters on well-known names compare against the owner.
const NameWatch = struct {
    connection: *Connection,
    name: []u8,
    rule: []u8,
    owner: ?[]u8 = null,
    refs: u32 = 1,
    serial: u32 = 0,

    /// Records a new owner; an empty name means the name is no longer owned.
    fn setOwner(self: *NameWatch, value: []const u8) void {
        const allocator = self.connection.allocator;
        if (self.owner) |old| allocator.free(old);
        self.owner = if (value.len == 0) null else allocator.dupe(u8, value) catch null;
    }
};

/// Well-known names need owner tracking; unique names and the bus itself are literal.
fn isWellKnown(name: []const u8) bool {
    return name.len > 0 and name[0] != ':' and !std.mem.eql(u8, name, bus_name);
}

pub const Error = error{ ConnectionFailed, AuthenticationFailed, ConnectionClosed, InvalidMessage, IoFailed, OutOfMemory, Timeout };

fn monotonicMs() i64 {
    var now: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &now);
    return @as(i64, now.sec) * 1000 + @divTrunc(@as(i64, now.nsec), 1_000_000);
}

const bus_name = "org.freedesktop.DBus";
const bus_path = "/org/freedesktop/DBus";

pub const Connection = struct {
    allocator: std.mem.Allocator,
    fd: i32,
    unique_name: []u8 = &.{},
    serial: u32 = 0,
    out: std.ArrayList(u8) = .empty,
    out_fds: std.ArrayList(i32) = .empty,
    in: std.ArrayList(u8) = .empty,
    in_fds: std.ArrayList(i32) = .empty,
    pending: std.ArrayList(Pending) = .empty,
    subscriptions: std.ArrayList(Subscription) = .empty,
    exports: std.ArrayList(Export) = .empty,
    names: std.ArrayList(*NameWatch) = .empty,
    next_id: u32 = 0,
    closed: bool = false,
    dispatching: bool = false,
    /// Notified when the earliest timeout may have changed, so a loop can reschedule.
    on_schedule: ?*const fn (?*anyopaque) void = null,
    /// Notified when received messages wait in the buffer, e.g. after a blocking call.
    on_backlog: ?*const fn (?*anyopaque) void = null,
    schedule_context: ?*anyopaque = null,

    pub const Call = struct {
        destination: ?[]const u8 = null,
        path: []const u8,
        interface: ?[]const u8 = null,
        member: []const u8,
        /// Fail instead of asking the bus to start the destination service.
        no_auto_start: bool = false,
    };

    /// Connects to a message bus, authenticates and registers with Hello.
    pub fn open(allocator: std.mem.Allocator, bus: Bus) Error!*Connection {
        const variable: [*:0]const u8 = if (bus == .session) "DBUS_SESSION_BUS_ADDRESS" else "DBUS_SYSTEM_BUS_ADDRESS";
        const address = if (std.c.getenv(variable)) |value| std.mem.span(value) else if (bus == .system) "unix:path=/run/dbus/system_bus_socket" else return error.ConnectionFailed;
        return openBus(allocator, address);
    }

    /// Connects to the message bus at `address`, authenticates and registers with Hello.
    pub fn openBus(allocator: std.mem.Allocator, address: []const u8) Error!*Connection {
        const self = try openAddress(allocator, address);
        errdefer self.close();
        const hello = self.callBlocking(.{ .destination = bus_name, .path = bus_path, .interface = bus_name, .member = "Hello" }, .{}, 25000) catch |err| return switch (err) {
            error.CallFailed => error.ConnectionFailed,
            else => |other| other,
        };
        defer hello.deinit();
        const name = hello.message().read(struct { []const u8 }) catch return error.InvalidMessage;
        self.unique_name = try allocator.dupe(u8, name[0]);
        return self;
    }

    /// Connects and authenticates to `address` without registering on a bus.
    pub fn openAddress(allocator: std.mem.Allocator, address: []const u8) Error!*Connection {
        var entries = std.mem.splitScalar(u8, address, ';');
        while (entries.next()) |entry| {
            const fd = connectEntry(entry) catch continue;
            const self = allocator.create(Connection) catch {
                _ = std.c.close(fd);
                return error.OutOfMemory;
            };
            self.* = .{ .allocator = allocator, .fd = fd };
            self.authenticate() catch |err| {
                self.close();
                return err;
            };
            return self;
        }
        return error.ConnectionFailed;
    }

    /// Fails pending calls and frees the connection. Never call this from within its own dispatch.
    pub fn close(self: *Connection) void {
        std.debug.assert(!self.dispatching);
        self.closed = true;
        self.failAll("org.freedesktop.DBus.Error.Disconnected", "Connection closed");
        for (self.subscriptions.items) |item| self.freeSubscription(item);
        self.subscriptions.deinit(self.allocator);
        for (self.names.items) |watch| self.freeWatch(watch);
        self.names.deinit(self.allocator);
        for (self.exports.items) |item| {
            self.allocator.free(item.path);
            self.allocator.free(item.interface);
        }
        self.exports.deinit(self.allocator);
        for (self.in_fds.items) |fd| _ = std.c.close(fd);
        for (self.out_fds.items) |fd| _ = std.c.close(fd);
        // Sent and received bytes may include secrets such as passwords.
        std.crypto.secureZero(u8, self.in.allocatedSlice());
        std.crypto.secureZero(u8, self.out.allocatedSlice());
        self.pending.deinit(self.allocator);
        self.in.deinit(self.allocator);
        self.in_fds.deinit(self.allocator);
        self.out.deinit(self.allocator);
        self.out_fds.deinit(self.allocator);
        self.allocator.free(self.unique_name);
        _ = std.c.close(self.fd);
        self.allocator.destroy(self);
    }

    fn authenticate(self: *Connection) Error!void {
        var line: [128]u8 = undefined;
        // A NUL byte precedes authentication; the uid is sent as hex-encoded decimal digits.
        var digits: [16]u8 = undefined;
        const uid = std.fmt.bufPrint(&digits, "{d}", .{std.c.getuid()}) catch unreachable;
        var hex: [32]u8 = undefined;
        for (uid, 0..) |digit, i| _ = std.fmt.bufPrint(hex[i * 2 ..][0..2], "{x:0>2}", .{digit}) catch unreachable;
        const auth = std.fmt.bufPrint(&line, "\x00AUTH EXTERNAL {s}\r\n", .{hex[0 .. uid.len * 2]}) catch unreachable;
        try self.writeRaw(auth);
        if (!std.mem.startsWith(u8, try self.readLine(&line), "OK ")) return error.AuthenticationFailed;
        try self.writeRaw("NEGOTIATE_UNIX_FD\r\n");
        _ = try self.readLine(&line); // AGREE_UNIX_FD, or ERROR when descriptors cannot be passed.
        try self.writeRaw("BEGIN\r\n");
    }
    fn writeRaw(self: *Connection, bytes: []const u8) Error!void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = std.c.write(self.fd, bytes[offset..].ptr, bytes.len - offset);
            if (n < 0) {
                if (std.c._errno().* == 4) continue;
                return error.IoFailed;
            }
            offset += @intCast(n);
        }
    }
    /// Reads one CRLF line a byte at a time so no message bytes are consumed early.
    fn readLine(self: *Connection, buffer: []u8) Error![]const u8 {
        var len: usize = 0;
        while (len < buffer.len) {
            var byte: u8 = 0;
            const n = std.c.read(self.fd, @ptrCast(&byte), 1);
            if (n < 0 and std.c._errno().* == 4) continue;
            if (n <= 0) return error.ConnectionClosed;
            buffer[len] = byte;
            len += 1;
            if (len >= 2 and buffer[len - 2] == '\r' and byte == '\n') return buffer[0 .. len - 2];
        }
        return error.AuthenticationFailed;
    }

    pub fn getFd(self: *const Connection) i32 {
        return self.fd;
    }

    fn nextSerial(self: *Connection) u32 {
        self.serial +%= 1;
        if (self.serial == 0) self.serial = 1;
        return self.serial;
    }
    fn queue(self: *Connection, header: Message, args: anytype) Error!void {
        if (self.closed) return error.ConnectionClosed;
        var message = encode(self.allocator, header, args) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidMessage,
        };
        defer message.deinit();
        try self.out.appendSlice(self.allocator, message.bytes.items);
        for (message.fds.items) |fd| {
            const copy = std.c.fcntl(fd, std.c.F.DUPFD_CLOEXEC, @as(c_int, 0));
            if (copy < 0) return error.IoFailed;
            try self.out_fds.append(self.allocator, copy);
        }
    }
    fn callHeader(serial: u32, flags: u8, target: Call) Message {
        return .{ .kind = .method_call, .flags = flags | (if (target.no_auto_start) @as(u8, 0x2) else 0), .serial = serial, .destination = target.destination, .path = target.path, .interface = target.interface, .member = target.member, .arena = undefined };
    }

    /// Sends a method call; `handler` receives the reply or failure exactly once unless cancelled.
    pub fn call(self: *Connection, target: Call, args: anytype, timeout_ms: u32, handler: ReplyHandler, context: ?*anyopaque) Error!u32 {
        const serial = self.nextSerial();
        try self.queue(callHeader(serial, 0, target), args);
        try self.pending.append(self.allocator, .{ .serial = serial, .deadline = monotonicMs() + timeout_ms, .handler = handler, .context = context });
        self.flush() catch {};
        if (self.on_schedule) |notify| notify(self.schedule_context);
        return serial;
    }
    /// Sends a method call whose reply is not wanted.
    pub fn send(self: *Connection, target: Call, args: anytype) Error!void {
        try self.queue(callHeader(self.nextSerial(), no_reply_expected, target), args);
        try self.flush();
    }
    /// Forgets a pending call; its handler will not run.
    pub fn cancel(self: *Connection, serial: u32) void {
        for (self.pending.items, 0..) |item, i| if (item.serial == serial) {
            _ = self.pending.orderedRemove(i);
            return;
        };
    }
    pub fn emit(self: *Connection, path: []const u8, interface: []const u8, member: []const u8, args: anytype) Error!void {
        return self.emitTo(null, path, interface, member, args);
    }
    /// Emits a signal; with a destination it is unicast to that connection only.
    pub fn emitTo(self: *Connection, destination: ?[]const u8, path: []const u8, interface: []const u8, member: []const u8, args: anytype) Error!void {
        try self.queue(.{ .kind = .signal, .serial = self.nextSerial(), .destination = destination, .path = path, .interface = interface, .member = member, .arena = undefined }, args);
        try self.flush();
    }
    /// Replies to a method call received through `register`.
    pub fn reply(self: *Connection, to: *const Message, args: anytype) Error!void {
        if (to.flags & no_reply_expected != 0) return;
        try self.queue(.{ .kind = .method_return, .serial = self.nextSerial(), .reply_serial = to.serial, .destination = to.sender, .arena = undefined }, args);
        try self.flush();
    }
    pub fn replyError(self: *Connection, to: *const Message, name: []const u8, text: []const u8) Error!void {
        if (to.flags & no_reply_expected != 0) return;
        try self.queue(.{ .kind = .@"error", .serial = self.nextSerial(), .reply_serial = to.serial, .destination = to.sender, .error_name = name, .arena = undefined }, .{text});
        try self.flush();
    }

    /// Receives matching signals; null filters match anything. Adds a bus match rule.
    pub fn subscribe(self: *Connection, sender: ?[]const u8, interface: ?[]const u8, member: ?[]const u8, path: ?[]const u8, handler: MessageHandler, context: ?*anyopaque) Error!u32 {
        return self.subscribeArg0(sender, interface, member, path, null, handler, context);
    }
    /// Like `subscribe`, also requiring the first argument to be the string `arg0`.
    pub fn subscribeArg0(self: *Connection, sender: ?[]const u8, interface: ?[]const u8, member: ?[]const u8, path: ?[]const u8, arg0: ?[]const u8, handler: MessageHandler, context: ?*anyopaque) Error!u32 {
        var rule: std.Io.Writer.Allocating = .init(self.allocator);
        defer rule.deinit();
        rule.writer.writeAll("type='signal'") catch return error.OutOfMemory;
        inline for (.{ .{ "sender", sender }, .{ "interface", interface }, .{ "member", member }, .{ "path", path }, .{ "arg0", arg0 } }) |pair| {
            if (pair[1]) |value| rule.writer.print(",{s}='{s}'", .{ pair[0], value }) catch return error.OutOfMemory;
        }
        self.next_id += 1;
        var item: Subscription = .{ .id = self.next_id, .handler = handler, .context = context, .sender = null, .interface = null, .member = null, .path = null, .rule = &.{} };
        errdefer self.freeSubscription(item);
        if (sender) |v| item.sender = try self.allocator.dupe(u8, v);
        if (interface) |v| item.interface = try self.allocator.dupe(u8, v);
        if (member) |v| item.member = try self.allocator.dupe(u8, v);
        if (path) |v| item.path = try self.allocator.dupe(u8, v);
        if (arg0) |v| item.arg0 = try self.allocator.dupe(u8, v);
        item.rule = try rule.toOwnedSlice();
        if (sender) |name| if (isWellKnown(name)) try self.watchName(name);
        errdefer if (sender) |name| if (isWellKnown(name)) self.unwatchName(name);
        try self.subscriptions.append(self.allocator, item);
        if (self.unique_name.len > 0) try self.send(.{ .destination = bus_name, .path = bus_path, .interface = bus_name, .member = "AddMatch" }, .{item.rule});
        return item.id;
    }
    pub fn unsubscribe(self: *Connection, id: u32) void {
        for (self.subscriptions.items, 0..) |item, i| if (item.id == id) {
            if (self.unique_name.len > 0) self.send(.{ .destination = bus_name, .path = bus_path, .interface = bus_name, .member = "RemoveMatch" }, .{item.rule}) catch {};
            if (item.sender) |name| if (isWellKnown(name)) self.unwatchName(name);
            self.freeSubscription(item);
            _ = self.subscriptions.orderedRemove(i);
            return;
        };
    }
    fn freeSubscription(self: *Connection, item: Subscription) void {
        inline for (.{ item.sender, item.interface, item.member, item.path, item.arg0 }) |value| if (value) |owned| self.allocator.free(owned);
        self.allocator.free(item.rule);
    }

    /// Starts tracking the owner of `name`: a match rule for its NameOwnerChanged and a GetNameOwner query.
    fn watchName(self: *Connection, name: []const u8) Error!void {
        for (self.names.items) |watch| if (std.mem.eql(u8, watch.name, name)) {
            watch.refs += 1;
            return;
        };
        const watch = try self.allocator.create(NameWatch);
        errdefer self.allocator.destroy(watch);
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        const rule = std.fmt.allocPrint(self.allocator, "type='signal',sender='" ++ bus_name ++ "',interface='" ++ bus_name ++ "',member='NameOwnerChanged',path='" ++ bus_path ++ "',arg0='{s}'", .{name}) catch return error.OutOfMemory;
        errdefer self.allocator.free(rule);
        watch.* = .{ .connection = self, .name = owned, .rule = rule };
        try self.names.append(self.allocator, watch);
        if (self.unique_name.len == 0) return;
        self.send(.{ .destination = bus_name, .path = bus_path, .interface = bus_name, .member = "AddMatch" }, .{rule}) catch {};
        watch.serial = self.call(.{ .destination = bus_name, .path = bus_path, .interface = bus_name, .member = "GetNameOwner" }, .{name}, 25000, &ownerReply, watch) catch 0;
    }
    fn unwatchName(self: *Connection, name: []const u8) void {
        for (self.names.items, 0..) |watch, i| if (std.mem.eql(u8, watch.name, name)) {
            watch.refs -= 1;
            if (watch.refs > 0) return;
            if (watch.serial != 0) self.cancel(watch.serial);
            if (self.unique_name.len > 0) self.send(.{ .destination = bus_name, .path = bus_path, .interface = bus_name, .member = "RemoveMatch" }, .{watch.rule}) catch {};
            _ = self.names.orderedRemove(i);
            self.freeWatch(watch);
            return;
        };
    }
    fn freeWatch(self: *Connection, watch: *NameWatch) void {
        if (watch.owner) |owner| self.allocator.free(owner);
        self.allocator.free(watch.name);
        self.allocator.free(watch.rule);
        self.allocator.destroy(watch);
    }
    fn ownerReply(context: ?*anyopaque, result: Reply) void {
        const watch: *NameWatch = @ptrCast(@alignCast(context));
        watch.serial = 0;
        // NameHasNoOwner leaves the name unowned until NameOwnerChanged says otherwise.
        const message = switch (result) {
            .ok => |value| value,
            .failed => return,
        };
        const owner = message.read(struct { []const u8 }) catch return;
        watch.setOwner(owner[0]);
    }
    /// The unique name currently owning `name`, if it is being watched and owned.
    pub fn ownerOf(self: *const Connection, name: []const u8) ?[]const u8 {
        for (self.names.items) |watch| if (std.mem.eql(u8, watch.name, name)) return watch.owner;
        return null;
    }
    fn senderMatches(self: *const Connection, filter: ?[]const u8, sender: ?[]const u8) bool {
        const expected = filter orelse return true;
        const actual = sender orelse return false;
        if (!isWellKnown(expected)) return std.mem.eql(u8, expected, actual);
        const owner = self.ownerOf(expected) orelse return false;
        return std.mem.eql(u8, owner, actual);
    }

    /// Routes method calls for `interface` at `path` to `handler`, which must reply.
    pub fn register(self: *Connection, path: []const u8, interface: []const u8, handler: MessageHandler, context: ?*anyopaque) Error!u32 {
        self.next_id += 1;
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        const owned_interface = try self.allocator.dupe(u8, interface);
        errdefer self.allocator.free(owned_interface);
        try self.exports.append(self.allocator, .{ .id = self.next_id, .path = owned_path, .interface = owned_interface, .handler = handler, .context = context });
        return self.next_id;
    }
    /// Exports `info` at `path`: calls are checked against its method signatures before
    /// reaching `handler`, and introspection and properties (through `get`) are answered here.
    /// `info` must outlive the export.
    pub fn exportObject(self: *Connection, path: []const u8, info: *const InterfaceInfo, handler: ?MessageHandler, get: ?PropertyGetter, context: ?*anyopaque) Error!u32 {
        return self.exportWritable(path, info, handler, get, null, context);
    }
    /// Like `exportObject`, with `set` answering Properties.Set for writable properties.
    pub fn exportWritable(self: *Connection, path: []const u8, info: *const InterfaceInfo, handler: ?MessageHandler, get: ?PropertyGetter, set: ?PropertySetter, context: ?*anyopaque) Error!u32 {
        const id = try self.register(path, info.name, handler orelse &ignoreCall, context);
        const item = &self.exports.items[self.exports.items.len - 1];
        item.info = info;
        item.get = get;
        item.set = set;
        if (handler == null) item.handler = null;
        return id;
    }
    fn ignoreCall(_: ?*anyopaque, _: *const Message) void {}

    /// Keeps what is needed to answer `message` after its handler returns.
    pub fn hold(self: *Connection, message: *const Message) Error!Invocation {
        return .{ .serial = message.serial, .flags = message.flags, .sender = if (message.sender) |sender| try self.allocator.dupe(u8, sender) else null };
    }
    /// Answers a held call and releases it.
    pub fn answer(self: *Connection, invocation: *Invocation, args: anytype) Error!void {
        defer invocation.release(self.allocator);
        return self.reply(&invocation.message(), args);
    }
    pub fn answerError(self: *Connection, invocation: *Invocation, name: []const u8, text: []const u8) Error!void {
        defer invocation.release(self.allocator);
        return self.replyError(&invocation.message(), name, text);
    }

    /// Requests a well-known name and waits for the bus; returns RequestName's reply code (1 = primary owner).
    pub fn requestName(self: *Connection, name: []const u8, flags: u32) (Error || error{CallFailed})!u32 {
        const result = try self.callBlocking(.{ .destination = bus_name, .path = bus_path, .interface = bus_name, .member = "RequestName" }, .{ name, flags }, 25000);
        defer result.deinit();
        const code = result.message().read(struct { u32 }) catch return error.InvalidMessage;
        return code[0];
    }

    /// Emits PropertiesChanged with the current value of every readable property of an export.
    pub fn emitPropertiesChanged(self: *Connection, path: []const u8, interface: []const u8) Error!void {
        const item = self.findExport(path, interface) orelse return;
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const values = try self.collectProperties(item, arena.allocator());
        try self.emit(path, "org.freedesktop.DBus.Properties", "PropertiesChanged", .{ interface, values, @as([]const []const u8, &.{}) });
    }
    fn findExport(self: *Connection, path: []const u8, interface: []const u8) ?*const Export {
        for (self.exports.items) |*item| {
            if (std.mem.eql(u8, item.path, path) and std.mem.eql(u8, item.interface, interface)) return item;
        }
        return null;
    }
    fn collectProperties(self: *Connection, item: *const Export, arena: std.mem.Allocator) Error!Dict([]const u8, Value) {
        _ = self;
        const info = item.info orelse return .{ .entries = &.{} };
        const get = item.get orelse return .{ .entries = &.{} };
        var entries: std.ArrayList(Dict([]const u8, Value).Entry) = .empty;
        for (info.properties) |property| {
            if (!property.readable) continue;
            const value = get(item.context, item.path, item.interface, property.name, arena) orelse continue;
            try entries.append(arena, .{ .key = property.name, .value = value });
        }
        return .{ .entries = entries.items };
    }
    pub fn unregister(self: *Connection, id: u32) void {
        for (self.exports.items, 0..) |item, i| if (item.id == id) {
            self.allocator.free(item.path);
            self.allocator.free(item.interface);
            _ = self.exports.orderedRemove(i);
            return;
        };
    }

    /// Sends buffered messages, blocking until the socket accepts them.
    pub fn flush(self: *Connection) Error!void {
        while (self.out.items.len > 0) {
            var iov = [_]std.posix.iovec_const{.{ .base = self.out.items.ptr, .len = self.out.items.len }};
            var control: [16 + 4 * 64]u8 align(8) = @splat(0);
            var header: std.c.msghdr_const = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
            const fd_count = @min(self.out_fds.items.len, 64);
            if (fd_count > 0) {
                std.mem.writeInt(usize, control[0..8], 16 + fd_count * 4, .little);
                std.mem.writeInt(i32, control[8..12], 1, .little); // SOL_SOCKET
                std.mem.writeInt(i32, control[12..16], 1, .little); // SCM_RIGHTS
                for (self.out_fds.items[0..fd_count], 0..) |fd, i| std.mem.writeInt(i32, control[16 + i * 4 ..][0..4], fd, .little);
                header.control = &control;
                header.controllen = std.mem.alignForward(usize, 16 + fd_count * 4, 8);
            }
            const sent = std.c.sendmsg(self.fd, &header, 0x4000); // MSG_NOSIGNAL
            if (sent < 0) {
                if (std.c._errno().* == 4) continue;
                self.closed = true;
                return error.IoFailed;
            }
            for (self.out_fds.items[0..fd_count]) |fd| _ = std.c.close(fd);
            std.mem.copyForwards(i32, self.out_fds.items[0 .. self.out_fds.items.len - fd_count], self.out_fds.items[fd_count..]);
            self.out_fds.items.len -= fd_count;
            const count: usize = @intCast(sent);
            std.mem.copyForwards(u8, self.out.items[0 .. self.out.items.len - count], self.out.items[count..]);
            self.out.items.len -= count;
        }
    }

    /// Reads available bytes without blocking; returns whether any arrived.
    fn read(self: *Connection) Error!bool {
        if (self.closed) return error.ConnectionClosed;
        try self.in.ensureUnusedCapacity(self.allocator, 64 * 1024);
        const space = self.in.unusedCapacitySlice();
        var iov = [_]std.posix.iovec{.{ .base = space.ptr, .len = space.len }};
        var control: [16 + 4 * 64]u8 align(8) = undefined;
        var header: std.c.msghdr = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &control, .controllen = control.len, .flags = 0 };
        const received = while (true) {
            const n = std.c.recvmsg(self.fd, &header, 0x40000000 | 0x40); // MSG_CMSG_CLOEXEC | MSG_DONTWAIT
            if (n >= 0) break n;
            switch (std.c._errno().*) {
                4 => continue,
                11 => return false,
                else => {
                    self.closed = true;
                    return error.IoFailed;
                },
            }
        };
        var offset: usize = 0;
        while (offset + 16 <= header.controllen) {
            const len = std.mem.readInt(usize, control[offset..][0..8], .little);
            if (len < 16 or offset + len > header.controllen) break;
            if (std.mem.readInt(i32, control[offset + 8 ..][0..4], .little) == 1 and std.mem.readInt(i32, control[offset + 12 ..][0..4], .little) == 1) {
                var at = offset + 16;
                while (at + 4 <= offset + len) : (at += 4) try self.in_fds.append(self.allocator, std.mem.readInt(i32, control[at..][0..4], .little));
            }
            offset += std.mem.alignForward(usize, len, 8);
        }
        if (received == 0) {
            self.closed = true;
            return error.ConnectionClosed;
        }
        self.in.items.len += @intCast(received);
        return true;
    }

    /// A received message together with the arena that owns its contents.
    pub const Owned = struct {
        arena: *std.heap.ArenaAllocator,
        value: Message,
        pub fn message(self: *const Owned) *const Message {
            return &self.value;
        }
        /// Closes the message's descriptors too: like a GUnixFDList, keepers must dup what they keep.
        pub fn deinit(self: *const Owned) void {
            for (self.value.fds) |fd| _ = std.c.close(fd);
            const child = self.arena.child_allocator;
            self.arena.deinit();
            child.destroy(self.arena);
        }
    };

    /// Takes the complete message at `offset` in the receive buffer, if there is one.
    fn take(self: *Connection, offset: usize) Error!?Owned {
        const rest = self.in.items[offset..];
        const length = (messageLength(rest) catch return error.InvalidMessage) orelse return null;
        if (rest.len < length) return null;
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        arena.* = .init(self.allocator);
        errdefer {
            arena.deinit();
            self.allocator.destroy(arena);
        }
        const bytes = try arena.allocator().dupe(u8, rest[0..length]);
        std.mem.copyForwards(u8, self.in.items[offset .. self.in.items.len - length], self.in.items[offset + length ..]);
        self.in.items.len -= length;
        // Descriptors are queued in arrival order and consumed by the messages that declare them.
        const fds = try arena.allocator().dupe(i32, self.in_fds.items);
        const value = parse(arena.allocator(), bytes, fds) catch return error.InvalidMessage;
        const used = value.fds.len;
        std.mem.copyForwards(i32, self.in_fds.items[0 .. self.in_fds.items.len - used], self.in_fds.items[used..]);
        self.in_fds.items.len -= used;
        return .{ .arena = arena, .value = value };
    }

    /// Calls and waits for the reply, leaving other messages for later dispatch.
    /// A D-Bus error reply becomes `error.CallFailed`; use `call` to see its details.
    pub fn callBlocking(self: *Connection, target: Call, args: anytype, timeout_ms: u32) (Error || error{CallFailed})!Owned {
        const result = try self.callBlockingRaw(target, args, timeout_ms);
        if (result.value.kind == .@"error") {
            result.deinit();
            return error.CallFailed;
        }
        return result;
    }
    /// Like `callBlocking`, but returns error replies too, for callers that report their details.
    pub fn callBlockingRaw(self: *Connection, target: Call, args: anytype, timeout_ms: u32) Error!Owned {
        // Messages read while waiting stay buffered; an event loop must be told to dispatch them,
        // because the socket will not become readable for data already received.
        defer if (self.in.items.len > 0) if (self.on_backlog) |notify| notify(self.schedule_context);
        const serial = self.nextSerial();
        try self.queue(callHeader(serial, 0, target), args);
        try self.flush();
        const deadline = monotonicMs() + timeout_ms;
        var scanned: usize = 0;
        while (true) {
            while (true) {
                const rest = self.in.items[scanned..];
                const length = (messageLength(rest) catch return error.InvalidMessage) orelse break;
                if (rest.len < length) break;
                if (try isReplyTo(self.allocator, rest[0..length], serial)) {
                    const owned = (try self.take(scanned)).?;
                    return owned;
                }
                scanned += length;
            }
            const remaining = deadline - monotonicMs();
            if (remaining <= 0) return error.Timeout;
            var poll = [_]std.c.pollfd{.{ .fd = self.fd, .events = std.c.POLL.IN, .revents = 0 }};
            if (std.c.poll(&poll, 1, @intCast(remaining)) < 0 and std.c._errno().* != 4) return error.IoFailed;
            _ = try self.read();
        }
    }

    /// Reads without blocking and dispatches every complete message.
    pub fn readAndDispatch(self: *Connection) Error!void {
        while (try self.read()) {}
        try self.dispatchPending();
    }
    pub fn dispatchPending(self: *Connection) Error!void {
        if (self.dispatching) return;
        self.dispatching = true;
        defer self.dispatching = false;
        while (try self.take(0)) |owned| {
            defer owned.deinit();
            self.deliver(owned.message());
        }
        try self.flush();
    }

    fn deliver(self: *Connection, message: *const Message) void {
        switch (message.kind) {
            .method_return, .@"error" => {
                const serial = message.reply_serial orelse return;
                for (self.pending.items, 0..) |item, i| if (item.serial == serial) {
                    _ = self.pending.orderedRemove(i);
                    if (message.kind == .method_return) {
                        item.handler(item.context, .{ .ok = message });
                    } else item.handler(item.context, .{ .failed = .{ .name = message.error_name orelse "org.freedesktop.DBus.Error.Failed", .text = message.errorText() } });
                    if (self.on_schedule) |notify| notify(self.schedule_context);
                    return;
                };
            },
            .signal => {
                self.trackOwner(message);
                // Collect matches first: handlers may subscribe or unsubscribe while running.
                var ids: [64]u32 = undefined;
                var count: usize = 0;
                for (self.subscriptions.items) |item| {
                    if (count == ids.len) break;
                    if (!self.senderMatches(item.sender, message.sender) or !matches(item.interface, message.interface) or !matches(item.member, message.member) or !matches(item.path, message.path) or !matches(item.arg0, firstString(message))) continue;
                    ids[count] = item.id;
                    count += 1;
                }
                for (ids[0..count]) |id| for (self.subscriptions.items) |item| if (item.id == id) {
                    item.handler(item.context, message);
                    break;
                };
            },
            .method_call => self.handleCall(message),
            _ => {},
        }
    }
    /// Applies NameOwnerChanged from the bus to watched names.
    fn trackOwner(self: *Connection, message: *const Message) void {
        if (!matches(bus_name, message.sender) or !matches(bus_name, message.interface) or !matches("NameOwnerChanged", message.member)) return;
        const change = message.read(struct { []const u8, []const u8, []const u8 }) catch return;
        for (self.names.items) |watch| if (std.mem.eql(u8, watch.name, change[0])) watch.setOwner(change[2]);
    }
    fn matches(filter: ?[]const u8, value: ?[]const u8) bool {
        const expected = filter orelse return true;
        return value != null and std.mem.eql(u8, expected, value.?);
    }
    fn handleCall(self: *Connection, message: *const Message) void {
        self.routeCall(message) catch |err| switch (err) {
            error.OutOfMemory => self.replyError(message, "org.freedesktop.DBus.Error.NoMemory", "Out of memory") catch {},
            else => {},
        };
    }
    fn routeCall(self: *Connection, message: *const Message) Error!void {
        const path = message.path orelse "";
        const member = message.member orelse "";
        const interface = message.interface;
        if (interface) |name| {
            if (std.mem.eql(u8, name, "org.freedesktop.DBus.Peer") and std.mem.eql(u8, member, "Ping")) return self.reply(message, .{});
            if (std.mem.eql(u8, name, "org.freedesktop.DBus.Introspectable") and std.mem.eql(u8, member, "Introspect")) return self.introspect(message, path);
            if (std.mem.eql(u8, name, "org.freedesktop.DBus.Properties")) return self.properties(message, path, member);
        }
        for (self.exports.items) |*item| {
            if (!std.mem.eql(u8, item.path, path)) continue;
            if (interface) |name| if (!std.mem.eql(u8, name, item.interface)) continue;
            if (item.info) |info| {
                const method = info.method(member) orelse {
                    // Without an interface, another export at this path may have the method.
                    if (interface == null) continue;
                    return self.replyErrorFormat(message, "org.freedesktop.DBus.Error.UnknownMethod", "No such method “{s}”", .{member});
                };
                if (!std.mem.eql(u8, message.signature, method.in)) return self.replyErrorFormat(message, "org.freedesktop.DBus.Error.InvalidArgs", "Type of message, “({s})”, does not match expected type “({s})”", .{ message.signature, method.in });
            }
            const handler = item.handler orelse return self.replyError(message, "org.freedesktop.DBus.Error.UnknownMethod", "No such method");
            handler(item.context, message);
            return;
        }
        // Like GDBus, an unknown path is reported the same way as an unknown interface,
        // so clients written against GDBus services see the same error.
        return self.replyErrorFormat(message, "org.freedesktop.DBus.Error.UnknownMethod", "No such interface “{s}” on object at path {s}", .{ interface orelse "", path });
    }
    fn replyErrorFormat(self: *Connection, to: *const Message, name: []const u8, comptime format: []const u8, args: anytype) Error!void {
        var buffer: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, format, args) catch buffer[0..];
        return self.replyError(to, name, text);
    }

    fn properties(self: *Connection, message: *const Message, path: []const u8, member: []const u8) Error!void {
        const invalid = "org.freedesktop.DBus.Error.InvalidArgs";
        if (std.mem.eql(u8, member, "GetAll")) {
            const args = message.read(struct { []const u8 }) catch return self.replyError(message, invalid, "Expected (s)");
            const item = self.findExport(path, args[0]) orelse return self.replyErrorFormat(message, invalid, "No such interface “{s}”", .{args[0]});
            return self.reply(message, .{try self.collectProperties(item, message.arena)});
        }
        if (std.mem.eql(u8, member, "Get")) {
            const args = message.read(struct { []const u8, []const u8 }) catch return self.replyError(message, invalid, "Expected (ss)");
            const item = self.findExport(path, args[0]) orelse return self.replyErrorFormat(message, invalid, "No such interface “{s}”", .{args[0]});
            const info = item.info orelse return self.replyErrorFormat(message, invalid, "No such property “{s}”", .{args[1]});
            const property = info.property(args[1]) orelse return self.replyErrorFormat(message, invalid, "No such property “{s}”", .{args[1]});
            if (!property.readable) return self.replyErrorFormat(message, invalid, "Property “{s}” is not readable", .{args[1]});
            const get = item.get orelse return self.replyError(message, "org.freedesktop.DBus.Error.Failed", "Property unavailable");
            const value = get(item.context, item.path, item.interface, property.name, message.arena) orelse return self.replyError(message, "org.freedesktop.DBus.Error.Failed", "Property unavailable");
            return self.reply(message, .{value});
        }
        if (std.mem.eql(u8, member, "Set")) {
            const args = message.read(struct { []const u8, []const u8, Value }) catch return self.replyError(message, invalid, "Expected (ssv)");
            const item = self.findExport(path, args[0]) orelse return self.replyErrorFormat(message, invalid, "No such interface “{s}”", .{args[0]});
            const info = item.info orelse return self.replyErrorFormat(message, invalid, "No such property “{s}”", .{args[1]});
            const property = info.property(args[1]) orelse return self.replyErrorFormat(message, invalid, "No such property “{s}”", .{args[1]});
            const set = item.set orelse return self.replyError(message, "org.freedesktop.DBus.Error.PropertyReadOnly", "Properties are read-only");
            if (!property.writable) return self.replyErrorFormat(message, "org.freedesktop.DBus.Error.PropertyReadOnly", "Property “{s}” is not writable", .{args[1]});
            var buffer: [256]u8 = undefined;
            const signature = args[2].signatureInto(&buffer) catch "";
            if (!std.mem.eql(u8, signature, property.signature)) return self.replyErrorFormat(message, invalid, "Property “{s}” has type “{s}”", .{ property.name, property.signature });
            if (set(item.context, item.path, item.interface, property.name, args[2])) |failure| return self.replyError(message, failure.name, failure.text);
            return self.reply(message, .{});
        }
        return self.replyErrorFormat(message, "org.freedesktop.DBus.Error.UnknownMethod", "No such method “{s}”", .{member});
    }

    /// Describes the interfaces exported at `path` and its immediate children.
    fn introspect(self: *Connection, message: *const Message, path: []const u8) Error!void {
        var xml: std.Io.Writer.Allocating = .init(message.arena);
        const w = &xml.writer;
        w.writeAll(introspection_header) catch return error.OutOfMemory;
        var found = false;
        for (self.exports.items) |item| {
            if (!std.mem.eql(u8, item.path, path)) continue;
            found = true;
            if (item.info) |info| {
                w.print("  {s}\n", .{info.xml}) catch return error.OutOfMemory;
            } else w.print("  <interface name=\"{s}\"/>\n", .{item.interface}) catch return error.OutOfMemory;
        }
        if (found) w.writeAll(standard_interfaces) catch return error.OutOfMemory;
        // Child nodes, each named once.
        const prefix_len = if (std.mem.eql(u8, path, "/")) 1 else path.len + 1;
        var children: std.ArrayList([]const u8) = .empty;
        for (self.exports.items) |item| {
            if (item.path.len <= prefix_len or !std.mem.startsWith(u8, item.path, path)) continue;
            if (!std.mem.eql(u8, path, "/") and item.path[path.len] != '/') continue;
            const rest = item.path[prefix_len..];
            const child = rest[0 .. std.mem.indexOfScalar(u8, rest, '/') orelse rest.len];
            for (children.items) |seen| {
                if (std.mem.eql(u8, seen, child)) break;
            } else {
                try children.append(message.arena, child);
                w.print("  <node name=\"{s}\"/>\n", .{child}) catch return error.OutOfMemory;
            }
        }
        w.writeAll("</node>\n") catch return error.OutOfMemory;
        return self.reply(message, .{xml.written()});
    }

    /// Fails calls whose timeout has passed; returns milliseconds until the next deadline, if any.
    pub fn expire(self: *Connection) ?i64 {
        const now = monotonicMs();
        var index: usize = 0;
        while (index < self.pending.items.len) {
            const item = self.pending.items[index];
            if (item.deadline > now) {
                index += 1;
                continue;
            }
            _ = self.pending.orderedRemove(index);
            item.handler(item.context, .{ .failed = .{ .name = "org.freedesktop.DBus.Error.Timeout", .text = "Timeout was reached" } });
            index = 0;
        }
        var earliest: ?i64 = null;
        for (self.pending.items) |item| earliest = if (earliest) |value| @min(value, item.deadline) else item.deadline;
        return if (earliest) |value| @max(0, value - now) else null;
    }

    /// Milliseconds until the earliest pending call times out, without running handlers.
    pub fn nextTimeout(self: *const Connection) ?i64 {
        var earliest: ?i64 = null;
        for (self.pending.items) |item| earliest = if (earliest) |value| @min(value, item.deadline) else item.deadline;
        return if (earliest) |value| @max(0, value - monotonicMs()) else null;
    }

    /// Marks the connection broken and fails every pending call, without freeing it.
    pub fn disconnect(self: *Connection) void {
        self.closed = true;
        self.failAll("org.freedesktop.DBus.Error.Disconnected", "Connection closed");
    }

    fn failAll(self: *Connection, name: []const u8, text: []const u8) void {
        while (self.pending.pop()) |item| item.handler(item.context, .{ .failed = .{ .name = name, .text = text } });
    }
};

/// The first body argument when it is a string or object path, for arg0 matching.
fn firstString(message: *const Message) ?[]const u8 {
    if (message.signature.len == 0 or (message.signature[0] != 's' and message.signature[0] != 'o')) return null;
    var reader: Reader = .{ .bytes = message.body, .arena = message.arena };
    return reader.string() catch null;
}

fn isReplyTo(allocator: std.mem.Allocator, bytes: []const u8, serial: u32) !bool {
    if (bytes[1] != 2 and bytes[1] != 3) return false;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const message = parse(arena.allocator(), bytes, null) catch return error.InvalidMessage;
    return message.reply_serial == serial;
}

fn connectEntry(entry: []const u8) !i32 {
    if (!std.mem.startsWith(u8, entry, "unix:")) return error.Unsupported;
    var path: [108]u8 = @splat(0);
    var path_len: usize = 0;
    var abstract = false;
    var pairs = std.mem.splitScalar(u8, entry["unix:".len..], ',');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        if (!std.mem.eql(u8, key, "path") and !std.mem.eql(u8, key, "abstract")) continue;
        abstract = std.mem.eql(u8, key, "abstract");
        path_len = try unescape(pair[eq + 1 ..], path[@intFromBool(abstract)..]);
    }
    if (path_len == 0) return error.Unsupported;
    const Address = extern struct { family: u16 = 1, path: [108]u8 };
    const address: Address = .{ .path = path };
    const fd = std.c.socket(1, 1 | 0o2000000, 0); // AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC
    if (fd < 0) return error.IoFailed;
    errdefer _ = std.c.close(fd);
    // Abstract names have an exact length; filesystem paths include their terminator.
    const length: u32 = @intCast(@as(usize, 2) + @intFromBool(abstract) + path_len + @intFromBool(!abstract));
    if (std.c.connect(fd, @ptrCast(&address), length) != 0) return error.ConnectionFailed;
    return fd;
}

/// Decodes D-Bus address escapes (%xx) into `out`, leaving room for a terminator.
fn unescape(value: []const u8, out: []u8) !usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < value.len) : (len += 1) {
        if (len + 1 >= out.len) return error.Unsupported;
        if (value[i] == '%') {
            if (i + 2 >= value.len) return error.Unsupported;
            out[len] = std.fmt.parseInt(u8, value[i + 1 .. i + 3], 16) catch return error.Unsupported;
            i += 3;
        } else {
            out[len] = value[i];
            i += 1;
        }
    }
    return len;
}

// ---------------------------------------------------------------- Introspection

const introspection_header =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
    \\ "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
    \\
;
const standard_interfaces =
    \\  <interface name="org.freedesktop.DBus.Properties">
    \\    <method name="Get"><arg type="s" name="interface_name" direction="in"/><arg type="s" name="property_name" direction="in"/><arg type="v" name="value" direction="out"/></method>
    \\    <method name="GetAll"><arg type="s" name="interface_name" direction="in"/><arg type="a{sv}" name="properties" direction="out"/></method>
    \\    <method name="Set"><arg type="s" name="interface_name" direction="in"/><arg type="s" name="property_name" direction="in"/><arg type="v" name="value" direction="in"/></method>
    \\    <signal name="PropertiesChanged"><arg type="s" name="interface_name"/><arg type="a{sv}" name="changed_properties"/><arg type="as" name="invalidated_properties"/></signal>
    \\  </interface>
    \\  <interface name="org.freedesktop.DBus.Introspectable">
    \\    <method name="Introspect"><arg type="s" name="xml_data" direction="out"/></method>
    \\  </interface>
    \\  <interface name="org.freedesktop.DBus.Peer">
    \\    <method name="Ping"/>
    \\    <method name="GetMachineId"><arg type="s" name="machine_uuid" direction="out"/></method>
    \\  </interface>
    \\
;

/// Follows the owner of a bus name like `g_bus_watch_name`: the first callback
/// reports the current state, then each change calls `vanished` for a lost
/// owner and `appeared` for a new one. Callbacks may stop the watcher.
pub const NameWatcher = struct {
    connection: *Connection,
    name: []u8,
    subscription: u32 = 0,
    serial: u32 = 0,
    owner: ?[]u8 = null,
    /// Set once the first state is known; a reply older than a signal is ignored.
    known: bool = false,
    /// While callbacks run, `destroy` only marks the watcher.
    dispatching: bool = false,
    dying: bool = false,
    appeared: *const fn (context: ?*anyopaque, owner: []const u8) void,
    vanished: *const fn (context: ?*anyopaque) void,
    context: ?*anyopaque,

    pub fn create(connection: *Connection, name: []const u8, appeared: *const fn (?*anyopaque, []const u8) void, vanished: *const fn (?*anyopaque) void, context: ?*anyopaque) Error!*NameWatcher {
        const allocator = connection.allocator;
        const self = try allocator.create(NameWatcher);
        errdefer allocator.destroy(self);
        const copy = try allocator.dupe(u8, name);
        errdefer allocator.free(copy);
        self.* = .{ .connection = connection, .name = copy, .appeared = appeared, .vanished = vanished, .context = context };
        self.subscription = try connection.subscribeArg0(bus_name, bus_name, "NameOwnerChanged", bus_path, name, &changed, self);
        errdefer connection.unsubscribe(self.subscription);
        self.serial = try connection.call(.{ .destination = bus_name, .path = bus_path, .interface = bus_name, .member = "GetNameOwner" }, .{name}, 25000, &replied, self);
        return self;
    }
    pub fn destroy(self: *NameWatcher) void {
        if (self.dying) return;
        self.dying = true;
        if (self.serial != 0) self.connection.cancel(self.serial);
        self.serial = 0;
        self.connection.unsubscribe(self.subscription);
        if (!self.dispatching) self.free();
    }
    fn free(self: *NameWatcher) void {
        const allocator = self.connection.allocator;
        if (self.owner) |owner| allocator.free(owner);
        allocator.free(self.name);
        allocator.destroy(self);
    }
    fn replied(context: ?*anyopaque, reply: Reply) void {
        const self: *NameWatcher = @ptrCast(@alignCast(context));
        self.serial = 0;
        if (self.known) return;
        const owner: ?[]const u8 = switch (reply) {
            .ok => |message| if (message.read(struct { []const u8 })) |args| args[0] else |_| null,
            .failed => null,
        };
        self.dispatching = true;
        self.update(owner);
        self.finish();
    }
    fn changed(context: ?*anyopaque, message: *const Message) void {
        const self: *NameWatcher = @ptrCast(@alignCast(context));
        const args = message.read(struct { []const u8, []const u8, []const u8 }) catch return;
        if (!std.mem.eql(u8, args[0], self.name)) return;
        self.dispatching = true;
        // A lost owner is reported before its replacement appears.
        if (self.owner != null and args[2].len > 0) self.update(null);
        if (!self.dying) self.update(if (args[2].len > 0) args[2] else null);
        self.finish();
    }
    fn finish(self: *NameWatcher) void {
        self.dispatching = false;
        if (self.dying) self.free();
    }
    fn update(self: *NameWatcher, owner: ?[]const u8) void {
        const first = !self.known;
        self.known = true;
        const allocator = self.connection.allocator;
        if (owner) |value| {
            if (self.owner) |old| if (std.mem.eql(u8, old, value)) return;
            const copy = allocator.dupe(u8, value) catch return;
            if (self.owner) |old| allocator.free(old);
            self.owner = copy;
            self.appeared(self.context, copy);
        } else {
            const had = self.owner != null;
            if (self.owner) |old| allocator.free(old);
            self.owner = null;
            if (had or first) self.vanished(self.context);
        }
    }
};

pub const MethodInfo = struct { name: []const u8, in: []const u8, out: []const u8 };
pub const PropertyInfo = struct { name: []const u8, signature: []const u8, readable: bool, writable: bool };
pub const InterfaceInfo = struct {
    name: []const u8,
    /// The interface's original element, served verbatim by Introspect.
    xml: []const u8,
    methods: []const MethodInfo,
    properties: []const PropertyInfo,

    pub fn method(self: *const InterfaceInfo, name: []const u8) ?*const MethodInfo {
        for (self.methods) |*item| if (std.mem.eql(u8, item.name, name)) return item;
        return null;
    }
    pub fn property(self: *const InterfaceInfo, name: []const u8) ?*const PropertyInfo {
        for (self.properties) |*item| if (std.mem.eql(u8, item.name, name)) return item;
        return null;
    }
};

/// Interfaces parsed from introspection XML. Names point into the XML, which must outlive this.
pub const Introspection = struct {
    arena: std.heap.ArenaAllocator,
    interfaces: []const InterfaceInfo,

    /// Parses the subset of introspection XML used by interface definitions:
    /// node, interface, method, signal, property, arg and annotation elements.
    pub fn parse(allocator: std.mem.Allocator, xml: []const u8) !Introspection {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var interfaces: std.ArrayList(InterfaceInfo) = .empty;
        var methods: std.ArrayList(MethodInfo) = .empty;
        var properties: std.ArrayList(PropertyInfo) = .empty;
        var in: std.ArrayList(u8) = .empty;
        var out: std.ArrayList(u8) = .empty;
        var interface_name: ?[]const u8 = null;
        var interface_start: usize = 0;
        var method_name: ?[]const u8 = null;
        var position: usize = 0;
        while (std.mem.indexOfScalarPos(u8, xml, position, '<')) |start| {
            if (std.mem.startsWith(u8, xml[start..], "<!--")) {
                position = (std.mem.indexOfPos(u8, xml, start, "-->") orelse return error.InvalidXml) + 3;
                continue;
            }
            const end = std.mem.indexOfScalarPos(u8, xml, start, '>') orelse return error.InvalidXml;
            position = end + 1;
            if (xml[start + 1] == '?' or xml[start + 1] == '!') continue;
            const closing = xml[start + 1] == '/';
            var tag = std.mem.trim(u8, xml[start + 1 + @intFromBool(closing) .. end], " \t\r\n");
            const self_closing = tag.len > 0 and tag[tag.len - 1] == '/';
            if (self_closing) tag = std.mem.trimEnd(u8, tag[0 .. tag.len - 1], " \t\r\n");
            const name_end = std.mem.indexOfAny(u8, tag, " \t\r\n") orelse tag.len;
            const element = tag[0..name_end];
            const attributes = tag[name_end..];
            if (std.mem.eql(u8, element, "interface")) {
                if (closing) {
                    try interfaces.append(a, .{ .name = interface_name orelse return error.InvalidXml, .xml = xml[interface_start..position], .methods = try methods.toOwnedSlice(a), .properties = try properties.toOwnedSlice(a) });
                    interface_name = null;
                } else {
                    interface_name = attribute(attributes, "name") orelse return error.InvalidXml;
                    interface_start = start;
                    if (self_closing) {
                        try interfaces.append(a, .{ .name = interface_name.?, .xml = xml[start..position], .methods = &.{}, .properties = &.{} });
                        interface_name = null;
                    }
                }
            } else if (std.mem.eql(u8, element, "method") and interface_name != null) {
                if (!closing) {
                    // A new method, possibly self-closing with no arguments.
                    method_name = attribute(attributes, "name") orelse return error.InvalidXml;
                    in.clearRetainingCapacity();
                    out.clearRetainingCapacity();
                }
                if (closing or self_closing) {
                    try methods.append(a, .{ .name = method_name orelse return error.InvalidXml, .in = try a.dupe(u8, in.items), .out = try a.dupe(u8, out.items) });
                    method_name = null;
                }
            } else if (std.mem.eql(u8, element, "arg") and method_name != null and !closing) {
                const signature = attribute(attributes, "type") orelse return error.InvalidXml;
                const direction = attribute(attributes, "direction") orelse "in";
                try (if (std.mem.eql(u8, direction, "out")) &out else &in).appendSlice(a, signature);
            } else if (std.mem.eql(u8, element, "property") and interface_name != null and !closing) {
                const access = attribute(attributes, "access") orelse "read";
                try properties.append(a, .{
                    .name = attribute(attributes, "name") orelse return error.InvalidXml,
                    .signature = attribute(attributes, "type") orelse return error.InvalidXml,
                    .readable = std.mem.indexOf(u8, access, "read") != null,
                    .writable = std.mem.indexOf(u8, access, "write") != null,
                });
            }
        }
        if (interface_name != null or method_name != null) return error.InvalidXml;
        return .{ .arena = arena, .interfaces = interfaces.items };
    }
    pub fn deinit(self: *Introspection) void {
        self.arena.deinit();
    }
    pub fn find(self: *const Introspection, name: []const u8) ?*const InterfaceInfo {
        for (self.interfaces) |*item| if (std.mem.eql(u8, item.name, name)) return item;
        return null;
    }
};

/// The value of `key="value"` (or single-quoted) within an element's attributes.
fn attribute(attributes: []const u8, key: []const u8) ?[]const u8 {
    var rest = attributes;
    while (true) {
        rest = std.mem.trimStart(u8, rest, " \t\r\n");
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse return null;
        const name = std.mem.trim(u8, rest[0..eq], " \t\r\n");
        var after = std.mem.trimStart(u8, rest[eq + 1 ..], " \t\r\n");
        if (after.len == 0 or (after[0] != '"' and after[0] != '\'')) return null;
        const quote = after[0];
        const close = std.mem.indexOfScalarPos(u8, after, 1, quote) orelse return null;
        if (std.mem.eql(u8, name, key)) return after[1..close];
        after = after[close + 1 ..];
        rest = after;
    }
}

// ---------------------------------------------------------------- Tests

test "signatures follow D-Bus type codes for Zig types" {
    try std.testing.expectEqualStrings("s", signatureOf([]const u8));
    try std.testing.expectEqualStrings("as", signatureOf([]const []const u8));
    try std.testing.expectEqualStrings("(sub)", signatureOf(struct { []const u8, u32, bool }));
    try std.testing.expectEqualStrings("a{sv}", signatureOf(Dict([]const u8, Value)));
    try std.testing.expectEqualStrings("ay", signatureOf(Bytes));
    try std.testing.expectEqualStrings("susssasa{sv}i", bodySignature(struct { []const u8, u32, []const u8, []const u8, []const u8, []const []const u8, Dict([]const u8, Value), i32 }));
}

test "messages round-trip with alignment, nested containers and variants" {
    const allocator = std.testing.allocator;
    const urgency: Value = .{ .byte = 2 };
    const hints = Dict([]const u8, Value){ .entries = &.{.{ .key = "urgency", .value = urgency }} };
    var message = try encode(allocator, .{ .kind = .method_call, .serial = 7, .destination = "org.freedesktop.Notifications", .path = "/org/freedesktop/Notifications", .interface = "org.freedesktop.Notifications", .member = "Notify", .arena = undefined }, .{ "desktop-zig", @as(u32, 0), "icon", "Title", "Body", @as([]const []const u8, &.{"default"}), hints, @as(i32, -1) });
    defer message.deinit();
    // The body starts 8-aligned after the header fields.
    try std.testing.expectEqual(@as(usize, 0), (message.bytes.items.len - std.mem.readInt(u32, message.bytes.items[4..8], .little)) % 8);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(), message.bytes.items, &.{});
    try std.testing.expectEqual(Kind.method_call, parsed.kind);
    try std.testing.expectEqual(@as(u32, 7), parsed.serial);
    try std.testing.expectEqualStrings("Notify", parsed.member.?);
    try std.testing.expectEqualStrings("susssasa{sv}i", parsed.signature);
    const args = try parsed.read(struct { []const u8, u32, []const u8, []const u8, []const u8, []const []const u8, Dict([]const u8, Value), i32 });
    try std.testing.expectEqualStrings("desktop-zig", args[0]);
    try std.testing.expectEqualStrings("Body", args[4]);
    try std.testing.expectEqualStrings("default", args[5][0]);
    try std.testing.expectEqualStrings("urgency", args[6].entries[0].key);
    try std.testing.expectEqual(@as(u8, 2), args[6].entries[0].value.byte);
    try std.testing.expectEqual(@as(i32, -1), args[7]);
    // A dictionary read as a single Value needs the matching signature.
    try std.testing.expectError(error.UnexpectedSignature, parsed.read(struct { []const u8, u32, []const u8, []const u8, []const u8, []const []const u8, Value, i32 }));
}

test "dynamic values decode any signature and look up dictionary keys" {
    const allocator = std.testing.allocator;
    const inner: Value = .{ .string = "dark" };
    const entry = [2]Value{ .{ .string = "color-scheme" }, .{ .variant = &inner } };
    const dict: Value = .{ .array = .{ .element = "{sv}", .items = &.{.{ .dict_entry = &entry }} } };
    var message = try encode(allocator, .{ .kind = .method_return, .serial = 1, .reply_serial = 3, .arena = undefined }, .{ dict, @as(u64, 1 << 40), @as(f64, 2.5), ObjectPath{ .value = "/a/b" } });
    defer message.deinit();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(), message.bytes.items, &.{});
    const values = try parsed.read(struct { Value, u64, f64, ObjectPath });
    try std.testing.expectEqualStrings("dark", values[0].lookup("color-scheme").?.string);
    try std.testing.expect(values[0].lookup("missing") == null);
    try std.testing.expectEqual(@as(u64, 1 << 40), values[1]);
    try std.testing.expectEqual(@as(f64, 2.5), values[2]);
    try std.testing.expectEqualStrings("/a/b", values[3].value);
    var buffer: [32]u8 = undefined;
    // Decoding a variant yields the value it contains.
    try std.testing.expectEqualStrings("a{sv}", try values[0].signatureInto(&buffer));
}

test "malformed messages are rejected" {
    const allocator = std.testing.allocator;
    var message = try encode(allocator, .{ .kind = .signal, .serial = 2, .path = "/p", .interface = "a.b", .member = "C", .arena = undefined }, .{ "text", true });
    defer message.deinit();
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    // The body is "text" (length, 4 bytes, NUL, padding to 12) followed by a u32 boolean.
    try std.testing.expectError(error.InvalidMessage, parse(arena.allocator(), message.bytes.items[0 .. message.bytes.items.len - 1], &.{}));
    var bytes = try arena.allocator().dupe(u8, message.bytes.items);
    bytes[bytes.len - 4] = 2;
    try std.testing.expectError(error.InvalidMessage, (try parse(arena.allocator(), bytes, &.{})).read(struct { []const u8, bool }));
    bytes[bytes.len - 4] = 1;
    bytes[bytes.len - 8] = 'x'; // the string's terminator
    try std.testing.expectError(error.InvalidMessage, (try parse(arena.allocator(), bytes, &.{})).read(struct { []const u8, bool }));
    bytes[bytes.len - 8] = 0;
    try std.testing.expect((try (try parse(arena.allocator(), bytes, &.{})).read(struct { []const u8, bool }))[1]);
    try std.testing.expectError(error.UnexpectedSignature, (try parse(arena.allocator(), message.bytes.items, &.{})).read(struct { []const u8 }));
}

test "addresses decode escapes and reject overlong paths" {
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("/run/a b", out[0..try unescape("/run/a%20b", &out)]);
    try std.testing.expectError(error.Unsupported, unescape("%2", &out));
    try std.testing.expectError(error.Unsupported, unescape("/a/very/long/path/name", &out));
}

test "introspection XML yields methods, signatures and property access" {
    const xml =
        \\<!-- comment with <tags> -->
        \\<node>
        \\  <interface name="org.example.A">
        \\    <method name="Get"><arg type="s" direction="in"/><arg type="u" name="n"/><arg type="a{sv}" direction="out"/></method>
        \\    <method name="Ping"/>
        \\    <signal name="Changed"><arg type="o"/></signal>
        \\    <property name="Level" type="d" access="read"/>
        \\    <property name='Mode' type='s' access='readwrite'/>
        \\    <annotation name="org.freedesktop.DBus.Deprecated" value="false"/>
        \\  </interface>
        \\  <interface name="org.example.Empty"/>
        \\</node>
    ;
    var parsed = try Introspection.parse(std.testing.allocator, xml);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.interfaces.len);
    const info = parsed.find("org.example.A").?;
    try std.testing.expectEqualStrings("su", info.method("Get").?.in);
    try std.testing.expectEqualStrings("a{sv}", info.method("Get").?.out);
    try std.testing.expectEqualStrings("", info.method("Ping").?.in);
    try std.testing.expect(info.method("Changed") == null);
    try std.testing.expect(info.property("Level").?.readable and !info.property("Level").?.writable);
    try std.testing.expect(info.property("Mode").?.writable);
    try std.testing.expect(std.mem.startsWith(u8, info.xml, "<interface name=\"org.example.A\">"));
    try std.testing.expect(std.mem.endsWith(u8, info.xml, "</interface>"));
    try std.testing.expectEqual(@as(usize, 0), parsed.find("org.example.Empty").?.methods.len);
    try std.testing.expectError(error.InvalidXml, Introspection.parse(std.testing.allocator, "<node><interface name=\"x\"><method name=\"m\"></interface></node>"));
}

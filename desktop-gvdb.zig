//! A reader for GVDB, GLib's on-disk hash table format, used by compiled
//! GSettings schemas and dconf databases. Values are serialized GVariants.
const std = @import("std");
const dbus = @import("dbus");
const gvariant = @import("desktop-gvariant.zig");

pub const Error = error{ InvalidFile, OutOfMemory };

const Pointer = extern struct { start: u32, end: u32 };
const Item = extern struct {
    hash: u32,
    /// The parent item whose name prefixes this one, or 0xffffffff.
    parent: u32,
    key_start: u32,
    key_size: u16,
    /// 'v' value, 'H' nested table, 'L' list.
    kind: u8,
    unused: u8,
    value: Pointer,
};
comptime {
    std.debug.assert(@sizeOf(Item) == 24);
}

/// A file's bytes; tables and values borrow from them.
pub const File = struct {
    bytes: []align(8) const u8,
    allocator: ?std.mem.Allocator = null,

    /// Reads a whole file; null when it cannot be opened. Uses libc so any thread can call it.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !?File {
        var name: [std.fs.max_path_bytes:0]u8 = undefined;
        if (path.len >= name.len) return null;
        @memcpy(name[0..path.len], path);
        name[path.len] = 0;
        const handle = std.c.fopen(&name, "rb") orelse return null;
        defer _ = std.c.fclose(handle);
        var bytes: std.ArrayListAligned(u8, .@"8") = .empty;
        errdefer bytes.deinit(allocator);
        while (true) {
            try bytes.ensureUnusedCapacity(allocator, 64 << 10);
            const unused = bytes.unusedCapacitySlice();
            const count = std.c.fread(unused.ptr, 1, unused.len, handle);
            bytes.items.len += count;
            if (count < unused.len) break;
        }
        const owned = try bytes.toOwnedSlice(allocator);
        const file: File = .{ .bytes = owned, .allocator = allocator };
        _ = file.root() catch {
            allocator.free(owned);
            return error.InvalidFile;
        };
        return file;
    }
    pub fn close(self: File) void {
        if (self.allocator) |allocator| allocator.free(self.bytes);
    }
    pub fn root(self: File) Error!Table {
        if (self.bytes.len < 24) return error.InvalidFile;
        // "GVariant" as two little-endian words; a byteswapped file is foreign-endian.
        if (!std.mem.eql(u8, self.bytes[0..8], "GVariant")) return error.InvalidFile;
        if (std.mem.readInt(u32, self.bytes[8..12], .little) != 0) return error.InvalidFile;
        return self.table(.{ .start = std.mem.readInt(u32, self.bytes[16..20], .little), .end = std.mem.readInt(u32, self.bytes[20..24], .little) });
    }
    fn table(self: File, pointer: Pointer) Error!Table {
        const data = try self.slice(pointer);
        if (data.len < 8 or pointer.start % 4 != 0) return error.InvalidFile;
        const bloom_words = std.mem.readInt(u32, data[0..4], .little) & ((1 << 27) - 1);
        const buckets = std.mem.readInt(u32, data[4..8], .little);
        const items_start = 8 + (@as(usize, bloom_words) + buckets) * 4;
        if (items_start > data.len or (data.len - items_start) % @sizeOf(Item) != 0) return error.InvalidFile;
        const count = (data.len - items_start) / @sizeOf(Item);
        const items: []align(1) const Item = @as([*]align(1) const Item, @ptrCast(data[items_start..].ptr))[0..count];
        return .{ .file = self, .items = items };
    }
    fn slice(self: File, pointer: Pointer) Error![]const u8 {
        if (pointer.start > pointer.end or pointer.end > self.bytes.len) return error.InvalidFile;
        return self.bytes[pointer.start..pointer.end];
    }
};

pub const Table = struct {
    file: File,
    items: []align(1) const Item,

    /// The item's full name: its parents' names followed by its own key.
    fn nameInto(self: Table, index: usize, buffer: []u8) ?[]const u8 {
        var parts: [64]usize = undefined;
        var depth: usize = 0;
        var current = index;
        while (true) {
            if (depth == parts.len) return null;
            parts[depth] = current;
            depth += 1;
            const parent = self.items[current].parent;
            if (parent == 0xffffffff) break;
            if (parent >= self.items.len) return null;
            current = parent;
        }
        var length: usize = 0;
        while (depth > 0) {
            depth -= 1;
            const item = self.items[parts[depth]];
            const key = self.file.slice(.{ .start = item.key_start, .end = item.key_start + item.key_size }) catch return null;
            if (length + key.len > buffer.len) return null;
            @memcpy(buffer[length..][0..key.len], key);
            length += key.len;
        }
        return buffer[0..length];
    }
    fn find(self: Table, key: []const u8) ?Item {
        var buffer: [1024]u8 = undefined;
        for (self.items, 0..) |item, index| {
            if (item.kind != 'v' and item.kind != 'H' and item.kind != 'L') continue;
            const name = self.nameInto(index, &buffer) orelse continue;
            if (std.mem.eql(u8, name, key)) return item;
        }
        return null;
    }
    /// The value stored at `key`, unwrapped from its variant, allocated from `arena`.
    pub fn value(self: Table, arena: std.mem.Allocator, key: []const u8) !?dbus.Value {
        const item = self.find(key) orelse return null;
        if (item.kind != 'v') return null;
        const decoded = try gvariant.decode(arena, "v", try self.file.slice(item.value));
        return decoded.variant.*;
    }
    pub fn table(self: Table, key: []const u8) !?Table {
        const item = self.find(key) orelse return null;
        if (item.kind != 'H') return null;
        return try self.file.table(item.value);
    }
    /// The full names of value and table items, allocated from `arena`.
    pub fn names(self: Table, arena: std.mem.Allocator) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var buffer: [1024]u8 = undefined;
        for (self.items, 0..) |item, index| {
            if (item.kind != 'v' and item.kind != 'H') continue;
            const name = self.nameInto(index, &buffer) orelse continue;
            try out.append(arena, try arena.dupe(u8, name));
        }
        return out.items;
    }
};

test "compiled schemas decode interface defaults" {
    const directory = std.c.getenv("GSETTINGS_SCHEMA_DIR") orelse return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, "{s}/gschemas.compiled", .{std.mem.span(directory)});
    const file = try File.open(std.testing.allocator, path) orelse return error.SkipZigTest;
    defer file.close();
    const schema = try (try file.root()).table("org.gnome.desktop.interface") orelse return error.SkipZigTest;
    var checked: usize = 0;
    for (try schema.names(a)) |name| {
        if (name.len == 0 or name[0] == '.') continue;
        const info = (try schema.value(a, name)) orelse continue;
        try std.testing.expect(info.structure.len >= 1);
        checked += 1;
    }
    try std.testing.expect(checked > 20);
}

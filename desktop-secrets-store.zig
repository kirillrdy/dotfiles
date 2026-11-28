//! The vault rewrites one authenticated snapshot on every set.
const std = @import("std");
const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const file_name = "secrets.json";
const max_size = 16 * 1024 * 1024;

pub const Attribute = struct { key: []const u8, value: []const u8 };
pub const Collection = struct { id: u64, label: []const u8, created: u64, modified: u64 };
pub const Item = struct { id: u64, collection: u64, label: []const u8, attributes: []const Attribute, created: u64, modified: u64 };
pub const Alias = struct { name: []const u8, collection: u64 };
pub const Index = struct { next_id: u64 = 1, collections: []const Collection = &.{}, items: []const Item = &.{}, aliases: []const Alias = &.{} };
pub const Value = struct { id: u64, bytes: []const u8, content_type: []const u8 };

const File = struct {
    salt: [32]u8,
    nonce: [Aead.nonce_length]u8,
    tag: [Aead.tag_length]u8,
    index: Index,
    ciphertext: []const u8,
};

pub const Vault = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    lock_file: std.Io.File,
    key: ?[32]u8 = null,
    saved: ?std.json.Parsed(File) = null,
    values: ?std.json.Parsed([]const Value) = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !Vault {
        const cwd = std.Io.Dir.cwd();
        cwd.createDir(io, directory, .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const dir = try cwd.openDir(io, directory, .{ .follow_symlinks = false });
        errdefer dir.close(io);
        const lock_file = dir.createFile(io, "lock", .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true, .permissions = .fromMode(0o600) }) catch |err| switch (err) {
            error.WouldBlock => return error.VaultInUse,
            else => return err,
        };
        errdefer lock_file.close(io);

        var vault: Vault = .{ .allocator = allocator, .io = io, .dir = dir, .lock_file = lock_file };
        const file = dir.openFile(io, file_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return vault,
            else => return err,
        };
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file or stat.size > max_size) return error.InvalidVault;
        const bytes = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(bytes);
        if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.InvalidVault;
        vault.saved = try std.json.parseFromSlice(File, allocator, bytes, .{ .allocate = .alloc_always });
        return vault;
    }

    pub fn index(self: *const Vault) Index {
        return if (self.saved) |saved| saved.value.index else .{};
    }

    pub fn unlock(self: *Vault, password: []const u8) !void {
        if (self.key != null) return;
        if (password.len == 0 or password.len > 4096) return error.InvalidPassword;
        var salt: [32]u8 = undefined;
        if (self.saved) |saved| salt = saved.value.salt else try self.io.randomSecure(&salt);
        self.key = @splat(0);
        errdefer self.lock();
        try std.crypto.pwhash.scrypt.kdf(self.allocator, &self.key.?, password, &salt, .owasp);
        const saved = self.saved orelse return self.write(.{}, &.{}, salt);
        const metadata = try std.json.Stringify.valueAlloc(self.allocator, saved.value.index, .{});
        defer self.allocator.free(metadata);
        const plain = try self.allocator.alloc(u8, saved.value.ciphertext.len);
        defer wipeFree(self.allocator, plain);
        try Aead.decrypt(plain, saved.value.ciphertext, saved.value.tag, metadata, saved.value.nonce, self.key.?);
        self.values = try std.json.parseFromSlice([]const Value, self.allocator, plain, .{ .allocate = .alloc_always });
    }

    pub fn get(self: *const Vault, id: u64) ?Value {
        return find(if (self.values) |values| values.value else &.{}, id);
    }

    /// Replaces the listed secrets and drops secrets whose items were deleted.
    /// The index and values take effect together after the file is replaced.
    pub fn set(self: *Vault, next_index: Index, updates: []const Value) !void {
        if (self.key == null) return error.IsLocked;
        var values: std.ArrayList(Value) = .empty;
        defer values.deinit(self.allocator);
        for (next_index.items) |item| {
            const value = find(updates, item.id) orelse self.get(item.id) orelse continue;
            try values.append(self.allocator, value);
        }
        try self.write(next_index, values.items, self.saved.?.value.salt);
    }

    fn write(self: *Vault, next_index: Index, values: []const Value, salt: [32]u8) !void {
        const allocator = self.allocator;
        const metadata = try std.json.Stringify.valueAlloc(allocator, next_index, .{});
        defer allocator.free(metadata);
        const plain = try std.json.Stringify.valueAlloc(allocator, values, .{});
        defer wipeFree(allocator, plain);
        const ciphertext = try allocator.alloc(u8, plain.len);
        defer allocator.free(ciphertext);
        var saved: File = .{ .salt = salt, .nonce = undefined, .tag = undefined, .index = next_index, .ciphertext = ciphertext };
        try self.io.randomSecure(&saved.nonce);
        Aead.encrypt(ciphertext, &saved.tag, plain, metadata, saved.nonce, self.key.?);
        const bytes = try std.json.Stringify.valueAlloc(allocator, saved, .{});
        defer allocator.free(bytes);
        if (bytes.len > max_size) return error.VaultTooLarge;

        const new_saved = try std.json.parseFromSlice(File, allocator, bytes, .{ .allocate = .alloc_always });
        errdefer new_saved.deinit();
        const new_values = try std.json.parseFromSlice([]const Value, allocator, plain, .{ .allocate = .alloc_always });
        errdefer freeValues(new_values);
        var file = self.dir.createFileAtomic(self.io, file_name, .{ .permissions = .fromMode(0o600), .replace = true }) catch return error.WriteVault;
        defer file.deinit(self.io);
        file.file.writeStreamingAll(self.io, bytes) catch return error.WriteVault;
        file.file.sync(self.io) catch return error.WriteVault;
        file.replace(self.io) catch return error.WriteVault;

        if (self.saved) |old| old.deinit();
        if (self.values) |old| freeValues(old);
        self.saved = new_saved;
        self.values = new_values;
    }

    pub fn lock(self: *Vault) void {
        if (self.key) |*key| std.crypto.secureZero(u8, key);
        if (self.values) |values| freeValues(values);
        self.key = null;
        self.values = null;
    }

    pub fn deinit(self: *Vault) void {
        self.lock();
        if (self.saved) |saved| saved.deinit();
        self.lock_file.close(self.io);
        self.dir.close(self.io);
    }
};

fn find(values: []const Value, id: u64) ?Value {
    for (values) |value| {
        if (value.id == id) return value;
    }
    return null;
}

fn wipeFree(allocator: std.mem.Allocator, bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
    allocator.free(bytes);
}

fn freeValues(values: std.json.Parsed([]const Value)) void {
    for (values.value) |value| std.crypto.secureZero(u8, @constCast(value.bytes));
    values.deinit();
}

test "set persists binary values and locking requires the password again" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(directory);

    {
        var vault = try Vault.init(allocator, io, directory);
        defer vault.deinit();
        try std.testing.expectError(error.VaultInUse, Vault.init(allocator, io, directory));
        try vault.unlock("password");
        const items = [_]Item{.{ .id = 1, .collection = 1, .label = "Test", .attributes = &.{}, .created = 0, .modified = 0 }};
        try vault.set(.{ .items = &items }, &.{.{ .id = 1, .bytes = "test\x00\xff", .content_type = "application/octet-stream" }});
    }
    {
        var vault = try Vault.init(allocator, io, directory);
        defer vault.deinit();
        try std.testing.expectEqualStrings("Test", vault.index().items[0].label);
        try std.testing.expect(vault.get(1) == null);
        try std.testing.expectError(error.AuthenticationFailed, vault.unlock("wrong"));
        try vault.unlock("password");
        try std.testing.expectEqualSlices(u8, "test\x00\xff", vault.get(1).?.bytes);
        try vault.set(.{}, &.{});
        try std.testing.expect(vault.get(1) == null);
    }
}

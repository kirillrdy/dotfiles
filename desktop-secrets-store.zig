//! Versioned authenticated vault. Metadata is public; secret values are encrypted.
//! Every allocation used for keys, KDF scratch, and decoded values is wiped on free.
const std = @import("std");
const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
pub const WipingAllocator = struct {
    parent: std.mem.Allocator,
    pub fn allocator(self: *WipingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        return (@as(*WipingAllocator, @ptrCast(@alignCast(ctx)))).parent.rawAlloc(len, alignment, ret);
    }
    // Force allocate/copy/free so truncated or relocated buffers are wiped before release.
    fn resize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }
    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *WipingAllocator = @ptrCast(@alignCast(ctx));
        std.crypto.secureZero(u8, bytes);
        self.parent.rawFree(bytes, alignment, ret);
    }
    const vtable = std.mem.Allocator.VTable{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
};
pub fn random(io: std.Io, bytes: []u8) !void {
    io.randomSecure(bytes) catch return error.RandomFailed;
}
pub const Attribute = struct { key: [:0]const u8, value: [:0]const u8 };
pub const Collection = struct { id: u64, label: [:0]const u8, created: u64, modified: u64 };
pub const Item = struct { id: u64, collection: u64, label: [:0]const u8, attributes: []const Attribute, created: u64, modified: u64 };
pub const Alias = struct { name: [:0]const u8, collection: u64 };
pub const Index = struct { next_id: u64 = 1, collections: []const Collection = &.{}, items: []const Item = &.{}, aliases: []const Alias = &.{} };
pub const Value = struct { id: u64, bytes: []const u8, content_type: [:0]const u8 };
const Envelope = struct { version: u32 = 1, salt: [32]u8, nonce: [24]u8, tag: [16]u8, index: Index, ciphertext: []const u8 };
pub const Vault = struct {
    a: std.mem.Allocator,
    io: std.Io,
    directory: [:0]const u8,
    lock_file: std.Io.File,
    index: Index = .{},
    values: std.ArrayList(Value) = .empty,
    key: ?[32]u8 = null,
    envelope: ?std.json.Parsed(Envelope) = null,
    salt: [32]u8 = @splat(0),
    // Mutable metadata lives in this arena; secret values never do.
    arena: std.heap.ArenaAllocator,
    pub fn init(a: std.mem.Allocator, io: std.Io, directory: [:0]const u8) !Vault {
        std.Io.Dir.cwd().createDir(io, directory, .fromMode(0o700)) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return error.CreateDirectory,
        };
        var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .follow_symlinks = false }) catch return error.UnsafeDirectory;
        defer dir.close(io);
        const lock_file = dir.createFile(io, "lock", .{
            .read = true,
            .truncate = false,
            .lock = .exclusive,
            .lock_nonblocking = true,
            .permissions = .fromMode(0o600),
        }) catch |err| switch (err) {
            error.WouldBlock => return error.VaultInUse,
            else => return error.LockVault,
        };
        var result = Vault{ .a = a, .io = io, .directory = directory, .lock_file = lock_file, .arena = .init(a) };
        errdefer result.deinit();
        const vault_file = dir.openFile(io, "vault.json", .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return result,
            else => return error.ReadVault,
        };
        defer vault_file.close(io);
        const st = vault_file.stat(io) catch return error.ReadVault;
        if (st.kind != .file or st.size > 16 * 1024 * 1024) return error.UnsafeVault;
        const bytes = try a.alloc(u8, @intCast(st.size));
        defer a.free(bytes);
        const got = vault_file.readPositionalAll(io, bytes, 0) catch return error.ReadVault;
        if (got != bytes.len) return error.ReadVault;
        const parsed = try std.json.parseFromSlice(Envelope, a, bytes, .{ .allocate = .alloc_always });
        result.envelope = parsed;
        if (parsed.value.version != 1) return error.UnsupportedVaultVersion;
        result.salt = parsed.value.salt;
        result.index = try result.cloneIndex(parsed.value.index);
        return result;
    }
    pub fn deinit(self: *Vault) void {
        self.lock();
        if (self.envelope) |*env| env.deinit();
        self.arena.deinit();
        self.lock_file.close(self.io);
    }
    pub fn lock(self: *Vault) void {
        if (self.key) |*key| std.crypto.secureZero(u8, key);
        self.key = null;
        for (self.values.items) |v| freeValue(self.a, v);
        self.values.deinit(self.a);
        self.values = .empty;
    }
    pub fn metadata(self: *Vault) std.mem.Allocator {
        return self.arena.allocator();
    }
    fn cloneIndex(self: *Vault, index: Index) !Index {
        const encoded = try std.json.Stringify.valueAlloc(self.a, index, .{});
        defer self.a.free(encoded);
        return (try std.json.parseFromSlice(Index, self.metadata(), encoded, .{ .allocate = .alloc_always })).value;
    }
    pub fn unlock(self: *Vault, password: []const u8) !void {
        if (self.key != null) return;
        if (password.len == 0 or password.len > 4096) return error.InvalidPassword;
        if (self.envelope == null) try random(self.io, &self.salt);
        var key: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &key);
        try std.crypto.pwhash.scrypt.kdf(self.a, &key, password, &self.salt, .owasp);
        try self.loadKey(key);
        if (self.envelope == null) self.save() catch |err| {
            self.lock();
            return err;
        };
    }
    fn loadKey(self: *Vault, key: [32]u8) !void {
        self.key = key;
        errdefer self.lock();
        if (self.envelope) |env| {
            const aad = try std.json.Stringify.valueAlloc(self.a, env.value.index, .{});
            defer self.a.free(aad);
            const plain = try self.a.alloc(u8, env.value.ciphertext.len);
            defer self.a.free(plain);
            try Aead.decrypt(plain, env.value.ciphertext, env.value.tag, aad, env.value.nonce, key);
            const decoded = try std.json.parseFromSlice([]const Value, self.a, plain, .{ .allocate = .alloc_always });
            defer decoded.deinit();
            for (decoded.value) |v| try self.setValue(v.id, v.bytes, v.content_type);
        }
    }
    pub fn save(self: *Vault) !void {
        var key = self.key orelse return error.IsLocked;
        defer std.crypto.secureZero(u8, &key);
        const aad = try std.json.Stringify.valueAlloc(self.a, self.index, .{});
        defer self.a.free(aad);
        const plain = try std.json.Stringify.valueAlloc(self.a, self.values.items, .{});
        defer self.a.free(plain);
        const cipher = try self.a.alloc(u8, plain.len);
        defer self.a.free(cipher);
        var env = Envelope{ .salt = self.salt, .nonce = undefined, .tag = undefined, .index = self.index, .ciphertext = cipher };
        try random(self.io, &env.nonce);
        Aead.encrypt(cipher, &env.tag, plain, aad, env.nonce, key);
        const bytes = try std.json.Stringify.valueAlloc(self.a, env, .{});
        defer self.a.free(bytes);
        if (bytes.len > 16 * 1024 * 1024) return error.VaultTooLarge;
        // Parse before committing so an allocation failure cannot leave stale ciphertext in memory.
        const parsed = try std.json.parseFromSlice(Envelope, self.a, bytes, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        var next_arena = std.heap.ArenaAllocator.init(self.a);
        errdefer next_arena.deinit();
        const next_index = (try std.json.parseFromSlice(Index, next_arena.allocator(), aad, .{ .allocate = .alloc_always })).value;
        const path = try std.fmt.allocPrintSentinel(self.a, "{s}/vault.json", .{self.directory}, 0);
        defer self.a.free(path);
        @import("desktop-paths.zig").writeFileAtomic(self.a, path, bytes, 0o600) catch return error.WriteVault;
        if (self.envelope) |*old| old.deinit();
        self.envelope = parsed;
        self.arena.deinit();
        self.arena = next_arena;
        self.index = next_index;
    }
    pub fn value(self: *Vault, id: u64) ?Value {
        for (self.values.items) |v| {
            if (v.id == id) return v;
        }
        return null;
    }
    pub fn setValue(self: *Vault, id: u64, bytes: []const u8, content_type: [:0]const u8) !void {
        if (self.key == null) return error.IsLocked;
        const data = try self.a.dupe(u8, bytes);
        errdefer {
            std.crypto.secureZero(u8, data);
            self.a.free(data);
        }
        const kind = try self.a.dupeSentinel(u8, content_type, 0);
        errdefer self.a.free(kind);
        for (self.values.items) |*v| {
            if (v.id == id) {
                freeValue(self.a, v.*);
                v.* = .{ .id = id, .bytes = data, .content_type = kind };
                return;
            }
        }
        try self.values.append(self.a, .{ .id = id, .bytes = data, .content_type = kind });
    }
    pub fn removeValue(self: *Vault, id: u64) !void {
        for (self.values.items, 0..) |v, i| {
            if (v.id == id) {
                freeValue(self.a, self.values.swapRemove(i));
                return;
            }
        }
    }
    pub fn restore(self: *Vault) !void {
        const was_unlocked = self.key != null;
        var key = self.key;
        defer if (key) |*k| std.crypto.secureZero(u8, k);
        self.lock();
        self.arena.deinit();
        self.arena = .init(self.a);
        self.index = if (self.envelope) |env| try self.cloneIndex(env.value.index) else .{};
        if (!was_unlocked) return;
        if (self.envelope != null) try self.loadKey(key.?);
    }
};

fn freeValue(a: std.mem.Allocator, v: Value) void {
    std.crypto.secureZero(u8, @constCast(v.bytes));
    a.free(v.bytes);
    a.free(v.content_type);
}

test "vault rejects wrong passwords and tampering; locking erases values; restart restores binary secrets" {
    var wa = WipingAllocator{ .parent = std.testing.allocator };
    const a = wa.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const directory = try std.fmt.allocPrintSentinel(a, "{s}/vault", .{root}, 0);
    defer a.free(directory);
    {
        var v = try Vault.init(a, std.testing.io, directory);
        defer v.deinit();
        try std.testing.expectError(error.VaultInUse, Vault.init(a, std.testing.io, directory));
        try v.unlock("vault-test-password");
        try v.setValue(1, "binary\x00secret\xff", "application/octet-stream");
        try v.save();
        v.lock();
        try std.testing.expect(v.key == null and v.values.items.len == 0);
        try std.testing.expectError(error.AuthenticationFailed, v.unlock("wrong-password"));
        try std.testing.expect(v.key == null);
        try v.unlock("vault-test-password");
        try std.testing.expectEqualSlices(u8, "binary\x00secret\xff", v.value(1).?.bytes);
        try v.setValue(1, "uncommitted", "text/plain");
        try v.restore();
        try std.testing.expectEqualSlices(u8, "binary\x00secret\xff", v.value(1).?.bytes);
    }
    {
        var v = try Vault.init(a, std.testing.io, directory);
        defer v.deinit();
        try v.unlock("vault-test-password");
        try std.testing.expectEqualSlices(u8, "binary\x00secret\xff", v.value(1).?.bytes);
        v.lock();
        v.envelope.?.value.tag[0] ^= 1;
        try std.testing.expectError(error.AuthenticationFailed, v.unlock("vault-test-password"));
    }
}

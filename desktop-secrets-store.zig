//! Versioned authenticated vault. Metadata is public; secret values are encrypted.
//! Every allocation used for keys, KDF scratch, and decoded values is wiped on free.
const std = @import("std");
const p = @import("posix");
const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
pub fn wipe(bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
}
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
        wipe(bytes);
        self.parent.rawFree(bytes, alignment, ret);
    }
    const vtable = std.mem.Allocator.VTable{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
};
pub fn random(bytes: []u8) !void {
    var n: usize = 0;
    while (n < bytes.len) {
        const count = p.getrandom(bytes[n..].ptr, bytes.len - n, 0);
        if (count < 0) {
            if (p.__errno_location().* == p.EINTR) continue;
            return error.RandomFailed;
        }
        if (count == 0) return error.RandomFailed;
        n += @intCast(count);
    }
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
    directory: [:0]const u8,
    lock_fd: c_int = -1,
    index: Index = .{},
    values: []const Value = &.{},
    key: ?[32]u8 = null,
    envelope: ?std.json.Parsed(Envelope) = null,
    salt: [32]u8 = @splat(0),
    // Mutable metadata lives in this arena; secret values never do.
    arena: std.heap.ArenaAllocator,
    pub fn init(a: std.mem.Allocator, directory: [:0]const u8) !Vault {
        if (p.mkdir(directory, 0o700) != 0 and p.__errno_location().* != p.EEXIST) return error.CreateDirectory;
        var st: p.struct_stat = undefined;
        if (p.lstat(directory, &st) != 0 or st.st_uid != p.getuid() or st.st_mode & p.S_IFMT != p.S_IFDIR or st.st_mode & 0o077 != 0) return error.UnsafeDirectory;
        const lock_path = try std.fmt.allocPrintSentinel(a, "{s}/lock", .{directory}, 0);
        defer a.free(lock_path);
        const lock_fd = p.open(lock_path, p.O_CREAT | p.O_RDWR | p.O_CLOEXEC | p.O_NOFOLLOW, @as(c_uint, 0o600));
        if (lock_fd < 0) return error.LockVault;
        var owns_lock = true;
        errdefer if (owns_lock) {
            _ = p.close(lock_fd);
        };
        if (p.fstat(lock_fd, &st) != 0 or st.st_uid != p.getuid() or st.st_mode & p.S_IFMT != p.S_IFREG or st.st_mode & 0o077 != 0) return error.UnsafeVault;
        if (p.flock(lock_fd, p.LOCK_EX | p.LOCK_NB) != 0) return error.VaultInUse;
        var result = Vault{ .a = a, .directory = directory, .lock_fd = lock_fd, .arena = .init(a) };
        owns_lock = false;
        errdefer result.deinit();
        const path = try std.fmt.allocPrintSentinel(a, "{s}/vault.json", .{directory}, 0);
        defer a.free(path);
        const fd = p.open(path, p.O_RDONLY | p.O_CLOEXEC | p.O_NOFOLLOW, @as(c_uint, 0));
        if (fd < 0) {
            if (p.__errno_location().* == p.ENOENT) return result;
            return error.ReadVault;
        }
        defer _ = p.close(fd);
        if (p.fstat(fd, &st) != 0 or st.st_uid != p.getuid() or st.st_mode & p.S_IFMT != p.S_IFREG or st.st_mode & 0o077 != 0 or st.st_size < 0 or st.st_size > 16 * 1024 * 1024) return error.UnsafeVault;
        const bytes = try a.alloc(u8, @intCast(st.st_size));
        defer a.free(bytes);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const n = p.read(fd, bytes[offset..].ptr, bytes.len - offset);
            if (n < 0 and p.__errno_location().* == p.EINTR) continue;
            if (n <= 0) return error.ReadVault;
            offset += @intCast(n);
        }
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
        if (self.lock_fd >= 0) _ = p.close(self.lock_fd);
    }
    pub fn lock(self: *Vault) void {
        if (self.key) |*key| wipe(key);
        self.key = null;
        _ = p.munlock(&self.key, @sizeOf(@TypeOf(self.key)));
        for (self.values) |v| {
            wipe(@constCast(v.bytes));
            if (v.bytes.len != 0) _ = p.munlock(v.bytes.ptr, v.bytes.len);
            self.a.free(v.bytes);
            self.a.free(v.content_type);
        }
        if (self.values.len != 0) self.a.free(self.values);
        self.values = &.{};
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
        if (self.envelope == null) try random(&self.salt);
        var key: [32]u8 = undefined;
        defer wipe(&key);
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
        if (p.mlock(&self.key, @sizeOf(@TypeOf(self.key))) != 0) return error.MemoryLockFailed;
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
        defer wipe(&key);
        const aad = try std.json.Stringify.valueAlloc(self.a, self.index, .{});
        defer self.a.free(aad);
        const plain = try std.json.Stringify.valueAlloc(self.a, self.values, .{});
        defer self.a.free(plain);
        const cipher = try self.a.alloc(u8, plain.len);
        defer self.a.free(cipher);
        var env = Envelope{ .salt = self.salt, .nonce = undefined, .tag = undefined, .index = self.index, .ciphertext = cipher };
        try random(&env.nonce);
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
        if (g_file_set_contents_full(path, bytes.ptr, @intCast(bytes.len), 3, 0o600, null) == 0) return error.WriteVault;
        if (self.envelope) |*old| old.deinit();
        self.envelope = parsed;
        self.arena.deinit();
        self.arena = next_arena;
        self.index = next_index;
    }
    pub fn value(self: *Vault, id: u64) ?Value {
        for (self.values) |v| {
            if (v.id == id) return v;
        }
        return null;
    }
    pub fn setValue(self: *Vault, id: u64, bytes: []const u8, content_type: [:0]const u8) !void {
        if (self.key == null) return error.IsLocked;
        const data = try self.a.dupe(u8, bytes);
        errdefer self.a.free(data);
        if (data.len != 0 and p.mlock(data.ptr, data.len) != 0) return error.MemoryLockFailed;
        errdefer if (data.len != 0) {
            wipe(data);
            _ = p.munlock(data.ptr, data.len);
        };
        const kind = try self.a.dupeSentinel(u8, content_type, 0);
        errdefer self.a.free(kind);
        for (@constCast(self.values)) |*v| {
            if (v.id == id) {
                wipe(@constCast(v.bytes));
                if (v.bytes.len != 0) _ = p.munlock(v.bytes.ptr, v.bytes.len);
                self.a.free(v.bytes);
                self.a.free(v.content_type);
                v.* = .{ .id = id, .bytes = data, .content_type = kind };
                return;
            }
        }
        const values = try self.a.alloc(Value, self.values.len + 1);
        @memcpy(values[0..self.values.len], self.values);
        values[self.values.len] = .{ .id = id, .bytes = data, .content_type = kind };
        if (self.values.len != 0) self.a.free(self.values);
        self.values = values;
    }
    pub fn removeValue(self: *Vault, id: u64) !void {
        for (self.values, 0..) |v, i| {
            if (v.id == id) {
                const values = try self.a.alloc(Value, self.values.len - 1);
                @memcpy(values[0..i], self.values[0..i]);
                @memcpy(values[i..], self.values[i + 1 ..]);
                wipe(@constCast(v.bytes));
                if (v.bytes.len != 0) _ = p.munlock(v.bytes.ptr, v.bytes.len);
                self.a.free(v.bytes);
                self.a.free(v.content_type);
                self.a.free(self.values);
                self.values = values;
                return;
            }
        }
    }
    pub fn restore(self: *Vault) !void {
        const was_unlocked = self.key != null;
        var key = self.key;
        defer if (key) |*k| wipe(k);
        self.lock();
        self.arena.deinit();
        self.arena = .init(self.a);
        self.index = if (self.envelope) |env| try self.cloneIndex(env.value.index) else .{};
        if (!was_unlocked) return;
        if (self.envelope != null) try self.loadKey(key.?);
    }
};
extern fn g_file_set_contents_full([*:0]const u8, [*]const u8, isize, c_int, c_int, ?*anyopaque) c_int;

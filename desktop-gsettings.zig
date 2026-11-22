//! Native GSettings: compiled schemas and dconf databases are read directly,
//! writes go to the dconf service over D-Bus, and its change notifications are
//! delivered to watchers. `GSETTINGS_BACKEND=memory` keeps values in-process,
//! as GLib's memory backend does for tests.
//!
//! Reads are safe from any thread; watching and writing belong to the main loop.
const std = @import("std");
const dbus = @import("dbus");
const gvdb = @import("desktop-gvdb.zig");
const gvariant = @import("desktop-gvariant.zig");
const Value = dbus.Value;

const writer_name = "ca.desrt.dconf";
const writer_interface = "ca.desrt.dconf.Writer";

pub const Handler = *const fn (context: ?*anyopaque, key: []const u8) void;

/// A schema from a compiled schema file.
const Schema = struct {
    table: gvdb.Table,
    path: ?[]const u8,
};
const Database = struct {
    path: []const u8,
    file: ?gvdb.File = null,
    user: bool = false,
};

const Backend = enum { dconf, memory, keyfile };

/// Process-wide state, guarded by `mutex`.
const Store = struct {
    arena: std.heap.ArenaAllocator = undefined,
    loaded: bool = false,
    backend: Backend = .dconf,
    /// The keyfile backend's values as GVariant text by path, from `keyfile_arena`.
    keyfile: std.StringHashMapUnmanaged([]const u8) = .empty,
    keyfile_arena: std.heap.ArenaAllocator = undefined,
    keyfile_path: []const u8 = "",
    keyfile_watch: c_uint = 0,
    keyfile_fd: c_int = -1,
    /// Compiled schema files, highest priority first.
    sources: std.ArrayList(gvdb.File) = .empty,
    databases: std.ArrayList(Database) = .empty,
    /// The dconf database written through the service (`user-db:NAME`), if any.
    writable: ?[]const u8 = null,
    /// Values written in this process: the memory backend's values, or dconf writes not yet confirmed.
    values: std.StringHashMapUnmanaged(?Value) = .empty,
    watchers: std.ArrayList(*Settings) = .empty,
    bus: ?*@import("desktop-dbus-loop.zig").Source = null,
    subscription: u32 = 0,
    write_cancel: ?*@import("desktop-glib.zig").GCancellable = null,
    pending_writes: usize = 0,
};
var mutex: Mutex = .{};
var store: Store = .{};

/// Releases the process-wide settings cache after all settings handles close.
pub fn deinit() void {
    const glib = @import("desktop-glib.zig");
    if (store.write_cancel) |cancel| {
        glib.g_cancellable_cancel(cancel);
        while (store.pending_writes != 0) _ = glib.g_main_context_iteration(null, 1);
        glib.g_object_unref(cancel);
    }
    mutex.lock();
    defer mutex.unlock();
    if (!store.loaded) return;
    if (store.keyfile_watch != 0) _ = glib.g_source_remove(store.keyfile_watch);
    if (store.keyfile_fd >= 0) _ = std.c.close(store.keyfile_fd);
    if (store.bus) |bus| {
        if (store.subscription != 0) bus.connection.unsubscribe(store.subscription);
        @import("desktop-dbus-loop.zig").release(bus);
    }
    for (store.databases.items) |database| if (database.file) |file| file.close();
    for (store.sources.items) |file| file.close();
    store.keyfile_arena.deinit();
    store.arena.deinit();
    store = .{};
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |value| std.mem.span(value) else null;
}

/// Loads the schema sources and the dconf profile once. Call with the mutex held.
fn load(allocator: std.mem.Allocator) void {
    if (store.loaded) return;
    store.loaded = true;
    store.arena = .init(allocator);
    store.keyfile_arena = .init(allocator);
    const a = store.arena.allocator();
    const backend = getenv("GSETTINGS_BACKEND") orelse "";
    store.backend = if (std.mem.eql(u8, backend, "memory")) .memory else if (std.mem.eql(u8, backend, "keyfile")) .keyfile else .dconf;
    // Schema directories in GLib's order: GSETTINGS_SCHEMA_DIR, the user's data, then system data.
    var directories: std.ArrayList([]const u8) = .empty;
    if (getenv("GSETTINGS_SCHEMA_DIR")) |value| {
        var parts = std.mem.tokenizeScalar(u8, value, ':');
        while (parts.next()) |part| directories.append(a, part) catch {};
    }
    const home = getenv("HOME") orelse "/";
    const data_home = getenv("XDG_DATA_HOME") orelse std.fmt.allocPrint(a, "{s}/.local/share", .{home}) catch "";
    directories.append(a, std.fmt.allocPrint(a, "{s}/glib-2.0/schemas", .{data_home}) catch "") catch {};
    var data = std.mem.tokenizeScalar(u8, getenv("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share", ':');
    while (data.next()) |part| directories.append(a, std.fmt.allocPrint(a, "{s}/glib-2.0/schemas", .{part}) catch "") catch {};
    for (directories.items) |directory| {
        const path = std.fmt.allocPrint(a, "{s}/gschemas.compiled", .{directory}) catch continue;
        const file = (gvdb.File.open(allocator, path) catch continue) orelse continue;
        store.sources.append(a, file) catch file.close();
    }
    switch (store.backend) {
        .dconf => loadProfile(a),
        .keyfile => {
            const config = getenv("XDG_CONFIG_HOME") orelse std.fmt.allocPrint(a, "{s}/.config", .{getenv("HOME") orelse "/"}) catch "";
            store.keyfile_path = std.fmt.allocPrint(a, "{s}/glib-2.0/settings/keyfile", .{config}) catch "";
            loadKeyfile();
        },
        .memory => {},
    }
}
/// Reads the dconf profile: a list of `user-db:`, `system-db:` and `file-db:` databases.
fn loadProfile(a: std.mem.Allocator) void {
    const config = getenv("XDG_CONFIG_HOME") orelse std.fmt.allocPrint(a, "{s}/.config", .{getenv("HOME") orelse "/"}) catch "";
    const name = getenv("DCONF_PROFILE") orelse "user";
    const profile_path = if (std.mem.startsWith(u8, name, "/")) name else std.fmt.allocPrint(a, "/etc/dconf/profile/{s}", .{name}) catch return;
    const owned = @import("desktop-decode.zig").read(store.arena.child_allocator, profile_path);
    defer if (owned) |contents| store.arena.child_allocator.free(contents);
    const contents = owned orelse "user-db:user";
    var lines = std.mem.tokenizeScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len], " \t\r");
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const kind = line[0..colon];
        const value = line[colon + 1 ..];
        const database: Database = if (std.mem.eql(u8, kind, "user-db")) blk: {
            if (store.writable == null and store.databases.items.len == 0) store.writable = a.dupe(u8, value) catch null;
            break :blk .{ .path = std.fmt.allocPrint(a, "{s}/dconf/{s}", .{ config, value }) catch continue, .user = true };
        } else if (std.mem.eql(u8, kind, "system-db"))
            .{ .path = std.fmt.allocPrint(a, "/etc/dconf/db/{s}", .{value}) catch continue }
        else if (std.mem.eql(u8, kind, "file-db"))
            .{ .path = a.dupe(u8, value) catch continue }
        else
            continue;
        store.databases.append(a, database) catch {};
    }
    reloadDatabases();
}
fn reloadDatabases() void {
    for (store.databases.items) |*database| {
        if (database.file) |file| file.close();
        database.file = gvdb.File.open(store.arena.child_allocator, database.path) catch null;
    }
}

/// GLib's keyfile backend: one `[group]` per settings path, values in GVariant text.
/// Call with the mutex held.
fn loadKeyfile() void {
    store.keyfile = .empty;
    _ = store.keyfile_arena.reset(.free_all);
    const a = store.keyfile_arena.allocator();
    const contents = @import("desktop-decode.zig").read(store.arena.child_allocator, store.keyfile_path) orelse return;
    defer store.arena.child_allocator.free(contents);
    var group: []const u8 = "";
    var lines = std.mem.tokenizeScalar(u8, contents, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            group = line[1 .. line.len - 1];
            continue;
        }
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..equals], " \t");
        const path = std.fmt.allocPrint(a, "/{s}/{s}", .{ group, key }) catch continue;
        store.keyfile.put(a, path, a.dupe(u8, std.mem.trim(u8, line[equals + 1 ..], " \t")) catch continue) catch {};
    }
}
/// Rewrites the keyfile with one value changed, atomically like g_file_set_contents.
fn writeKeyfile(path: []const u8, value: Value) !void {
    mutex.lock();
    defer mutex.unlock();
    const a = store.keyfile_arena.allocator();
    const text = try @import("desktop-dbus-text.zig").print(a, value);
    const owned = if (store.keyfile.getKey(path)) |existing| existing else try a.dupe(u8, path);
    try store.keyfile.put(a, owned, text);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(store.arena.child_allocator);
    // Group the values by settings path.
    var groups: std.StringArrayHashMapUnmanaged(std.ArrayList(u8)) = .empty;
    defer {
        for (groups.values()) |*lines| lines.deinit(store.arena.child_allocator);
        groups.deinit(store.arena.child_allocator);
    }
    var it = store.keyfile.iterator();
    while (it.next()) |entry| {
        const full = entry.key_ptr.*;
        const slash = std.mem.lastIndexOfScalar(u8, full, '/') orelse continue;
        if (slash == 0) continue;
        const result = try groups.getOrPut(store.arena.child_allocator, full[1..slash]);
        if (!result.found_existing) result.value_ptr.* = .empty;
        try result.value_ptr.print(store.arena.child_allocator, "{s}={s}\n", .{ full[slash + 1 ..], entry.value_ptr.* });
    }
    for (groups.keys(), groups.values(), 0..) |group, lines, i| {
        if (i > 0) try out.append(store.arena.child_allocator, '\n');
        try out.print(store.arena.child_allocator, "[{s}]\n", .{group});
        try out.appendSlice(store.arena.child_allocator, lines.items);
    }
    const paths = @import("desktop-paths.zig");
    const directory = std.fs.path.dirname(store.keyfile_path) orelse return error.InvalidPath;
    try paths.makeDirectories(directory, 0o700);
    const prefix = try std.fmt.allocPrint(store.arena.child_allocator, "{s}.", .{store.keyfile_path});
    defer store.arena.child_allocator.free(prefix);
    const temporary = try paths.createTemporary(store.arena.child_allocator, prefix);
    defer store.arena.child_allocator.free(temporary.path);
    var written: usize = 0;
    while (written < out.items.len) {
        const count = std.c.write(temporary.fd, out.items[written..].ptr, out.items.len - written);
        if (count <= 0) {
            _ = std.c.close(temporary.fd);
            _ = std.c.unlink(temporary.path);
            return error.WriteFailed;
        }
        written += @intCast(count);
    }
    _ = std.c.fsync(temporary.fd);
    _ = std.c.close(temporary.fd);
    const target = try store.arena.child_allocator.dupeSentinel(u8, store.keyfile_path, 0);
    defer store.arena.child_allocator.free(target);
    if (std.c.rename(temporary.path, target) != 0) {
        _ = std.c.unlink(temporary.path);
        return error.WriteFailed;
    }
}
/// Watches the keyfile's directory and reports keys whose text changed.
fn watchKeyfile() void {
    const linux = std.os.linux;
    const directory = std.fs.path.dirname(store.keyfile_path) orelse return;
    @import("desktop-paths.zig").makeDirectories(directory, 0o700) catch return;
    const fd: i32 = @intCast(linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK));
    if (fd < 0) return;
    const name = store.arena.child_allocator.dupeSentinel(u8, directory, 0) catch {
        _ = std.c.close(fd);
        return;
    };
    defer store.arena.child_allocator.free(name);
    if (@as(isize, @bitCast(linux.inotify_add_watch(fd, name, linux.IN.CLOSE_WRITE | linux.IN.MOVED_TO | linux.IN.DELETE | linux.IN.CREATE))) < 0) {
        _ = std.c.close(fd);
        return;
    }
    const glib = @import("desktop-glib.zig");
    store.keyfile_watch = glib.g_unix_fd_add(fd, glib.G_IO_IN, &keyfileChanged, null);
    if (store.keyfile_watch == 0) {
        _ = std.c.close(fd);
    } else {
        store.keyfile_fd = fd;
    }
}
fn keyfileChanged(fd: c_int, _: @import("desktop-glib.zig").GIOCondition, _: ?*anyopaque) callconv(.c) c_int {
    var buffer: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
    while (std.c.read(fd, &buffer, buffer.len) > 0) {}
    var arena: std.heap.ArenaAllocator = .init(store.arena.child_allocator);
    defer arena.deinit();
    var changed_paths: std.ArrayList([]const u8) = .empty;
    {
        mutex.lock();
        defer mutex.unlock();
        var previous: std.StringHashMapUnmanaged([]const u8) = .empty;
        var it = store.keyfile.iterator();
        while (it.next()) |entry| previous.put(arena.allocator(), arena.allocator().dupe(u8, entry.key_ptr.*) catch continue, arena.allocator().dupe(u8, entry.value_ptr.*) catch continue) catch {};
        loadKeyfile();
        var current = store.keyfile.iterator();
        while (current.next()) |entry| {
            const old = previous.get(entry.key_ptr.*);
            if (old == null or !std.mem.eql(u8, old.?, entry.value_ptr.*)) changed_paths.append(arena.allocator(), arena.allocator().dupe(u8, entry.key_ptr.*) catch continue) catch {};
        }
        var old_it = previous.iterator();
        while (old_it.next()) |entry| if (!store.keyfile.contains(entry.key_ptr.*)) changed_paths.append(arena.allocator(), entry.key_ptr.*) catch {};
    }
    for (changed_paths.items) |path| notify(path);
    return 1;
}
fn findSchema(id: []const u8) ?Schema {
    for (store.sources.items) |file| {
        const root = file.root() catch continue;
        const table = (root.table(id) catch continue) orelse continue;
        var buffer: [4096]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
        const path: ?[]const u8 = if (table.value(fixed.allocator(), ".path") catch null) |value| switch (value) {
            .string => |text| store.arena.allocator().dupe(u8, text) catch null,
            else => null,
        } else null;
        return .{ .table = table, .path = path };
    }
    return null;
}
/// Whether `path` is locked by a system database.
fn locked(arena: std.mem.Allocator, path: []const u8) bool {
    for (store.databases.items) |database| {
        if (database.user) continue;
        const file = database.file orelse continue;
        const locks = ((file.root() catch continue).table(".locks") catch continue) orelse continue;
        if ((locks.value(arena, path) catch null) != null) return true;
    }
    return false;
}
/// The stored value at a dconf `path`, from this process's writes or the databases.
fn stored(arena: std.mem.Allocator, path: []const u8, signature: []const u8) ?Value {
    if (store.values.get(path)) |value| return value;
    switch (store.backend) {
        .memory => return null,
        .keyfile => {
            const text = store.keyfile.get(path) orelse return null;
            return @import("desktop-dbus-text.zig").parse(arena, signature, text) catch null;
        },
        .dconf => {},
    }
    const skip_user = locked(arena, path);
    for (store.databases.items) |database| {
        if (database.user and skip_user) continue;
        const file = database.file orelse continue;
        const root = file.root() catch continue;
        if (root.value(arena, path) catch null) |value| return value;
    }
    return null;
}

pub const Settings = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    schema: Schema,
    path: []const u8,
    handler: ?Handler = null,
    context: ?*anyopaque = null,

    /// Opens an installed schema; with `required_key`, only if it has that key.
    /// The first allocator also backs the shared cache and must outlive it.
    pub fn open(allocator: std.mem.Allocator, id: []const u8, required_key: ?[]const u8) ?*Settings {
        mutex.lock();
        defer mutex.unlock();
        load(allocator);
        const schema = findSchema(id) orelse return null;
        // Relocatable schemas need a path, which no caller supplies.
        const path = schema.path orelse return null;
        const self = allocator.create(Settings) catch return null;
        self.* = .{ .allocator = allocator, .id = id, .schema = schema, .path = path };
        if (required_key) |key| if (!self.hasKeyLocked(key)) {
            allocator.destroy(self);
            return null;
        };
        return self;
    }
    pub fn close(self: *Settings) void {
        self.unwatch();
        self.allocator.destroy(self);
    }
    fn hasKeyLocked(self: *Settings, key: []const u8) bool {
        if (key.len == 0 or key[0] == '.') return false;
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        return (self.schema.table.value(scratch.allocator(), key) catch null) != null;
    }
    pub fn hasKey(self: *Settings, key: []const u8) bool {
        mutex.lock();
        defer mutex.unlock();
        return self.hasKeyLocked(key);
    }
    /// The schema's keys, allocated from `arena`.
    pub fn keys(self: *Settings, arena: std.mem.Allocator) ![]const []const u8 {
        mutex.lock();
        defer mutex.unlock();
        var out: std.ArrayList([]const u8) = .empty;
        for (try self.schema.table.names(arena)) |name| {
            if (name.len > 0 and name[0] != '.') try out.append(arena, name);
        }
        return out.items;
    }
    /// The key's schema information: a tuple of the default and `(y*)` annotations.
    fn info(self: *Settings, arena: std.mem.Allocator, key: []const u8) ?[]const Value {
        const value = (self.schema.table.value(arena, key) catch return null) orelse return null;
        return switch (value) {
            .structure => |fields| fields,
            else => null,
        };
    }
    /// The key's current value, allocated from `arena`; null for unknown keys.
    pub fn get(self: *Settings, arena: std.mem.Allocator, key: []const u8) ?Value {
        mutex.lock();
        defer mutex.unlock();
        return self.getLocked(arena, key);
    }
    /// Schema and database decoding uses a private arena, so `arena` only has to
    /// hold the returned value.
    fn getLocked(self: *Settings, arena: std.mem.Allocator, key: []const u8) ?Value {
        var scratch: std.heap.ArenaAllocator = .init(self.allocator);
        defer scratch.deinit();
        const temporary = scratch.allocator();
        const fields = self.info(temporary, key) orelse return null;
        const default = fields[0];
        const value = blk: {
            const path = std.fmt.allocPrint(temporary, "{s}{s}", .{ self.path, key }) catch break :blk default;
            var signature_buffer: [256]u8 = undefined;
            const found = stored(temporary, path, default.signatureInto(&signature_buffer) catch break :blk default) orelse break :blk default;
            // A stored value of the wrong type is ignored, as GLib does.
            var expected: [256]u8 = undefined;
            var actual: [256]u8 = undefined;
            const want = default.signatureInto(&expected) catch break :blk default;
            const have = found.signatureInto(&actual) catch break :blk default;
            break :blk if (std.mem.eql(u8, want, have)) found else default;
        };
        return value.clone(arena) catch null;
    }
    pub fn boolean(self: *Settings, key: []const u8) bool {
        var buffer: [4096]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
        return switch (self.get(fixed.allocator(), key) orelse return false) {
            .boolean => |value| value,
            else => false,
        };
    }
    /// The string value, allocated from `arena`, or "" when unset or not a string.
    pub fn string(self: *Settings, arena: std.mem.Allocator, key: []const u8) []const u8 {
        return switch (self.get(arena, key) orelse return "") {
            .string => |value| value,
            else => "",
        };
    }
    pub fn strings(self: *Settings, arena: std.mem.Allocator, key: []const u8) []const []const u8 {
        const items = switch (self.get(arena, key) orelse return &.{}) {
            .array => |array| if (std.mem.eql(u8, array.element, "s")) array.items else return &.{},
            else => return &.{},
        };
        const out = arena.alloc([]const u8, items.len) catch return &.{};
        for (out, items) |*item, value| item.* = value.string;
        return out;
    }
    /// An enum key's value as its number from the schema's enum definition.
    pub fn enumeration(self: *Settings, key: []const u8) i32 {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const fields = blk: {
            mutex.lock();
            defer mutex.unlock();
            break :blk self.info(arena.allocator(), key) orelse return 0;
        };
        const nick = switch (self.get(arena.allocator(), key) orelse return 0) {
            .string => |value| value,
            else => return 0,
        };
        for (fields[1..]) |field| {
            if (field != .structure or field.structure.len != 2 or field.structure[0] != .byte or field.structure[0].byte != 'e') continue;
            return enumNumber(field.structure[1], nick) orelse 0;
        }
        return 0;
    }
    pub fn setBoolean(self: *Settings, key: []const u8, value: bool) !void {
        return self.set(key, .{ .boolean = value });
    }
    pub fn setString(self: *Settings, key: []const u8, value: []const u8) !void {
        return self.set(key, .{ .string = value });
    }
    /// Writes a value: in memory, or through the dconf service. Watchers are told at once.
    pub fn set(self: *Settings, key: []const u8, value: Value) !void {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const path = try std.fmt.allocPrint(arena.allocator(), "{s}{s}", .{ self.path, key });
        {
            mutex.lock();
            defer mutex.unlock();
            const fields = self.info(arena.allocator(), key) orelse return error.UnknownKey;
            var expected: [256]u8 = undefined;
            var actual: [256]u8 = undefined;
            if (!std.mem.eql(u8, try fields[0].signatureInto(&expected), try value.signatureInto(&actual))) return error.WrongType;
            // The keyfile is the source of truth; other backends keep the value here.
            if (store.backend != .keyfile) {
                const a = store.arena.allocator();
                const owned_path = if (store.values.getKey(path)) |existing| existing else try a.dupe(u8, path);
                try store.values.put(a, owned_path, try value.clone(a));
            }
        }
        switch (store.backend) {
            .dconf => try writeDconf(self.allocator, arena.allocator(), path, value),
            .keyfile => try writeKeyfile(path, value),
            .memory => {},
        }
        notify(path);
    }
    /// Calls `handler` with each changed key, from the main loop.
    pub fn watch(self: *Settings, handler: Handler, context: ?*anyopaque) !void {
        self.handler = handler;
        self.context = context;
        mutex.lock();
        defer mutex.unlock();
        try store.watchers.append(store.arena.allocator(), self);
        switch (store.backend) {
            .dconf => if (store.bus == null) subscribe(),
            .keyfile => if (store.keyfile_watch == 0) watchKeyfile(),
            .memory => {},
        }
    }
    fn unwatch(self: *Settings) void {
        mutex.lock();
        defer mutex.unlock();
        for (store.watchers.items, 0..) |item, i| if (item == self) {
            _ = store.watchers.swapRemove(i);
            break;
        };
    }
};

/// Looks a nick up in an enum's string table (`au`): each entry is a value word
/// followed by 0xff, the nick, and NUL padding up to a word ending in 0xff.
fn enumNumber(table: Value, nick: []const u8) ?i32 {
    const words = switch (table) {
        .array => |array| array.items,
        else => return null,
    };
    var i: usize = 0;
    while (i + 1 < words.len) {
        const number = words[i].uint32;
        i += 1;
        var name: [256]u8 = undefined;
        var length: usize = 0;
        var done = false;
        while (i < words.len and !done) : (i += 1) {
            const bytes = std.mem.asBytes(&std.mem.nativeToLittle(u32, words[i].uint32));
            for (bytes, 0..) |byte, index| {
                if (index == 3 and byte == 0xff) done = true;
                if (byte == 0 or byte == 0xff or byte == 0xfe or length == name.len) continue;
                name[length] = byte;
                length += 1;
            }
        }
        if (std.mem.eql(u8, name[0..length], nick)) return @bitCast(number);
    }
    return null;
}

fn writeDconf(allocator: std.mem.Allocator, arena: std.mem.Allocator, path: []const u8, value: Value) !void {
    const database = store.writable orelse return error.ReadOnly;
    const loop = @import("desktop-dbus-loop.zig");
    const changeset = try gvariant.encodeChangeset(arena, &.{.{ .key = path, .value = value }});
    const object = try std.fmt.allocPrint(arena, "/ca/desrt/dconf/Writer/{s}", .{database});
    if (store.write_cancel == null) store.write_cancel = @import("desktop-glib.zig").g_cancellable_new();
    store.pending_writes += 1;
    loop.request(allocator, .session, .{ .destination = writer_name, .path = object, .interface = writer_interface, .member = "Change" }, .{dbus.Bytes{ .value = changeset }}, 25000, store.write_cancel, &writeFinished, null);
}
fn writeFinished(_: ?*anyopaque, reply: dbus.Reply) void {
    store.pending_writes -= 1;
    switch (reply) {
        .ok => {},
        .failed => |failure| if (!std.mem.eql(u8, failure.name, "Cancelled")) {
            std.log.warn("gsettings: dconf write failed: {s}: {s}", .{ failure.name, failure.text });
        },
    }
}
fn subscribe() void {
    const loop = @import("desktop-dbus-loop.zig");
    const bus = loop.acquire(store.arena.child_allocator, .session) catch return;
    store.bus = bus;
    store.subscription = bus.connection.subscribe(null, writer_interface, "Notify", null, &changed, null) catch 0;
}
/// dconf's Notify(prefix, changes, tag): the database changed below `prefix`.
fn changed(_: ?*anyopaque, message: *const dbus.Message) void {
    const args = message.read(struct { []const u8, []const []const u8, []const u8 }) catch return;
    {
        mutex.lock();
        defer mutex.unlock();
        reloadDatabases();
    }
    if (args[1].len == 0) return notify(args[0]);
    var buffer: [4096]u8 = undefined;
    for (args[1]) |change| {
        const path = std.fmt.bufPrint(&buffer, "{s}{s}", .{ args[0], change }) catch continue;
        {
            // The database now holds what this process wrote.
            mutex.lock();
            defer mutex.unlock();
            _ = store.values.remove(path);
        }
        notify(path);
    }
}
/// Tells watchers about a changed path; a path ending in '/' covers everything below it.
fn notify(path: []const u8) void {
    var arena: std.heap.ArenaAllocator = .init(store.arena.child_allocator);
    defer arena.deinit();
    const Call = struct { settings: *Settings, key: []const u8 };
    var calls: std.ArrayList(Call) = .empty;
    {
        mutex.lock();
        defer mutex.unlock();
        for (store.watchers.items) |settings| {
            if (std.mem.endsWith(u8, path, "/")) {
                if (!std.mem.startsWith(u8, settings.path, path) and !std.mem.startsWith(u8, path, settings.path)) continue;
                for (settings.schema.table.names(arena.allocator()) catch continue) |key| {
                    if (key.len == 0 or key[0] == '.') continue;
                    const full = std.fmt.allocPrint(arena.allocator(), "{s}{s}", .{ settings.path, key }) catch continue;
                    if (std.mem.startsWith(u8, full, path)) calls.append(arena.allocator(), .{ .settings = settings, .key = key }) catch {};
                }
            } else if (std.mem.startsWith(u8, path, settings.path) and std.mem.indexOfScalar(u8, path[settings.path.len..], '/') == null) {
                const key = path[settings.path.len..];
                if (settings.hasKeyLocked(key)) calls.append(arena.allocator(), .{ .settings = settings, .key = arena.allocator().dupe(u8, key) catch continue }) catch {};
            }
        }
    }
    // Handlers run unlocked; they may read settings or close their watcher.
    for (calls.items) |call| {
        const still_watching = blk: {
            mutex.lock();
            defer mutex.unlock();
            for (store.watchers.items) |item| if (item == call.settings) break :blk true;
            break :blk false;
        };
        if (still_watching) if (call.settings.handler) |handler| handler(call.settings.context, call.key);
    }
}

test "settings read schema defaults and keep memory-backend writes" {
    defer deinit();
    if (getenv("GSETTINGS_SCHEMA_DIR") == null) return error.SkipZigTest;
    if (!std.mem.eql(u8, getenv("GSETTINGS_BACKEND") orelse "", "memory")) return error.SkipZigTest;
    const settings = Settings.open(std.testing.allocator, "org.gnome.desktop.interface", "color-scheme") orelse return error.SkipZigTest;
    defer settings.close();
    try std.testing.expect(Settings.open(std.testing.allocator, "org.gnome.desktop.interface", "no-such-key") == null);
    try std.testing.expect(Settings.open(std.testing.allocator, "org.example.Missing", null) == null);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("default", settings.string(arena.allocator(), "color-scheme"));
    try std.testing.expectEqual(@as(i32, 0), settings.enumeration("color-scheme"));
    const Seen = struct {
        var key: [64]u8 = undefined;
        var length: usize = 0;
        fn changed(_: ?*anyopaque, name: []const u8) void {
            @memcpy(key[0..name.len], name);
            length = name.len;
        }
    };
    try settings.watch(&Seen.changed, null);
    try settings.setString("color-scheme", "prefer-dark");
    try std.testing.expectEqualStrings("color-scheme", Seen.key[0..Seen.length]);
    try std.testing.expectEqualStrings("prefer-dark", settings.string(arena.allocator(), "color-scheme"));
    try std.testing.expectEqual(@as(i32, 1), settings.enumeration("color-scheme"));
    try std.testing.expectError(error.WrongType, settings.setBoolean("color-scheme", true));
    try std.testing.expect((try settings.keys(arena.allocator())).len > 20);
}

/// A libc mutex: usable from any thread without a std.Io instance.
const Mutex = struct {
    inner: std.c.pthread_mutex_t = .{},
    fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }
    fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

test "dconf values match GLib" {
    defer deinit();
    // Runs against the real dconf databases when GLib would use them.
    // The write test below loads a throwaway profile; the store loads only once.
    if (getenv("DESKTOP_GSETTINGS_DCONF_TEST_PROFILE") != null) return error.SkipZigTest;
    if (getenv("GSETTINGS_BACKEND") != null) return error.SkipZigTest;
    const c = @import("tests/glib-oracle.zig");
    const g = struct {
        extern fn g_variant_print(*c.GVariant, c.gboolean) [*:0]u8;
    };
    const settings = Settings.open(std.testing.allocator, "org.gnome.desktop.interface", null) orelse return error.SkipZigTest;
    defer settings.close();
    const r = gvdb.reference;
    const source = r.g_settings_schema_source_get_default() orelse return error.SkipZigTest;
    const schema = r.g_settings_schema_source_lookup(source, "org.gnome.desktop.interface", 1) orelse return error.SkipZigTest;
    defer r.g_settings_schema_unref(schema);
    const reference = r.g_settings_new_full(schema, null, null);
    defer r.g_object_unref(reference);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = @import("desktop-dbus-text.zig");
    for (try settings.keys(a)) |key| {
        const expected = r.g_settings_get_value(reference, (try a.dupeSentinel(u8, key, 0)).ptr);
        defer c.g_variant_unref(expected);
        const printed = std.mem.span(g.g_variant_print(expected, 1));
        defer c.g_free(printed.ptr);
        const value = settings.get(a, key).?;
        var buffer: [256]u8 = undefined;
        const signature = try value.signatureInto(&buffer);
        std.testing.expectEqualStrings(try text.print(a, try text.parse(a, signature, printed)), try text.print(a, value)) catch |err| {
            std.debug.print("key {s}\n", .{key});
            return err;
        };
    }
    try std.testing.expectEqual(@as(i32, r.g_settings_get_enum(reference, "color-scheme")), settings.enumeration("color-scheme"));
}

test "settings opened twice share memory-backend writes" {
    defer deinit();
    if (getenv("GSETTINGS_SCHEMA_DIR") == null) return error.SkipZigTest;
    if (!std.mem.eql(u8, getenv("GSETTINGS_BACKEND") orelse "", "memory")) return error.SkipZigTest;
    const first = Settings.open(std.testing.allocator, "org.gnome.desktop.notifications", null) orelse return error.SkipZigTest;
    defer first.close();
    const second = Settings.open(std.testing.allocator, "org.gnome.desktop.notifications", null).?;
    defer second.close();
    const before = first.boolean("show-banners");
    try first.setBoolean("show-banners", !before);
    try std.testing.expectEqual(!before, second.boolean("show-banners"));
    try second.setBoolean("show-banners", before);
    try std.testing.expectEqual(before, first.boolean("show-banners"));
}

test "small result buffers only need to hold the value" {
    defer deinit();
    if (getenv("GSETTINGS_SCHEMA_DIR") == null) return error.SkipZigTest;
    const settings = Settings.open(std.testing.allocator, "org.gnome.desktop.interface", "color-scheme") orelse return error.SkipZigTest;
    defer settings.close();
    // The key's schema info, with its enum table, is far larger than this.
    var buffer: [64]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    try std.testing.expect(settings.string(fixed.allocator(), "color-scheme").len > 0);
}

test "dconf writes reach the database and notify watchers" {
    defer deinit();
    // Opt-in: needs a running dconf service. Point DCONF_PROFILE at a profile
    // whose user database is a throwaway one, never the real `user` database.
    const profile = getenv("DESKTOP_GSETTINGS_DCONF_TEST_PROFILE") orelse return error.SkipZigTest;
    if (getenv("GSETTINGS_BACKEND") != null) return error.SkipZigTest;
    _ = profile;
    const c = @import("desktop-glib.zig");
    const settings = Settings.open(std.testing.allocator, "org.gnome.desktop.interface", "color-scheme") orelse return error.SkipZigTest;
    defer settings.close();
    try std.testing.expect(store.writable != null and !std.mem.eql(u8, store.writable.?, "user"));
    const Seen = struct {
        var count: usize = 0;
        fn changed(_: ?*anyopaque, key: []const u8) void {
            if (std.mem.eql(u8, key, "color-scheme")) count += 1;
        }
    };
    try settings.watch(&Seen.changed, null);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const next = if (std.mem.eql(u8, settings.string(arena.allocator(), "color-scheme"), "prefer-dark")) "prefer-light" else "prefer-dark";
    try settings.setString("color-scheme", next);
    // Once immediately, again when dconf's Notify arrives.
    var tries: usize = 0;
    while (Seen.count < 2 and tries < 300) : (tries += 1) {
        _ = c.g_main_context_iteration(null, 0);
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(Seen.count >= 2);
    // The value now comes from the database file, not this process's pending write.
    {
        mutex.lock();
        defer mutex.unlock();
        try std.testing.expect(store.values.count() == 0);
    }
    try std.testing.expectEqualStrings(next, settings.string(arena.allocator(), "color-scheme"));
}

//! Native Secret Service. Bus sessions and prompts belong to their unique caller.
const std = @import("std");
const c = @import("desktop-glib.zig");
const p = @import("posix");
const dbus = @import("dbus");
const loop = @import("desktop-dbus-loop.zig");
const bridge = @import("desktop-dbus-gvariant.zig");
pub const store = @import("desktop-secrets-store.zig");
const transport = @import("desktop-secrets-transport.zig");
pub const Dialog = @import("desktop-auth-dialog.zig").Dialog;
const root = "/org/freedesktop/secrets";
const name = "org.freedesktop.secrets";
const prefix = "org.freedesktop.Secret.";
pub const Options = struct {
    prompt_ready: ?*const fn (*Dialog) void = null,
};
const Kind = enum { service, collection, item, session, prompt, login };
const Target = struct { kind: Kind, id: u64 };
fn iface(kind: Kind) [:0]const u8 {
    return switch (kind) {
        .service => prefix ++ "Service",
        .collection => prefix ++ "Collection",
        .item => prefix ++ "Item",
        .session => prefix ++ "Session",
        .prompt => prefix ++ "Prompt",
        .login => "org.dotfiles.Desktop.Secrets",
    };
}
const eq = c.__zig.eq;
const cast = c.__zig.cast;
const child = c.__zig.variant.child;
const str = c.__zig.variant.text;
fn text(v: ?*c.GVariant, i: usize) [:0]const u8 {
    const value = child(v, i);
    defer c.g_variant_unref(value);
    return str(value);
}
const build = c.__zig.variant.builder;
const bytes = c.__zig.variant.bytes;
const byteVariant = c.__zig.variant.byteArray;
fn stringVariant(value: [:0]const u8) *c.GVariant {
    return variantString(value.ptr).?;
}
fn now() u64 {
    return @intCast(@divTrunc(c.__zig.realTime(), 1000000));
}
fn append(comptime T: type, a: std.mem.Allocator, old: []const T, value: T) ![]const T {
    const out = try a.alloc(T, old.len + 1);
    @memcpy(out[0..old.len], old);
    out[old.len] = value;
    return out;
}
fn without(comptime T: type, a: std.mem.Allocator, old: []const T, id: u64) ![]const T {
    var out: std.ArrayList(T) = .empty;
    for (old) |value| {
        if (value.id != id) try out.append(a, value);
    }
    return out.toOwnedSlice(a);
}
const Object = struct {
    server: *Server,
    kind: Kind,
    id: u64 = 0,
    path: [:0]const u8,
    owner: [:0]const u8 = "",
    registration: u32 = 0,
    key: ?[16]u8 = null,
    dialog: ?*Dialog = null,
    started: bool = false,
    create: bool = false,
    label: [:0]const u8 = "",
    alias: [:0]const u8 = "",
    targets: []const Target = &.{},
};
const Server = struct {
    a: std.mem.Allocator,
    options: Options = .{},
    vault: store.Vault,
    bus: *dbus.Connection,
    introspection: dbus.Introspection,
    objects: std.ArrayList(*Object) = .empty,
    serial: u64 = 1,
    stopping: bool = false,
    screen_locked: bool = false,
    sleeping: bool = false,
    logind: ?[:0]const u8 = null,
    fn object(self: *Server, path: []const u8, kind: Kind) ?*Object {
        for (self.objects.items) |o| {
            if (o.kind == kind and eq(o.path, path)) return o;
        }
        return null;
    }
    fn collection(self: *Server, id: u64) ?*store.Collection {
        for (@constCast(self.vault.index.collections)) |*col| {
            if (col.id == id) return col;
        }
        return null;
    }
    fn findItem(self: *Server, id: u64) ?*store.Item {
        for (@constCast(self.vault.index.items)) |*item| {
            if (item.id == id) return item;
        }
        return null;
    }
    fn objectPath(self: *Server, kind: Kind, id: u64) [:0]const u8 {
        for (self.objects.items) |o| {
            if (o.kind == kind and o.id == id and !std.mem.startsWith(u8, o.path, root ++ "/aliases/")) return o.path;
        }
        return "/";
    }
    fn register(self: *Server, kind: Kind, id: u64, path: [:0]const u8, owner: [:0]const u8) !*Object {
        const o = try self.a.create(Object);
        errdefer self.a.destroy(o);
        const copy = try self.a.dupeSentinel(u8, path, 0);
        errdefer self.a.free(copy);
        const who = try self.a.dupeSentinel(u8, owner, 0);
        errdefer self.a.free(who);
        o.* = .{ .server = self, .kind = kind, .id = id, .path = copy, .owner = who };
        o.registration = self.bus.exportWritable(o.path, self.introspection.find(iface(kind)).?, &methodCall, &getProperty, &setProperty, o) catch 0;
        if (o.registration == 0) return error.RegistrationFailed;
        errdefer self.bus.unregister(o.registration);
        try self.objects.append(self.a, o);
        return o;
    }
    fn remove(self: *Server, o: *Object) void {
        if (o.dialog) |dialog| {
            dialog.destroy();
        }
        self.bus.unregister(o.registration);
        for (self.objects.items, 0..) |other, i| {
            if (other == o) {
                _ = self.objects.swapRemove(i);
                break;
            }
        }
        if (o.key) |*key| store.wipe(key);
        self.a.free(o.path);
        self.a.free(o.owner);
        if (o.label.len != 0) self.a.free(o.label);
        if (o.alias.len != 0) self.a.free(o.alias);
        if (o.targets.len != 0) self.a.free(o.targets);
        self.a.destroy(o);
    }
    fn reconcile(self: *Server) !void {
        var i: usize = 0;
        while (i < self.objects.items.len) {
            const o = self.objects.items[i];
            const missing = switch (o.kind) {
                .collection => self.collection(o.id) == null,
                .item => self.findItem(o.id) == null,
                else => false,
            };
            if (missing or (o.kind == .collection and std.mem.startsWith(u8, o.path, root ++ "/aliases/") and self.aliasId(o.path[(root ++ "/aliases/").len..]) != o.id)) self.remove(o) else i += 1;
        }
        for (self.vault.index.collections) |col| {
            if (eq(self.objectPath(.collection, col.id), "/")) {
                const path = try std.fmt.allocPrintSentinel(self.a, root ++ "/collection/c{d}", .{col.id}, 0);
                defer self.a.free(path);
                _ = try self.register(.collection, col.id, path, "");
            }
        }
        for (self.vault.index.items) |item| {
            if (eq(self.objectPath(.item, item.id), "/")) {
                const path = try std.fmt.allocPrintSentinel(self.a, "{s}/i{d}", .{ self.objectPath(.collection, item.collection), item.id }, 0);
                defer self.a.free(path);
                _ = try self.register(.item, item.id, path, "");
            }
        }
        for (self.vault.index.aliases) |alias| {
            const path = try std.fmt.allocPrintSentinel(self.a, root ++ "/aliases/{s}", .{alias.name}, 0);
            defer self.a.free(path);
            if (self.object(path, .collection) == null) _ = try self.register(.collection, alias.collection, path, "");
        }
    }
    fn signal(self: *Server, path: [:0]const u8, kind: Kind, member: [:0]const u8, target: [:0]const u8) void {
        self.bus.emit(path, iface(kind), member, .{dbus.ObjectPath{ .value = target }}) catch {};
    }
    fn changed(self: *Server) void {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        for (self.objects.items) |o| {
            if (o.kind != .collection and o.kind != .item and o.kind != .service) continue;
            _ = arena.reset(.retain_capacity);
            const names: []const [:0]const u8 = switch (o.kind) {
                .service => &.{"Collections"},
                .collection => &.{ "Items", "Label", "Locked", "Modified" },
                else => &.{ "Attributes", "Label", "Locked", "Modified" },
            };
            var entries: [4]bridge.Dict.Entry = undefined;
            var count: usize = 0;
            for (names) |prop| {
                const value = self.property(o, prop) orelse continue;
                entries[count] = .{ .key = prop, .value = bridge.fromVariant(arena.allocator(), value) catch continue };
                count += 1;
            }
            self.bus.emit(o.path, "org.freedesktop.DBus.Properties", "PropertiesChanged", .{ iface(o.kind), bridge.Dict{ .entries = entries[0..count] }, @as([]const []const u8, &.{}) }) catch {};
        }
    }
    fn lock(self: *Server) void {
        self.vault.lock();
        // A pending prompt must not unlock after a screen-lock event.
        var i: usize = 0;
        while (i < self.objects.items.len) {
            const o = self.objects.items[i];
            if (o.kind == .prompt) self.complete(o, true, c.g_variant_new("ao", @as(?*anyopaque, null)).?) else i += 1;
        }
        self.changed();
    }
    fn aliasId(self: *Server, alias: []const u8) u64 {
        for (self.vault.index.aliases) |v| {
            if (eq(v.name, alias)) return v.collection;
        }
        return 0;
    }
    fn setAlias(self: *Server, alias: [:0]const u8, id: u64) !void {
        if (alias.len == 0 or alias.len > 128) return error.InvalidArgs;
        for (alias) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '_') return error.InvalidArgs;
        }
        const a = self.vault.metadata();
        var out: std.ArrayList(store.Alias) = .empty;
        for (self.vault.index.aliases) |v| {
            if (!eq(v.name, alias)) try out.append(a, v);
        }
        if (id != 0) try out.append(a, .{ .name = try a.dupeSentinel(u8, alias, 0), .collection = id });
        self.vault.index.aliases = try out.toOwnedSlice(a);
    }
    fn createCollection(self: *Server, label: [:0]const u8, alias: [:0]const u8) !u64 {
        if (self.vault.key == null) return error.IsLocked;
        const existing = self.aliasId(alias);
        if (existing != 0) return existing;
        if (self.vault.index.collections.len >= 64) return error.LimitsExceeded;
        const a = self.vault.metadata();
        const id = self.vault.index.next_id;
        self.vault.index.next_id += 1;
        self.vault.index.collections = try append(store.Collection, a, self.vault.index.collections, .{ .id = id, .label = try a.dupeSentinel(u8, label, 0), .created = now(), .modified = now() });
        if (alias.len != 0) try self.setAlias(alias, id);
        try self.vault.save();
        try self.reconcile();
        self.signal(root, .service, "CollectionCreated", self.objectPath(.collection, id));
        self.changed();
        return id;
    }
    fn session(self: *Server, path: []const u8, owner: []const u8) !*Object {
        const o = self.object(path, .session) orelse return error.NoSession;
        if (!eq(o.owner, owner)) return error.NoSession;
        return o;
    }
    fn decode(self: *Server, secret: ?*c.GVariant, owner: []const u8, a: std.mem.Allocator) !struct { value: []const u8, content_type: [:0]const u8 } {
        const session_path = text(secret, 0);
        const s = try self.session(session_path, owner);
        const parameters = child(secret, 1);
        defer c.g_variant_unref(parameters);
        const value = child(secret, 2);
        defer c.g_variant_unref(value);
        if (bytes(value).len > 1024 * 1024) return error.LimitsExceeded;
        const data = if (s.key) |key| try transport.decode(a, key, bytes(parameters), bytes(value)) else blk: {
            if (bytes(parameters).len != 0) return error.InvalidArgs;
            break :blk try a.dupe(u8, bytes(value));
        };
        return .{ .value = data, .content_type = try a.dupeSentinel(u8, text(secret, 3), 0) };
    }
    fn encode(self: *Server, id: u64, s: *Object, a: std.mem.Allocator) !*c.GVariant {
        if (self.vault.key == null) return error.IsLocked;
        const v = self.vault.value(id) orelse return error.NoSuchObject;
        var iv: [16]u8 = undefined;
        const data = if (s.key) |key| blk: {
            try store.random(&iv);
            break :blk try transport.encode(a, key, iv, v.bytes);
        } else v.bytes;
        return c.g_variant_new("(o@ay@ays)", s.path.ptr, byteVariant(if (s.key != null) &iv else &.{}), byteVariant(data), v.content_type.ptr).?;
    }
    fn attributes(a: std.mem.Allocator, v: ?*c.GVariant) ![]const store.Attribute {
        if (c.g_variant_n_children(v) > 256) return error.LimitsExceeded;
        var out: std.ArrayList(store.Attribute) = .empty;
        for (0..c.g_variant_n_children(v)) |i| {
            const entry = child(v, i);
            defer c.g_variant_unref(entry);
            const key = text(entry, 0);
            const value = text(entry, 1);
            if (key.len > 4096 or value.len > 16384) return error.LimitsExceeded;
            for (out.items) |old| {
                if (eq(old.key, key)) return error.InvalidArgs;
            }
            try out.append(a, .{ .key = try a.dupeSentinel(u8, key, 0), .value = try a.dupeSentinel(u8, value, 0) });
        }
        return out.toOwnedSlice(a);
    }
    fn matches(item: store.Item, query: []const store.Attribute) bool {
        for (query) |q| {
            var found = false;
            for (item.attributes) |attr| {
                if (eq(q.key, attr.key) and eq(q.value, attr.value)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
        return true;
    }
    fn attrsVariant(attrs: []const store.Attribute) *c.GVariant {
        const dict = build("a{ss}");
        defer c.g_variant_builder_unref(dict);
        for (attrs) |attr| c.g_variant_builder_add(dict, "{ss}", attr.key.ptr, attr.value.ptr);
        return c.g_variant_builder_end(dict).?;
    }
    fn property(self: *Server, o: *Object, prop: []const u8) ?*c.GVariant {
        if (o.kind == .service and eq(prop, "Collections")) {
            const b = build("ao");
            defer c.g_variant_builder_unref(b);
            for (self.vault.index.collections) |col| c.g_variant_builder_add(b, "o", self.objectPath(.collection, col.id).ptr);
            return c.g_variant_builder_end(b);
        }
        const col = if (o.kind == .collection) self.collection(o.id) else null;
        const item = if (o.kind == .item) self.findItem(o.id) else null;
        if (col == null and item == null) return null;
        if (eq(prop, "Locked")) return variantBool(@intFromBool(self.vault.key == null));
        if (eq(prop, "Label")) return stringVariant(if (col) |v| v.label else item.?.label);
        if (eq(prop, "Created")) return variantUint(if (col) |v| v.created else item.?.created);
        if (eq(prop, "Modified")) return variantUint(if (col) |v| v.modified else item.?.modified);
        if (item != null and eq(prop, "Attributes")) return attrsVariant(item.?.attributes);
        if (col != null and eq(prop, "Items")) {
            const b = build("ao");
            defer c.g_variant_builder_unref(b);
            for (self.vault.index.items) |v| {
                if (v.collection == o.id) c.g_variant_builder_add(b, "o", self.objectPath(.item, v.id).ptr);
            }
            return c.g_variant_builder_end(b);
        }
        return null;
    }
    fn newPrompt(self: *Server, owner: [:0]const u8, create: bool, label: [:0]const u8, alias: [:0]const u8, targets: []const Target) !*Object {
        var count: usize = 0;
        for (self.objects.items) |o| {
            if (o.kind == .prompt) count += 1;
        }
        if (count >= 16) return error.LimitsExceeded;
        const path = try std.fmt.allocPrintSentinel(self.a, root ++ "/prompt/p{d}", .{self.serial}, 0);
        defer self.a.free(path);
        self.serial += 1;
        const o = try self.register(.prompt, 0, path, owner);
        errdefer self.remove(o);
        o.create = create;
        if (label.len != 0) o.label = try self.a.dupeSentinel(u8, label, 0);
        if (alias.len != 0) o.alias = try self.a.dupeSentinel(u8, alias, 0);
        if (targets.len != 0) o.targets = try self.a.dupe(Target, targets);
        return o;
    }
    fn complete(self: *Server, o: *Object, dismissed: bool, result: *c.GVariant) void {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        if (bridge.fromVariant(arena.allocator(), result)) |value| {
            self.bus.emitTo(o.owner, o.path, iface(.prompt), "Completed", .{ dismissed, value }) catch {};
        } else |_| {}
        self.remove(o);
    }
    /// Replies with the children of `tuple`, or with no arguments when it is null.
    fn ret(self: *Server, message: *const dbus.Message, a: std.mem.Allocator, tuple: ?*c.GVariant) !void {
        const body = if (tuple) |value| try bridge.bodyFromVariant(a, value) else dbus.Body{ .values = &.{} };
        try self.bus.reply(message, body);
    }
    fn showPrompt(self: *Server, o: *Object) !void {
        if (o.started) return error.InvalidArgs;
        if (self.screen_locked or self.sleeping) return error.IsLocked;
        o.started = true;
        // The service can start before Wayland; only prompts open a connection.
        const creating = self.vault.envelope == null;
        const dialog = try Dialog.createWithOptions(.password, if (creating) "Choose a password for your new password vault." else "Enter your password to unlock saved passwords.", .{
            .title = if (creating) "Create Password Vault" else "Unlock Passwords",
            .role = "desktop-secrets",
            .accept = if (creating) "Create" else "Unlock",
            .confirmation = creating,
        });
        o.dialog = dialog;
        dialog.responded = &promptResponse;
        dialog.response_context = o;
        if (self.options.prompt_ready) |ready| ready(dialog);
    }
    fn method(self: *Server, o: *Object, owner: [:0]const u8, verb: []const u8, args: ?*c.GVariant, message: *const dbus.Message, a: std.mem.Allocator) !void {
        if (o.owner.len != 0 and !eq(o.owner, owner)) return error.AccessDenied;
        if (o.kind == .login) {
            if (eq(verb, "SetScreenLocked")) {
                const value = child(args, 0);
                defer c.g_variant_unref(value);
                self.screen_locked = c.g_variant_get_boolean(value) != 0;
                if (self.screen_locked) self.lock();
                try self.ret(message, a, null);
                return;
            }
            if (self.screen_locked or self.sleeping) return error.IsLocked;
            const password = child(args, 0);
            defer c.g_variant_unref(password);
            try self.vault.unlock(bytes(password));
            if (self.vault.index.collections.len == 0) _ = try self.createCollection("Login", "default");
            self.changed();
            try self.ret(message, a, null);
            return;
        }
        if (o.kind == .session) {
            try self.ret(message, a, null);
            self.remove(o);
            return;
        }
        if (o.kind == .prompt) {
            if (eq(verb, "Dismiss")) {
                try self.ret(message, a, null);
                self.complete(o, true, variantString("").?);
                return;
            }
            self.showPrompt(o) catch {
                try self.ret(message, a, null);
                self.complete(o, true, variantString("").?);
                return;
            };
            try self.ret(message, a, null);
            return;
        }
        if (eq(verb, "OpenSession")) {
            var count: usize = 0;
            var owned: usize = 0;
            for (self.objects.items) |v| {
                if (v.kind == .session) {
                    count += 1;
                    if (eq(v.owner, owner)) owned += 1;
                }
            }
            if (count >= 256 or owned >= 16) return error.LimitsExceeded;
            const algorithm = text(args, 0);
            var key: ?[16]u8 = null;
            defer if (key) |*v| store.wipe(v);
            var output: *c.GVariant = undefined;
            if (eq(algorithm, "plain")) {
                output = stringVariant("");
            } else if (eq(algorithm, transport.algorithm)) {
                const input = child(args, 1);
                defer c.g_variant_unref(input);
                const value = c.g_variant_get_variant(input);
                defer c.g_variant_unref(value);
                if (!eq(std.mem.span(c.g_variant_get_type_string(value)), "ay")) return error.InvalidArgs;
                var public: [128]u8 = undefined;
                key = try transport.negotiate(bytes(value), &public);
                output = byteVariant(&public);
            } else return error.NotSupported;
            const path = try std.fmt.allocPrintSentinel(a, root ++ "/session/s{d}", .{self.serial}, 0);
            self.serial += 1;
            const s = try self.register(.session, 0, path, owner);
            s.key = key;
            try self.ret(message, a, c.g_variant_new("(vo)", output, s.path.ptr));
            return;
        }
        if (eq(verb, "ReadAlias")) {
            try self.ret(message, a, c.g_variant_new("(o)", self.objectPath(.collection, self.aliasId(text(args, 0))).ptr));
            return;
        }
        if (eq(verb, "SetAlias")) {
            if (self.vault.key == null) return error.IsLocked;
            const target = text(args, 1);
            const id = if (eq(target, "/")) 0 else (self.object(target, .collection) orelse return error.NoSuchObject).id;
            try self.setAlias(text(args, 0), id);
            try self.vault.save();
            try self.reconcile();
            self.changed();
            try self.ret(message, a, null);
            return;
        }
        if (eq(verb, "CreateCollection")) {
            const properties = child(args, 0);
            defer c.g_variant_unref(properties);
            const label_v = c.g_variant_lookup_value(properties, prefix ++ "Collection.Label", @ptrCast(@as([*:0]const u8, "s"))) orelse return error.InvalidArgs;
            defer c.g_variant_unref(label_v);
            const label = str(label_v);
            const alias = text(args, 1);
            if (label.len > 4096) return error.LimitsExceeded;
            if (self.vault.key == null) {
                const prompt = try self.newPrompt(owner, true, label, alias, &.{});
                try self.ret(message, a, c.g_variant_new("(oo)", @as([*:0]const u8, "/"), prompt.path.ptr));
                return;
            }
            const id = try self.createCollection(label, alias);
            try self.ret(message, a, c.g_variant_new("(oo)", self.objectPath(.collection, id).ptr, @as([*:0]const u8, "/")));
            return;
        }
        if (eq(verb, "SearchItems")) {
            const attrs = child(args, 0);
            defer c.g_variant_unref(attrs);
            const query = try attributes(a, attrs);
            const found = build("ao");
            defer c.g_variant_builder_unref(found);
            const empty = build("ao");
            defer c.g_variant_builder_unref(empty);
            for (self.vault.index.items) |item| {
                if ((o.kind == .service or item.collection == o.id) and matches(item, query)) c.g_variant_builder_add(found, "o", self.objectPath(.item, item.id).ptr);
            }
            const result = c.g_variant_builder_end(found);
            if (o.kind == .collection) try self.ret(message, a, c.g_variant_new("(@ao)", result)) else {
                const other = c.g_variant_builder_end(empty);
                try self.ret(message, a, c.g_variant_new("(@ao@ao)", if (self.vault.key == null) other else result, if (self.vault.key == null) result else other));
            }
            return;
        }
        if (eq(verb, "Lock") or eq(verb, "Unlock")) {
            const paths = child(args, 0);
            defer c.g_variant_unref(paths);
            var ids: std.ArrayList(Target) = .empty;
            const found = build("ao");
            defer c.g_variant_builder_unref(found);
            for (0..c.g_variant_n_children(paths)) |i| {
                const v = child(paths, i);
                defer c.g_variant_unref(v);
                const target = self.object(str(v), .collection) orelse self.object(str(v), .item) orelse continue;
                try ids.append(a, .{ .kind = target.kind, .id = target.id });
                if (eq(verb, "Lock") or self.vault.key != null) c.g_variant_builder_add(found, "o", target.path.ptr);
            }
            var prompt_path: [:0]const u8 = "/";
            if (eq(verb, "Lock")) {
                if (ids.items.len != 0) self.lock();
            } else if (ids.items.len != 0 and self.vault.key == null) {
                prompt_path = (try self.newPrompt(owner, false, "", "", ids.items)).path;
            }
            try self.ret(message, a, c.g_variant_new("(@aoo)", c.g_variant_builder_end(found), prompt_path.ptr));
            return;
        }
        if (eq(verb, "GetSecrets")) {
            const s = try self.session(text(args, 1), owner);
            const paths = child(args, 0);
            defer c.g_variant_unref(paths);
            const dict = build("a{o(oayays)}");
            defer c.g_variant_builder_unref(dict);
            if (self.vault.key != null) for (0..c.g_variant_n_children(paths)) |i| {
                const v = child(paths, i);
                defer c.g_variant_unref(v);
                const item = self.object(str(v), .item) orelse continue;
                c.g_variant_builder_add(dict, "{o@(oayays)}", item.path.ptr, try self.encode(item.id, s, a));
            };
            try self.ret(message, a, c.g_variant_new("(@a{o(oayays)})", c.g_variant_builder_end(dict)));
            return;
        }
        if (self.vault.key == null) return error.IsLocked;
        if (eq(verb, "CreateItem")) {
            if (self.vault.index.items.len >= 4096) return error.LimitsExceeded;
            const properties = child(args, 0);
            defer c.g_variant_unref(properties);
            const label_v = c.g_variant_lookup_value(properties, prefix ++ "Item.Label", @ptrCast(@as([*:0]const u8, "s"))) orelse return error.InvalidArgs;
            defer c.g_variant_unref(label_v);
            if (str(label_v).len > 4096) return error.LimitsExceeded;
            const attrs_v = c.g_variant_lookup_value(properties, prefix ++ "Item.Attributes", @ptrCast(@as([*:0]const u8, "a{ss}"))) orelse return error.InvalidArgs;
            defer c.g_variant_unref(attrs_v);
            const attrs = try attributes(self.vault.metadata(), attrs_v);
            const secret = child(args, 1);
            defer c.g_variant_unref(secret);
            const decoded = try self.decode(secret, owner, a);
            const replace_v = child(args, 2);
            defer c.g_variant_unref(replace_v);
            var id: u64 = 0;
            if (c.g_variant_get_boolean(replace_v) != 0) for (self.vault.index.items) |item| {
                if (item.collection == o.id and item.attributes.len == attrs.len and matches(item, attrs)) {
                    id = item.id;
                    break;
                }
            };
            const replacing = id != 0;
            if (!replacing) {
                id = self.vault.index.next_id;
                self.vault.index.next_id += 1;
            }
            const entry = store.Item{ .id = id, .collection = o.id, .label = try self.vault.metadata().dupeSentinel(u8, str(label_v), 0), .attributes = attrs, .created = if (self.findItem(id)) |item| item.created else now(), .modified = now() };
            if (self.findItem(id)) |item| item.* = entry else self.vault.index.items = try append(store.Item, self.vault.metadata(), self.vault.index.items, entry);
            try self.vault.setValue(id, decoded.value, decoded.content_type);
            self.collection(o.id).?.modified = now();
            try self.vault.save();
            try self.reconcile();
            self.signal(self.objectPath(.collection, o.id), .collection, if (replacing) "ItemChanged" else "ItemCreated", self.objectPath(.item, id));
            self.changed();
            try self.ret(message, a, c.g_variant_new("(oo)", self.objectPath(.item, id).ptr, @as([*:0]const u8, "/")));
            return;
        }
        if (eq(verb, "GetSecret")) {
            const s = try self.session(text(args, 0), owner);
            try self.ret(message, a, c.g_variant_new("(@(oayays))", try self.encode(o.id, s, a)));
            return;
        }
        if (eq(verb, "SetSecret")) {
            const secret = child(args, 0);
            defer c.g_variant_unref(secret);
            const decoded = try self.decode(secret, owner, a);
            try self.vault.setValue(o.id, decoded.value, decoded.content_type);
            self.findItem(o.id).?.modified = now();
            try self.vault.save();
            self.changed();
            self.signal(self.objectPath(.collection, self.findItem(o.id).?.collection), .collection, "ItemChanged", o.path);
            try self.ret(message, a, null);
            return;
        }
        if (eq(verb, "Delete")) {
            const id = o.id;
            const path = try a.dupeSentinel(u8, o.path, 0);
            if (o.kind == .item) {
                const col = self.findItem(id).?.collection;
                self.vault.index.items = try without(store.Item, self.vault.metadata(), self.vault.index.items, id);
                try self.vault.removeValue(id);
                try self.vault.save();
                self.signal(self.objectPath(.collection, col), .collection, "ItemDeleted", path);
            } else {
                var items: std.ArrayList(store.Item) = .empty;
                for (self.vault.index.items) |item| {
                    if (item.collection == id) try self.vault.removeValue(item.id) else try items.append(self.vault.metadata(), item);
                }
                self.vault.index.items = try items.toOwnedSlice(self.vault.metadata());
                self.vault.index.collections = try without(store.Collection, self.vault.metadata(), self.vault.index.collections, id);
                var aliases: std.ArrayList(store.Alias) = .empty;
                for (self.vault.index.aliases) |alias| {
                    if (alias.collection != id) try aliases.append(self.vault.metadata(), alias);
                }
                self.vault.index.aliases = try aliases.toOwnedSlice(self.vault.metadata());
                try self.vault.save();
                self.signal(root, .service, "CollectionDeleted", path);
            }
            try self.reconcile();
            self.changed();
            try self.ret(message, a, c.g_variant_new("(o)", @as([*:0]const u8, "/")));
            return;
        }
        return error.NotSupported;
    }
};
fn errorName(err: anyerror) [:0]const u8 {
    return switch (err) {
        error.IsLocked => prefix ++ "Error.IsLocked",
        error.NoSession => prefix ++ "Error.NoSession",
        error.NoSuchObject => prefix ++ "Error.NoSuchObject",
        error.NotSupported => "org.freedesktop.DBus.Error.NotSupported",
        error.AccessDenied => "org.freedesktop.DBus.Error.AccessDenied",
        error.InvalidArgs, error.InvalidPublicKey, error.NonCanonical, error.InvalidCiphertext, error.InvalidPadding => "org.freedesktop.DBus.Error.InvalidArgs",
        error.LimitsExceeded, error.VaultTooLarge => "org.freedesktop.DBus.Error.LimitsExceeded",
        else => "org.freedesktop.DBus.Error.Failed",
    };
}
fn methodCall(data: ?*anyopaque, message: *const dbus.Message) void {
    const o = cast(Object, data);
    const self = o.server;
    var arena = std.heap.ArenaAllocator.init(self.a);
    defer arena.deinit();
    const args: ?*c.GVariant = if (message.signature.len == 0) null else bridge.argumentsVariant(message) orelse return self.bus.replyError(message, "org.freedesktop.DBus.Error.InvalidArgs", "InvalidArgs") catch {};
    defer if (args) |value| c.g_variant_unref(value);
    const owner = arena.allocator().dupeSentinel(u8, message.sender orelse "", 0) catch return;
    self.method(o, owner, message.member orelse "", args, message, arena.allocator()) catch |err| {
        // Restore the last committed version after any rejected mutation.
        self.vault.restore() catch {
            self.lock();
            self.stopping = true;
        };
        self.reconcile() catch {
            self.stopping = true;
        };
        self.bus.replyError(message, errorName(err), @errorName(err)) catch {};
    };
}
fn getProperty(data: ?*anyopaque, _: []const u8, _: []const u8, prop: []const u8, arena: std.mem.Allocator) ?dbus.Value {
    const o = cast(Object, data);
    return bridge.fromVariant(arena, o.server.property(o, prop) orelse return null) catch null;
}
fn setProperty(data: ?*anyopaque, _: []const u8, _: []const u8, prop: []const u8, value: dbus.Value) ?dbus.Failure {
    const o = cast(Object, data);
    const self = o.server;
    const variant = c.g_variant_take_ref(bridge.toVariant(value) orelse return .{ .name = "org.freedesktop.DBus.Error.InvalidArgs", .text = "InvalidArgs" });
    defer c.g_variant_unref(variant);
    setPropertyValue(o, prop, variant) catch |failure| {
        self.vault.restore() catch {
            self.lock();
            self.stopping = true;
        };
        return .{ .name = errorName(failure), .text = @errorName(failure) };
    };
    self.changed();
    if (o.kind == .item) self.signal(self.objectPath(.collection, self.findItem(o.id).?.collection), .collection, "ItemChanged", o.path) else self.signal(root, .service, "CollectionChanged", o.path);
    return null;
}
fn setPropertyValue(o: *Object, prop: []const u8, value: ?*c.GVariant) !void {
    const self = o.server;
    if (self.vault.key == null) return error.IsLocked;
    if (eq(prop, "Label")) {
        if (str(value).len > 4096) return error.LimitsExceeded;
        const label = try self.vault.metadata().dupeSentinel(u8, str(value), 0);
        if (o.kind == .collection) {
            self.collection(o.id).?.label = label;
            self.collection(o.id).?.modified = now();
        } else {
            self.findItem(o.id).?.label = label;
            self.findItem(o.id).?.modified = now();
        }
    } else if (o.kind == .item and eq(prop, "Attributes")) {
        self.findItem(o.id).?.attributes = try Server.attributes(self.vault.metadata(), value);
        self.findItem(o.id).?.modified = now();
    } else return error.InvalidArgs;
    try self.vault.save();
}
fn promptResponse(data: ?*anyopaque, accepted: bool) void {
    const o = cast(Object, data);
    const self = o.server;
    if (!accepted or self.screen_locked or self.sleeping) {
        self.complete(o, true, stringVariant(""));
        return;
    }
    const dialog = o.dialog.?;
    if (!(dialog.validatePassword() catch {
        self.complete(o, true, stringVariant(""));
        return;
    })) return;
    self.vault.unlock(dialog.entry.?.buffer.value()) catch {
        dialog.clear();
        dialog.setStatus("Could not unlock passwords. Please try again.", true) catch {
            self.complete(o, true, stringVariant(""));
            return;
        };
        dialog.focus(.entry);
        return;
    };
    dialog.clear();
    if (o.create) {
        const id = self.createCollection(o.label, o.alias) catch {
            self.vault.restore() catch self.lock();
            self.complete(o, true, stringVariant(""));
            return;
        };
        self.complete(o, false, variantPath(self.objectPath(.collection, id)).?);
    } else {
        const result = build("ao");
        defer c.g_variant_builder_unref(result);
        for (o.targets) |target| {
            const exists = if (target.kind == .collection) self.collection(target.id) != null else self.findItem(target.id) != null;
            if (exists) c.g_variant_builder_add(result, "o", self.objectPath(target.kind, target.id).ptr);
        }
        self.changed();
        self.complete(o, false, c.g_variant_builder_end(result).?);
    }
}
fn ownerChanged(data: ?*anyopaque, message: *const dbus.Message) void {
    const args = message.read(struct { []const u8, []const u8, []const u8 }) catch return;
    if (args[2].len != 0) return;
    const self = cast(Server, data);
    var i: usize = 0;
    while (i < self.objects.items.len) {
        const o = self.objects.items[i];
        if (o.owner.len != 0 and eq(o.owner, args[0])) self.remove(o) else i += 1;
    }
}
fn sessionSignal(data: ?*anyopaque, message: *const dbus.Message) void {
    const self = cast(Server, data);
    const member = message.member orelse "";
    const path = message.path orelse "";
    if (eq(member, "PrepareForSleep")) {
        self.sleeping = (message.read(struct { bool }) catch return)[0];
        if (self.sleeping) self.lock();
    } else if (self.logind != null and eq(self.logind.?, path)) {
        if (eq(member, "Lock")) {
            self.screen_locked = true;
            self.lock();
        }
        if (eq(member, "Unlock")) self.screen_locked = false;
        if (eq(member, "PropertiesChanged")) {
            const args = message.read(struct { []const u8, bridge.Dict, []const []const u8 }) catch return;
            if (!eq(args[0], "org.freedesktop.login1.Session")) return;
            for (args[1].entries) |entry| if (eq(entry.key, "LockedHint")) switch (entry.value) {
                .boolean => |locked| {
                    self.screen_locked = locked;
                    if (self.screen_locked) self.lock();
                },
                else => {},
            };
        }
    }
}
fn quit(data: ?*anyopaque) callconv(.c) c_int {
    cast(Server, data).stopping = true;
    return 1;
}
pub fn run() !void {
    const base = std.mem.span(c.g_get_user_data_dir());
    if (c.g_mkdir_with_parents(base.ptr, 0o700) != 0) return error.CreateDirectory;
    const directory = try std.fmt.allocPrintSentinel(std.heap.page_allocator, "{s}/desktop-secrets", .{base}, 0);
    defer std.heap.page_allocator.free(directory);
    return runAt(directory);
}
pub fn runAt(directory: [:0]const u8) !void {
    return runAtWithOptions(directory, .{});
}
pub fn runAtWithOptions(directory: [:0]const u8, options: Options) !void {
    if (p.prctl(p.PR_SET_DUMPABLE, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return error.PrctlFailed;
    var wa = store.WipingAllocator{ .parent = std.heap.page_allocator };
    const a = wa.allocator();
    const source = loop.acquire(.session) catch return error.NoSessionBus;
    defer loop.release(source);
    const bus = source.connection;
    var introspection = try dbus.Introspection.parse(a, @embedFile("desktop-secrets.xml"));
    defer introspection.deinit();
    var server = Server{ .a = a, .options = options, .vault = try store.Vault.init(a, directory), .bus = bus, .introspection = introspection };
    defer {
        while (server.objects.items.len != 0) server.remove(server.objects.items[server.objects.items.len - 1]);
        server.objects.deinit(a);
        server.vault.deinit();
        if (server.logind) |v| a.free(v);
    }
    _ = try server.register(.service, 0, root, "");
    _ = try server.register(.login, 0, root, "");
    try server.reconcile();
    // Activation releases queued client calls as soon as the name is owned.
    // Register the complete object tree first.
    if ((bus.requestName(name, 4) catch return error.NameUnavailable) != 1) return error.NameUnavailable;
    const owners = try bus.subscribe("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", &ownerChanged, &server);
    defer bus.unsubscribe(owners);
    const system: ?*loop.Source = loop.acquire(.system) catch null;
    var subscriptions: [3]u32 = .{ 0, 0, 0 };
    defer if (system) |held| {
        for (subscriptions) |id| if (id != 0) held.connection.unsubscribe(id);
        loop.release(held);
    };
    if (system) |held| {
        const connection = held.connection;
        if (connection.callBlocking(.{ .destination = "org.freedesktop.login1", .path = "/org/freedesktop/login1", .interface = "org.freedesktop.login1.Manager", .member = "GetSessionByPID" }, .{@as(u32, @intCast(p.getpid()))}, 3000)) |reply| {
            defer reply.deinit();
            if (reply.message().read(struct { dbus.ObjectPath })) |args| server.logind = try a.dupeSentinel(u8, args[0].value, 0) else |_| {}
        } else |_| {}
        subscriptions[0] = try connection.subscribe("org.freedesktop.login1", "org.freedesktop.login1.Session", null, null, &sessionSignal, &server);
        subscriptions[1] = try connection.subscribe("org.freedesktop.login1", "org.freedesktop.DBus.Properties", "PropertiesChanged", null, &sessionSignal, &server);
        subscriptions[2] = try connection.subscribe("org.freedesktop.login1", "org.freedesktop.login1.Manager", "PrepareForSleep", "/org/freedesktop/login1", &sessionSignal, &server);
    }
    const term = c.g_unix_signal_add(c.SIGTERM, &quit, &server);
    const interrupt = c.g_unix_signal_add(c.SIGINT, &quit, &server);
    defer {
        _ = c.g_source_remove(term);
        _ = c.g_source_remove(interrupt);
    }
    while (!server.stopping and !bus.closed) _ = c.g_main_context_iteration(null, 1);
}
/// Called by PAM's dropped-privilege helper. Passwords travel through stdin, never argv or environment.
pub fn loginUnlock(password: []const u8) !void {
    const bus = dbus.Connection.open(std.heap.page_allocator, .session) catch return error.NoSessionBus;
    defer bus.close();
    const reply = bus.callBlocking(.{ .destination = name, .path = root, .interface = "org.dotfiles.Desktop.Secrets", .member = "LoginUnlock" }, .{dbus.Bytes{ .value = password }}, 30000) catch return error.UnlockFailed;
    reply.deinit();
}
test {
    _ = transport;
    _ = store;
}

fn variantString(v: [*:0]const u8) ?*c.GVariant {
    return c.g_variant_new("s", v);
}
fn variantBool(v: c_int) ?*c.GVariant {
    return c.g_variant_new("b", v);
}
fn variantUint(v: u64) ?*c.GVariant {
    return c.g_variant_new("t", v);
}
fn variantPath(v: [*:0]const u8) ?*c.GVariant {
    return c.g_variant_new("o", v);
}

/// Calls the source service and returns its reply as an owned GVariant tuple.
fn sourceCall(bus: *dbus.Connection, owner: [:0]const u8, path: [:0]const u8, interface: [:0]const u8, verb: [:0]const u8, args: ?*c.GVariant) !*c.GVariant {
    var arena = std.heap.ArenaAllocator.init(bus.allocator);
    defer arena.deinit();
    const body = if (args) |value| try bridge.bodyFromVariant(arena.allocator(), value) else dbus.Body{ .values = &.{} };
    const reply = bus.callBlocking(.{ .destination = owner, .path = path, .interface = interface, .member = verb, .no_auto_start = true }, body, 30000) catch return error.SourceUnavailable;
    defer reply.deinit();
    return bridge.argumentsVariant(reply.message()) orelse error.SourceUnavailable;
}
fn sourceProperty(bus: *dbus.Connection, owner: [:0]const u8, path: [:0]const u8, kind: Kind, prop: [:0]const u8) !*c.GVariant {
    const reply = try sourceCall(bus, owner, path, "org.freedesktop.DBus.Properties", "Get", c.g_variant_new("(ss)", iface(kind).ptr, prop.ptr));
    defer c.g_variant_unref(reply);
    const boxed = child(reply, 0);
    defer c.g_variant_unref(boxed);
    return c.g_variant_get_variant(boxed).?;
}
/// Copy from a running, unlocked Secret Service into a new authenticated vault.
/// Pin the unique bus owner for the entire import; never modify the source.
pub fn importAt(directory: [:0]const u8, password: []const u8) !void {
    var wa = store.WipingAllocator{ .parent = std.heap.page_allocator };
    const a = wa.allocator();
    var vault = try store.Vault.init(a, directory);
    defer vault.deinit();
    if (vault.envelope != null and vault.index.collections.len != 0) return error.DestinationNotEmpty;
    const bus = dbus.Connection.open(std.heap.page_allocator, .session) catch return error.NoSessionBus;
    defer bus.close();
    const owned = sourceCall(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", c.g_variant_new("(s)", @as([*:0]const u8, name))) catch return error.NoSourceService;
    defer c.g_variant_unref(owned);
    const owner = try a.dupeSentinel(u8, text(owned, 0), 0);
    defer a.free(owner);
    const opened = try sourceCall(bus, owner, root, iface(.service), "OpenSession", c.g_variant_new("(sv)", @as([*:0]const u8, "plain"), stringVariant("")));
    defer c.g_variant_unref(opened);
    const session = text(opened, 1);
    defer {
        if (sourceCall(bus, owner, session, iface(.session), "Close", null)) |v| c.g_variant_unref(v) else |_| {}
    }
    const collections = try sourceProperty(bus, owner, root, .service, "Collections");
    defer c.g_variant_unref(collections);
    if (c.g_variant_n_children(collections) > 64) return error.LimitsExceeded;
    // Validate all collections before creating the destination.
    for (0..c.g_variant_n_children(collections)) |i| {
        const path = child(collections, i);
        defer c.g_variant_unref(path);
        const locked = try sourceProperty(bus, owner, str(path), .collection, "Locked");
        defer c.g_variant_unref(locked);
        if (c.g_variant_get_boolean(locked) != 0) return error.SourceLocked;
    }
    try vault.unlock(password);
    const ma = vault.metadata();
    for (0..c.g_variant_n_children(collections)) |i| {
        const path_v = child(collections, i);
        defer c.g_variant_unref(path_v);
        const path = str(path_v);
        const label = try sourceProperty(bus, owner, path, .collection, "Label");
        defer c.g_variant_unref(label);
        const id = vault.index.next_id;
        vault.index.next_id += 1;
        vault.index.collections = try append(store.Collection, ma, vault.index.collections, .{ .id = id, .label = try ma.dupeSentinel(u8, str(label), 0), .created = now(), .modified = now() });
        for ([_][:0]const u8{ "default", "login" }) |alias| {
            const target = try sourceCall(bus, owner, root, iface(.service), "ReadAlias", c.g_variant_new("(s)", alias.ptr));
            defer c.g_variant_unref(target);
            if (eq(text(target, 0), path)) vault.index.aliases = try append(store.Alias, ma, vault.index.aliases, .{ .name = try ma.dupeSentinel(u8, alias, 0), .collection = id });
        }
        const items = try sourceProperty(bus, owner, path, .collection, "Items");
        defer c.g_variant_unref(items);
        for (0..c.g_variant_n_children(items)) |j| {
            if (vault.index.items.len >= 4096) return error.LimitsExceeded;
            const item_v = child(items, j);
            defer c.g_variant_unref(item_v);
            const item_path = str(item_v);
            const item_label = try sourceProperty(bus, owner, item_path, .item, "Label");
            defer c.g_variant_unref(item_label);
            const attrs = try sourceProperty(bus, owner, item_path, .item, "Attributes");
            defer c.g_variant_unref(attrs);
            const reply = try sourceCall(bus, owner, item_path, iface(.item), "GetSecret", c.g_variant_new("(o)", session.ptr));
            defer c.g_variant_unref(reply);
            const secret = child(reply, 0);
            defer c.g_variant_unref(secret);
            const parameters = child(secret, 1);
            defer c.g_variant_unref(parameters);
            if (bytes(parameters).len != 0 or !eq(text(secret, 0), session)) return error.InvalidSourceSecret;
            const data = child(secret, 2);
            defer c.g_variant_unref(data);
            if (bytes(data).len > 1024 * 1024) return error.LimitsExceeded;
            const item_id = vault.index.next_id;
            vault.index.next_id += 1;
            vault.index.items = try append(store.Item, ma, vault.index.items, .{ .id = item_id, .collection = id, .label = try ma.dupeSentinel(u8, str(item_label), 0), .attributes = try Server.attributes(ma, attrs), .created = now(), .modified = now() });
            try vault.setValue(item_id, bytes(data), text(secret, 3));
        }
    }
    if (vault.index.collections.len != 0 and vault.index.aliases.len == 0) vault.index.aliases = try append(store.Alias, ma, vault.index.aliases, .{ .name = "default", .collection = vault.index.collections[0].id });
    try vault.save();
}
pub fn runImport() !void {
    if (p.prctl(p.PR_SET_DUMPABLE, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return error.PrctlFailed;
    const a = std.heap.page_allocator;
    const dialog = try createImportDialog();
    defer dialog.destroy();
    while (true) {
        dialog.run();
        if (!dialog.accepted) return error.Cancelled;
        if (try dialog.validatePassword()) break;
    }
    const base = std.mem.span(c.g_get_user_data_dir());
    if (c.g_mkdir_with_parents(base.ptr, 0o700) != 0) return error.CreateDirectory;
    const directory = try std.fmt.allocPrintSentinel(a, "{s}/desktop-secrets", .{base}, 0);
    defer a.free(directory);
    try importAt(directory, dialog.entry.?.buffer.value());
    std.debug.print("Imported Secret Service collections. The source keyring is unchanged.\n", .{});
}
pub fn createImportDialog() !*Dialog {
    return Dialog.createWithOptions(.password, "Choose the destination vault password. Use your login password for automatic unlock.", .{
        .title = "Import Saved Passwords",
        .role = "desktop-secrets-import",
        .accept = "Continue",
        .confirmation = true,
    });
}

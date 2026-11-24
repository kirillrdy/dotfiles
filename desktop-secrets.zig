//! Native Secret Service. Bus sessions and prompts belong to their unique caller.
const std = @import("std");
const mainloop = @import("desktop-loop.zig");
const util = @import("desktop-util.zig");
const p = @import("desktop-libc.zig");
const dbus = @import("dbus");
const loop = @import("desktop-dbus-loop.zig");
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
const eq = util.eq;
const cast = util.cast;
fn now() u64 {
    return @intCast(@divTrunc(util.realTime(), 1000000));
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
/// A transferred secret: session, parameters, value and content type (`(oayays)`).
const Secret = struct { dbus.ObjectPath, dbus.Bytes, dbus.Bytes, []const u8 };
const SecretMap = dbus.Dict(dbus.ObjectPath, Secret);
const Attributes = dbus.Dict([]const u8, []const u8);
const Properties = dbus.Dict([]const u8, dbus.Value);
/// Arguments of the expected signature, or InvalidArgs.
fn read(message: *const dbus.Message, comptime T: type) !T {
    return message.read(T) catch error.InvalidArgs;
}
fn lookup(properties: Properties, key: []const u8) ?dbus.Value {
    for (properties.entries) |entry| if (eq(entry.key, key)) return entry.value;
    return null;
}
/// An `a{ss}` property value as attributes.
fn attributeValue(a: std.mem.Allocator, value: dbus.Value) !Attributes {
    const array = switch (value) {
        .array => |array| array,
        else => return error.InvalidArgs,
    };
    if (!eq(array.element, "{ss}")) return error.InvalidArgs;
    const entries = try a.alloc(Attributes.Entry, array.items.len);
    for (entries, array.items) |*entry, item| entry.* = .{ .key = item.dict_entry[0].string, .value = item.dict_entry[1].string };
    return .{ .entries = entries };
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
    ui_allocator: std.mem.Allocator,
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
            var entries: [4]Properties.Entry = undefined;
            var count: usize = 0;
            for (names) |prop| {
                entries[count] = .{ .key = prop, .value = (self.property(o, prop, arena.allocator()) catch null) orelse continue };
                count += 1;
            }
            self.bus.emit(o.path, "org.freedesktop.DBus.Properties", "PropertiesChanged", .{ iface(o.kind), Properties{ .entries = entries[0..count] }, @as([]const []const u8, &.{}) }) catch {};
        }
    }
    fn lock(self: *Server) void {
        self.vault.lock();
        // A pending prompt must not unlock after a screen-lock event.
        var i: usize = 0;
        while (i < self.objects.items.len) {
            const o = self.objects.items[i];
            if (o.kind == .prompt) self.complete(o, true, .{ .array = .{ .element = "o", .items = &.{} } }) else i += 1;
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
    fn decode(self: *Server, secret: Secret, owner: []const u8, a: std.mem.Allocator) !struct { value: []const u8, content_type: [:0]const u8 } {
        const s = try self.session(secret[0].value, owner);
        const parameters = secret[1].value;
        const value = secret[2].value;
        if (value.len > 1024 * 1024) return error.LimitsExceeded;
        const data = if (s.key) |key| try transport.decode(a, key, parameters, value) else blk: {
            if (parameters.len != 0) return error.InvalidArgs;
            break :blk try a.dupe(u8, value);
        };
        return .{ .value = data, .content_type = try a.dupeSentinel(u8, secret[3], 0) };
    }
    fn encode(self: *Server, id: u64, s: *Object, a: std.mem.Allocator) !Secret {
        if (self.vault.key == null) return error.IsLocked;
        const v = self.vault.value(id) orelse return error.NoSuchObject;
        const iv = try a.alloc(u8, if (s.key != null) 16 else 0);
        const data = if (s.key) |key| blk: {
            try store.random(iv);
            break :blk try transport.encode(a, key, iv[0..16].*, v.bytes);
        } else v.bytes;
        return .{ .{ .value = s.path }, .{ .value = iv }, .{ .value = data }, v.content_type };
    }
    fn attributes(a: std.mem.Allocator, v: Attributes) ![]const store.Attribute {
        if (v.entries.len > 256) return error.LimitsExceeded;
        var out: std.ArrayList(store.Attribute) = .empty;
        for (v.entries) |entry| {
            if (entry.key.len > 4096 or entry.value.len > 16384) return error.LimitsExceeded;
            for (out.items) |old| {
                if (eq(old.key, entry.key)) return error.InvalidArgs;
            }
            try out.append(a, .{ .key = try a.dupeSentinel(u8, entry.key, 0), .value = try a.dupeSentinel(u8, entry.value, 0) });
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
    fn paths(a: std.mem.Allocator, list: []const []const u8) !dbus.Value {
        const items = try a.alloc(dbus.Value, list.len);
        for (items, list) |*item, path| item.* = .{ .object_path = path };
        return .{ .array = .{ .element = "o", .items = items } };
    }
    /// A property's current value, allocated from `a`; null for unknown properties.
    fn property(self: *Server, o: *Object, prop: []const u8, a: std.mem.Allocator) !?dbus.Value {
        if (o.kind == .service and eq(prop, "Collections")) {
            var list: std.ArrayList([]const u8) = .empty;
            for (self.vault.index.collections) |col| try list.append(a, self.objectPath(.collection, col.id));
            return try paths(a, list.items);
        }
        const col = if (o.kind == .collection) self.collection(o.id) else null;
        const item = if (o.kind == .item) self.findItem(o.id) else null;
        if (col == null and item == null) return null;
        if (eq(prop, "Locked")) return .{ .boolean = self.vault.key == null };
        if (eq(prop, "Label")) return .{ .string = if (col) |v| v.label else item.?.label };
        if (eq(prop, "Created")) return .{ .uint64 = if (col) |v| v.created else item.?.created };
        if (eq(prop, "Modified")) return .{ .uint64 = if (col) |v| v.modified else item.?.modified };
        if (item != null and eq(prop, "Attributes")) {
            const entries = try a.alloc(dbus.Value, item.?.attributes.len);
            for (entries, item.?.attributes) |*entry, attr| {
                const pair = try a.create([2]dbus.Value);
                pair.* = .{ .{ .string = attr.key }, .{ .string = attr.value } };
                entry.* = .{ .dict_entry = pair };
            }
            return .{ .array = .{ .element = "{ss}", .items = entries } };
        }
        if (col != null and eq(prop, "Items")) {
            var list: std.ArrayList([]const u8) = .empty;
            for (self.vault.index.items) |v| {
                if (v.collection == o.id) try list.append(a, self.objectPath(.item, v.id));
            }
            return try paths(a, list.items);
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
    /// Ends a prompt; `result` is sent as the variant of Completed.
    fn complete(self: *Server, o: *Object, dismissed: bool, result: dbus.Value) void {
        self.bus.emitTo(o.owner, o.path, iface(.prompt), "Completed", .{ dismissed, result }) catch {};
        self.remove(o);
    }
    fn showPrompt(self: *Server, o: *Object) !void {
        if (o.started) return error.InvalidArgs;
        if (self.screen_locked or self.sleeping) return error.IsLocked;
        o.started = true;
        // The service can start before Wayland; only prompts open a connection.
        const creating = self.vault.envelope == null;
        const dialog = try Dialog.createWithOptions(self.ui_allocator, .password, if (creating) "Choose a password for your new password vault." else "Enter your password to unlock saved passwords.", .{
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
    fn method(self: *Server, o: *Object, owner: [:0]const u8, verb: []const u8, message: *const dbus.Message, a: std.mem.Allocator) !void {
        const bus = self.bus;
        if (o.owner.len != 0 and !eq(o.owner, owner)) return error.AccessDenied;
        if (o.kind == .login) {
            if (eq(verb, "SetScreenLocked")) {
                self.screen_locked = (try read(message, struct { bool }))[0];
                if (self.screen_locked) self.lock();
                return bus.reply(message, .{});
            }
            if (self.screen_locked or self.sleeping) return error.IsLocked;
            const password = (try read(message, struct { dbus.Bytes }))[0].value;
            try self.vault.unlock(password);
            if (self.vault.index.collections.len == 0) _ = try self.createCollection("Login", "default");
            self.changed();
            return bus.reply(message, .{});
        }
        if (o.kind == .session) {
            try bus.reply(message, .{});
            self.remove(o);
            return;
        }
        if (o.kind == .prompt) {
            if (eq(verb, "Dismiss")) {
                try bus.reply(message, .{});
                self.complete(o, true, .{ .string = "" });
                return;
            }
            self.showPrompt(o) catch {
                try bus.reply(message, .{});
                self.complete(o, true, .{ .string = "" });
                return;
            };
            return bus.reply(message, .{});
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
            const args = try read(message, struct { []const u8, dbus.Value });
            var key: ?[16]u8 = null;
            defer if (key) |*v| store.wipe(v);
            var public: [128]u8 = undefined;
            var output: dbus.Value = undefined;
            if (eq(args[0], "plain")) {
                output = .{ .string = "" };
            } else if (eq(args[0], transport.algorithm)) {
                const input = switch (args[1]) {
                    .bytes => |value| value,
                    else => return error.InvalidArgs,
                };
                key = try transport.negotiate(input, &public);
                output = .{ .bytes = &public };
            } else return error.NotSupported;
            const path = try std.fmt.allocPrintSentinel(a, root ++ "/session/s{d}", .{self.serial}, 0);
            self.serial += 1;
            const s = try self.register(.session, 0, path, owner);
            s.key = key;
            return bus.reply(message, .{ output, dbus.ObjectPath{ .value = s.path } });
        }
        if (eq(verb, "ReadAlias")) {
            const alias = (try read(message, struct { []const u8 }))[0];
            return bus.reply(message, .{dbus.ObjectPath{ .value = self.objectPath(.collection, self.aliasId(alias)) }});
        }
        if (eq(verb, "SetAlias")) {
            if (self.vault.key == null) return error.IsLocked;
            const args = try read(message, struct { []const u8, dbus.ObjectPath });
            const target = args[1].value;
            const id = if (eq(target, "/")) 0 else (self.object(target, .collection) orelse return error.NoSuchObject).id;
            try self.setAlias(try a.dupeSentinel(u8, args[0], 0), id);
            try self.vault.save();
            try self.reconcile();
            self.changed();
            return bus.reply(message, .{});
        }
        if (eq(verb, "CreateCollection")) {
            const args = try read(message, struct { Properties, []const u8 });
            const label = switch (lookup(args[0], prefix ++ "Collection.Label") orelse return error.InvalidArgs) {
                .string => |value| try a.dupeSentinel(u8, value, 0),
                else => return error.InvalidArgs,
            };
            const alias = try a.dupeSentinel(u8, args[1], 0);
            if (label.len > 4096) return error.LimitsExceeded;
            if (self.vault.key == null) {
                const prompt = try self.newPrompt(owner, true, label, alias, &.{});
                return bus.reply(message, .{ dbus.ObjectPath{ .value = "/" }, dbus.ObjectPath{ .value = prompt.path } });
            }
            const id = try self.createCollection(label, alias);
            return bus.reply(message, .{ dbus.ObjectPath{ .value = self.objectPath(.collection, id) }, dbus.ObjectPath{ .value = "/" } });
        }
        if (eq(verb, "SearchItems")) {
            const query = try attributes(a, (try read(message, struct { Attributes }))[0]);
            var found: std.ArrayList(dbus.ObjectPath) = .empty;
            for (self.vault.index.items) |item| {
                if ((o.kind == .service or item.collection == o.id) and matches(item, query)) try found.append(a, .{ .value = self.objectPath(.item, item.id) });
            }
            if (o.kind == .collection) return bus.reply(message, .{@as([]const dbus.ObjectPath, found.items)});
            const none: []const dbus.ObjectPath = &.{};
            // Unlocked, then locked results.
            return if (self.vault.key == null) bus.reply(message, .{ none, @as([]const dbus.ObjectPath, found.items) }) else bus.reply(message, .{ @as([]const dbus.ObjectPath, found.items), none });
        }
        if (eq(verb, "Lock") or eq(verb, "Unlock")) {
            const requested = (try read(message, struct { []const dbus.ObjectPath }))[0];
            var ids: std.ArrayList(Target) = .empty;
            var found: std.ArrayList(dbus.ObjectPath) = .empty;
            for (requested) |path| {
                const target = self.object(path.value, .collection) orelse self.object(path.value, .item) orelse continue;
                try ids.append(a, .{ .kind = target.kind, .id = target.id });
                if (eq(verb, "Lock") or self.vault.key != null) try found.append(a, .{ .value = target.path });
            }
            var prompt_path: [:0]const u8 = "/";
            if (eq(verb, "Lock")) {
                if (ids.items.len != 0) self.lock();
            } else if (ids.items.len != 0 and self.vault.key == null) {
                prompt_path = (try self.newPrompt(owner, false, "", "", ids.items)).path;
            }
            return bus.reply(message, .{ @as([]const dbus.ObjectPath, found.items), dbus.ObjectPath{ .value = prompt_path } });
        }
        if (eq(verb, "GetSecrets")) {
            const args = try read(message, struct { []const dbus.ObjectPath, dbus.ObjectPath });
            const s = try self.session(args[1].value, owner);
            var secrets: std.ArrayList(SecretMap.Entry) = .empty;
            if (self.vault.key != null) for (args[0]) |path| {
                const item = self.object(path.value, .item) orelse continue;
                try secrets.append(a, .{ .key = .{ .value = item.path }, .value = try self.encode(item.id, s, a) });
            };
            return bus.reply(message, .{SecretMap{ .entries = secrets.items }});
        }
        if (self.vault.key == null) return error.IsLocked;
        if (eq(verb, "CreateItem")) {
            if (self.vault.index.items.len >= 4096) return error.LimitsExceeded;
            const args = try read(message, struct { Properties, Secret, bool });
            const label = switch (lookup(args[0], prefix ++ "Item.Label") orelse return error.InvalidArgs) {
                .string => |value| value,
                else => return error.InvalidArgs,
            };
            if (label.len > 4096) return error.LimitsExceeded;
            const attrs = try attributes(self.vault.metadata(), try attributeValue(a, lookup(args[0], prefix ++ "Item.Attributes") orelse return error.InvalidArgs));
            const decoded = try self.decode(args[1], owner, a);
            var id: u64 = 0;
            if (args[2]) for (self.vault.index.items) |item| {
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
            const entry = store.Item{ .id = id, .collection = o.id, .label = try self.vault.metadata().dupeSentinel(u8, label, 0), .attributes = attrs, .created = if (self.findItem(id)) |item| item.created else now(), .modified = now() };
            if (self.findItem(id)) |item| item.* = entry else self.vault.index.items = try append(store.Item, self.vault.metadata(), self.vault.index.items, entry);
            try self.vault.setValue(id, decoded.value, decoded.content_type);
            self.collection(o.id).?.modified = now();
            try self.vault.save();
            try self.reconcile();
            self.signal(self.objectPath(.collection, o.id), .collection, if (replacing) "ItemChanged" else "ItemCreated", self.objectPath(.item, id));
            self.changed();
            return bus.reply(message, .{ dbus.ObjectPath{ .value = self.objectPath(.item, id) }, dbus.ObjectPath{ .value = "/" } });
        }
        if (eq(verb, "GetSecret")) {
            const s = try self.session((try read(message, struct { dbus.ObjectPath }))[0].value, owner);
            return bus.reply(message, .{try self.encode(o.id, s, a)});
        }
        if (eq(verb, "SetSecret")) {
            const decoded = try self.decode((try read(message, struct { Secret }))[0], owner, a);
            try self.vault.setValue(o.id, decoded.value, decoded.content_type);
            self.findItem(o.id).?.modified = now();
            try self.vault.save();
            self.changed();
            self.signal(self.objectPath(.collection, self.findItem(o.id).?.collection), .collection, "ItemChanged", o.path);
            return bus.reply(message, .{});
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
            try bus.reply(message, .{dbus.ObjectPath{ .value = "/" }});
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
    const owner = arena.allocator().dupeSentinel(u8, message.sender orelse "", 0) catch return;
    self.method(o, owner, message.member orelse "", message, arena.allocator()) catch |err| {
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
    return o.server.property(o, prop, arena) catch null;
}
fn setProperty(data: ?*anyopaque, _: []const u8, _: []const u8, prop: []const u8, value: dbus.Value) ?dbus.Failure {
    const o = cast(Object, data);
    const self = o.server;
    setPropertyValue(o, prop, value) catch |failure| {
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
fn setPropertyValue(o: *Object, prop: []const u8, value: dbus.Value) !void {
    const self = o.server;
    if (self.vault.key == null) return error.IsLocked;
    if (eq(prop, "Label")) {
        const text_value = switch (value) {
            .string => |v| v,
            else => return error.InvalidArgs,
        };
        if (text_value.len > 4096) return error.LimitsExceeded;
        const label = try self.vault.metadata().dupeSentinel(u8, text_value, 0);
        if (o.kind == .collection) {
            self.collection(o.id).?.label = label;
            self.collection(o.id).?.modified = now();
        } else {
            self.findItem(o.id).?.label = label;
            self.findItem(o.id).?.modified = now();
        }
    } else if (o.kind == .item and eq(prop, "Attributes")) {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        self.findItem(o.id).?.attributes = try Server.attributes(self.vault.metadata(), try attributeValue(arena.allocator(), value));
        self.findItem(o.id).?.modified = now();
    } else return error.InvalidArgs;
    try self.vault.save();
}
fn promptResponse(data: ?*anyopaque, accepted: bool) void {
    const o = cast(Object, data);
    const self = o.server;
    if (!accepted or self.screen_locked or self.sleeping) {
        self.complete(o, true, .{ .string = "" });
        return;
    }
    const dialog = o.dialog.?;
    if (!(dialog.validatePassword() catch {
        self.complete(o, true, .{ .string = "" });
        return;
    })) return;
    self.vault.unlock(dialog.entry.?.buffer.value()) catch {
        dialog.clear();
        dialog.setStatus("Could not unlock passwords. Please try again.", true) catch {
            self.complete(o, true, .{ .string = "" });
            return;
        };
        dialog.focus(.entry);
        return;
    };
    dialog.clear();
    if (o.create) {
        const id = self.createCollection(o.label, o.alias) catch {
            self.vault.restore() catch self.lock();
            self.complete(o, true, .{ .string = "" });
            return;
        };
        self.complete(o, false, .{ .object_path = self.objectPath(.collection, id) });
    } else {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        var unlocked: std.ArrayList([]const u8) = .empty;
        for (o.targets) |target| {
            const exists = if (target.kind == .collection) self.collection(target.id) != null else self.findItem(target.id) != null;
            if (exists) unlocked.append(arena.allocator(), self.objectPath(target.kind, target.id)) catch {};
        }
        self.changed();
        self.complete(o, false, Server.paths(arena.allocator(), unlocked.items) catch .{ .array = .{ .element = "o", .items = &.{} } });
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
            const args = message.read(struct { []const u8, Properties, []const []const u8 }) catch return;
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
fn quit(self: *Server) bool {
    self.stopping = true;
    return true;
}
pub fn run(allocator: std.mem.Allocator) !void {
    const base = @import("desktop-paths.zig").dataHome();
    @import("desktop-paths.zig").makeDirectories(base, 0o700) catch return error.CreateDirectory;
    const directory = try std.fmt.allocPrintSentinel(allocator, "{s}/desktop-secrets", .{base}, 0);
    defer allocator.free(directory);
    return runAt(allocator, directory);
}
pub fn runAt(allocator: std.mem.Allocator, directory: [:0]const u8) !void {
    return runAtWithOptions(allocator, directory, .{});
}
pub fn runAtWithOptions(allocator: std.mem.Allocator, directory: [:0]const u8, options: Options) !void {
    if (p.prctl(p.PR_SET_DUMPABLE, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return error.PrctlFailed;
    var wa = store.WipingAllocator{ .parent = std.heap.page_allocator };
    const a = wa.allocator();
    const source = loop.acquire(a, .session) catch return error.NoSessionBus;
    defer loop.release(source);
    const bus = source.connection;
    var introspection = try dbus.Introspection.parse(a, @embedFile("desktop-secrets.xml"));
    defer introspection.deinit();
    var server = Server{ .ui_allocator = allocator, .a = a, .options = options, .vault = try store.Vault.init(a, directory), .bus = bus, .introspection = introspection };
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
    const system: ?*loop.Source = loop.acquire(allocator, .system) catch null;
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
    const term = mainloop.signal(mainloop.SIGTERM, &server, quit);
    const interrupt = mainloop.signal(mainloop.SIGINT, &server, quit);
    defer {
        _ = mainloop.remove(term);
        _ = mainloop.remove(interrupt);
    }
    while (!server.stopping and !bus.closed) _ = mainloop.iteration(true);
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

/// Calls the source service; the caller reads and releases the reply.
fn sourceCall(bus: *dbus.Connection, owner: []const u8, path: []const u8, interface: []const u8, verb: []const u8, args: anytype) !dbus.Connection.Owned {
    return bus.callBlocking(.{ .destination = owner, .path = path, .interface = interface, .member = verb, .no_auto_start = true }, args, 30000) catch error.SourceUnavailable;
}
/// A property of the source service, copied into `a`.
fn sourceProperty(a: std.mem.Allocator, bus: *dbus.Connection, owner: []const u8, path: []const u8, kind: Kind, prop: []const u8) !dbus.Value {
    const reply = try sourceCall(bus, owner, path, "org.freedesktop.DBus.Properties", "Get", .{ @as([]const u8, iface(kind)), prop });
    defer reply.deinit();
    const value = (reply.message().read(struct { dbus.Value }) catch return error.InvalidSourceReply)[0];
    return value.clone(a);
}
fn objectPaths(value: dbus.Value) ![]const dbus.Value {
    return switch (value) {
        .array => |array| if (eq(array.element, "o")) array.items else error.InvalidSourceReply,
        else => error.InvalidSourceReply,
    };
}
/// Copy from a running, unlocked Secret Service into a new authenticated vault.
/// Pin the unique bus owner for the entire import; never modify the source.
pub fn importAt(directory: [:0]const u8, password: []const u8) !void {
    var wa = store.WipingAllocator{ .parent = std.heap.page_allocator };
    const a = wa.allocator();
    var vault = try store.Vault.init(a, directory);
    defer vault.deinit();
    if (vault.envelope != null and vault.index.collections.len != 0) return error.DestinationNotEmpty;
    // Replies can carry secrets; everything copied from them is wiped when freed.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const bus = dbus.Connection.open(a, .session) catch return error.NoSessionBus;
    defer bus.close();
    const owner = blk: {
        const reply = sourceCall(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", .{@as([]const u8, name)}) catch return error.NoSourceService;
        defer reply.deinit();
        break :blk try scratch.dupe(u8, (reply.message().read(struct { []const u8 }) catch return error.NoSourceService)[0]);
    };
    const session = blk: {
        const reply = try sourceCall(bus, owner, root, iface(.service), "OpenSession", .{ "plain", dbus.Value{ .string = "" } });
        defer reply.deinit();
        break :blk try scratch.dupe(u8, (reply.message().read(struct { dbus.Value, dbus.ObjectPath }) catch return error.InvalidSourceReply)[1].value);
    };
    defer {
        if (sourceCall(bus, owner, session, iface(.session), "Close", .{})) |reply| reply.deinit() else |_| {}
    }
    const collections = try objectPaths(try sourceProperty(scratch, bus, owner, root, .service, "Collections"));
    if (collections.len > 64) return error.LimitsExceeded;
    // Validate all collections before creating the destination.
    for (collections) |path| {
        const locked = try sourceProperty(scratch, bus, owner, path.object_path, .collection, "Locked");
        if (locked != .boolean) return error.InvalidSourceReply;
        if (locked.boolean) return error.SourceLocked;
    }
    try vault.unlock(password);
    const ma = vault.metadata();
    for (collections) |path_value| {
        const path = path_value.object_path;
        const label = try sourceProperty(scratch, bus, owner, path, .collection, "Label");
        if (label != .string) return error.InvalidSourceReply;
        const id = vault.index.next_id;
        vault.index.next_id += 1;
        vault.index.collections = try append(store.Collection, ma, vault.index.collections, .{ .id = id, .label = try ma.dupeSentinel(u8, label.string, 0), .created = now(), .modified = now() });
        for ([_][:0]const u8{ "default", "login" }) |alias| {
            const reply = try sourceCall(bus, owner, root, iface(.service), "ReadAlias", .{@as([]const u8, alias)});
            defer reply.deinit();
            const target = (reply.message().read(struct { dbus.ObjectPath }) catch return error.InvalidSourceReply)[0].value;
            if (eq(target, path)) vault.index.aliases = try append(store.Alias, ma, vault.index.aliases, .{ .name = try ma.dupeSentinel(u8, alias, 0), .collection = id });
        }
        const items = try objectPaths(try sourceProperty(scratch, bus, owner, path, .collection, "Items"));
        for (items) |item_value| {
            if (vault.index.items.len >= 4096) return error.LimitsExceeded;
            const item_path = item_value.object_path;
            const item_label = try sourceProperty(scratch, bus, owner, item_path, .item, "Label");
            if (item_label != .string) return error.InvalidSourceReply;
            const attrs = try attributeValue(scratch, try sourceProperty(scratch, bus, owner, item_path, .item, "Attributes"));
            const reply = try sourceCall(bus, owner, item_path, iface(.item), "GetSecret", .{dbus.ObjectPath{ .value = session }});
            defer reply.deinit();
            const secret = (reply.message().read(struct { Secret }) catch return error.InvalidSourceSecret)[0];
            if (secret[1].value.len != 0 or !eq(secret[0].value, session)) return error.InvalidSourceSecret;
            if (secret[2].value.len > 1024 * 1024) return error.LimitsExceeded;
            const item_id = vault.index.next_id;
            vault.index.next_id += 1;
            vault.index.items = try append(store.Item, ma, vault.index.items, .{ .id = item_id, .collection = id, .label = try ma.dupeSentinel(u8, item_label.string, 0), .attributes = try Server.attributes(ma, attrs), .created = now(), .modified = now() });
            const content_type = try scratch.dupeSentinel(u8, secret[3], 0);
            try vault.setValue(item_id, secret[2].value, content_type);
        }
    }
    if (vault.index.collections.len != 0 and vault.index.aliases.len == 0) vault.index.aliases = try append(store.Alias, ma, vault.index.aliases, .{ .name = "default", .collection = vault.index.collections[0].id });
    try vault.save();
}
pub fn runImport(allocator: std.mem.Allocator) !void {
    if (p.prctl(p.PR_SET_DUMPABLE, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return error.PrctlFailed;
    const a = allocator;
    const dialog = try createImportDialog(a);
    defer dialog.destroy();
    while (true) {
        dialog.run();
        if (!dialog.accepted) return error.Cancelled;
        if (try dialog.validatePassword()) break;
    }
    const base = @import("desktop-paths.zig").dataHome();
    @import("desktop-paths.zig").makeDirectories(base, 0o700) catch return error.CreateDirectory;
    const directory = try std.fmt.allocPrintSentinel(a, "{s}/desktop-secrets", .{base}, 0);
    defer a.free(directory);
    try importAt(directory, dialog.entry.?.buffer.value());
    std.debug.print("Imported Secret Service collections. The source keyring is unchanged.\n", .{});
}
pub fn createImportDialog(allocator: std.mem.Allocator) !*Dialog {
    return Dialog.createWithOptions(allocator, .password, "Choose the destination vault password. Use your login password for automatic unlock.", .{
        .title = "Import Saved Passwords",
        .role = "desktop-secrets-import",
        .accept = "Continue",
        .confirmation = true,
    });
}

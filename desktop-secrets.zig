//! Native Secret Service. Bus sessions and prompts belong to their unique caller.
const std = @import("std");
const c = @import("gtk");
const p = @import("secrets-posix");
pub const store = @import("desktop-secrets-store.zig");
const transport = @import("desktop-secrets-transport.zig");
const root = "/org/freedesktop/secrets";
const name = "org.freedesktop.secrets";
const prefix = "org.freedesktop.Secret.";
pub const Options = struct {
    prompt_ready: ?*const fn (*c.GtkWidget, *c.GtkWidget, ?*c.GtkWidget) void = null,
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
fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}
fn cast(comptime T: type, ptr: anytype) *T {
    return @ptrCast(@alignCast(ptr));
}
fn child(v: ?*c.GVariant, i: usize) *c.GVariant {
    return c.g_variant_get_child_value(v, i).?;
}
fn str(v: ?*c.GVariant) [:0]const u8 {
    return std.mem.span(c.g_variant_get_string(v, null));
}
fn text(v: ?*c.GVariant, i: usize) [:0]const u8 {
    const value = child(v, i);
    defer c.g_variant_unref(value);
    return str(value);
}
fn build(comptime signature: [:0]const u8) *c.GVariantBuilder {
    return c.g_variant_builder_new(@ptrCast(signature.ptr)).?;
}
fn bytes(v: ?*c.GVariant) []const u8 {
    var n: usize = 0;
    const data = c.g_variant_get_fixed_array(v, &n, 1);
    return if (n == 0) &.{} else @as([*]const u8, @ptrCast(data))[0..n];
}
fn byteVariant(value: []const u8) *c.GVariant {
    return c.g_variant_new_fixed_array(@ptrCast(@as([*:0]const u8, "y")), value.ptr, value.len, 1).?;
}
fn stringVariant(value: [:0]const u8) *c.GVariant {
    return variantString(value.ptr).?;
}
fn now() u64 {
    return @intCast(@divTrunc(c.g_get_real_time(), 1000000));
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
    registration: c_uint = 0,
    key: ?[16]u8 = null,
    dialog: ?*c.GtkWidget = null,
    entry: ?*c.GtkWidget = null,
    confirmation: ?*c.GtkWidget = null,
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
    bus: *c.GDBusConnection,
    node: *c.GDBusNodeInfo,
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
        o.registration = c.g_dbus_connection_register_object(self.bus, o.path, self.node.*.interfaces[@backingInt(kind)], &vtable, o, null, null);
        if (o.registration == 0) return error.RegistrationFailed;
        errdefer _ = c.g_dbus_connection_unregister_object(self.bus, o.registration);
        try self.objects.append(self.a, o);
        return o;
    }
    fn remove(self: *Server, o: *Object) void {
        if (o.dialog) |dialog| {
            if (o.entry) |entry| c.gtk_entry_set_text(cast(c.GtkEntry, entry), "");
            if (o.confirmation) |entry| c.gtk_entry_set_text(cast(c.GtkEntry, entry), "");
            c.gtk_widget_destroy(dialog);
        }
        _ = c.g_dbus_connection_unregister_object(self.bus, o.registration);
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
        _ = c.g_dbus_connection_emit_signal(self.bus, null, path, iface(kind), member, c.g_variant_new("(o)", target.ptr), null);
    }
    fn changed(self: *Server) void {
        for (self.objects.items) |o| {
            if (o.kind != .collection and o.kind != .item and o.kind != .service) continue;
            const dict = build("a{sv}");
            defer c.g_variant_builder_unref(dict);
            const names: []const [:0]const u8 = switch (o.kind) {
                .service => &.{"Collections"},
                .collection => &.{ "Items", "Label", "Locked", "Modified" },
                else => &.{ "Attributes", "Label", "Locked", "Modified" },
            };
            for (names) |prop| {
                if (self.property(o, prop)) |v| c.g_variant_builder_add(dict, "{sv}", prop.ptr, v);
            }
            const invalidated = build("as");
            defer c.g_variant_builder_unref(invalidated);
            _ = c.g_dbus_connection_emit_signal(self.bus, null, o.path, "org.freedesktop.DBus.Properties", "PropertiesChanged", c.g_variant_new("(s@a{sv}@as)", iface(o.kind).ptr, c.g_variant_builder_end(dict), c.g_variant_builder_end(invalidated)), null);
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
        _ = c.g_dbus_connection_emit_signal(self.bus, o.owner, o.path, iface(.prompt), "Completed", c.g_variant_new("(bv)", @as(c_int, @intFromBool(dismissed)), result), null);
        self.remove(o);
    }
    fn showPrompt(self: *Server, o: *Object) !void {
        if (o.started) return error.InvalidArgs;
        if (self.screen_locked or self.sleeping) return error.IsLocked;
        o.started = true;
        // The service can start during PAM login before Wayland exists. GTK is initialized only here.
        if (c.gtk_init_check(null, null) == 0) return error.DisplayUnavailable;
        const dialog = c.gtk_dialog_new().?;
        o.dialog = dialog;
        c.gtk_window_set_title(cast(c.GtkWindow, dialog), "Unlock Passwords");
        c.gtk_window_set_modal(cast(c.GtkWindow, dialog), 1);
        _ = c.gtk_dialog_add_button(cast(c.GtkDialog, dialog), "Cancel", c.GTK_RESPONSE_CANCEL);
        _ = c.gtk_dialog_add_button(cast(c.GtkDialog, dialog), "Unlock", c.GTK_RESPONSE_OK);
        c.gtk_dialog_set_default_response(cast(c.GtkDialog, dialog), c.GTK_RESPONSE_OK);
        const area = c.gtk_dialog_get_content_area(cast(c.GtkDialog, dialog));
        const label = c.gtk_label_new(if (self.vault.envelope == null) "Choose a password for your new password vault." else "Enter your password to unlock saved passwords.").?;
        c.gtk_box_pack_start(cast(c.GtkBox, area), label, 0, 0, 12);
        const entry = c.gtk_entry_new().?;
        o.entry = entry;
        c.gtk_entry_set_visibility(cast(c.GtkEntry, entry), 0);
        c.gtk_entry_set_activates_default(cast(c.GtkEntry, entry), 1);
        c.gtk_box_pack_start(cast(c.GtkBox, area), entry, 0, 0, 12);
        if (self.vault.envelope == null) {
            const confirmation = c.gtk_entry_new().?;
            o.confirmation = confirmation;
            c.gtk_entry_set_visibility(cast(c.GtkEntry, confirmation), 0);
            c.gtk_entry_set_placeholder_text(cast(c.GtkEntry, confirmation), "Confirm password");
            c.gtk_entry_set_activates_default(cast(c.GtkEntry, confirmation), 1);
            c.gtk_box_pack_start(cast(c.GtkBox, area), confirmation, 0, 0, 12);
        }
        _ = c.g_signal_connect_data(dialog, "response", @ptrCast(&promptResponse), o, null, 0);
        c.gtk_widget_show_all(dialog);
        c.gtk_widget_grab_focus(entry);
        if (self.options.prompt_ready) |ready| ready(dialog, entry, o.confirmation);
    }
    fn method(self: *Server, o: *Object, owner: [:0]const u8, verb: []const u8, args: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation, a: std.mem.Allocator) !void {
        if (o.owner.len != 0 and !eq(o.owner, owner)) return error.AccessDenied;
        if (o.kind == .login) {
            if (eq(verb, "SetScreenLocked")) {
                const value = child(args, 0);
                defer c.g_variant_unref(value);
                self.screen_locked = c.g_variant_get_boolean(value) != 0;
                if (self.screen_locked) self.lock();
                c.g_dbus_method_invocation_return_value(invocation, null);
                return;
            }
            if (self.screen_locked or self.sleeping) return error.IsLocked;
            const password = child(args, 0);
            defer c.g_variant_unref(password);
            try self.vault.unlock(bytes(password));
            if (self.vault.index.collections.len == 0) _ = try self.createCollection("Login", "default");
            self.changed();
            c.g_dbus_method_invocation_return_value(invocation, null);
            return;
        }
        if (o.kind == .session) {
            c.g_dbus_method_invocation_return_value(invocation, null);
            self.remove(o);
            return;
        }
        if (o.kind == .prompt) {
            if (eq(verb, "Dismiss")) {
                c.g_dbus_method_invocation_return_value(invocation, null);
                self.complete(o, true, variantString("").?);
                return;
            }
            self.showPrompt(o) catch {
                c.g_dbus_method_invocation_return_value(invocation, null);
                self.complete(o, true, variantString("").?);
                return;
            };
            c.g_dbus_method_invocation_return_value(invocation, null);
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
            c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(vo)", output, s.path.ptr));
            return;
        }
        if (eq(verb, "ReadAlias")) {
            c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(o)", self.objectPath(.collection, self.aliasId(text(args, 0))).ptr));
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
            c.g_dbus_method_invocation_return_value(invocation, null);
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
                c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(oo)", @as([*:0]const u8, "/"), prompt.path.ptr));
                return;
            }
            const id = try self.createCollection(label, alias);
            c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(oo)", self.objectPath(.collection, id).ptr, @as([*:0]const u8, "/")));
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
            if (o.kind == .collection) c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(@ao)", result)) else {
                const other = c.g_variant_builder_end(empty);
                c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(@ao@ao)", if (self.vault.key == null) other else result, if (self.vault.key == null) result else other));
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
            c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(@aoo)", c.g_variant_builder_end(found), prompt_path.ptr));
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
            c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(@a{o(oayays)})", c.g_variant_builder_end(dict)));
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
            c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(oo)", self.objectPath(.item, id).ptr, @as([*:0]const u8, "/")));
            return;
        }
        if (eq(verb, "GetSecret")) {
            const s = try self.session(text(args, 0), owner);
            c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(@(oayays))", try self.encode(o.id, s, a)));
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
            c.g_dbus_method_invocation_return_value(invocation, null);
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
            c.g_dbus_method_invocation_return_value(invocation, c.g_variant_new("(o)", @as([*:0]const u8, "/")));
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
fn methodCall(_: ?*c.GDBusConnection, owner: [*c]const u8, _: [*c]const u8, _: [*c]const u8, method: [*c]const u8, args: ?*c.GVariant, invocation: ?*c.GDBusMethodInvocation, data: ?*anyopaque) callconv(.c) void {
    const o = cast(Object, data);
    const self = o.server;
    var arena = std.heap.ArenaAllocator.init(self.a);
    defer arena.deinit();
    self.method(o, std.mem.span(owner), std.mem.span(method), args, invocation, arena.allocator()) catch |err| {
        // Restore the last committed version after any rejected mutation.
        self.vault.restore() catch {
            self.lock();
            self.stopping = true;
        };
        self.reconcile() catch {
            self.stopping = true;
        };
        c.g_dbus_method_invocation_return_dbus_error(invocation, errorName(err), @errorName(err));
    };
}
fn getProperty(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, prop: [*c]const u8, _: [*c][*c]c.GError, data: ?*anyopaque) callconv(.c) ?*c.GVariant {
    const o = cast(Object, data);
    return o.server.property(o, std.mem.span(prop));
}
fn setProperty(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, prop: [*c]const u8, value: ?*c.GVariant, err: [*c][*c]c.GError, data: ?*anyopaque) callconv(.c) c_int {
    const o = cast(Object, data);
    const self = o.server;
    setPropertyValue(o, std.mem.span(prop), value) catch |failure| {
        self.vault.restore() catch {
            self.lock();
            self.stopping = true;
        };
        c.g_dbus_error_set_dbus_error(err, errorName(failure), @errorName(failure), null);
        return 0;
    };
    self.changed();
    if (o.kind == .item) self.signal(self.objectPath(.collection, self.findItem(o.id).?.collection), .collection, "ItemChanged", o.path) else self.signal(root, .service, "CollectionChanged", o.path);
    return 1;
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
const vtable = c.GDBusInterfaceVTable{ .method_call = &methodCall, .get_property = &getProperty, .set_property = &setProperty };
fn promptResponse(_: *c.GtkDialog, response: c_int, data: ?*anyopaque) callconv(.c) void {
    const o = cast(Object, data);
    const self = o.server;
    if (response != c.GTK_RESPONSE_OK or self.screen_locked or self.sleeping) {
        self.complete(o, true, stringVariant(""));
        return;
    }
    const password = std.mem.span(c.gtk_entry_get_text(cast(c.GtkEntry, o.entry.?)));
    if (o.confirmation) |entry| {
        if (!eq(password, std.mem.span(c.gtk_entry_get_text(cast(c.GtkEntry, entry))))) {
            c.gtk_window_set_title(cast(c.GtkWindow, o.dialog.?), "Passwords do not match");
            return;
        }
    }
    self.vault.unlock(password) catch {
        c.gtk_entry_set_text(cast(c.GtkEntry, o.entry.?), "");
        c.gtk_window_set_title(cast(c.GtkWindow, o.dialog.?), "Could not unlock passwords — try again");
        return;
    };
    c.gtk_entry_set_text(cast(c.GtkEntry, o.entry.?), "");
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
fn ownerChanged(_: ?*c.GDBusConnection, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, _: [*c]const u8, args: ?*c.GVariant, data: ?*anyopaque) callconv(.c) void {
    if (text(args, 2).len != 0) return;
    const self = cast(Server, data);
    const owner = text(args, 0);
    var i: usize = 0;
    while (i < self.objects.items.len) {
        const o = self.objects.items[i];
        if (o.owner.len != 0 and eq(o.owner, owner)) self.remove(o) else i += 1;
    }
}
fn sessionSignal(_: ?*c.GDBusConnection, _: [*c]const u8, path: [*c]const u8, _: [*c]const u8, member: [*c]const u8, args: ?*c.GVariant, data: ?*anyopaque) callconv(.c) void {
    const self = cast(Server, data);
    if (eq(std.mem.span(member), "PrepareForSleep")) {
        const sleeping = child(args, 0);
        defer c.g_variant_unref(sleeping);
        self.sleeping = c.g_variant_get_boolean(sleeping) != 0;
        if (self.sleeping) self.lock();
    } else if (self.logind != null and eq(self.logind.?, std.mem.span(path))) {
        if (eq(std.mem.span(member), "Lock")) {
            self.screen_locked = true;
            self.lock();
        }
        if (eq(std.mem.span(member), "Unlock")) self.screen_locked = false;
        if (eq(std.mem.span(member), "PropertiesChanged") and eq(text(args, 0), "org.freedesktop.login1.Session")) {
            const properties = child(args, 1);
            defer c.g_variant_unref(properties);
            const locked = c.g_variant_lookup_value(properties, "LockedHint", @ptrCast(@as([*:0]const u8, "b"))) orelse return;
            defer c.g_variant_unref(locked);
            self.screen_locked = c.g_variant_get_boolean(locked) != 0;
            if (self.screen_locked) self.lock();
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
    const bus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, null) orelse return error.NoSessionBus;
    defer c.g_object_unref(bus);
    const node = c.g_dbus_node_info_new_for_xml(@embedFile("desktop-secrets.xml"), null) orelse return error.InvalidXml;
    defer c.g_dbus_node_info_unref(node);
    var server = Server{ .a = a, .options = options, .vault = try store.Vault.init(a, directory), .bus = bus, .node = node };
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
    const reply = c.g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", c.g_variant_new("(su)", @as([*:0]const u8, name), @as(c_uint, 4)), @ptrCast(@as([*:0]const u8, "(u)")), 0, 3000, null, null) orelse return error.NameUnavailable;
    defer c.g_variant_unref(reply);
    const status = child(reply, 0);
    defer c.g_variant_unref(status);
    if (c.g_variant_get_uint32(status) != 1) return error.NameUnavailable;
    const owners = c.g_dbus_connection_signal_subscribe(bus, "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", null, 0, &ownerChanged, &server, null);
    defer c.g_dbus_connection_signal_unsubscribe(bus, owners);
    const system = c.g_bus_get_sync(c.G_BUS_TYPE_SYSTEM, null, null);
    var locks: c_uint = 0;
    var sleep: c_uint = 0;
    var hints: c_uint = 0;
    defer if (system) |connection| {
        c.g_dbus_connection_signal_unsubscribe(connection, locks);
        c.g_dbus_connection_signal_unsubscribe(connection, sleep);
        c.g_dbus_connection_signal_unsubscribe(connection, hints);
        c.g_object_unref(connection);
    };
    if (system) |connection| {
        const session = c.g_dbus_connection_call_sync(connection, "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "GetSessionByPID", c.g_variant_new("(u)", @as(c_uint, @intCast(p.getpid()))), @ptrCast(@as([*:0]const u8, "(o)")), 0, 3000, null, null);
        if (session) |v| {
            defer c.g_variant_unref(v);
            server.logind = try a.dupeSentinel(u8, text(v, 0), 0);
        }
        locks = c.g_dbus_connection_signal_subscribe(connection, "org.freedesktop.login1", "org.freedesktop.login1.Session", null, null, null, 0, &sessionSignal, &server, null);
        hints = c.g_dbus_connection_signal_subscribe(connection, "org.freedesktop.login1", "org.freedesktop.DBus.Properties", "PropertiesChanged", null, null, 0, &sessionSignal, &server, null);
        sleep = c.g_dbus_connection_signal_subscribe(connection, "org.freedesktop.login1", "org.freedesktop.login1.Manager", "PrepareForSleep", "/org/freedesktop/login1", null, 0, &sessionSignal, &server, null);
    }
    const term = c.g_unix_signal_add(c.SIGTERM, &quit, &server);
    const interrupt = c.g_unix_signal_add(c.SIGINT, &quit, &server);
    defer {
        _ = c.g_source_remove(term);
        _ = c.g_source_remove(interrupt);
    }
    while (!server.stopping and c.g_dbus_connection_is_closed(bus) == 0) _ = c.g_main_context_iteration(null, 1);
}
/// Called by PAM's dropped-privilege helper. Passwords travel through stdin, never argv or environment.
pub fn loginUnlock(password: []const u8) !void {
    const bus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, null) orelse return error.NoSessionBus;
    defer c.g_object_unref(bus);
    const reply = c.g_dbus_connection_call_sync(bus, name, root, "org.dotfiles.Desktop.Secrets", "LoginUnlock", c.g_variant_new("(@ay)", byteVariant(password)), null, 0, 30000, null, null) orelse return error.UnlockFailed;
    c.g_variant_unref(reply);
}
test {
    _ = transport;
    _ = @import("tests/desktop-secrets-store.zig");
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

fn sourceCall(bus: *c.GDBusConnection, owner: [:0]const u8, path: [:0]const u8, interface: [:0]const u8, verb: [:0]const u8, args: ?*c.GVariant) !*c.GVariant {
    return c.g_dbus_connection_call_sync(bus, owner, path, interface, verb, args, null, c.G_DBUS_CALL_FLAGS_NO_AUTO_START, 30000, null, null) orelse error.SourceUnavailable;
}
fn sourceProperty(bus: *c.GDBusConnection, owner: [:0]const u8, path: [:0]const u8, kind: Kind, prop: [:0]const u8) !*c.GVariant {
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
    const bus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, null) orelse return error.NoSessionBus;
    defer c.g_object_unref(bus);
    const owned = c.g_dbus_connection_call_sync(bus, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "GetNameOwner", c.g_variant_new("(s)", @as([*:0]const u8, name)), null, 0, 3000, null, null) orelse return error.NoSourceService;
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
    if (c.gtk_init_check(null, null) == 0) return error.DisplayUnavailable;
    var wa = store.WipingAllocator{ .parent = std.heap.page_allocator };
    const a = wa.allocator();
    const password = try migrationPassword(a, "Choose the destination vault password. Use your login password for automatic unlock.");
    defer a.free(password);
    const confirmation = try migrationPassword(a, "Confirm the destination vault password.");
    defer a.free(confirmation);
    if (!eq(password, confirmation)) return error.PasswordsDoNotMatch;
    const base = std.mem.span(c.g_get_user_data_dir());
    if (c.g_mkdir_with_parents(base.ptr, 0o700) != 0) return error.CreateDirectory;
    const directory = try std.fmt.allocPrintSentinel(a, "{s}/desktop-secrets", .{base}, 0);
    defer a.free(directory);
    try importAt(directory, password);
    std.debug.print("Imported Secret Service collections. The source keyring is unchanged.\n", .{});
}
fn migrationPassword(a: std.mem.Allocator, prompt: [:0]const u8) ![]u8 {
    const dialog = c.gtk_dialog_new().?;
    defer c.gtk_widget_destroy(dialog);
    c.gtk_window_set_title(cast(c.GtkWindow, dialog), "Import Saved Passwords");
    _ = c.gtk_dialog_add_button(cast(c.GtkDialog, dialog), "Cancel", c.GTK_RESPONSE_CANCEL);
    _ = c.gtk_dialog_add_button(cast(c.GtkDialog, dialog), "Continue", c.GTK_RESPONSE_OK);
    c.gtk_dialog_set_default_response(cast(c.GtkDialog, dialog), c.GTK_RESPONSE_OK);
    const area = c.gtk_dialog_get_content_area(cast(c.GtkDialog, dialog));
    c.gtk_box_pack_start(cast(c.GtkBox, area), c.gtk_label_new(prompt.ptr), 0, 0, 12);
    const entry = c.gtk_entry_new().?;
    defer c.gtk_entry_set_text(cast(c.GtkEntry, entry), "");
    c.gtk_entry_set_visibility(cast(c.GtkEntry, entry), 0);
    c.gtk_entry_set_activates_default(cast(c.GtkEntry, entry), 1);
    c.gtk_box_pack_start(cast(c.GtkBox, area), entry, 0, 0, 12);
    c.gtk_widget_show_all(dialog);
    c.gtk_widget_grab_focus(entry);
    if (c.gtk_dialog_run(cast(c.GtkDialog, dialog)) != c.GTK_RESPONSE_OK) return error.Cancelled;
    const value = std.mem.span(c.gtk_entry_get_text(cast(c.GtkEntry, entry)));
    if (value.len == 0 or value.len > 4096) return error.InvalidPassword;
    return a.dupe(u8, value);
}

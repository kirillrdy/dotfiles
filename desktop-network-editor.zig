//! Native connection properties. Unknown settings round-trip without libnm.
const std = @import("std");
const mainloop = @import("desktop-loop.zig");
const util = @import("desktop-util.zig");
const dbus = @import("dbus");
const variant_text = @import("desktop-dbus-text.zig");
const native = @import("desktop-form.zig");
const network = @import("desktop-network.zig");
const Settings = network.Settings;
const presentation = @import("desktop-network-editor-view.zig");
const raster = @import("desktop-raster.zig");
const cast = util.cast;
fn z(a: std.mem.Allocator, s: []const u8) [:0]u8 {
    return util.dupeZ(a, s);
}
const eq = util.eq;
fn text(w: *native.Item) [:0]const u8 {
    return w.value();
}
const Field = struct { group: [:0]const u8, key: [:0]const u8, title: [:0]const u8, kind: [:0]const u8, hint: [:0]const u8 = "" };
const fields = [_]Field{
    .{ .group = "connection", .key = "id", .title = "Connection name", .kind = "s" },
    .{ .group = "connection", .key = "type", .title = "Connection type", .kind = "s", .hint = "802-3-ethernet, 802-11-wireless, bridge, bond, vlan, vpn, wireguard…" },
    .{ .group = "connection", .key = "interface-name", .title = "Interface", .kind = "s", .hint = "Leave empty for any compatible interface" },
    .{ .group = "connection", .key = "autoconnect", .title = "Connect automatically", .kind = "b" },
    .{ .group = "connection", .key = "controller", .title = "Bridge or bond controller", .kind = "s" },
    .{ .group = "connection", .key = "port-type", .title = "Port type", .kind = "s", .hint = "bridge, bond, team" },
    .{ .group = "802-3-ethernet", .key = "mtu", .title = "MTU", .kind = "u", .hint = "0 for automatic" },
    .{ .group = "802-3-ethernet", .key = "cloned-mac-address", .title = "Cloned MAC address", .kind = "s" },
    .{ .group = "802-11-wireless", .key = "ssid", .title = "Wi-Fi network name", .kind = "ay" },
    .{ .group = "802-11-wireless", .key = "mode", .title = "Wi-Fi mode", .kind = "s", .hint = "infrastructure, ap, adhoc" },
    .{ .group = "802-11-wireless", .key = "hidden", .title = "Hidden network", .kind = "b" },
    .{ .group = "802-11-wireless-security", .key = "key-mgmt", .title = "Wi-Fi authentication", .kind = "s", .hint = "wpa-psk, sae, wpa-eap, owe, none" },
    .{ .group = "802-11-wireless-security", .key = "psk", .title = "Wi-Fi password", .kind = "s", .hint = "Leave empty to keep the saved password" },
    .{ .group = "802-1x", .key = "eap", .title = "EAP methods", .kind = "as", .hint = "peap, tls, ttls" },
    .{ .group = "802-1x", .key = "identity", .title = "Identity", .kind = "s" },
    .{ .group = "802-1x", .key = "anonymous-identity", .title = "Anonymous identity", .kind = "s" },
    .{ .group = "802-1x", .key = "password", .title = "EAP password", .kind = "s", .hint = "Leave empty to keep the saved password" },
    .{ .group = "802-1x", .key = "phase2-auth", .title = "Inner authentication", .kind = "s", .hint = "mschapv2, pap, chap, gtc" },
    .{ .group = "bridge", .key = "stp", .title = "Spanning Tree Protocol", .kind = "b" },
    .{ .group = "bond", .key = "options", .title = "Bond options", .kind = "a{ss}", .hint = "{'mode': 'active-backup', 'miimon': '100'}" },
    .{ .group = "vlan", .key = "parent", .title = "Parent interface", .kind = "s" },
    .{ .group = "vlan", .key = "id", .title = "VLAN ID", .kind = "u" },
    .{ .group = "vpn", .key = "service-type", .title = "VPN service", .kind = "s" },
    .{ .group = "vpn", .key = "data", .title = "VPN options", .kind = "a{ss}", .hint = "{'gateway': 'vpn.example.com'}" },
    .{ .group = "vpn", .key = "secrets", .title = "VPN credentials", .kind = "a{ss}" },
    .{ .group = "wireguard", .key = "private-key", .title = "Private key", .kind = "s" },
    .{ .group = "wireguard", .key = "listen-port", .title = "Listen port", .kind = "u" },
    .{ .group = "wireguard", .key = "peers", .title = "Peers", .kind = "aa{sv}" },
};
const ip_fields = [_]struct { key: [:0]const u8, title: [:0]const u8, kind: [:0]const u8, hint: [:0]const u8 = "" }{
    .{ .key = "method", .title = "Configuration", .kind = "s", .hint = "auto, manual, link-local, shared, disabled (IPv6 also dhcp, ignore)" },
    .{ .key = "address-data", .title = "Addresses", .kind = "aa{sv}", .hint = "Address/prefix, separated by commas" },
    .{ .key = "gateway", .title = "Gateway", .kind = "s" },
    .{ .key = "dns-data", .title = "DNS servers", .kind = "as", .hint = "Separated by commas" },
    .{ .key = "dns-search", .title = "Search domains", .kind = "as", .hint = "Separated by commas" },
    .{ .key = "ignore-auto-dns", .title = "Ignore automatic DNS", .kind = "b" },
    .{ .key = "never-default", .title = "Use only for resources on this network", .kind = "b" },
    .{ .key = "route-data", .title = "Routes", .kind = "aa{sv}", .hint = "[{'dest': <'10.0.0.0'>, 'prefix': <uint32 8>, 'next-hop': <'192.168.1.1'>}]" },
    .{ .key = "ignore-auto-routes", .title = "Ignore automatic routes", .kind = "b" },
};
pub const Row = struct {
    group: [:0]u8,
    key: [:0]u8,
    kind: [:0]u8,
    widget: *native.Item,
    remove: *native.Item,
    /// The loaded value, borrowed from the editor's base settings.
    original: ?dbus.Value,
    initial: [:0]u8,
    preserve_original: bool = false,
    bytes_as_text: bool = false,
    addresses_as_text: bool = false,
    fn deinit(self: *Row, a: std.mem.Allocator) void {
        a.free(self.group);
        a.free(self.key);
        a.free(self.kind);
        a.free(self.initial);
    }
    /// The row's value, allocated from `arena`; null leaves the property at its default.
    fn value(self: *Row, arena: std.mem.Allocator) !?dbus.Value {
        if (self.remove.checked) return null;
        if (self.preserve_original) return self.original.?;
        if (eq(self.kind, "b")) return .{ .boolean = self.widget.checked };
        const entered = text(self.widget);
        // Preserve the original representation, including unrecognised address attributes.
        if (self.original) |v| if (eq(entered, self.initial)) return v;
        if (entered.len == 0) return null;
        if (eq(self.kind, "s")) return .{ .string = try arena.dupe(u8, entered) };
        if (self.bytes_as_text) {
            if (entered.len > 32) return error.InvalidSSIDLength;
            return .{ .bytes = try arena.dupe(u8, entered) };
        }
        if (self.addresses_as_text) return try parseAddresses(arena, entered, eq(self.group, "ipv6"));
        if (eq(self.kind, "as")) {
            var items: std.ArrayList(dbus.Value) = .empty;
            var parts = std.mem.tokenizeAny(u8, entered, ", \t\n");
            while (parts.next()) |part| try items.append(arena, .{ .string = try arena.dupe(u8, part) });
            return .{ .array = .{ .element = "s", .items = items.items } };
        }
        return variant_text.parse(arena, self.kind, entered) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidText => error.InvalidPropertyValue,
        };
    }
};
/// Parses "address/prefix, ..." into NetworkManager's `aa{sv}` address data.
pub fn parseAddresses(arena: std.mem.Allocator, input: []const u8, ipv6: bool) !dbus.Value {
    var items: std.ArrayList(dbus.Value) = .empty;
    var addresses = std.mem.tokenizeAny(u8, input, ", \t\n");
    while (addresses.next()) |cidr| {
        const slash = std.mem.lastIndexOfScalar(u8, cidr, '/') orelse return error.AddressNeedsPrefix;
        const address = cidr[0..slash];
        const parsed = std.Io.net.IpAddress.parse(address, 0) catch return error.InvalidIPAddress;
        if ((parsed == .ip6) != ipv6) return error.WrongAddressFamily;
        const prefix = std.fmt.parseInt(u32, cidr[slash + 1 ..], 10) catch return error.InvalidPrefix;
        if (prefix > @as(u32, if (ipv6) 128 else 32)) return error.InvalidPrefix;
        try items.append(arena, try dictionary(arena, &.{ .{ "address", .{ .string = try arena.dupe(u8, address) } }, .{ "prefix", .{ .uint32 = prefix } } }));
    }
    return .{ .array = .{ .element = "a{sv}", .items = items.items } };
}
const dictionary = @import("desktop-portal-options.zig").toValue;
/// A dictionary entry's value with any variant wrapper removed.
fn lookupString(dict: dbus.Value, key: []const u8) ?[]const u8 {
    return switch (dict.lookup(key) orelse return null) {
        .string => |v| v,
        else => null,
    };
}
fn lookupUint(dict: dbus.Value, key: []const u8) ?u32 {
    return switch (dict.lookup(key) orelse return null) {
        .uint32 => |v| v,
        else => null,
    };
}
pub const Editor = struct {
    allocator: std.mem.Allocator,
    window: *native.host.Window,
    ui: *native.Form,
    message: *native.Item,
    save_button: *native.Item,
    client: *network.Client,
    base: *Settings,
    cancel: *mainloop.Cancellable,
    path: ?[:0]u8,
    version: u64,
    rows: std.ArrayList(Row) = .empty,
    refs: usize = 1,
    closed: bool = false,
    saving: bool = false,
    property_group: *native.Item,
    property_key: *native.Item,
    property_type: *native.Item,
    view: presentation.View = .{},
    presented_fields: std.ArrayList(presentation.Field) = .empty,
    pub fn create(parent: *native.host.Window, io: std.Io, profile: ?network.Profile) *Editor {
        return createWithBase(parent, io, profile, null);
    }
    pub fn createWireless(parent: *native.host.Window, io: std.Io, ap: network.AccessPoint) *Editor {
        const a = parent.allocator;
        const base = template(a, io, ap) catch @panic("out of memory");
        defer base.unref();
        const self = createWithBase(parent, io, null, base);
        self.view.strength = ap.strength;
        if (ap.security == .enterprise) self.view.page = .security;
        a.free(self.ui.title);
        self.ui.title = z(a, ap.title);
        self.window.setTitle(self.ui.title);
        self.ui.relayout();
        return self;
    }
    fn createWithBase(parent: *native.host.Window, io: std.Io, profile: ?network.Profile, initial: ?*Settings) *Editor {
        const a = parent.allocator;
        const self = a.create(Editor) catch @panic("out of memory");
        const ui = native.Form.create(a, if (profile) |p| p.title else "New Connection", self, &action, &fieldChanged) catch @panic("out of memory");
        const window = ui.window;
        window.parent = parent;
        // Rows borrow their original values from these settings for the editor's lifetime.
        const base = if (initial) |value| value.ref() else if (profile) |p| p.base.ref() else template(a, io, null) catch @panic("out of memory");
        self.* = .{ .allocator = a, .window = window, .ui = ui, .message = undefined, .save_button = undefined, .cancel = mainloop.Cancellable.create(), .path = if (profile) |p| z(a, p.path) else null, .version = if (profile) |p| p.version else 0, .client = network.Client.create(a, &changed, self) catch @panic("out of memory"), .base = base, .property_group = undefined, .property_key = undefined, .property_type = undefined };
        // Known fields first; every other property remains editable below them.
        for (fields) |field| {
            if (base.group(field.group) != null or eq(field.group, "connection")) self.addRow(field, base.get(field.group, field.key));
        }
        for ([_][:0]const u8{ "ipv4", "ipv6" }) |section| for (ip_fields) |field| self.addRow(.{ .group = section, .key = field.key, .title = field.title, .kind = field.kind, .hint = field.hint }, base.get(section, field.key));
        for (base.groups.items) |group| for (group.properties.items) |property| {
            if (self.row(group.name, property.key) != null) continue;
            var buffer: [256]u8 = undefined;
            const kind = property.value.signatureInto(&buffer) catch continue;
            const group_name = z(a, group.name);
            defer a.free(group_name);
            const key_name = z(a, property.key);
            defer a.free(key_name);
            const kind_name = z(a, kind);
            defer a.free(kind_name);
            self.addRow(.{ .group = group_name, .key = key_name, .title = key_name, .kind = kind_name }, property.value);
        };
        _ = ui.add(.heading, "Additional connection properties", "", false) catch @panic("out of memory");
        self.property_group = ui.get(ui.add(.entry, "Section", "e.g. ipv4, vlan, 802-1x", false) catch @panic("out of memory"));
        self.property_key = ui.get(ui.add(.entry, "Property", "e.g. mtu, parent, identity", false) catch @panic("out of memory"));
        self.property_type = ui.get(ui.add(.entry, "Value type", "s: text, b: boolean, u: unsigned integer, as: text list", false) catch @panic("out of memory"));
        const add_property = ui.add(.button, "Add property", "", false) catch @panic("out of memory");
        self.message = ui.get(ui.addPinned(.label, "") catch @panic("out of memory"));
        self.save_button = ui.get(ui.addPinned(.button, "Apply") catch @panic("out of memory"));
        const cancel_button = ui.get(ui.addPinned(.button, "Cancel") catch @panic("out of memory"));
        cancel_button.always_enabled = true;
        self.view = .{
            .page = if (profile != null) .details else .identity,
            .cancel = cancel_button.id,
            .apply = self.save_button.id,
            .message = self.message.id,
            .property_group = self.property_group.id,
            .property_key = self.property_key.id,
            .property_type = self.property_type.id,
            .add_property = add_property,
            .connected = if (profile) |p| p.active else false,
            .kind = ui.add(.choice, "Connection Type", "", false) catch @panic("out of memory"),
            .ipv4 = ui.add(.choice, "IPv4 Method", "", false) catch @panic("out of memory"),
            .ipv6 = ui.add(.choice, "IPv6 Method", "", false) catch @panic("out of memory"),
            .security = ui.add(.choice, "Security", "", false) catch @panic("out of memory"),
            .dot1x = ui.add(.toggle, "802.1X Authentication", "", false) catch @panic("out of memory"),
        };
        for (presentation.titles, &self.view.tabs) |title, *id| {
            id.* = ui.add(.button, title, "", false) catch @panic("out of memory");
            ui.get(id.*).always_enabled = true;
        }
        ui.setOptions(self.view.kind, &.{
            .{ .id = "802-3-ethernet", .label = "Ethernet" }, .{ .id = "802-11-wireless", .label = "Wi-Fi" }, .{ .id = "bridge", .label = "Bridge" }, .{ .id = "bond", .label = "Bond" }, .{ .id = "vlan", .label = "VLAN" }, .{ .id = "vpn", .label = "VPN" }, .{ .id = "wireguard", .label = "WireGuard" },
        }, false) catch @panic("out of memory");
        ui.setOptions(self.view.ipv4, &.{
            .{ .id = "auto", .label = "Automatic (DHCP)" }, .{ .id = "manual", .label = "Manual" }, .{ .id = "link-local", .label = "Link-Local Only" }, .{ .id = "shared", .label = "Shared to Other Computers" }, .{ .id = "disabled", .label = "Disabled" },
        }, false) catch @panic("out of memory");
        ui.setOptions(self.view.ipv6, &.{
            .{ .id = "auto", .label = "Automatic" }, .{ .id = "dhcp", .label = "Automatic, DHCP Only" }, .{ .id = "manual", .label = "Manual" }, .{ .id = "link-local", .label = "Link-Local Only" }, .{ .id = "ignore", .label = "Ignore" }, .{ .id = "disabled", .label = "Disabled" },
        }, false) catch @panic("out of memory");
        ui.setOptions(self.view.security, &.{
            .{ .id = "", .label = "None" }, .{ .id = "wpa-psk", .label = "WPA & WPA2 Personal" }, .{ .id = "sae", .label = "WPA3 Personal" }, .{ .id = "wpa-eap", .label = "WPA & WPA2 Enterprise" }, .{ .id = "owe", .label = "Enhanced Open" }, .{ .id = "none", .label = "WEP" },
        }, false) catch @panic("out of memory");
        if (profile) |snapshot| for (self.client.state().access_points.items) |ap| if (eq(ap.ssid, snapshot.ssid)) {
            self.view.strength = ap.strength;
            break;
        };
        self.rebuildPresentation();
        window.setSize(720, 640);
        ui.window.surface.?.options.min_width = 680;
        ui.window.surface.?.options.min_height = 400;
        ui.layout = &layout;
        ui.painter = &paint;
        ui.scrolled = &scroll;
        ui.reveal = &reveal;
        ui.close_callback = &destroyed;
        ui.show();
        return self;
    }
    pub fn row(self: *Editor, group: []const u8, key: []const u8) ?*Row {
        for (self.rows.items) |*r| if (eq(r.group, group) and eq(r.key, key)) return r;
        return null;
    }
    fn layout(ui: *native.Form) void {
        cast(Editor, ui.context).view.layout(ui);
    }
    fn paint(ui: *native.Form, target: raster.Buffer, scale: u32) !void {
        try cast(Editor, ui.context).view.paint(ui, target, scale);
    }
    fn scroll(ptr: ?*anyopaque, delta: f64) void {
        const self = cast(Editor, ptr);
        self.view.offset = std.math.clamp(self.view.offset + delta, 0, self.view.maxOffset());
        self.ui.relayout();
    }
    fn reveal(ptr: ?*anyopaque, id: usize) void {
        const self = cast(Editor, ptr);
        const r = self.ui.get(id).bounds;
        if (r.y == 6 or r.y == 46) return;
        if (r.y < 100) self.view.offset = @max(0, self.view.offset + r.y - 100);
        if (r.y + r.height > self.view.frame.height - 16) self.view.offset += r.y + r.height - self.view.frame.height + 16;
        self.ui.relayout();
    }
    fn rebuildPresentation(self: *Editor) void {
        self.view.fields = &.{};
        self.presented_fields.clearRetainingCapacity();
        for (self.rows.items) |r| self.presented_fields.append(self.allocator, .{ .id = r.widget.id, .remove = r.remove.id, .group = r.group, .key = r.key, .page = presentation.section(r.group, r.key) }) catch @panic("out of memory");
        self.view.fields = self.presented_fields.items;
        self.ui.get(self.view.dot1x).checked = false;
        for (self.rows.items) |r| if (eq(r.group, "802-1x") and !r.remove.checked and (r.original != null or r.widget.value().len > 0)) {
            self.ui.get(self.view.dot1x).checked = true;
            break;
        };
        const kind = if (self.row("connection", "type")) |r| r.widget.value() else "";
        self.ui.get(self.view.tabs[4]).enabled = eq(kind, "802-11-wireless") or eq(kind, "802-3-ethernet");
        for ([_]struct { id: usize, group: []const u8, key: []const u8 }{
            .{ .id = self.view.kind, .group = "connection", .key = "type" }, .{ .id = self.view.ipv4, .group = "ipv4", .key = "method" }, .{ .id = self.view.ipv6, .group = "ipv6", .key = "method" }, .{ .id = self.view.security, .group = "802-11-wireless-security", .key = "key-mgmt" },
        }) |control| {
            _ = self.ui.select(control.id, if (self.row(control.group, control.key)) |r| r.widget.value() else "");
        }
    }
    fn addRow(self: *Editor, field: Field, original: ?dbus.Value) void {
        var kind_buffer: [256]u8 = undefined;
        const kind: []const u8 = if (original) |v| v.signatureInto(&kind_buffer) catch field.kind else field.kind;
        const widget = self.ui.get(self.ui.add(if (eq(kind, "b")) .toggle else .entry, field.title, field.hint, network.secretProperty(field.key) and !std.mem.endsWith(u8, field.key, "-flags")) catch @panic("out of memory"));
        const default_label = std.fmt.allocPrintSentinel(self.allocator, "Use default · {s}", .{field.key}, 0) catch @panic("out of memory");
        defer self.allocator.free(default_label);
        const remove = self.ui.get(self.ui.add(.toggle, default_label, "", false) catch @panic("out of memory"));
        remove.checked = original == null and eq(kind, "b");
        var initial: [:0]u8 = z(self.allocator, "");
        var preserve_original = false;
        var byte_text = eq(field.key, "ssid");
        var address_text = eq(field.key, "address-data");
        if (original) |v| {
            if (eq(kind, "b")) widget.checked = v.boolean else {
                self.allocator.free(initial);
                initial = self.initialText(v, kind, &byte_text, &address_text);
                self.ui.setText(widget.id, initial) catch {
                    // Arbitrary values must still round-trip losslessly.
                    preserve_original = true;
                    self.ui.setText(widget.id, "[Original value preserved; too large or multiline to edit]") catch {};
                    widget.enabled = false;
                };
            }
        }
        self.rows.append(self.allocator, .{ .group = z(self.allocator, field.group), .key = z(self.allocator, field.key), .kind = z(self.allocator, kind), .widget = widget, .remove = remove, .original = original, .initial = initial, .preserve_original = preserve_original, .bytes_as_text = byte_text, .addresses_as_text = address_text }) catch @panic("out of memory");
    }
    /// How a loaded value is shown: plain text for common forms, the GVariant text format otherwise.
    fn initialText(self: *Editor, v: dbus.Value, kind: []const u8, byte_text: *bool, address_text: *bool) [:0]u8 {
        if (eq(kind, "s")) return z(self.allocator, v.string);
        if (byte_text.* and !eq(kind, "ay")) byte_text.* = false;
        if (address_text.* and !eq(kind, "aa{sv}")) address_text.* = false;
        if (byte_text.*) {
            const bytes = v.bytes;
            if (std.unicode.utf8ValidateSlice(bytes) and std.mem.indexOfScalar(u8, bytes, 0) == null) return z(self.allocator, bytes);
            byte_text.* = false;
        } else if (eq(kind, "as")) {
            var list: std.ArrayList(u8) = .empty;
            defer list.deinit(self.allocator);
            for (v.array.items, 0..) |item, i| {
                if (i != 0) list.appendSlice(self.allocator, ", ") catch @panic("out of memory");
                list.appendSlice(self.allocator, item.string) catch @panic("out of memory");
            }
            return z(self.allocator, list.items);
        } else if (address_text.*) {
            var list: std.ArrayList(u8) = .empty;
            defer list.deinit(self.allocator);
            for (v.array.items, 0..) |address, i| {
                // Only plain address/prefix pairs are shown as text; anything else stays exact.
                const ip = lookupString(address, "address");
                const prefix = lookupUint(address, "prefix");
                if (ip == null or prefix == null or address.array.items.len != 2) {
                    address_text.* = false;
                    break;
                }
                list.print(self.allocator, "{s}{s}/{d}", .{ if (i == 0) "" else ", ", ip.?, prefix.? }) catch @panic("out of memory");
            }
            if (address_text.*) return z(self.allocator, list.items);
        }
        const printed = variant_text.print(self.allocator, v) catch @panic("out of memory");
        defer self.allocator.free(printed);
        return z(self.allocator, printed);
    }
    fn fieldChanged(ptr: ?*anyopaque, id: usize) void {
        const self = cast(Editor, ptr);
        if (self.closed or self.saving) return;
        if (id == self.view.dot1x) {
            const enabled = self.ui.get(id).checked;
            if (enabled) for (fields) |field| {
                if (eq(field.group, "802-1x") and self.row(field.group, field.key) == null) self.addRow(field, null);
            };
            if (enabled) if (self.row("802-1x", "eap")) |r| if (r.widget.value().len == 0) self.ui.setText(r.widget.id, "tls") catch {};
            for (self.rows.items) |*r| if (eq(r.group, "802-1x")) {
                r.remove.checked = !enabled;
            };
            self.rebuildPresentation();
            self.ui.relayout();
            return;
        }
        if (id == self.view.kind or id == self.view.ipv4 or id == self.view.ipv6 or id == self.view.security) {
            const value = self.ui.get(id).selectedId() orelse return;
            // A row may be appended below; retain the selection across form updates.
            const group: []const u8 = if (id == self.view.kind) "connection" else if (id == self.view.ipv4) "ipv4" else if (id == self.view.ipv6) "ipv6" else "802-11-wireless-security";
            const key: []const u8 = if (id == self.view.kind) "type" else if (id == self.view.security) "key-mgmt" else "method";
            if (self.row(group, key) == null) self.addRow(.{ .group = "802-11-wireless-security", .key = "key-mgmt", .title = "Security", .kind = "s" }, null);
            if (id == self.view.security and value.len == 0) for (self.rows.items) |*r| {
                if (eq(r.group, "802-11-wireless-security") or eq(r.group, "802-1x")) {
                    if (r.widget.entry) |entry| if (!entry.echo) entry.clear();
                    r.remove.checked = true;
                }
            };
            if (id == self.view.security and value.len > 0) {
                for (fields) |field| {
                    const personal = eq(value, "wpa-psk") or eq(value, "sae");
                    const enterprise = eq(value, "wpa-eap");
                    if (((personal and eq(field.group, "802-11-wireless-security") and eq(field.key, "psk")) or (enterprise and eq(field.group, "802-1x"))) and self.row(field.group, field.key) == null) self.addRow(field, null);
                }
                if (eq(value, "none") and self.row("802-11-wireless-security", "wep-key0") == null) self.addRow(.{ .group = "802-11-wireless-security", .key = "wep-key0", .title = "WEP Password", .kind = "s" }, null);
            }
            self.setValue(group, key, value) catch {};
            if (id == self.view.security and value.len == 0) for (self.rows.items) |*r| {
                if (eq(r.group, "802-11-wireless-security") or eq(r.group, "802-1x")) r.remove.checked = true;
            };
            self.view.offset = 0;
            self.rebuildPresentation();
            self.ui.relayout();
            return;
        }
        for (self.rows.items) |*r| if (r.widget.id == id) {
            r.remove.checked = false;
        };
        const kind_row = self.row("connection", "type") orelse return;
        if (kind_row.widget.id == id) self.kindChanged();
    }
    fn action(ptr: ?*anyopaque, id: usize) void {
        const self = cast(Editor, ptr);
        for (self.view.tabs, presentation.pages) |tab, page| if (id == tab) {
            self.view.page = page;
            self.view.offset = 0;
            self.ui.expanded = null;
            self.ui.focus = null;
            self.ui.relayout();
            return;
        };
        if (id == self.save_button.id) {
            self.save();
            return;
        }
        const title = self.ui.get(id).title;
        if (eq(title, "Save")) self.save() else if (eq(title, "Cancel")) self.ui.close() else if (eq(title, "Add property")) self.addProperty();
    }
    pub fn setValue(self: *Editor, group: []const u8, key: []const u8, value: [:0]const u8) !void {
        const field = self.row(group, key) orelse return error.UnknownProperty;
        if (field.preserve_original) return error.ReadOnlyProperty;
        try self.ui.setText(field.widget.id, value);
        fieldChanged(self, field.widget.id);
    }
    fn kindChanged(self: *Editor) void {
        const kind_row = self.row("connection", "type") orelse return;
        const kind = text(kind_row.widget);
        for (fields) |field| {
            const wifi = eq(kind, "802-11-wireless") and (eq(field.group, "802-11-wireless-security") or eq(field.group, "802-1x"));
            if ((eq(field.group, kind) or wifi) and self.row(field.group, field.key) == null) self.addRow(field, null);
        }
        self.rebuildPresentation();
        self.ui.relayout();
    }
    fn addProperty(self: *Editor) void {
        const group = text(self.property_group);
        const key = text(self.property_key);
        const kind = text(self.property_type);
        if (group.len == 0 or key.len == 0 or !dbus.isSingleType(kind) or self.row(group, key) != null) {
            self.setMessage("Enter a new section, property and valid value type.");
            return;
        }
        self.addRow(.{ .group = group, .key = key, .title = key, .kind = kind }, null);
        self.rebuildPresentation();
        self.ui.relayout();
    }
    /// The edited settings; the caller owns the returned reference.
    pub fn values(self: *Editor) !*Settings {
        const out = try Settings.create(self.allocator);
        errdefer out.unref();
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        for (self.rows.items) |*r| {
            const modern: ?[]const u8 = if (eq(r.key, "dns")) "dns-data" else if (eq(r.key, "addresses")) "address-data" else if (eq(r.key, "routes")) "route-data" else null;
            if (modern) |key| if (self.row(r.group, key)) |replacement| {
                if (text(replacement.widget).len != 0 and !replacement.remove.checked) continue;
            };
            const value = r.value(scratch.allocator()) catch |err| {
                const message = std.fmt.allocPrintSentinel(self.allocator, "{s} · {s}: {s}", .{ r.group, r.key, @errorName(err) }, 0) catch @panic("out of memory");
                defer self.allocator.free(message);
                self.setMessage(message);
                return err;
            } orelse continue;
            try out.put(r.group, r.key, value);
        }
        // The group named by the connection type must exist, even when empty.
        if (self.row("connection", "type")) |kind_row| {
            const kind = text(kind_row.widget);
            if (kind.len > 0) _ = try out.ensureGroup(kind);
        }
        return out;
    }
    pub fn save(self: *Editor) void {
        if (self.saving or self.closed) return;
        const settings = self.values() catch return;
        defer settings.unref();
        if (settings.text("connection", "id").len == 0) {
            self.setMessage("Enter a connection name.");
            return;
        }
        self.saving = true;
        self.refs += 1;
        self.ui.setEnabled(false);
        self.setMessage("Saving connection…");
        self.client.perform(.{ .save = .{ .path = self.path, .settings = settings, .version = self.version } }, self.cancel, &saved, self);
    }
    fn saved(ptr: ?*anyopaque, result: network.Result) void {
        const self = cast(Editor, ptr);
        defer self.unref();
        self.saving = false;
        if (self.closed) return;
        if (result == .success) {
            self.ui.close();
            return;
        }
        self.setMessage(result.failure);
        self.ui.setEnabled(true);
    }
    fn changed(_: ?*anyopaque, _: *network.Client) void {}
    fn destroyed(ptr: ?*anyopaque) void {
        const self = cast(Editor, ptr);
        self.closed = true;
        self.cancel.cancel();
        self.unref();
    }
    fn unref(self: *Editor) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        self.client.destroy();
        self.base.unref();
        self.cancel.unref();
        if (self.path) |path| self.allocator.free(path);
        for (self.rows.items) |*r| r.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.presented_fields.deinit(self.allocator);
        self.ui.deinit();
        self.allocator.destroy(self);
    }
    fn setMessage(self: *Editor, message: [:0]const u8) void {
        self.ui.setText(self.message.id, message) catch {};
    }
};
fn template(a: std.mem.Allocator, io: std.Io, ap: ?network.AccessPoint) !*Settings {
    const out = try Settings.create(a);
    errdefer out.unref();
    try out.put("connection", "id", .{ .string = if (ap) |point| point.title else "New connection" });
    try out.put("connection", "uuid", .{ .string = &uuid(io) });
    try out.put("connection", "type", .{ .string = if (ap != null) "802-11-wireless" else "802-3-ethernet" });
    try out.put("connection", "autoconnect", .{ .boolean = true });
    for ([_][]const u8{ "ipv4", "ipv6" }) |group| try out.put(group, "method", .{ .string = "auto" });
    const device = if (ap != null) "802-11-wireless" else "802-3-ethernet";
    _ = try out.ensureGroup(device);
    if (ap) |point| {
        try out.put(device, "ssid", .{ .bytes = point.ssid });
        try out.put(device, "mode", .{ .string = "infrastructure" });
        if (point.security != .open) try out.put("802-11-wireless-security", "key-mgmt", .{ .string = switch (point.security) {
            .open => "",
            .wep => "none",
            .personal => "wpa-psk",
            .sae => "sae",
            .enterprise => "wpa-eap",
            .owe => "owe",
        } });
        if (point.security == .enterprise) try out.put("802-1x", "eap", .{ .array = .{ .element = "s", .items = &.{.{ .string = "peap" }} } });
    }
    return out;
}
/// A random (version 4) UUID in its usual text form.
fn uuid(io: std.Io) [36]u8 {
    var raw: [16]u8 = undefined;
    @import("desktop-secrets-store.zig").random(io, &raw) catch @panic("no randomness available");
    raw[6] = (raw[6] & 0x0f) | 0x40;
    raw[8] = (raw[8] & 0x3f) | 0x80;
    var out: [36]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}-{x}-{x}-{x}-{x}", .{ raw[0..4], raw[4..6], raw[6..8], raw[8..10], raw[10..16] }) catch unreachable;
    return out;
}

//! Native connection properties. Unknown settings round-trip without libnm.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const native = @import("desktop-form.zig");
const network = @import("desktop-network.zig");
const presentation = @import("desktop-network-editor-view.zig");
const raster = @import("desktop-raster.zig");
const g = network.api;
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
const cast = c.__zig.cast;
fn z(s: []const u8) [:0]u8 {
    return c.__zig.dupeZ(a, s);
}
const eq = c.__zig.eq;
fn text(w: *native.Item) [:0]const u8 {
    return w.value();
}
const builder = c.__zig.variant.builder;
fn add(b: *c.GVariantBuilder, key: [:0]const u8, value: *c.GVariant) void {
    c.g_variant_builder_add(b, "{sv}", key.ptr, value);
}
const lookup = c.__zig.variant.nested;
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
    original: ?*c.GVariant,
    initial: [:0]u8,
    preserve_original: bool = false,
    bytes_as_text: bool = false,
    addresses_as_text: bool = false,
    fn deinit(self: *Row) void {
        a.free(self.group);
        a.free(self.key);
        a.free(self.kind);
        a.free(self.initial);
        if (self.original) |v| c.g_variant_unref(v);
    }
    fn value(self: *Row) !?*c.GVariant {
        if (self.remove.checked) return null;
        if (self.preserve_original) return c.g_variant_ref(self.original.?);
        if (eq(self.kind, "b")) {
            const enabled: c_int = @intFromBool(self.widget.checked);
            return c.g_variant_ref_sink(c.g_variant_new("b", enabled));
        }
        const entered = text(self.widget);
        // Preserve the original representation, including unrecognised address attributes.
        if (self.original) |v| if (eq(entered, self.initial)) return c.g_variant_ref(v);
        if (entered.len == 0) return null;
        if (eq(self.kind, "s")) return c.g_variant_ref_sink(c.g_variant_new("s", entered.ptr));
        if (self.bytes_as_text) {
            if (entered.len > 32) return error.InvalidSSIDLength;
            return c.g_variant_ref_sink(c.__zig.variant.byteArray(entered));
        }
        if (self.addresses_as_text) return parseAddresses(entered, eq(self.group, "ipv6"));
        if (eq(self.kind, "as")) {
            const out = builder("as");
            defer c.g_variant_builder_unref(out);
            var parts = std.mem.tokenizeAny(u8, entered, ", \t\n");
            while (parts.next()) |part| {
                const part_z = z(part);
                defer a.free(part_z);
                c.g_variant_builder_add(out, "s", part_z.ptr);
            }
            return c.g_variant_ref_sink(c.g_variant_builder_end(out));
        }
        var err: [*c]c.GError = null;
        defer c.g_clear_error(&err);
        return c.g_variant_parse(@ptrCast(self.kind.ptr), entered.ptr, null, null, &err) orelse error.InvalidPropertyValue;
    }
};
pub fn parseAddresses(input: []const u8, ipv6: bool) !*c.GVariant {
    const out = builder("aa{sv}");
    defer c.g_variant_builder_unref(out);
    var addresses = std.mem.tokenizeAny(u8, input, ", \t\n");
    while (addresses.next()) |cidr| {
        const slash = std.mem.lastIndexOfScalar(u8, cidr, '/') orelse return error.AddressNeedsPrefix;
        const address = cidr[0..slash];
        const parsed = std.Io.net.IpAddress.parse(address, 0) catch return error.InvalidIPAddress;
        if ((parsed == .ip6) != ipv6) return error.WrongAddressFamily;
        const prefix = std.fmt.parseInt(u32, cidr[slash + 1 ..], 10) catch return error.InvalidPrefix;
        if (prefix > @as(u32, if (ipv6) 128 else 32)) return error.InvalidPrefix;
        const inner = builder("a{sv}");
        defer c.g_variant_builder_unref(inner);
        const address_z = z(address);
        defer a.free(address_z);
        add(inner, "address", c.g_variant_new("s", address_z.ptr).?);
        add(inner, "prefix", c.g_variant_new("u", prefix).?);
        c.g_variant_builder_add(out, "@a{sv}", c.g_variant_builder_end(inner));
    }
    return c.g_variant_ref_sink(c.g_variant_builder_end(out)).?;
}
pub const Editor = struct {
    window: *native.host.Window,
    ui: *native.Form,
    message: *native.Item,
    save_button: *native.Item,
    client: *network.Client,
    cancel: *c.GCancellable,
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
    pub fn create(parent: *native.host.Window, profile: ?network.Profile) *Editor {
        return createWithBase(parent, profile, null);
    }
    pub fn createWireless(parent: *native.host.Window, ap: network.AccessPoint) *Editor {
        const base = template(ap);
        defer c.g_variant_unref(base);
        const self = createWithBase(parent, null, base);
        self.view.strength = ap.strength;
        if (ap.security == .enterprise) self.view.page = .security;
        a.free(self.ui.title);
        self.ui.title = z(ap.title);
        self.window.setTitle(self.ui.title);
        self.ui.relayout();
        return self;
    }
    fn createWithBase(parent: *native.host.Window, profile: ?network.Profile, initial: ?*c.GVariant) *Editor {
        const self = a.create(Editor) catch @panic("out of memory");
        const ui = native.Form.create(if (profile) |p| p.title else "New Connection", self, &action, &fieldChanged) catch @panic("out of memory");
        const window = ui.window;
        window.parent = parent;
        self.* = .{ .window = window, .ui = ui, .message = undefined, .save_button = undefined, .cancel = c.g_cancellable_new().?, .path = if (profile) |p| z(p.path) else null, .version = if (profile) |p| p.version else 0, .client = network.Client.create(&changed, self) catch @panic("out of memory"), .property_group = undefined, .property_key = undefined, .property_type = undefined };
        const base = if (initial) |value| c.g_variant_ref(value).? else if (profile) |p| c.g_variant_ref(p.base).? else template(null);
        defer c.g_variant_unref(base);
        // Known fields first; every other property remains editable below them.
        for (fields) |field| {
            const section = c.g_variant_lookup_value(base, field.group, null);
            defer if (section) |v| c.g_variant_unref(v);
            if (section != null or eq(field.group, "connection")) self.addRow(field, lookup(base, field.group, field.key));
        }
        for ([_][:0]const u8{ "ipv4", "ipv6" }) |section| for (ip_fields) |field| self.addRow(.{ .group = section, .key = field.key, .title = field.title, .kind = field.kind, .hint = field.hint }, lookup(base, section, field.key));
        for (0..c.g_variant_n_children(base)) |i| {
            const pair = c.g_variant_get_child_value(base, i).?;
            defer c.g_variant_unref(pair);
            const key = c.g_variant_get_child_value(pair, 0).?;
            defer c.g_variant_unref(key);
            const group_name = std.mem.span(c.g_variant_get_string(key, null));
            const dict = c.g_variant_get_child_value(pair, 1).?;
            defer c.g_variant_unref(dict);
            for (0..c.g_variant_n_children(dict)) |j| {
                const property = c.g_variant_get_child_value(dict, j).?;
                defer c.g_variant_unref(property);
                const k = c.g_variant_get_child_value(property, 0).?;
                defer c.g_variant_unref(k);
                const key_name = std.mem.span(c.g_variant_get_string(k, null));
                if (self.row(group_name, key_name) != null) continue;
                const wrapped = c.g_variant_get_child_value(property, 1).?;
                defer c.g_variant_unref(wrapped);
                const value = c.g_variant_get_variant(wrapped).?;
                self.addRow(.{ .group = group_name, .key = key_name, .title = key_name, .kind = std.mem.span(c.g_variant_get_type_string(value)) }, value);
            }
        }
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
        for (self.rows.items) |r| self.presented_fields.append(a, .{ .id = r.widget.id, .remove = r.remove.id, .group = r.group, .key = r.key, .page = presentation.section(r.group, r.key) }) catch @panic("out of memory");
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
    fn addRow(self: *Editor, field: Field, original: ?*c.GVariant) void {
        const kind = if (original) |v| std.mem.span(c.g_variant_get_type_string(v)) else field.kind;
        const widget = self.ui.get(self.ui.add(if (eq(kind, "b")) .toggle else .entry, field.title, field.hint, network.secretProperty(field.key) and !std.mem.endsWith(u8, field.key, "-flags")) catch @panic("out of memory"));
        const default_label = std.fmt.allocPrintSentinel(a, "Use default · {s}", .{field.key}, 0) catch @panic("out of memory");
        defer a.free(default_label);
        const remove = self.ui.get(self.ui.add(.toggle, default_label, "", false) catch @panic("out of memory"));
        remove.checked = original == null and eq(kind, "b");
        var initial: [:0]u8 = z("");
        var preserve_original = false;
        var byte_text = eq(field.key, "ssid");
        var address_text = eq(field.key, "address-data");
        if (original) |v| {
            if (eq(kind, "b")) widget.checked = c.g_variant_get_boolean(v) != 0 else {
                a.free(initial);
                if (eq(kind, "s")) initial = z(std.mem.span(c.g_variant_get_string(v, null))) else if (byte_text) blk: {
                    var len: usize = 0;
                    const raw = c.g_variant_get_fixed_array(v, &len, 1);
                    const bytes = if (raw) |p| @as([*]const u8, @ptrCast(p))[0..len] else "";
                    if (std.unicode.utf8ValidateSlice(bytes) and std.mem.indexOfScalar(u8, bytes, 0) == null) {
                        initial = z(bytes);
                        break :blk;
                    }
                    byte_text = false;
                    const printed = c.g_variant_print(v, 1);
                    defer c.g_free(printed);
                    initial = z(std.mem.span(printed));
                } else if (eq(kind, "as")) {
                    var list: std.ArrayList(u8) = .empty;
                    defer list.deinit(a);
                    for (0..c.g_variant_n_children(v)) |i| {
                        const value = c.g_variant_get_child_value(v, i).?;
                        defer c.g_variant_unref(value);
                        if (i != 0) list.appendSlice(a, ", ") catch @panic("out of memory");
                        list.appendSlice(a, std.mem.span(c.g_variant_get_string(value, null))) catch @panic("out of memory");
                    }
                    initial = z(list.items);
                } else if (address_text) {
                    var list: std.ArrayList(u8) = .empty;
                    defer list.deinit(a);
                    for (0..c.g_variant_n_children(v)) |i| {
                        const address = c.g_variant_get_child_value(v, i).?;
                        defer c.g_variant_unref(address);
                        const ip = c.g_variant_lookup_value(address, "address", @ptrCast(@as([*:0]const u8, "s"))) orelse {
                            address_text = false;
                            break;
                        };
                        defer c.g_variant_unref(ip);
                        const prefix = c.g_variant_lookup_value(address, "prefix", @ptrCast(@as([*:0]const u8, "u"))) orelse {
                            address_text = false;
                            break;
                        };
                        defer c.g_variant_unref(prefix);
                        const cidr = std.fmt.allocPrint(a, "{s}{s}/{d}", .{ if (i == 0) "" else ", ", std.mem.span(c.g_variant_get_string(ip, null)), c.g_variant_get_uint32(prefix) }) catch @panic("out of memory");
                        defer a.free(cidr);
                        list.appendSlice(a, cidr) catch @panic("out of memory");
                        if (c.g_variant_n_children(address) != 2) {
                            address_text = false;
                            break;
                        }
                    }
                    if (address_text) initial = z(list.items) else {
                        const printed = c.g_variant_print(v, 1);
                        defer c.g_free(printed);
                        initial = z(std.mem.span(printed));
                    }
                } else {
                    const printed = c.g_variant_print(v, 1);
                    defer c.g_free(printed);
                    initial = z(std.mem.span(printed));
                }
                self.ui.setText(widget.id, initial) catch {
                    // Arbitrary GVariant data must still round-trip losslessly.
                    preserve_original = true;
                    self.ui.setText(widget.id, "[Original value preserved; too large or multiline to edit]") catch {};
                    widget.enabled = false;
                };
            }
        }
        self.rows.append(a, .{ .group = z(field.group), .key = z(field.key), .kind = z(kind), .widget = widget, .remove = remove, .original = original, .initial = initial, .preserve_original = preserve_original, .bytes_as_text = byte_text, .addresses_as_text = address_text }) catch @panic("out of memory");
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
        if (group.len == 0 or key.len == 0 or c.g_variant_type_string_is_valid(kind) == 0 or c.g_variant_type_is_definite(@ptrCast(kind.ptr)) == 0 or self.row(group, key) != null) {
            self.setMessage("Enter a new section, property and valid value type.");
            return;
        }
        self.addRow(.{ .group = group, .key = key, .title = key, .kind = kind }, null);
        self.rebuildPresentation();
        self.ui.relayout();
    }
    pub fn values(self: *Editor) !*c.GVariant {
        const Group = struct { name: [:0]const u8, value: *c.GVariantBuilder };
        var groups: std.ArrayList(Group) = .empty;
        defer {
            for (groups.items) |group| c.g_variant_builder_unref(group.value);
            groups.deinit(a);
        }
        for (self.rows.items) |*r| {
            const modern: ?[]const u8 = if (eq(r.key, "dns")) "dns-data" else if (eq(r.key, "addresses")) "address-data" else if (eq(r.key, "routes")) "route-data" else null;
            if (modern) |key| if (self.row(r.group, key)) |replacement| {
                if (text(replacement.widget).len != 0 and !replacement.remove.checked) continue;
            };
            const value = r.value() catch |err| {
                const message = std.fmt.allocPrintSentinel(a, "{s} · {s}: {s}", .{ r.group, r.key, @errorName(err) }, 0) catch @panic("out of memory");
                defer a.free(message);
                self.setMessage(message);
                return err;
            } orelse continue;
            defer c.g_variant_unref(value);
            var group_builder: ?*c.GVariantBuilder = null;
            for (groups.items) |group| if (eq(group.name, r.group)) {
                group_builder = group.value;
                break;
            };
            if (group_builder == null) {
                group_builder = builder("a{sv}");
                try groups.append(a, .{ .name = r.group, .value = group_builder.? });
            }
            add(group_builder.?, r.key, value);
        }
        if (self.row("connection", "type")) |kind_row| {
            const kind = text(kind_row.widget);
            var found = false;
            for (groups.items) |group| {
                if (eq(group.name, kind)) found = true;
            }
            if (!found and kind.len > 0) try groups.append(a, .{ .name = kind, .value = builder("a{sv}") });
        }
        const out = builder("a{sa{sv}}");
        defer c.g_variant_builder_unref(out);
        for (groups.items) |group| c.g_variant_builder_add(out, "{s@a{sv}}", group.name.ptr, c.g_variant_builder_end(group.value));
        return c.g_variant_ref_sink(c.g_variant_builder_end(out)).?;
    }
    pub fn save(self: *Editor) void {
        if (self.saving or self.closed) return;
        const settings = self.values() catch return;
        defer c.g_variant_unref(settings);
        const id = lookup(settings, "connection", "id");
        defer if (id) |v| c.g_variant_unref(v);
        if (id == null or std.mem.span(c.g_variant_get_string(id, null)).len == 0) {
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
        c.g_cancellable_cancel(self.cancel);
        self.unref();
    }
    fn unref(self: *Editor) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        self.client.destroy();
        c.g_object_unref(self.cancel);
        if (self.path) |path| a.free(path);
        for (self.rows.items) |*r| r.deinit();
        self.rows.deinit(a);
        self.presented_fields.deinit(a);
        self.ui.deinit();
        a.destroy(self);
    }
    fn setMessage(self: *Editor, message: [:0]const u8) void {
        self.ui.setText(self.message.id, message) catch {};
    }
};
fn template(ap: ?network.AccessPoint) *c.GVariant {
    const uuid = c.g_uuid_string_random();
    defer c.g_free(uuid);
    const out = builder("a{sa{sv}}");
    defer c.g_variant_builder_unref(out);
    const connection = builder("a{sv}");
    defer c.g_variant_builder_unref(connection);
    add(connection, "id", c.g_variant_new("s", if (ap) |point| point.title.ptr else @as([*:0]const u8, "New connection")).?);
    add(connection, "uuid", c.g_variant_new("s", uuid).?);
    add(connection, "type", c.g_variant_new("s", @as([*:0]const u8, if (ap != null) "802-11-wireless" else "802-3-ethernet")).?);
    add(connection, "autoconnect", c.g_variant_new("b", @as(c_int, 1)).?);
    c.g_variant_builder_add(out, "{s@a{sv}}", @as([*:0]const u8, "connection"), c.g_variant_builder_end(connection));
    for ([_][:0]const u8{ "ipv4", "ipv6" }) |group| {
        const inner = builder("a{sv}");
        defer c.g_variant_builder_unref(inner);
        add(inner, "method", c.g_variant_new("s", @as([*:0]const u8, "auto")).?);
        c.g_variant_builder_add(out, "{s@a{sv}}", group.ptr, c.g_variant_builder_end(inner));
    }
    const device = builder("a{sv}");
    defer c.g_variant_builder_unref(device);
    if (ap) |point| {
        add(device, "ssid", c.__zig.variant.byteArray(point.ssid));
        add(device, "mode", c.g_variant_new("s", @as([*:0]const u8, "infrastructure")).?);
        if (point.security != .open) {
            const auth = builder("a{sv}");
            defer c.g_variant_builder_unref(auth);
            const key: [*:0]const u8 = switch (point.security) {
                .open => "",
                .wep => "none",
                .personal => "wpa-psk",
                .sae => "sae",
                .enterprise => "wpa-eap",
                .owe => "owe",
            };
            add(auth, "key-mgmt", c.g_variant_new("s", key).?);
            c.g_variant_builder_add(out, "{s@a{sv}}", @as([*:0]const u8, "802-11-wireless-security"), c.g_variant_builder_end(auth));
        }
        if (point.security == .enterprise) {
            const enterprise = builder("a{sv}");
            defer c.g_variant_builder_unref(enterprise);
            const methods = builder("as");
            defer c.g_variant_builder_unref(methods);
            c.g_variant_builder_add(methods, "s", @as([*:0]const u8, "peap"));
            add(enterprise, "eap", c.g_variant_builder_end(methods).?);
            c.g_variant_builder_add(out, "{s@a{sv}}", @as([*:0]const u8, "802-1x"), c.g_variant_builder_end(enterprise));
        }
    }
    c.g_variant_builder_add(out, "{s@a{sv}}", @as([*:0]const u8, if (ap != null) "802-11-wireless" else "802-3-ethernet"), c.g_variant_builder_end(device));
    return c.g_variant_ref_sink(c.g_variant_builder_end(out)).?;
}

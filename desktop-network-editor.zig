//! Native connection properties. Unknown settings round-trip without libnm.
const std = @import("std");
const c = @import("gtk");
const network = @import("network");
const g = network.api;
const a = if (@import("builtin").is_test) std.testing.allocator else std.heap.page_allocator;
fn cast(comptime T: type, p: anytype) *T {
    return @ptrCast(@alignCast(p));
}
fn z(s: []const u8) [:0]u8 {
    return a.dupeSentinel(u8, s, 0) catch @panic("out of memory");
}
fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}
fn pack(box: *c.GtkWidget, widget: *c.GtkWidget) void {
    c.gtk_box_pack_start(cast(c.GtkBox, box), widget, 0, 0, 0);
}
fn label(caption: [*:0]const u8) *c.GtkWidget {
    const w = c.gtk_label_new(caption).?;
    c.gtk_label_set_xalign(cast(c.GtkLabel, w), 0);
    return w;
}
fn entry(box: *c.GtkWidget, title: [*:0]const u8, hint: [*:0]const u8) *c.GtkWidget {
    pack(box, label(title));
    const w = c.gtk_entry_new().?;
    c.gtk_entry_set_placeholder_text(cast(c.GtkEntry, w), hint);
    pack(box, w);
    return w;
}
fn text(w: *c.GtkWidget) [:0]const u8 {
    return std.mem.span(c.gtk_entry_get_text(cast(c.GtkEntry, w)));
}
fn builder(kind: [:0]const u8) *g.GVariantBuilder {
    return g.g_variant_builder_new(@ptrCast(kind));
}
fn add(b: *g.GVariantBuilder, key: [:0]const u8, value: *c.GVariant) void {
    g.g_variant_builder_add(b, "{sv}", key.ptr, value);
}
fn lookup(base: *c.GVariant, group: [:0]const u8, key: [:0]const u8) ?*c.GVariant {
    const section = c.g_variant_lookup_value(base, group, null) orelse return null;
    defer c.g_variant_unref(section);
    return c.g_variant_lookup_value(section, key, null);
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
    widget: *c.GtkWidget,
    remove: *c.GtkWidget,
    original: ?*c.GVariant,
    initial: [:0]u8,
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
        if (c.gtk_toggle_button_get_active(cast(c.GtkToggleButton, self.remove)) != 0) return null;
        if (eq(self.kind, "b")) {
            const enabled = c.gtk_toggle_button_get_active(cast(c.GtkToggleButton, self.widget));
            return g.g_variant_ref_sink(c.g_variant_new("b", enabled));
        }
        const entered = text(self.widget);
        // Preserve the original representation, including unrecognised address attributes.
        if (self.original) |v| if (eq(entered, self.initial)) return g.g_variant_ref(v);
        if (entered.len == 0) return null;
        if (eq(self.kind, "s")) return g.g_variant_ref_sink(c.g_variant_new("s", entered.ptr));
        if (self.bytes_as_text) {
            if (entered.len > 32) return error.InvalidSSIDLength;
            return g.g_variant_ref_sink(g.g_variant_new_fixed_array(@ptrCast(@as([*:0]const u8, "y")), entered.ptr, entered.len, 1));
        }
        if (self.addresses_as_text) return parseAddresses(entered, eq(self.group, "ipv6"));
        if (eq(self.kind, "as")) {
            const out = builder("as");
            defer g.g_variant_builder_unref(out);
            var parts = std.mem.tokenizeAny(u8, entered, ", \t\n");
            while (parts.next()) |part| {
                const part_z = z(part);
                defer a.free(part_z);
                g.g_variant_builder_add(out, "s", part_z.ptr);
            }
            return g.g_variant_ref_sink(g.g_variant_builder_end(out));
        }
        var err: [*c]c.GError = null;
        defer c.g_clear_error(&err);
        return c.g_variant_parse(@ptrCast(self.kind.ptr), entered.ptr, null, null, &err) orelse error.InvalidPropertyValue;
    }
};
pub fn parseAddresses(input: []const u8, ipv6: bool) !*c.GVariant {
    const out = builder("aa{sv}");
    defer g.g_variant_builder_unref(out);
    var addresses = std.mem.tokenizeAny(u8, input, ", \t\n");
    while (addresses.next()) |cidr| {
        const slash = std.mem.lastIndexOfScalar(u8, cidr, '/') orelse return error.AddressNeedsPrefix;
        const address = cidr[0..slash];
        const parsed = std.Io.net.IpAddress.parse(address, 0) catch return error.InvalidIPAddress;
        if ((parsed == .ip6) != ipv6) return error.WrongAddressFamily;
        const prefix = std.fmt.parseInt(u32, cidr[slash + 1 ..], 10) catch return error.InvalidPrefix;
        if (prefix > @as(u32, if (ipv6) 128 else 32)) return error.InvalidPrefix;
        const inner = builder("a{sv}");
        defer g.g_variant_builder_unref(inner);
        const address_z = z(address);
        defer a.free(address_z);
        add(inner, "address", c.g_variant_new("s", address_z.ptr).?);
        add(inner, "prefix", c.g_variant_new("u", prefix).?);
        g.g_variant_builder_add(out, "@a{sv}", g.g_variant_builder_end(inner));
    }
    return g.g_variant_ref_sink(g.g_variant_builder_end(out)).?;
}
pub const Editor = struct {
    window: *c.GtkWidget,
    body: *c.GtkWidget,
    message: *c.GtkWidget,
    save_button: *c.GtkWidget,
    client: *network.Client,
    cancel: *c.GCancellable,
    path: ?[:0]u8,
    version: u64,
    rows: std.ArrayList(Row) = .empty,
    refs: usize = 1,
    closed: bool = false,
    saving: bool = false,
    property_group: *c.GtkWidget,
    property_key: *c.GtkWidget,
    property_type: *c.GtkWidget,
    pub fn create(parent: *c.GtkWidget, profile: ?network.Profile) *Editor {
        const self = a.create(Editor) catch @panic("out of memory");
        const window = c.gtk_dialog_new_with_buttons(if (profile != null) "Edit Connection" else "New Connection", cast(c.GtkWindow, parent), c.GTK_DIALOG_DESTROY_WITH_PARENT, @as([*:0]const u8, "Cancel"), c.GTK_RESPONSE_CANCEL, @as([*:0]const u8, "Save"), c.GTK_RESPONSE_OK, @as(?*anyopaque, null)).?;
        c.gtk_window_set_default_size(cast(c.GtkWindow, window), 640, 700);
        const content = c.gtk_dialog_get_content_area(cast(c.GtkDialog, window));
        const scroll = c.gtk_scrolled_window_new(null, null).?;
        c.gtk_scrolled_window_set_policy(cast(c.GtkScrolledWindow, scroll), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
        c.gtk_box_pack_start(cast(c.GtkBox, content), scroll, 1, 1, 0);
        const body = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 8).?;
        c.gtk_container_set_border_width(cast(c.GtkContainer, body), 16);
        c.gtk_container_add(cast(c.GtkContainer, scroll), body);
        const message = label("");
        c.gtk_label_set_line_wrap(cast(c.GtkLabel, message), 1);
        pack(cast(c.GtkWidget, content), message);
        const extra = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4).?;
        self.* = .{ .window = window, .body = body, .message = message, .save_button = c.gtk_dialog_get_widget_for_response(cast(c.GtkDialog, window), c.GTK_RESPONSE_OK).?, .cancel = c.g_cancellable_new().?, .path = if (profile) |p| z(p.path) else null, .version = if (profile) |p| p.version else 0, .client = network.Client.create(&changed, self) catch @panic("out of memory"), .property_group = entry(extra, "Section", "e.g. ipv4, vlan, 802-1x"), .property_key = entry(extra, "Property", "e.g. mtu, parent, identity"), .property_type = entry(extra, "Value type", "s: text, b: boolean, u: unsigned integer, as: text list") };
        _ = c.g_signal_connect_data(window, "response", @ptrCast(&response), self, null, 0);
        _ = c.g_signal_connect_data(window, "destroy", @ptrCast(&destroyed), self, null, 0);
        const base = if (profile) |p| g.g_variant_ref(p.base).? else template();
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
        pack(body, label("Additional connection properties"));
        pack(body, extra);
        const add_button = c.gtk_button_new_with_label("Add property").?;
        pack(extra, add_button);
        _ = c.g_signal_connect_data(add_button, "clicked", @ptrCast(&addProperty), self, null, 0);
        if (self.row("connection", "type")) |kind_row| _ = c.g_signal_connect_data(kind_row.widget, "changed", @ptrCast(&kindChanged), self, null, 0);
        c.gtk_widget_show_all(window);
        return self;
    }
    pub fn row(self: *Editor, group: []const u8, key: []const u8) ?*Row {
        for (self.rows.items) |*r| if (eq(r.group, group) and eq(r.key, key)) return r;
        return null;
    }
    fn addRow(self: *Editor, field: Field, original: ?*c.GVariant) void {
        const kind = if (original) |v| std.mem.span(c.g_variant_get_type_string(v)) else field.kind;
        const caption = std.fmt.allocPrintSentinel(a, "{s} · {s}", .{ field.group, field.title }, 0) catch @panic("out of memory");
        defer a.free(caption);
        const line = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6).?;
        pack(self.body, label(caption));
        pack(self.body, line);
        const widget = if (eq(kind, "b")) c.gtk_check_button_new_with_label(field.title).? else c.gtk_entry_new().?;
        c.gtk_box_pack_start(cast(c.GtkBox, line), widget, 1, 1, 0);
        const remove = c.gtk_check_button_new_with_label("Use default").?;
        pack(line, remove);
        if (original == null and eq(kind, "b")) c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, remove), 1);
        if (eq(kind, "b")) _ = c.g_signal_connect_data(widget, "toggled", @ptrCast(&booleanChanged), remove, null, 0);
        var initial: [:0]u8 = z("");
        var byte_text = eq(field.key, "ssid");
        var address_text = eq(field.key, "address-data");
        if (original) |v| {
            if (eq(kind, "b")) c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, widget), c.g_variant_get_boolean(v)) else {
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
                c.gtk_entry_set_text(cast(c.GtkEntry, widget), initial);
            }
        }
        if (!eq(kind, "b")) {
            c.gtk_entry_set_placeholder_text(cast(c.GtkEntry, widget), field.hint);
            if (network.secretProperty(field.key) and !std.mem.endsWith(u8, field.key, "-flags")) c.gtk_entry_set_visibility(cast(c.GtkEntry, widget), 0);
        }
        self.rows.append(a, .{ .group = z(field.group), .key = z(field.key), .kind = z(kind), .widget = widget, .remove = remove, .original = original, .initial = initial, .bytes_as_text = byte_text, .addresses_as_text = address_text }) catch @panic("out of memory");
    }
    fn booleanChanged(_: *c.GtkToggleButton, ptr: c.gpointer) callconv(.c) void {
        c.gtk_toggle_button_set_active(cast(c.GtkToggleButton, ptr), 0);
    }
    fn kindChanged(_: *c.GtkEntry, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Editor, ptr);
        const kind_row = self.row("connection", "type") orelse return;
        const kind = text(kind_row.widget);
        for (fields) |field| {
            const wifi = eq(kind, "802-11-wireless") and (eq(field.group, "802-11-wireless-security") or eq(field.group, "802-1x"));
            if ((eq(field.group, kind) or wifi) and self.row(field.group, field.key) == null) self.addRow(field, null);
        }
        c.gtk_widget_show_all(self.body);
    }
    fn addProperty(_: *c.GtkButton, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Editor, ptr);
        const group = text(self.property_group);
        const key = text(self.property_key);
        const kind = text(self.property_type);
        if (group.len == 0 or key.len == 0 or c.g_variant_type_string_is_valid(kind) == 0 or c.g_variant_type_is_definite(@ptrCast(kind.ptr)) == 0 or self.row(group, key) != null) {
            self.setMessage("Enter a new section, property and valid value type.");
            return;
        }
        self.addRow(.{ .group = group, .key = key, .title = key, .kind = kind }, null);
        c.gtk_widget_show_all(self.body);
    }
    pub fn values(self: *Editor) !*c.GVariant {
        const Group = struct { name: [:0]const u8, value: *g.GVariantBuilder };
        var groups: std.ArrayList(Group) = .empty;
        defer {
            for (groups.items) |group| g.g_variant_builder_unref(group.value);
            groups.deinit(a);
        }
        for (self.rows.items) |*r| {
            const modern: ?[]const u8 = if (eq(r.key, "dns")) "dns-data" else if (eq(r.key, "addresses")) "address-data" else if (eq(r.key, "routes")) "route-data" else null;
            if (modern) |key| if (self.row(r.group, key)) |replacement| {
                if (text(replacement.widget).len != 0 and c.gtk_toggle_button_get_active(cast(c.GtkToggleButton, replacement.remove)) == 0) continue;
            };
            const value = r.value() catch |err| {
                const message = std.fmt.allocPrintSentinel(a, "{s} · {s}: {s}", .{ r.group, r.key, @errorName(err) }, 0) catch @panic("out of memory");
                defer a.free(message);
                self.setMessage(message);
                return err;
            } orelse continue;
            defer c.g_variant_unref(value);
            var group_builder: ?*g.GVariantBuilder = null;
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
        defer g.g_variant_builder_unref(out);
        for (groups.items) |group| g.g_variant_builder_add(out, "{s@a{sv}}", group.name.ptr, g.g_variant_builder_end(group.value));
        return g.g_variant_ref_sink(g.g_variant_builder_end(out)).?;
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
        c.gtk_widget_set_sensitive(self.body, 0);
        c.gtk_widget_set_sensitive(self.save_button, 0);
        self.setMessage("Saving connection…");
        self.client.perform(.{ .save = .{ .path = self.path, .settings = settings, .version = self.version } }, self.cancel, &saved, self);
    }
    fn saved(ptr: ?*anyopaque, result: network.Result) void {
        const self = cast(Editor, ptr);
        defer self.unref();
        self.saving = false;
        if (self.closed) return;
        if (result == .success) {
            c.gtk_widget_destroy(self.window);
            return;
        }
        self.setMessage(result.failure);
        c.gtk_widget_set_sensitive(self.body, 1);
        c.gtk_widget_set_sensitive(self.save_button, 1);
    }
    fn response(_: *c.GtkDialog, answer: c_int, ptr: c.gpointer) callconv(.c) void {
        const self = cast(Editor, ptr);
        if (answer == c.GTK_RESPONSE_OK) self.save() else c.gtk_widget_destroy(self.window);
    }
    fn changed(_: ?*anyopaque, _: *network.Client) void {}
    fn destroyed(_: *c.GtkWidget, ptr: c.gpointer) callconv(.c) void {
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
        a.destroy(self);
    }
    fn setMessage(self: *Editor, message: [:0]const u8) void {
        c.gtk_label_set_text(cast(c.GtkLabel, self.message), message);
    }
};
fn template() *c.GVariant {
    const uuid = c.g_uuid_string_random();
    defer c.g_free(uuid);
    const out = builder("a{sa{sv}}");
    defer g.g_variant_builder_unref(out);
    const connection = builder("a{sv}");
    defer g.g_variant_builder_unref(connection);
    add(connection, "id", c.g_variant_new("s", @as([*:0]const u8, "New connection")).?);
    add(connection, "uuid", c.g_variant_new("s", uuid).?);
    add(connection, "type", c.g_variant_new("s", @as([*:0]const u8, "802-3-ethernet")).?);
    add(connection, "autoconnect", c.g_variant_new("b", @as(c_int, 1)).?);
    g.g_variant_builder_add(out, "{s@a{sv}}", @as([*:0]const u8, "connection"), g.g_variant_builder_end(connection));
    for ([_][:0]const u8{ "ipv4", "ipv6" }) |group| {
        const inner = builder("a{sv}");
        defer g.g_variant_builder_unref(inner);
        add(inner, "method", c.g_variant_new("s", @as([*:0]const u8, "auto")).?);
        g.g_variant_builder_add(out, "{s@a{sv}}", group.ptr, g.g_variant_builder_end(inner));
    }
    const ethernet = builder("a{sv}");
    defer g.g_variant_builder_unref(ethernet);
    g.g_variant_builder_add(out, "{s@a{sv}}", @as([*:0]const u8, "802-3-ethernet"), g.g_variant_builder_end(ethernet));
    return g.g_variant_ref_sink(g.g_variant_builder_end(out)).?;
}

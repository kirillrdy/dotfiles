//! Connection-editor presentation; typed NetworkManager values stay in the controller.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const form = @import("desktop-form.zig");
const raster = @import("desktop-raster.zig");
const p = @import("desktop-preferences-view.zig");
pub const Page = enum { details, identity, ipv4, ipv6, security, advanced };
pub const pages = [_]Page{ .details, .identity, .ipv4, .ipv6, .security, .advanced };
pub const titles = [_][:0]const u8{ "Details", "Identity", "IPv4", "IPv6", "Security", "Advanced" };
pub const Field = struct { id: usize, remove: usize, group: [:0]const u8, key: [:0]const u8, page: Page };
pub fn section(group: []const u8, key: []const u8) Page {
    if (std.mem.eql(u8, group, "ipv4") or std.mem.eql(u8, group, "ipv6")) {
        for ([_][]const u8{ "method", "address-data", "gateway", "dns-data", "dns-search", "ignore-auto-dns", "never-default", "ignore-auto-routes" }) |known| if (std.mem.eql(u8, key, known)) return if (std.mem.eql(u8, group, "ipv4")) .ipv4 else .ipv6;
        return .advanced;
    }
    if (std.mem.eql(u8, group, "802-11-wireless-security")) {
        for ([_][]const u8{ "key-mgmt", "psk", "wep-key0" }) |known| if (std.mem.eql(u8, key, known)) return .security;
        return .advanced;
    }
    if (std.mem.eql(u8, group, "802-1x")) {
        for ([_][]const u8{ "eap", "identity", "anonymous-identity", "password", "phase2-auth" }) |known| if (std.mem.eql(u8, key, known)) return .security;
        return .advanced;
    }
    if (std.mem.eql(u8, group, "connection")) {
        for ([_][]const u8{ "id", "type", "interface-name", "autoconnect" }) |known| if (std.mem.eql(u8, key, known)) return .identity;
        return .advanced;
    }
    for ([_][]const u8{ "802-3-ethernet", "802-11-wireless", "bridge", "bond", "vlan", "vpn", "wireguard" }) |known| if (std.mem.eql(u8, group, known)) return .identity;
    return .advanced;
}
pub const View = struct {
    page: Page = .details,
    tabs: [6]usize = @splat(0),
    cancel: usize = 0,
    apply: usize = 0,
    message: usize = 0,
    kind: usize = 0,
    ipv4: usize = 0,
    ipv6: usize = 0,
    security: usize = 0,
    dot1x: usize = 0,
    property_group: usize = 0,
    property_key: usize = 0,
    property_type: usize = 0,
    add_property: usize = 0,
    fields: []const Field = &.{},
    offset: f64 = 0,
    extent: f64 = 0,
    connected: bool = false,
    strength: ?u8 = null,
    frame: p.Frame = .{ .width = 720, .height = 640, .sidebar = 0, .x = 72, .content_width = 576 },
    fn findField(self: *const View, group: []const u8, key: []const u8) ?usize {
        for (self.fields) |value| if (std.mem.eql(u8, group, value.group) and std.mem.eql(u8, key, value.key)) return value.id;
        return null;
    }
    fn fieldValue(self: *const View, ui: *form.Form, group: []const u8, key: []const u8) [:0]const u8 {
        return if (self.findField(group, key)) |id| ui.get(id).value() else "";
    }
    fn shown(self: *const View, ui: *form.Form, item: Field) bool {
        if (self.page == .advanced) return true;
        if (item.page != self.page) return false;
        if (std.mem.eql(u8, item.key, "type") and std.mem.eql(u8, item.group, "connection")) return false;
        if (std.mem.eql(u8, item.key, "method") and (item.page == .ipv4 or item.page == .ipv6)) return false;
        if (self.page == .security) {
            if (std.mem.eql(u8, item.key, "key-mgmt")) return false;
            const mode = self.fieldValue(ui, "802-11-wireless-security", "key-mgmt");
            const enterprise = std.mem.eql(u8, mode, "wpa-eap") or std.mem.eql(u8, mode, "wpa-eap-suite-b-192") or std.mem.eql(u8, mode, "ieee8021x");
            if (std.mem.eql(u8, item.group, "802-1x")) return if (std.mem.eql(u8, self.fieldValue(ui, "connection", "type"), "802-3-ethernet")) ui.get(self.dot1x).checked else enterprise;
            if (std.mem.eql(u8, item.key, "psk")) return std.mem.eql(u8, mode, "wpa-psk") or std.mem.eql(u8, mode, "sae");
            if (std.mem.eql(u8, item.key, "wep-key0")) return std.mem.eql(u8, mode, "none");
        }
        if (self.page == .ipv4 or self.page == .ipv6) {
            const method = self.fieldValue(ui, item.group, "method");
            if (std.mem.eql(u8, method, "disabled") or std.mem.eql(u8, method, "ignore")) return false;
            if (std.mem.eql(u8, item.key, "address-data") or std.mem.eql(u8, item.key, "gateway")) return std.mem.eql(u8, method, "manual");
        }
        return true;
    }
    fn currentControl(self: *const View, ui: *form.Form) ?usize {
        return switch (self.page) {
            .identity => self.kind,
            .ipv4 => self.ipv4,
            .ipv6 => self.ipv6,
            .security => if (std.mem.eql(u8, self.fieldValue(ui, "connection", "type"), "802-11-wireless")) self.security else self.dot1x,
            else => null,
        };
    }
    pub fn maxOffset(self: *const View) f64 {
        return @max(0, self.extent - self.frame.height + 24);
    }
    pub fn layout(self: *View, ui: *form.Form) void {
        self.frame = p.Frame.init(ui, 0);
        const f = self.frame;
        self.offset = std.math.clamp(self.offset, 0, self.maxOffset());
        p.reset(ui);
        p.place(ui, self.cancel, .{ .x = 6, .y = 6, .width = 80, .height = 34 });
        p.place(ui, self.apply, .{ .x = f.width - 86, .y = 6, .width = 80, .height = 34 });
        for (self.tabs, 0..) |id, i| p.place(ui, id, .{ .x = @as(f64, @floatFromInt(i)) * f.width / 6, .y = 46, .width = f.width / 6, .height = 42 });
        var y: f64 = 112 - self.offset;
        if (self.page == .details) {
            y += 4 * 55 + 24;
            if (self.findField("connection", "autoconnect")) |id| {
                p.place(ui, id, .{ .x = f.x, .y = y, .width = f.content_width, .height = 55 });
                y += 55;
            }
        } else {
            const control = self.currentControl(ui);
            if (control) |id| {
                p.place(ui, id, .{ .x = f.x, .y = y, .width = f.content_width, .height = 55 });
                y += 80;
            }
            for (self.fields) |item| {
                if (!self.shown(ui, item)) continue;
                const height: f64 = if (ui.get(item.id).kind == .toggle) 55 else 68;
                p.place(ui, item.id, .{ .x = f.x, .y = y, .width = f.content_width, .height = height });
                y += height + 1;
                if (self.page == .advanced) {
                    p.place(ui, item.remove, .{ .x = f.x, .y = y, .width = f.content_width, .height = 44 });
                    y += 60;
                }
            }
            if (self.page == .advanced) {
                y += 48;
                for ([_]usize{ self.property_group, self.property_key, self.property_type }) |id| {
                    p.place(ui, id, .{ .x = f.x, .y = y, .width = f.content_width, .height = 68 });
                    y += 69;
                }
                p.place(ui, self.add_property, .{ .x = f.x + f.content_width - 140, .y = y + 16, .width = 140, .height = 36 });
                y += 70;
            }
        }
        self.extent = y + self.offset;
        const clip: p.Rect = .{ .x = 0, .y = 88, .width = f.width, .height = f.height - 88 };
        for (ui.items.items) |item| if (item.visible and item.bounds.y != 6 and item.bounds.y != 46) {
            item.clip = clip;
        };
    }
    pub fn paint(self: *View, ui: *form.Form, target: raster.Buffer, scale: u32) !void {
        self.layout(ui);
        const f = self.frame;
        const canvas: p.Canvas = .{ .target = target, .scale = @floatFromInt(scale) };
        @memset(target.pixels, 0xff222226);
        if (self.page == .details) {
            const y = 112 - self.offset;
            p.fill(canvas, .{ .x = f.x, .y = y, .width = f.content_width, .height = 220 }, p.card, 12);
            var strength_buffer: [24]u8 = undefined;
            const strength: [:0]const u8 = if (self.strength) |s| try std.fmt.bufPrintSentinel(&strength_buffer, "{d}%", .{s}, 0) else "—";
            const kind = self.fieldValue(ui, "connection", "type");
            const wireless = std.mem.eql(u8, kind, "802-11-wireless");
            const type_label: [:0]const u8 = if (wireless) "Wi-Fi" else if (std.mem.eql(u8, kind, "802-3-ethernet")) "Wired" else kind;
            const labels = [_][:0]const u8{ "Status", "Connection Type", if (wireless) "Signal Strength" else "Interface", "Connection Name" };
            const values = [_][:0]const u8{ if (self.connected) "Connected" else "Not connected", type_label, if (wireless) strength else self.fieldValue(ui, "connection", "interface-name"), self.fieldValue(ui, "connection", "id") };
            for (labels, values, 0..) |label, value, i| {
                const top = y + @as(f64, @floatFromInt(i * 55));
                try p.text(ui, canvas, label, .{ .x = f.x + 14, .y = top, .width = f.content_width * 0.48, .height = 55 }, 14.666, false, false, p.secondary);
                try p.text(ui, canvas, value, .{ .x = f.x + f.content_width * 0.5, .y = top, .width = f.content_width * 0.5 - 14, .height = 55 }, 14.666, false, false, 0xffffff);
                if (i > 0) p.line(canvas, f.x, top, f.content_width);
            }
            if (self.findField("connection", "autoconnect")) |id| {
                p.fill(canvas, ui.get(id).bounds, p.card, 12);
                try p.toggle(ui, canvas, id);
            }
        } else {
            const control = self.currentControl(ui);
            if (control) |id| {
                p.fill(canvas, ui.get(id).bounds, p.card, 12);
                try p.field(ui, canvas, id);
            }
            var first: ?p.Rect = null;
            var last: p.Rect = undefined;
            for (self.fields) |item| if (ui.get(item.id).visible) {
                if (first == null) first = ui.get(item.id).bounds;
                last = ui.get(item.id).bounds;
            };
            if (first) |r| p.fill(canvas, .{ .x = r.x, .y = r.y, .width = r.width, .height = last.y + last.height - r.y }, p.card, 12);
            for (self.fields) |item| {
                const field = ui.get(item.id);
                if (!field.visible) continue;
                if (field.bounds.y + field.bounds.height < 88 or field.bounds.y > f.height) continue;
                try p.field(ui, canvas, item.id);
                if (first != null and field.bounds.y > first.?.y) p.line(canvas, field.bounds.x, field.bounds.y, field.bounds.width);
                if (self.page == .advanced) {
                    p.fill(canvas, ui.get(item.remove).bounds, p.card, 0);
                    try p.toggle(ui, canvas, item.remove);
                }
            }
            if (self.page == .advanced) {
                for ([_]usize{ self.property_group, self.property_key, self.property_type }) |id| {
                    p.fill(canvas, ui.get(id).bounds, p.card, 0);
                    try p.field(ui, canvas, id);
                }
                try p.button(ui, canvas, self.add_property, false, false);
            }
        }
        p.fill(canvas, .{ .x = 0, .y = 0, .width = f.width, .height = 88 }, p.background, 0);
        try p.text(ui, canvas, ui.title, .{ .x = 100, .y = 6, .width = f.width - 200, .height = 34 }, 14.666, true, true, 0xffffff);
        try p.button(ui, canvas, self.cancel, false, false);
        try p.button(ui, canvas, self.apply, true, false);
        for (self.tabs, pages) |id, page| {
            const item = ui.get(id);
            const r = item.bounds;
            if (ui.hover == id) p.fill(canvas, r, 0x303034, 0);
            try p.text(ui, canvas, item.title, r, 14.666, self.page == page, true, if (self.page == page) @as(u32, 0xffffff) else p.secondary);
            if (self.page == page) p.fill(canvas, .{ .x = r.x + 12, .y = r.y + r.height - 3, .width = r.width - 24, .height = 3 }, 0x3584e4, 1.5);
        }
        if (self.maxOffset() > 0) p.fill(canvas, .{ .x = f.width - 7, .y = 94 + (f.height - 144) * self.offset / self.maxOffset(), .width = 4, .height = 40 }, 0x68686c, 2);
        try p.toast(ui, canvas, self.message, f);
        try p.expanded(ui, canvas);
    }
};

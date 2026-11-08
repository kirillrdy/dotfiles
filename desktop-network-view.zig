//! GNOME-style network pages. The controller owns NetworkManager operations.
const std = @import("std");
const c = @import("desktop-gtk.zig");
const form = @import("desktop-form.zig");
const raster = @import("desktop-raster.zig");
const p = @import("desktop-preferences-view.zig");
pub const Page = enum { wifi, network, saved, hidden };
pub const Row = struct {
    item: usize,
    details: usize,
    remove: ?usize = null,
    key: [:0]const u8,
    profile: ?[:0]const u8 = null,
    kind: enum { access_point, device, profile },
    icon: [:0]const u8,
    subtitle: [:0]const u8 = "",
    connected: bool = false,
    secure: bool = false,
    strength: u8 = 0,
};
pub const View = struct {
    page: Page = .wifi,
    wifi_nav: usize = 0,
    network_nav: usize = 0,
    wifi: usize = 0,
    saved: usize = 0,
    hidden: usize = 0,
    hotspot: usize = 0,
    back: usize = 0,
    close: usize = 0,
    refresh: usize = 0,
    search: usize = 0,
    query: usize = 0,
    new_connection: usize = 0,
    manual: usize = 0,
    password: usize = 0,
    connect: usize = 0,
    message: usize = 0,
    available: bool = false,
    has_wifi: bool = false,
    radio: bool = false,
    hardware: bool = true,
    busy: bool = false,
    searching: bool = false,
    rows: []const Row = &.{},
    offset: f64 = 0,
    extent: f64 = 0,
    frame: p.Frame = .{ .width = 900, .height = 700, .sidebar = 280, .x = 320, .content_width = 540 },
    icons: p.Icons = .{},
    pub fn deinit(self: *View) void {
        self.icons.deinit();
    }
    pub fn maxOffset(self: *const View) f64 {
        return @max(0, self.extent - self.frame.height + 24);
    }
    pub fn layout(self: *View, ui: *form.Form) void {
        self.frame = p.Frame.init(ui, @min(280, @as(f64, @floatFromInt(ui.width)) * 0.3));
        const f = self.frame;
        self.offset = std.math.clamp(self.offset, 0, self.maxOffset());
        p.reset(ui);
        p.place(ui, self.wifi_nav, .{ .x = 6, .y = 52, .width = f.sidebar - 12, .height = 43 });
        p.place(ui, self.network_nav, .{ .x = 6, .y = 97, .width = f.sidebar - 12, .height = 43 });
        p.place(ui, self.search, .{ .x = 6, .y = 6, .width = 34, .height = 34 });
        p.place(ui, self.refresh, .{ .x = f.sidebar - 40, .y = 6, .width = 34, .height = 34 });
        p.place(ui, self.close, .{ .x = f.width - 35, .y = 11, .width = 24, .height = 24 });
        if (self.page == .saved or self.page == .hidden) p.place(ui, self.back, .{ .x = f.sidebar + 6, .y = 6, .width = 34, .height = 34 });
        if (self.searching) {
            p.place(ui, self.query, .{ .x = f.sidebar + 52, .y = 6, .width = f.width - f.sidebar - 110, .height = 34 });
            ui.get(self.query).entry.?.rect = .{ .x = f.sidebar + 52, .y = 6, .width = f.width - f.sidebar - 110, .height = 34 };
        }
        var y: f64 = 70 - self.offset;
        if (self.page == .wifi) {
            p.place(ui, self.wifi, .{ .x = f.x, .y = y, .width = f.content_width, .height = 55 });
            p.place(ui, self.saved, .{ .x = f.x, .y = y + 55, .width = f.content_width, .height = 55 });
            p.place(ui, self.hidden, .{ .x = f.x, .y = y + 110, .width = f.content_width, .height = 55 });
            p.place(ui, self.hotspot, .{ .x = f.x, .y = y + 165, .width = f.content_width, .height = 55 });
            y += 273;
        } else if (self.page == .network) {
            y += 32;
            p.place(ui, self.new_connection, .{ .x = f.x + f.content_width - 34, .y = y - 8, .width = 34, .height = 34 });
            y += 32;
        } else if (self.page == .hidden) {
            p.place(ui, self.manual, .{ .x = f.x, .y = y, .width = f.content_width, .height = 68 });
            p.place(ui, self.password, .{ .x = f.x, .y = y + 69, .width = f.content_width, .height = 68 });
            p.place(ui, self.connect, .{ .x = f.x + f.content_width - 120, .y = y + 155, .width = 120, .height = 36 });
            y += 200;
        }
        if (self.page != .hidden) for (self.rows) |row| {
            p.place(ui, row.item, .{ .x = f.x, .y = y, .width = f.content_width - (if (self.page == .saved) @as(f64, 98) else if (row.profile != null or row.kind != .access_point) @as(f64, 54) else 0), .height = 55 });
            if (row.profile != null or row.kind != .access_point) p.place(ui, row.details, .{ .x = f.x + f.content_width - 48, .y = y + 10, .width = 36, .height = 36 });
            if (self.page == .saved) if (row.remove) |id| p.place(ui, id, .{ .x = f.x + f.content_width - 92, .y = y + 10, .width = 36, .height = 36 });
            y += 55;
        };
        self.extent = y + self.offset;
        const clip: p.Rect = .{ .x = f.sidebar, .y = 46, .width = f.width - f.sidebar, .height = f.height - 46 };
        for (ui.items.items) |item| if (item.visible and item.bounds.y != 6 and item.id != self.close and item.id != self.wifi_nav and item.id != self.network_nav) {
            item.clip = clip;
        };
    }
    fn iconButton(self: *View, ui: *form.Form, canvas: p.Canvas, id: usize, icon: [:0]const u8) !void {
        const field = ui.get(id);
        if (!field.visible) return;
        if (ui.hover == id) p.fill(canvas, field.bounds, 0x414145, 6);
        try self.icons.paint(canvas, icon, field.bounds.x + (field.bounds.width - 16) / 2, field.bounds.y + (field.bounds.height - 16) / 2, 16);
        if (ui.focus == id) p.focus(canvas, field.bounds);
    }
    pub fn paint(self: *View, ui: *form.Form, target: raster.Buffer, scale: u32) !void {
        self.layout(ui);
        const f = self.frame;
        const canvas: p.Canvas = .{ .target = target, .scale = @floatFromInt(scale) };
        @memset(target.pixels, 0xff222226);
        const y = 70 - self.offset;
        if (self.page == .wifi) {
            p.fill(canvas, .{ .x = f.x, .y = y, .width = f.content_width, .height = 220 }, p.card, 12);
            try p.toggle(ui, canvas, self.wifi);
            for ([_]usize{ self.saved, self.hidden, self.hotspot }) |id| {
                const field = ui.get(id);
                if (ui.hover == id and ui.active(id)) p.fill(canvas, field.bounds, 0x3b3b3f, 0);
                try p.title(ui, canvas, id, .{ .x = field.bounds.x + 14, .y = field.bounds.y, .width = field.bounds.width - 60, .height = 55 }, false, if (ui.active(id)) @as(u32, 0xffffff) else p.secondary);
                try self.icons.paint(canvas, "go-next-symbolic", field.bounds.x + field.bounds.width - 30, field.bounds.y + 20, 16);
                p.line(canvas, f.x, field.bounds.y, f.content_width);
            }
            if (self.available and self.has_wifi and self.radio and self.hardware) try p.text(ui, canvas, "Visible Networks", .{ .x = f.x, .y = y + 242, .width = f.content_width, .height = 24 }, 14.666, true, false, 0xffffff);
        } else if (self.page == .network) {
            try p.text(ui, canvas, "Connections", .{ .x = f.x, .y = y + 32, .width = f.content_width, .height = 24 }, 14.666, true, false, 0xffffff);
            try self.iconButton(ui, canvas, self.new_connection, "list-add-symbolic");
        } else if (self.page == .hidden) {
            p.fill(canvas, .{ .x = f.x, .y = y, .width = f.content_width, .height = 137 }, p.card, 12);
            try p.field(ui, canvas, self.manual);
            p.line(canvas, f.x, y + 68, f.content_width);
            try p.field(ui, canvas, self.password);
            try p.button(ui, canvas, self.connect, true, false);
        }
        if (self.page != .hidden and self.rows.len > 0) {
            const first = ui.get(self.rows[0].item).bounds;
            p.fill(canvas, .{ .x = f.x, .y = first.y, .width = f.content_width, .height = @as(f64, @floatFromInt(self.rows.len * 55)) }, p.card, 12);
            for (self.rows, 0..) |row, i| {
                const field = ui.get(row.item);
                const r = field.bounds;
                if (r.y + r.height < 46 or r.y > f.height) continue;
                if (ui.hover == row.item and ui.active(row.item)) p.fill(canvas, r, 0x3b3b3f, 6);
                if (ui.focus == row.item) p.focus(canvas, r);
                try self.icons.paint(canvas, row.icon, r.x + 14, r.y + 20, 16);
                if (row.secure) try self.icons.paint(canvas, "network-wireless-encrypted-symbolic", r.x + 28, r.y + 28, 8);
                try p.title(ui, canvas, row.item, .{ .x = r.x + 50, .y = r.y + (if (row.subtitle.len > 0) @as(f64, 5) else 0), .width = f.content_width - 150, .height = if (row.subtitle.len > 0) 26 else 55 }, false, 0xffffff);
                if (row.subtitle.len > 0) try p.text(ui, canvas, row.subtitle, .{ .x = r.x + 50, .y = r.y + 28, .width = f.content_width - 150, .height = 20 }, 12.666, false, false, p.secondary);
                try self.iconButton(ui, canvas, row.details, "emblem-system-symbolic");
                if (self.page == .saved) if (row.remove) |id| try self.iconButton(ui, canvas, id, "user-trash-symbolic");
                if (i > 0) p.line(canvas, f.x, r.y, f.content_width);
            }
        } else if (self.page != .hidden) {
            const unavailable = !self.available;
            const disabled = self.page == .wifi and (!self.radio or !self.hardware);
            const missing = self.page == .wifi and !self.has_wifi;
            const status: [:0]const u8 = if (unavailable) "Network Unavailable" else if (missing) "No Wi-Fi Adapter Found" else if (disabled) (if (!self.hardware) "Wi-Fi Unavailable" else "Wi-Fi Off") else if (self.page == .saved) "No Saved Networks" else if (self.page == .network) "No Network Connections" else "No Networks Found";
            const top: f64 = if (self.page == .wifi) @max(y + 340, f.height / 2) else f.height / 2 - 80;
            try self.icons.paint(canvas, if (disabled) "network-wireless-disabled-symbolic" else "network-wireless-no-route-symbolic", f.sidebar + (f.width - f.sidebar) / 2 - 32, top, 64);
            try p.text(ui, canvas, status, .{ .x = f.x, .y = top + 80, .width = f.content_width, .height = 36 }, 22, true, true, 0xffffff);
            try p.text(ui, canvas, if (unavailable) "NetworkManager is not running" else if (disabled) "Turn on to use Wi-Fi" else if (missing) "Make sure you have a Wi-Fi adapter connected" else if (self.page == .network) "Add a connection to get started" else "", .{ .x = f.x, .y = top + 120, .width = f.content_width, .height = 28 }, 14.666, false, true, p.secondary);
        }
        p.fill(canvas, .{ .x = 0, .y = 0, .width = f.sidebar - 1, .height = f.height }, 0x2e2e32, 0);
        p.fill(canvas, .{ .x = f.sidebar, .y = 0, .width = f.width - f.sidebar, .height = 46 }, p.background, 0);
        try p.text(ui, canvas, "Settings", .{ .x = 40, .y = 6, .width = f.sidebar - 80, .height = 34 }, 14.666, true, true, 0xffffff);
        try self.iconButton(ui, canvas, self.search, "edit-find-symbolic");
        try self.iconButton(ui, canvas, self.refresh, "view-refresh-symbolic");
        for ([_]usize{ self.wifi_nav, self.network_nav }, [_][:0]const u8{ "network-wireless-symbolic", "network-workgroup-symbolic" }, 0..) |id, icon, i| {
            const r = ui.get(id).bounds;
            const selected = (i == 0) == (self.page != .network);
            if (selected or ui.hover == id) p.fill(canvas, r, if (selected) 0x414145 else 0x38383c, 9);
            try self.icons.paint(canvas, icon, r.x + 14, r.y + 14, 16);
            try p.title(ui, canvas, id, .{ .x = r.x + 42, .y = r.y, .width = r.width - 56, .height = r.height }, false, 0xffffff);
        }
        if (self.searching) try ui.get(self.query).entry.?.paint(target, scale) else {
            const heading: [:0]const u8 = switch (self.page) {
                .wifi => "Wi-Fi",
                .network => "Network",
                .saved => "Saved Wi-Fi Networks",
                .hidden => "Connect to Hidden Network",
            };
            try p.text(ui, canvas, heading, .{ .x = f.sidebar + 50, .y = 6, .width = f.width - f.sidebar - 100, .height = 34 }, 14.666, true, true, 0xffffff);
        }
        try self.iconButton(ui, canvas, self.back, "go-previous-symbolic");
        p.fill(canvas, ui.get(self.close).bounds, 0x38383c, 12);
        try self.iconButton(ui, canvas, self.close, "window-close-symbolic");
        if (self.maxOffset() > 0) p.fill(canvas, .{ .x = f.width - 7, .y = 50 + (f.height - 100) * self.offset / self.maxOffset(), .width = 4, .height = 40 }, 0x68686c, 2);
        try p.toast(ui, canvas, self.message, f);
    }
};

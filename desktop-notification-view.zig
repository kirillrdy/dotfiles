//! Shared notification data for native banners and history.
pub const c = @import("desktop-gtk.zig");
pub const Action = struct { key: [:0]const u8, label: [:0]const u8 };
pub const Data = struct {
    id: u32,
    app: [:0]const u8,
    title: [:0]const u8,
    body: [:0]const u8,
    icon: [:0]const u8 = "application-x-executable-symbolic",
    image: ?*c.GdkPixbuf = null,
    actions: []const Action = &.{},
    created: i64,
};

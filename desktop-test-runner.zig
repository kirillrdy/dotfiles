//! One unit-test binary, including tests from the actual production sources.
test {
    _ = @import("desktop-zig.zig");
    _ = @import("tests/desktop-gtk-abi.zig");
    _ = @import("tests/desktop-libc-abi.zig");
    _ = @import("tests/desktop-protocols.zig");
    _ = @import("desktop-switcher.zig");
    _ = @import("desktop-layer-shell.zig");
    _ = @import("desktop-wallpaper.zig");
    _ = @import("desktop-surface.zig");
    _ = @import("desktop-osd-view.zig");
    _ = @import("desktop-screenshot.zig");
    _ = @import("desktop-png.zig");
    _ = @import("desktop-raster.zig");
    _ = @import("desktop-text.zig");
    _ = @import("desktop-notification-banner.zig");
    _ = @import("desktop-quick-settings-view.zig");
    _ = @import("desktop-date-menu-view.zig");
    _ = @import("desktop-askpass-view.zig");
    _ = @import("desktop-sound-view.zig");
    _ = @import("desktop-panel-view.zig");
    _ = @import("desktop-form.zig");
    _ = @import("desktop-file-list.zig");
    _ = @import("desktop-keyboard.zig");
    _ = @import("desktop-apps-view.zig");
    _ = @import("desktop-dash-view.zig");
    _ = @import("desktop-password-entry.zig");
}

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
}

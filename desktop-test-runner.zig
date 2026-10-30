//! One unit-test binary, including tests from the actual production sources.
test {
    _ = @import("desktop-zig.zig");
    _ = @import("tests/desktop-gtk-abi.zig");
    _ = @import("tests/desktop-libc-abi.zig");
    _ = @import("tests/desktop-protocols.zig");
    _ = @import("desktop-switcher.zig");
}

//! Compare the checked-in ABI against independently translated system headers.
const abi = @import("abi-check.zig");
const reference = @import("glib-reference");

test "explicit Cairo declarations match the installed C ABI" {
    abi.checkDeclarations(@import("desktop-cairo.zig"), reference);
}

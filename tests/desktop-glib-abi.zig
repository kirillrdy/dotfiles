//! Compare the checked-in ABI against independently translated system headers.
const abi = @import("abi-check.zig");
const reference = @import("glib-reference");

test "explicit GLib, Cairo, librsvg and NetworkManager declarations match the installed C ABI" {
    abi.checkDeclarations(@import("../desktop-glib.zig"), reference);
    abi.checkDeclarations(@import("../desktop-wayland.zig"), reference);
    abi.checkDeclarations(@import("../desktop-network-api.zig"), reference);
    abi.checkDeclarations(@import("../desktop-text.zig").api, reference);
    abi.checkDeclarations(@import("../desktop-decode.zig").api, reference);
}

//! Compare the checked-in ABI against independently translated system headers.
const abi = @import("abi-check.zig");
const reference = @import("gtk-reference");

test "explicit toolkit and NetworkManager declarations match the installed C ABI" {
    abi.checkDeclarations(@import("../desktop-gtk.zig"), reference);
    abi.checkDeclarations(@import("../desktop-wayland.zig"), reference);
    abi.checkDeclarations(@import("../desktop-network-api.zig"), reference);
    abi.checkDeclarations(@import("../desktop-text.zig").api, reference);
}

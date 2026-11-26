//! Compare the checked-in C ABIs against independently translated system headers.
const abi = @import("abi-check.zig");

test "explicit desktop declarations match the installed C ABI" {
    abi.checkDeclarations(@import("../desktop-libc.zig"), @import("libc-reference"));
}

test "explicit PAM declarations match the installed Linux-PAM headers" {
    abi.checkDeclarations(@import("../desktop-pam.zig"), @import("pam-reference"));
}

test "explicit SPA and PipeWire constants match the installed PipeWire headers" {
    abi.checkDeclarations(@import("../desktop-spa.zig"), @import("pipewire"));
}

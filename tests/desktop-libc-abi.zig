//! Compare the checked-in libc ABI against independently translated system headers.
const abi = @import("abi-check.zig");

test "explicit desktop declarations match the installed C ABI" {
    abi.checkDeclarations(@import("../desktop-libc.zig"), @import("libc-reference"));
}

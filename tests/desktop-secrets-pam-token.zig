//! Test module only. Supplies a fixed dummy login password and checks the bridge captured it.
const std = @import("std");
const Handle = opaque {};
extern fn pam_set_item(?*Handle, c_int, ?*const anyopaque) c_int;
extern fn pam_get_data(?*const Handle, [*:0]const u8, *?*const anyopaque) c_int;
export fn pam_sm_authenticate(handle: ?*Handle, _: c_int, _: c_int, _: [*c][*c]const u8) c_int {
    return pam_set_item(handle, 6, "integration-vault-password");
}
export fn pam_sm_setcred(_: ?*Handle, _: c_int, _: c_int, _: [*c][*c]const u8) c_int {
    return 0;
}
export fn pam_sm_open_session(handle: ?*Handle, _: c_int, _: c_int, _: [*c][*c]const u8) c_int {
    var data: ?*const anyopaque = null;
    if (pam_get_data(handle, "desktop-secrets-token", &data) != 0 or data == null) return 6;
    const Cached = struct { length: usize, password: [4096]u8 };
    const cached: *const Cached = @ptrCast(@alignCast(data.?));
    if (!std.mem.eql(u8, cached.password[0..cached.length], "integration-vault-password")) return 6;
    return 0;
}
export fn pam_sm_close_session(handle: ?*Handle, _: c_int, _: c_int, _: [*c][*c]const u8) c_int {
    var data: ?*const anyopaque = null;
    if (pam_get_data(handle, "desktop-secrets-token", &data) != 0 or data == null) return 6;
    const Cached = struct { length: usize, password: [4096]u8 };
    const cached: *const Cached = @ptrCast(@alignCast(data.?));
    if (cached.length != 0) return 6;
    for (cached.password) |byte| {
        if (byte != 0) return 6;
    }
    return 0;
}

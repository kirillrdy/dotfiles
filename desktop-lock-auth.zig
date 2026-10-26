//! PAM stays off the Wayland thread. No credentials are passed to subprocesses.
const std = @import("std");
const PamHandle = opaque {};
pub const Message = extern struct { style: c_int, text: [*c]const u8 };
pub const Response = extern struct { text: [*c]u8 = null, code: c_int = 0 };
pub const Conversation = extern struct {
    callback: *const fn (c_int, [*c]const [*c]const Message, [*c][*c]Response, ?*anyopaque) callconv(.c) c_int,
    data: ?*anyopaque,
};
extern fn pam_start([*:0]const u8, [*:0]const u8, *const Conversation, *?*PamHandle) c_int;
extern fn pam_authenticate(?*PamHandle, c_int) c_int;
extern fn pam_acct_mgmt(?*PamHandle, c_int) c_int;
extern fn pam_end(?*PamHandle, c_int) c_int;
extern fn calloc(usize, usize) ?*anyopaque;
extern fn strdup([*:0]const u8) [*c]u8;
extern fn free(?*anyopaque) void;
const Attempt = struct { user: [*:0]const u8, password: [*:0]const u8, prompted: bool = false };

pub fn converse(count: c_int, messages: [*c]const [*c]const Message, responses: [*c][*c]Response, data: ?*anyopaque) callconv(.c) c_int {
    if (count <= 0 or count > 32 or messages == null or responses == null or data == null) return 19;
    responses.* = null;
    const attempt: *Attempt = @ptrCast(@alignCast(data));
    const result: [*]Response = @ptrCast(@alignCast(calloc(@intCast(count), @sizeOf(Response)) orelse return 5));
    var valid = true;
    for (0..@intCast(count)) |i| {
        if (messages[i] == null) {
            valid = false;
            break;
        }
        switch (messages[i].*.style) {
            1 => { // One hidden password prompt; fail closed on unsupported MFA challenges.
                if (attempt.prompted) {
                    valid = false;
                    break;
                }
                attempt.prompted = true;
                result[i].text = strdup(attempt.password);
                if (result[i].text == null) {
                    valid = false;
                    break;
                }
            },
            2 => {
                result[i].text = strdup(attempt.user);
                if (result[i].text == null) {
                    valid = false;
                    break;
                }
            },
            3, 4 => {},
            else => {
                valid = false;
                break;
            },
        }
    }
    if (!valid) {
        for (0..@intCast(count)) |i| if (result[i].text != null) {
            std.crypto.secureZero(u8, std.mem.span(result[i].text));
            free(result[i].text);
        };
        free(result);
        return 19;
    }
    responses.* = result;
    return 0;
}

pub fn authenticate(user: [*:0]const u8, password: [*:0]const u8) bool {
    var attempt = Attempt{ .user = user, .password = password };
    const conversation = Conversation{ .callback = converse, .data = &attempt };
    var handle: ?*PamHandle = null;
    var status = pam_start("desktop-lock", user, &conversation, &handle);
    if (status != 0) return false;
    defer _ = pam_end(handle, status);
    status = pam_authenticate(handle, 0x0001); // PAM_DISALLOW_NULL_AUTHTOK
    if (status != 0) return false;
    status = pam_acct_mgmt(handle, 0);
    return status == 0;
}

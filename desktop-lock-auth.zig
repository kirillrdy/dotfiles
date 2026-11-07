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

const Mock = struct {
    var conversation: Conversation = undefined;
    var authentication_status: c_int = 0;
    var account_status: c_int = 0;
    var end_status: c_int = -1;
    var account_calls: usize = 0;
    var prompt_twice = false;

    fn start(service: [*:0]const u8, user: [*:0]const u8, conv: *const Conversation, handle: *?*anyopaque) callconv(.c) c_int {
        std.debug.assert(std.mem.eql(u8, std.mem.span(service), "desktop-lock"));
        std.debug.assert(std.mem.eql(u8, std.mem.span(user), "fixture-user"));
        conversation = conv.*;
        handle.* = @ptrFromInt(16);
        return 0;
    }
    fn auth(_: ?*anyopaque, flags: c_int) callconv(.c) c_int {
        std.debug.assert(flags == 1);
        var info = Message{ .style = 4, .text = "Info" };
        var user = Message{ .style = 2, .text = "User" };
        var password = Message{ .style = 1, .text = "Password" };
        const messages = [_][*c]const Message{ &info, &user, &password };
        var responses: [*c]Response = null;
        const result = conversation.callback(3, &messages, &responses, conversation.data);
        std.debug.assert(result == 0);
        std.debug.assert(responses[0].text == null);
        std.debug.assert(std.mem.eql(u8, std.mem.span(responses[1].text), "fixture-user"));
        std.debug.assert(std.mem.eql(u8, std.mem.span(responses[2].text), "fixture-password"));
        for (0..3) |i| if (responses[i].text != null) {
            std.crypto.secureZero(u8, std.mem.span(responses[i].text));
            free(responses[i].text);
        };
        free(responses);
        if (prompt_twice) {
            const again = [_][*c]const Message{&password};
            responses = null;
            const second = conversation.callback(1, &again, &responses, conversation.data);
            std.debug.assert(second == 19 and responses == null);
            return second;
        }
        return authentication_status;
    }
    fn acct(_: ?*anyopaque, _: c_int) callconv(.c) c_int {
        account_calls += 1;
        return account_status;
    }
    fn end(_: ?*anyopaque, status: c_int) callconv(.c) c_int {
        end_status = status;
        return 0;
    }
};
comptime {
    if (@import("builtin").is_test) {
        @export(&Mock.start, .{ .name = "pam_start" });
        @export(&Mock.auth, .{ .name = "pam_authenticate" });
        @export(&Mock.acct, .{ .name = "pam_acct_mgmt" });
        @export(&Mock.end, .{ .name = "pam_end" });
    }
}

test "PAM requires authentication and valid account, and closes every transaction" {
    try std.testing.expect(authenticate("fixture-user", "fixture-password"));
    try std.testing.expectEqual(@as(c_int, 0), Mock.end_status);
    try std.testing.expectEqual(@as(usize, 1), Mock.account_calls);
    Mock.authentication_status = 7;
    try std.testing.expect(!authenticate("fixture-user", "fixture-password"));
    try std.testing.expectEqual(@as(c_int, 7), Mock.end_status);
    try std.testing.expectEqual(@as(usize, 1), Mock.account_calls);
    Mock.authentication_status = 0;
    Mock.account_status = 13;
    try std.testing.expect(!authenticate("fixture-user", "fixture-password"));
    try std.testing.expectEqual(@as(c_int, 13), Mock.end_status);
    Mock.account_status = 0;
    Mock.prompt_twice = true;
    try std.testing.expect(!authenticate("fixture-user", "fixture-password"));
    try std.testing.expectEqual(@as(c_int, 19), Mock.end_status);
}

//! PAM stays off the Wayland thread. No credentials are passed to subprocesses.
const std = @import("std");
const posix = @import("posix");

pub const Message = posix.struct_pam_message;
pub const Response = posix.struct_pam_response;
pub const Conversation = posix.struct_pam_conv;

extern fn strdup([*:0]const u8) [*c]u8;

pub const Attempt = struct {
    user: [*:0]const u8,
    password: [*:0]const u8,
    prompted: bool = false,
};

pub fn converse(count: c_int, messages: [*c]const [*c]const Message, responses: [*c][*c]Response, data: ?*anyopaque) callconv(.c) c_int {
    if (count <= 0 or count > 32 or messages == null or responses == null or data == null) return posix.PAM_CONV_ERR;
    responses.* = null;
    const attempt: *Attempt = @ptrCast(@alignCast(data));
    const result: [*]Response = @ptrCast(@alignCast(posix.calloc(@intCast(count), @sizeOf(Response)) orelse return posix.PAM_BUF_ERR));
    var valid = true;
    for (0..@intCast(count)) |i| {
        if (messages[i] == null) {
            valid = false;
            break;
        }
        switch (messages[i].*.msg_style) {
            posix.PAM_PROMPT_ECHO_OFF => { // One hidden password prompt; fail closed on unsupported MFA challenges.
                if (attempt.prompted) {
                    valid = false;
                    break;
                }
                attempt.prompted = true;
                result[i].resp = strdup(attempt.password);
                if (result[i].resp == null) {
                    valid = false;
                    break;
                }
            },
            posix.PAM_PROMPT_ECHO_ON => {
                result[i].resp = strdup(attempt.user);
                if (result[i].resp == null) {
                    valid = false;
                    break;
                }
            },
            posix.PAM_ERROR_MSG, posix.PAM_TEXT_INFO => {},
            else => {
                valid = false;
                break;
            },
        }
    }
    if (!valid) {
        for (0..@intCast(count)) |i| if (result[i].resp != null) {
            std.crypto.secureZero(u8, std.mem.span(result[i].resp));
            posix.free(result[i].resp);
        };
        posix.free(result);
        return posix.PAM_CONV_ERR;
    }
    responses.* = result;
    return posix.PAM_SUCCESS;
}

pub fn authenticate(user: [*:0]const u8, password: [*:0]const u8) bool {
    var attempt = Attempt{ .user = user, .password = password };
    var conversation = Conversation{ .conv = &converse, .appdata_ptr = &attempt };
    var handle: ?*posix.pam_handle_t = null;
    var status = posix.pam_start("desktop-lock", user, &conversation, &handle);
    if (status != posix.PAM_SUCCESS) return false;
    defer _ = posix.pam_end(handle, status);
    status = posix.pam_authenticate(handle, posix.PAM_DISALLOW_NULL_AUTHTOK);
    if (status != posix.PAM_SUCCESS) return false;
    status = posix.pam_acct_mgmt(handle, 0);
    return status == posix.PAM_SUCCESS;
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
        var info = Message{ .msg_style = posix.PAM_TEXT_INFO, .msg = "Info" };
        var user = Message{ .msg_style = posix.PAM_PROMPT_ECHO_ON, .msg = "User" };
        var password = Message{ .msg_style = posix.PAM_PROMPT_ECHO_OFF, .msg = "Password" };
        var messages = [_][*c]const Message{ &info, &user, &password };
        var responses: [*c]Response = null;
        const result = conversation.conv.?(3, &messages, &responses, conversation.appdata_ptr);
        std.debug.assert(result == 0);
        std.debug.assert(responses[0].resp == null);
        std.debug.assert(std.mem.eql(u8, std.mem.span(responses[1].resp), "fixture-user"));
        std.debug.assert(std.mem.eql(u8, std.mem.span(responses[2].resp), "fixture-password"));
        for (0..3) |i| if (responses[i].resp != null) {
            std.crypto.secureZero(u8, std.mem.span(responses[i].resp));
            posix.free(responses[i].resp);
        };
        posix.free(responses);
        if (prompt_twice) {
            var again = [_][*c]const Message{&password};
            responses = null;
            const second = conversation.conv.?(1, &again, &responses, conversation.appdata_ptr);
            std.debug.assert(second == posix.PAM_CONV_ERR and responses == null);
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

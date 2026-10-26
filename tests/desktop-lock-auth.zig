//! PAM is substituted at the ABI boundary; the production conversation is exercised.
const std = @import("std");
const auth = @import("auth");
var conversation: auth.Conversation = undefined;
var authentication_status: c_int = 0;
var account_status: c_int = 0;
var end_status: c_int = -1;
var account_calls: usize = 0;
var prompt_twice = false;
extern fn free(?*anyopaque) void;

export fn pam_start(service: [*:0]const u8, user: [*:0]const u8, conv: *const auth.Conversation, handle: *?*anyopaque) c_int {
    std.debug.assert(std.mem.eql(u8, std.mem.span(service), "desktop-lock"));
    std.debug.assert(std.mem.eql(u8, std.mem.span(user), "fixture-user"));
    conversation = conv.*;
    handle.* = @ptrFromInt(16);
    return 0;
}
export fn pam_authenticate(_: ?*anyopaque, flags: c_int) c_int {
    std.debug.assert(flags == 1);
    var info = auth.Message{ .style = 4, .text = "Info" };
    var user = auth.Message{ .style = 2, .text = "User" };
    var password = auth.Message{ .style = 1, .text = "Password" };
    const messages = [_][*c]const auth.Message{ &info, &user, &password };
    var responses: [*c]auth.Response = null;
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
        const again = [_][*c]const auth.Message{&password};
        responses = null;
        const second = conversation.callback(1, &again, &responses, conversation.data);
        std.debug.assert(second == 19 and responses == null);
        return second;
    }
    return authentication_status;
}
export fn pam_acct_mgmt(_: ?*anyopaque, _: c_int) c_int {
    account_calls += 1;
    return account_status;
}
export fn pam_end(_: ?*anyopaque, status: c_int) c_int {
    end_status = status;
    return 0;
}

test "PAM requires authentication and valid account, and closes every transaction" {
    try std.testing.expect(auth.authenticate("fixture-user", "fixture-password"));
    try std.testing.expectEqual(@as(c_int, 0), end_status);
    try std.testing.expectEqual(@as(usize, 1), account_calls);
    authentication_status = 7;
    try std.testing.expect(!auth.authenticate("fixture-user", "fixture-password"));
    try std.testing.expectEqual(@as(c_int, 7), end_status);
    try std.testing.expectEqual(@as(usize, 1), account_calls);
    authentication_status = 0;
    account_status = 13;
    try std.testing.expect(!auth.authenticate("fixture-user", "fixture-password"));
    try std.testing.expectEqual(@as(c_int, 13), end_status);
    account_status = 0;
    prompt_twice = true;
    try std.testing.expect(!auth.authenticate("fixture-user", "fixture-password"));
    try std.testing.expectEqual(@as(c_int, 19), end_status);
}

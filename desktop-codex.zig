//! Codex allowance data using the existing login. Credentials stay in memory.
const std = @import("std");
const u = @import("desktop-util.zig");
const http = @import("desktop-http.zig");
const usage = @import("desktop-usage.zig");

fn unavailable(message: []const u8) usage.Report {
    return usage.unavailable("Codex", message);
}

/// Reads `rate_limit.{primary,secondary}_window` from the usage response.
pub fn parseUsage(data: u.Value) [2]?usage.Window {
    const limits = u.get(data, "rate_limit");
    var windows: [2]?usage.Window = .{ null, null };
    for (&windows, [_][]const u8{ "primary_window", "secondary_window" }) |*window, key| {
        const source = u.get(limits, key);
        const used = u.number(u.get(source, "used_percent")) orelse continue;
        window.* = .{ .used = used, .reset_at = usage.stamp(u.get(source, "reset_at")) };
    }
    return windows;
}

pub fn read(a: u.Allocator) usage.Report {
    return fetch(a) catch unavailable("Codex usage is unavailable; check login and network");
}
fn fetch(a: u.Allocator) !usage.Report {
    const dir = u.env("CODEX_HOME") orelse try u.fmt(a, "{s}/.codex", .{u.env("HOME") orelse return error.NoHome});
    const auth = try u.parse(a, try u.read(a, try u.fmt(a, "{s}/auth.json", .{dir})));
    const nested = u.get(auth, "tokens");
    const tokens = if (nested == .object) nested else auth;
    const token = u.string(u.get(tokens, "access_token"));
    if (token.len == 0) return unavailable("Sign in with codex login to see account usage");
    const account = u.string(u.get(tokens, "account_id"));
    if (std.mem.indexOfAny(u8, account, "\r\n") != null) return error.InvalidAccount;
    const headers = [_]std.http.Header{
        try usage.bearerHeader(a, token),
        .{ .name = "ChatGPT-Account-Id", .value = account },
    };
    const response = try http.get(a, u.io, .{
        .url = "https://chatgpt.com/backend-api/wham/usage",
        .headers = headers[0..if (account.len > 0) 2 else 1],
    });
    defer a.free(response.body);
    const status = @backingInt(response.status);
    if (status == 401 or status == 403) return unavailable("Codex login needs refreshing; run codex login");
    if (status != 200) return unavailable(try u.fmt(a, "Codex usage service returned HTTP {d}", .{status}));
    return .{ .name = "Codex", .windows = parseUsage(try u.parse(a, response.body)) };
}

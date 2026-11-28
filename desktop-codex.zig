//! Codex allowance data using the existing login. Credentials stay in memory.
const std = @import("std");
const u = @import("desktop-util.zig");
const http = @import("desktop-http.zig");
const usage = @import("desktop-usage.zig");

fn unavailable(message: []const u8) usage.Report {
    return usage.unavailable("Codex", message);
}

/// Reads `rate_limit.{primary,secondary}_window` from the usage response.
pub fn parseUsage(data: std.json.Value) [2]?usage.Window {
    const limits = usage.jsonGet(data, "rate_limit");
    var windows: [2]?usage.Window = .{ null, null };
    for (&windows, [_][]const u8{ "primary_window", "secondary_window" }) |*window, key| {
        const source = usage.jsonGet(limits, key);
        const used = u.number(usage.jsonGet(source, "used_percent")) orelse continue;
        window.* = .{ .used = used, .reset_at = usage.stamp(usage.jsonGet(source, "reset_at")) };
    }
    return windows;
}

pub fn read(a: std.mem.Allocator, io: std.Io) usage.Report {
    return fetch(a, io) catch unavailable("Codex usage is unavailable; check login and network");
}
fn fetch(a: std.mem.Allocator, io: std.Io) !usage.Report {
    const dir = u.env("CODEX_HOME") orelse try std.fmt.allocPrint(a, "{s}/.codex", .{u.env("HOME") orelse return error.NoHome});
    const auth = try usage.parseJson(a, try std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(a, "{s}/auth.json", .{dir}), a, .limited(4 * 1024 * 1024)));
    const nested = usage.jsonGet(auth, "tokens");
    const tokens = if (nested == .object) nested else auth;
    const token = usage.jsonString(usage.jsonGet(tokens, "access_token"));
    if (token.len == 0) return unavailable("Sign in with codex login to see account usage");
    const account = usage.jsonString(usage.jsonGet(tokens, "account_id"));
    if (std.mem.indexOfAny(u8, account, "\r\n") != null) return error.InvalidAccount;
    const headers = [_]std.http.Header{
        try usage.bearerHeader(a, token),
        .{ .name = "ChatGPT-Account-Id", .value = account },
    };
    const response = try http.get(a, io, .{
        .url = "https://chatgpt.com/backend-api/wham/usage",
        .headers = headers[0..if (account.len > 0) 2 else 1],
    });
    defer a.free(response.body);
    const status = @backingInt(response.status);
    if (status == 401 or status == 403) return unavailable("Codex login needs refreshing; run codex login");
    if (status != 200) return unavailable(try std.fmt.allocPrint(a, "Codex usage service returned HTTP {d}", .{status}));
    return .{ .name = "Codex", .windows = parseUsage(try usage.parseJson(a, response.body)) };
}

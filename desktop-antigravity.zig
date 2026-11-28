//! Antigravity allowance data using agy's existing Google login. agy keeps an
//! OAuth token in the Secret Service; it is only read here, and agy itself
//! owns refreshing it. Secrets live in a scratch arena that is wiped and freed
//! before the report is returned.
const std = @import("std");
const u = @import("desktop-util.zig");
const dbus = @import("dbus");
const http = @import("desktop-http.zig");
const usage = @import("desktop-usage.zig");
const claude = @import("desktop-claude.zig");

const name = "Antigravity";

fn unavailable(message: []const u8) usage.Report {
    return usage.unavailable(name, message);
}

/// Which shared window (0 = 5h, 1 = 7d) a quota bucket describes, if known.
fn slot(bucket: std.json.Value) ?usize {
    const window = usage.jsonGet(bucket, "window");
    // A protobuf Duration ("18000s"), or an object with seconds.
    const seconds: ?f64 = switch (window) {
        .string => |s| if (s.len > 1 and s[s.len - 1] == 's') std.fmt.parseFloat(f64, s[0 .. s.len - 1]) catch null else null,
        .object => u.number(usage.jsonGet(window, "seconds")) orelse if (usage.jsonString(usage.jsonGet(window, "seconds")).len > 0) std.fmt.parseFloat(f64, usage.jsonString(usage.jsonGet(window, "seconds"))) catch null else null,
        else => u.number(window),
    };
    if (seconds) |s| return if (s <= 86400) 0 else 1;
    // Otherwise go by the window, id or name text.
    for ([_][]const u8{ "window", "bucketId", "displayName" }) |key| {
        var buffer: [128]u8 = undefined;
        const text = usage.jsonString(usage.jsonGet(bucket, key));
        const lower = std.ascii.lowerString(buffer[0..@min(text.len, buffer.len)], text[0..@min(text.len, buffer.len)]);
        for ([_][]const u8{ "week", "7d", "7 d", "seven", "day" }) |word| if (std.mem.indexOf(u8, lower, word) != null) return 1;
        for ([_][]const u8{ "hour", "5h", "5 h", "five", "session" }) |word| if (std.mem.indexOf(u8, lower, word) != null) return 0;
    }
    // Per-model buckets from `retrieveUserQuota` report the 5-hour quota.
    if (usage.jsonString(usage.jsonGet(bucket, "modelId")).len > 0) return 0;
    return null;
}

fn tighter(current: ?usage.Window, candidate: usage.Window) usage.Window {
    const prev = current orelse return candidate;
    if (candidate.used > prev.used) return candidate;
    if (candidate.used < prev.used) return prev;
    if (candidate.reset_at) |c_reset| {
        if (prev.reset_at) |p_reset| return if (c_reset < p_reset) candidate else prev;
        return candidate;
    }
    return prev;
}

/// Combines two window sets, keeping the tightest bucket for each slot.
pub fn mergeWindows(first: [2]?usage.Window, second: [2]?usage.Window) [2]?usage.Window {
    var result = first;
    for (second, 0..) |maybe, i| {
        if (maybe) |w| result[i] = tighter(result[i], w);
    }
    return result;
}

fn mentionsGemini(text: []const u8) bool {
    var buffer: [128]u8 = undefined;
    const lower = std.ascii.lowerString(buffer[0..@min(text.len, buffer.len)], text[0..@min(text.len, buffer.len)]);
    return std.mem.indexOf(u8, lower, "gemini") != null;
}

/// Whether a bucket (or the group holding it) belongs to the Gemini models.
fn isGemini(group: std.json.Value, bucket: std.json.Value) bool {
    if (mentionsGemini(usage.jsonString(usage.jsonGet(group, "displayName")))) return true;
    for ([_][]const u8{ "bucketId", "modelId" }) |key| if (mentionsGemini(usage.jsonString(usage.jsonGet(bucket, key)))) return true;
    return false;
}

/// Reads `retrieveUserQuota` and `retrieveUserQuotaSummary`: buckets, directly
/// or in groups, each with a `remainingFraction` and `resetTime`. When any
/// Gemini bucket is present, only Gemini buckets count, so the separate
/// Claude/GPT allowance does not hide the Gemini one. The tightest bucket of
/// each window wins. Buckets without a recognisable window fill the 5h slot
/// by earliest reset and the 7d slot by latest.
pub fn parseUsage(data: std.json.Value) [2]?usage.Window {
    var windows: [2]?usage.Window = .{ null, null };
    var unknown: [2]?usage.Window = .{ null, null };
    var lists: [65]std.json.Value = undefined;
    var owners: [65]std.json.Value = undefined;
    var count: usize = 0;
    lists[count] = usage.jsonGet(data, "buckets");
    owners[count] = .null;
    count += 1;
    const groups = usage.jsonGet(data, "groups");
    if (groups == .array) for (groups.array.items) |group| {
        if (count == lists.len) break;
        lists[count] = usage.jsonGet(group, "buckets");
        owners[count] = group;
        count += 1;
    };
    var gemini_only = false;
    for (lists[0..count], owners[0..count]) |list, group| {
        if (list != .array) continue;
        for (list.array.items) |bucket| if (isGemini(group, bucket)) {
            gemini_only = true;
        };
    }
    for (lists[0..count], owners[0..count]) |list, group| {
        if (list != .array) continue;
        for (list.array.items) |bucket| {
            if (gemini_only and !isGemini(group, bucket)) continue;
            if (usage.jsonGet(bucket, "disabled") == .bool and usage.jsonGet(bucket, "disabled").bool) continue;
            const fraction = u.number(usage.jsonGet(bucket, "remainingFraction")) orelse continue;
            const window: usage.Window = .{ .used = (1 - std.math.clamp(fraction, 0, 1)) * 100, .reset_at = claude.parseTimestamp(usage.jsonString(usage.jsonGet(bucket, "resetTime"))) };
            if (slot(bucket)) |i| {
                windows[i] = tighter(windows[i], window);
                continue;
            }
            const reset = window.reset_at orelse std.math.maxInt(i64);
            if (unknown[0] == null or reset < unknown[0].?.reset_at orelse std.math.maxInt(i64)) unknown[0] = window;
            if (unknown[1] == null or reset > unknown[1].?.reset_at orelse std.math.maxInt(i64)) unknown[1] = window;
        }
    }
    if (windows[0] == null and windows[1] == null) {
        windows[0] = unknown[0];
        // One bucket fills only the 5h slot.
        if (unknown[1] != null and unknown[0] != null and unknown[1].?.reset_at != unknown[0].?.reset_at) windows[1] = unknown[1];
    }
    return windows;
}

/// agy stores a Go `oauth2.Token` as JSON, optionally base64 encoded by go-keyring.
pub fn parseToken(a: std.mem.Allocator, raw: []const u8, now: i64) !union(enum) { token: []const u8, expired } {
    var text = raw;
    const prefix = "go-keyring-base64:";
    if (std.mem.startsWith(u8, text, prefix)) {
        const encoded = text[prefix.len..];
        const decoded = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
        try std.base64.standard.Decoder.decode(decoded, encoded);
        text = decoded;
    }
    const parsed = usage.parseJson(a, text) catch return .{ .token = std.mem.trim(u8, text, " \n\r\t") };
    const nested = usage.jsonGet(parsed, "token");
    const token = if (nested == .object) nested else parsed;
    const access = usage.jsonString(usage.jsonGet(token, "access_token"));
    const value = if (access.len > 0) access else usage.jsonString(usage.jsonGet(token, "accessToken"));
    if (value.len == 0) return error.NoToken;
    if (claude.parseTimestamp(usage.jsonString(usage.jsonGet(token, "expiry")))) |expiry| if (expiry <= now) return .expired;
    return .{ .token = value };
}

const service = "org.freedesktop.secrets";
const root = "/org/freedesktop/secrets";
const Secret = struct { dbus.ObjectPath, dbus.Bytes, dbus.Bytes, []const u8 };

fn call(bus: *dbus.Connection, path: []const u8, interface: []const u8, member: []const u8, args: anytype) !dbus.Connection.Owned {
    return bus.callBlocking(.{ .destination = service, .path = path, .interface = interface, .member = member }, args, 5000);
}

/// The raw keyring value for service=gemini, username=antigravity.
fn secret(a: std.mem.Allocator) ![]const u8 {
    const bus = dbus.Connection.open(a, .session) catch return error.NoSessionBus;
    defer bus.close();
    const item = blk: {
        const attributes = dbus.Dict([]const u8, []const u8){ .entries = &.{ .{ .key = "service", .value = "gemini" }, .{ .key = "username", .value = "antigravity" } } };
        const reply = try call(bus, root, "org.freedesktop.Secret.Service", "SearchItems", .{attributes});
        defer reply.deinit();
        const found = try reply.message().read(struct { []const dbus.ObjectPath, []const dbus.ObjectPath });
        if (found[0].len == 0) return if (found[1].len > 0) error.Locked else error.NoToken;
        break :blk try a.dupe(u8, found[0][0].value);
    };
    const session = blk: {
        const reply = try call(bus, root, "org.freedesktop.Secret.Service", "OpenSession", .{ "plain", dbus.Value{ .string = "" } });
        defer reply.deinit();
        break :blk try a.dupe(u8, (try reply.message().read(struct { dbus.Value, dbus.ObjectPath }))[1].value);
    };
    defer if (call(bus, session, "org.freedesktop.Secret.Session", "Close", .{})) |reply| reply.deinit() else |_| {};
    // Replies allocate from `a`, so the wiping arena in `read` clears them.
    const reply = try call(bus, item, "org.freedesktop.Secret.Item", "GetSecret", .{dbus.ObjectPath{ .value = session }});
    defer reply.deinit();
    const value = (try reply.message().read(struct { Secret }))[0];
    if (value[2].value.len > 64 * 1024) return error.InvalidReply;
    return a.dupe(u8, value[2].value);
}

pub fn read(a: std.mem.Allocator, io: std.Io) usage.Report {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const report = fetch(arena.allocator(), io) catch |err| switch (err) {
        error.NoToken => unavailable("Sign in with agy to see account usage"),
        error.Locked => unavailable("Unlock the keyring to see Antigravity usage"),
        else => unavailable("Antigravity usage is unavailable; check login and network"),
    };
    var copy = report;
    copy.@"error" = a.dupe(u8, report.@"error") catch "Antigravity usage is unavailable";
    return copy;
}
fn fetch(a: std.mem.Allocator, io: std.Io) !usage.Report {
    const now = std.Io.Clock.real.now(io).toSeconds();
    const token = switch (try parseToken(a, try secret(a), now)) {
        .token => |value| value,
        .expired => return unavailable("Antigravity login expired; run agy to refresh it"),
    };
    // Never pass authorization through process arguments or log HTTP headers.
    if (std.mem.indexOfAny(u8, token, "\r\n") != null) return error.InvalidToken;
    const home = u.env("HOME") orelse return error.NoHome;
    const project = std.mem.trim(u8, u.read(a, io, try std.fmt.allocPrint(a, "{s}/.gemini/antigravity-cli/cache/default_project_id.txt", .{home})) catch "", " \n\r\t");
    const body = if (project.len > 0 and std.mem.indexOfAny(u8, project, "\"\\") == null) try std.fmt.allocPrint(a, "{{\"project\":\"{s}\"}}", .{project}) else "{}";
    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{token}) },
        .{ .name = "Content-Type", .value = "application/json" },
    };
    const response = try http.get(a, io, .{
        .url = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        .headers = &headers,
        .body = body,
        .timeout = .fromSeconds(10),
        // Cloud Code gates the Gemini Models summary group on the Hub client family.
        .user_agent = "antigravity/hub/2.9.1 linux/amd64",
    });
    const status = @backingInt(response.status);
    if (status == 401 or status == 403) return unavailable("Antigravity login needs refreshing; run agy");
    if (status != 200) return unavailable(try std.fmt.allocPrint(a, "Antigravity usage service returned HTTP {d}", .{status}));
    return .{ .name = name, .windows = parseUsage(try usage.parseJson(a, response.body)) };
}

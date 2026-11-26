const std = @import("std");
const u = @import("desktop-util.zig");
const panel = @import("desktop-panel-data.zig");
const codex = @import("desktop-codex.zig");
const claude = @import("desktop-claude.zig");
const antigravity = @import("desktop-antigravity.zig");
const usage = @import("desktop-usage.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;
test "panel uses native microphone mute state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: panel.Update = .{ .items = &.{} };
    try panel.addAudio(a, &out, .{ .percent = 65 }, .{ .percent = 40, .muted = true });
    try equal(@as(usize, 2), out.items.?.len);
    try strings("microphone-sensitivity-muted-symbolic", out.items.?[1].icon);
}

test "integration: Linux virtual files are read despite reporting size zero" {
    if (!@import("options").integration_tests) return error.SkipZigTest;
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    const stat = try u.read(a, "/proc/stat");
    defer a.free(stat);
    try expect(std.mem.startsWith(u8, stat, "cpu "));
    const counters = panel.cpuCounters(stat);
    try expect(counters[0] + counters[2] + counters[3] > 0);
    const meminfo = try u.read(a, "/proc/meminfo");
    defer a.free(meminfo);
    try expect(panel.memoryUsage(meminfo).total > 0.001);
}
test "CPU categories share one total; idle and counter resets stay zero" {
    try equal([5]f64{ 20, 10, 5, 5, 10 }, panel.cpuUsage(@as([8]u64, @splat(0)), .{ 20, 5, 10, 50, 5, 3, 4, 3 }));
    try equal(@as([5]f64, @splat(0)), panel.cpuUsage(@as([8]u64, @splat(100)), @as([8]u64, @splat(0))));
    try equal(@as([5]f64, @splat(0)), panel.cpuUsage(@as([8]u64, @splat(0)), .{ 0, 0, 0, 100, 0, 0, 0, 0 }));
    try equal([8]u64{ 20, 5, 10, 50, 5, 3, 4, 3 }, panel.cpuCounters("cpu  20 5 10 50 5 3 4 3 10\ncpu0 99\n"));
}
test "memory separates programs buffers and cache" {
    const result = panel.memoryUsage("MemTotal: 1048576 kB\nMemFree: 262144 kB\nBuffers: 131072 kB\nCached: 262144 kB\nSReclaimable: 131072 kB\nShmem: 131072 kB\n");
    try equal([3]f64{ 37.5, 12.5, 25 }, result.values);
    try equal(@as(f64, 0.375), result.used);
    try equal(@as(f64, 1), result.total);
    try expect(panel.memoryUsage("MemTotal: 0 kB\nMemFree: 0 kB\n").total > 0);
}
test "network rate units" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]f64{ 1024, 1048576, 1073741824 }, [_][]const u8{ "KiB/s", "MiB/s", "GiB/s" }) |rate, unit| try expect(std.mem.indexOf(u8, try panel.rateText(a, rate), unit) != null);
    try expect(std.mem.startsWith(u8, try panel.rateText(a, -1), "0"));
}
test "panel appends native battery state and omits absent batteries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: panel.Update = .{ .items = &.{.{ .icon = "audio-volume-high-symbolic" }} };
    try panel.addBattery(a, &out, .{});
    try equal(@as(usize, 1), out.items.?.len);
    try panel.addBattery(a, &out, .{ .present = true, .percent = 80, .state = 2, .time_to_empty = 9000 });
    const items = out.items.?;
    try equal(@as(usize, 2), items.len);
    try strings("battery-level-80-symbolic", items[1].icon);
    try strings("2∶30", items[1].text);
}
test "usage renders remaining budget for both popup windows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const windows = codex.parseUsage(try u.parse(a, "{\"rate_limit\":{\"primary_window\":{\"used_percent\":46},\"secondary_window\":{\"used_percent\":7}}}"));
    const out = try usage.update(a, .{ .name = "Codex", .windows = windows }, "icon", 1000);
    try strings("54%", out.items.?[0].text);
    try strings("icon", out.items.?[0].icon);
    try expect(std.mem.indexOf(u8, out.tooltip, "Codex allowance remaining") != null);
    try expect(std.mem.indexOf(u8, out.tooltip, "7d: 93% remaining") != null);
    try equal(@as(?f64, 54), out.windows[0].percent);
    try strings("", out.@"error");
    const missing = try usage.update(a, .{ .name = "Codex", .windows = codex.parseUsage(try u.parse(a, "{\"rate_limit\":{\"secondary_window\":{\"used_percent\":7}}}")) }, "", 1000);
    try strings("—", missing.items.?[0].text);
    try equal(@as(?f64, null), missing.windows[0].percent);
    try equal(@as(?f64, 93), missing.windows[1].percent);
    for ([_][]const u8{ "null", "true", "\"50\"", "{}" }) |value| {
        const invalid = try u.parse(a, try u.fmt(a, "{{\"rate_limit\":{{\"primary_window\":{{\"used_percent\":{s}}}}}}}", .{value}));
        const out_invalid = try usage.update(a, .{ .name = "Codex", .windows = codex.parseUsage(invalid) }, "", 1000);
        try strings("Codex usage is unavailable", out_invalid.@"error");
        try equal(@as(usize, 0), out_invalid.windows.len);
    }
}
test "usage reset countdown handles missing invalid and past timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try strings("Resets in 2d 3h", try usage.resetText(a, 1000 + 2 * 86400 + 3 * 3600, 1000));
    try strings("Resets in 2h 15m", try usage.resetText(a, 1000 + 2 * 3600 + 15 * 60, 1000));
    try strings("Resets in now", try usage.resetText(a, 900, 1000));
    try strings("Resets: —", try usage.resetText(a, null, 1000));
    for ([_]u.Value{ .null, .{ .bool = true }, u.str("1000"), u.num(std.math.nan(f64)), u.num(std.math.inf(f64)), u.num(1e13) }) |value| try equal(@as(?i64, null), usage.stamp(value));
    try equal(@as(?i64, 1000), usage.stamp(u.num(1000.5)));
}

test "disk usage uses fragment sizes and excludes free reserved blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try strings("2.0G/4.0G", try panel.diskUsageText(arena.allocator(), .{
        .f_bsize = 8192,
        .f_frsize = 4096,
        .f_blocks = 1048576,
        .f_bfree = 524288,
        .f_bavail = 262144,
    }));
    try strings("0B/0B", try panel.diskUsageText(arena.allocator(), .{}));
}

test "integration: disk panel queries the root filesystem without commands" {
    if (!@import("options").integration_tests) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try panel.sample(arena.allocator(), "disk", false);
    const entry = result.items.?[0];
    const label = entry.text;
    try expect(!std.mem.eql(u8, label, "—/—"));
    try expect(std.mem.indexOfScalar(u8, label, '/') != null);
    try strings("", entry.command);
}

test {
    // Initialize SVG loaders before any test creates an icon theme or decoder.
    // Nix builds do not inherit the graphical session's loader environment.
    try @import("desktop-runtime.zig").setup(std.testing.allocator);
    _ = @import("desktop-zig.zig");
    _ = @import("tests/desktop-libc-abi.zig");
    _ = @import("desktop-fonts.zig");
    _ = @import("desktop-pipewire.zig");
    _ = @import("desktop-xkb.zig");
    _ = @import("desktop-switcher.zig");
    _ = @import("desktop-overview.zig");
    _ = @import("desktop-overview-animation.zig");
    _ = @import("desktop-overview-layout.zig");
    _ = @import("desktop-hot-corner.zig");
    _ = @import("tests/desktop-overview-render.zig");
    _ = @import("desktop-wallpaper.zig");
    _ = @import("desktop-surface.zig");
    _ = @import("desktop-osd-view.zig");
    _ = @import("desktop-screenshot.zig");
    _ = @import("desktop-png.zig");
    _ = @import("desktop-raster.zig");
    _ = @import("desktop-path.zig");
    _ = @import("desktop-svg.zig");
    _ = @import("desktop-text.zig");
    _ = @import("desktop-notification-banner.zig");
    _ = @import("desktop-quick-settings-view.zig");
    _ = @import("desktop-quick-settings.zig");
    _ = @import("desktop-date-menu-view.zig");
    _ = @import("desktop-date-menu.zig");
    _ = @import("desktop-popup.zig");
    _ = @import("desktop-askpass-view.zig");
    _ = @import("desktop-sound-view.zig");
    _ = @import("desktop-panel-view.zig");
    _ = @import("desktop-widgets.zig");
    _ = @import("desktop-dbus-text.zig");
    _ = @import("desktop-gvariant.zig");
    _ = @import("desktop-gvdb.zig");
    _ = @import("desktop-gsettings.zig");
    _ = @import("desktop-icons.zig");
    _ = @import("desktop-decode.zig");
    _ = @import("desktop-form.zig");
    _ = @import("desktop-file-list.zig");
    _ = @import("desktop-keyboard.zig");
    _ = @import("desktop-input.zig");
    _ = @import("desktop-apps-view.zig");
    _ = @import("desktop-apps.zig");
    _ = @import("desktop-dash-view.zig");
    _ = @import("desktop-password-entry.zig");
    _ = @import("desktop-runtime.zig");
    _ = @import("desktop-secrets.zig");
    _ = @import("desktop-portal-email.zig");
    _ = @import("desktop-portal-options.zig");
    _ = @import("desktop-audio.zig");
    _ = @import("desktop-audio-pod.zig");
    _ = @import("desktop-battery.zig");
    _ = @import("desktop-battery-monitor.zig");
    _ = @import("desktop-backlight.zig");
    _ = @import("desktop-network.zig");
    _ = @import("desktop-portal-capture.zig");
    _ = @import("desktop-output.zig");
    _ = @import("desktop-lock.zig");
    _ = @import("desktop-lock-view.zig");
    _ = @import("desktop-login-ui.zig");
    _ = @import("desktop-login-client.zig");
    _ = @import("desktop-datetime.zig");
    _ = @import("desktop-paths.zig");
    _ = @import("desktop-netmon.zig");
    _ = @import("desktop-appinfo.zig");
    _ = @import("desktop-mime.zig");
    _ = @import("desktop-process.zig");
    _ = @import("desktop-watch.zig");
    _ = @import("desktop-unicode.zig");
    _ = @import("desktop-loop.zig");
    _ = @import("desktop-greeter-view.zig");
    _ = @import("desktop-greeter.zig");
    _ = @import("desktop-dm.zig");
    _ = @import("desktop-idle.zig");
    _ = @import("desktop-osd.zig");
    _ = @import("desktop-settings.zig");
    _ = @import("desktop-http.zig");
    _ = @import("desktop-lock-auth.zig");
    _ = @import("desktop-wayland-client.zig");
    _ = @import("tests/desktop-dbus-bus.zig");
    _ = @import("tests/desktop-power-fixture.zig");
}

test "integration: monitor updates retain their sampled values across later samples" {
    if (!@import("options").integration_tests) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var monitor = try panel.Monitor.init(alloc);
    const first = try monitor.sample(alloc, true);
    const original = first.monitors.?[0].values[0];
    const second = try monitor.sample(alloc, true);
    try equal(original, first.monitors.?[0].values[0]);
    try expect(second.monitors.?[0].values[0] != original);
}
test "Claude parses RFC 3339 reset timestamps" {
    try equal(@as(?i64, 1762232399), claude.parseTimestamp("2025-11-04T04:59:59.943648+00:00"));
    try equal(@as(?i64, 1762232399), claude.parseTimestamp("2025-11-04T04:59:59Z"));
    try equal(@as(?i64, 1762232399), claude.parseTimestamp("2025-11-04T15:59:59+11:00"));
    try equal(@as(?i64, 951782400), claude.parseTimestamp("2000-02-29T00:00:00Z"));
    for ([_][]const u8{ "", "2025-11-04", "2025-13-04T04:59:59Z", "2025-11-04T04:59:59", "2025-11-04T04:59:59.Z", "2025-11-04T04:59:59+0000" }) |value| try equal(@as(?i64, null), claude.parseTimestamp(value));
}
test "Claude maps five-hour and weekly utilization onto the shared windows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const windows = claude.parseUsage(try u.parse(a, "{\"five_hour\":{\"utilization\":46.0,\"resets_at\":\"1970-01-01T00:16:40+00:00\"},\"seven_day\":{\"utilization\":7,\"resets_at\":\"1970-01-03T03:16:40Z\"},\"seven_day_opus\":null}"));
    const out = try usage.update(a, .{ .name = "Claude", .windows = windows }, "", 1000);
    try strings("54%", out.items.?[0].text);
    try expect(std.mem.indexOf(u8, out.tooltip, "Claude allowance remaining") != null);
    try strings("Resets in 2d 3h", out.windows[1].reset);
    // An idle five-hour window is reported as null and means nothing is used.
    const idle = claude.parseUsage(try u.parse(a, "{\"five_hour\":null,\"seven_day\":{\"utilization\":20}}"));
    try strings("100%", (try usage.update(a, .{ .name = "Claude", .windows = idle }, "", 1000)).items.?[0].text);
    for ([_][]const u8{ "{}", "{\"five_hour\":null,\"seven_day\":null}", "{\"error\":{}}" }) |value| {
        const none = claude.parseUsage(try u.parse(a, value));
        try expect(none[0] == null and none[1] == null);
    }
}

test "Claude backs off after 429 like Claude Code and keeps the last usage" {
    try equal(@as(i64, 300), claude.backoffSeconds(null));
    try equal(@as(i64, 300), claude.backoffSeconds(0));
    try equal(@as(i64, 90), claude.backoffSeconds(90));
    try equal(@as(i64, 3600), claude.backoffSeconds(86400));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const previous: usage.Report = .{ .name = "Claude", .windows = .{ .{ .used = 46 }, .{ .used = 7 } }, .checked = 1000 };
    const kept = try usage.update(a, try claude.rateLimited(a, previous, 1300), "", 1100);
    try strings("54%", kept.items.?[0].text);
    try expect(std.mem.indexOf(u8, kept.tooltip, "Rate limited; retrying at") != null);
    try expect(std.mem.indexOf(u8, kept.checked, "retry") != null);
    const empty = try usage.update(a, try claude.rateLimited(a, null, 1300), "", 1100);
    try equal(@as(usize, 0), empty.windows.len);
    try expect(std.mem.indexOf(u8, empty.@"error", "rate limited") != null);
}

test "Antigravity reports the Gemini allowance, not the Claude/GPT one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const windows = antigravity.parseUsage(try u.parse(a,
        \\{"groups":[{"displayName":"Gemini","buckets":[
        \\  {"window":"18000s","remainingFraction":0.8,"resetTime":"1970-01-01T00:16:40Z"},
        \\  {"window":"604800s","remainingFraction":0.95,"resetTime":"1970-01-03T03:16:40Z"}]},
        \\ {"displayName":"Claude","buckets":[
        \\  {"window":"18000s","remainingFraction":0.54,"resetTime":"1970-01-01T00:16:40Z"},
        \\  {"window":"604800s","remainingFraction":0.1,"disabled":true}]}]}
    ));
    const out = try usage.update(a, .{ .name = "Antigravity", .windows = windows }, "", 1000);
    try strings("80%", out.items.?[0].text);
    try expect(std.mem.indexOf(u8, out.tooltip, "Antigravity allowance remaining") != null);
    try strings("Resets in 2d 3h", out.windows[1].reset);
    try expect(@abs(out.windows[1].percent.? - 95) < 1e-9);
    // The live summary: a Gemini Models group and a Claude and GPT models group.
    const summary = antigravity.parseUsage(try u.parse(a,
        \\{"groups":[{"displayName":"Gemini Models","buckets":[
        \\  {"bucketId":"gemini-weekly","window":"weekly","resetTime":"1970-01-03T00:00:00Z","remainingFraction":0.70},
        \\  {"bucketId":"gemini-5h","window":"5h","resetTime":"1970-01-01T01:00:00Z","remainingFraction":0.94}]},
        \\ {"displayName":"Claude and GPT models","buckets":[
        \\  {"bucketId":"3p-weekly","window":"weekly","resetTime":"1970-01-03T00:00:00Z","remainingFraction":0.58},
        \\  {"bucketId":"3p-5h","window":"5h","resetTime":"1970-01-01T03:00:00Z","remainingFraction":0.52}]}]}
    ));
    try expect(@abs(summary[0].?.used - 6) < 1e-9 and @abs(summary[1].?.used - 30) < 1e-9);
    // Per-model buckets: Claude models are ignored when Gemini ones exist.
    const models = antigravity.parseUsage(try u.parse(a,
        \\{"buckets":[
        \\  {"modelId":"claude-opus-5-5-high","resetTime":"1970-01-01T03:00:00Z","remainingFraction":0.17},
        \\  {"modelId":"gemini-3.8-flash-high","resetTime":"1970-01-01T01:00:00Z","remainingFraction":0.93}]}
    ));
    try expect(@abs(models[0].?.used - 7) < 1e-6);
    // The live service labels windows "5h" and "weekly".
    const live = antigravity.parseUsage(try u.parse(a, "{\"groups\":[{\"buckets\":[{\"bucketId\":\"3p-weekly\",\"window\":\"weekly\",\"resetTime\":\"1970-01-03T03:16:40Z\",\"remainingFraction\":0.9},{\"bucketId\":\"3p-5h\",\"window\":\"5h\",\"resetTime\":\"1970-01-01T00:16:40Z\",\"remainingFraction\":0.25}]}]}"));
    try expect(@abs(live[0].?.used - 75) < 1e-9 and @abs(live[1].?.used - 10) < 1e-9);
    // Per-model buckets from retrieveUserQuota populate only the 5h slot and
    // merge with weekly summary groups.
    const per_model = antigravity.parseUsage(try u.parse(a,
        \\{"buckets":[
        \\  {"modelId":"tab_flash_lite_preview","remainingFraction":1},
        \\  {"modelId":"claude-opus-5-5-high","resetTime":"1970-01-01T05:00:00Z","remainingFraction":1},
        \\  {"modelId":"gemini-3.8-flash-tiered","resetTime":"1970-01-01T04:00:00Z","remainingFraction":0.76}]}
    ));
    try expect(@abs(per_model[0].?.used - 24) < 1e-9 and per_model[0].?.reset_at.? == 4 * 3600);
    try expect(per_model[1] == null);
    const merged = antigravity.mergeWindows(per_model, antigravity.parseUsage(try u.parse(a,
        \\{"groups":[{"buckets":[
        \\  {"bucketId":"3p-weekly","window":"weekly","resetTime":"1970-01-03T00:00:00Z","remainingFraction":1},
        \\  {"bucketId":"3p-5h","window":"5h","resetTime":"1970-01-01T05:00:00Z","remainingFraction":1}]}]}
    )));
    try expect(@abs(merged[0].?.used - 24) < 1e-9 and @abs(merged[1].?.used - 0) < 1e-9);
    // Unlabelled buckets are placed by reset time.
    const ordered = antigravity.parseUsage(try u.parse(a, "{\"buckets\":[{\"remainingFraction\":0.5,\"resetTime\":\"1970-01-03T00:00:00Z\"},{\"remainingFraction\":0.25,\"resetTime\":\"1970-01-01T01:00:00Z\"}]}"));
    try expect(@abs(ordered[0].?.used - 75) < 1e-9 and @abs(ordered[1].?.used - 50) < 1e-9);
    for ([_][]const u8{ "{}", "{\"buckets\":[]}", "{\"groups\":[{\"buckets\":[{\"window\":\"18000s\"}]}]}" }) |value| {
        const none = antigravity.parseUsage(try u.parse(a, value));
        try expect(none[0] == null and none[1] == null);
    }
}

test "Antigravity reads agy's stored OAuth token and notices expiry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = "{\"access_token\":\"ya29.fixture\",\"token_type\":\"Bearer\",\"refresh_token\":\"r\",\"expiry\":\"1970-01-01T00:16:40.123456789+11:00\"}";
    try strings("ya29.fixture", (try antigravity.parseToken(a, json, -40000)).token);
    try expect(try antigravity.parseToken(a, json, 1000) == .expired);
    const encoded = try std.fmt.allocPrint(a, "go-keyring-base64:{b64}", .{json});
    try strings("ya29.fixture", (try antigravity.parseToken(a, encoded, -40000)).token);
    try strings("ya29.nested", (try antigravity.parseToken(a, "{\"token\":{\"access_token\":\"ya29.nested\"}}", 0)).token);
    try std.testing.expectError(error.NoToken, antigravity.parseToken(a, "{\"token_type\":\"Bearer\"}", 0));
}

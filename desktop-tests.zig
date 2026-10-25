const std = @import("std");
const u = @import("desktop-util.zig");
const panel = @import("waybar-panel.zig");
const codex = @import("waybar-codex.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;
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
test "network units and cached NetworkManager strength" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]f64{ 1024, 1048576, 1073741824 }, [_][]const u8{ "KiB/s", "MiB/s", "GiB/s" }) |rate, unit| try expect(std.mem.indexOf(u8, try panel.rateText(a, rate), unit) != null);
    try expect(std.mem.startsWith(u8, try panel.rateText(a, -1), "0"));
    const wifi = (try panel.nmWireless(a, "*:72\n:50")).?;
    try strings("network-wireless-signal-good-symbolic", wifi.icon);
    try strings("Wi-Fi: 72%", wifi.tooltip);
}
test "battery derives Adwaita levels and estimates instead of legacy icons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const battery = try panel.batteryInfo(a, "state: discharging\npercentage: 80%\ntime to empty: 2.5 hours\nicon-name: 'battery-full-charged-symbolic'\n");
    try strings("battery-level-80-symbolic", battery.icon);
    try strings("2∶30", battery.label);
    const cases = [_]struct { input: []const u8, icon: []const u8 }{
        .{ .input = "state: fully-charged\npercentage: 100%\n", .icon = "battery-level-100-charged-symbolic" },
        .{ .input = "state: charging\npercentage: 85%\n", .icon = "battery-level-80-charging-symbolic" },
        .{ .input = "state: charging\npercentage: 100%\n", .icon = "battery-level-100-charged-symbolic" },
        .{ .input = "state: discharging\npercentage: 87%\n", .icon = "battery-level-80-symbolic" },
        .{ .input = "state: pending-charge\npercentage: 80%\ncharge-threshold-enabled: yes\n", .icon = "battery-level-80-plugged-in-symbolic" },
    };
    for (cases) |case| try strings(case.icon, (try panel.batteryInfo(a, case.input)).icon);
    for ([_][]const u8{ "unknown", "nan", "inf", "" }) |value| try strings("battery-missing-symbolic", (try panel.batteryInfo(a, try u.fmt(a, "percentage: {s}\n", .{value}))).icon);
    try strings("", (try panel.batteryInfo(a, "state: fully-charged\npercentage: 100%\n")).label);
}
test "Codex keeps used and remaining modes and both popup windows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try u.parse(a, "{\"rate_limit\":{\"primary_window\":{\"used_percent\":46},\"secondary_window\":{\"used_percent\":7}}}");
    const remaining = try codex.formatUsage(a, data, true, true, 1000);
    try strings("54%", u.string(u.get(remaining, "text")));
    try expect(std.mem.indexOf(u8, u.string(u.get(remaining, "tooltip")), "7d: 93% remaining") != null);
    try equal(@as(?f64, 54), u.number(u.get(u.get(remaining, "windows").array.items[0], "percent")));
    try strings("Codex 5h 46% · 7d 7%", u.string(u.get(try codex.formatUsage(a, data, false, false, 1000), "text")));
    const missing = try codex.formatUsage(a, try u.parse(a, "{\"rate_limit\":{\"secondary_window\":{\"used_percent\":7}}}"), true, true, 1000);
    try strings("—", u.string(u.get(missing, "text")));
    try expect(u.get(u.get(missing, "windows").array.items[0], "percent") == .null);
    try equal(@as(?f64, 93), u.number(u.get(u.get(missing, "windows").array.items[1], "percent")));
    for ([_][]const u8{ "null", "true", "\"50\"", "{}" }) |value| {
        const invalid = try u.parse(a, try u.fmt(a, "{{\"rate_limit\":{{\"primary_window\":{{\"used_percent\":{s}}}}}}}", .{value}));
        try strings("unavailable", u.string(u.get(try codex.formatUsage(a, invalid, true, true, 1000), "class")));
    }
}
test "Codex reset countdown handles missing invalid and past timestamps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try strings("Resets in 2d 3h", try codex.resetText(a, u.num(1000 + 2 * 86400 + 3 * 3600), 1000));
    try strings("Resets in 2h 15m", try codex.resetText(a, u.num(1000 + 2 * 3600 + 15 * 60), 1000));
    try strings("Resets in now", try codex.resetText(a, u.num(900), 1000));
    for ([_]u.Value{ .null, .{ .bool = true }, u.str("1000"), u.num(std.math.nan(f64)), u.num(std.math.inf(f64)) }) |value| try strings("Resets: —", try codex.resetText(a, value, 1000));
}
test "running Codex stream refreshes immediately on SIGUSR1" {
    const binary = u.env("WB_PANEL_BINARY") orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = try u.environment(a);
    try env.put("WB_PANEL_DEMO", "1");
    var process = try std.process.spawn(u.io, .{ .argv = &.{ binary, "codex" }, .environ_map = &env, .stdout = .pipe });
    defer process.kill(u.io);
    var fd = u.libc.struct_pollfd{ .fd = process.stdout.?.handle, .events = u.libc.POLLIN, .revents = 0 };
    try expect(u.libc.poll(&fd, 1, 5000) > 0);
    var buffer: [65536]u8 = undefined;
    var reader = process.stdout.?.reader(u.io, &buffer);
    const first = try u.parse(a, (try reader.interface.takeDelimiter('\n')).?);
    try equal(@as(?f64, 54), u.number(u.get(u.get(first, "windows").array.items[0], "percent")));
    try std.posix.kill(process.id.?, std.posix.SIG.USR1);
    try expect(u.libc.poll(&fd, 1, 5000) > 0);
    const second = try u.parse(a, (try reader.interface.takeDelimiter('\n')).?);
    try equal(@as(?f64, 93), u.number(u.get(u.get(second, "windows").array.items[1], "percent")));
}
test "compact Codex CLI without login emits one placeholder" {
    const binary = u.env("WB_CODEX_BINARY") orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    var env = try u.environment(a);
    try env.put("CODEX_HOME", try directory.dir.realPathFileAlloc(std.testing.io, ".", a));
    const result = try std.process.run(a, u.io, .{ .environ_map = &env, .argv = &.{ binary, "--remaining", "--compact" } });
    try equal(std.process.Child.Term{ .exited = 0 }, result.term);
    try strings("—", u.string(u.get(try u.parse(a, result.stdout), "text")));
}

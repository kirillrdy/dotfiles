//! JSON streams for the native panel. Each update owns a bounded arena.
const std = @import("std");
const u = @import("desktop-util.zig");
const codex = @import("waybar-codex.zig");
const A = u.Allocator;
const V = u.Value;
const cpu_colors = [_][]const u8{ "#0072b3", "#0092e6", "#00a3ff", "#002f3d", "#001d26" };
const memory_colors = [_][]const u8{ "#00b35b", "#00ff82", "#aaf5d0" };
const network_colors = [_][]const u8{ "#fce94f", "#ff6e00", "#fb74fb", "#e0006e", "#ff0000" };

pub fn cpuCounters(contents: []const u8) [8]u64 {
    var words = std.mem.tokenizeAny(u8, contents[0 .. std.mem.indexOfScalar(u8, contents, '\n') orelse contents.len], " \t");
    _ = words.next();
    var result = @as([8]u64, @splat(0));
    for (&result) |*value| value.* = std.fmt.parseInt(u64, words.next() orelse "0", 10) catch 0;
    return result;
}
pub fn cpuUsage(previous: [8]u64, current: [8]u64) [5]f64 {
    var delta: [8]u64 = undefined;
    var total: f64 = 0;
    for (previous, current, &delta) |old, new, *d| {
        d.* = new -| old;
        total += @floatFromInt(d.*);
    }
    if (total == 0) return @as([5]f64, @splat(0));
    const values = [_]u64{ delta[0], delta[2], delta[1], delta[4], delta[5] + delta[6] + delta[7] };
    var result: [5]f64 = undefined;
    for (values, &result) |value, *out| out.* = @as(f64, @floatFromInt(value)) * 100 / total;
    return result;
}
pub const Memory = struct { values: [3]f64, used: f64, total: f64 };
fn field(contents: []const u8, key: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (u.eq(u.trim(line[0..colon]), key)) return u.trim(line[colon + 1 ..]);
    }
    return "";
}
fn integerField(contents: []const u8, key: []const u8) u64 {
    var words = std.mem.tokenizeAny(u8, field(contents, key), " \t");
    return std.fmt.parseInt(u64, words.next() orelse "0", 10) catch 0;
}
pub fn memoryUsage(contents: []const u8) Memory {
    const total = @max(1, integerField(contents, "MemTotal"));
    const cache = (integerField(contents, "Cached") + integerField(contents, "SReclaimable")) -| integerField(contents, "Shmem");
    const buffers = integerField(contents, "Buffers");
    const used = total -| (integerField(contents, "MemFree") + buffers + cache);
    var values: [3]f64 = undefined;
    for ([_]u64{ used, buffers, cache }, &values) |value, *out| out.* = @as(f64, @floatFromInt(value)) * 100 / @as(f64, @floatFromInt(total));
    return .{ .values = values, .used = @as(f64, @floatFromInt(used)) / 1048576, .total = @as(f64, @floatFromInt(total)) / 1048576 };
}
fn networkCounters(a: A) ![2]u64 {
    var result = @as([2]u64, @splat(0));
    var lines = std.mem.splitScalar(u8, try u.read(a, "/proc/net/dev"), '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!u.exists(try u.fmt(a, "/sys/class/net/{s}/device", .{u.trim(line[0..colon])}))) continue;
        var words = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        var i: usize = 0;
        while (words.next()) |word| : (i += 1) {
            if (i == 0 or i == 8) result[if (i == 0) @as(usize, 0) else 1] += std.fmt.parseInt(u64, word, 10) catch 0;
        }
    }
    return result;
}
// Three significant digits, matching the compact GNOME graph labels.
pub fn shortNumber(a: A, value: f64) ![]const u8 {
    var buffer: [64]u8 = undefined;
    const len = u.libc.snprintf(&buffer, buffer.len, "%.3g", value);
    if (len < 0 or len >= buffer.len) return error.InvalidNumber;
    return a.dupe(u8, buffer[0..@intCast(len)]);
}
pub fn rateText(a: A, rate: f64) ![]const u8 {
    var value = @max(0, rate) / 1024;
    var unit: []const u8 = "KiB/s";
    if (value >= 1024) {
        value /= 1024;
        unit = "MiB/s";
    }
    if (value >= 1024) {
        value /= 1024;
        unit = "GiB/s";
    }
    return u.fmt(a, "{s}<span size=\"62.5%\" alpha=\"65%\"> {s}</span>", .{ try shortNumber(a, value), unit });
}
fn graph(a: A, values: []const f64, colors: []const []const u8, sequence: u64, markup: []const u8, tooltip: []const u8, maximum: f64) !V {
    var out = u.object();
    var series = u.array(a);
    var palette = u.array(a);
    for (values) |v| try series.array.append(u.num(v));
    for (colors) |color| try palette.array.append(u.str(color));
    try u.put(a, &out, "values", series);
    try u.put(a, &out, "colors", palette);
    try u.put(a, &out, "sequence", .{ .integer = @intCast(sequence) });
    try u.put(a, &out, "markup", u.str(markup));
    try u.put(a, &out, "tooltip", u.str(tooltip));
    try u.put(a, &out, "maximum", u.num(maximum));
    return out;
}
fn monitorStream(demo: bool) !void {
    var initial = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var previous_cpu = cpuCounters(try u.read(initial.allocator(), "/proc/stat"));
    var previous_net = try networkCounters(initial.allocator());
    initial.deinit();
    const timer = u.Timer.start();
    var last = @as([3]f64, @splat(-10));
    var sequences = @as([3]u64, @splat(0));
    var cpu = @as([5]f64, @splat(0));
    var memory = Memory{ .values = .{ 0, 0, 0 }, .used = 0, .total = 0 };
    var down: f64 = 0;
    var up: f64 = 0;
    var tick: f64 = 0;
    while (true) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const now = @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_s;
        if (demo or now - last[0] >= 1.5) {
            const current = cpuCounters(try u.read(a, "/proc/stat"));
            cpu = if (demo) .{ 12 + 8 * @sin(tick / 9), 5, 0, 1, 0 } else cpuUsage(previous_cpu, current);
            previous_cpu = current;
            last[0] = now;
            sequences[0] += 1;
        }
        if (demo or now - last[1] >= 5) {
            memory = if (demo) .{ .values = .{ 24 + 2 * @sin(tick / 18), 1, 32 }, .used = 7.65, .total = 31 } else memoryUsage(try u.read(a, "/proc/meminfo"));
            last[1] = now;
            sequences[1] += 1;
        }
        if (demo or now - last[2] >= 1) {
            const current = try networkCounters(a);
            const elapsed = @max(0.001, now - @max(0, last[2]));
            down = if (demo) 12000 + 8000 * @sin(tick / 8) else @as(f64, @floatFromInt(current[0] -| previous_net[0])) / elapsed;
            up = if (demo) 3000 + 1500 * @sin(tick / 5) else @as(f64, @floatFromInt(current[1] -| previous_net[1])) / elapsed;
            previous_net = current;
            last[2] = now;
            sequences[2] += 1;
        }
        const percent = @round(cpu[0] + cpu[1] + cpu[2] + cpu[3] + cpu[4]);
        var graphs = u.array(a);
        try graphs.array.append(try graph(a, &cpu, &cpu_colors, sequences[0], try u.fmt(a, "{d:.0}<span size=\"62.5%\" alpha=\"65%\">%</span>", .{percent}), try u.fmt(a, "CPU: {d:.0}%", .{percent}), 100));
        try graphs.array.append(try graph(a, &memory.values, &memory_colors, sequences[1], try u.fmt(a, "{s} / {s}<span size=\"62.5%\" alpha=\"65%\"> GiB</span>", .{ try shortNumber(a, memory.used), try shortNumber(a, memory.total) }), try u.fmt(a, "Memory: {d:.0}% programs, {d:.0}% buffers, {d:.0}% cache", .{ memory.values[0], memory.values[1], memory.values[2] }), 100));
        try graphs.array.append(try graph(a, &.{ down, 0, up, 0, 0 }, &network_colors, sequences[2], try u.fmt(a, "{s}\n{s}", .{ try rateText(a, down), try rateText(a, up) }), try u.fmt(a, "Download: {d:.1} KiB/s\nUpload: {d:.1} KiB/s", .{ down / 1024, up / 1024 }), 0));
        var out = u.object();
        try u.put(a, &out, "monitors", graphs);
        try u.emit(a, out);
        tick += 1;
        u.sleep(if (demo) 20 * std.time.ns_per_ms else 500 * std.time.ns_per_ms);
    }
}
pub const Status = struct { icon: []const u8, label: []const u8 = "", tooltip: []const u8 };
fn wirelessStrength(a: A, quality: f64) !Status {
    const level = if (quality >= 0.8) "excellent" else if (quality >= 0.55) "good" else if (quality >= 0.3) "ok" else "weak";
    return .{ .icon = try u.fmt(a, "network-wireless-signal-{s}-symbolic", .{level}), .tooltip = try u.fmt(a, "Wi-Fi: {d:.0}%", .{@min(100, quality * 100)}) };
}
pub fn nmWireless(a: A, output: []const u8) !?Status {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "*:")) {
        const strength = std.fmt.parseFloat(f64, line[2..]) catch continue;
        if (std.math.isFinite(strength)) return try wirelessStrength(a, strength / 100);
    };
    return null;
}
fn wirelessIcon(a: A) !Status {
    if (try nmWireless(a, u.command(a, &.{ "nmcli", "-t", "-f", "IN-USE,SIGNAL", "device", "wifi", "list", "--rescan", "no" }, 4))) |status| return status;
    const contents = u.read(a, "/proc/net/wireless") catch "";
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const state = u.read(a, try u.fmt(a, "/sys/class/net/{s}/operstate", .{u.trim(line[0..colon])})) catch continue;
        if (!u.eq(u.trim(state), "up")) continue;
        var words = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        _ = words.next();
        const quality = std.fmt.parseFloat(f64, words.next() orelse continue) catch continue;
        if (std.math.isFinite(quality)) return wirelessStrength(a, quality / 70);
    }
    var dir = std.Io.Dir.openDirAbsolute(u.io, "/sys/class/net", .{ .iterate = true }) catch return .{ .icon = "network-wireless-offline-symbolic", .tooltip = "Network disconnected" };
    defer dir.close(u.io);
    var entries = dir.iterate();
    while (try entries.next(u.io)) |entry| {
        const base = try u.fmt(a, "/sys/class/net/{s}", .{entry.name});
        if (!u.exists(try u.fmt(a, "{s}/device", .{base}))) continue;
        const state = u.read(a, try u.fmt(a, "{s}/operstate", .{base})) catch continue;
        if (!u.eq(u.trim(state), "up")) continue;
        if (u.exists(try u.fmt(a, "{s}/wireless", .{base})) or u.exists(try u.fmt(a, "{s}/phy80211", .{base}))) return .{ .icon = "network-wireless-connected-symbolic", .tooltip = "Wi-Fi connected" };
        return .{ .icon = "network-wired-symbolic", .tooltip = "Wired network" };
    }
    return .{ .icon = "network-wireless-offline-symbolic", .tooltip = "Network disconnected" };
}
pub fn batteryInfo(a: A, contents: []const u8) !Status {
    const percent = field(contents, "percentage");
    const state = field(contents, "state");
    var icon: []const u8 = "battery-missing-symbolic";
    const percentage = std.fmt.parseFloat(f64, std.mem.trimEnd(u8, percent, "%")) catch std.math.nan(f64);
    if (std.math.isFinite(percentage)) {
        const level: u32 = @as(u32, @intFromFloat(std.math.clamp(percentage, 0, 100))) / 10 * 10;
        if (u.eq(state, "fully-charged") or (u.eq(state, "charging") and level == 100)) icon = "battery-level-100-charged-symbolic" else {
            const suffix = if (u.eq(state, "charging")) "-charging" else if (u.eq(state, "pending-charge") and u.eq(field(contents, "charge-threshold-enabled"), "yes")) "-plugged-in" else "";
            icon = try u.fmt(a, "battery-level-{d}{s}-symbolic", .{ level, suffix });
        }
    }
    var duration = field(contents, "time to empty");
    if (duration.len == 0) duration = field(contents, "time to full");
    var label: []const u8 = "";
    var words = std.mem.tokenizeAny(u8, duration, " \t");
    const amount = std.fmt.parseFloat(f64, words.next() orelse "") catch std.math.nan(f64);
    const unit = words.next() orelse "";
    if (std.math.isFinite(amount) and amount >= 0 and amount < 1e9 and (std.mem.startsWith(u8, unit, "hour") or std.mem.startsWith(u8, unit, "minute"))) {
        const minutes: u64 = @intFromFloat(@round(amount * @as(f64, if (std.mem.startsWith(u8, unit, "hour")) 60 else 1)));
        label = try u.fmt(a, "{d}∶{d:0>2}", .{ minutes / 60, minutes % 60 });
    }
    return .{ .icon = icon, .label = label, .tooltip = try u.fmt(a, "Battery: {s} · {s}", .{ if (percent.len > 0) percent else "—", if (state.len > 0) state else "unknown" }) };
}
fn item(a: A, icon: []const u8, label: []const u8, tooltip: []const u8, cmd: []const u8) !V {
    var out = u.object();
    try u.put(a, &out, "icon", u.str(icon));
    try u.put(a, &out, "text", u.str(label));
    try u.put(a, &out, "tooltip", u.str(tooltip));
    try u.put(a, &out, "command", u.str(cmd));
    return out;
}
fn bluetoothPowered(a: A) !bool {
    var dir = std.Io.Dir.openDirAbsolute(u.io, "/sys/class/rfkill", .{ .iterate = true }) catch return false;
    defer dir.close(u.io);
    var entries = dir.iterate();
    while (try entries.next(u.io)) |entry| {
        const kind = u.read(a, try u.fmt(a, "/sys/class/rfkill/{s}/type", .{entry.name})) catch continue;
        const state = u.read(a, try u.fmt(a, "/sys/class/rfkill/{s}/state", .{entry.name})) catch continue;
        if (u.eq(u.trim(kind), "bluetooth") and u.eq(u.trim(state), "1")) return true;
    }
    return false;
}
fn statusItems(a: A, demo: bool) !V {
    var items = u.array(a);
    if (demo) {
        try items.array.append(try item(a, "network-wireless-signal-excellent-symbolic", "", "Wi-Fi", ""));
        try items.array.append(try item(a, "bluetooth-active-symbolic", "", "Bluetooth · Quick Settings", ""));
        try items.array.append(try item(a, "audio-volume-high-symbolic", "", "Volume", ""));
        try items.array.append(try item(a, "battery-level-80-symbolic", "5∶42", "Battery", ""));
        return items;
    }
    const wireless = try wirelessIcon(a);
    try items.array.append(try item(a, wireless.icon, "", wireless.tooltip, "ghostty -e nmtui"));
    if (try bluetoothPowered(a)) try items.array.append(try item(a, "bluetooth-active-symbolic", "", "Bluetooth · Quick Settings", ""));
    const volume = u.command(a, &.{ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" }, 4);
    var words = std.mem.tokenizeAny(u8, volume, " \t");
    _ = words.next();
    const amount = std.fmt.parseFloat(f64, words.next() orelse "") catch std.math.nan(f64);
    const percentage = if (std.math.isFinite(amount)) amount * 100 else 0;
    const level = if (std.mem.indexOf(u8, volume, "MUTED") != null or !std.math.isFinite(amount)) "muted" else if (percentage >= 66) "high" else if (percentage >= 33) "medium" else "low";
    try items.array.append(try item(a, try u.fmt(a, "audio-volume-{s}-symbolic", .{level}), "", try u.fmt(a, "Volume: {d:.0}%", .{percentage}), "pavucontrol"));
    const contents = u.command(a, &.{ "upower", "-i", "/org/freedesktop/UPower/devices/DisplayDevice" }, 4);
    if (u.eq(field(contents, "is-present"), "yes") or field(contents, "percentage").len > 0) {
        const battery = try batteryInfo(a, contents);
        try items.array.append(try item(a, battery.icon, battery.label, try u.fmt(a, "{s} · Quick Settings", .{battery.tooltip}), ""));
    }
    return items;
}
var wake_pipe: [2]std.posix.fd_t = .{ -1, -1 };
fn refreshSignal(_: std.posix.SIG) callconv(.c) void {
    const saved_errno = u.libc.__errno_location().*;
    defer u.libc.__errno_location().* = saved_errno;
    _ = u.libc.write(wake_pipe[1], "r", 1);
}
fn waitRefresh(milliseconds: c_int) void {
    var fd = u.libc.struct_pollfd{ .fd = wake_pipe[0], .events = u.libc.POLLIN, .revents = 0 };
    _ = u.libc.poll(&fd, 1, milliseconds);
    var buf: [128]u8 = undefined;
    while (u.libc.read(wake_pipe[0], &buf, buf.len) > 0) {}
}
pub fn main(init: std.process.Init) !void {
    u.io = init.io;
    run(init.minimal.args) catch |err| if (err != error.WriteFailed) return err;
}
fn run(args_source: std.process.Args) !void {
    var startup = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer startup.deinit();
    const args = try args_source.toSlice(startup.allocator());
    if (args.len < 2) return error.MissingKind;
    const kind = args[1];
    if (!u.eq(kind, "monitors") and !u.eq(kind, "codex") and !u.eq(kind, "status") and !u.eq(kind, "disk")) return error.InvalidKind;
    var icon: []const u8 = "";
    var codex_command: ?[]const u8 = null;
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.MissingValue;
        if (u.eq(args[i], "--codex-icon")) icon = args[i + 1] else if (u.eq(args[i], "--codex-command")) codex_command = args[i + 1] else return error.InvalidArgument;
    }
    const demo = u.eq(u.env("WB_PANEL_DEMO") orelse "", "1");
    if (u.eq(kind, "monitors")) return monitorStream(demo);
    if (u.libc.pipe2(&wake_pipe, u.libc.O_NONBLOCK | u.libc.O_CLOEXEC) != 0) return error.PipeFailed;
    defer {
        _ = u.libc.close(wake_pipe[0]);
        _ = u.libc.close(wake_pipe[1]);
    }
    if (u.eq(kind, "codex")) std.posix.sigaction(std.posix.SIG.USR1, &.{ .handler = .{ .handler = refreshSignal }, .mask = std.posix.sigemptyset(), .flags = 0 }, null);
    while (true) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var out = u.object();
        if (u.eq(kind, "status")) try u.put(a, &out, "items", try statusItems(a, demo)) else if (u.eq(kind, "disk")) {
            const output = u.command(a, &.{ "df", "-h", "/" }, 4);
            var rows = std.mem.splitScalar(u8, output, '\n');
            _ = rows.next();
            var words = std.mem.tokenizeAny(u8, rows.next() orelse "", " \t");
            _ = words.next();
            const total = words.next() orelse "—";
            const used = words.next() orelse "—";
            var items = u.array(a);
            try items.array.append(try item(a, "", try u.fmt(a, "{s}/{s}", .{ used, total }), "Root filesystem usage", "ghostty -e ncdu /"));
            try u.put(a, &out, "items", items);
        } else {
            const result = if (demo) try u.parse(a, "{\"text\":\"54%\",\"tooltip\":\"5h: 54% remaining\\n7d: 93% remaining\",\"windows\":[{\"percent\":54,\"reset\":\"Resets in 2h 15m\"},{\"percent\":93,\"reset\":\"Resets in 4d 8h\"}]}") else if (codex_command) |cmd| u.parse(a, u.command(a, &.{ cmd, "--remaining", "--compact" }, 12)) catch try codex.unavailable(a, "Codex usage unavailable", true) else try codex.readUsage(a, true, true);
            var items = u.array(a);
            try items.array.append(try item(a, icon, u.string(u.get(result, "text")), "", ""));
            try u.put(a, &out, "items", items);
            try u.put(a, &out, "tooltip", u.get(result, "tooltip"));
            const windows = u.get(result, "windows");
            try u.put(a, &out, "windows", if (windows == .array) windows else u.array(a));
            try u.put(a, &out, "error", u.str(if (windows == .array and windows.array.items.len > 0) "" else u.string(u.get(result, "tooltip"))));
            try u.put(a, &out, "checked", if (demo) u.str(try u.localTime(a, u.timestamp(), "Checked: %H:%M:%S")) else if (u.get(result, "checked") == .string) u.get(result, "checked") else u.str("Checked: —"));
        }
        try u.emit(a, out);
        waitRefresh(if (u.eq(kind, "codex")) 60000 else 5000);
    }
}

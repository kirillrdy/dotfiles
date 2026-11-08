//! Typed panel updates. Each worker result owns a bounded arena.
const std = @import("std");
const network = @import("desktop-network.zig");
const u = @import("desktop-util.zig");
const audio = @import("desktop-audio.zig");
const battery = @import("desktop-battery.zig");
const codex = @import("desktop-codex.zig");
const A = u.Allocator;
pub const Item = struct {
    icon: []const u8 = "",
    text: []const u8 = "",
    tooltip: []const u8 = "",
    command: []const u8 = "",
};
pub const Graph = struct {
    values: []const f64,
    colors: []const [:0]const u8 = &.{},
    sequence: i64,
    markup: []const u8 = "",
    tooltip: []const u8 = "",
    maximum: f64 = 0,
};
pub const Window = struct { percent: ?f64 = null, reset: []const u8 = "Resets: —" };
pub const Update = struct {
    items: ?[]const Item = null,
    monitors: ?[]const Graph = null,
    windows: []const Window = &.{},
    tooltip: []const u8 = "",
    checked: []const u8 = "Checked: —",
    @"error": []const u8 = "",
};
const cpu_colors = [_][:0]const u8{ "#0072b3", "#0092e6", "#00a3ff", "#002f3d", "#001d26" };
const memory_colors = [_][:0]const u8{ "#00b35b", "#00ff82", "#aaf5d0" };
const network_colors = [_][:0]const u8{ "#fce94f", "#ff6e00", "#fb74fb", "#e0006e", "#ff0000" };

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
pub const Monitor = struct {
    previous_cpu: [8]u64,
    previous_net: [2]u64,
    timer: u.Timer,
    last: [3]f64 = @splat(-10),
    sequences: [3]u64 = @splat(0),
    cpu: [5]f64 = @splat(0),
    memory: Memory = .{ .values = .{ 0, 0, 0 }, .used = 0, .total = 0 },
    down: f64 = 0,
    up: f64 = 0,
    tick: f64 = 0,

    pub fn init(a: A) !Monitor {
        return .{ .previous_cpu = cpuCounters(try u.read(a, "/proc/stat")), .previous_net = try networkCounters(a), .timer = u.Timer.start() };
    }

    pub fn sample(self: *Monitor, a: A, demo: bool) !Update {
        const now = @as(f64, @floatFromInt(self.timer.read())) / std.time.ns_per_s;
        if (demo or now - self.last[0] >= 1.5) {
            const current = cpuCounters(try u.read(a, "/proc/stat"));
            self.cpu = if (demo) .{ 12 + 8 * @sin(self.tick / 9), 5, 0, 1, 0 } else cpuUsage(self.previous_cpu, current);
            self.previous_cpu = current;
            self.last[0] = now;
            self.sequences[0] += 1;
        }
        if (demo or now - self.last[1] >= 5) {
            self.memory = if (demo) .{ .values = .{ 24 + 2 * @sin(self.tick / 18), 1, 32 }, .used = 7.65, .total = 31 } else memoryUsage(try u.read(a, "/proc/meminfo"));
            self.last[1] = now;
            self.sequences[1] += 1;
        }
        if (demo or now - self.last[2] >= 1) {
            const current = try networkCounters(a);
            const elapsed = @max(0.001, now - @max(0, self.last[2]));
            self.down = if (demo) 12000 + 8000 * @sin(self.tick / 8) else @as(f64, @floatFromInt(current[0] -| self.previous_net[0])) / elapsed;
            self.up = if (demo) 3000 + 1500 * @sin(self.tick / 5) else @as(f64, @floatFromInt(current[1] -| self.previous_net[1])) / elapsed;
            self.previous_net = current;
            self.last[2] = now;
            self.sequences[2] += 1;
        }
        const percent = @round(self.cpu[0] + self.cpu[1] + self.cpu[2] + self.cpu[3] + self.cpu[4]);
        const graphs = try a.alloc(Graph, 3);
        graphs[0] = .{ .values = try a.dupe(f64, &self.cpu), .colors = &cpu_colors, .sequence = @intCast(self.sequences[0]), .markup = try u.fmt(a, "{d:.0}<span size=\"62.5%\" alpha=\"65%\">%</span>", .{percent}), .tooltip = try u.fmt(a, "CPU: {d:.0}%", .{percent}), .maximum = 100 };
        graphs[1] = .{ .values = try a.dupe(f64, &self.memory.values), .colors = &memory_colors, .sequence = @intCast(self.sequences[1]), .markup = try u.fmt(a, "{s} / {s}<span size=\"62.5%\" alpha=\"65%\"> GiB</span>", .{ try shortNumber(a, self.memory.used), try shortNumber(a, self.memory.total) }), .tooltip = try u.fmt(a, "Memory: {d:.0}% programs, {d:.0}% buffers, {d:.0}% cache", .{ self.memory.values[0], self.memory.values[1], self.memory.values[2] }), .maximum = 100 };
        graphs[2] = .{ .values = try a.dupe(f64, &.{ self.down, 0, self.up, 0, 0 }), .colors = &network_colors, .sequence = @intCast(self.sequences[2]), .markup = try u.fmt(a, "{s}\n{s}", .{ try rateText(a, self.down), try rateText(a, self.up) }), .tooltip = try u.fmt(a, "Download: {d:.1} KiB/s\nUpload: {d:.1} KiB/s", .{ self.down / 1024, self.up / 1024 }) };
        self.tick += 1;
        return .{ .monitors = graphs };
    }
};
pub const Status = struct { icon: []const u8, label: []const u8 = "", tooltip: []const u8 };
fn append(a: A, out: *Update, value: Item) !void {
    const old = out.items orelse return;
    const items = try a.alloc(Item, old.len + 1);
    @memcpy(items[0..old.len], old);
    items[old.len] = value;
    out.items = items;
}
pub fn addNetwork(a: A, out: *Update, state: *const network.State) !void {
    const info = state.indicator();
    try append(a, out, .{ .icon = info.icon, .tooltip = info.title, .command = "desktop-zig settings network" });
}
pub fn batteryInfo(a: A, state: battery.State) !Status {
    var icon_buffer: [100]u8 = undefined;
    var time_buffer: [80]u8 = undefined;
    return .{ .icon = try a.dupe(u8, try state.icon(&icon_buffer)), .label = try a.dupe(u8, try state.duration(&time_buffer)), .tooltip = try u.fmt(a, "Battery: {d:.0}% · {s}", .{ state.percent, state.description() }) };
}
pub fn addBattery(a: A, out: *Update, state: battery.State) !void {
    if (!state.visible()) return;
    const info = try batteryInfo(a, state);
    try append(a, out, .{ .icon = info.icon, .text = info.label, .tooltip = try u.fmt(a, "{s} · Quick Settings", .{info.tooltip}) });
}
pub fn addAudio(a: A, out: *Update, output: ?audio.State, input: ?audio.State) !void {
    if (output) |state| {
        const level = if (state.muted or state.percent == 0) "muted" else if (state.percent >= 66) "high" else if (state.percent >= 33) "medium" else "low";
        try append(a, out, .{ .icon = try u.fmt(a, "audio-volume-{s}-symbolic", .{level}), .tooltip = try u.fmt(a, "Volume: {d:.0}%", .{state.percent}), .command = "desktop-zig settings sound" });
    }
    if (input) |state| if (state.muted) {
        try append(a, out, .{ .icon = "microphone-sensitivity-muted-symbolic", .tooltip = "Microphone muted" });
    };
}
fn diskSize(a: A, bytes: u128) ![]const u8 {
    var size: f64 = @floatFromInt(bytes);
    const units = "BKMGTPEZY";
    var unit: usize = 0;
    while (size >= 1024 and unit + 1 < units.len) : (unit += 1) size /= 1024;
    if (unit > 0 and size < 10) return u.fmt(a, "{d:.1}{c}", .{ @ceil(size * 10) / 10, units[unit] });
    return u.fmt(a, "{d:.0}{c}", .{ @ceil(size), units[unit] });
}

pub fn diskUsageText(a: A, stats: u.libc.struct_statvfs) ![]const u8 {
    // f_bfree includes reserved blocks; f_bavail would count them as used.
    const block_size: u128 = stats.f_frsize;
    const total = @as(u128, stats.f_blocks) * block_size;
    const used = @as(u128, stats.f_blocks -| stats.f_bfree) * block_size;
    return u.fmt(a, "{s}/{s}", .{ try diskSize(a, used), try diskSize(a, total) });
}

/// One bounded update, suitable for a shared session worker.
pub fn sample(a: A, kind: []const u8, icon: []const u8, demo: bool) !Update {
    if (u.eq(kind, "status")) return .{ .items = if (demo) &.{
        .{ .icon = "network-wireless-signal-excellent-symbolic", .tooltip = "Wi-Fi" },
        .{ .icon = "audio-volume-high-symbolic", .tooltip = "Volume" },
        .{ .icon = "battery-level-80-symbolic", .text = "5∶42", .tooltip = "Battery" },
    } else &.{} };
    const items = try a.alloc(Item, 1);
    if (u.eq(kind, "disk")) {
        var stats: u.libc.struct_statvfs = undefined;
        items[0] = .{ .text = if (u.libc.statvfs("/", &stats) == 0) try diskUsageText(a, stats) else "—/—", .tooltip = "Root filesystem usage", .command = "ghostty -e ncdu /" };
        return .{ .items = items };
    }
    // Decode the external API once; the session transports typed data throughout.
    const result = if (demo) try u.parse(a, "{\"text\":\"54%\",\"tooltip\":\"5h: 54% remaining\\n7d: 93% remaining\",\"windows\":[{\"percent\":54,\"reset\":\"Resets in 2h 15m\"},{\"percent\":93,\"reset\":\"Resets in 4d 8h\"}]}") else try codex.readUsage(a, true, true);
    items[0] = .{ .icon = icon, .text = u.string(u.get(result, "text")) };
    const raw_windows = u.get(result, "windows");
    const windows = try a.alloc(Window, if (raw_windows == .array) raw_windows.array.items.len else 0);
    for (windows, 0..) |*window, i| {
        const value = raw_windows.array.items[i];
        window.* = .{ .percent = u.number(u.get(value, "percent")), .reset = u.string(u.get(value, "reset")) };
    }
    return .{
        .items = items,
        .tooltip = u.string(u.get(result, "tooltip")),
        .windows = windows,
        .@"error" = if (windows.len > 0) "" else u.string(u.get(result, "tooltip")),
        .checked = if (demo) try u.localTime(a, u.timestamp(), "Checked: %H:%M:%S") else if (u.get(result, "checked") == .string) u.string(u.get(result, "checked")) else "Checked: —",
    };
}

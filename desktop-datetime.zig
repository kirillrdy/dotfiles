//! Local wall-clock dates and times, in Zig: the system time zone database
//! (TZif via std.tz, plus its POSIX TZ footer rule), proleptic Gregorian
//! calendar arithmetic, and strftime-style formatting with English names.
//!
//! A DateTime is a plain local calendar value. Day and month arithmetic keeps
//! the wall-clock time; only conversion from an instant consults the zone.
const std = @import("std");
const linux = std.os.linux;

const seconds_per_day = std.time.s_per_day;

pub const DateTime = struct {
    /// Days since 1970-01-01 in local time.
    days: i64,
    /// Seconds since local midnight.
    second: u32 = 0,
    microsecond: u32 = 0,

    pub fn now() !DateTime {
        var clock: linux.timespec = undefined;
        if (linux.errno(linux.clock_gettime(.REALTIME, &clock)) != .SUCCESS) return error.DateUnavailable;
        var value = try fromUnix(clock.sec);
        value.microsecond = @intCast(@divTrunc(clock.nsec, std.time.ns_per_us));
        return value;
    }

    pub fn fromUnix(seconds: i64) !DateTime {
        const wall = std.math.add(i64, seconds, localZone().offsetAt(seconds)) catch return error.DateUnavailable;
        return .{ .days = @divFloor(wall, seconds_per_day), .second = @intCast(@mod(wall, seconds_per_day)) };
    }

    /// A local time from calendar fields; month is 1 to 12.
    pub fn local(year_value: i32, month_value: i32, day_value: i32, h: i32, m: i32, s: i32) !DateTime {
        if (month_value < 1 or month_value > 12 or day_value < 1 or day_value > daysInMonth(year_value, month_value)) return error.DateUnavailable;
        if (h < 0 or h > 23 or m < 0 or m > 59 or s < 0 or s > 59) return error.DateUnavailable;
        return .{ .days = daysFromCivil(year_value, month_value, day_value), .second = @intCast(h * 3600 + m * 60 + s) };
    }

    pub fn addDays(self: DateTime, days: i32) !DateTime {
        var value = self;
        value.days = std.math.add(i64, self.days, days) catch return error.DateUnavailable;
        return value;
    }

    /// Moves by whole months, clamping the day to the target month's length.
    pub fn addMonths(self: DateTime, months: i32) !DateTime {
        const date = civilFromDays(self.days);
        const total = @as(i64, date.year) * 12 + (date.month - 1) + months;
        const year_value = std.math.cast(i32, @divFloor(total, 12)) orelse return error.DateUnavailable;
        const month_value: i32 = @intCast(@mod(total, 12) + 1);
        var value = self;
        value.days = daysFromCivil(year_value, month_value, @min(date.day, daysInMonth(year_value, month_value)));
        return value;
    }

    pub fn year(self: DateTime) i32 {
        return civilFromDays(self.days).year;
    }

    /// 1 (January) to 12.
    pub fn month(self: DateTime) i32 {
        return civilFromDays(self.days).month;
    }

    pub fn day(self: DateTime) i32 {
        return civilFromDays(self.days).day;
    }

    /// ISO weekday: 1 (Monday) to 7 (Sunday). 1970-01-01 was a Thursday.
    pub fn dayOfWeek(self: DateTime) i32 {
        return @intCast(@mod(self.days + 3, 7) + 1);
    }

    /// 1 to 366.
    pub fn dayOfYear(self: DateTime) i32 {
        return @intCast(self.days - daysFromCivil(self.year(), 1, 1) + 1);
    }

    pub fn hour(self: DateTime) u32 {
        return self.second / 3600;
    }

    pub fn minute(self: DateTime) u32 {
        return self.second / 60 % 60;
    }

    pub fn sameDay(self: DateTime, other: DateTime) bool {
        return self.days == other.days;
    }

    /// strftime-style formatting into `buffer`, NUL-terminated.
    /// Supports %a %A %b %B %d %e %f %H %I %j %m %M %p %S %y %Y %%, and a `-`
    /// flag that drops padding. Fails when the result does not fit.
    pub fn format(self: DateTime, buffer: []u8, pattern: []const u8) ![:0]u8 {
        if (buffer.len == 0) return error.DateFormatFailed;
        var writer: std.Io.Writer = .fixed(buffer[0 .. buffer.len - 1]);
        self.write(&writer, pattern) catch return error.DateFormatFailed;
        const len = writer.end;
        buffer[len] = 0;
        return buffer[0..len :0];
    }

    fn write(self: DateTime, writer: *std.Io.Writer, pattern: []const u8) !void {
        const date = civilFromDays(self.days);
        var i: usize = 0;
        while (i < pattern.len) : (i += 1) {
            if (pattern[i] != '%') {
                try writer.writeByte(pattern[i]);
                continue;
            }
            i += 1;
            const pad = !(i < pattern.len and pattern[i] == '-');
            if (!pad) i += 1;
            if (i >= pattern.len) return error.InvalidFormat;
            const hour12 = (self.hour() + 11) % 12 + 1;
            switch (pattern[i]) {
                'a' => try writer.writeAll(weekday_names[@intCast(@mod(self.days + 4, 7))][0..3]),
                'A' => try writer.writeAll(weekday_names[@intCast(@mod(self.days + 4, 7))]),
                'b' => try writer.writeAll(month_names[@intCast(date.month - 1)][0..3]),
                'B' => try writer.writeAll(month_names[@intCast(date.month - 1)]),
                'd' => try number(writer, date.day, if (pad) '0' else null, 2),
                'e' => try number(writer, date.day, if (pad) ' ' else null, 2),
                'f' => try number(writer, self.microsecond, '0', 6),
                'H' => try number(writer, self.hour(), if (pad) '0' else null, 2),
                'I' => try number(writer, hour12, if (pad) '0' else null, 2),
                'j' => try number(writer, self.dayOfYear(), if (pad) '0' else null, 3),
                'm' => try number(writer, date.month, if (pad) '0' else null, 2),
                'M' => try number(writer, self.minute(), if (pad) '0' else null, 2),
                'p' => try writer.writeAll(if (self.hour() < 12) "AM" else "PM"),
                'S' => try number(writer, self.second % 60, if (pad) '0' else null, 2),
                'y' => try number(writer, @mod(date.year, 100), if (pad) '0' else null, 2),
                'Y' => try writer.print("{d}", .{date.year}),
                '%' => try writer.writeByte('%'),
                else => return error.InvalidFormat,
            }
        }
    }
};

const weekday_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

fn number(writer: *std.Io.Writer, value: anytype, fill: ?u8, width: usize) !void {
    const v: i64 = @intCast(value);
    var digits: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&digits, "{d}", .{v}) catch unreachable;
    if (fill) |byte| if (text.len < width) try writer.splatByteAll(byte, width - text.len);
    try writer.writeAll(text);
}

pub fn isLeapYear(year: i32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

pub fn daysInMonth(year: i32, month: i32) i32 {
    return switch (month) {
        2 => if (isLeapYear(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

pub const Civil = struct { year: i32, month: i32, day: i32 };

/// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's algorithm).
pub fn daysFromCivil(year: i32, month: i32, day: i32) i64 {
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (month > 2) month - 3 else month + 9;
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day: i32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const month: i32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const year: i32 = @intCast(yoe + era * 400 + @intFromBool(month <= 2));
    return .{ .year = year, .month = month, .day = day };
}

/// A POSIX TZ rule such as "AEST-10AEDT,M10.1.0,M4.1.0/3". Offsets are seconds east of UTC.
pub const Rule = struct {
    std_offset: i32,
    dst: ?Dst = null,

    const Dst = struct { offset: i32, start: Change, end: Change };
    const Change = struct {
        date: union(enum) {
            /// Jn: 1 to 365, February 29 never counted.
            julian: u16,
            /// n: 0 to 365, counting February 29.
            ordinal: u16,
            /// Mm.w.d: weekday d (0 = Sunday) of week w (5 = last) of month m.
            weekday: struct { month: u8, week: u8, weekday: u8 },
        },
        /// Seconds after local midnight; may be negative or past a day.
        time: i32 = 2 * 3600,

        /// Days since the epoch on which the change happens in `year`.
        fn day(self: Change, year: i32) i64 {
            const jan1 = daysFromCivil(year, 1, 1);
            switch (self.date) {
                .julian => |n| return jan1 + n - 1 + @intFromBool(isLeapYear(year) and n >= 60),
                .ordinal => |n| return jan1 + n,
                .weekday => |w| {
                    const first = daysFromCivil(year, w.month, 1);
                    const first_weekday = @mod(first + 4, 7);
                    var result = first + @mod(@as(i64, w.weekday) - first_weekday, 7) + (@as(i64, w.week) - 1) * 7;
                    const last = first + daysInMonth(year, w.month) - 1;
                    while (result > last) result -= 7;
                    return result;
                },
            }
        }

        /// The UTC instant of the change in `year`, given the offset in effect before it.
        fn instant(self: Change, year: i32, offset_before: i32) i64 {
            return self.day(year) * seconds_per_day + self.time - offset_before;
        }
    };

    pub fn parse(text: []const u8) !Rule {
        var parser: Parser = .{ .text = text };
        try parser.name();
        const std_offset = -try parser.time(false);
        if (parser.done()) return .{ .std_offset = std_offset };
        try parser.name();
        const dst_offset = if (!parser.done() and parser.peek() != ',') -try parser.time(false) else std_offset + 3600;
        // Without explicit rules, glibc and musl apply the US rules.
        var start: Change = .{ .date = .{ .weekday = .{ .month = 3, .week = 2, .weekday = 0 } } };
        var end: Change = .{ .date = .{ .weekday = .{ .month = 11, .week = 1, .weekday = 0 } } };
        if (!parser.done()) {
            try parser.expect(',');
            start = try parser.change();
            try parser.expect(',');
            end = try parser.change();
        }
        if (!parser.done()) return error.InvalidTimeZone;
        return .{ .std_offset = std_offset, .dst = .{ .offset = dst_offset, .start = start, .end = end } };
    }

    pub fn offsetAt(self: Rule, t: i64) i32 {
        const dst = self.dst orelse return self.std_offset;
        const year = civilFromDays(@divFloor(t + self.std_offset, seconds_per_day)).year;
        const start = dst.start.instant(year, self.std_offset);
        const end = dst.end.instant(year, dst.offset);
        // Southern-hemisphere rules start daylight saving late in the year and end it early.
        const in_dst = if (start < end) t >= start and t < end else !(t >= end and t < start);
        return if (in_dst) dst.offset else self.std_offset;
    }

    const Parser = struct {
        text: []const u8,
        index: usize = 0,

        fn done(self: *const Parser) bool {
            return self.index >= self.text.len;
        }
        fn peek(self: *const Parser) u8 {
            return self.text[self.index];
        }
        fn expect(self: *Parser, byte: u8) !void {
            if (self.done() or self.peek() != byte) return error.InvalidTimeZone;
            self.index += 1;
        }
        fn name(self: *Parser) !void {
            if (!self.done() and self.peek() == '<') {
                const close = std.mem.indexOfScalarPos(u8, self.text, self.index, '>') orelse return error.InvalidTimeZone;
                if (close - self.index < 4) return error.InvalidTimeZone;
                self.index = close + 1;
                return;
            }
            const start = self.index;
            while (!self.done() and std.ascii.isAlphabetic(self.peek())) self.index += 1;
            if (self.index - start < 3) return error.InvalidTimeZone;
        }
        fn integer(self: *Parser, max: u32) !u32 {
            const start = self.index;
            var value: u32 = 0;
            while (!self.done() and std.ascii.isDigit(self.peek())) : (self.index += 1) {
                value = value * 10 + (self.peek() - '0');
                if (value > max) return error.InvalidTimeZone;
            }
            if (self.index == start) return error.InvalidTimeZone;
            return value;
        }
        /// [+-]hh[:mm[:ss]] in seconds. Rule times may reach 167 hours (RFC 8536).
        fn time(self: *Parser, rule_time: bool) !i32 {
            var sign: i32 = 1;
            if (!self.done() and (self.peek() == '+' or self.peek() == '-')) {
                if (self.peek() == '-') sign = -1;
                self.index += 1;
            }
            var seconds: i32 = @intCast(try self.integer(if (rule_time) 167 else 24) * 3600);
            if (!self.done() and self.peek() == ':') {
                self.index += 1;
                seconds += @intCast(try self.integer(59) * 60);
                if (!self.done() and self.peek() == ':') {
                    self.index += 1;
                    seconds += @intCast(try self.integer(59));
                }
            }
            return sign * seconds;
        }
        fn change(self: *Parser) !Change {
            var result: Change = undefined;
            if (self.done()) return error.InvalidTimeZone;
            switch (self.peek()) {
                'J' => {
                    self.index += 1;
                    const n = try self.integer(365);
                    if (n == 0) return error.InvalidTimeZone;
                    result = .{ .date = .{ .julian = @intCast(n) } };
                },
                'M' => {
                    self.index += 1;
                    const m = try self.integer(12);
                    try self.expect('.');
                    const w = try self.integer(5);
                    try self.expect('.');
                    const d = try self.integer(6);
                    if (m == 0 or w == 0) return error.InvalidTimeZone;
                    result = .{ .date = .{ .weekday = .{ .month = @intCast(m), .week = @intCast(w), .weekday = @intCast(d) } } };
                },
                else => result = .{ .date = .{ .ordinal = @intCast(try self.integer(365)) } },
            }
            if (!self.done() and self.peek() == '/') {
                self.index += 1;
                result.time = try self.time(true);
            }
            return result;
        }
    };
};

/// A time zone: TZif transitions with an optional rule for later times, a bare rule, or UTC.
pub const Zone = struct {
    tz: ?std.tz.Tz = null,
    rule: ?Rule = null,

    pub const utc: Zone = .{};

    /// Seconds east of UTC in effect at the instant `t`.
    pub fn offsetAt(self: *const Zone, t: i64) i32 {
        const tz = self.tz orelse return if (self.rule) |rule| rule.offsetAt(t) else 0;
        const transitions = tz.transitions;
        if (transitions.len == 0 or t < transitions[0].ts) {
            if (transitions.len == 0) if (self.rule) |rule| return rule.offsetAt(t);
            // RFC 8536: local time type 0 applies before the first transition.
            return if (tz.timetypes.len > 0) tz.timetypes[0].offset else 0;
        }
        if (t >= transitions[transitions.len - 1].ts) if (self.rule) |rule| return rule.offsetAt(t);
        // The last transition at or before t.
        var low: usize = 0;
        var high: usize = transitions.len;
        while (high - low > 1) {
            const mid = low + (high - low) / 2;
            if (transitions[mid].ts <= t) low = mid else high = mid;
        }
        return transitions[low].timetype.offset;
    }

    /// Parses TZif data; the zone owns allocations from `allocator`.
    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Zone {
        var reader: std.Io.Reader = .fixed(data);
        var tz = try std.tz.Tz.parse(allocator, &reader);
        errdefer tz.deinit();
        const rule = if (tz.footer) |footer| Rule.parse(footer) catch null else null;
        return .{ .tz = tz, .rule = rule };
    }

    pub fn deinit(self: *Zone) void {
        if (self.tz) |*tz| tz.deinit();
        self.* = .{};
    }

    /// The zone libc would use: $TZ as a file path, a zoneinfo name or a POSIX
    /// rule, otherwise /etc/localtime, otherwise UTC.
    pub fn load(allocator: std.mem.Allocator) Zone {
        const env = @import("desktop-util.zig").env;
        var value = env("TZ") orelse return loadFile(allocator, "/etc/localtime") orelse utc;
        if (value.len > 0 and value[0] == ':') value = value[1..];
        if (value.len == 0) return utc;
        if (value[0] == '/') return loadFile(allocator, value) orelse utc;
        if (std.mem.indexOf(u8, value, "..") == null) {
            var path: [std.fs.max_path_bytes]u8 = undefined;
            for ([_]?[]const u8{ env("TZDIR"), "/etc/zoneinfo", "/usr/share/zoneinfo" }) |directory| {
                const dir = directory orelse continue;
                const full = std.fmt.bufPrint(&path, "{s}/{s}", .{ dir, value }) catch continue;
                if (loadFile(allocator, full)) |zone| return zone;
            }
        }
        return .{ .rule = Rule.parse(value) catch return utc };
    }

    fn loadFile(allocator: std.mem.Allocator, path: []const u8) ?Zone {
        var name: [std.fs.max_path_bytes:0]u8 = undefined;
        if (path.len >= name.len) return null;
        @memcpy(name[0..path.len], path);
        name[path.len] = 0;
        const opened = linux.open(&name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(opened) != .SUCCESS) return null;
        const fd: linux.fd_t = @intCast(opened);
        defer _ = linux.close(fd);
        // Compiled zones are a few kilobytes; the largest is well under this.
        const buffer = allocator.alloc(u8, 256 * 1024) catch return null;
        defer allocator.free(buffer);
        var len: usize = 0;
        while (len < buffer.len) {
            const got = linux.read(fd, buffer[len..].ptr, buffer.len - len);
            switch (linux.errno(got)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return null,
            }
            if (got == 0) break;
            len += got;
        }
        return parse(allocator, buffer[0..len]) catch null;
    }
};

fn loadLocalZone() Zone {
    return Zone.load(std.heap.page_allocator);
}

/// The process's local zone, loaded once like libc's and GLib's.
const localZone = @import("desktop-util.zig").Lazy(Zone, loadLocalZone).get;

test "calendar arithmetic clamps months and crosses leap days and years" {
    const leap = try DateTime.local(2024, 2, 29, 12, 0, 0);
    try std.testing.expectEqual(@as(i32, 60), leap.dayOfYear());
    try std.testing.expectEqual(@as(i32, 4), leap.dayOfWeek());
    const next = try leap.addDays(1);
    try std.testing.expectEqual(@as(i32, 3), next.month());
    try std.testing.expectEqual(@as(i32, 1), next.day());
    const year_later = try leap.addMonths(12);
    try std.testing.expectEqual(@as(i32, 2025), year_later.year());
    try std.testing.expectEqual(@as(i32, 28), year_later.day());
    const back = try (try DateTime.local(2024, 3, 31, 12, 0, 0)).addMonths(-1);
    try std.testing.expectEqual(@as(i32, 2), back.month());
    try std.testing.expectEqual(@as(i32, 29), back.day());
    const new_year = try (try DateTime.local(2023, 12, 31, 12, 0, 0)).addDays(1);
    try std.testing.expectEqual(@as(i32, 2024), new_year.year());
    try std.testing.expectEqual(@as(i32, 1), new_year.dayOfYear());
    try std.testing.expectEqual(@as(i32, 7), (try DateTime.local(2024, 3, 3, 12, 0, 0)).dayOfWeek());
    try std.testing.expect(leap.sameDay(try DateTime.local(2024, 2, 29, 23, 59, 0)));
    try std.testing.expectError(error.DateUnavailable, DateTime.local(2023, 2, 29, 0, 0, 0));
    for ([_]i64{ -719468 - 1, -1, 0, 59, 11016, 19782, 2932896 }) |days| {
        const date = civilFromDays(days);
        try std.testing.expectEqual(days, daysFromCivil(date.year, date.month, date.day));
    }
}

test "formatting matches strftime in the C locale" {
    var buffer: [96]u8 = undefined;
    var value = try DateTime.local(2024, 2, 9, 7, 5, 3);
    value.microsecond = 42;
    try std.testing.expectEqualStrings("Friday February 9 2024 07:05", try value.format(&buffer, "%A %B %-d %Y %H:%M"));
    try std.testing.expectEqualStrings("Fri Feb  9, 09 | 2024-02-09_07-05-03_000042 040 07AM 24 %", try value.format(&buffer, "%a %b %e, %d | %Y-%m-%d_%H-%M-%S_%f %j %IAM %y %%"));
    try std.testing.expectError(error.DateFormatFailed, value.format(buffer[0..4], "%A"));
    try std.testing.expectError(error.DateFormatFailed, value.format(&buffer, "%Q"));
}

test "POSIX rules place daylight saving in both hemispheres" {
    const melbourne = try Rule.parse("AEST-10AEDT,M10.1.0,M4.1.0/3");
    // 2024-10-06 02:00 AEST starts AEDT; 2025-04-06 03:00 AEDT ends it.
    const start: i64 = daysFromCivil(2024, 10, 6) * seconds_per_day + 2 * 3600 - 10 * 3600;
    try std.testing.expectEqual(@as(i32, 10 * 3600), melbourne.offsetAt(start - 1));
    try std.testing.expectEqual(@as(i32, 11 * 3600), melbourne.offsetAt(start));
    const end: i64 = daysFromCivil(2025, 4, 6) * seconds_per_day + 3 * 3600 - 11 * 3600;
    try std.testing.expectEqual(@as(i32, 11 * 3600), melbourne.offsetAt(end - 1));
    try std.testing.expectEqual(@as(i32, 10 * 3600), melbourne.offsetAt(end));
    const new_york = try Rule.parse("EST5EDT,M3.2.0,M11.1.0");
    const spring: i64 = daysFromCivil(2025, 3, 9) * seconds_per_day + 2 * 3600 + 5 * 3600;
    try std.testing.expectEqual(@as(i32, -5 * 3600), new_york.offsetAt(spring - 1));
    try std.testing.expectEqual(@as(i32, -4 * 3600), new_york.offsetAt(spring));
    try std.testing.expectEqual(@as(i32, 5 * 3600 + 45 * 60), (try Rule.parse("<+0545>-5:45")).offsetAt(0));
    try std.testing.expectEqual(@as(i32, -4 * 3600), (try Rule.parse("EST5EDT")).offsetAt(spring));
    try std.testing.expectError(error.InvalidTimeZone, Rule.parse("X1"));
}

test "local time agrees with libc across the system zone database" {
    // libc is only the oracle here; the desktop never calls it for time.
    const libc = @import("desktop-libc.zig");
    const oracle = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
        extern "c" fn tzset() void;
    };
    const previous = if (libc.getenv("TZ")) |value| try std.testing.allocator.dupeSentinel(u8, std.mem.span(value), 0) else null;
    defer {
        if (previous) |value| {
            _ = oracle.setenv("TZ", value, 1);
            std.testing.allocator.free(value);
        } else _ = oracle.unsetenv("TZ");
        oracle.tzset();
    }
    var checked: usize = 0;
    for ([_][:0]const u8{ "/etc/localtime", "/etc/zoneinfo/America/New_York", "/etc/zoneinfo/Europe/London", "/etc/zoneinfo/Asia/Kolkata", "/etc/zoneinfo/Pacific/Chatham", "/etc/zoneinfo/America/Sao_Paulo" }) |path| {
        var zone = Zone.loadFile(std.testing.allocator, path) orelse continue;
        defer zone.deinit();
        var spec: [256]u8 = undefined;
        _ = oracle.setenv("TZ", try std.fmt.bufPrintSentinel(&spec, ":{s}", .{path}, 0), 1);
        oracle.tzset();
        // Every ~9 days from 1901 to 2100, well past the last compiled transition.
        var t: i64 = -2145916800;
        while (t < 4102444800) : (t += 777_777) {
            var stamp: libc.time_t = @intCast(t);
            var tm: libc.struct_tm = .{};
            if (libc.localtime_r(&stamp, &tm) == null) return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(i64, tm.tm_gmtoff), zone.offsetAt(t));
            checked += 1;
        }
    }
    if (checked == 0) return error.SkipZigTest;
}

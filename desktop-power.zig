//! Direct Linux power controls. Only main() runs privileged; the panel uses inspect().
const std = @import("std");
const c = @import("libc");
const a = std.heap.page_allocator;

pub const Profile = enum {
    performance,
    balanced,
    @"power-saver",

    pub fn parse(value: []const u8) !Profile {
        return std.meta.stringToEnum(Profile, value) orelse error.InvalidProfile;
    }
};
pub const State = struct {
    available: [3]bool = @splat(false),
    active: ?Profile = null,
};
const Path = [1024:0]u8;
fn path(buffer: *Path, comptime format: []const u8, args: anytype) ![:0]const u8 {
    return std.fmt.bufPrintSentinel(buffer, format, args, 0);
}
fn read(file: [:0]const u8, buffer: []u8) ![]const u8 {
    const fd = c.open(file.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW);
    if (fd < 0) return if (c.__errno_location().* == c.ENOENT) error.FileNotFound else error.ReadFailed;
    defer _ = c.close(fd);
    const n = c.read(fd, buffer.ptr, buffer.len);
    if (n < 0) return error.ReadFailed;
    if (n == buffer.len) return error.ValueTooLong;
    return std.mem.trim(u8, buffer[0..@intCast(n)], " \t\r\n");
}
fn write(file: [:0]const u8, value: []const u8) !void {
    const fd = c.open(file.ptr, c.O_WRONLY | c.O_CLOEXEC | c.O_NOFOLLOW | c.O_TRUNC);
    if (fd < 0) return error.WriteFailed;
    defer _ = c.close(fd);
    // sysfs attributes expect a single write containing the complete value.
    if (c.write(fd, value.ptr, value.len) != value.len) return error.WriteFailed;
}
fn has(choices: []const u8, value: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, choices, " \t\r\n");
    while (words.next()) |word| if (std.mem.eql(u8, word, value)) return true;
    return false;
}
fn choose(choices: []const u8, candidates: []const []const u8) ![]const u8 {
    for (candidates) |candidate| if (has(choices, candidate)) return candidate;
    return error.UnsupportedProfile;
}
const Change = struct {
    file: [:0]const u8,
    previous: []const u8,
    value: []const u8,
};
const Plan = struct {
    changes: std.ArrayList(Change) = .empty,
    fn deinit(self: *Plan) void {
        for (self.changes.items) |change| {
            a.free(change.file);
            a.free(change.previous);
        }
        self.changes.deinit(a);
    }
    fn add(self: *Plan, file: [:0]const u8, value: []const u8) !void {
        var buffer: [256]u8 = undefined;
        const old = try a.dupe(u8, try read(file, &buffer));
        errdefer a.free(old);
        const name = try a.dupeSentinel(u8, file, 0);
        errdefer a.free(name);
        try self.changes.append(a, .{ .file = name, .previous = old, .value = value });
    }
    fn matches(self: Plan) bool {
        for (self.changes.items) |change| if (!std.mem.eql(u8, change.previous, change.value)) return false;
        return true;
    }
};

pub const Backend = struct {
    // These paths are fixed in the installed helper, never taken from arguments/environment.
    root: []const u8 = "/sys",
    state: []const u8 = "/var/lib/desktop-power",

    fn plan(self: Backend, profile: Profile) !Plan {
        var result = Plan{};
        errdefer result.deinit();
        var name: Path = undefined;
        var buffer: [1024]u8 = undefined;
        const platform_choices = read(try path(&name, "{s}/firmware/acpi/platform_profile_choices", .{self.root}), &buffer) catch |err| switch (err) {
            error.FileNotFound => "",
            else => return err,
        };
        if (platform_choices.len > 0) {
            const value = try choose(platform_choices, switch (profile) {
                .performance => &.{"performance"},
                .balanced => &.{"balanced"},
                .@"power-saver" => &.{ "low-power", "quiet", "cool" },
            });
            try result.add(try path(&name, "{s}/firmware/acpi/platform_profile", .{self.root}), value);
        }
        const directory = c.opendir((try path(&name, "{s}/devices/system/cpu/cpufreq", .{self.root})).ptr);
        if (directory) |dir| {
            defer _ = c.closedir(dir);
            while (c.readdir(dir)) |entry| {
                const policy = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
                if (!std.mem.startsWith(u8, policy, "policy") or policy.len == 6) continue;
                for (policy[6..]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidPolicy;
                const choices = read(try path(&name, "{s}/devices/system/cpu/cpufreq/{s}/energy_performance_available_preferences", .{ self.root, policy }), &buffer) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };
                const value = try choose(choices, switch (profile) {
                    .performance => &.{"performance"},
                    .balanced => &.{ "balance_performance", "balance_power" },
                    .@"power-saver" => &.{ "power", "balance_power" },
                });
                var driver_buffer: [128]u8 = undefined;
                const driver = try read(try path(&name, "{s}/devices/system/cpu/cpufreq/{s}/scaling_driver", .{ self.root, policy }), &driver_buffer);
                // Active pstate's "performance" governor forces EPP=performance.
                // "powersave" permits all three EPP preferences, including performance.
                if (std.mem.eql(u8, driver, "intel_pstate") or std.mem.eql(u8, driver, "amd-pstate-epp")) {
                    try result.add(try path(&name, "{s}/devices/system/cpu/cpufreq/{s}/scaling_governor", .{ self.root, policy }), "powersave");
                }
                try result.add(try path(&name, "{s}/devices/system/cpu/cpufreq/{s}/energy_performance_preference", .{ self.root, policy }), value);
            }
        } else if (c.__errno_location().* != c.ENOENT) return error.ReadFailed;
        if (result.changes.items.len == 0) return error.NoSupportedControls;
        return result;
    }

    pub fn inspect(self: Backend) State {
        var state = State{};
        inline for (std.meta.tags(Profile), 0..) |profile, i| {
            if (self.plan(profile)) |value| {
                var candidate = value;
                defer candidate.deinit();
                state.available[i] = true;
                if (candidate.matches()) state.active = profile;
            } else |_| {}
        }
        return state;
    }

    pub fn apply(self: Backend, profile: Profile) !void {
        var changes = try self.plan(profile);
        defer changes.deinit();
        var failure: ?anyerror = null;
        for (changes.changes.items) |change| {
            // A preceding platform/governor write can also change EPP implicitly.
            write(change.file, change.value) catch |err| {
                failure = err;
                break;
            };
        }
        if (failure == null) self.save(profile) catch |err| {
            failure = err;
        };
        if (failure) |err| {
            var restored = true;
            // Restore the platform first, then governors and their EPP values.
            // Include controls that may have changed implicitly before a failure.
            for (changes.changes.items) |change| write(change.file, change.previous) catch {
                restored = false;
            };
            return if (restored) err else error.RollbackFailed;
        }
    }

    fn save(self: Backend, profile: Profile) !void {
        var name: Path = undefined;
        var temporary: Path = undefined;
        const destination = try path(&name, "{s}/profile", .{self.state});
        const staging = try path(&temporary, "{s}/profile.tmp", .{self.state});
        const fd = c.open(staging.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o644));
        if (fd < 0) return error.SaveFailed;
        defer _ = c.close(fd);
        errdefer _ = c.unlink(staging.ptr);
        const value = @tagName(profile);
        if (c.write(fd, value.ptr, value.len) != value.len or c.fsync(fd) != 0) return error.SaveFailed;
        if (c.rename(staging.ptr, destination.ptr) != 0) return error.SaveFailed;
    }

    pub fn restore(self: Backend) !void {
        var name: Path = undefined;
        var buffer: [64]u8 = undefined;
        const value = read(try path(&name, "{s}/profile", .{self.state}), &buffer) catch |err| switch (err) {
            error.FileNotFound => "balanced",
            else => return err,
        };
        try self.apply(try Profile.parse(value));
    }
};

pub fn runArgs(init: std.process.Init, args: []const []const u8) !void {
    _ = init;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // Validate before opening files. No arbitrary paths or commands are accepted.
    const restore = args.len == 2 and std.mem.eql(u8, args[1], "restore");
    const profile: ?Profile = if (args.len == 3 and std.mem.eql(u8, args[1], "set")) try Profile.parse(args[2]) else if (restore) null else return error.InvalidArguments;
    if (c.geteuid() != 0) return error.RootRequired;
    const fd = c.open("/var/lib/desktop-power/lock", c.O_WRONLY | c.O_CREAT | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0o600));
    if (fd < 0) return error.LockFailed;
    defer _ = c.close(fd);
    if (c.flock(fd, c.LOCK_EX) != 0) return error.LockFailed;
    const backend = Backend{};
    if (profile) |selected| {
        try backend.apply(selected);
    } else backend.restore() catch |err| switch (err) {
        error.NoSupportedControls => {},
        else => return err,
    };
}

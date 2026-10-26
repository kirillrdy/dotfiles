//! Exercise real file operations against private sysfs/state trees, never /sys.
const std = @import("std");
const power = @import("power");
const c = @import("libc");
const assert = std.debug.assert;
const Fixture = struct {
    io: std.Io,
    root: []const u8,
    a: std.mem.Allocator,
    fn file(self: Fixture, relative: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.root, relative });
    }
    fn write(self: Fixture, relative: []const u8, value: []const u8) !void {
        const name = try self.file(relative);
        try std.Io.Dir.cwd().createDirPath(self.io, std.fs.path.dirname(name).?);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = name, .data = value });
    }
    fn expect(self: Fixture, relative: []const u8, expected: []const u8) !void {
        const value = try std.Io.Dir.cwd().readFileAlloc(self.io, try self.file(relative), self.a, .limited(1024));
        assert(std.mem.eql(u8, std.mem.trim(u8, value, "\n "), expected));
    }
    fn policy(self: Fixture, name: []const u8, attribute: []const u8, value: []const u8) !void {
        try self.write(try std.fmt.allocPrint(self.a, "devices/system/cpu/cpufreq/{s}/{s}", .{ name, attribute }), value);
    }
};
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var template = "/tmp/desktop-power-XXXXXX".*;
    const root = c.mkdtemp(&template) orelse return error.TempFailed;
    defer std.Io.Dir.cwd().deleteTree(init.io, std.mem.span(root)) catch {};
    const f = Fixture{ .io = init.io, .root = std.mem.span(root), .a = a };
    const state = try f.file("state");
    try std.Io.Dir.cwd().createDirPath(init.io, state);
    const backend = power.Backend{ .root = f.root, .state = state };
    assert(backend.inspect().active == null);
    assert(!backend.inspect().available[1]);
    if (backend.restore()) |_| return error.ExpectedUnsupported else |err| assert(err == error.NoSupportedControls);
    if (power.Profile.parse("../../etc/passwd")) |_| return error.ExpectedInvalid else |err| assert(err == error.InvalidProfile);

    try f.write("firmware/acpi/platform_profile_choices", "low-power balanced performance\n");
    try f.write("firmware/acpi/platform_profile", "balanced\n");
    for ([_][]const u8{ "policy0", "policy2" }) |policy| {
        try f.policy(policy, "energy_performance_available_preferences", "default performance balance_performance balance_power power\n");
        try f.policy(policy, "energy_performance_preference", "balance_performance\n");
        try f.policy(policy, "scaling_driver", "intel_pstate\n");
        try f.policy(policy, "scaling_governor", "powersave\n");
    }
    assert(backend.inspect().active == .balanced);
    for (backend.inspect().available) |available| assert(available);
    // With no saved selection, boot defaults to balanced.
    try backend.restore();
    try f.expect("state/profile", "balanced");
    try backend.apply(.performance);
    try f.expect("firmware/acpi/platform_profile", "performance");
    try f.expect("devices/system/cpu/cpufreq/policy0/energy_performance_preference", "performance");
    try f.expect("devices/system/cpu/cpufreq/policy2/energy_performance_preference", "performance");
    try f.expect("state/profile", "performance");
    assert(backend.inspect().active == .performance);
    try backend.apply(.@"power-saver");
    try f.expect("firmware/acpi/platform_profile", "low-power");
    try f.expect("devices/system/cpu/cpufreq/policy2/energy_performance_preference", "power");
    try f.expect("state/profile", "power-saver");
    try f.write("firmware/acpi/platform_profile", "balanced");
    assert(backend.inspect().active == null); // Mixed/external settings are not mislabelled.
    try backend.restore();
    assert(backend.inspect().active == .@"power-saver");

    // An unsupported platform profile must fail before changing any CPU settings.
    try f.write("firmware/acpi/platform_profile_choices", "quiet balanced\n");
    assert(!backend.inspect().available[0]);
    if (backend.apply(.performance)) |_| return error.ExpectedUnsupported else |err| assert(err == error.UnsupportedProfile);
    try f.expect("devices/system/cpu/cpufreq/policy0/energy_performance_preference", "power");
    try backend.apply(.@"power-saver");
    try f.expect("firmware/acpi/platform_profile", "quiet");

    // Persistence failure rolls back every applied control and preserves saved state.
    const broken = power.Backend{ .root = f.root, .state = try f.file("missing-state") };
    if (broken.apply(.balanced)) |_| return error.ExpectedSaveFailure else |err| assert(err == error.SaveFailed);
    try f.expect("firmware/acpi/platform_profile", "quiet");
    try f.expect("devices/system/cpu/cpufreq/policy0/energy_performance_preference", "power");
    try f.expect("devices/system/cpu/cpufreq/policy2/energy_performance_preference", "power");
    try f.expect("state/profile", "power-saver");

    // EPP-only systems work too, and a performance governor is changed first.
    try std.Io.Dir.cwd().deleteFile(init.io, try f.file("firmware/acpi/platform_profile_choices"));
    try f.policy("policy0", "scaling_governor", "performance");
    try backend.apply(.balanced);
    try f.expect("devices/system/cpu/cpufreq/policy0/scaling_governor", "powersave");
    assert(backend.inspect().active == .balanced);
    try f.policy("policy2", "energy_performance_available_preferences", "balance_performance balance_power\n");
    assert(!backend.inspect().available[0]);
    try backend.apply(.@"power-saver");
    try f.expect("devices/system/cpu/cpufreq/policy2/energy_performance_preference", "balance_power");
    // Unsupported/corrupt persistent state is rejected, never interpreted as a path.
    try f.write("state/profile", "../performance");
    if (backend.restore()) |_| return error.ExpectedInvalid else |err| assert(err == error.InvalidProfile);
    std.debug.print("desktop-power: platform and EPP profiles, all policies, capability detection, persistence, restore and rollback passed\n", .{});
}

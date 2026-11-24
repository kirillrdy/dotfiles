//! Native panel modules and popup checks on a private Wayland display.
const std = @import("std");
const p = @import("desktop").widgets;
const decode = @import("desktop").decode;
const icons = @import("desktop").icons;
const mainloop = @import("desktop").mainloop;
const util = @import("desktop").util;
const assert = std.debug.assert;
fn eq(a: [*c]const u8, b: [:0]const u8) void {
    assert(std.mem.eql(u8, std.mem.span(a), b));
}
fn pumpEvents(milliseconds: i64) void {
    const end = util.monotonicTime() + milliseconds * 1000;
    while (util.monotonicTime() < end) {
        while (mainloop.iteration(false)) {}
        mainloop.sleep(1000);
    }
}
var refresh_count: usize = 0;
fn refresh(kind: []const u8) void {
    assert(std.mem.eql(u8, kind, "codex"));
    refresh_count += 1;
}
fn clickControl(controls: *@import("desktop").quick.Controls, target: @import("desktop").quick.Target) void {
    const rect = (controls.view.item(target) orelse std.debug.panic("quick settings control {s} is not shown", .{@tagName(target)})).rect;
    controls.pointerButton(true, rect.x + rect.width / 2, rect.y + rect.height / 2);
    controls.pointerButton(false, rect.x + rect.width / 2, rect.y + rect.height / 2);
}
pub fn main(process_init: std.process.Init) !void {
    const args = try process_init.minimal.args.toSlice(process_init.arena.allocator());
    // Re-exec this fixture in place of pkexec to exercise argv, async completion,
    // error reporting and disposal without authorization or real sysfs writes.
    if (args.len == 5 and std.mem.eql(u8, args[1], "--power-fixture")) {
        assert(std.mem.eql(u8, args[2], "power"));
        assert(std.mem.eql(u8, args[3], "set"));
        _ = try @import("desktop").power.Profile.parse(args[4]);
        if (std.mem.eql(u8, args[4], "power-saver")) {
            std.debug.print("fixture: permission denied", .{});
            std.process.exit(1);
        }
        std.process.exit(0);
    }
    _ = @import("desktop").libc.setenv("GSETTINGS_BACKEND", "memory", 1);
    // Resolve and decode the SVGs through the native icon loader.
    if (std.c.getenv("DESKTOP_PANEL_ICON_PATH") != null) {
        for ([_][:0]const u8{
            "network-wireless-signal-good-symbolic",
            "battery-level-90-symbolic",
            "battery-level-50-charging-symbolic",
            "audio-volume-medium-symbolic",
            "microphone-sensitivity-high-symbolic",
            "microphone-sensitivity-muted-symbolic",
            "display-brightness-symbolic",
        }) |name| {
            for ([_]u32{ 1, 2 }) |scale| {
                const image = icons.load(process_init.gpa, name, 16, scale, null).?;
                assert(image.width > 0 and image.height > 0);
                decode.free(process_init.gpa, image);
            }
        }
    }
    const executable = try process_init.arena.allocator().dupeSentinel(u8, args[0], 0);
    @import("desktop").runtime.power_pkexec = executable;
    @import("desktop").runtime.power_helper = "--power-fixture";
    const status = p.init(process_init.gpa, .{ .name = "gnome-status" }, null, null, null);
    assert(status.quick != null);
    const initial_network_title = status.quick.?.view.model.network_title;
    p.update(status, .{ .items = &.{ .{ .icon = "audio-volume-high-symbolic" }, .{ .icon = "battery-level-80-symbolic" } } });
    assert(status.view.items[0].visible and status.view.items[1].visible);
    p.update(status, .{ .items = &.{.{ .icon = "network-wired-symbolic", .tooltip = "Wired network" }} });
    // Collector tooltips must not overwrite the quick-settings connection name.
    assert(std.mem.eql(u8, status.quick.?.view.model.network_title.slice(), initial_network_title.slice()));
    assert(status.quick.?.view.item(.wifi).?.rect.height == 48);
    const controls = status.quick.?;
    // A second panel borrows the same services and detaches independently.
    const peer = p.init(process_init.gpa, .{ .name = "gnome-status" }, controls.devices, null, null);
    assert(peer.quick.?.devices == controls.devices);
    assert(controls.devices.subscribers.items.len == 2);
    p.deinit(peer);
    assert(controls.devices.subscribers.items.len == 1);
    p.apply_power_state(status, .{});
    assert(std.mem.eql(u8, controls.view.model.message.slice(), "Power profiles unavailable"));
    clickControl(controls, .profiles);
    assert(controls.view.item(.profile0) == null and controls.view.item(.profile1) == null);
    p.apply_power_state(status, .{ .available = .{ false, true, true }, .active = .balanced });
    assert(controls.view.item(.profile0) == null and controls.view.item(.profile1) != null);
    assert(std.mem.eql(u8, controls.view.item(.profile_toggle).?.subtitle, "Balanced"));
    p.apply_power_state(status, .{ .available = .{ true, true, true }, .active = .balanced });
    clickControl(controls, .profile0);
    assert(status.power_pending != 0 and !controls.view.enabled(.profile0));
    pumpEvents(500);
    assert(status.power_pending == 0);
    assert(controls.view.model.message.len == 0);
    p.apply_power_state(status, .{ .available = .{ true, true, true }, .active = .balanced });
    clickControl(controls, .profile2);
    pumpEvents(500);
    assert(status.power_pending == 0);
    assert(std.mem.eql(u8, controls.view.model.message.slice(), "fixture: permission denied"));
    clickControl(controls, .profiles);

    const refs_before_refresh = status.refs;
    // Refreshing the tile must never launch another profile change, including
    // transitions between balanced (inactive) and either active toggle state.
    for ([_]?@import("desktop").power.Profile{ .performance, .balanced, .@"power-saver", .balanced, null }) |profile| {
        p.apply_power_state(status, .{ .available = .{ true, true, true }, .active = profile });
        assert(status.power_pending == 0 and status.refs == refs_before_refresh);
        assert(controls.view.item(.profile_toggle).?.active == (profile != null and profile.? != .balanced));
    }
    // User clicks still dispatch once; async completion must not dispatch again.
    clickControl(controls, .profile_toggle);
    assert(status.power_pending != 0);
    pumpEvents(500);
    assert(status.power_pending == 0);
    if (controls.interface) |prefs| {
        const before = controls.view.model.dark;
        clickControl(controls, .dark);
        assert(controls.view.model.dark != before);
        var buffer: [256]u8 = undefined;
        var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
        assert(std.mem.eql(u8, prefs.string(fixed.allocator(), "color-scheme"), if (!before) "prefer-dark" else "default"));
    }
    if (controls.notifications) |prefs| {
        const before = prefs.boolean("show-banners");
        clickControl(controls, .dnd);
        assert(prefs.boolean("show-banners") != before);
        prefs.setBoolean("show-banners", before) catch unreachable;
        // A timed pause turns banners off and shows when they come back.
        clickControl(controls, .dnd_menu);
        assert(controls.view.submenu == .dnd);
        clickControl(controls, .dnd1);
        assert(controls.view.submenu == .none and !prefs.boolean("show-banners"));
        assert(controls.dnd_until != 0 and controls.view.item(.dnd).?.subtitle.len > 0);
        // Turning it off by hand cancels the pending deadline.
        clickControl(controls, .dnd);
        assert(prefs.boolean("show-banners") and controls.dnd_until == 0);
        prefs.setBoolean("show-banners", before) catch unreachable;
    }
    clickControl(controls, .profiles);
    assert(controls.view.submenu == .profiles);
    clickControl(controls, .network);
    assert(controls.view.submenu == .network and controls.view.item(.power_settings) == null);
    clickControl(controls, .network);
    assert(controls.view.submenu == .none);
    const previous_volume = controls.view.model.volume;
    controls.view.model.volume = 50;
    controls.redraw();
    const slider = controls.view.item(.volume).?.rect;
    controls.pointerButton(true, slider.x + 8, slider.y + slider.height / 2);
    assert(controls.view.model.volume.? == 0);
    controls.pointerMotion(slider.x + slider.width + 100, slider.y + 100);
    assert(controls.view.model.volume.? == 100);
    controls.pointerButton(false, slider.x + slider.width + 100, slider.y + 100);
    assert(controls.view.pressed == .none and controls.view.model.volume.? == 100);
    controls.view.focus = .volume;
    assert(controls.handleKey(0xff50, 0) and controls.view.model.volume.? == 0); // Home
    assert(controls.handleKey(0xff53, 0) and controls.view.model.volume.? == 5); // Right
    assert(controls.handleKey(0xff57, 0) and controls.view.model.volume.? == 100); // End
    controls.view.focus = .network;
    assert(controls.handleKey(0xff0d, 0) and controls.view.submenu == .network);
    assert(controls.handleKey(0xff1b, 0) and controls.view.submenu == .none and controls.view.focus == .network);
    _ = mainloop.remove(controls.volume_timer);
    controls.volume_timer = 0;
    controls.view.model.volume = previous_volume;
    controls.redraw();
    p.apply_power_state(status, .{ .available = .{ true, true, true }, .active = .balanced });
    clickControl(controls, .profiles);
    clickControl(controls, .profile0);
    p.deinit(status);
    pumpEvents(500);

    const usage = p.init(process_init.gpa, .{ .name = "gnome-codex", .source = "codex" }, null, null, null);
    p.refresh_source = &refresh;
    defer p.refresh_source = null;
    const usage_menu = usage.usage_menu.?;
    assert(usage_menu.module == usage);
    p.update(usage, .{});
    try usage_menu.show(320, 32);
    pumpEvents(50);
    const refresh_rect = usage.usage.refreshRect();
    const codex_surface = usage_menu.popup.surface.?;
    const zoom = usage_menu.popup.rect.width / @as(f64, @floatFromInt(usage.usage.width));
    const rx = usage_menu.popup.rect.x + (refresh_rect.x + refresh_rect.width / 2) * zoom;
    const ry = usage_menu.popup.rect.y + (refresh_rect.y + refresh_rect.height / 2) * zoom;
    codex_surface.input.button.?(usage_menu, codex_surface, 272, true, rx, ry);
    assert(usage.usage.pressed);
    codex_surface.input.button.?(usage_menu, codex_surface, 272, false, rx, ry);
    assert(refresh_count == 1);
    // Ignore another activation until the collector delivers completion.
    p.usage_refresh(usage);
    assert(refresh_count == 1);
    assert(!usage.usage.enabled);
    eq(usage.usage.checked.value, "Refreshing…");
    p.update(usage, .{ .items = &.{.{ .text = "54%" }}, .tooltip = "5h: 54% remaining", .windows = &.{ .{ .percent = 54, .reset = "Resets in 2h 15m" }, .{ .percent = 93, .reset = "Resets in 4d 8h" } }, .checked = "Checked: 12:00:00" });
    assert(usage.usage.enabled);
    assert(codex_surface.input.symbol.?(usage_menu, codex_surface, 0xff0d, 0, true));
    assert(refresh_count == 2 and !usage.usage.enabled);
    p.update(usage, .{ .windows = &.{ .{ .percent = 54, .reset = "Resets in 2h 15m" }, .{ .percent = 93, .reset = "Resets in 4d 8h" } }, .tooltip = "5h: 54% remaining" });
    usage_menu.hide();
    eq(usage.tooltip.?, "5h: 54% remaining");
    try usage_menu.show(320, 32);
    p.update(usage, .{ .items = &.{.{ .text = "54%" }}, .tooltip = "5h: 54% remaining", .windows = &.{ .{ .percent = 54, .reset = "Resets in 2h 15m" }, .{ .percent = 93, .reset = "Resets in 4d 8h" } }, .checked = "Checked: 12:00:00" });
    assert(usage_menu.popup.visible);
    usage_menu.hide();
    eq(usage.usage.percent[0].value, "54.0% remaining");
    eq(usage.usage.percent[1].value, "93.0% remaining");
    assert(usage.usage.values[0] == 54);
    assert(p.native.usageColor(54).green > 0.7);
    eq(usage.usage.reset[1].value, "Resets in 4d 8h");
    assert(usage.usage.error_label.value.len == 0);
    p.update(usage, .{ .items = &.{.{ .text = "—" }}, .windows = &.{}, .@"error" = "Sign in with codex login" });
    eq(usage.usage.percent[0].value, "—");
    assert(usage.usage.values[0] == 0 and usage.usage.error_label.value.len > 0);
    // Disposal must cancel a dismissal queued from native keyboard input.
    try usage_menu.show(320, 32);
    assert(usage_menu.handleKey(0xff1b));
    assert(usage_menu.popup.close_idle != 0);
    p.deinit(usage);
    pumpEvents(50);

    const clock = p.init(process_init.gpa, .{ .kind = "clock" }, null, null, null);
    const date = &clock.date_controls.?.view;
    const DateTime = @TypeOf(date.selected);
    date.setDate(try DateTime.local(2024, 2, 29, 12, 0, 0));
    try date.prepare(1);
    assert(date.selectedIndex() == 32);
    date.selectDay(33);
    assert(date.selected.month() == 3 and date.selected.day() == 1);
    for (0..3) |_| date.navigate(-1);
    assert(date.selected.year() == 2023 and date.selected.month() == 12);
    clock.date_controls.?.reset();
    assert(date.selected.sameDay(try DateTime.now()));
    p.deinit(clock);
    // Exercise graph history rollover and the native draw callback after migration.
    const monitors = p.init(process_init.gpa, .{ .kind = "monitors" }, null, null, null);
    for (0..130) |i| {
        p.update(monitors, .{ .monitors = &.{.{ .sequence = @intCast(i), .values = &.{@floatFromInt(i)}, .colors = &.{0x0072b3}, .maximum = 100 }} });
    }
    assert(monitors.view.graphs[0].count == 100);
    assert(monitors.view.graphs[0].history[0][0] == 30 and monitors.view.graphs[0].history[0][99] == 129);
    var pixels: [100 * 32]u32 = @splat(0);
    monitors.view.graphs[0].paint(.{ .target = .{ .pixels = &pixels, .width = 100, .height = 32 }, .scale = 1 }, 0, 100, 32);
    assert(pixels[pixels.len - 1] != 0);
    // Verify #ffffff16 background and clipped polygon bounds on a step graph.
    const empty_graph = p.init(process_init.gpa, .{ .kind = "monitors" }, null, null, null);
    var step_pixels: [110 * 32]u32 = @splat(0);
    empty_graph.view.graphs[0].paint(.{ .target = .{ .pixels = &step_pixels, .width = 110, .height = 32 }, .scale = 1 }, 5, 100, 32);
    assert(step_pixels[4] == 0 and step_pixels[5] == 0x16161616 and step_pixels[104] == 0x16161616 and step_pixels[105] == 0);
    p.update(empty_graph, .{ .monitors = &.{.{ .sequence = 1, .values = &.{50}, .colors = &.{0x0072b3}, .maximum = 100 }} });
    p.update(empty_graph, .{ .monitors = &.{.{ .sequence = 2, .values = &.{50}, .colors = &.{0x0072b3}, .maximum = 100 }} });
    @memset(&step_pixels, 0);
    empty_graph.view.graphs[0].paint(.{ .target = .{ .pixels = &step_pixels, .width = 110, .height = 32 }, .scale = 1 }, 5, 100, 32);
    assert(step_pixels[104] == 0x16161616);
    assert(step_pixels[31 * 110 + 104] != 0x16161616);
    assert(step_pixels[31 * 110 + 103] == 0xff0072b3);
    assert(step_pixels[31 * 110 + 101] == 0x16161616);
    p.deinit(empty_graph);
    p.deinit(monitors);
    std.debug.print("desktop-widgets: power controls, quick settings, calendar, codex and monitors graph passed\n", .{});
}

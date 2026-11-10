//! Application discovery, search, selection and native Wayland hosting.
const std = @import("std");
pub const c = @import("desktop-gtk.zig");
pub const KeyEvent = struct { state: u32 = 0, keyval: u32 };
const cast = c.__zig.cast;
const wire = @import("desktop-surface.zig");
const raster = @import("desktop-raster.zig");
const shaping = @import("desktop-text.zig");
const input = @import("desktop-search-entry.zig");
const view = @import("desktop-apps-view.zig");
const allocator = std.heap.c_allocator;
// Normalize before matching so composed/decomposed names and Unicode casing agree.
pub fn fold(text: [*c]const u8) [*c]u8 {
    const lower = c.g_utf8_casefold(text, -1);
    defer c.g_free(lower);
    return c.g_utf8_normalize(lower, -1, c.G_NORMALIZE_ALL_COMPOSE);
}
pub fn rank(name: [*c]const u8, query: [*c]const u8) u8 {
    const n = std.mem.span(name);
    const q = std.mem.span(query);
    return if (std.mem.startsWith(u8, n, q)) 0 else if (std.mem.indexOf(u8, n, q) != null) 1 else 2;
}
// GIO's terminal fallback does not consistently include Ghostty. Expand desktop
// field codes into argv directly, preserving quoting without invoking a shell.
pub fn terminalArgs(a: std.mem.Allocator, info: *c.GDesktopAppInfo) !std.array_list.Managed(?[*:0]const u8) {
    const command = c.g_app_info_get_commandline(@ptrCast(info));
    if (command == null) return error.MissingCommand;
    var argc: c_int = 0;
    var argv: [*c][*c]u8 = null;
    var err: [*c]c.GError = null;
    if (c.g_shell_parse_argv(command, &argc, &argv, &err) == 0) {
        if (err != null) c.g_error_free(err);
        return error.InvalidCommand;
    }
    defer c.g_strfreev(argv);
    var args = std.array_list.Managed(?[*:0]const u8).init(a);
    try args.appendSlice(&.{ "ghostty", "-e" });
    for (argv[0..@intCast(argc)]) |argument| {
        const text = std.mem.span(argument);
        if (std.mem.eql(u8, text, "%i")) {
            const icon = c.g_desktop_app_info_get_string(info, "Icon");
            defer c.g_free(icon);
            if (icon != null and icon[0] != 0) try args.appendSlice(&.{ "--icon", (try a.dupeSentinel(u8, std.mem.span(icon), 0)).ptr });
            continue;
        }
        var expanded = std.array_list.Managed(u8).init(a);
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] != '%') {
                try expanded.append(text[i]);
                continue;
            }
            i += 1;
            if (i == text.len) return error.InvalidFieldCode;
            switch (text[i]) {
                '%' => try expanded.append('%'),
                'c' => try expanded.appendSlice(std.mem.span(c.g_app_info_get_name(@ptrCast(info)))),
                'k' => {
                    const filename = c.g_desktop_app_info_get_filename(info);
                    if (filename != null) try expanded.appendSlice(std.mem.span(filename));
                },
                // No files/URIs are supplied when launching from the grid.
                'f', 'F', 'u', 'U', 'd', 'D', 'n', 'N', 'v', 'm' => {},
                else => return error.InvalidFieldCode,
            }
        }
        if (expanded.items.len > 0 or text.len == 0) try args.append((try a.dupeSentinel(u8, expanded.items, 0)).ptr);
    }
    try args.append(null);
    return args;
}
pub const Entry = struct {
    info: *c.GAppInfo,
    name: [*c]const u8,
    folded: [*c]u8,
    tile: view.Tile = .{},
};

pub const Launcher = struct {
    host: ?*Host = null,
    visible_window: bool = false,
    owner: ?*anyopaque = null,
    redraw_fn: ?*const fn (?*anyopaque) void = null,
    hidden_fn: ?*const fn (?*anyopaque) void = null,
    /// Return true when the owner defers hiding for an exit animation.
    hide_requested_fn: ?*const fn (?*anyopaque) bool = null,
    search_input: ?*input.Entry = null,
    entries: std.array_list.Managed(*Entry),
    visible: std.array_list.Managed(*Entry),
    query: [*c]u8,
    renderer: shaping.Renderer = .{},
    search_view: view.Search = .{},
    geometry: view.Grid = view.Grid.init(1040, 600),
    selected: usize = 0,
    page: usize = 0,
    hover: ?usize = null,
    pressed: ?usize = null,
    search_focus: bool = true,
    search_hover: bool = false,
    search_hash: u64 = 0,
    search_offset: f64 = 0,
    status: [:0]u8,
    on_search: ?*const fn (?*anyopaque) void = null,
    search_context: ?*anyopaque = null,
    wheel: f64 = 0,
    wheel_time: u32 = 0,

    pub fn init(_: ?*c.GtkApplication) Launcher {
        return .{ .entries = .init(allocator), .visible = .init(allocator), .query = fold(""), .status = allocator.dupeSentinel(u8, "", 0) catch @panic("out of memory") };
    }
    pub fn bind(self: *Launcher) void {
        self.bindControls();
    }
    pub fn bindControls(self: *Launcher) void {
        if (self.search_input == null) self.search_input = input.Entry.create(&inputChanged, self) catch @panic("out of memory");
    }
    pub fn redraw(self: *Launcher) void {
        if (self.host) |host| for (host.client.seats.items) |seat| {
            if (seat.text_input) |value| value.update();
        };
        if (self.redraw_fn) |callback| callback(self.owner) else if (self.host) |host| if (host.surface) |surface| surface.redraw();
    }
    pub fn hide(self: *Launcher) void {
        if (self.visible_window) if (self.hide_requested_fn) |requested| if (requested(self.owner)) return;
        self.visible_window = false;
        self.search_input.?.focus(false);
        self.pressed = null;
        self.hover = null;
        if (self.hidden_fn) |callback| callback(self.owner) else if (self.host) |host| if (host.surface) |surface| surface.hide();
    }
    pub fn deinit(self: *Launcher) void {
        // Stop callbacks before freeing the native connection and entry state.
        self.redraw_fn = null;
        self.hidden_fn = null;
        self.hide_requested_fn = null;
        if (self.host) |host| host.destroy();
        self.host = null;
        if (self.search_input) |entry_input| entry_input.destroy();
        self.freeEntries();
        self.entries.deinit();
        self.visible.deinit();
        self.renderer.deinit();
        self.search_view.deinit();
        allocator.free(self.status);
        c.g_free(self.query);
    }
    fn freeEntries(self: *Launcher) void {
        self.visible.clearRetainingCapacity();
        for (self.entries.items) |item| {
            item.tile.deinit();
            c.g_object_unref(item.info);
            c.g_free(item.folded);
            allocator.destroy(item);
        }
        self.entries.clearRetainingCapacity();
    }
    pub fn reload(self: *Launcher) !void {
        self.freeEntries();
        try self.load();
    }
    pub fn add(self: *Launcher, info: *c.GAppInfo) !void {
        if (c.g_app_info_should_show(info) == 0) return;
        const item = try allocator.create(Entry);
        errdefer allocator.destroy(item);
        item.* = .{ .info = @ptrCast(c.g_object_ref(info)), .name = c.g_app_info_get_display_name(info), .folded = fold(c.g_app_info_get_display_name(info)) };
        errdefer {
            c.g_object_unref(item.info);
            c.g_free(item.folded);
        }
        try self.entries.append(item);
    }
    pub fn load(self: *Launcher) !void {
        const all = c.g_app_info_get_all();
        defer c.g_list_free_full(all, c.g_object_unref);
        var node = all;
        while (node != null) : (node = node.*.next) try self.add(cast(c.GAppInfo, node.*.data));
        self.refresh();
    }
    pub fn first(self: *Launcher) ?*Entry {
        return if (self.visible.items.len > 0) self.visible.items[0] else null;
    }
    pub fn searchText(self: *const Launcher) [:0]const u8 {
        return if (self.search_input) |entry_input| entry_input.buffer.valueZ() else "";
    }
    pub fn setSearch(self: *Launcher, value: []const u8) !void {
        const entry_input = self.search_input orelse return error.NotBound;
        // Validate before clearing, so a rejected update preserves the query.
        var buffer: input.Buffer = .{};
        try buffer.insert(value);
        entry_input.clear();
        try entry_input.insert(value);
    }
    pub fn setMessage(self: *Launcher, value: []const u8) void {
        const owned = allocator.dupeSentinel(u8, value, 0) catch return;
        allocator.free(self.status);
        self.status = owned;
        self.redraw();
    }
    pub fn refresh(self: *Launcher) void {
        c.g_free(self.query);
        self.query = fold(self.searchText());
        self.visible.clearRetainingCapacity();
        for (self.entries.items) |item| if (rank(item.folded, self.query) < 2) {
            self.visible.append(item) catch @panic("out of memory");
        };
        std.mem.sort(*Entry, self.visible.items, self.query, struct {
            fn less(query: [*c]u8, left: *Entry, right: *Entry) bool {
                const l = rank(left.folded, query);
                const r = rank(right.folded, query);
                return if (l != r) l < r else c.g_utf8_collate(left.name, right.name) < 0;
            }
        }.less);
        self.page = 0;
        self.selected = 0;
        self.hover = null;
        self.pressed = null;
        self.setMessage("");
        self.redraw();
    }
    pub fn focusGrid(self: *Launcher) void {
        self.search_focus = false;
        self.search_input.?.focus(false);

        self.redraw();
    }
    pub fn present(self: *Launcher) void {
        if (self.host == null) self.host = Host.create(self) catch |err| {
            std.log.err("applications window: {s}", .{@errorName(err)});
            return;
        };
        self.setSearch("") catch {};
        self.refresh();
        self.visible_window = true;
        self.focusSearch();
        const surface = self.host.?.surface orelse {
            self.visible_window = false;
            return;
        };
        surface.show() catch |err| std.log.err("applications window: {s}", .{@errorName(err)});
    }
    pub fn focusSearch(self: *Launcher) void {
        self.search_focus = true;
        self.search_input.?.focus(true);
        self.redraw();
    }
    pub fn text(self: *Launcher, value: []const u8) void {
        self.focusSearch();
        self.search_input.?.insert(value) catch {};
    }
    fn pageCount(self: *const Launcher) usize {
        return @max(1, std.math.divCeil(usize, self.visible.items.len, self.geometry.capacity()) catch unreachable);
    }
    pub fn changePage(self: *Launcher, direction: i32) void {
        const target = @as(i64, @intCast(self.page)) + direction;
        if (target < 0 or target >= self.pageCount()) return;
        self.page = @intCast(target);
        self.selected = self.page * self.geometry.capacity();
        self.hover = null;
        self.pressed = null;
        self.redraw();
    }
    pub fn launch(self: *Launcher, info: *c.GAppInfo) bool {
        var err: [*c]c.GError = null;
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        var ok = false;
        const desktop = cast(c.GDesktopAppInfo, info);
        if (c.g_type_check_instance_is_a(cast(c.GTypeInstance, info), c.g_desktop_app_info_get_type()) != 0 and
            c.g_desktop_app_info_get_filename(desktop) != null and c.g_desktop_app_info_get_boolean(desktop, "Terminal") != 0)
        {
            if (terminalArgs(arena.allocator(), desktop)) |args| {
                const directory = c.g_desktop_app_info_get_string(desktop, "Path");
                defer c.g_free(directory);
                ok = c.g_spawn_async(if (directory != null and directory[0] != 0) directory else null, @ptrCast(args.items.ptr), null, c.G_SPAWN_SEARCH_PATH, null, null, null, &err) != 0;
            } else |_| {}
        } else {
            ok = c.g_app_info_launch(info, null, null, &err) != 0;
        }
        if (ok) {
            self.hide();
        } else {
            self.setMessage(if (err != null) std.mem.span(err.*.message) else "Could not launch application");
        }
        if (err != null) c.g_error_free(err);
        return ok;
    }
};
fn inputChanged(data: ?*anyopaque) void {
    const self = cast(Launcher, data);
    const hash = std.hash.Wyhash.hash(0, self.searchText());
    if (self.search_hash != hash) {
        self.search_hash = hash;
        self.refresh();
        if (self.on_search) |callback| callback(self.search_context);
    }
    self.redraw();
}
pub fn keyPress(_: ?*anyopaque, event: *KeyEvent, data: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast(Launcher, data);
    const symbol = event.keyval;
    if (symbol == c.GDK_KEY_Escape) {
        self.hide();
        return 1;
    }
    if (symbol == c.GDK_KEY_Return or symbol == c.GDK_KEY_KP_Enter) {
        if (self.selected < self.visible.items.len) _ = self.launch(self.visible.items[self.selected].info);
        return 1;
    }
    if (symbol == 0xff56 or symbol == 0xff55) {
        self.changePage(if (symbol == 0xff56) 1 else -1);
        return 1;
    }
    if (symbol == 0xff09 or symbol == 0xfe20) {
        if (self.search_focus and symbol == 0xff09 and event.state & c.GDK_SHIFT_MASK == 0) self.focusGrid() else {
            self.focusSearch();
        }
        return 1;
    }
    if (self.search_focus and symbol == c.GDK_KEY_Down) {
        self.focusGrid();
        return 1;
    }
    if (!self.search_focus and self.visible.items.len > 0) {
        const cols: i64 = @intCast(self.geometry.columns);
        const delta: i64 = if (symbol == c.GDK_KEY_Left) -1 else if (symbol == c.GDK_KEY_Right) 1 else if (symbol == c.GDK_KEY_Up) -cols else if (symbol == c.GDK_KEY_Down) cols else 0;
        if (delta != 0 or symbol == 0xff50 or symbol == 0xff57) {
            const next: i64 = if (symbol == 0xff50) 0 else if (symbol == 0xff57) @intCast(self.visible.items.len - 1) else @as(i64, @intCast(self.selected)) + delta;
            if (next < 0 and symbol == c.GDK_KEY_Up) {
                self.focusSearch();
            } else self.selected = @intCast(std.math.clamp(next, 0, @as(i64, @intCast(self.visible.items.len - 1))));
            self.page = self.selected / self.geometry.capacity();
            self.hover = null;
            self.redraw();
            return 1;
        }
    }
    if (self.search_focus or symbol == c.GDK_KEY_BackSpace) {
        self.focusSearch();
        return @intFromBool(self.search_input.?.key(symbol, event.state));
    }
    return 0;
}
pub const Part = enum { search, grid, message };
pub fn press(self: *Launcher, part: Part, x: f64, y: f64, modifiers: u32) void {
    if (part == .search) {
        self.focusSearch();
        if (x > 338 and self.searchText().len > 0) self.setSearch("") catch {} else {
            self.search_input.?.buffer.cursor = searchPoint(self, x);
            if (modifiers & 1 == 0) self.search_input.?.buffer.anchor = self.search_input.?.buffer.cursor;
            self.search_input.?.revision += 1;
            self.search_input.?.dragging = true;
            inputChanged(self);
        }
    } else if (part == .grid) {
        self.focusGrid();
        const g = self.geometry;
        if (y > g.height - 40) {
            const count = self.pageCount();
            const left = (g.width - @as(f64, @floatFromInt(count * 34))) / 2;
            const index: i64 = @intFromFloat(@floor((x - left) / 34));
            if (index >= 0 and index < count) self.changePage(@intCast(index - @as(i64, @intCast(self.page))));
        } else if (x < g.width * 0.1) self.changePage(-1) else if (x >= g.width * 0.9) self.changePage(1) else if (g.hit(x, y)) |slot| {
            const index = self.page * g.capacity() + slot;
            if (index < self.visible.items.len) {
                self.selected = index;
                self.pressed = index;
            }
        }
    }
    self.redraw();
}
pub fn release(self: *Launcher, part: Part, x: f64, y: f64) void {
    self.search_input.?.dragging = false;
    const pressed = self.pressed;
    self.pressed = null;
    if (part == .grid) if (self.geometry.hit(x, y)) |slot| {
        const index = self.page * self.geometry.capacity() + slot;
        if (pressed == index and index < self.visible.items.len) _ = self.launch(self.visible.items[index].info);
    };
    self.redraw();
}
pub fn motion(self: *Launcher, part: Part, x: f64, y: f64) void {
    self.search_hover = part == .search;
    if (self.search_input.?.dragging) {
        self.search_input.?.buffer.cursor = searchPoint(self, x);
        self.search_input.?.revision += 1;
        inputChanged(self);
    } else if (part == .grid) {
        const slot = self.geometry.hit(x, y);
        const index = if (slot) |i| self.page * self.geometry.capacity() + i else self.visible.items.len;
        self.hover = if (index < self.visible.items.len) index else null;
    } else self.hover = null;
    self.redraw();
}
pub fn scroll(self: *Launcher, amount: f64) void {
    const time: u32 = @truncate(@as(u64, @intCast(@divTrunc(c.g_get_monotonic_time(), 1000))));
    if (time -% self.wheel_time > 200) self.wheel = 0;
    self.wheel_time = time;
    self.wheel += amount;
    if (@abs(self.wheel) >= 10) {
        self.changePage(if (self.wheel > 0) 1 else -1);
        self.wheel = 0;
    }
}

fn searchPoint(self: *Launcher, x: f64) usize {
    // Use shaped prefix advances, so proportional fonts and CJK hit correctly.
    const value = self.searchText();
    var previous: f64 = 0;
    var offset: usize = 0;
    while (offset < value.len) {
        const next = offset + (std.unicode.utf8ByteSequenceLength(value[offset]) catch 1);
        const advance = view.measure(&self.renderer, value[0..next], 1) catch previous;
        if (x - 41 + self.search_offset < (previous + advance) / 2) return offset;
        previous = advance;
        offset = next;
    }
    return value.len;
}
pub fn paint(l: *Launcher, part: Part, target: raster.Buffer, scale: u32) void {
    @memset(target.pixels, 0xff222226);
    if (part == .search) {
        var buffer = l.search_input.?.presentation();
        const state = .{ .buffer = &buffer, .focused = l.search_input.?.focused, .caret = l.search_input.?.caret and (l.search_input.?.composition.len == 0 or l.search_input.?.composition_caret) };
        view.paintSearch(target, scale, &l.renderer, &l.search_view, &state, l.search_hover, &l.search_offset) catch {};
    } else if (part == .message) {
        view.centerText(target, scale, &l.renderer, l.status, 0xb6b6b9) catch {};
    } else {
        const canvas: raster.Canvas = .{ .target = target, .scale = @floatFromInt(scale) };
        if (l.visible.items.len == 0) view.centerText(target, scale, &l.renderer, "No applications found", 0xb6b6b9) catch {};
        const start = l.page * l.geometry.capacity();
        const end = @min(l.visible.items.len, start + l.geometry.capacity());
        for (start..@max(start, end)) |i| {
            const item = l.visible.items[i];
            const focused = !l.search_focus and l.selected == i;
            // GNOME marks the default search result selected while the entry
            // retains focus; the keyboard focus ring belongs to the grid only.
            const selected = l.search_focus and l.query[0] != 0 and l.selected == i;
            item.tile.paint(canvas, scale, &l.renderer, item.name, c.g_app_info_get_icon(item.info), l.geometry.tile(i - start), l.geometry.icon_size, l.hover == i, focused, selected, l.pressed == i) catch {};
        }
        view.paintPages(canvas, l.geometry, l.page, l.pageCount());
    }
}
pub fn activate(_: ?*c.GtkApplication, data: ?*anyopaque) callconv(.c) void {
    const state = cast(?Launcher, data);
    if (state.* == null) {
        state.* = Launcher.init(null);
        state.*.?.bind();
    }
    const self = &state.*.?;
    if (self.visible_window) self.hide() else {
        self.reload() catch |err| std.log.err("loading applications: {s}", .{@errorName(err)});
        self.present();
    }
}

pub const Region = struct {
    x: f64 = 0,
    y: f64 = 0,
    width: u32,
    height: u32,
    pub fn contains(self: Region, x: f64, y: f64) bool {
        return x >= self.x and y >= self.y and x < self.x + @as(f64, @floatFromInt(self.width)) and y < self.y + @as(f64, @floatFromInt(self.height));
    }
};

/// Paint over existing pixels when the region occupies complete destination
/// rows. The painter must preserve the backdrop in transparent areas.
pub fn paintRegionInPlace(target: raster.Buffer, scale: u32, region: Region, context: anytype, comptime painter: anytype) void {
    if (region.width == 0 or region.height == 0) return;
    const width = region.width * scale;
    const height = region.height * scale;
    const factor: f64 = @floatFromInt(scale);
    const py = region.y * factor;
    if (region.x == 0 and width == target.width and @floor(py) == py and py >= 0 and py + @as(f64, @floatFromInt(height)) <= @as(f64, @floatFromInt(target.height))) {
        const first: usize = @intFromFloat(py);
        painter(context, .{ .pixels = target.pixels[first * target.width .. (first + height) * target.width], .width = width, .height = height }, scale);
        return;
    }
    paintRegion(target, scale, region, context, painter);
}

pub fn paintRegion(target: raster.Buffer, scale: u32, region: Region, context: anytype, comptime painter: anytype) void {
    if (region.width == 0 or region.height == 0) return;
    const width = region.width * scale;
    const height = region.height * scale;
    const factor: f64 = @floatFromInt(scale);
    const px = region.x * factor;
    const py = region.y * factor;
    const pixels = allocator.alloc(u32, @as(usize, width) * height) catch return;
    defer allocator.free(pixels);
    @memset(pixels, 0);
    const buffer: raster.Buffer = .{ .pixels = pixels, .width = width, .height = height };
    painter(context, buffer, scale);
    if (@floor(px) == px and @floor(py) == py) {
        const x0: usize = @intFromFloat(std.math.clamp(-px, 0, @as(f64, @floatFromInt(width))));
        const y0: usize = @intFromFloat(std.math.clamp(-py, 0, @as(f64, @floatFromInt(height))));
        const x1: usize = @intFromFloat(std.math.clamp(@as(f64, @floatFromInt(target.width)) - px, 0, @as(f64, @floatFromInt(width))));
        const y1: usize = @intFromFloat(std.math.clamp(@as(f64, @floatFromInt(target.height)) - py, 0, @as(f64, @floatFromInt(height))));
        if (x1 <= x0 or y1 <= y0) return;
        for (y0..y1) |y| for (x0..x1) |x| {
            const source = pixels[y * width + x];
            if (source == 0) continue;
            const dx: usize = @intFromFloat(px + @as(f64, @floatFromInt(x)));
            const dy: usize = @intFromFloat(py + @as(f64, @floatFromInt(y)));
            const destination = &target.pixels[dy * target.width + dx];
            destination.* = if (source >> 24 == 255) source else raster.over(destination.*, source);
        };
        return;
    }
    raster.blit(target, .{ .pixels = std.mem.sliceAsBytes(pixels), .width = width, .height = height, .stride = @as(usize, width) * 4, .format = .argb }, .{ .x = region.x * @as(f64, @floatFromInt(scale)), .y = region.y * @as(f64, @floatFromInt(scale)), .width = @floatFromInt(width), .height = @floatFromInt(height) }, null) catch {};
}

pub const Host = struct {
    launcher: *Launcher,
    client: *wire.Client,
    surface: ?*wire.Surface,
    search: Region = .{ .width = 370, .height = 37 },
    grid: Region = .{ .width = 1040, .height = 600 },
    message: Region = .{ .width = 1040, .height = 64 },
    fn create(launcher: *Launcher) !*Host {
        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);
        const client = try wire.Client.createInteractive(.{ .added = &added, .removed = &removed }, self);
        errdefer client.destroy();
        if (client.outputs.items.len == 0) return error.DisplayUnavailable;
        self.* = .{ .launcher = launcher, .client = client, .surface = null };
        self.surface = try self.createSurface(client.outputs.items[0]);
        try client.start();
        return self;
    }
    fn destroy(self: *Host) void {
        self.client.destroy();
        allocator.destroy(self);
    }
    fn added(data: ?*anyopaque, output: *wire.Output) void {
        const self = cast(Host, data);
        if (self.surface == null) self.surface = self.createSurface(output) catch null;
    }
    fn createSurface(self: *Host, output: *wire.Output) !*wire.Surface {
        const surface = try wire.Surface.createPixels(output, .{ .namespace = "desktop-apps", .title = "Applications", .role = .toplevel, .width = 1040, .height = 720, .interactive = true, .cursor = .arrow, .maximized = true }, &draw, self);
        surface.close = &closed;
        surface.input = .{ .symbol = &symbol, .text = &text, .button = &button, .motion = &Host.motion, .leave = &leave, .focus = &focus, .scroll = &Host.scroll, .surrounding = &surrounding, .preedit = &preedit, .commit = &commit, .delete = &delete };
        return surface;
    }
    fn removed(data: ?*anyopaque, output: *wire.Output) void {
        const self = cast(Host, data);
        if (self.surface) |surface| if (surface.output == output) {
            self.launcher.hide();
            self.surface = null;
        };
    }
    fn closed(data: ?*anyopaque) void {
        cast(Host, data).launcher.hide();
    }
    pub fn draw(data: ?*anyopaque, target: wire.Pixels) void {
        const self = cast(Host, data);
        const scale = self.surface.?.output.scale;
        const width = target.width / scale;
        const height = target.height / scale;
        self.search.x = (@as(f64, @floatFromInt(width)) - 370) / 2;
        self.search.y = 12;
        self.grid = .{ .y = 55, .width = width, .height = height -| (55 + @as(u32, if (self.launcher.status.len > 0) 64 else 0)) };
        self.message = .{ .y = @floatFromInt(height -| 64), .width = width, .height = 64 };
        const previous = self.launcher.geometry;
        self.launcher.geometry = view.Grid.init(@max(1, self.grid.width), @max(1, self.grid.height));
        if (previous.width != self.launcher.geometry.width or previous.height != self.launcher.geometry.height) self.launcher.page = self.launcher.selected / self.launcher.geometry.capacity();
        @memset(target.pixels, 0xff222226);
        paintRegion(target, scale, self.search, .{ self.launcher, Part.search }, paintPart);
        paintRegion(target, scale, self.grid, .{ self.launcher, Part.grid }, paintPart);
        if (self.launcher.status.len > 0) paintRegion(target, scale, self.message, .{ self.launcher, Part.message }, paintPart);
    }
    fn symbol(data: ?*anyopaque, _: *wire.Surface, key: u32, modifiers: u32, pressed: bool) bool {
        if (!pressed) return false;
        var event: KeyEvent = .{ .state = modifiers, .keyval = key };
        return keyPress(null, &event, cast(Host, data).launcher) != 0;
    }
    fn text(data: ?*anyopaque, _: *wire.Surface, value: []const u8) void {
        cast(Host, data).launcher.text(value);
    }
    fn part(self: *Host, x: f64, y: f64) Part {
        return if (self.search.contains(x, y)) .search else .grid;
    }
    fn button(data: ?*anyopaque, _: *wire.Surface, code: u32, down: bool, x: f64, y: f64) void {
        if (code != 272) return;
        const self = cast(Host, data);
        const current = self.part(x, y);
        const rect = if (current == .search) self.search else self.grid;
        if (down) press(self.launcher, current, x - rect.x, y - rect.y, 0) else release(self.launcher, current, x - rect.x, y - rect.y);
    }
    fn motion(data: ?*anyopaque, _: *wire.Surface, x: f64, y: f64) void {
        const self = cast(Host, data);
        const current = if (self.launcher.search_input.?.dragging) Part.search else self.part(x, y);
        const rect = if (current == .search) self.search else self.grid;
        @import("desktop-apps.zig").motion(self.launcher, current, x - rect.x, y - rect.y);
    }
    fn leave(data: ?*anyopaque, _: *wire.Surface) void {
        const self = cast(Host, data);
        self.launcher.hover = null;
        self.launcher.search_hover = false;
        self.launcher.redraw();
    }
    fn focus(data: ?*anyopaque, _: *wire.Surface, value: bool) void {
        const self = cast(Host, data);
        self.launcher.search_input.?.focus(value and self.launcher.search_focus);
    }
    fn scroll(data: ?*anyopaque, _: *wire.Surface, _: u32, amount: f64) void {
        @import("desktop-apps.zig").scroll(cast(Host, data).launcher, amount);
    }
    fn surrounding(data: ?*anyopaque, _: *wire.Surface) ?@import("desktop-input.zig").TextState {
        const self = cast(Host, data);
        return textState(self.launcher, self.search);
    }
    fn preedit(data: ?*anyopaque, _: *wire.Surface, value: []const u8, cursor: i32) void {
        cast(Host, data).launcher.search_input.?.preedit(value, cursor);
    }
    fn commit(data: ?*anyopaque, _: *wire.Surface, value: []const u8) void {
        cast(Host, data).launcher.search_input.?.insert(value) catch {};
    }
    fn delete(data: ?*anyopaque, _: *wire.Surface, before: u32, after: u32) void {
        cast(Host, data).launcher.search_input.?.deleteSurrounding(before, after);
    }
};
pub fn paintPart(context: struct { *Launcher, Part }, target: raster.Buffer, scale: u32) void {
    paint(context[0], context[1], target, scale);
}
pub fn textState(launcher: *Launcher, region: Region) ?@import("desktop-input.zig").TextState {
    const entry = launcher.search_input orelse return null;
    if (!entry.focused) return null;
    const display = entry.presentation();
    const advance = view.measure(&launcher.renderer, display.value()[0..display.cursor], 1) catch 0;
    const caret = std.math.clamp(advance - launcher.search_offset, 0, @as(f64, @floatFromInt(region.width -| 82)));
    return .{ .text = entry.buffer.valueZ(), .cursor = @intCast(entry.buffer.cursor), .anchor = @intCast(entry.buffer.anchor), .rect = .{ .x = @intFromFloat(region.x + 41 + caret), .y = @intFromFloat(region.y), .width = 1, .height = @intCast(region.height) } };
}

test "native layout compositing clips regions and preserves transparent pixels" {
    const Painter = struct {
        fn paint(_: void, target: raster.Buffer, _: u32) void {
            @memset(target.pixels, 0x80800000);
        }
    };
    var pixels: [18]u32 = @splat(0xff0000ff);
    const target: raster.Buffer = .{ .pixels = pixels[1..17], .width = 4, .height = 4 };
    paintRegion(target, 1, .{ .x = -1, .y = -1, .width = 3, .height = 3 }, {}, Painter.paint);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xff80007f), pixels[1]);
    try std.testing.expectEqual(@as(u32, 0xff80007f), pixels[6]);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), pixels[3]);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), pixels[17]);
    const before = pixels;
    paintRegion(target, 1, .{ .x = 10, .y = 10, .width = 3, .height = 3 }, {}, Painter.paint);
    try std.testing.expectEqualSlices(u32, &before, &pixels);
}

test "in-place layout painting preserves the backdrop and adjacent rows" {
    const Painter = struct {
        fn paint(_: void, target: raster.Buffer, _: u32) void {
            for (target.pixels) |*pixel| pixel.* = raster.over(pixel.*, 0x80800000);
        }
    };
    var pixels: [16]u32 = @splat(0xff0000ff);
    paintRegionInPlace(.{ .pixels = &pixels, .width = 4, .height = 4 }, 1, .{ .y = 1, .width = 4, .height = 2 }, {}, Painter.paint);
    for (pixels, 0..) |pixel, index| try std.testing.expectEqual(if (index >= 4 and index < 12) @as(u32, 0xff80007f) else @as(u32, 0xff0000ff), pixel);
}

test "launcher owners can defer hiding until an exit animation completes" {
    const State = struct {
        defer_hide: bool = true,
        hidden: bool = false,
        fn requested(data: ?*anyopaque) bool {
            return cast(@This(), data).defer_hide;
        }
        fn complete(data: ?*anyopaque) void {
            cast(@This(), data).hidden = true;
        }
    };
    var state: State = .{};
    var launcher = Launcher.init(null);
    defer launcher.deinit();
    launcher.bindControls();
    launcher.owner = &state;
    launcher.hide_requested_fn = &State.requested;
    launcher.hidden_fn = &State.complete;
    launcher.visible_window = true;
    launcher.hide();
    try std.testing.expect(launcher.visible_window and !state.hidden);
    state.defer_hide = false;
    launcher.hide();
    try std.testing.expect(!launcher.visible_window and state.hidden);
}

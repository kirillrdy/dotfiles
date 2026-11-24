//! Application discovery, search, selection and native Wayland hosting.
const std = @import("std");
const keyboard = @import("desktop-keyboard.zig");
const util = @import("desktop-util.zig");
pub const KeyEvent = struct { state: u32 = 0, keyval: u32 };
const cast = util.cast;
const wire = @import("desktop-surface.zig");
const raster = @import("desktop-raster.zig");
const shaping = @import("desktop-text.zig");
const input = @import("desktop-password-entry.zig");
const view = @import("desktop-apps-view.zig");
pub const appinfo = @import("desktop-appinfo.zig");
pub const App = appinfo.App;
const unicode = @import("desktop-unicode.zig");
// Normalize before matching so composed/decomposed names and Unicode casing agree.
pub fn fold(a: std.mem.Allocator, text: []const u8) ![:0]u8 {
    const lower = try unicode.casefold(a, text);
    defer a.free(lower);
    return unicode.normalize(a, lower);
}
pub fn rank(n: []const u8, q: []const u8) u8 {
    return if (std.mem.startsWith(u8, n, q)) 0 else if (std.mem.indexOf(u8, n, q) != null) 1 else 2;
}
pub const Entry = struct {
    info: *App,
    name: [*c]const u8,
    folded: [:0]u8,
    /// Orders names as GLib's collation does in the C locale.
    collation: [:0]u8,
    tile: view.Tile = .{},
};

pub const Launcher = struct {
    allocator: std.mem.Allocator,
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
    query: [:0]u8,
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
    overview_search: bool = false,
    arrow_hover: ?view.PageArrow = null,
    arrow_pressed: ?view.PageArrow = null,
    status: [:0]u8,
    on_search: ?*const fn (?*anyopaque) void = null,
    search_context: ?*anyopaque = null,
    wheel: f64 = 0,
    wheel_time: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Launcher {
        return .{ .allocator = allocator, .entries = .init(allocator), .visible = .init(allocator), .query = allocator.dupeSentinel(u8, "", 0) catch @panic("out of memory"), .status = allocator.dupeSentinel(u8, "", 0) catch @panic("out of memory") };
    }
    pub fn bind(self: *Launcher) void {
        if (self.search_input == null) {
            self.search_input = input.Entry.create(self.allocator, &inputChanged, self) catch @panic("out of memory");
            self.search_input.?.makePublic();
        }
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
        self.arrow_hover = null;
        self.arrow_pressed = null;
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
        self.search_view.deinit(self.allocator);
        self.allocator.free(self.status);
        self.allocator.free(self.query);
    }
    fn freeEntries(self: *Launcher) void {
        self.visible.clearRetainingCapacity();
        for (self.entries.items) |item| {
            item.tile.deinit(self.allocator);
            item.info.unref();
            self.allocator.free(item.folded);
            self.allocator.free(item.collation);
            self.allocator.destroy(item);
        }
        self.entries.clearRetainingCapacity();
    }
    pub fn reload(self: *Launcher) !void {
        self.freeEntries();
        try self.load();
    }
    pub fn add(self: *Launcher, info: *App) !void {
        if (!info.shouldShow()) return;
        const item = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(item);
        const folded = try fold(self.allocator, info.display_name);
        errdefer self.allocator.free(folded);
        const collation = try unicode.collateKey(self.allocator, info.display_name);
        errdefer self.allocator.free(collation);
        item.* = .{ .info = info.ref(), .name = info.display_name.ptr, .folded = folded, .collation = collation };
        errdefer item.info.unref();
        try self.entries.append(item);
    }
    pub fn load(self: *Launcher) !void {
        const all = try appinfo.all(self.allocator);
        defer {
            for (all) |info| info.unref();
            self.allocator.free(all);
        }
        for (all) |info| try self.add(info);
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
        const owned = self.allocator.dupeSentinel(u8, value, 0) catch return;
        self.allocator.free(self.status);
        self.status = owned;
        self.redraw();
    }
    pub fn refresh(self: *Launcher) void {
        const folded = fold(self.allocator, self.searchText()) catch @panic("out of memory");
        self.allocator.free(self.query);
        self.query = folded;
        self.visible.clearRetainingCapacity();
        for (self.entries.items) |item| if (rank(item.folded, self.query) < 2) {
            self.visible.append(item) catch @panic("out of memory");
        };
        std.mem.sort(*Entry, self.visible.items, self.query, struct {
            fn less(query: [:0]u8, left: *Entry, right: *Entry) bool {
                const l = rank(left.folded, query);
                const r = rank(right.folded, query);
                return if (l != r) l < r else std.mem.order(u8, left.collation, right.collation) == .lt;
            }
        }.less);
        self.page = 0;
        self.selected = 0;
        self.hover = null;
        self.pressed = null;
        self.arrow_hover = null;
        self.arrow_pressed = null;
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
    pub fn searchMode(self: *const Launcher) bool {
        return self.overview_search and self.searchText().len != 0;
    }
    fn searchGrid(self: *const Launcher) view.SearchGrid {
        return view.SearchGrid.init(@intFromFloat(@max(1, self.geometry.width)), @intFromFloat(@max(1, self.geometry.height)), self.visible.items.len);
    }
    fn pageCount(self: *const Launcher) usize {
        if (self.searchMode()) return 1;
        return @max(1, std.math.divCeil(usize, self.visible.items.len, self.geometry.capacity()) catch unreachable);
    }
    pub fn changePage(self: *Launcher, direction: i32) void {
        if (self.searchMode()) return;
        const target = @as(i64, @intCast(self.page)) + direction;
        if (target < 0 or target >= self.pageCount()) return;
        self.page = @intCast(target);
        self.selected = self.page * self.geometry.capacity();
        self.hover = null;
        self.pressed = null;
        self.arrow_hover = null;
        self.arrow_pressed = null;
        self.redraw();
    }
    pub fn launch(self: *Launcher, info: *App) bool {
        info.launch(self.allocator, .{}, null, null) catch |err| {
            var buffer: [512]u8 = undefined;
            const reason: []const u8 = switch (err) {
                error.FileNotFound => "No such file or directory",
                error.AccessDenied => "Permission denied",
                error.InvalidCommand, error.EmptyCommand, error.MissingCommand => "Invalid command line",
                else => @errorName(err),
            };
            self.setMessage(std.fmt.bufPrint(&buffer, "Could not launch “{s}”: {s}", .{ info.display_name, reason }) catch "Could not launch application");
            return false;
        };
        self.hide();
        return true;
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
pub fn keyPress(self: *Launcher, event: *KeyEvent) bool {
    const symbol = event.keyval;
    const search_mode = self.searchMode();
    if (symbol == keyboard.keys.Escape) {
        self.hide();
        return true;
    }
    if (symbol == keyboard.keys.Return or symbol == keyboard.keys.KP_Enter) {
        const count = self.visible.items.len;
        if (count > 0) {
            const selected = if (search_mode)
                (if (self.search_focus) 0 else @min(self.selected, self.searchGrid().shown - 1))
            else
                self.selected;
            if (selected < count) _ = self.launch(self.visible.items[selected].info);
        }
        return true;
    }
    if (symbol == 0xff56 or symbol == 0xff55) {
        self.changePage(if (symbol == 0xff56) 1 else -1);
        return true;
    }
    if (symbol == 0xff09 or symbol == 0xfe20) {
        if (self.search_focus and symbol == 0xff09 and event.state & keyboard.shift == 0) self.focusGrid() else {
            self.focusSearch();
        }
        return true;
    }
    if (self.search_focus and symbol == keyboard.keys.Down) {
        if (search_mode) {
            if (self.visible.items.len == 0) return true;
            self.selected = 0;
            self.hover = null;
        }
        self.focusGrid();
        return true;
    }
    if (self.search_focus and symbol == keyboard.keys.Right and
        event.state & (keyboard.shift | keyboard.control | keyboard.alt) == 0 and
        search_mode and self.searchGrid().shown > 1)
    {
        const entry = self.search_input.?;
        if (entry.buffer.cursor == entry.buffer.len and !entry.buffer.selected() and entry.composition.len == 0) {
            // The first result is already highlighted while the query has focus.
            self.selected = 1;
            self.hover = null;
            self.focusGrid();
            return true;
        }
    }
    if (!self.search_focus and self.visible.items.len > 0) {
        if (search_mode) {
            const shown = self.searchGrid().shown;
            if (shown > 0) {
                if (symbol == keyboard.keys.Up) {
                    self.focusSearch();
                    return true;
                }
                const delta: i64 = if (symbol == keyboard.keys.Left) -1 else if (symbol == keyboard.keys.Right) 1 else 0;
                if (delta != 0 or symbol == 0xff50 or symbol == 0xff57) {
                    const last: i64 = @intCast(shown - 1);
                    const current: i64 = @intCast(@min(self.selected, shown - 1));
                    const next: i64 = if (symbol == 0xff50) 0 else if (symbol == 0xff57) last else current + delta;
                    self.selected = @intCast(std.math.clamp(next, 0, last));
                    self.page = 0;
                    self.hover = null;
                    self.redraw();
                    return true;
                }
            }
        } else {
            const cols: i64 = @intCast(self.geometry.columns);
            const delta: i64 = if (symbol == keyboard.keys.Left) -1 else if (symbol == keyboard.keys.Right) 1 else if (symbol == keyboard.keys.Up) -cols else if (symbol == keyboard.keys.Down) cols else 0;
            if (delta != 0 or symbol == 0xff50 or symbol == 0xff57) {
                const next: i64 = if (symbol == 0xff50) 0 else if (symbol == 0xff57) @intCast(self.visible.items.len - 1) else @as(i64, @intCast(self.selected)) + delta;
                if (next < 0 and symbol == keyboard.keys.Up) {
                    self.focusSearch();
                } else self.selected = @intCast(std.math.clamp(next, 0, @as(i64, @intCast(self.visible.items.len - 1))));
                self.page = self.selected / self.geometry.capacity();
                self.hover = null;
                self.redraw();
                return true;
            }
        }
    }
    if (self.search_focus or symbol == keyboard.keys.BackSpace) {
        self.focusSearch();
        return self.search_input.?.key(symbol, event.state);
    }
    return false;
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
        if (self.searchMode()) {
            const sg = self.searchGrid();
            if (sg.hit(x, y)) |index| {
                self.selected = index;
                self.pressed = index;
            }
        } else {
            const g = self.geometry;
            const count = self.pageCount();
            if (y > g.height - 40) {
                const left = (g.width - @as(f64, @floatFromInt(count * 34))) / 2;
                const index: i64 = @intFromFloat(@floor((x - left) / 34));
                if (index >= 0 and index < count) self.changePage(@intCast(index - @as(i64, @intCast(self.page))));
            } else if (view.hitPageArrow(g, self.page, count, x, y)) |arrow| {
                self.arrow_pressed = arrow;
            } else if (g.hit(x, y)) |slot| {
                const index = self.page * g.capacity() + slot;
                if (index < self.visible.items.len) {
                    self.selected = index;
                    self.pressed = index;
                }
            }
        }
    }
    self.redraw();
}
pub fn release(self: *Launcher, part: Part, x: f64, y: f64) void {
    self.search_input.?.dragging = false;
    const pressed = self.pressed;
    const arrow_pressed = self.arrow_pressed;
    self.pressed = null;
    self.arrow_pressed = null;
    if (part == .grid) {
        if (self.searchMode()) {
            if (self.searchGrid().hit(x, y)) |index| {
                if (pressed == index and index < self.visible.items.len) _ = self.launch(self.visible.items[index].info);
            }
        } else if (arrow_pressed) |arrow| {
            if (view.hitPageArrow(self.geometry, self.page, self.pageCount(), x, y) == arrow) self.changePage(@backingInt(arrow));
        } else if (self.geometry.hit(x, y)) |slot| {
            const index = self.page * self.geometry.capacity() + slot;
            if (pressed == index and index < self.visible.items.len) _ = self.launch(self.visible.items[index].info);
        }
    }
    self.redraw();
}
pub fn motion(self: *Launcher, part: Part, x: f64, y: f64) void {
    self.search_hover = part == .search;
    self.arrow_hover = if (part == .grid and !self.searchMode()) view.hitPageArrow(self.geometry, self.page, self.pageCount(), x, y) else null;
    if (self.search_input.?.dragging) {
        self.search_input.?.buffer.cursor = searchPoint(self, x);
        self.search_input.?.revision += 1;
        inputChanged(self);
    } else if (part == .grid) {
        if (self.searchMode()) {
            self.hover = self.searchGrid().hit(x, y);
        } else {
            const slot = self.geometry.hit(x, y);
            const index = if (slot) |i| self.page * self.geometry.capacity() + i else self.visible.items.len;
            self.hover = if (index < self.visible.items.len) index else null;
        }
    } else self.hover = null;
    self.redraw();
}
pub fn scroll(self: *Launcher, amount: f64) void {
    if (self.searchMode()) return;
    const time: u32 = @truncate(@as(u64, @intCast(@divTrunc(util.monotonicTime(), 1000))));
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
        const advance = view.measure(self.allocator, &self.renderer, value[0..next], 1) catch previous;
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
        view.paintSearch(l.allocator, target, scale, &l.renderer, &l.search_view, &state, l.search_hover, &l.search_offset) catch {};
    } else if (part == .message) {
        view.centerText(l.allocator, target, scale, &l.renderer, l.status, 0xb6b6b9) catch {};
    } else {
        const canvas: raster.Canvas = .{ .target = target, .scale = @floatFromInt(scale) };
        if (l.searchMode()) {
            if (l.visible.items.len == 0) {
                view.statusText(l.allocator, target, scale, &l.renderer, "No results") catch {};
            } else {
                const sg = l.searchGrid();
                for (0..sg.shown) |i| {
                    const item = l.visible.items[i];
                    const focused = !l.search_focus and @min(l.selected, sg.shown - 1) == i;
                    const selected = l.search_focus and i == 0;
                    item.tile.paint(l.allocator, canvas, scale, &l.renderer, item.name, item.info.icon, sg.tile(i), sg.icon_size, l.hover == i, focused, selected, l.pressed == i) catch {};
                }
            }
        } else {
            if (l.visible.items.len == 0) view.centerText(l.allocator, target, scale, &l.renderer, "No applications found", 0xb6b6b9) catch {};
            const start = l.page * l.geometry.capacity();
            const end = @min(l.visible.items.len, start + l.geometry.capacity());
            for (start..@max(start, end)) |i| {
                const item = l.visible.items[i];
                const focused = !l.search_focus and l.selected == i;
                // GNOME marks the default search result selected while the entry
                // retains focus; the keyboard focus ring belongs to the grid only.
                const selected = l.search_focus and l.query.len != 0 and l.selected == i;
                item.tile.paint(l.allocator, canvas, scale, &l.renderer, item.name, item.info.icon, l.geometry.tile(i - start), l.geometry.icon_size, l.hover == i, focused, selected, l.pressed == i) catch {};
            }
            view.paintPages(canvas, l.geometry, l.page, l.pageCount(), l.arrow_hover, l.arrow_pressed);
        }
    }
}
pub fn activate(allocator: std.mem.Allocator, state: *?Launcher) void {
    if (state.* == null) {
        state.* = Launcher.init(allocator);
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
pub fn paintRegionInPlace(allocator: std.mem.Allocator, target: raster.Buffer, scale: u32, region: Region, context: anytype, comptime painter: anytype) void {
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
    paintRegion(allocator, target, scale, region, context, painter);
}

pub fn paintRegion(allocator: std.mem.Allocator, target: raster.Buffer, scale: u32, region: Region, context: anytype, comptime painter: anytype) void {
    paintRegionOpacity(allocator, target, scale, region, context, painter, 1);
}

pub fn paintRegionOpacity(allocator: std.mem.Allocator, target: raster.Buffer, scale: u32, region: Region, context: anytype, comptime painter: anytype, opacity: f64) void {
    if (opacity <= 0) return;
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
    if (opacity < 1) {
        const alpha: u32 = @intFromFloat(@round(std.math.clamp(opacity, 0, 1) * 255));
        for (pixels) |*pixel| {
            var faded: u32 = 0;
            inline for (.{ 0, 8, 16, 24 }) |shift| {
                faded |= (((pixel.* >> shift) & 255) * alpha + 127) / 255 << shift;
            }
            pixel.* = faded;
        }
    }
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
        const allocator = launcher.allocator;
        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);
        const client = try wire.Client.createInteractive(allocator, .{ .added = &added, .removed = &removed }, self);
        errdefer client.destroy();
        if (client.outputs.items.len == 0) return error.DisplayUnavailable;
        self.* = .{ .launcher = launcher, .client = client, .surface = null };
        self.surface = try self.createSurface(client.outputs.items[0]);
        if (launcher.search_input) |entry| entry.client = client;
        try client.start();
        return self;
    }
    fn destroy(self: *Host) void {
        self.client.destroy();
        self.launcher.allocator.destroy(self);
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
        paintRegion(self.launcher.allocator, target, scale, self.search, .{ self.launcher, Part.search }, paintPart);
        paintRegion(self.launcher.allocator, target, scale, self.grid, .{ self.launcher, Part.grid }, paintPart);
        if (self.launcher.status.len > 0) paintRegion(self.launcher.allocator, target, scale, self.message, .{ self.launcher, Part.message }, paintPart);
    }
    fn symbol(data: ?*anyopaque, _: *wire.Surface, key: u32, modifiers: u32, pressed: bool) bool {
        if (!pressed) return false;
        var event: KeyEvent = .{ .state = modifiers, .keyval = key };
        return keyPress(cast(Host, data).launcher, &event);
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
    const advance = view.measure(launcher.allocator, &launcher.renderer, display.value()[0..display.cursor], 1) catch 0;
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
    paintRegion(std.testing.allocator, target, 1, .{ .x = -1, .y = -1, .width = 3, .height = 3 }, {}, Painter.paint);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xff80007f), pixels[1]);
    try std.testing.expectEqual(@as(u32, 0xff80007f), pixels[6]);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), pixels[3]);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), pixels[17]);
    const before = pixels;
    paintRegion(std.testing.allocator, target, 1, .{ .x = 10, .y = 10, .width = 3, .height = 3 }, {}, Painter.paint);
    try std.testing.expectEqualSlices(u32, &before, &pixels);
}

test "region opacity fades premultiplied controls over the desktop" {
    const Painter = struct {
        fn paint(_: void, target: raster.Buffer, _: u32) void {
            @memset(target.pixels, 0x80800000);
        }
    };
    var pixels: [4]u32 = @splat(0xff0000ff);
    const target: raster.Buffer = .{ .pixels = &pixels, .width = 2, .height = 2 };
    const region: Region = .{ .width = 1, .height = 1 };
    paintRegionOpacity(std.testing.allocator, target, 1, region, {}, Painter.paint, 0);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), pixels[0]);
    paintRegionOpacity(std.testing.allocator, target, 1, region, {}, Painter.paint, 0.5);
    try std.testing.expectEqual(@as(u32, 0xff4000bf), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0xff0000ff), pixels[1]);
}

test "in-place layout painting preserves the backdrop and adjacent rows" {
    const Painter = struct {
        fn paint(_: void, target: raster.Buffer, _: u32) void {
            for (target.pixels) |*pixel| pixel.* = raster.over(pixel.*, 0x80800000);
        }
    };
    var pixels: [16]u32 = @splat(0xff0000ff);
    paintRegionInPlace(std.testing.allocator, .{ .pixels = &pixels, .width = 4, .height = 4 }, 1, .{ .y = 1, .width = 4, .height = 2 }, {}, Painter.paint);
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
    var launcher = Launcher.init(std.testing.allocator);
    defer launcher.deinit();
    launcher.bind();
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

test "overview search navigates results from the end of the query" {
    var launcher = Launcher.init(std.testing.allocator);
    defer launcher.deinit();
    launcher.bind();
    launcher.overview_search = true;
    for (0..3) |index| {
        var buffer: [128]u8 = undefined;
        const source = try std.fmt.bufPrint(&buffer, "[Desktop Entry]\nType=Application\nName=Editor {d}\nExec=true\n", .{index});
        const info = (try App.parse(std.testing.allocator, source, "", null)) orelse return error.AppInfoCreationFailed;
        defer info.unref();
        try launcher.add(info);
    }
    try launcher.setSearch("Editor");
    try std.testing.expectEqual(@as(usize, 3), launcher.visible.items.len);

    var event: KeyEvent = .{ .keyval = keyboard.keys.Left, .state = keyboard.shift };
    try std.testing.expect(keyPress(&launcher, &event));
    try std.testing.expect(launcher.search_input.?.buffer.selected());
    event = .{ .keyval = keyboard.keys.Right };
    try std.testing.expect(keyPress(&launcher, &event));
    try std.testing.expect(launcher.search_focus and !launcher.search_input.?.buffer.selected());
    try std.testing.expect(keyPress(&launcher, &event));
    try std.testing.expect(!launcher.search_focus and launcher.selected == 1);
    try std.testing.expect(keyPress(&launcher, &event));
    try std.testing.expectEqual(@as(usize, 2), launcher.selected);

    event.keyval = keyboard.keys.Left;
    try std.testing.expect(keyPress(&launcher, &event));
    try std.testing.expectEqual(@as(usize, 1), launcher.selected);
    event.keyval = keyboard.keys.Up;
    try std.testing.expect(keyPress(&launcher, &event));
    try std.testing.expect(launcher.search_focus);
    event.keyval = keyboard.keys.Down;
    try std.testing.expect(keyPress(&launcher, &event));
    try std.testing.expect(!launcher.search_focus and launcher.selected == 0);
}

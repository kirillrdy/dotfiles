//! Kernel mode setting without libdrm: connector discovery, modes, dumb
//! buffers and page flips through the DRM ioctls. Frames are drawn in
//! software and scanned out from dumb buffers; GPU rendering is separate.
const std = @import("std");
const linux = std.os.linux;

pub const Error = error{ DrmFailed, NoDisplays, OutOfMemory };

fn ioctlNumber(comptime dir: u32, comptime nr: u8, comptime T: type) u32 {
    return dir << 30 | @as(u32, @sizeOf(T)) << 16 | @as(u32, 'd') << 8 | nr;
}
const read_write: u32 = 3;
const write_only: u32 = 1;

pub const ModeInfo = extern struct {
    clock: u32 = 0,
    hdisplay: u16 = 0,
    hsync_start: u16 = 0,
    hsync_end: u16 = 0,
    htotal: u16 = 0,
    hskew: u16 = 0,
    vdisplay: u16 = 0,
    vsync_start: u16 = 0,
    vsync_end: u16 = 0,
    vtotal: u16 = 0,
    vscan: u16 = 0,
    vrefresh: u32 = 0,
    flags: u32 = 0,
    type: u32 = 0,
    name: [32]u8 = @splat(0),

    pub const type_preferred: u32 = 1 << 3;

    /// Refresh rate in millihertz, as wl_output reports it.
    pub fn refreshMilli(self: ModeInfo) u32 {
        if (self.htotal == 0 or self.vtotal == 0) return self.vrefresh * 1000;
        var refresh = (@as(u64, self.clock) * 1_000_000 / self.htotal + self.vtotal / 2) / self.vtotal;
        if (self.flags & 0x10 != 0) refresh *= 2; // DRM_MODE_FLAG_INTERLACE
        if (self.flags & 0x20 != 0) refresh /= 2; // DRM_MODE_FLAG_DBLSCAN
        if (self.vscan > 1) refresh /= self.vscan;
        return @intCast(refresh);
    }
};

pub const CardResources = extern struct {
    fb_id_ptr: u64 = 0,
    crtc_id_ptr: u64 = 0,
    connector_id_ptr: u64 = 0,
    encoder_id_ptr: u64 = 0,
    count_fbs: u32 = 0,
    count_crtcs: u32 = 0,
    count_connectors: u32 = 0,
    count_encoders: u32 = 0,
    min_width: u32 = 0,
    max_width: u32 = 0,
    min_height: u32 = 0,
    max_height: u32 = 0,
};

pub const Crtc = extern struct {
    set_connectors_ptr: u64 = 0,
    count_connectors: u32 = 0,
    crtc_id: u32 = 0,
    fb_id: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    gamma_size: u32 = 0,
    mode_valid: u32 = 0,
    mode: ModeInfo = .{},
};

pub const Encoder = extern struct {
    encoder_id: u32 = 0,
    encoder_type: u32 = 0,
    crtc_id: u32 = 0,
    possible_crtcs: u32 = 0,
    possible_clones: u32 = 0,
};

pub const Connector = extern struct {
    encoders_ptr: u64 = 0,
    modes_ptr: u64 = 0,
    props_ptr: u64 = 0,
    prop_values_ptr: u64 = 0,
    count_modes: u32 = 0,
    count_props: u32 = 0,
    count_encoders: u32 = 0,
    encoder_id: u32 = 0,
    connector_id: u32 = 0,
    connector_type: u32 = 0,
    connector_type_id: u32 = 0,
    connection: u32 = 0,
    mm_width: u32 = 0,
    mm_height: u32 = 0,
    subpixel: u32 = 0,
    pad: u32 = 0,
};

pub const FbCommand = extern struct {
    fb_id: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    pitch: u32 = 0,
    bpp: u32 = 0,
    depth: u32 = 0,
    handle: u32 = 0,
};

pub const FbCommand2 = extern struct {
    fb_id: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    pixel_format: u32 = 0,
    flags: u32 = 0,
    handles: [4]u32 = @splat(0),
    pitches: [4]u32 = @splat(0),
    offsets: [4]u32 = @splat(0),
    modifier: [4]u64 = @splat(0),
};

pub const PageFlip = extern struct {
    crtc_id: u32 = 0,
    fb_id: u32 = 0,
    flags: u32 = 0,
    reserved: u32 = 0,
    user_data: u64 = 0,
};

pub const CreateDumb = extern struct {
    height: u32 = 0,
    width: u32 = 0,
    bpp: u32 = 0,
    flags: u32 = 0,
    handle: u32 = 0,
    pitch: u32 = 0,
    size: u64 = 0,
};

pub const MapDumb = extern struct {
    handle: u32 = 0,
    pad: u32 = 0,
    offset: u64 = 0,
};

pub const DestroyDumb = extern struct { handle: u32 = 0 };

pub const GetCap = extern struct { capability: u64 = 0, value: u64 = 0 };

pub const CursorCommand = extern struct {
    flags: u32 = 0,
    crtc_id: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    handle: u32 = 0,
    hot_x: i32 = 0,
    hot_y: i32 = 0,
};

/// struct drm_event_vblank, the payload of page flip completion events.
pub const VblankEvent = extern struct {
    type: u32,
    length: u32,
    user_data: u64,
    tv_sec: u32,
    tv_usec: u32,
    sequence: u32,
    crtc_id: u32,
};

pub const ioctl = struct {
    pub const set_master = 0x641e; // _IO('d', 0x1e)
    pub const drop_master = 0x641f; // _IO('d', 0x1f)
    pub const get_cap = ioctlNumber(read_write, 0x0c, GetCap);
    pub const get_resources = ioctlNumber(read_write, 0xa0, CardResources);
    pub const get_crtc = ioctlNumber(read_write, 0xa1, Crtc);
    pub const set_crtc = ioctlNumber(read_write, 0xa2, Crtc);
    pub const get_encoder = ioctlNumber(read_write, 0xa6, Encoder);
    pub const get_connector = ioctlNumber(read_write, 0xa7, Connector);
    pub const add_fb = ioctlNumber(read_write, 0xae, FbCommand);
    pub const remove_fb = ioctlNumber(read_write, 0xaf, u32);
    pub const page_flip = ioctlNumber(read_write, 0xb0, PageFlip);
    pub const add_fb2 = ioctlNumber(read_write, 0xb8, FbCommand2);
    pub const create_dumb = ioctlNumber(read_write, 0xb2, CreateDumb);
    pub const map_dumb = ioctlNumber(read_write, 0xb3, MapDumb);
    pub const destroy_dumb = ioctlNumber(read_write, 0xb4, DestroyDumb);
    pub const cursor2 = ioctlNumber(read_write, 0xbb, CursorCommand);
};

const page_flip_event: u32 = 0x01;
const event_flip_complete: u32 = 0x02;
const cap_dumb_buffer: u64 = 0x1;
const cap_cursor_width: u64 = 0x8;
const cap_cursor_height: u64 = 0x9;
const cursor_set_image: u32 = 0x01;
const cursor_move: u32 = 0x02;
const connected: u32 = 1;

fn call(fd: i32, request: u32, argument: anytype) bool {
    while (true) {
        const result = linux.ioctl(fd, request, @intFromPtr(argument));
        switch (linux.errno(result)) {
            .SUCCESS => return true,
            .INTR, .AGAIN => continue,
            else => return false,
        }
    }
}

/// The kernel's connector names, as wlroots and wlr-randr show them (e.g. eDP-1, HDMI-A-1).
pub fn connectorName(buffer: []u8, kind: u32, index: u32) []const u8 {
    const names = [_][]const u8{ "Unknown", "VGA", "DVI-I", "DVI-D", "DVI-A", "Composite", "SVIDEO", "LVDS", "Component", "DIN", "DP", "HDMI-A", "HDMI-B", "TV", "eDP", "Virtual", "DSI", "DPI", "Writeback", "SPI", "USB" };
    const base = if (kind < names.len) names[kind] else "Unknown";
    return std.fmt.bufPrint(buffer, "{s}-{d}", .{ base, index }) catch base;
}

/// A scan-out buffer: CPU-mapped dumb memory registered as a framebuffer.
pub const Dumb = struct {
    handle: u32 = 0,
    fb: u32 = 0,
    pitch: u32 = 0,
    memory: ?[*]u8 = null,
    size: usize = 0,

    fn create(fd: i32, width: u32, height: u32) Error!Dumb {
        var request: CreateDumb = .{ .width = width, .height = height, .bpp = 32 };
        if (!call(fd, ioctl.create_dumb, &request)) return error.DrmFailed;
        var self: Dumb = .{ .handle = request.handle, .pitch = request.pitch, .size = @intCast(request.size) };
        errdefer self.destroy(fd);
        var command: FbCommand = .{ .width = width, .height = height, .pitch = request.pitch, .bpp = 32, .depth = 24, .handle = request.handle };
        if (!call(fd, ioctl.add_fb, &command)) return error.DrmFailed;
        self.fb = command.fb_id;
        var map: MapDumb = .{ .handle = request.handle };
        if (!call(fd, ioctl.map_dumb, &map)) return error.DrmFailed;
        const address = linux.mmap(null, self.size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, @intCast(map.offset));
        if (linux.errno(address) != .SUCCESS) return error.DrmFailed;
        self.memory = @ptrFromInt(address);
        @memset(self.memory.?[0..self.size], 0);
        return self;
    }

    fn destroy(self: *Dumb, fd: i32) void {
        if (self.memory) |memory| _ = linux.munmap(memory, self.size);
        if (self.fb != 0) _ = call(fd, ioctl.remove_fb, &self.fb);
        if (self.handle != 0) {
            var request: DestroyDumb = .{ .handle = self.handle };
            _ = call(fd, ioctl.destroy_dumb, &request);
        }
        self.* = .{};
    }
};

/// A connected display driven by one CRTC.
pub const Display = struct {
    card: *Card,
    connector: u32,
    crtc: u32,
    mode: ModeInfo,
    name_buffer: [32]u8 = undefined,
    name_len: usize = 0,
    mm_width: u32 = 0,
    mm_height: u32 = 0,
    buffers: [2]Dumb = .{ .{}, .{} },
    /// The buffer scanned out, and whether a flip to the other is pending.
    front: usize = 0,
    flipping: bool = false,
    /// The first frame sets the mode; later ones flip.
    modeset: bool = false,
    /// Called when a flip finished and the next frame may be drawn.
    on_flip: ?*const fn (?*anyopaque) void = null,
    context: ?*anyopaque = null,

    pub fn name(self: *const Display) []const u8 {
        return self.name_buffer[0..self.name_len];
    }

    pub fn width(self: *const Display) u32 {
        return self.mode.hdisplay;
    }

    pub fn height(self: *const Display) u32 {
        return self.mode.vdisplay;
    }

    fn allocate(self: *Display) Error!void {
        for (&self.buffers) |*buffer| buffer.* = try Dumb.create(self.card.fd, self.width(), self.height());
    }

    /// Copies ARGB pixels into the back buffer and shows it at the next vblank.
    /// Returns false while a previous flip is pending or the session is inactive.
    pub fn present(self: *Display, pixels: []const u32) bool {
        if (self.flipping or !self.card.active) return false;
        if (self.buffers[0].handle == 0) self.allocate() catch return false;
        const back = &self.buffers[1 - self.front];
        const memory = back.memory orelse return false;
        const w = self.width();
        // Frames of another size (a mode the display does not have) are not shown.
        if (pixels.len != @as(usize, w) * self.height()) return false;
        for (0..self.height()) |row| {
            const line: [*]u32 = @ptrCast(@alignCast(memory + row * back.pitch));
            @memcpy(line[0..w], pixels[row * w ..][0..w]);
        }
        switch (self.show(back.fb)) {
            .shown => {
                self.front = 1 - self.front;
                return true;
            },
            .flipping => return true,
            .failed => return false,
        }
    }

    pub const Shown = enum { shown, flipping, failed };

    /// Scans out framebuffer `fb`: the first frame sets the mode and shows at
    /// once; later ones flip at the next vblank and report it through on_flip.
    pub fn show(self: *Display, fb: u32) Shown {
        if (self.flipping or !self.card.active) return .failed;
        if (!self.modeset) {
            var connectors = [_]u32{self.connector};
            var request: Crtc = .{ .set_connectors_ptr = @intFromPtr(&connectors), .count_connectors = 1, .crtc_id = self.crtc, .fb_id = fb, .mode_valid = 1, .mode = self.mode };
            if (!call(self.card.fd, ioctl.set_crtc, &request)) return .failed;
            self.modeset = true;
            self.showCursor();
            return .shown;
        }
        var flip: PageFlip = .{ .crtc_id = self.crtc, .fb_id = fb, .flags = page_flip_event, .user_data = @intFromPtr(self) };
        if (!call(self.card.fd, ioctl.page_flip, &flip)) {
            // Drivers without flips, or a mode lost to another master, get a mode set.
            self.modeset = false;
            return .failed;
        }
        self.flipping = true;
        return .flipping;
    }

    /// Places the cursor image's top-left corner, in this display's pixels.
    pub fn moveCursor(self: *Display, x: i32, y: i32) void {
        if (!self.card.active) return;
        var command: CursorCommand = .{ .flags = cursor_move, .crtc_id = self.crtc, .x = x, .y = y };
        _ = call(self.card.fd, ioctl.cursor2, &command);
    }

    fn showCursor(self: *Display) void {
        const card = self.card;
        var command: CursorCommand = .{ .flags = cursor_set_image, .crtc_id = self.crtc, .hot_x = card.cursor_hotspot[0], .hot_y = card.cursor_hotspot[1] };
        if (card.cursor_visible) {
            command.handle = card.cursor.handle;
            command.width = card.cursor_size[0];
            command.height = card.cursor_size[1];
        }
        // Displays without a cursor plane get the cursor drawn into frames.
        if (!call(card.fd, ioctl.cursor2, &command) and card.cursor_visible and self.modeset) card.cursor_hardware = false;
    }

    /// Turns the display off until the next frame sets its mode again.
    pub fn disable(self: *Display) void {
        if (!self.card.active) return;
        var request: Crtc = .{ .crtc_id = self.crtc };
        _ = call(self.card.fd, ioctl.set_crtc, &request);
        self.modeset = false;
        self.flipping = false;
    }

    fn flipped(self: *Display) void {
        self.flipping = false;
        self.front = 1 - self.front;
        if (self.on_flip) |callback| callback(self.context);
    }

    fn destroy(self: *Display) void {
        for (&self.buffers) |*buffer| buffer.destroy(self.card.fd);
    }
};

/// A DRM device opened through the session, with its connected displays.
pub const Card = struct {
    allocator: std.mem.Allocator,
    fd: i32,
    displays: std.ArrayList(*Display) = .empty,
    /// False while the session is switched away; flips wait for resumption.
    active: bool = true,
    /// One cursor image shared by every display.
    cursor: Dumb = .{},
    cursor_size: [2]u32 = .{ 64, 64 },
    cursor_hotspot: [2]i32 = .{ 0, 0 },
    cursor_visible: bool = false,
    /// False once a display rejected the cursor plane.
    cursor_hardware: bool = true,
    /// Called before a display that was unplugged is freed.
    on_remove: ?*const fn (?*anyopaque, *Display) void = null,
    remove_context: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, fd: i32) Error!*Card {
        var cap: GetCap = .{ .capability = cap_dumb_buffer };
        if (!call(fd, ioctl.get_cap, &cap) or cap.value == 0) return error.DrmFailed;
        const self = try allocator.create(Card);
        self.* = .{ .allocator = allocator, .fd = fd };
        var width: GetCap = .{ .capability = cap_cursor_width };
        var height: GetCap = .{ .capability = cap_cursor_height };
        if (call(fd, ioctl.get_cap, &width) and call(fd, ioctl.get_cap, &height) and width.value > 0 and height.value > 0) {
            self.cursor_size = .{ @intCast(@min(width.value, 256)), @intCast(@min(height.value, 256)) };
        }
        return self;
    }

    pub fn deinit(self: *Card) void {
        self.cursor.destroy(self.fd);
        for (self.displays.items) |display| {
            display.destroy();
            self.allocator.destroy(display);
        }
        self.displays.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Finds connected connectors with a free CRTC; returns displays added since the last scan.
    pub fn scan(self: *Card, added: *std.ArrayList(*Display)) Error!void {
        const a = self.allocator;
        var resources: CardResources = .{};
        if (!call(self.fd, ioctl.get_resources, &resources)) return error.DrmFailed;
        const crtcs = try a.alloc(u32, resources.count_crtcs);
        defer a.free(crtcs);
        const connectors = try a.alloc(u32, resources.count_connectors);
        defer a.free(connectors);
        const encoders = try a.alloc(u32, resources.count_encoders);
        defer a.free(encoders);
        resources = .{ .crtc_id_ptr = @intFromPtr(crtcs.ptr), .connector_id_ptr = @intFromPtr(connectors.ptr), .encoder_id_ptr = @intFromPtr(encoders.ptr), .count_crtcs = @intCast(crtcs.len), .count_connectors = @intCast(connectors.len), .count_encoders = @intCast(encoders.len) };
        if (!call(self.fd, ioctl.get_resources, &resources)) return error.DrmFailed;
        for (connectors[0..@min(connectors.len, resources.count_connectors)]) |connector_id| {
            const known = for (self.displays.items) |display| {
                if (display.connector == connector_id) break display;
            } else null;
            const info = self.connector(connector_id) orelse continue;
            defer a.free(info.modes);
            defer a.free(info.encoders);
            if (info.header.connection != connected or info.modes.len == 0) {
                // A display that was unplugged.
                if (known) |display| self.remove(display);
                continue;
            }
            if (known != null) continue;
            const crtc = self.freeCrtc(info.encoders, crtcs[0..@min(crtcs.len, resources.count_crtcs)]) orelse continue;
            var mode = info.modes[0];
            for (info.modes) |candidate| if (candidate.type & ModeInfo.type_preferred != 0) {
                mode = candidate;
                break;
            };
            const display = try a.create(Display);
            errdefer a.destroy(display);
            display.* = .{ .card = self, .connector = connector_id, .crtc = crtc, .mode = mode, .mm_width = info.header.mm_width, .mm_height = info.header.mm_height };
            display.name_len = connectorName(&display.name_buffer, info.header.connector_type, info.header.connector_type_id).len;
            try self.displays.append(a, display);
            try added.append(a, display);
        }
    }

    const ConnectorInfo = struct { header: Connector, modes: []ModeInfo, encoders: []u32 };

    fn connector(self: *Card, id: u32) ?ConnectorInfo {
        const a = self.allocator;
        var header: Connector = .{ .connector_id = id };
        if (!call(self.fd, ioctl.get_connector, &header)) return null;
        // The counts may change between calls when a display is plugged in; retry until stable.
        for (0..4) |_| {
            const modes = a.alloc(ModeInfo, header.count_modes) catch return null;
            const encoders = a.alloc(u32, header.count_encoders) catch {
                a.free(modes);
                return null;
            };
            var full: Connector = .{ .connector_id = id, .modes_ptr = @intFromPtr(modes.ptr), .count_modes = @intCast(modes.len), .encoders_ptr = @intFromPtr(encoders.ptr), .count_encoders = @intCast(encoders.len) };
            if (call(self.fd, ioctl.get_connector, &full) and full.count_modes <= modes.len and full.count_encoders <= encoders.len) {
                return .{ .header = full, .modes = modes[0..full.count_modes], .encoders = encoders[0..full.count_encoders] };
            }
            a.free(modes);
            a.free(encoders);
            header = full;
        }
        return null;
    }

    fn freeCrtc(self: *Card, encoder_ids: []const u32, crtcs: []const u32) ?u32 {
        for (encoder_ids) |encoder_id| {
            var encoder: Encoder = .{ .encoder_id = encoder_id };
            if (!call(self.fd, ioctl.get_encoder, &encoder)) continue;
            for (crtcs, 0..) |crtc, index| {
                if (encoder.possible_crtcs & (@as(u32, 1) << @intCast(index)) == 0) continue;
                const used = for (self.displays.items) |display| {
                    if (display.crtc == crtc) break true;
                } else false;
                if (!used) return crtc;
            }
        }
        return null;
    }

    pub fn remove(self: *Card, display: *Display) void {
        if (self.on_remove) |callback| callback(self.remove_context, display);
        for (self.displays.items, 0..) |candidate, index| if (candidate == display) {
            _ = self.displays.orderedRemove(index);
            break;
        };
        display.destroy();
        self.allocator.destroy(display);
    }

    /// Registers a GPU buffer as a framebuffer, for `Display.show`.
    pub fn addFramebuffer(self: *Card, width: u32, height: u32, format: u32, handle: u32, stride: u32) ?u32 {
        var command: FbCommand2 = .{ .width = width, .height = height, .pixel_format = format };
        command.handles[0] = handle;
        command.pitches[0] = stride;
        if (!call(self.fd, ioctl.add_fb2, &command)) return null;
        return command.fb_id;
    }

    pub fn removeFramebuffer(self: *Card, fb: u32) void {
        var id = fb;
        _ = call(self.fd, ioctl.remove_fb, &id);
    }

    /// Shows premultiplied ARGB `pixels` (`width` wide) as the cursor on every
    /// display, or hides it when null. Images larger than the cursor plane are cropped.
    pub fn setCursor(self: *Card, pixels: ?[]const u32, width: u32, hotspot: [2]i32) void {
        self.cursor_visible = false;
        if (pixels) |image| if (width > 0) {
            if (self.cursor.handle == 0) self.cursor = Dumb.create(self.fd, self.cursor_size[0], self.cursor_size[1]) catch return;
            const memory = self.cursor.memory.?;
            @memset(memory[0..self.cursor.size], 0);
            const height = image.len / width;
            for (0..@min(height, self.cursor_size[1])) |row| {
                const line: [*]u32 = @ptrCast(@alignCast(memory + row * self.cursor.pitch));
                const count = @min(width, self.cursor_size[0]);
                @memcpy(line[0..count], image[row * width ..][0..count]);
            }
            self.cursor_hotspot = hotspot;
            self.cursor_visible = true;
        };
        if (!self.active) return;
        for (self.displays.items) |display| display.showCursor();
    }

    /// Reads page flip events; call when the device is readable.
    pub fn dispatch(self: *Card) void {
        var buffer: [1024]u8 align(8) = undefined;
        const count = linux.read(self.fd, &buffer, buffer.len);
        if (linux.errno(count) != .SUCCESS) return;
        var offset: usize = 0;
        while (offset + @sizeOf(VblankEvent) <= count) {
            const event: *const VblankEvent = @ptrCast(@alignCast(&buffer[offset]));
            if (event.length < 8) break;
            if (event.type == event_flip_complete) {
                for (self.displays.items) |display| if (@intFromPtr(display) == event.user_data) {
                    display.flipped();
                    break;
                };
            }
            offset += event.length;
        }
    }

    /// The session was switched away: flips stop and master is released by the session.
    pub fn pause(self: *Card) void {
        self.active = false;
        for (self.displays.items) |display| display.flipping = false;
    }

    /// The session is back: every display sets its mode again.
    pub fn resumeWith(self: *Card, fd: i32) void {
        self.fd = fd;
        self.active = true;
        for (self.displays.items) |display| display.modeset = false;
    }
};

test "DRM ioctl structures match the kernel headers" {
    const c = @import("drm-reference");
    inline for (.{
        .{ ModeInfo, c.struct_drm_mode_modeinfo },
        .{ CardResources, c.struct_drm_mode_card_res },
        .{ Crtc, c.struct_drm_mode_crtc },
        .{ Encoder, c.struct_drm_mode_get_encoder },
        .{ Connector, c.struct_drm_mode_get_connector },
        .{ FbCommand, c.struct_drm_mode_fb_cmd },
        .{ PageFlip, c.struct_drm_mode_crtc_page_flip },
        .{ CreateDumb, c.struct_drm_mode_create_dumb },
        .{ MapDumb, c.struct_drm_mode_map_dumb },
        .{ DestroyDumb, c.struct_drm_mode_destroy_dumb },
        .{ GetCap, c.struct_drm_get_cap },
        .{ CursorCommand, c.struct_drm_mode_cursor2 },
        .{ FbCommand2, c.struct_drm_mode_fb_cmd2 },
        .{ VblankEvent, c.struct_drm_event_vblank },
    }) |pair| {
        try std.testing.expectEqual(@sizeOf(pair[1]), @sizeOf(pair[0]));
        inline for (@typeInfo(pair[0]).@"struct".field_names) |field| {
            if (@hasField(pair[1], field)) try std.testing.expectEqual(@offsetOf(pair[1], field), @offsetOf(pair[0], field));
        }
    }
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_MODE_GETRESOURCES), ioctl.get_resources);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_MODE_SETCRTC), ioctl.set_crtc);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_MODE_GETCONNECTOR), ioctl.get_connector);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_MODE_PAGE_FLIP), ioctl.page_flip);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_MODE_CREATE_DUMB), ioctl.create_dumb);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_MODE_MAP_DUMB), ioctl.map_dumb);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_MODE_ADDFB), ioctl.add_fb);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_SET_MASTER), ioctl.set_master);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_GET_CAP), ioctl.get_cap);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_MODE_CURSOR2), ioctl.cursor2);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_MODE_ADDFB2), ioctl.add_fb2);
}

test "connector names follow the kernel's" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("eDP-1", connectorName(&buffer, 14, 1));
    try std.testing.expectEqualStrings("HDMI-A-2", connectorName(&buffer, 11, 2));
    try std.testing.expectEqualStrings("Virtual-1", connectorName(&buffer, 15, 1));
}

test "mode refresh rates are millihertz" {
    const mode: ModeInfo = .{ .clock = 148500, .htotal = 2200, .vtotal = 1125, .hdisplay = 1920, .vdisplay = 1080 };
    try std.testing.expectEqual(@as(u32, 60000), mode.refreshMilli());
}

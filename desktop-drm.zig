//! Kernel mode setting without libdrm: connector discovery, modes, the
//! cursor plane and page flips through the DRM ioctls. Frames are drawn by
//! the GPU (desktop-gl.zig) into GBM buffers registered as framebuffers;
//! dumb buffers only hold the cursor.
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
pub const SetClientCap = extern struct { capability: u64 = 0, value: u64 = 0 };

pub const PlaneResources = extern struct {
    plane_id_ptr: u64 = 0,
    count_planes: u32 = 0,
};

pub const Plane = extern struct {
    plane_id: u32 = 0,
    crtc_id: u32 = 0,
    fb_id: u32 = 0,
    possible_crtcs: u32 = 0,
    gamma_size: u32 = 0,
    count_format_types: u32 = 0,
    format_type_ptr: u64 = 0,
};

pub const Atomic = extern struct {
    flags: u32 = 0,
    count_objs: u32 = 0,
    objs_ptr: u64 = 0,
    count_props_ptr: u64 = 0,
    props_ptr: u64 = 0,
    prop_values_ptr: u64 = 0,
    reserved: u64 = 0,
    user_data: u64 = 0,
};

pub const ObjectProperties = extern struct {
    props_ptr: u64 = 0,
    prop_values_ptr: u64 = 0,
    count_props: u32 = 0,
    obj_id: u32 = 0,
    obj_type: u32 = 0,
};

pub const Property = extern struct {
    values_ptr: u64 = 0,
    enum_blob_ptr: u64 = 0,
    prop_id: u32 = 0,
    flags: u32 = 0,
    name: [32]u8 = @splat(0),
    count_values: u32 = 0,
    count_enum_blobs: u32 = 0,
};

pub const SetProperty = extern struct {
    value: u64 = 0,
    prop_id: u32 = 0,
    obj_id: u32 = 0,
    obj_type: u32 = 0,
};

pub const object_crtc: u32 = 0xcccccccc;
pub const object_connector: u32 = 0xc0c0c0c0;
pub const object_plane: u32 = 0xeeeeeeee;

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
    pub const set_client_cap = ioctlNumber(write_only, 0x0d, SetClientCap);
    pub const get_resources = ioctlNumber(read_write, 0xa0, CardResources);
    pub const get_crtc = ioctlNumber(read_write, 0xa1, Crtc);
    pub const set_crtc = ioctlNumber(read_write, 0xa2, Crtc);
    pub const get_encoder = ioctlNumber(read_write, 0xa6, Encoder);
    pub const get_connector = ioctlNumber(read_write, 0xa7, Connector);
    pub const add_fb = ioctlNumber(read_write, 0xae, FbCommand);
    pub const remove_fb = ioctlNumber(read_write, 0xaf, u32);
    pub const get_property = ioctlNumber(read_write, 0xaa, Property);
    pub const get_plane_resources = ioctlNumber(read_write, 0xb5, PlaneResources);
    pub const get_plane = ioctlNumber(read_write, 0xb6, Plane);
    pub const object_properties = ioctlNumber(read_write, 0xb9, ObjectProperties);
    pub const set_object_property = ioctlNumber(read_write, 0xba, SetProperty);
    pub const add_fb2 = ioctlNumber(read_write, 0xb8, FbCommand2);
    pub const create_dumb = ioctlNumber(read_write, 0xb2, CreateDumb);
    pub const map_dumb = ioctlNumber(read_write, 0xb3, MapDumb);
    pub const destroy_dumb = ioctlNumber(read_write, 0xb4, DestroyDumb);
    pub const atomic = ioctlNumber(read_write, 0xbc, Atomic);
};

const page_flip_event: u32 = 0x01;
const atomic_nonblock: u32 = 0x0200;
const event_flip_complete: u32 = 0x02;
const cap_dumb_buffer: u64 = 0x1;
const cap_cursor_width: u64 = 0x8;
const cap_addfb2_modifiers: u64 = 0x10;
const fb_modifiers: u32 = 1 << 1;
/// DRM_FORMAT_MOD_INVALID: no explicit layout.
pub const modifier_invalid: u64 = 0x00ffffffffffffff;
const cap_cursor_height: u64 = 0x9;
const client_cap_atomic: u64 = 0x3;
const plane_type_primary: u64 = 1;
const plane_type_cursor: u64 = 2;
const format_xrgb8888: u32 = 0x34325258; // 'XR24'
const format_argb8888: u32 = 0x34325241; // 'AR24'
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

    fn create(fd: i32, width: u32, height: u32, format: u32) Error!Dumb {
        var request: CreateDumb = .{ .width = width, .height = height, .bpp = 32 };
        if (!call(fd, ioctl.create_dumb, &request)) return error.DrmFailed;
        var self: Dumb = .{ .handle = request.handle, .pitch = request.pitch, .size = @intCast(request.size) };
        errdefer self.destroy(fd);
        var command: FbCommand2 = .{ .width = width, .height = height, .pixel_format = format };
        command.handles[0] = request.handle;
        command.pitches[0] = request.pitch;
        if (!call(fd, ioctl.add_fb2, &command)) return error.DrmFailed;
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

const PrimaryPlane = struct {
    id: u32 = 0,
    fb_id: u32 = 0,
};

const CursorPlane = struct {
    id: u32 = 0,
    /// FB_ID, CRTC_ID, CRTC_X, CRTC_Y, CRTC_W, CRTC_H, SRC_X, SRC_Y, SRC_W, SRC_H.
    props: [10]u32 = @splat(0),
};

/// A connected display driven by one CRTC.
pub const Display = struct {
    card: *Card,
    connector: u32,
    crtc: u32,
    primary_plane: PrimaryPlane = .{},
    cursor_plane: CursorPlane = .{},
    mode: ModeInfo,
    /// Every mode the connector offers, preferred first as the kernel lists them.
    modes: []ModeInfo = &.{},
    name_buffer: [32]u8 = undefined,
    name_len: usize = 0,
    mm_width: u32 = 0,
    mm_height: u32 = 0,
    /// Whether an atomic commit is pending.
    flipping: bool = false,
    /// True when the pending atomic commit updates only the cursor plane.
    cursor_commit: bool = false,
    /// Desired cursor position in display pixels, and what is currently committed.
    cursor_x: i32 = 0,
    cursor_y: i32 = 0,
    cursor_committed_x: i32 = 0,
    cursor_committed_y: i32 = 0,
    cursor_committed_fb: u32 = 0,
    cursor_shown: bool = false,
    cursor_dirty: bool = false,
    /// When the last flip reached the screen (CLOCK_MONOTONIC seconds and
    /// microseconds, from the vblank event) and its vblank count.
    flip_time: [2]u32 = .{ 0, 0 },
    flip_sequence: u32 = 0,
    /// Whether the display can vary its refresh rate, and whether it does.
    vrr_capable: bool = false,
    vrr_enabled: bool = false,
    /// The first frame sets the mode; later ones flip.
    modeset: bool = false,
    /// Called when an atomic commit finished (`primary` is false for cursor-only commits).
    on_flip: ?*const fn (?*anyopaque, bool) void = null,
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

    pub const Shown = enum { shown, flipping, failed };

    fn cursorVisible(self: *const Display) bool {
        const card = self.card;
        if (!card.cursor_visible or !card.cursor_hardware or self.cursor_plane.id == 0) return false;
        const cw: i32 = @intCast(card.cursor_size[0]);
        const ch: i32 = @intCast(card.cursor_size[1]);
        const w: i32 = @intCast(self.width());
        const h: i32 = @intCast(self.height());
        return self.cursor_x + cw > 0 and self.cursor_y + ch > 0 and self.cursor_x < w and self.cursor_y < h;
    }

    fn cursorPropValues(self: *const Display, visible: bool, fb: u32) [10]u64 {
        if (!visible) return @splat(0);
        const cw: u64 = self.card.cursor_size[0];
        const ch: u64 = self.card.cursor_size[1];
        return .{
            fb,
            self.crtc,
            @bitCast(@as(i64, self.cursor_x)),
            @bitCast(@as(i64, self.cursor_y)),
            cw,
            ch,
            0,
            0,
            cw << 16,
            ch << 16,
        };
    }

    /// Scans out framebuffer `fb`: the first frame sets the mode and shows at
    /// once; later ones flip atomically at the next vblank (folding in any
    /// pending cursor update) and report it through on_flip.
    pub fn show(self: *Display, fb: u32) Shown {
        if (self.flipping or !self.card.active) return .failed;
        if (!self.modeset) {
            var connectors = [_]u32{self.connector};
            var request: Crtc = .{ .set_connectors_ptr = @intFromPtr(&connectors), .count_connectors = 1, .crtc_id = self.crtc, .fb_id = fb, .mode_valid = 1, .mode = self.mode };
            if (!call(self.card.fd, ioctl.set_crtc, &request)) return .failed;
            self.modeset = true;
            self.cursor_shown = false;
            self.cursor_committed_fb = 0;
            self.cursor_dirty = true;
            self.commitCursor();
            return .shown;
        }
        if (self.primary_plane.id == 0) return .failed;
        const with_cursor = self.cursor_dirty and self.cursor_plane.id != 0;
        const want_visible = if (with_cursor) self.cursorVisible() else false;
        const want_fb: u32 = if (want_visible) self.card.cursors[self.card.cursor_front].fb else 0;
        var objs = [_]u32{ self.primary_plane.id, self.cursor_plane.id };
        var counts = [_]u32{ 1, 10 };
        var props: [11]u32 = undefined;
        props[0] = self.primary_plane.fb_id;
        @memcpy(props[1..11], &self.cursor_plane.props);
        var values: [11]u64 = undefined;
        values[0] = fb;
        if (with_cursor) @memcpy(values[1..11], &self.cursorPropValues(want_visible, want_fb));
        var request: Atomic = .{
            .flags = atomic_nonblock | page_flip_event,
            .count_objs = if (with_cursor) 2 else 1,
            .objs_ptr = @intFromPtr(&objs),
            .count_props_ptr = @intFromPtr(&counts),
            .props_ptr = @intFromPtr(&props),
            .prop_values_ptr = @intFromPtr(&values),
            .user_data = @intFromPtr(self),
        };
        if (!call(self.card.fd, ioctl.atomic, &request)) {
            self.modeset = false;
            return .failed;
        }
        self.flipping = true;
        self.cursor_commit = false;
        if (with_cursor) {
            self.cursor_dirty = false;
            self.cursor_shown = want_visible;
            self.cursor_committed_fb = want_fb;
            self.cursor_committed_x = self.cursor_x;
            self.cursor_committed_y = self.cursor_y;
        }
        return .flipping;
    }

    /// Places the cursor image's top-left corner, in this display's pixels.
    pub fn moveCursor(self: *Display, x: i32, y: i32) void {
        self.cursor_x = x;
        self.cursor_y = y;
        if (!self.card.active or !self.card.cursor_hardware) return;
        const want_visible = self.cursorVisible();
        const want_fb: u32 = if (want_visible) self.card.cursors[self.card.cursor_front].fb else 0;
        if (!self.cursor_dirty) {
            if (!want_visible and !self.cursor_shown) return;
            if (want_visible and self.cursor_shown and x == self.cursor_committed_x and y == self.cursor_committed_y and want_fb == self.cursor_committed_fb) return;
        }
        self.cursor_dirty = true;
        self.commitCursor();
    }

    fn commitCursor(self: *Display) void {
        if (!self.card.active or !self.modeset or self.flipping or !self.cursor_dirty or self.cursor_plane.id == 0) return;
        const want_visible = self.cursorVisible();
        const want_fb: u32 = if (want_visible) self.card.cursors[self.card.cursor_front].fb else 0;
        if (!want_visible and !self.cursor_shown) {
            self.cursor_dirty = false;
            return;
        }
        if (want_visible and self.cursor_shown and self.cursor_x == self.cursor_committed_x and self.cursor_y == self.cursor_committed_y and want_fb == self.cursor_committed_fb) {
            self.cursor_dirty = false;
            return;
        }
        var objs = [_]u32{self.cursor_plane.id};
        var counts = [_]u32{10};
        var props = self.cursor_plane.props;
        var values = self.cursorPropValues(want_visible, want_fb);
        var request: Atomic = .{
            .flags = atomic_nonblock | page_flip_event,
            .count_objs = 1,
            .objs_ptr = @intFromPtr(&objs),
            .count_props_ptr = @intFromPtr(&counts),
            .props_ptr = @intFromPtr(&props),
            .prop_values_ptr = @intFromPtr(&values),
            .user_data = @intFromPtr(self),
        };
        if (!call(self.card.fd, ioctl.atomic, &request)) return;
        self.flipping = true;
        self.cursor_commit = true;
        self.cursor_dirty = false;
        self.cursor_shown = want_visible;
        self.cursor_committed_fb = want_fb;
        self.cursor_committed_x = self.cursor_x;
        self.cursor_committed_y = self.cursor_y;
    }

    /// Turns the display off until the next frame sets its mode again.
    pub fn disable(self: *Display) void {
        if (!self.card.active) return;
        var request: Crtc = .{ .crtc_id = self.crtc };
        _ = call(self.card.fd, ioctl.set_crtc, &request);
        self.modeset = false;
        self.flipping = false;
        self.cursor_commit = false;
        self.cursor_shown = false;
    }

    fn flipped(self: *Display, event: *const VblankEvent) void {
        self.flip_time = .{ event.tv_sec, event.tv_usec };
        self.flip_sequence = event.sequence;
        self.flipping = false;
        const primary = !self.cursor_commit;
        self.cursor_commit = false;
        if (self.on_flip) |callback| callback(self.context, primary);
        if (self.cursor_dirty and !self.flipping) self.commitCursor();
    }

    /// Turns variable refresh on or off, as the CRTC's VRR_ENABLED property.
    pub fn setAdaptiveSync(self: *Display, enabled: bool) bool {
        if (enabled == self.vrr_enabled) return true;
        if (enabled and !self.vrr_capable) return false;
        const property = self.card.findProperty(self.crtc, object_crtc, "VRR_ENABLED") orelse return false;
        var request: SetProperty = .{ .value = @intFromBool(enabled), .prop_id = property.id, .obj_id = self.crtc, .obj_type = object_crtc };
        if (!call(self.card.fd, ioctl.set_object_property, &request)) return false;
        self.vrr_enabled = enabled;
        return true;
    }

    /// Switches to another of the connector's modes at the next frame.
    pub fn setMode(self: *Display, mode: ModeInfo) void {
        if (std.meta.eql(mode, self.mode)) return;
        self.mode = mode;
        self.modeset = false;
    }

    fn destroy(self: *Display) void {
        self.card.allocator.free(self.modes);
    }
};

/// A DRM device opened through the session, with its connected displays.
pub const Card = struct {
    allocator: std.mem.Allocator,
    fd: i32,
    displays: std.ArrayList(*Display) = .empty,
    /// False while the session is switched away; flips wait for resumption.
    active: bool = true,
    /// Double-buffered cursor image shared by every display.
    cursors: [2]Dumb = .{ .{}, .{} },
    cursor_front: usize = 0,
    cursor_size: [2]u32 = .{ 64, 64 },
    cursor_hotspot: [2]i32 = .{ 0, 0 },
    cursor_visible: bool = false,
    /// Whether framebuffers may carry layout modifiers.
    modifiers: bool = false,
    /// False when software cursor is requested (e.g. rotated displays or tests).
    cursor_hardware: bool = true,
    /// Called before a display that was unplugged is freed.
    on_remove: ?*const fn (?*anyopaque, *Display) void = null,
    remove_context: ?*anyopaque = null,

    pub fn cursorBuffer(self: *const Card) *const Dumb {
        return &self.cursors[self.cursor_front];
    }

    pub fn init(allocator: std.mem.Allocator, fd: i32) Error!*Card {
        var cap: GetCap = .{ .capability = cap_dumb_buffer };
        if (!call(fd, ioctl.get_cap, &cap) or cap.value == 0) return error.DrmFailed;
        var atomic_cap: SetClientCap = .{ .capability = client_cap_atomic, .value = 1 };
        if (!call(fd, ioctl.set_client_cap, &atomic_cap)) return error.DrmFailed;
        const self = try allocator.create(Card);
        self.* = .{ .allocator = allocator, .fd = fd };
        var modifiers: GetCap = .{ .capability = cap_addfb2_modifiers };
        self.modifiers = call(fd, ioctl.get_cap, &modifiers) and modifiers.value != 0;
        var width: GetCap = .{ .capability = cap_cursor_width };
        var height: GetCap = .{ .capability = cap_cursor_height };
        if (call(fd, ioctl.get_cap, &width) and call(fd, ioctl.get_cap, &height) and width.value > 0 and height.value > 0) {
            self.cursor_size = .{ @intCast(@min(width.value, 256)), @intCast(@min(height.value, 256)) };
        }
        return self;
    }

    pub fn deinit(self: *Card) void {
        for (&self.cursors) |*buffer| buffer.destroy(self.fd);
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
            const planes = self.findPlanes(crtc.index);
            const display = try a.create(Display);
            errdefer a.destroy(display);
            display.* = .{ .card = self, .connector = connector_id, .crtc = crtc.id, .primary_plane = planes.primary, .cursor_plane = planes.cursor, .mode = mode, .mm_width = info.header.mm_width, .mm_height = info.header.mm_height, .modes = try a.dupe(ModeInfo, info.modes) };
            display.name_len = connectorName(&display.name_buffer, info.header.connector_type, info.header.connector_type_id).len;
            if (self.findProperty(connector_id, object_connector, "vrr_capable")) |property| display.vrr_capable = property.value != 0;
            if (self.findProperty(crtc.id, object_crtc, "VRR_ENABLED")) |property| display.vrr_enabled = property.value != 0;
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

    fn freeCrtc(self: *Card, encoder_ids: []const u32, crtcs: []const u32) ?struct { id: u32, index: u5 } {
        for (encoder_ids) |encoder_id| {
            var encoder: Encoder = .{ .encoder_id = encoder_id };
            if (!call(self.fd, ioctl.get_encoder, &encoder)) continue;
            for (crtcs, 0..) |crtc, index| {
                if (index >= 32) break;
                if (encoder.possible_crtcs & (@as(u32, 1) << @intCast(index)) == 0) continue;
                const used = for (self.displays.items) |display| {
                    if (display.crtc == crtc) break true;
                } else false;
                if (!used) return .{ .id = crtc, .index = @intCast(index) };
            }
        }
        return null;
    }

    const Planes = struct { primary: PrimaryPlane = .{}, cursor: CursorPlane = .{} };

    /// Finds the primary and cursor planes compatible with `crtc_index`, with their atomic property IDs.
    fn findPlanes(self: *Card, crtc_index: u5) Planes {
        var result: Planes = .{};
        var resources: PlaneResources = .{};
        if (!call(self.fd, ioctl.get_plane_resources, &resources) or resources.count_planes == 0) return result;
        const ids = self.allocator.alloc(u32, resources.count_planes) catch return result;
        defer self.allocator.free(ids);
        resources = .{ .plane_id_ptr = @intFromPtr(ids.ptr), .count_planes = @intCast(ids.len) };
        if (!call(self.fd, ioctl.get_plane_resources, &resources)) return result;
        const mask = @as(u32, 1) << crtc_index;
        for (ids[0..@min(ids.len, resources.count_planes)]) |plane_id| {
            var plane: Plane = .{ .plane_id = plane_id };
            if (!call(self.fd, ioctl.get_plane, &plane)) continue;
            if (plane.possible_crtcs & mask == 0) continue;
            const kind = (self.findProperty(plane_id, object_plane, "type") orelse continue).value;
            if (kind == plane_type_primary and result.primary.id == 0) {
                const used = for (self.displays.items) |display| {
                    if (display.primary_plane.id == plane_id) break true;
                } else false;
                if (!used) if (self.findProperty(plane_id, object_plane, "FB_ID")) |fb_prop| {
                    result.primary = .{ .id = plane_id, .fb_id = fb_prop.id };
                };
            } else if (kind == plane_type_cursor and result.cursor.id == 0) {
                const used = for (self.displays.items) |display| {
                    if (display.cursor_plane.id == plane_id) break true;
                } else false;
                if (!used) {
                    const names = [_][]const u8{ "FB_ID", "CRTC_ID", "CRTC_X", "CRTC_Y", "CRTC_W", "CRTC_H", "SRC_X", "SRC_Y", "SRC_W", "SRC_H" };
                    var props: [10]u32 = @splat(0);
                    var complete = true;
                    for (names, 0..) |name, i| {
                        if (self.findProperty(plane_id, object_plane, name)) |prop| {
                            props[i] = prop.id;
                        } else {
                            complete = false;
                            break;
                        }
                    }
                    if (complete) result.cursor = .{ .id = plane_id, .props = props };
                }
            }
        }
        return result;
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

    /// A DRM object's property by name, with its current value.
    pub fn findProperty(self: *Card, object: u32, kind: u32, name: []const u8) ?struct { id: u32, value: u64 } {
        var ids: [64]u32 = undefined;
        var values: [64]u64 = undefined;
        var request: ObjectProperties = .{ .props_ptr = @intFromPtr(&ids), .prop_values_ptr = @intFromPtr(&values), .count_props = ids.len, .obj_id = object, .obj_type = kind };
        if (!call(self.fd, ioctl.object_properties, &request)) return null;
        for (ids[0..@min(request.count_props, ids.len)], values[0..@min(request.count_props, ids.len)]) |id, value| {
            var property: Property = .{ .prop_id = id };
            if (!call(self.fd, ioctl.get_property, &property)) continue;
            const length = std.mem.indexOfScalar(u8, &property.name, 0) orelse property.name.len;
            if (std.mem.eql(u8, property.name[0..length], name)) return .{ .id = id, .value = value };
        }
        return null;
    }

    pub const FramePlane = struct { handle: u32, stride: u32, offset: u32 };

    /// Registers a GPU buffer as a framebuffer, for `Display.show`. Tiled
    /// layouts (NVIDIA's always are) need their modifier, where the driver
    /// takes modifiers; DRM_FORMAT_MOD_INVALID keeps the implicit layout.
    pub fn addFramebuffer(self: *Card, width: u32, height: u32, format: u32, planes: []const FramePlane, modifier: u64) ?u32 {
        var command: FbCommand2 = .{ .width = width, .height = height, .pixel_format = format };
        for (planes[0..@min(planes.len, 4)], 0..) |plane, index| {
            command.handles[index] = plane.handle;
            command.pitches[index] = plane.stride;
            command.offsets[index] = plane.offset;
            if (modifier != modifier_invalid and self.modifiers) command.modifier[index] = modifier;
        }
        if (modifier != modifier_invalid and self.modifiers) command.flags = fb_modifiers;
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
            const next = 1 - self.cursor_front;
            if (self.cursors[next].handle == 0) self.cursors[next] = Dumb.create(self.fd, self.cursor_size[0], self.cursor_size[1], format_argb8888) catch return;
            const memory = self.cursors[next].memory.?;
            @memset(memory[0..self.cursors[next].size], 0);
            const height = image.len / width;
            for (0..@min(height, self.cursor_size[1])) |row| {
                const line: [*]u32 = @ptrCast(@alignCast(memory + row * self.cursors[next].pitch));
                const count = @min(width, self.cursor_size[0]);
                @memcpy(line[0..count], image[row * width ..][0..count]);
            }
            self.cursor_front = next;
            self.cursor_hotspot = hotspot;
            self.cursor_visible = true;
        };
        // Without the plane, the image is only kept for drawing into frames.
        if (!self.active or !self.cursor_hardware) return;
        for (self.displays.items) |display| {
            display.cursor_dirty = true;
            display.commitCursor();
        }
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
                    display.flipped(event);
                    break;
                };
            }
            offset += event.length;
        }
    }

    /// The session was switched away: flips stop and master is released by the session.
    pub fn pause(self: *Card) void {
        self.active = false;
        for (self.displays.items) |display| {
            display.flipping = false;
            display.cursor_commit = false;
        }
    }

    /// The session is back: every display sets its mode again.
    pub fn resumeWith(self: *Card, fd: i32) void {
        self.fd = fd;
        self.active = true;
        for (self.displays.items) |display| {
            display.modeset = false;
            display.cursor_shown = false;
        }
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
        .{ SetClientCap, c.struct_drm_set_client_cap },
        .{ PlaneResources, c.struct_drm_mode_get_plane_res },
        .{ Plane, c.struct_drm_mode_get_plane },
        .{ Atomic, c.struct_drm_mode_atomic },
        .{ FbCommand2, c.struct_drm_mode_fb_cmd2 },
        .{ ObjectProperties, c.struct_drm_mode_obj_get_properties },
        .{ Property, c.struct_drm_mode_get_property },
        .{ SetProperty, c.struct_drm_mode_obj_set_property },
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
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_MODE_CREATE_DUMB), ioctl.create_dumb);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_MODE_MAP_DUMB), ioctl.map_dumb);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_MODE_ADDFB), ioctl.add_fb);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_SET_MASTER), ioctl.set_master);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_GET_CAP), ioctl.get_cap);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_SET_CLIENT_CAP), ioctl.set_client_cap);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_MODE_GETPLANERESOURCES), ioctl.get_plane_resources);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_MODE_GETPLANE), ioctl.get_plane);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_MODE_ATOMIC), ioctl.atomic);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_MODE_ADDFB2), ioctl.add_fb2);
    try std.testing.expectEqual(@as(u64, c.DRM_CAP_ADDFB2_MODIFIERS), cap_addfb2_modifiers);
    try std.testing.expectEqual(@as(u32, c.DRM_MODE_FB_MODIFIERS), fb_modifiers);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_MODE_GETPROPERTY), ioctl.get_property);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_MODE_OBJ_GETPROPERTIES), ioctl.object_properties);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_MODE_OBJ_SETPROPERTY), ioctl.set_object_property);
    try std.testing.expectEqual(@as(u32, c.DRM_MODE_OBJECT_CRTC), object_crtc);
    try std.testing.expectEqual(@as(u32, c.DRM_MODE_OBJECT_CONNECTOR), object_connector);
    try std.testing.expectEqual(@as(u32, c.DRM_MODE_OBJECT_PLANE), object_plane);
    try std.testing.expectEqual(@as(u64, c.DRM_CLIENT_CAP_ATOMIC), client_cap_atomic);
    try std.testing.expectEqual(@as(u32, c.DRM_MODE_ATOMIC_NONBLOCK), atomic_nonblock);
    try std.testing.expectEqual(@as(u32, c.DRM_MODE_PAGE_FLIP_EVENT), page_flip_event);
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

test "atomic cursor properties encode signed coordinates and 16.16 source sizes" {
    var card: Card = .{ .allocator = std.testing.allocator, .fd = -1, .cursor_size = .{ 256, 256 }, .cursor_visible = true };
    var display: Display = .{
        .card = &card,
        .connector = 1,
        .crtc = 42,
        .cursor_plane = .{ .id = 7 },
        .mode = .{ .hdisplay = 2880, .vdisplay = 1800 },
        .cursor_x = -8,
        .cursor_y = -4,
    };
    try std.testing.expect(display.cursorVisible());
    const shown = display.cursorPropValues(true, 99);
    try std.testing.expectEqual(@as(u64, 99), shown[0]);
    try std.testing.expectEqual(@as(u64, 42), shown[1]);
    try std.testing.expectEqual(@as(i64, -8), @as(i64, @bitCast(shown[2])));
    try std.testing.expectEqual(@as(i64, -4), @as(i64, @bitCast(shown[3])));
    try std.testing.expectEqual(@as(u64, 256), shown[4]);
    try std.testing.expectEqual(@as(u64, 256), shown[5]);
    try std.testing.expectEqual(@as(u64, 0), shown[6]);
    try std.testing.expectEqual(@as(u64, 0), shown[7]);
    try std.testing.expectEqual(@as(u64, 256 << 16), shown[8]);
    try std.testing.expectEqual(@as(u64, 256 << 16), shown[9]);

    const hidden = display.cursorPropValues(false, 0);
    for (hidden) |value| try std.testing.expectEqual(@as(u64, 0), value);

    display.cursor_x = -256;
    try std.testing.expect(!display.cursorVisible());
    display.cursor_x = 2880;
    try std.testing.expect(!display.cursorVisible());
}

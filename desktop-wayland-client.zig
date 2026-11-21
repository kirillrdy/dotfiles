//! Typed Wayland client bindings over the native wire runtime, plus shared helpers.
const std = @import("std");
const libc = @import("desktop-libc.zig");
pub const wire = @import("wayland-wire");
pub const protocol = @import("wayland-client");

pub const ShmBuffer = struct {
    buffer: protocol.wl_buffer,
    memory: [*]u8,
    size: usize,

    /// Unmaps the pixels; the caller destroys `buffer` when the compositor is done with it.
    pub fn unmap(self: ShmBuffer) void {
        _ = libc.munmap(self.memory, self.size);
    }
};

/// One shared-memory frame linked into a caller-owned list and freed when the
/// compositor releases it.
pub const FrameBuffer = struct {
    allocator: std.mem.Allocator,
    head: *?*FrameBuffer,
    shm: ShmBuffer,
    next: ?*FrameBuffer,

    pub fn create(allocator: std.mem.Allocator, head: *?*FrameBuffer, shm: protocol.wl_shm, name: [*:0]const u8, width: u32, height: u32, format: u32) !*FrameBuffer {
        const frame = try shmBuffer(shm, name, width, height, format);
        errdefer {
            frame.buffer.destroy();
            frame.unmap();
        }
        const self = try allocator.create(FrameBuffer);
        self.* = .{ .allocator = allocator, .head = head, .shm = frame, .next = head.* };
        head.* = self;
        frame.buffer.listen(FrameBuffer, self, released);
        return self;
    }

    fn released(self: *FrameBuffer, _: protocol.wl_buffer, _: protocol.wl_buffer.Event) void {
        self.destroy();
    }

    pub fn destroy(self: *FrameBuffer) void {
        var link = self.head;
        while (link.* != self) link = &link.*.?.next;
        link.* = self.next;
        self.shm.buffer.destroy();
        self.shm.unmap();
        self.allocator.destroy(self);
    }

    pub fn destroyAll(head: *?*FrameBuffer) void {
        while (head.*) |buf| buf.destroy();
    }
};

/// A memfd-backed buffer of `width` x `height` 32-bit pixels in `format`.
pub fn shmBuffer(shm: protocol.wl_shm, name: [*:0]const u8, width: u32, height: u32, format: u32) !ShmBuffer {
    return shmBufferLayout(shm, name, @as(usize, width) * height * 4, width, height, width * 4, format);
}

/// Like `shmBuffer` with an explicit row stride and a mapping of at least `size` bytes.
pub fn shmBufferLayout(shm: protocol.wl_shm, name: [*:0]const u8, size: usize, width: u32, height: u32, stride: u32, format: u32) !ShmBuffer {
    if (width == 0 or height == 0 or width > 16384 or height > 16384) return error.SharedMemory;
    if (size < @as(usize, stride) * height or size > std.math.maxInt(i32)) return error.SharedMemory;
    const fd = libc.memfd_create(name, libc.MFD_CLOEXEC);
    if (fd < 0) return error.SharedMemory;
    defer _ = libc.close(fd);
    if (libc.ftruncate(fd, @intCast(size)) != 0) return error.SharedMemory;
    const memory = libc.mmap(null, size, libc.PROT_READ | libc.PROT_WRITE, libc.MAP_SHARED, fd, 0);
    if (memory == libc.MAP_FAILED or memory == null) return error.SharedMemory;
    // The pool only lives long enough to carve out one buffer; the buffer keeps the memory.
    const pool = shm.create_pool(fd, @intCast(size));
    defer pool.destroy();
    const buffer = pool.create_buffer(0, @intCast(width), @intCast(height), @intCast(stride), format);
    return .{ .buffer = buffer, .memory = @ptrCast(memory.?), .size = size };
}

/// Forces semantic analysis of every non-generic declaration below `T`.
fn analyze(comptime T: type) void {
    @setEvalBranchQuota(1_000_000);
    inline for (@typeInfo(T).@"struct".decl_names) |name| {
        const value = @field(T, name);
        if (@TypeOf(value) == type) {
            if (@typeInfo(value) == .@"struct") analyze(value);
        } else if (@typeInfo(@TypeOf(value)) == .@"fn") {
            if (!@typeInfo(@TypeOf(value)).@"fn".is_generic) _ = &value;
        } else _ = &value;
    }
}

test "every generated protocol binding compiles" {
    comptime analyze(protocol);
}

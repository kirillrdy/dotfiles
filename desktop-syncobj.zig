//! DRM timeline synchronization objects without libdrm, for explicit sync
//! (linux-drm-syncobj-v1): importing clients' timelines, waiting for their
//! acquire points, and signalling release points from GPU fences.
const std = @import("std");
const linux = std.os.linux;

fn ioctlNumber(comptime nr: u8, comptime T: type) u32 {
    return 3 << 30 | @as(u32, @sizeOf(T)) << 16 | @as(u32, 'd') << 8 | nr;
}

pub const Create = extern struct { handle: u32 = 0, flags: u32 = 0 };
pub const Destroy = extern struct { handle: u32 = 0, pad: u32 = 0 };
pub const Handle = extern struct { handle: u32 = 0, flags: u32 = 0, fd: i32 = -1, pad: u32 = 0, point: u64 = 0 };
pub const Transfer = extern struct { src_handle: u32 = 0, dst_handle: u32 = 0, src_point: u64 = 0, dst_point: u64 = 0, flags: u32 = 0, pad: u32 = 0 };
pub const TimelineArray = extern struct { handles: u64 = 0, points: u64 = 0, count_handles: u32 = 0, flags: u32 = 0 };
pub const TimelineWait = extern struct { handles: u64 = 0, points: u64 = 0, timeout_nsec: i64 = 0, count_handles: u32 = 0, flags: u32 = 0, first_signaled: u32 = 0, pad: u32 = 0, deadline_nsec: u64 = 0 };

pub const ioctl = struct {
    pub const create = ioctlNumber(0xbf, Create);
    pub const destroy = ioctlNumber(0xc0, Destroy);
    pub const handle_to_fd = ioctlNumber(0xc1, Handle);
    pub const fd_to_handle = ioctlNumber(0xc2, Handle);
    pub const timeline_wait = ioctlNumber(0xca, TimelineWait);
    pub const transfer = ioctlNumber(0xcc, Transfer);
    pub const timeline_signal = ioctlNumber(0xcd, TimelineArray);
};

const export_sync_file: u32 = 1 << 0;
const import_sync_file: u32 = 1 << 0;
const wait_for_submit: u32 = 1 << 1;
const wait_available: u32 = 1 << 2;
pub const cap_syncobj_timeline: u64 = 0x14;

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

/// Whether the device supports timeline syncobjs.
pub fn supported(fd: i32) bool {
    const GetCap = extern struct { capability: u64, value: u64 };
    var cap: GetCap = .{ .capability = cap_syncobj_timeline, .value = 0 };
    return call(fd, 3 << 30 | @as(u32, @sizeOf(GetCap)) << 16 | @as(u32, 'd') << 8 | 0x0c, &cap) and cap.value != 0;
}

/// A syncobj handle on a DRM device.
pub const Timeline = struct {
    device: i32,
    handle: u32,

    /// Takes a client's timeline descriptor.
    pub fn import(device: i32, fd: i32) ?Timeline {
        var request: Handle = .{ .fd = fd };
        if (!call(device, ioctl.fd_to_handle, &request)) return null;
        return .{ .device = device, .handle = request.handle };
    }

    pub fn create(device: i32) ?Timeline {
        var request: Create = .{};
        if (!call(device, ioctl.create, &request)) return null;
        return .{ .device = device, .handle = request.handle };
    }

    pub fn destroy(self: Timeline) void {
        var request: Destroy = .{ .handle = self.handle };
        _ = call(self.device, ioctl.destroy, &request);
    }

    /// Waits until `point` has a fence (submitted), up to `timeout_ns`, without
    /// waiting for the GPU work itself.
    pub fn waitSubmitted(self: Timeline, point: u64, timeout_ns: i64) bool {
        return self.wait(point, timeout_ns, wait_for_submit | wait_available);
    }

    /// Whether `point` has signalled, waiting up to `timeout_ns`.
    pub fn waitSignalled(self: Timeline, point: u64, timeout_ns: i64) bool {
        return self.wait(point, timeout_ns, wait_for_submit);
    }

    fn wait(self: Timeline, point: u64, timeout_ns: i64, flags: u32) bool {
        var handle = self.handle;
        var value = point;
        var now: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &now);
        const deadline = @as(i64, now.sec) * std.time.ns_per_s + now.nsec + timeout_ns;
        var request: TimelineWait = .{ .handles = @intFromPtr(&handle), .points = @intFromPtr(&value), .timeout_nsec = deadline, .count_handles = 1, .flags = flags };
        return call(self.device, ioctl.timeline_wait, &request);
    }

    /// A sync_file of the fence at `point`, for the GPU to wait on.
    pub fn exportPoint(self: Timeline, point: u64) ?i32 {
        const binary = create(self.device) orelse return null;
        defer binary.destroy();
        var move: Transfer = .{ .src_handle = self.handle, .src_point = point, .dst_handle = binary.handle };
        if (!call(self.device, ioctl.transfer, &move)) return null;
        var request: Handle = .{ .handle = binary.handle, .flags = export_sync_file };
        if (!call(self.device, ioctl.handle_to_fd, &request)) return null;
        return request.fd;
    }

    /// Makes `point` signal when the GPU fence in `sync_file` does.
    pub fn importPoint(self: Timeline, point: u64, sync_file: i32) bool {
        const binary = create(self.device) orelse return false;
        defer binary.destroy();
        var request: Handle = .{ .handle = binary.handle, .flags = import_sync_file, .fd = sync_file };
        if (!call(self.device, ioctl.fd_to_handle, &request)) return false;
        var move: Transfer = .{ .src_handle = binary.handle, .dst_handle = self.handle, .dst_point = point };
        return call(self.device, ioctl.transfer, &move);
    }

    /// Signals `point` now, from the CPU.
    pub fn signal(self: Timeline, point: u64) bool {
        var handle = self.handle;
        var value = point;
        var request: TimelineArray = .{ .handles = @intFromPtr(&handle), .points = @intFromPtr(&value), .count_handles = 1 };
        return call(self.device, ioctl.timeline_signal, &request);
    }
};

test "syncobj ioctl structures match the kernel headers" {
    const c = @import("drm-reference");
    inline for (.{
        .{ Create, c.struct_drm_syncobj_create },
        .{ Destroy, c.struct_drm_syncobj_destroy },
        .{ Handle, c.struct_drm_syncobj_handle },
        .{ Transfer, c.struct_drm_syncobj_transfer },
        .{ TimelineArray, c.struct_drm_syncobj_timeline_array },
        .{ TimelineWait, c.struct_drm_syncobj_timeline_wait },
    }) |pair| {
        try std.testing.expectEqual(@sizeOf(pair[1]), @sizeOf(pair[0]));
        inline for (@typeInfo(pair[0]).@"struct".field_names) |field| {
            if (@hasField(pair[1], field)) try std.testing.expectEqual(@offsetOf(pair[1], field), @offsetOf(pair[0], field));
        }
    }
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_SYNCOBJ_CREATE), ioctl.create);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_SYNCOBJ_DESTROY), ioctl.destroy);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_SYNCOBJ_HANDLE_TO_FD), ioctl.handle_to_fd);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_SYNCOBJ_FD_TO_HANDLE), ioctl.fd_to_handle);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_SYNCOBJ_TIMELINE_WAIT), ioctl.timeline_wait);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_SYNCOBJ_TRANSFER), ioctl.transfer);
    try std.testing.expectEqual(@as(u32, c.DRM_IOCTL_SYNCOBJ_TIMELINE_SIGNAL), ioctl.timeline_signal);
    try std.testing.expectEqual(@as(u32, c.DRM_SYNCOBJ_HANDLE_TO_FD_FLAGS_EXPORT_SYNC_FILE), export_sync_file);
    try std.testing.expectEqual(@as(u32, c.DRM_SYNCOBJ_FD_TO_HANDLE_FLAGS_IMPORT_SYNC_FILE), import_sync_file);
    try std.testing.expectEqual(@as(u32, c.DRM_SYNCOBJ_WAIT_FLAGS_WAIT_FOR_SUBMIT), wait_for_submit);
    try std.testing.expectEqual(@as(u32, c.DRM_SYNCOBJ_WAIT_FLAGS_WAIT_AVAILABLE), wait_available);
    try std.testing.expectEqual(@as(u64, c.DRM_CAP_SYNCOBJ_TIMELINE), cap_syncobj_timeline);
}

test "integration: timeline points signal, export and import on every GPU" {
    if (!@import("options").integration_tests) return error.SkipZigTest;
    var tested: usize = 0;
    var name_buffer: [32]u8 = undefined;
    for (128..136) |minor| {
        const path = std.fmt.bufPrintSentinel(&name_buffer, "/dev/dri/renderD{d}", .{minor}, 0) catch unreachable;
        const device = std.c.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true });
        if (device < 0) continue;
        defer _ = std.c.close(device);
        if (!supported(device)) {
            std.debug.print("{s}: no timeline syncobjs\n", .{path});
            continue;
        }
        // A client's timeline, shared as a descriptor.
        const client = Timeline.create(device) orelse return error.Create;
        defer client.destroy();
        var shared: Handle = .{ .handle = client.handle };
        try std.testing.expect(call(device, ioctl.handle_to_fd, &shared));
        const imported = Timeline.import(device, shared.fd) orelse return error.Import;
        _ = std.c.close(shared.fd);
        defer imported.destroy();
        // An unsubmitted acquire point is not waited on forever.
        try std.testing.expect(!imported.waitSubmitted(1, 10 * std.time.ns_per_ms));
        try std.testing.expect(client.signal(1));
        try std.testing.expect(imported.waitSubmitted(1, std.time.ns_per_s));
        // Its fence, as the renderer waits on it, signals a release point.
        const fence = imported.exportPoint(1) orelse return error.Export;
        defer _ = std.c.close(fence);
        try std.testing.expect(imported.importPoint(2, fence));
        try std.testing.expect(client.waitSignalled(2, std.time.ns_per_s));
        std.debug.print("{s}: timeline points work\n", .{path});
        tested += 1;
    }
    if (tested == 0) return error.SkipZigTest;
}

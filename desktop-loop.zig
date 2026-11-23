//! The desktop's event loop, in Zig, with the semantics of GLib's default main
//! context that the desktop used before: timeouts, idle callbacks, descriptor
//! watches and Unix signals, dispatched by `iteration`. Sources may be added
//! and removed from any thread; callbacks run on the thread that iterates.
//!
//! Like GLib, a callback returning 0 removes its source, idle callbacks run
//! only when nothing else is ready, and a source being dispatched is not
//! dispatched again by a nested iteration.
//!
//! Also here: Cancellable and Task, the cancellation and worker-thread
//! primitives the loop's users share.
const std = @import("std");
const linux = std.os.linux;
const util = @import("desktop-util.zig");

pub const IN: u32 = 1;
pub const PRI: u32 = 2;
pub const OUT: u32 = 4;
pub const ERR: u32 = 8;
pub const HUP: u32 = 16;
pub const NVAL: u32 = 32;

/// Returns nonzero to keep the source.
pub const SourceFn = *const fn (?*anyopaque) callconv(.c) c_int;
/// Receives the descriptor and the conditions that occurred.
pub const FdFn = *const fn (c_int, c_uint, ?*anyopaque) callconv(.c) c_int;

const Source = struct {
    id: u32,
    kind: union(enum) {
        timeout: struct { interval_us: i64, deadline: i64 },
        idle,
        fd: struct { fd: c_int, events: u32 },
        signal: u6,
    },
    callback: union { plain: SourceFn, fd: FdFn },
    data: ?*anyopaque,
    removed: bool = false,
    in_call: bool = false,
};

const allocator = std.heap.smp_allocator;

const Mutex = @import("desktop-util.zig").Mutex;

var mutex: Mutex = .{};
var sources: std.ArrayList(*Source) = .empty;
var next_id: u32 = 1;
/// Wakes a blocked iteration when sources change or a signal arrives.
var wake_fd: std.atomic.Value(i32) = .init(-1);
var signal_pending: [65]std.atomic.Value(bool) = @splat(.init(false));
var signal_refs: [65]u32 = @splat(0);

fn wakeFd() i32 {
    const current = wake_fd.load(.acquire);
    if (current >= 0) return current;
    const opened = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(opened) != .SUCCESS) return -1;
    const fd: i32 = @intCast(opened);
    if (wake_fd.cmpxchgStrong(-1, fd, .acq_rel, .acquire)) |existing| {
        _ = linux.close(fd);
        return existing;
    }
    return fd;
}

fn wake() void {
    const fd = wakeFd();
    if (fd < 0) return;
    const one: u64 = 1;
    _ = linux.write(fd, std.mem.asBytes(&one), 8);
}

fn add(source: Source) u32 {
    const owned = allocator.create(Source) catch @panic("out of memory");
    mutex.lock();
    owned.* = source;
    owned.id = next_id;
    next_id +%= 1;
    if (next_id == 0) next_id = 1;
    sources.append(allocator, owned) catch @panic("out of memory");
    mutex.unlock();
    wake();
    return owned.id;
}

/// Calls `callback` every `ms` milliseconds until it returns 0.
pub fn timeout(ms: u32, callback: SourceFn, data: ?*anyopaque) u32 {
    const interval: i64 = @as(i64, ms) * std.time.us_per_ms;
    return add(.{ .id = 0, .kind = .{ .timeout = .{ .interval_us = interval, .deadline = util.monotonicTime() + interval } }, .callback = .{ .plain = callback }, .data = data });
}

pub fn timeoutSeconds(seconds: u32, callback: SourceFn, data: ?*anyopaque) u32 {
    return timeout(seconds *| 1000, callback, data);
}

/// Calls `callback` whenever nothing else is ready, until it returns 0.
pub fn idle(callback: SourceFn, data: ?*anyopaque) u32 {
    return add(.{ .id = 0, .kind = .idle, .callback = .{ .plain = callback }, .data = data });
}

/// Calls `callback` when `fd` reports any of `events`, or an error or hangup.
pub fn watch(fd: c_int, events: u32, callback: FdFn, data: ?*anyopaque) u32 {
    return add(.{ .id = 0, .kind = .{ .fd = .{ .fd = fd, .events = events } }, .callback = .{ .fd = callback }, .data = data });
}

/// Calls `callback` on the loop after the process receives `signum`.
pub fn signal(signum: u6, callback: SourceFn, data: ?*anyopaque) u32 {
    _ = wakeFd();
    mutex.lock();
    signal_refs[signum] += 1;
    const first = signal_refs[signum] == 1;
    mutex.unlock();
    if (first) {
        var action: linux.Sigaction = .{ .handler = .{ .handler = &caught }, .mask = linux.sigemptyset(), .flags = linux.SA.RESTART | linux.SA.NOCLDSTOP };
        _ = linux.sigaction(@fromBackingInt(@intCast(signum)), &action, null);
    }
    return add(.{ .id = 0, .kind = .{ .signal = signum }, .callback = .{ .plain = callback }, .data = data });
}

fn caught(sig: linux.SIG) callconv(.c) void {
    const number: usize = @intCast(@backingInt(sig));
    if (number < signal_pending.len) signal_pending[number].store(true, .release);
    const fd = wake_fd.load(.acquire);
    if (fd >= 0) {
        const one: u64 = 1;
        _ = linux.write(fd, std.mem.asBytes(&one), 8);
    }
}

/// Removes a source; returns whether it existed. Safe from inside its own callback.
pub fn remove(id: u32) bool {
    mutex.lock();
    const index = for (sources.items, 0..) |source, i| {
        if (source.id == id and !source.removed) break i;
    } else {
        mutex.unlock();
        return false;
    };
    const source = sources.items[index];
    source.removed = true;
    const restore = if (source.kind == .signal) releaseSignal(source.kind.signal) else null;
    if (!source.in_call) {
        _ = sources.swapRemove(index);
        allocator.destroy(source);
    }
    mutex.unlock();
    if (restore) |signum| restoreSignal(signum);
    wake();
    return true;
}

/// Drops a signal watch reference; returns the signal when its default action should return.
fn releaseSignal(signum: u6) ?u6 {
    signal_refs[signum] -= 1;
    return if (signal_refs[signum] == 0) signum else null;
}

fn restoreSignal(signum: u6) void {
    var action: linux.Sigaction = .{ .handler = .{ .handler = linux.SIG.DFL }, .mask = linux.sigemptyset(), .flags = 0 };
    _ = linux.sigaction(@fromBackingInt(@intCast(signum)), &action, null);
}

const Ready = struct { id: u32, conditions: u32 = 0 };

/// Waits for and dispatches ready sources once; returns whether any callback ran.
pub fn iteration(may_block: bool) bool {
    var pollfds: std.ArrayList(linux.pollfd) = .empty;
    defer pollfds.deinit(allocator);
    var owners: std.ArrayList(u32) = .empty;
    defer owners.deinit(allocator);
    const wake_descriptor = wakeFd();
    pollfds.append(allocator, .{ .fd = wake_descriptor, .events = linux.POLL.IN, .revents = 0 }) catch return false;
    owners.append(allocator, 0) catch return false;

    mutex.lock();
    var wait_ms: i32 = if (may_block) -1 else 0;
    const now = util.monotonicTime();
    for (sources.items) |source| {
        if (source.removed or source.in_call) continue;
        switch (source.kind) {
            .idle => wait_ms = 0,
            .timeout => |value| {
                const remaining: i64 = @max(0, value.deadline - now);
                const ms: i32 = @intCast(@min(std.math.maxInt(i32), @divFloor(remaining + std.time.us_per_ms - 1, std.time.us_per_ms)));
                if (wait_ms < 0 or ms < wait_ms) wait_ms = ms;
            },
            .fd => |value| {
                pollfds.append(allocator, .{ .fd = value.fd, .events = @intCast(value.events & (IN | PRI | OUT)), .revents = 0 }) catch {};
                owners.append(allocator, source.id) catch {};
            },
            .signal => |signum| if (signal_pending[signum].load(.acquire)) {
                wait_ms = 0;
            },
        }
    }
    mutex.unlock();

    const polled = linux.poll(pollfds.items.ptr, @intCast(pollfds.items.len), wait_ms);
    const poll_ok = linux.errno(polled) == .SUCCESS;
    if (poll_ok and pollfds.items[0].revents != 0) {
        var count: u64 = 0;
        _ = linux.read(wake_descriptor, std.mem.asBytes(&count), 8);
    }

    var ready: std.ArrayList(Ready) = .empty;
    defer ready.deinit(allocator);
    mutex.lock();
    const after = util.monotonicTime();
    if (poll_ok) for (pollfds.items[1..], owners.items[1..]) |entry, id| {
        if (entry.revents != 0) ready.append(allocator, .{ .id = id, .conditions = @intCast(entry.revents) }) catch {};
    };
    var fired: [65]bool = @splat(false);
    for (&fired, 0..) |*flag, signum| flag.* = signal_pending[signum].swap(false, .acq_rel);
    for (sources.items) |source| {
        if (source.removed or source.in_call) continue;
        switch (source.kind) {
            .timeout => |value| if (value.deadline <= after) ready.append(allocator, .{ .id = source.id }) catch {},
            .signal => |signum| if (fired[signum]) ready.append(allocator, .{ .id = source.id }) catch {},
            else => {},
        }
    }
    // Idle callbacks have the lowest priority.
    if (ready.items.len == 0) for (sources.items) |source| {
        if (source.kind == .idle and !source.removed and !source.in_call) ready.append(allocator, .{ .id = source.id }) catch {};
    };
    mutex.unlock();

    var dispatched = false;
    for (ready.items) |item| {
        if (dispatch(item)) dispatched = true;
    }
    return dispatched;
}

fn dispatch(item: Ready) bool {
    mutex.lock();
    const source = for (sources.items) |candidate| {
        if (candidate.id == item.id) break candidate;
    } else {
        mutex.unlock();
        return false;
    };
    if (source.removed or source.in_call) {
        mutex.unlock();
        return false;
    }
    source.in_call = true;
    mutex.unlock();

    const keep = switch (source.kind) {
        .fd => |value| source.callback.fd(value.fd, item.conditions, source.data),
        else => source.callback.plain(source.data),
    } != 0;

    mutex.lock();
    source.in_call = false;
    var restore: ?u6 = null;
    if (source.removed or !keep) {
        if (!source.removed and source.kind == .signal) restore = releaseSignal(source.kind.signal);
        source.removed = true;
        for (sources.items, 0..) |candidate, i| if (candidate == source) {
            _ = sources.swapRemove(i);
            break;
        };
        allocator.destroy(source);
    } else if (source.kind == .timeout) {
        source.kind.timeout.deadline = util.monotonicTime() + source.kind.timeout.interval_us;
    }
    mutex.unlock();
    if (restore) |signum| restoreSignal(signum);
    return true;
}

/// Sleeps the calling thread.
pub fn sleep(microseconds: u64) void {
    var request: linux.timespec = .{ .sec = @intCast(microseconds / std.time.us_per_s), .nsec = @intCast((microseconds % std.time.us_per_s) * std.time.ns_per_us) };
    while (true) {
        var remaining: linux.timespec = undefined;
        if (linux.errno(linux.nanosleep(&request, &remaining)) != .INTR) return;
        request = remaining;
    }
}

/// The header shared by reference-counted loop objects.
pub const Object = extern struct {
    refs: u32 = 1,
    finalize: *const fn (*Object) callconv(.c) void,
    /// Callbacks run once the last reference goes away.
    weak: ?*anyopaque = null,

    pub fn ref(self: *Object) *Object {
        _ = @atomicRmw(u32, &self.refs, .Add, 1, .acq_rel);
        return self;
    }

    pub fn unref(self: *Object) void {
        if (@atomicRmw(u32, &self.refs, .Sub, 1, .acq_rel) != 1) return;
        if (self.weak) |raw| {
            const list: *std.ArrayList(Weak) = @ptrCast(@alignCast(raw));
            for (list.items) |item| item.notify(item.data, self);
            list.deinit(allocator);
            allocator.destroy(list);
        }
        self.finalize(self);
    }

    /// Calls `notify` when the object is finalized.
    pub fn weakRef(self: *Object, notify: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void, data: ?*anyopaque) void {
        const list: *std.ArrayList(Weak) = if (self.weak) |raw| @ptrCast(@alignCast(raw)) else blk: {
            const created = allocator.create(std.ArrayList(Weak)) catch @panic("out of memory");
            created.* = .empty;
            self.weak = created;
            break :blk created;
        };
        list.append(allocator, .{ .notify = notify, .data = data }) catch @panic("out of memory");
    }

    const Weak = struct { notify: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void, data: ?*anyopaque };
};

/// A cancellation flag with callbacks, as GCancellable: callbacks run on the
/// cancelling thread, and connecting to a cancelled one runs the callback at once.
pub const Cancellable = extern struct {
    object: Object = .{ .finalize = &finalize },
    cancelled: u32 = 0,
    handlers: ?*anyopaque = null,

    pub const Handler = *const fn (?*Cancellable, ?*anyopaque) callconv(.c) void;
    const Entry = struct { id: u64, handler: Handler, data: ?*anyopaque };

    var handler_mutex: Mutex = .{};
    var next_handler: u64 = 1;

    pub fn create() *Cancellable {
        const self = allocator.create(Cancellable) catch @panic("out of memory");
        self.* = .{};
        return self;
    }

    fn finalize(object: *Object) callconv(.c) void {
        const self: *Cancellable = @fieldParentPtr("object", object);
        if (self.handlers) |raw| {
            const list: *std.ArrayList(Entry) = @ptrCast(@alignCast(raw));
            list.deinit(allocator);
            allocator.destroy(list);
        }
        allocator.destroy(self);
    }

    pub fn isCancelled(self: *const Cancellable) bool {
        return @atomicLoad(u32, &self.cancelled, .acquire) != 0;
    }

    pub fn cancel(self: *Cancellable) void {
        if (@atomicRmw(u32, &self.cancelled, .Xchg, 1, .acq_rel) != 0) return;
        _ = self.object.ref();
        defer self.object.unref();
        handler_mutex.lock();
        var copy: std.ArrayList(Entry) = .empty;
        defer copy.deinit(allocator);
        if (self.handlers) |raw| {
            const list: *std.ArrayList(Entry) = @ptrCast(@alignCast(raw));
            copy.appendSlice(allocator, list.items) catch {};
        }
        handler_mutex.unlock();
        for (copy.items) |entry| entry.handler(self, entry.data);
    }

    /// Adds a callback for cancellation; when already cancelled it runs now and 0 is returned.
    pub fn connect(self: *Cancellable, handler: Handler, data: ?*anyopaque) u64 {
        if (self.isCancelled()) {
            handler(self, data);
            return 0;
        }
        return self.listen(handler, data);
    }

    /// Adds a callback for a later cancellation only.
    pub fn listen(self: *Cancellable, handler: Handler, data: ?*anyopaque) u64 {
        handler_mutex.lock();
        defer handler_mutex.unlock();
        const list: *std.ArrayList(Entry) = if (self.handlers) |raw| @ptrCast(@alignCast(raw)) else blk: {
            const created = allocator.create(std.ArrayList(Entry)) catch @panic("out of memory");
            created.* = .empty;
            self.handlers = created;
            break :blk created;
        };
        const id = next_handler;
        next_handler += 1;
        list.append(allocator, .{ .id = id, .handler = handler, .data = data }) catch @panic("out of memory");
        return id;
    }

    pub fn disconnect(self: *Cancellable, id: u64) void {
        if (id == 0) return;
        handler_mutex.lock();
        defer handler_mutex.unlock();
        const list: *std.ArrayList(Entry) = @ptrCast(@alignCast(self.handlers orelse return));
        for (list.items, 0..) |entry, i| if (entry.id == id) {
            _ = list.orderedRemove(i);
            return;
        };
    }
};

/// Work run on its own thread, then completed on the loop, as GTask's
/// run_in_thread: the completion callback runs on the loop after the work
/// returns its result, and the task is released afterwards.
pub const Task = extern struct {
    object: Object = .{ .finalize = &finalize },
    callback: ?Completion,
    callback_data: ?*anyopaque,
    cancellable: ?*Cancellable,
    task_data: ?*anyopaque = null,
    task_data_destroy: ?Destroy = null,
    result: ?*anyopaque = null,
    result_destroy: ?Destroy = null,
    result_bool: bool = false,
    work: ?Work = null,

    pub const Completion = *const fn (?*anyopaque, ?*Task, ?*anyopaque) callconv(.c) void;
    pub const Work = *const fn (?*Task, ?*anyopaque, ?*anyopaque, ?*Cancellable) callconv(.c) void;
    pub const Destroy = *const fn (?*anyopaque) callconv(.c) void;

    pub fn create(cancellable: ?*Cancellable, callback: ?Completion, callback_data: ?*anyopaque) *Task {
        const self = allocator.create(Task) catch @panic("out of memory");
        self.* = .{ .callback = callback, .callback_data = callback_data, .cancellable = cancellable };
        if (cancellable) |value| _ = value.object.ref();
        return self;
    }

    fn finalize(object: *Object) callconv(.c) void {
        const self: *Task = @fieldParentPtr("object", object);
        if (self.task_data_destroy) |destroy| destroy(self.task_data);
        if (self.result_destroy) |destroy| destroy(self.result);
        if (self.cancellable) |value| value.object.unref();
        allocator.destroy(self);
    }

    pub fn runInThread(self: *Task, work: Work) void {
        self.work = work;
        _ = self.object.ref();
        const thread = std.Thread.spawn(.{}, run, .{self}) catch {
            // Without a thread the work runs here, still completing on the loop.
            run(self);
            return;
        };
        thread.detach();
    }

    fn run(self: *Task) void {
        self.work.?(self, null, self.task_data, self.cancellable);
        _ = idle(&complete, self);
    }

    fn complete(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Task = @ptrCast(@alignCast(data));
        if (self.callback) |callback| callback(null, self, self.callback_data);
        self.object.unref();
        return 0;
    }

    pub fn returnPointer(self: *Task, result: ?*anyopaque, destroy: ?Destroy) void {
        self.result = result;
        self.result_destroy = destroy;
    }

    pub fn returnBoolean(self: *Task, result: bool) void {
        self.result_bool = result;
    }

    /// Takes the pointer result; the caller now owns it.
    pub fn propagatePointer(self: *Task) ?*anyopaque {
        const result = self.result;
        self.result = null;
        self.result_destroy = null;
        return result;
    }

    pub fn propagateBoolean(self: *Task) bool {
        return self.result_bool;
    }
};

test "timeouts, idles, descriptors, removal and nested iteration" {
    const State = struct {
        ticks: u32 = 0,
        idles: u32 = 0,
        reads: u32 = 0,
        nested: bool = false,
        removed_id: u32 = 0,
        fn tick(data: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(data));
            self.ticks += 1;
            return @intFromBool(self.ticks < 3);
        }
        fn idled(data: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(data));
            self.idles += 1;
            // A nested iteration must not dispatch this source again.
            if (!self.nested) {
                self.nested = true;
                _ = iteration(false);
            }
            return 0;
        }
        fn readable(fd: c_int, conditions: c_uint, data: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(data));
            var byte: [8]u8 = undefined;
            _ = linux.read(fd, &byte, byte.len);
            std.debug.assert(conditions & IN != 0);
            self.reads += 1;
            return 1;
        }
        fn never(_: ?*anyopaque) callconv(.c) c_int {
            unreachable;
        }
    };
    var state: State = .{};
    _ = timeout(5, &State.tick, &state);
    _ = idle(&State.idled, &state);
    const doomed = timeout(1, &State.never, null);
    try std.testing.expect(remove(doomed));
    try std.testing.expect(!remove(doomed));
    var pipe: [2]linux.fd_t = undefined;
    _ = linux.pipe2(&pipe, .{ .CLOEXEC = true, .NONBLOCK = true });
    defer _ = linux.close(pipe[0]);
    defer _ = linux.close(pipe[1]);
    const reader = watch(pipe[0], IN, &State.readable, &state);
    _ = linux.write(pipe[1], "x", 1);
    while (state.ticks < 3 or state.reads == 0 or state.idles == 0) _ = iteration(true);
    try std.testing.expectEqual(@as(u32, 1), state.idles);
    try std.testing.expect(remove(reader));
    // Sources added from another thread wake a blocked iteration.
    const Wake = struct {
        fn fire(data: ?*anyopaque) callconv(.c) c_int {
            const flag: *bool = @ptrCast(@alignCast(data));
            flag.* = true;
            return 0;
        }
        fn later(flag: *bool) void {
            sleep(20 * std.time.us_per_ms);
            _ = idle(&fire, flag);
        }
    };
    var woken = false;
    const thread = try std.Thread.spawn(.{}, Wake.later, .{&woken});
    while (!woken) _ = iteration(true);
    thread.join();
}

test "signals, cancellation and worker tasks" {
    const Flags = struct {
        signalled: bool = false,
        cancelled: u32 = 0,
        finished: bool = false,
        result: bool = false,
        fn onSignal(data: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(data));
            self.signalled = true;
            return 1;
        }
        fn onCancel(_: ?*Cancellable, data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(data));
            self.cancelled += 1;
        }
        fn work(task: ?*Task, _: ?*anyopaque, data: ?*anyopaque, _: ?*Cancellable) callconv(.c) void {
            const input: *u32 = @ptrCast(@alignCast(data));
            task.?.returnBoolean(input.* == 42);
        }
        fn done(_: ?*anyopaque, task: ?*Task, data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(data));
            self.result = task.?.propagateBoolean();
            self.finished = true;
        }
    };
    var flags: Flags = .{};
    const id = signal(@intCast(@backingInt(linux.SIG.USR1)), &Flags.onSignal, &flags);
    _ = linux.kill(linux.getpid(), .USR1);
    while (!flags.signalled) _ = iteration(true);
    try std.testing.expect(remove(id));

    const cancellable = Cancellable.create();
    _ = cancellable.connect(&Flags.onCancel, &flags);
    const gone = cancellable.connect(&Flags.onCancel, &flags);
    cancellable.disconnect(gone);
    cancellable.cancel();
    cancellable.cancel();
    try std.testing.expectEqual(@as(u32, 1), flags.cancelled);
    try std.testing.expectEqual(@as(u64, 0), cancellable.connect(&Flags.onCancel, &flags));
    try std.testing.expectEqual(@as(u32, 2), flags.cancelled);

    var input: u32 = 42;
    const task = Task.create(cancellable, &Flags.done, &flags);
    task.task_data = &input;
    task.runInThread(&Flags.work);
    task.object.unref();
    cancellable.object.unref();
    while (!flags.finished) _ = iteration(true);
    try std.testing.expect(flags.result);
}

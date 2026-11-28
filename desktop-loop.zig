//! The desktop's event loop: timeouts, idle callbacks, descriptor watches and
//! Unix signals, dispatched by `iteration`. Sources may be added and removed
//! from any thread; callbacks run on the thread that iterates.
//!
//! Callbacks receive the context they were registered with and return whether
//! to keep their source. Idle callbacks run only when nothing else is ready,
//! and a source being dispatched is not dispatched again by a nested iteration.
//!
//! Also here: Cancellable, and `background` for work on a worker thread.
const std = @import("std");
const linux = std.os.linux;
const util = @import("desktop-util.zig");

pub const IN: u32 = 1;
pub const PRI: u32 = 2;
pub const OUT: u32 = 4;
pub const ERR: u32 = 8;
pub const HUP: u32 = 16;
pub const NVAL: u32 = 32;
pub const SIGINT: u6 = 2;
pub const SIGTERM: u6 = 15;

/// A registered callback with its context erased; returns whether to keep the source.
const Thunk = *const fn (data: ?*anyopaque, fd: c_int, conditions: u32) bool;

const Source = struct {
    id: u32,
    kind: union(enum) {
        timeout: struct { interval_us: i64, deadline: i64 },
        idle,
        fd: struct { fd: c_int, events: u32 },
        signal: u6,
    },
    callback: Thunk,
    data: ?*anyopaque,
    removed: bool = false,
    in_call: bool = false,
};

/// Converts a context (a pointer, or `{}` for none) to and from the loop's untyped slot.
fn toData(context: anytype) ?*anyopaque {
    return switch (@typeInfo(@TypeOf(context))) {
        .void => null,
        .optional => if (context) |value| @ptrCast(@constCast(value)) else null,
        else => @ptrCast(@constCast(context)),
    };
}
fn fromData(comptime Context: type, data: ?*anyopaque) Context {
    return switch (@typeInfo(Context)) {
        .void => {},
        .optional => @ptrCast(@alignCast(data)),
        else => @ptrCast(@alignCast(data.?)),
    };
}

/// Adapts `callback(context) bool` to the loop's thunk.
fn plain(comptime Context: type, comptime callback: anytype) Thunk {
    return &struct {
        fn call(data: ?*anyopaque, _: c_int, _: u32) bool {
            return callback(fromData(Context, data));
        }
    }.call;
}

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

fn add(io: std.Io, source: Source) u32 {
    const owned = allocator.create(Source) catch @panic("out of memory");
    mutex.lock(io);
    owned.* = source;
    owned.id = next_id;
    next_id +%= 1;
    if (next_id == 0) next_id = 1;
    sources.append(allocator, owned) catch @panic("out of memory");
    mutex.unlock(io);
    wake();
    return owned.id;
}

/// Calls `callback(context)` every `ms` milliseconds until it returns false.
pub fn timeout(io: std.Io, ms: u32, context: anytype, comptime callback: anytype) u32 {
    const interval: i64 = @as(i64, ms) * std.time.us_per_ms;
    return add(io, .{ .id = 0, .kind = .{ .timeout = .{ .interval_us = interval, .deadline = std.Io.Clock.awake.now(io).toMicroseconds() + interval } }, .callback = plain(@TypeOf(context), callback), .data = toData(context) });
}

pub fn timeoutSeconds(io: std.Io, seconds: u32, context: anytype, comptime callback: anytype) u32 {
    return timeout(io, seconds *| 1000, context, callback);
}

/// Calls `callback(context)` whenever nothing else is ready, until it returns false.
pub fn idle(io: std.Io, context: anytype, comptime callback: anytype) u32 {
    return add(io, .{ .id = 0, .kind = .idle, .callback = plain(@TypeOf(context), callback), .data = toData(context) });
}

/// Calls `callback(context, fd, conditions)` when `fd` reports any of `events`,
/// or an error or hangup, until it returns false.
pub fn watch(io: std.Io, fd: c_int, events: u32, context: anytype, comptime callback: anytype) u32 {
    const Context = @TypeOf(context);
    const thunk = &struct {
        fn call(data: ?*anyopaque, descriptor: c_int, conditions: u32) bool {
            return callback(fromData(Context, data), descriptor, conditions);
        }
    }.call;
    return add(io, .{ .id = 0, .kind = .{ .fd = .{ .fd = fd, .events = events } }, .callback = thunk, .data = toData(context) });
}

/// Calls `callback(context)` on the loop after the process receives `signum`.
pub fn signal(io: std.Io, signum: u6, context: anytype, comptime callback: anytype) u32 {
    _ = wakeFd();
    mutex.lock(io);
    signal_refs[signum] += 1;
    const first = signal_refs[signum] == 1;
    mutex.unlock(io);
    if (first) {
        var action: linux.Sigaction = .{ .handler = .{ .handler = &caught }, .mask = linux.sigemptyset(), .flags = linux.SA.RESTART | linux.SA.NOCLDSTOP };
        _ = linux.sigaction(@fromBackingInt(@intCast(signum)), &action, null);
    }
    return add(io, .{ .id = 0, .kind = .{ .signal = signum }, .callback = plain(@TypeOf(context), callback), .data = toData(context) });
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
pub fn remove(io: std.Io, id: u32) bool {
    mutex.lock(io);
    const index = for (sources.items, 0..) |source, i| {
        if (source.id == id and !source.removed) break i;
    } else {
        mutex.unlock(io);
        return false;
    };
    const source = sources.items[index];
    source.removed = true;
    const restore = if (source.kind == .signal) releaseSignal(source.kind.signal) else null;
    if (!source.in_call) {
        _ = sources.swapRemove(index);
        allocator.destroy(source);
    }
    mutex.unlock(io);
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
pub fn iteration(io: std.Io, may_block: bool) bool {
    var pollfds: std.ArrayList(linux.pollfd) = .empty;
    defer pollfds.deinit(allocator);
    var owners: std.ArrayList(u32) = .empty;
    defer owners.deinit(allocator);
    const wake_descriptor = wakeFd();
    pollfds.append(allocator, .{ .fd = wake_descriptor, .events = linux.POLL.IN, .revents = 0 }) catch return false;
    owners.append(allocator, 0) catch return false;

    mutex.lock(io);
    var wait_ms: i32 = if (may_block) -1 else 0;
    const now = std.Io.Clock.awake.now(io).toMicroseconds();
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
    mutex.unlock(io);

    const polled = linux.poll(pollfds.items.ptr, @intCast(pollfds.items.len), wait_ms);
    const poll_ok = linux.errno(polled) == .SUCCESS;
    if (poll_ok and pollfds.items[0].revents != 0) {
        var count: u64 = 0;
        _ = linux.read(wake_descriptor, std.mem.asBytes(&count), 8);
    }

    var ready: std.ArrayList(Ready) = .empty;
    defer ready.deinit(allocator);
    mutex.lock(io);
    const after = std.Io.Clock.awake.now(io).toMicroseconds();
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
    mutex.unlock(io);

    var dispatched = false;
    for (ready.items) |item| {
        if (dispatch(io, item)) dispatched = true;
    }
    return dispatched;
}

fn dispatch(io: std.Io, item: Ready) bool {
    mutex.lock(io);
    const source = for (sources.items) |candidate| {
        if (candidate.id == item.id) break candidate;
    } else {
        mutex.unlock(io);
        return false;
    };
    if (source.removed or source.in_call) {
        mutex.unlock(io);
        return false;
    }
    source.in_call = true;
    mutex.unlock(io);

    const keep = source.callback(source.data, if (source.kind == .fd) source.kind.fd.fd else -1, item.conditions);

    mutex.lock(io);
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
        source.kind.timeout.deadline = std.Io.Clock.awake.now(io).toMicroseconds() + source.kind.timeout.interval_us;
    }
    mutex.unlock(io);
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


/// A reference-counted cancellation flag with callbacks: callbacks run on the
/// cancelling thread, and connecting to a cancelled one runs the callback at once.
pub const Cancellable = struct {
    io: std.Io,
    refs: std.atomic.Value(u32) = .init(1),
    cancelled: std.atomic.Value(bool) = .init(false),
    /// Guarded by `handler_mutex`.
    handlers: std.ArrayList(Entry) = .empty,
    /// Run once the last reference goes away; guarded by `handler_mutex`.
    finalizers: std.ArrayList(Entry) = .empty,

    const Entry = struct { id: u64, call: *const fn (?*anyopaque) void, data: ?*anyopaque };

    var handler_mutex: Mutex = .{};
    var next_handler: u64 = 1;

    pub fn create(io: std.Io) *Cancellable {
        const self = allocator.create(Cancellable) catch @panic("out of memory");
        self.* = .{ .io = io };
        return self;
    }

    pub fn ref(self: *Cancellable) *Cancellable {
        _ = self.refs.fetchAdd(1, .acq_rel);
        return self;
    }

    pub fn unref(self: *Cancellable) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        for (self.finalizers.items) |entry| entry.call(entry.data);
        self.finalizers.deinit(allocator);
        self.handlers.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn isCancelled(self: *const Cancellable) bool {
        return self.cancelled.load(.acquire);
    }

    pub fn cancel(self: *Cancellable) void {
        if (self.cancelled.swap(true, .acq_rel)) return;
        _ = self.ref();
        defer self.unref();
        handler_mutex.lock(self.io);
        const copy = allocator.dupe(Entry, self.handlers.items) catch &.{};
        handler_mutex.unlock(self.io);
        defer allocator.free(copy);
        for (copy) |entry| entry.call(entry.data);
    }

    /// Calls `handler(context)` on cancellation, or now when already
    /// cancelled, in which case 0 is returned.
    pub fn connect(self: *Cancellable, context: anytype, comptime handler: anytype) u64 {
        if (self.isCancelled()) {
            handler(context);
            return 0;
        }
        return self.listen(context, handler);
    }

    /// Calls `handler(context)` on a later cancellation only.
    pub fn listen(self: *Cancellable, context: anytype, comptime handler: anytype) u64 {
        handler_mutex.lock(self.io);
        defer handler_mutex.unlock(self.io);
        const id = next_handler;
        next_handler += 1;
        self.handlers.append(allocator, makeEntry(id, context, handler)) catch @panic("out of memory");
        return id;
    }

    pub fn disconnect(self: *Cancellable, id: u64) void {
        if (id == 0) return;
        handler_mutex.lock(self.io);
        defer handler_mutex.unlock(self.io);
        for (self.handlers.items, 0..) |item, i| if (item.id == id) {
            _ = self.handlers.orderedRemove(i);
            return;
        };
    }

    /// Calls `callback(context)` when the last reference is released; used by
    /// lifecycle tests to observe that a cancellable is freed.
    pub fn onFinalize(self: *Cancellable, context: anytype, comptime callback: anytype) void {
        handler_mutex.lock(self.io);
        defer handler_mutex.unlock(self.io);
        self.finalizers.append(allocator, makeEntry(0, context, callback)) catch @panic("out of memory");
    }

    fn makeEntry(id: u64, context: anytype, comptime callback: anytype) Entry {
        const Context = @TypeOf(context);
        return .{ .id = id, .data = toData(context), .call = &struct {
            fn call(data: ?*anyopaque) void {
                callback(fromData(Context, data));
            }
        }.call };
    }
};

/// Runs `work(context)` on its own thread, then `done(context, result)` on the
/// loop; `done(context)` when `work` returns nothing.
pub fn background(io: std.Io, context: anytype, comptime work: anytype, comptime done: anytype) void {
    const Context = @TypeOf(context);
    const Result = @typeInfo(@TypeOf(work)).@"fn".return_type.?;
    const Job = struct {
        io: std.Io,
        context: Context,
        result: Result = undefined,
        fn run(job: *@This()) void {
            job.result = work(job.context);
            _ = idle(job.io, job, complete);
        }
        fn complete(job: *@This()) bool {
            defer allocator.destroy(job);
            if (Result == void) done(job.context) else done(job.context, job.result);
            return false;
        }
    };
    const job = allocator.create(Job) catch @panic("out of memory");
    job.* = .{ .io = io, .context = context };
    // Without a thread the work runs here, still completing on the loop.
    const thread = std.Thread.spawn(.{}, Job.run, .{job}) catch return Job.run(job);
    thread.detach();
}

test "timeouts, idles, descriptors, removal and nested iteration" {
    const io = std.testing.io;
    const State = struct {
        ticks: u32 = 0,
        idles: u32 = 0,
        reads: u32 = 0,
        nested: bool = false,
        fn tick(self: *@This()) bool {
            self.ticks += 1;
            return self.ticks < 3;
        }
        fn idled(self: *@This()) bool {
            self.idles += 1;
            // A nested iteration must not dispatch this source again.
            if (!self.nested) {
                self.nested = true;
                _ = iteration(io, false);
            }
            return false;
        }
        fn readable(self: *@This(), fd: c_int, conditions: u32) bool {
            var byte: [8]u8 = undefined;
            _ = linux.read(fd, &byte, byte.len);
            std.debug.assert(conditions & IN != 0);
            self.reads += 1;
            return true;
        }
        fn never(_: void) bool {
            unreachable;
        }
    };
    var state: State = .{};
    _ = timeout(io, 5, &state, State.tick);
    _ = idle(io, &state, State.idled);
    const doomed = timeout(io, 1, {}, State.never);
    try std.testing.expect(remove(io, doomed));
    try std.testing.expect(!remove(io, doomed));
    var pipe: [2]linux.fd_t = undefined;
    _ = linux.pipe2(&pipe, .{ .CLOEXEC = true, .NONBLOCK = true });
    defer _ = linux.close(pipe[0]);
    defer _ = linux.close(pipe[1]);
    const reader = watch(io, pipe[0], IN, &state, State.readable);
    _ = linux.write(pipe[1], "x", 1);
    while (state.ticks < 3 or state.reads == 0 or state.idles == 0) _ = iteration(io, true);
    try std.testing.expectEqual(@as(u32, 1), state.idles);
    try std.testing.expect(remove(io, reader));
    // Sources added from another thread wake a blocked iteration.
    const Wake = struct {
        fn fire(flag: *bool) bool {
            flag.* = true;
            return false;
        }
        fn later(flag: *bool) void {
            sleep(20 * std.time.us_per_ms);
            _ = idle(io, flag, fire);
        }
    };
    var woken = false;
    const thread = try std.Thread.spawn(.{}, Wake.later, .{&woken});
    while (!woken) _ = iteration(io, true);
    thread.join();
}

test "signals, cancellation and background work" {
    const io = std.testing.io;
    const Flags = struct {
        signalled: bool = false,
        cancelled: u32 = 0,
        finalized: bool = false,
        finished: bool = false,
        result: bool = false,
        input: u32 = 42,
        fn onSignal(self: *@This()) bool {
            self.signalled = true;
            return true;
        }
        fn onCancel(self: *@This()) void {
            self.cancelled += 1;
        }
        fn onFinalize(self: *@This()) void {
            self.finalized = true;
        }
        fn work(self: *@This()) bool {
            return self.input == 42;
        }
        fn done(self: *@This(), result: bool) void {
            self.result = result;
            self.finished = true;
        }
    };
    var flags: Flags = .{};
    const id = signal(io, @intCast(@backingInt(linux.SIG.USR1)), &flags, Flags.onSignal);
    _ = linux.kill(linux.getpid(), .USR1);
    while (!flags.signalled) _ = iteration(io, true);
    try std.testing.expect(remove(io, id));

    const cancellable = Cancellable.create(io);
    cancellable.onFinalize(&flags, Flags.onFinalize);
    _ = cancellable.connect(&flags, Flags.onCancel);
    const gone = cancellable.connect(&flags, Flags.onCancel);
    cancellable.disconnect(gone);
    cancellable.cancel();
    cancellable.cancel();
    try std.testing.expectEqual(@as(u32, 1), flags.cancelled);
    try std.testing.expectEqual(@as(u64, 0), cancellable.connect(&flags, Flags.onCancel));
    try std.testing.expectEqual(@as(u32, 2), flags.cancelled);
    cancellable.unref();
    try std.testing.expect(flags.finalized);

    background(io, &flags, Flags.work, Flags.done);
    while (!flags.finished) _ = iteration(io, true);
    try std.testing.expect(flags.result);
}

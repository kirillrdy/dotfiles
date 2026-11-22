//! The GLib-style API the desktop's modules call, implemented in Zig by
//! desktop-loop.zig: the main loop (timeouts, idle callbacks, descriptor and
//! signal watches), cancellables, worker tasks and their reference counting.
//! Nothing here links GLib; the names keep existing call sites unchanged.

// Zig helpers shared by toolkit consumers.
pub const __zig = @import("desktop-ui.zig");
const std = @import("std");
const loop = @import("desktop-loop.zig");

pub const gchar = u8;
pub const gint = c_int;
pub const guint = c_uint;
pub const glong = c_long;
pub const gulong = c_ulong;
pub const gsize = c_ulong;
pub const gssize = c_long;
pub const gboolean = gint;
pub const gdouble = f64;
pub const gpointer = ?*anyopaque;
pub const gconstpointer = ?*const anyopaque;
pub const GDestroyNotify = ?*const fn (data: gpointer) callconv(.c) void;

/// Tasks here never fail with an error; propagation sites pass null.
pub const GError = extern struct {
    domain: u32 = 0,
    code: gint = 0,
    message: [*c]gchar = null,
};

pub const G_IO_IN: c_int = @intCast(loop.IN);
pub const G_IO_OUT: c_int = @intCast(loop.OUT);
pub const G_IO_ERR: c_int = @intCast(loop.ERR);
pub const G_IO_HUP: c_int = @intCast(loop.HUP);
pub const GIOCondition = c_uint;
pub const GMainContext = opaque {};
pub const GSourceFunc = ?*const fn (user_data: gpointer) callconv(.c) gboolean;
pub const GUnixFDSourceFunc = ?*const fn (fd: gint, condition: GIOCondition, user_data: gpointer) callconv(.c) gboolean;
pub const SIGINT = @as(c_int, 2);
pub const SIGTERM = @as(c_int, 15);

pub fn g_main_context_iteration(_: ?*GMainContext, may_block: gboolean) gboolean {
    return @intFromBool(loop.iteration(may_block != 0));
}
pub fn g_source_remove(tag: guint) gboolean {
    return @intFromBool(loop.remove(tag));
}
pub fn g_timeout_add(interval: guint, function: GSourceFunc, data: gpointer) guint {
    return loop.timeout(interval, function.?, data);
}
pub fn g_timeout_add_seconds(interval: guint, function: GSourceFunc, data: gpointer) guint {
    return loop.timeoutSeconds(interval, function.?, data);
}
pub fn g_idle_add(function: GSourceFunc, data: gpointer) guint {
    return loop.idle(function.?, data);
}
pub fn g_unix_fd_add(fd: gint, condition: GIOCondition, function: GUnixFDSourceFunc, data: gpointer) guint {
    return loop.watch(fd, condition, function.?, data);
}
pub fn g_unix_signal_add(signum: gint, handler: GSourceFunc, data: gpointer) guint {
    return loop.signal(@intCast(signum), handler.?, data);
}
pub fn g_usleep(microseconds: gulong) void {
    loop.sleep(microseconds);
}

pub const GObject = loop.Object;
pub const GCancellable = loop.Cancellable;
pub const GTask = loop.Task;
pub const GAsyncResult = loop.Task;
pub const GCallback = ?*const fn () callconv(.c) void;
pub const GAsyncReadyCallback = ?*const fn (source_object: [*c]GObject, res: ?*GAsyncResult, data: gpointer) callconv(.c) void;
pub const GTaskThreadFunc = ?*const fn (task: ?*GTask, source_object: gpointer, task_data: gpointer, cancellable: [*c]GCancellable) callconv(.c) void;

/// Cancellables and tasks begin with the shared reference-counted header.
pub fn g_object_ref(object: gpointer) gpointer {
    const header: *loop.Object = @ptrCast(@alignCast(object.?));
    return header.ref();
}
pub fn g_object_unref(object: gpointer) void {
    const header: *loop.Object = @ptrCast(@alignCast(object.?));
    header.unref();
}
pub fn g_object_weak_ref(object: ?*GObject, notify: ?*const fn (?*anyopaque, ?*GObject) callconv(.c) void, data: ?*anyopaque) void {
    object.?.weakRef(@ptrCast(notify.?), data);
}

pub fn g_cancellable_new() [*c]GCancellable {
    return loop.Cancellable.create();
}
pub fn g_cancellable_cancel(cancellable: [*c]GCancellable) void {
    if (cancellable != null) cancellable.*.cancel();
}
pub fn g_cancellable_is_cancelled(cancellable: [*c]GCancellable) gboolean {
    return @intFromBool(cancellable != null and cancellable.*.isCancelled());
}
pub fn g_cancellable_connect(cancellable: [*c]GCancellable, callback: GCallback, data: gpointer, _: GDestroyNotify) gulong {
    return cancellable.*.connect(@ptrCast(callback.?), data);
}
pub fn g_cancellable_disconnect(cancellable: [*c]GCancellable, handler: gulong) void {
    if (cancellable != null) cancellable.*.disconnect(handler);
}
/// Only a cancellable's "cancelled" signal remains in use.
pub fn g_signal_connect_data(instance: gpointer, detailed_signal: [*c]const gchar, handler: GCallback, data: gpointer, _: ?*anyopaque, _: c_uint) gulong {
    std.debug.assert(std.mem.eql(u8, std.mem.span(detailed_signal), "cancelled"));
    const cancellable: *GCancellable = @ptrCast(@alignCast(instance.?));
    return cancellable.listen(@ptrCast(handler.?), data);
}
pub fn g_signal_handler_disconnect(instance: gpointer, handler: gulong) void {
    const cancellable: *GCancellable = @ptrCast(@alignCast(instance.?));
    cancellable.disconnect(handler);
}

pub fn g_task_new(_: gpointer, cancellable: [*c]GCancellable, callback: GAsyncReadyCallback, data: gpointer) ?*GTask {
    return loop.Task.create(cancellable, @ptrCast(callback), data);
}
pub fn g_task_set_task_data(task: ?*GTask, task_data: gpointer, destroy: GDestroyNotify) void {
    task.?.task_data = task_data;
    task.?.task_data_destroy = destroy;
}
pub fn g_task_run_in_thread(task: ?*GTask, work: GTaskThreadFunc) void {
    task.?.runInThread(@ptrCast(work.?));
}
pub fn g_task_return_pointer(task: ?*GTask, result: gpointer, destroy: GDestroyNotify) void {
    task.?.returnPointer(result, destroy);
}
pub fn g_task_return_boolean(task: ?*GTask, result: gboolean) void {
    task.?.returnBoolean(result != 0);
}
pub fn g_task_propagate_pointer(task: ?*GTask, _: [*c][*c]GError) gpointer {
    return task.?.propagatePointer();
}
pub fn g_task_propagate_boolean(task: ?*GTask, _: [*c][*c]GError) gboolean {
    return @intFromBool(task.?.propagateBoolean());
}

pub const __icons = struct {
    pub const load = @import("desktop-icons.zig").load;
    pub const loadApp = @import("desktop-icons.zig").loadApp;
    pub const Image = @import("desktop-decode.zig").Image;
    pub const free = @import("desktop-decode.zig").free;
};

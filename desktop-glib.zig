//! Explicit C ABI declarations for the desktop's GLib/GIO, Cairo, PolicyKit and
//! Wayland APIs. Library handles use empty extern structs for nullable C
//! pointers. Never allocate or copy these objects by value; only the library
//! owns their storage. Value types and layouts accessed by Zig are defined in
//! full. Normal builds do not parse the C headers. tests/desktop-glib-abi.zig
//! checks these declarations against the installed headers.

// Zig helpers shared by toolkit consumers; excluded from C ABI comparisons.
pub const __zig = @import("desktop-ui.zig");
pub const guint8 = u8;
pub const gint32 = c_int;
pub const guint32 = c_uint;
pub const gint64 = c_long;
pub const guint64 = c_ulong;
pub const gssize = c_long;
pub const gsize = c_ulong;
pub const GPid = c_int;
pub const __uid_t = c_uint;
pub const __off_t = c_long;
pub const __pid_t = c_int;
pub const __time_t = c_long;
pub const time_t = __time_t;
pub extern fn time(__timer: [*c]time_t) time_t;
pub const gchar = u8;
pub const glong = c_long;
pub const gint = c_int;
pub const gboolean = gint;
pub const gulong = c_ulong;
pub const guint = c_uint;
pub const gfloat = f32;
pub const gdouble = f64;
pub const gpointer = ?*anyopaque;
pub const gconstpointer = ?*const anyopaque;
pub const GDestroyNotify = ?*const fn (data: gpointer) callconv(.c) void;
pub const GQuark = guint32;

pub const struct__GError = extern struct {
    domain: GQuark = 0,
    code: gint = 0,
    message: [*c]gchar = null,
};

pub const GError = struct__GError;
pub extern fn g_error_free(@"error": [*c]GError) void;
pub extern fn g_clear_error(err: [*c][*c]GError) void;
pub extern fn close(__fd: c_int) c_int;
pub extern fn write(__fd: c_int, __buf: ?*const anyopaque, __n: usize) isize;
pub extern fn getpid() __pid_t;
pub extern fn getuid() __uid_t;
pub extern fn fork() __pid_t;
pub extern fn ftruncate(__fd: c_int, __length: __off_t) c_int;

pub const struct__GData = opaque {};

pub const GData = struct__GData;
pub extern fn g_setenv(variable: [*c]const gchar, value: [*c]const gchar, overwrite: gboolean) gboolean;
pub extern fn g_dir_make_tmp(tmpl: [*c]const gchar, @"error": [*c][*c]GError) [*c]gchar;
pub extern fn g_free(mem: gpointer) void;
pub extern fn g_malloc0_n(n_blocks: gsize, n_block_bytes: gsize) gpointer;
pub const GList = struct__GList;

pub const struct__GList = extern struct {
    data: gpointer = null,
    next: [*c]GList = null,
    prev: [*c]GList = null,
};

pub extern fn g_list_free_full(list: [*c]GList, free_func: GDestroyNotify) void;
pub const GSList = struct__GSList;

pub const struct__GSList = extern struct {
    data: gpointer = null,
    next: [*c]GSList = null,
};

pub const G_IO_IN: c_int = 1;
pub const G_IO_OUT: c_int = 4;
pub const G_IO_ERR: c_int = 8;
pub const G_IO_HUP: c_int = 16;
pub const GIOCondition = c_uint;
pub const struct__GMainContext = opaque {};

pub const GMainContext = struct__GMainContext;
pub const GSourceFunc = ?*const fn (user_data: gpointer) callconv(.c) gboolean;
pub extern fn g_main_context_iteration(context: ?*GMainContext, may_block: gboolean) gboolean;
pub extern fn g_source_remove(tag: guint) gboolean;
pub extern fn g_timeout_add(interval: guint, function: GSourceFunc, data: gpointer) guint;
pub extern fn g_timeout_add_seconds(interval: guint, function: GSourceFunc, data: gpointer) guint;
pub extern fn g_utf8_casefold(str: [*c]const gchar, len: gssize) [*c]gchar;
pub const G_NORMALIZE_ALL_COMPOSE: c_int = 3;
pub const GNormalizeMode = c_uint;
pub extern fn g_utf8_normalize(str: [*c]const gchar, len: gssize, mode: GNormalizeMode) [*c]gchar;
pub extern fn g_utf8_collate(str1: [*c]const gchar, str2: [*c]const gchar) gint;
pub extern fn g_strlcpy(dest: [*c]gchar, src: [*c]const gchar, dest_size: gsize) gsize;
pub extern fn g_strdup(str: [*c]const gchar) [*c]gchar;
pub extern fn g_strndup(str: [*c]const gchar, n: gsize) [*c]gchar;
pub extern fn g_strdup_printf(format: [*c]const gchar, ...) [*c]gchar;
pub const struct__GKeyFile = opaque {};

pub const GKeyFile = struct__GKeyFile;
pub const struct__GVariantType = opaque {};

pub const GVariantType = struct__GVariantType;
pub const struct__GVariant = opaque {};

pub const GVariant = struct__GVariant;
pub extern fn g_variant_unref(value: ?*GVariant) void;
pub extern fn g_print(format: [*c]const gchar, ...) void;
pub const GSpawnChildSetupFunc = ?*const fn (data: gpointer) callconv(.c) void;
pub const GSpawnFlags = c_uint;
pub extern fn g_strcmp0(str1: [*c]const u8, str2: [*c]const u8) c_int;
pub extern fn g_usleep(microseconds: gulong) void;
pub const GType = gsize;
const union_unnamed_51 = extern union {
    v_int: gint,
    v_uint: guint,
    v_long: glong,
    v_ulong: gulong,
    v_int64: gint64,
    v_uint64: guint64,
    v_float: gfloat,
    v_double: gdouble,
    v_pointer: gpointer,
};

pub const struct__GTypeClass = extern struct {
    g_type: GType = 0,
};

pub const GTypeClass = struct__GTypeClass;

pub const struct__GTypeInstance = extern struct {
    g_class: [*c]GTypeClass = null,
};

pub const GTypeInstance = struct__GTypeInstance;

pub const struct__GClosure = opaque {};

pub const GClosure = struct__GClosure;
pub const GClosureNotify = ?*const fn (data: gpointer, closure: ?*GClosure) callconv(.c) void;
pub const GCallback = ?*const fn () callconv(.c) void;
pub const GConnectFlags = c_uint;
pub const G_SIGNAL_MATCH_DATA: c_int = 16;
pub const GSignalMatchType = c_uint;
pub extern fn g_signal_connect_data(instance: gpointer, detailed_signal: [*c]const gchar, c_handler: GCallback, data: gpointer, destroy_data: GClosureNotify, connect_flags: GConnectFlags) gulong;
pub extern fn g_signal_handler_disconnect(instance: gpointer, handler_id: gulong) void;
pub extern fn g_signal_handlers_disconnect_matched(instance: gpointer, mask: GSignalMatchType, signal_id: guint, detail: GQuark, closure: ?*GClosure, func: gpointer, data: gpointer) guint;

pub const struct__GObject = extern struct {
    g_type_instance: GTypeInstance = @import("std").mem.zeroes(GTypeInstance),
    ref_count: guint = 0,
    qdata: ?*GData = null,
};

pub const GObject = struct__GObject;

pub extern fn g_object_ref(object: gpointer) gpointer;
pub extern fn g_object_unref(object: gpointer) void;
pub extern fn g_object_weak_ref(object: ?*GObject, notify: ?*const fn (?*anyopaque, ?*GObject) callconv(.c) void, data: ?*anyopaque) void;
pub const GSubprocessFlags = c_uint;

pub const struct__GAsyncResult = opaque {};

pub const GAsyncResult = struct__GAsyncResult;

pub const struct__GCancellablePrivate = opaque {};

pub const GCancellablePrivate = struct__GCancellablePrivate;

pub const struct__GCancellable = extern struct {
    parent_instance: GObject = @import("std").mem.zeroes(GObject),
    priv: ?*GCancellablePrivate = null,
};

pub const GCancellable = struct__GCancellable;

pub const struct__GTask = opaque {};

pub const GTask = struct__GTask;
pub const GAsyncReadyCallback = ?*const fn (source_object: [*c]GObject, res: ?*GAsyncResult, data: gpointer) callconv(.c) void;

pub const struct__GSubprocess = opaque {};

pub const GSubprocess = struct__GSubprocess;

pub extern fn g_cancellable_new() [*c]GCancellable;
pub extern fn g_cancellable_cancel(cancellable: [*c]GCancellable) void;

pub extern fn g_subprocess_newv(argv: [*c]const [*c]const gchar, flags: GSubprocessFlags, @"error": [*c][*c]GError) ?*GSubprocess;
pub extern fn g_task_new(source_object: gpointer, cancellable: [*c]GCancellable, callback: GAsyncReadyCallback, callback_data: gpointer) ?*GTask;
pub extern fn g_task_set_task_data(task: ?*GTask, task_data: gpointer, task_data_destroy: GDestroyNotify) void;
pub const GTaskThreadFunc = ?*const fn (task: ?*GTask, source_object: gpointer, task_data: gpointer, cancellable: [*c]GCancellable) callconv(.c) void;
pub extern fn g_task_run_in_thread(task: ?*GTask, task_func: GTaskThreadFunc) void;
pub extern fn g_task_return_pointer(task: ?*GTask, result: gpointer, result_destroy: GDestroyNotify) void;
pub extern fn g_task_return_boolean(task: ?*GTask, result: gboolean) void;
pub extern fn g_task_propagate_pointer(task: ?*GTask, @"error": [*c][*c]GError) gpointer;
pub extern fn g_task_propagate_boolean(task: ?*GTask, @"error": [*c][*c]GError) gboolean;

pub extern fn g_unix_signal_add(signum: gint, handler: GSourceFunc, user_data: gpointer) guint;
pub const GUnixFDSourceFunc = ?*const fn (fd: gint, condition: GIOCondition, user_data: gpointer) callconv(.c) gboolean;
pub extern fn g_unix_fd_add(fd: gint, condition: GIOCondition, function: GUnixFDSourceFunc, user_data: gpointer) guint;
pub const SIGINT = @as(c_int, 2);
pub const SIGTERM = @as(c_int, 15);
pub extern fn g_cancellable_is_cancelled([*c]GCancellable) gboolean;
pub extern fn g_cancellable_connect([*c]GCancellable, GCallback, gpointer, GDestroyNotify) gulong;
pub extern fn g_cancellable_disconnect([*c]GCancellable, gulong) void;

// GIO proxy properties and variant helpers.
pub extern fn g_variant_get_type_string(?*GVariant) [*c]const gchar;
pub extern fn g_variant_print(?*GVariant, gboolean) [*c]gchar;
pub extern fn g_variant_parse(?*const GVariantType, [*c]const gchar, [*c]const gchar, [*c][*c]const gchar, [*c][*c]GError) ?*GVariant;

// Native portal broker: tuples and Unix file descriptor forwarding.
pub extern fn g_variant_take_ref(?*GVariant) ?*GVariant;
pub extern fn g_markup_escape_text([*c]const gchar, gssize) [*c]gchar;
// File chooser dialogs run in the native portal process.
pub extern fn g_variant_equal(gconstpointer, gconstpointer) gboolean;
pub extern fn g_idle_add(GSourceFunc, gpointer) guint;
pub extern fn g_strcompress([*c]const gchar) [*c]gchar;

pub const __icons = struct {
    pub const load = @import("desktop-icons.zig").load;
    pub const loadApp = @import("desktop-icons.zig").loadApp;
    pub const Image = @import("desktop-decode.zig").Image;
    pub const free = @import("desktop-decode.zig").free;
};

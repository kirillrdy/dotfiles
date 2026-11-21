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
pub extern fn g_get_home_dir() [*c]const gchar;
pub const G_USER_DIRECTORY_PICTURES: c_int = 4;
pub const GUserDirectory = c_uint;
pub extern fn g_get_user_special_dir(directory: GUserDirectory) [*c]const gchar;
pub extern fn close(__fd: c_int) c_int;
pub extern fn write(__fd: c_int, __buf: ?*const anyopaque, __n: usize) isize;
pub extern fn getpid() __pid_t;
pub extern fn getuid() __uid_t;
pub extern fn fork() __pid_t;
pub extern fn ftruncate(__fd: c_int, __length: __off_t) c_int;
pub const struct__GDateTime = opaque {};

pub const GDateTime = struct__GDateTime;
pub extern fn g_date_time_unref(datetime: ?*GDateTime) void;
pub extern fn g_date_time_ref(datetime: ?*GDateTime) ?*GDateTime;
pub extern fn g_date_time_new_now_local() ?*GDateTime;
pub extern fn g_date_time_new_local(year: gint, month: gint, day: gint, hour: gint, minute: gint, seconds: gdouble) ?*GDateTime;
pub extern fn g_date_time_add_months(datetime: ?*GDateTime, months: gint) ?*GDateTime;
pub extern fn g_date_time_add_days(datetime: ?*GDateTime, days: gint) ?*GDateTime;
pub extern fn g_date_time_get_year(datetime: ?*GDateTime) gint;
pub extern fn g_date_time_get_month(datetime: ?*GDateTime) gint;
pub extern fn g_date_time_get_day_of_month(datetime: ?*GDateTime) gint;
pub extern fn g_date_time_get_day_of_week(datetime: ?*GDateTime) gint;
pub extern fn g_date_time_get_day_of_year(datetime: ?*GDateTime) gint;
pub extern fn g_date_time_format(datetime: ?*GDateTime, format: [*c]const gchar) [*c]gchar;
pub extern fn g_filename_from_uri(uri: [*c]const gchar, hostname: [*c][*c]gchar, @"error": [*c][*c]GError) [*c]gchar;
pub const struct__GData = opaque {};

pub const GData = struct__GData;
pub extern fn g_setenv(variable: [*c]const gchar, value: [*c]const gchar, overwrite: gboolean) gboolean;
pub extern fn g_file_get_contents(filename: [*c]const gchar, contents: [*c][*c]gchar, length: [*c]gsize, @"error": [*c][*c]GError) gboolean;
pub extern fn g_dir_make_tmp(tmpl: [*c]const gchar, @"error": [*c][*c]GError) [*c]gchar;
pub extern fn g_mkdir_with_parents(pathname: [*c]const gchar, mode: gint) gint;
pub extern fn g_path_is_absolute(file_name: [*c]const gchar) gboolean;
pub extern fn g_free(mem: gpointer) void;
pub extern fn g_malloc0_n(n_blocks: gsize, n_block_bytes: gsize) gpointer;
pub const GList = struct__GList;

pub const struct__GList = extern struct {
    data: gpointer = null,
    next: [*c]GList = null,
    prev: [*c]GList = null,
};

pub extern fn g_list_free(list: [*c]GList) void;
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
pub extern fn g_utf8_offset_to_pointer(str: [*c]const gchar, offset: glong) [*c]gchar;
pub extern fn g_utf8_casefold(str: [*c]const gchar, len: gssize) [*c]gchar;
pub const G_NORMALIZE_ALL_COMPOSE: c_int = 3;
pub const GNormalizeMode = c_uint;
pub extern fn g_utf8_normalize(str: [*c]const gchar, len: gssize, mode: GNormalizeMode) [*c]gchar;
pub extern fn g_utf8_collate(str1: [*c]const gchar, str2: [*c]const gchar) gint;
pub extern fn g_strlcpy(dest: [*c]gchar, src: [*c]const gchar, dest_size: gsize) gsize;
pub extern fn g_str_has_prefix(str: [*c]const gchar, prefix: [*c]const gchar) gboolean;
pub extern fn g_strdup(str: [*c]const gchar) [*c]gchar;
pub extern fn g_strndup(str: [*c]const gchar, n: gsize) [*c]gchar;
pub extern fn g_strdup_printf(format: [*c]const gchar, ...) [*c]gchar;
pub extern fn g_strfreev(str_array: [*c][*c]gchar) void;
pub const struct__GKeyFile = opaque {};

pub const GKeyFile = struct__GKeyFile;
pub const GKeyFileFlags = c_uint;
pub extern fn g_key_file_new() ?*GKeyFile;
pub extern fn g_key_file_unref(key_file: ?*GKeyFile) void;
pub extern fn g_key_file_load_from_data(key_file: ?*GKeyFile, data: [*c]const gchar, length: gsize, flags: GKeyFileFlags, @"error": [*c][*c]GError) gboolean;
pub const struct__GVariantType = opaque {};

pub const GVariantType = struct__GVariantType;
pub const struct__GVariant = opaque {};

pub const GVariant = struct__GVariant;
pub extern fn g_variant_unref(value: ?*GVariant) void;
pub extern fn g_variant_get_boolean(value: ?*GVariant) gboolean;
pub extern fn g_variant_get_byte(value: ?*GVariant) guint8;
pub extern fn g_variant_get_int32(value: ?*GVariant) gint32;
pub extern fn g_variant_get_uint32(value: ?*GVariant) guint32;
pub extern fn g_variant_get_string(value: ?*GVariant, length: [*c]gsize) [*c]const gchar;
pub extern fn g_variant_n_children(value: ?*GVariant) gsize;
pub extern fn g_variant_get_child_value(value: ?*GVariant, index_: gsize) ?*GVariant;
pub extern fn g_variant_get_fixed_array(value: ?*GVariant, n_elements: [*c]gsize, element_size: gsize) gconstpointer;
pub extern fn g_print(format: [*c]const gchar, ...) void;
pub extern fn g_shell_quote(unquoted_string: [*c]const gchar) [*c]gchar;
pub extern fn g_shell_parse_argv(command_line: [*c]const gchar, argcp: [*c]gint, argvp: [*c][*c][*c]gchar, @"error": [*c][*c]GError) gboolean;
pub const GSpawnChildSetupFunc = ?*const fn (data: gpointer) callconv(.c) void;
pub const G_SPAWN_SEARCH_PATH: c_int = 4;
pub const GSpawnFlags = c_uint;
pub extern fn g_spawn_async(working_directory: [*c]const gchar, argv: [*c][*c]gchar, envp: [*c][*c]gchar, flags: GSpawnFlags, child_setup: GSpawnChildSetupFunc, user_data: gpointer, child_pid: [*c]GPid, @"error": [*c][*c]GError) gboolean;
pub extern fn g_spawn_command_line_async(command_line: [*c]const gchar, @"error": [*c][*c]GError) gboolean;
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

pub const struct__GValue = extern struct {
    g_type: GType = 0,
    data: [2]union_unnamed_51 = @import("std").mem.zeroes([2]union_unnamed_51),
};

pub const GValue = struct__GValue;

pub const struct__GTypeClass = extern struct {
    g_type: GType = 0,
};

pub const GTypeClass = struct__GTypeClass;

pub const struct__GTypeInstance = extern struct {
    g_class: [*c]GTypeClass = null,
};

pub const GTypeInstance = struct__GTypeInstance;
pub const GClassInitFunc = ?*const fn (g_class: gpointer, class_data: gpointer) callconv(.c) void;
pub const GInstanceInitFunc = ?*const fn (instance: [*c]GTypeInstance, g_class: gpointer) callconv(.c) void;
pub const GTypeFlags = c_uint;
pub extern fn g_type_register_static_simple(parent_type: GType, type_name: [*c]const gchar, class_size: guint, class_init: GClassInitFunc, instance_size: guint, instance_init: GInstanceInitFunc, flags: GTypeFlags) GType;
pub extern fn g_type_check_instance_is_a(instance: [*c]GTypeInstance, iface_type: GType) gboolean;
pub const GParamFlags = c_int;

pub const struct__GParamSpec = extern struct {
    g_type_instance: GTypeInstance = @import("std").mem.zeroes(GTypeInstance),
    name: [*c]const gchar = null,
    flags: GParamFlags = @import("std").mem.zeroes(GParamFlags),
    value_type: GType = 0,
    owner_type: GType = 0,
    _nick: [*c]gchar = null,
    _blurb: [*c]gchar = null,
    qdata: ?*GData = null,
    ref_count: guint = 0,
    param_id: guint = 0,
};

pub const GParamSpec = struct__GParamSpec;
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

pub const struct__GObjectConstructParam = extern struct {
    pspec: [*c]GParamSpec = null,
    value: [*c]GValue = null,
};

pub const GObjectConstructParam = struct__GObjectConstructParam;

pub const struct__GObjectClass = extern struct {
    g_type_class: GTypeClass = @import("std").mem.zeroes(GTypeClass),
    construct_properties: [*c]GSList = null,
    constructor: ?*const fn (@"type": GType, n_construct_properties: guint, construct_properties: [*c]GObjectConstructParam) callconv(.c) [*c]GObject = null,
    set_property: ?*const fn (object: [*c]GObject, property_id: guint, value: [*c]const GValue, pspec: [*c]GParamSpec) callconv(.c) void = null,
    get_property: ?*const fn (object: [*c]GObject, property_id: guint, value: [*c]GValue, pspec: [*c]GParamSpec) callconv(.c) void = null,
    dispose: ?*const fn (object: [*c]GObject) callconv(.c) void = null,
    finalize: ?*const fn (object: [*c]GObject) callconv(.c) void = null,
    dispatch_properties_changed: ?*const fn (object: [*c]GObject, n_pspecs: guint, pspecs: [*c][*c]GParamSpec) callconv(.c) void = null,
    notify: ?*const fn (object: [*c]GObject, pspec: [*c]GParamSpec) callconv(.c) void = null,
    constructed: ?*const fn (object: [*c]GObject) callconv(.c) void = null,
    flags: gsize = 0,
    n_construct_properties: gsize = 0,
    pspecs: gpointer = null,
    n_pspecs: gsize = 0,
    pdummy: [3]gpointer = @import("std").mem.zeroes([3]gpointer),
};

pub const GObjectClass = struct__GObjectClass;
pub extern fn g_object_new(object_type: GType, first_property_name: [*c]const gchar, ...) gpointer;
pub extern fn g_object_ref(object: gpointer) gpointer;
pub extern fn g_object_unref(object: gpointer) void;
pub extern fn g_object_get_data(object: [*c]GObject, key: [*c]const gchar) gpointer;
pub extern fn g_object_set_data_full(object: [*c]GObject, key: [*c]const gchar, data: gpointer, destroy: GDestroyNotify) void;
pub extern fn g_object_weak_ref(object: ?*GObject, notify: ?*const fn (?*anyopaque, ?*GObject) callconv(.c) void, data: ?*anyopaque) void;
pub const GAppInfoCreateFlags = c_uint;
pub const G_SUBPROCESS_FLAGS_NONE: c_int = 0;
pub const G_SUBPROCESS_FLAGS_STDOUT_SILENCE: c_int = 8;
pub const G_SUBPROCESS_FLAGS_STDERR_PIPE: c_int = 16;
pub const GSubprocessFlags = c_uint;
pub const struct__GAppLaunchContextPrivate = opaque {};

pub const GAppLaunchContextPrivate = struct__GAppLaunchContextPrivate;

pub const struct__GAppLaunchContext = extern struct {
    parent_instance: GObject = @import("std").mem.zeroes(GObject),
    priv: ?*GAppLaunchContextPrivate = null,
};

pub const GAppLaunchContext = struct__GAppLaunchContext;
pub const struct__GAppInfo = opaque {};

pub const GAppInfo = struct__GAppInfo;
pub const struct__GAsyncResult = opaque {};

pub const GAsyncResult = struct__GAsyncResult;
pub const struct__GInputStreamPrivate = opaque {};

pub const GInputStreamPrivate = struct__GInputStreamPrivate;

pub const struct__GInputStream = extern struct {
    parent_instance: GObject = @import("std").mem.zeroes(GObject),
    priv: ?*GInputStreamPrivate = null,
};

pub const GInputStream = struct__GInputStream;
pub const struct__GCancellablePrivate = opaque {};

pub const GCancellablePrivate = struct__GCancellablePrivate;

pub const struct__GCancellable = extern struct {
    parent_instance: GObject = @import("std").mem.zeroes(GObject),
    priv: ?*GCancellablePrivate = null,
};

pub const GCancellable = struct__GCancellable;










pub const struct__GFile = opaque {};

pub const GFile = struct__GFile;
pub const struct__GIcon = opaque {};

pub const GIcon = struct__GIcon;
pub const struct__GTask = opaque {};

pub const GTask = struct__GTask;
pub const GAsyncReadyCallback = ?*const fn (source_object: [*c]GObject, res: ?*GAsyncResult, data: gpointer) callconv(.c) void;


















pub const struct__GSubprocess = opaque {};

pub const GSubprocess = struct__GSubprocess;
pub const struct__GSubprocessLauncher = opaque {};

pub const GSubprocessLauncher = struct__GSubprocessLauncher;
pub extern fn g_app_info_create_from_commandline(commandline: [*c]const u8, application_name: [*c]const u8, flags: GAppInfoCreateFlags, @"error": [*c][*c]GError) ?*GAppInfo;
pub extern fn g_app_info_get_name(appinfo: ?*GAppInfo) [*c]const u8;
pub extern fn g_app_info_get_display_name(appinfo: ?*GAppInfo) [*c]const u8;
pub extern fn g_app_info_get_commandline(appinfo: ?*GAppInfo) [*c]const u8;
pub extern fn g_app_info_get_icon(appinfo: ?*GAppInfo) ?*GIcon;
pub extern fn g_app_info_get_id(appinfo: ?*GAppInfo) [*c]const gchar;
pub extern fn g_app_info_launch(appinfo: ?*GAppInfo, files: [*c]GList, context: [*c]GAppLaunchContext, @"error": [*c][*c]GError) gboolean;
pub extern fn g_app_info_should_show(appinfo: ?*GAppInfo) gboolean;
pub extern fn g_app_info_get_all() [*c]GList;
pub extern fn g_cancellable_new() [*c]GCancellable;
pub extern fn g_cancellable_cancel(cancellable: [*c]GCancellable) void;
pub extern fn g_file_new_for_path(path: [*c]const u8) ?*GFile;


pub extern fn g_subprocess_newv(argv: [*c]const [*c]const gchar, flags: GSubprocessFlags, @"error": [*c][*c]GError) ?*GSubprocess;
pub extern fn g_subprocess_wait_async(subprocess: ?*GSubprocess, cancellable: [*c]GCancellable, callback: GAsyncReadyCallback, user_data: gpointer) void;
pub extern fn g_subprocess_wait_finish(subprocess: ?*GSubprocess, result: ?*GAsyncResult, @"error": [*c][*c]GError) gboolean;
pub extern fn g_subprocess_wait_check_async(subprocess: ?*GSubprocess, cancellable: [*c]GCancellable, callback: GAsyncReadyCallback, user_data: gpointer) void;
pub extern fn g_subprocess_wait_check_finish(subprocess: ?*GSubprocess, result: ?*GAsyncResult, @"error": [*c][*c]GError) gboolean;
pub extern fn g_subprocess_get_successful(subprocess: ?*GSubprocess) gboolean;
pub extern fn g_subprocess_communicate_utf8_async(subprocess: ?*GSubprocess, stdin_buf: [*c]const u8, cancellable: [*c]GCancellable, callback: GAsyncReadyCallback, user_data: gpointer) void;
pub extern fn g_subprocess_communicate_utf8_finish(subprocess: ?*GSubprocess, result: ?*GAsyncResult, stdout_buf: [*c][*c]u8, stderr_buf: [*c][*c]u8, @"error": [*c][*c]GError) gboolean;
pub extern fn g_subprocess_launcher_new(flags: GSubprocessFlags) ?*GSubprocessLauncher;
pub extern fn g_subprocess_launcher_spawnv(self: ?*GSubprocessLauncher, argv: [*c]const [*c]const gchar, @"error": [*c][*c]GError) ?*GSubprocess;
pub extern fn g_task_new(source_object: gpointer, cancellable: [*c]GCancellable, callback: GAsyncReadyCallback, callback_data: gpointer) ?*GTask;
pub extern fn g_task_set_task_data(task: ?*GTask, task_data: gpointer, task_data_destroy: GDestroyNotify) void;
pub const GTaskThreadFunc = ?*const fn (task: ?*GTask, source_object: gpointer, task_data: gpointer, cancellable: [*c]GCancellable) callconv(.c) void;
pub extern fn g_task_run_in_thread(task: ?*GTask, task_func: GTaskThreadFunc) void;
pub extern fn g_task_return_pointer(task: ?*GTask, result: gpointer, result_destroy: GDestroyNotify) void;
pub extern fn g_task_return_boolean(task: ?*GTask, result: gboolean) void;
pub extern fn g_task_propagate_pointer(task: ?*GTask, @"error": [*c][*c]GError) gpointer;
pub extern fn g_task_propagate_boolean(task: ?*GTask, @"error": [*c][*c]GError) gboolean;







pub const struct__GDesktopAppInfo = opaque {};

pub const GDesktopAppInfo = struct__GDesktopAppInfo;
pub extern fn g_desktop_app_info_get_type() GType;
pub extern fn g_desktop_app_info_new_from_keyfile(key_file: ?*GKeyFile) ?*GDesktopAppInfo;
pub extern fn g_desktop_app_info_get_filename(info: ?*GDesktopAppInfo) [*c]const u8;
pub extern fn g_desktop_app_info_new(desktop_id: [*c]const u8) ?*GDesktopAppInfo;
pub extern fn g_desktop_app_info_get_string(info: ?*GDesktopAppInfo, key: [*c]const u8) [*c]u8;
pub extern fn g_desktop_app_info_get_boolean(info: ?*GDesktopAppInfo, key: [*c]const u8) gboolean;

pub extern fn g_unix_signal_add(signum: gint, handler: GSourceFunc, user_data: gpointer) guint;
pub const GUnixFDSourceFunc = ?*const fn (fd: gint, condition: GIOCondition, user_data: gpointer) callconv(.c) gboolean;
pub extern fn g_unix_fd_add(fd: gint, condition: GIOCondition, function: GUnixFDSourceFunc, user_data: gpointer) guint;
pub extern fn g_mkstemp([*c]u8) c_int;
pub extern fn g_filename_to_uri([*c]const u8, [*c]const u8, [*c][*c]GError) [*c]u8;
pub extern fn g_get_user_runtime_dir() [*:0]const u8;
pub const SIGINT = @as(c_int, 2);
pub const SIGTERM = @as(c_int, 15);
pub extern fn g_variant_get_handle(?*GVariant) gint32;
pub extern fn g_variant_get_variant(?*GVariant) ?*GVariant;
pub extern fn g_file_read_link([*c]const gchar, [*c][*c]GError) [*c]gchar;
pub extern fn g_subprocess_launcher_take_fd(?*GSubprocessLauncher, gint, gint) void;
pub extern fn g_cancellable_is_cancelled([*c]GCancellable) gboolean;
pub extern fn g_cancellable_connect([*c]GCancellable, GCallback, gpointer, GDestroyNotify) gulong;
pub extern fn g_cancellable_disconnect([*c]GCancellable, gulong) void;

// GIO proxy properties and variant helpers.
pub extern fn g_variant_get_type_string(?*GVariant) [*c]const gchar;
pub extern fn g_variant_get_double(?*GVariant) f64;
pub extern fn g_variant_get_uint64(?*GVariant) u64;
pub extern fn g_variant_print(?*GVariant, gboolean) [*c]gchar;
pub extern fn g_variant_parse(?*const GVariantType, [*c]const gchar, [*c]const gchar, [*c][*c]const gchar, [*c][*c]GError) ?*GVariant;
pub extern fn g_uuid_string_random() [*c]gchar;

// Native portal broker: tuples and Unix file descriptor forwarding.
pub extern fn g_app_info_launch_default_for_uri_async([*c]const gchar, ?*GAppLaunchContext, [*c]GCancellable, GAsyncReadyCallback, gpointer) void;
pub extern fn g_app_info_launch_default_for_uri_finish(?*GAsyncResult, [*c][*c]GError) gboolean;
pub extern fn g_app_info_get_default_for_uri_scheme([*c]const gchar) ?*GAppInfo;
pub extern fn g_file_get_uri(?*GFile) [*c]gchar;
pub extern fn g_variant_take_ref(?*GVariant) ?*GVariant;
pub const GNetworkMonitor = opaque {};
pub extern fn g_network_monitor_get_default() ?*GNetworkMonitor;
pub extern fn g_network_monitor_get_network_available(?*GNetworkMonitor) gboolean;
pub extern fn g_network_monitor_get_network_metered(?*GNetworkMonitor) gboolean;
pub extern fn g_network_monitor_get_connectivity(?*GNetworkMonitor) c_uint;
pub extern fn g_file_query_file_type(?*GFile, c_uint, [*c]GCancellable) c_uint;
pub const GSocketConnectable = opaque {};
pub extern fn g_network_address_new([*c]const gchar, u16) ?*GSocketConnectable;
pub extern fn g_network_monitor_can_reach_async(?*GNetworkMonitor, ?*GSocketConnectable, [*c]GCancellable, GAsyncReadyCallback, gpointer) void;
pub extern fn g_network_monitor_can_reach_finish(?*GNetworkMonitor, ?*GAsyncResult, [*c][*c]GError) gboolean;
pub const GFileMonitor = opaque {};
pub extern fn g_file_monitor_directory(?*GFile, c_uint, [*c]GCancellable, [*c][*c]GError) ?*GFileMonitor;
pub extern fn g_file_monitor_cancel(?*GFileMonitor) gboolean;
pub extern fn g_get_user_data_dir() [*c]const gchar;
pub extern fn g_icon_deserialize(?*GVariant) ?*GIcon;
pub extern fn g_icon_to_string(?*GIcon) [*c]gchar;
pub const GBytes = opaque {};
pub extern fn g_bytes_icon_get_type() GType;
pub extern fn g_bytes_icon_get_bytes(?*GIcon) ?*GBytes;
pub extern fn g_memory_input_stream_new_from_bytes(?*GBytes) ?*GInputStream;
pub extern fn g_markup_escape_text([*c]const gchar, gssize) [*c]gchar;
// File chooser dialogs run in the native portal process.
pub extern fn g_variant_equal(gconstpointer, gconstpointer) gboolean;
pub extern fn g_file_get_child(?*GFile, [*c]const gchar) ?*GFile;
pub extern fn g_file_query_exists(?*GFile, [*c]GCancellable) gboolean;
pub extern fn g_idle_add(GSourceFunc, gpointer) guint;
pub extern fn g_get_user_name() [*c]const gchar;
pub extern fn g_get_real_name() [*c]const gchar;
pub extern fn g_strcompress([*c]const gchar) [*c]gchar;
pub extern fn g_app_launch_context_setenv(?*GAppLaunchContext, [*c]const gchar, [*c]const gchar) void;
pub extern fn g_app_launch_context_get_type() GType;
pub const GAppLaunchContextClass = extern struct {
    parent_class: GObjectClass,
    get_display: ?*const fn (?*GAppLaunchContext, ?*GAppInfo, [*c]GList) callconv(.c) [*c]gchar,
    get_startup_notify_id: ?*const fn (?*GAppLaunchContext, ?*GAppInfo, [*c]GList) callconv(.c) [*c]gchar,
    launch_failed: ?*const fn (?*GAppLaunchContext, [*c]const gchar) callconv(.c) void,
    launched: ?*const fn (?*GAppLaunchContext, ?*GAppInfo, ?*GVariant) callconv(.c) void,
    launch_started: ?*const fn (?*GAppLaunchContext, ?*GAppInfo, ?*GVariant) callconv(.c) void,
    _g_reserved1: ?*const fn () callconv(.c) void,
    _g_reserved2: ?*const fn () callconv(.c) void,
    _g_reserved3: ?*const fn () callconv(.c) void,
};


pub const __icons = struct {
    pub const load = @import("desktop-icons.zig").load;
    pub const loadThemed = @import("desktop-icons.zig").loadThemed;
    pub const Image = @import("desktop-decode.zig").Image;
    pub const free = @import("desktop-decode.zig").free;
};

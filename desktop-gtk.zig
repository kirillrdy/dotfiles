//! Explicit C ABI declarations for the desktop's GTK 3, GLib, Cairo,
//! JSON-GLib, layer-shell, PolicyKit and Wayland APIs.
//! Toolkit handles use empty extern structs for nullable C pointers. Never
//! allocate or copy these objects by value; only GTK owns their storage.
//! Value types and layouts accessed by Zig are defined in full.
//! Normal builds do not parse the toolkit's C headers. test-gtk-abi checks these
//! declarations against the installed headers when updating dependencies.
const __root = @This();
pub const __helpers = @import("std").zig.c_translation.helpers;

pub const gint8 = i8;

pub const guint8 = u8;

pub const gint16 = c_short;

pub const gint32 = c_int;

pub const guint32 = c_uint;

pub const gint64 = c_long;

pub const guint64 = c_ulong;

pub const gssize = c_long;

pub const gsize = c_ulong;

pub const GPid = c_int;

pub const __uid_t = c_uint;

pub const __gid_t = c_uint;

pub const __off_t = c_long;

pub const __pid_t = c_int;

pub const __time_t = c_long;

pub const time_t = __time_t;

pub extern fn time(__timer: [*c]time_t) time_t;

pub const gchar = u8;

pub const glong = c_long;

pub const gint = c_int;

pub const gboolean = gint;

pub const guchar = u8;

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

pub extern fn g_set_prgname(prgname: [*c]const gchar) void;

pub const G_USER_DIRECTORY_PICTURES: c_int = 4;

pub const GUserDirectory = c_uint;

pub extern fn g_get_user_special_dir(directory: GUserDirectory) [*c]const gchar;

pub const uid_t = __uid_t;

pub extern fn raise(__sig: c_int) c_int;

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

pub extern fn g_getenv(variable: [*c]const gchar) [*c]const gchar;

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

pub const G_IO_ERR: c_int = 8;

pub const G_IO_HUP: c_int = 16;

pub const GIOCondition = c_uint;

pub const struct__GMainContext = opaque {};

pub const GMainContext = struct__GMainContext;

pub const GSourceFunc = ?*const fn (user_data: gpointer) callconv(.c) gboolean;

pub extern fn g_main_context_iteration(context: ?*GMainContext, may_block: gboolean) gboolean;

pub extern fn g_get_monotonic_time() gint64;

pub extern fn g_get_real_time() gint64;

pub extern fn g_source_remove(tag: guint) gboolean;

pub extern fn g_timeout_add(interval: guint, function: GSourceFunc, data: gpointer) guint;

pub extern fn g_timeout_add_seconds(interval: guint, function: GSourceFunc, data: gpointer) guint;

pub const gunichar = guint32;

pub extern fn g_utf8_offset_to_pointer(str: [*c]const gchar, offset: glong) [*c]gchar;

pub extern fn g_utf8_strlen(p: [*c]const gchar, max: gssize) glong;

pub extern fn g_utf8_casefold(str: [*c]const gchar, len: gssize) [*c]gchar;

pub const G_NORMALIZE_ALL_COMPOSE: c_int = 3;

pub const GNormalizeMode = c_uint;

pub extern fn g_utf8_normalize(str: [*c]const gchar, len: gssize, mode: GNormalizeMode) [*c]gchar;

pub extern fn g_utf8_collate(str1: [*c]const gchar, str2: [*c]const gchar) gint;

pub extern fn g_strlcpy(dest: [*c]gchar, src: [*c]const gchar, dest_size: gsize) gsize;

pub extern fn g_str_has_prefix(str: [*c]const gchar, prefix: [*c]const gchar) gboolean;

pub extern fn g_strdup(str: [*c]const gchar) [*c]gchar;

pub extern fn g_strdup_printf(format: [*c]const gchar, ...) [*c]gchar;

pub extern fn g_strndup(str: [*c]const gchar, n: gsize) [*c]gchar;

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

pub extern fn g_variant_new_strv(strv: [*c]const [*c]const gchar, length: gssize) ?*GVariant;

pub extern fn g_variant_get_boolean(value: ?*GVariant) gboolean;

pub extern fn g_variant_get_byte(value: ?*GVariant) guint8;

pub extern fn g_variant_get_int32(value: ?*GVariant) gint32;

pub extern fn g_variant_get_uint32(value: ?*GVariant) guint32;

pub extern fn g_variant_get_string(value: ?*GVariant, length: [*c]gsize) [*c]const gchar;

pub extern fn g_variant_n_children(value: ?*GVariant) gsize;

pub extern fn g_variant_get_child_value(value: ?*GVariant, index_: gsize) ?*GVariant;

pub extern fn g_variant_lookup_value(dictionary: ?*GVariant, key: [*c]const gchar, expected_type: ?*const GVariantType) ?*GVariant;

pub extern fn g_variant_get_fixed_array(value: ?*GVariant, n_elements: [*c]gsize, element_size: gsize) gconstpointer;

pub extern fn g_variant_new(format_string: [*c]const gchar, ...) ?*GVariant;

pub extern fn g_print(format: [*c]const gchar, ...) void;

pub extern fn g_printerr(format: [*c]const gchar, ...) void;

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

pub extern fn g_type_check_instance_cast(instance: [*c]GTypeInstance, iface_type: GType) [*c]GTypeInstance;

pub extern fn g_type_check_instance_is_a(instance: [*c]GTypeInstance, iface_type: GType) gboolean;

pub extern fn g_type_name_from_instance(instance: [*c]GTypeInstance) [*c]const gchar;

pub extern fn g_value_unset(value: [*c]GValue) void;

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

pub extern fn g_signal_emit_by_name(instance: gpointer, detailed_signal: [*c]const gchar, ...) void;

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

pub extern fn g_object_set(object: gpointer, first_property_name: [*c]const gchar, ...) void;

pub extern fn g_object_ref_sink(object: gpointer) gpointer;

pub extern fn g_object_ref(object: gpointer) gpointer;

pub extern fn g_object_unref(object: gpointer) void;

pub extern fn g_object_get_data(object: [*c]GObject, key: [*c]const gchar) gpointer;

pub extern fn g_object_set_data(object: [*c]GObject, key: [*c]const gchar, data: gpointer) void;

pub extern fn g_object_set_data_full(object: [*c]GObject, key: [*c]const gchar, data: gpointer, destroy: GDestroyNotify) void;

pub extern fn g_value_get_int(value: [*c]const GValue) gint;

pub const GAppInfoCreateFlags = c_uint;

pub const G_BUS_TYPE_SESSION: c_int = 2;

pub const GBusType = c_int;

pub const G_BUS_NAME_OWNER_FLAGS_NONE: c_int = 0;

pub const GBusNameOwnerFlags = c_uint;

pub const G_DBUS_CALL_FLAGS_NONE: c_int = 0;

pub const GDBusCallFlags = c_uint;

pub const GDBusPropertyInfoFlags = c_uint;

pub const G_DBUS_SIGNAL_FLAGS_NONE: c_int = 0;

pub const GDBusSignalFlags = c_uint;

pub const G_APPLICATION_FLAGS_NONE: c_int = 0;

pub const G_APPLICATION_DEFAULT_FLAGS: c_int = 0;

pub const G_APPLICATION_HANDLES_COMMAND_LINE: c_int = 8;

pub const GApplicationFlags = c_uint;

pub const G_SUBPROCESS_FLAGS_NONE: c_int = 0;

pub const G_SUBPROCESS_FLAGS_STDIN_PIPE: c_int = 1;

pub const G_SUBPROCESS_FLAGS_STDOUT_PIPE: c_int = 4;

pub const G_SUBPROCESS_FLAGS_STDOUT_SILENCE: c_int = 8;

pub const G_SUBPROCESS_FLAGS_STDERR_PIPE: c_int = 16;

pub const G_SUBPROCESS_FLAGS_STDERR_SILENCE: c_int = 32;

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

pub const struct__GFilterInputStream = extern struct {
    parent_instance: GInputStream = @import("std").mem.zeroes(GInputStream),
    base_stream: [*c]GInputStream = null,
};

pub const GFilterInputStream = struct__GFilterInputStream;

pub const struct__GBufferedInputStreamPrivate = opaque {};

pub const GBufferedInputStreamPrivate = struct__GBufferedInputStreamPrivate;

pub const struct__GBufferedInputStream = extern struct {
    parent_instance: GFilterInputStream = @import("std").mem.zeroes(GFilterInputStream),
    priv: ?*GBufferedInputStreamPrivate = null,
};

pub const GBufferedInputStream = struct__GBufferedInputStream;

pub const struct__GCancellablePrivate = opaque {};

pub const GCancellablePrivate = struct__GCancellablePrivate;

pub const struct__GCancellable = extern struct {
    parent_instance: GObject = @import("std").mem.zeroes(GObject),
    priv: ?*GCancellablePrivate = null,
};

pub const GCancellable = struct__GCancellable;

pub const struct__GApplicationPrivate = opaque {};

pub const GApplicationPrivate = struct__GApplicationPrivate;

pub const struct__GApplication = extern struct {
    parent_instance: GObject = @import("std").mem.zeroes(GObject),
    priv: ?*GApplicationPrivate = null,
};

pub const GApplication = struct__GApplication;

pub const struct__GApplicationCommandLinePrivate = opaque {};

pub const GApplicationCommandLinePrivate = struct__GApplicationCommandLinePrivate;

pub const struct__GApplicationCommandLine = extern struct {
    parent_instance: GObject = @import("std").mem.zeroes(GObject),
    priv: ?*GApplicationCommandLinePrivate = null,
};

pub const GApplicationCommandLine = struct__GApplicationCommandLine;

pub const struct__GSettingsBackend = opaque {};

pub const GSettingsBackend = struct__GSettingsBackend;

pub const struct__GSettingsPrivate = opaque {};

pub const GSettingsPrivate = struct__GSettingsPrivate;

pub const struct__GSettings = extern struct {
    parent_instance: GObject = @import("std").mem.zeroes(GObject),
    priv: ?*GSettingsPrivate = null,
};

pub const GSettings = struct__GSettings;

pub const struct__GFile = opaque {};

pub const GFile = struct__GFile;

pub const struct__GIcon = opaque {};

pub const GIcon = struct__GIcon;

pub const struct__GTask = opaque {};

pub const GTask = struct__GTask;

pub const GAsyncReadyCallback = ?*const fn (source_object: [*c]GObject, res: ?*GAsyncResult, data: gpointer) callconv(.c) void;

pub const struct__GDBusConnection = opaque {};

pub const GDBusConnection = struct__GDBusConnection;

pub const struct__GDBusMethodInvocation = opaque {};

pub const GDBusMethodInvocation = struct__GDBusMethodInvocation;

pub const GDBusInterfaceMethodCallFunc = ?*const fn (connection: ?*GDBusConnection, sender: [*c]const gchar, object_path: [*c]const gchar, interface_name: [*c]const gchar, method_name: [*c]const gchar, parameters: ?*GVariant, invocation: ?*GDBusMethodInvocation, user_data: gpointer) callconv(.c) void;

pub const GDBusInterfaceGetPropertyFunc = ?*const fn (connection: ?*GDBusConnection, sender: [*c]const gchar, object_path: [*c]const gchar, interface_name: [*c]const gchar, property_name: [*c]const gchar, @"error": [*c][*c]GError, user_data: gpointer) callconv(.c) ?*GVariant;

pub const GDBusInterfaceSetPropertyFunc = ?*const fn (connection: ?*GDBusConnection, sender: [*c]const gchar, object_path: [*c]const gchar, interface_name: [*c]const gchar, property_name: [*c]const gchar, value: ?*GVariant, @"error": [*c][*c]GError, user_data: gpointer) callconv(.c) gboolean;

pub const struct__GDBusInterfaceVTable = extern struct {
    method_call: GDBusInterfaceMethodCallFunc = null,
    get_property: GDBusInterfaceGetPropertyFunc = null,
    set_property: GDBusInterfaceSetPropertyFunc = null,
    padding: [8]gpointer = @import("std").mem.zeroes([8]gpointer),
};

pub const GDBusInterfaceVTable = struct__GDBusInterfaceVTable;

pub const struct__GDBusAnnotationInfo = extern struct {
    ref_count: gint = 0,
    key: [*c]gchar = null,
    value: [*c]gchar = null,
    annotations: [*c][*c]GDBusAnnotationInfo = null,
};

pub const GDBusAnnotationInfo = struct__GDBusAnnotationInfo;

pub const struct__GDBusArgInfo = extern struct {
    ref_count: gint = 0,
    name: [*c]gchar = null,
    signature: [*c]gchar = null,
    annotations: [*c][*c]GDBusAnnotationInfo = null,
};

pub const GDBusArgInfo = struct__GDBusArgInfo;

pub const struct__GDBusMethodInfo = extern struct {
    ref_count: gint = 0,
    name: [*c]gchar = null,
    in_args: [*c][*c]GDBusArgInfo = null,
    out_args: [*c][*c]GDBusArgInfo = null,
    annotations: [*c][*c]GDBusAnnotationInfo = null,
};

pub const GDBusMethodInfo = struct__GDBusMethodInfo;

pub const struct__GDBusSignalInfo = extern struct {
    ref_count: gint = 0,
    name: [*c]gchar = null,
    args: [*c][*c]GDBusArgInfo = null,
    annotations: [*c][*c]GDBusAnnotationInfo = null,
};

pub const GDBusSignalInfo = struct__GDBusSignalInfo;

pub const struct__GDBusPropertyInfo = extern struct {
    ref_count: gint = 0,
    name: [*c]gchar = null,
    signature: [*c]gchar = null,
    flags: GDBusPropertyInfoFlags = @import("std").mem.zeroes(GDBusPropertyInfoFlags),
    annotations: [*c][*c]GDBusAnnotationInfo = null,
};

pub const GDBusPropertyInfo = struct__GDBusPropertyInfo;

pub const struct__GDBusInterfaceInfo = extern struct {
    ref_count: gint = 0,
    name: [*c]gchar = null,
    methods: [*c][*c]GDBusMethodInfo = null,
    signals: [*c][*c]GDBusSignalInfo = null,
    properties: [*c][*c]GDBusPropertyInfo = null,
    annotations: [*c][*c]GDBusAnnotationInfo = null,
};

pub const GDBusInterfaceInfo = struct__GDBusInterfaceInfo;

pub const GDBusNodeInfo = struct__GDBusNodeInfo;

pub const struct__GDBusNodeInfo = extern struct {
    ref_count: gint = 0,
    path: [*c]gchar = null,
    interfaces: [*c][*c]GDBusInterfaceInfo = null,
    nodes: [*c][*c]GDBusNodeInfo = null,
    annotations: [*c][*c]GDBusAnnotationInfo = null,
};

pub const struct__GSubprocess = opaque {};

pub const GSubprocess = struct__GSubprocess;

pub const struct__GSubprocessLauncher = opaque {};

pub const GSubprocessLauncher = struct__GSubprocessLauncher;

pub extern fn g_app_info_create_from_commandline(commandline: [*c]const u8, application_name: [*c]const u8, flags: GAppInfoCreateFlags, @"error": [*c][*c]GError) ?*GAppInfo;

pub extern fn g_app_info_get_name(appinfo: ?*GAppInfo) [*c]const u8;

pub extern fn g_app_info_get_display_name(appinfo: ?*GAppInfo) [*c]const u8;

pub extern fn g_app_info_get_commandline(appinfo: ?*GAppInfo) [*c]const u8;

pub extern fn g_app_info_get_icon(appinfo: ?*GAppInfo) ?*GIcon;

pub extern fn g_app_info_launch(appinfo: ?*GAppInfo, files: [*c]GList, context: [*c]GAppLaunchContext, @"error": [*c][*c]GError) gboolean;

pub extern fn g_app_info_should_show(appinfo: ?*GAppInfo) gboolean;

pub extern fn g_app_info_get_all() [*c]GList;

pub extern fn g_application_get_dbus_connection(application: [*c]GApplication) ?*GDBusConnection;

pub extern fn g_application_hold(application: [*c]GApplication) void;

pub extern fn g_application_run(application: [*c]GApplication, argc: c_int, argv: [*c][*c]u8) c_int;

pub extern fn g_application_quit(application: [*c]GApplication) void;

pub extern fn g_application_get_default() [*c]GApplication;

pub extern fn g_application_command_line_get_arguments(cmdline: [*c]GApplicationCommandLine, argc: [*c]c_int) [*c][*c]gchar;

pub extern fn g_application_command_line_printerr(cmdline: [*c]GApplicationCommandLine, format: [*c]const gchar, ...) void;

pub extern fn g_cancellable_new() [*c]GCancellable;

pub extern fn g_cancellable_cancel(cancellable: [*c]GCancellable) void;

pub extern fn g_bus_get(bus_type: GBusType, cancellable: [*c]GCancellable, callback: GAsyncReadyCallback, user_data: gpointer) void;

pub extern fn g_bus_get_finish(res: ?*GAsyncResult, @"error": [*c][*c]GError) ?*GDBusConnection;

pub extern fn g_bus_get_sync(bus_type: GBusType, cancellable: [*c]GCancellable, @"error": [*c][*c]GError) ?*GDBusConnection;

pub extern fn g_dbus_connection_emit_signal(connection: ?*GDBusConnection, destination_bus_name: [*c]const gchar, object_path: [*c]const gchar, interface_name: [*c]const gchar, signal_name: [*c]const gchar, parameters: ?*GVariant, @"error": [*c][*c]GError) gboolean;

pub extern fn g_dbus_connection_call(connection: ?*GDBusConnection, bus_name: [*c]const gchar, object_path: [*c]const gchar, interface_name: [*c]const gchar, method_name: [*c]const gchar, parameters: ?*GVariant, reply_type: ?*const GVariantType, flags: GDBusCallFlags, timeout_msec: gint, cancellable: [*c]GCancellable, callback: GAsyncReadyCallback, user_data: gpointer) void;

pub extern fn g_dbus_connection_call_finish(connection: ?*GDBusConnection, res: ?*GAsyncResult, @"error": [*c][*c]GError) ?*GVariant;

pub extern fn g_dbus_connection_call_sync(connection: ?*GDBusConnection, bus_name: [*c]const gchar, object_path: [*c]const gchar, interface_name: [*c]const gchar, method_name: [*c]const gchar, parameters: ?*GVariant, reply_type: ?*const GVariantType, flags: GDBusCallFlags, timeout_msec: gint, cancellable: [*c]GCancellable, @"error": [*c][*c]GError) ?*GVariant;

pub extern fn g_dbus_connection_register_object(connection: ?*GDBusConnection, object_path: [*c]const gchar, interface_info: [*c]GDBusInterfaceInfo, vtable: [*c]const GDBusInterfaceVTable, user_data: gpointer, user_data_free_func: GDestroyNotify, @"error": [*c][*c]GError) guint;

pub extern fn g_dbus_connection_unregister_object(connection: ?*GDBusConnection, registration_id: guint) gboolean;

pub const GDBusSignalCallback = ?*const fn (connection: ?*GDBusConnection, sender_name: [*c]const gchar, object_path: [*c]const gchar, interface_name: [*c]const gchar, signal_name: [*c]const gchar, parameters: ?*GVariant, user_data: gpointer) callconv(.c) void;

pub extern fn g_dbus_connection_signal_subscribe(connection: ?*GDBusConnection, sender: [*c]const gchar, interface_name: [*c]const gchar, member: [*c]const gchar, object_path: [*c]const gchar, arg0: [*c]const gchar, flags: GDBusSignalFlags, callback: GDBusSignalCallback, user_data: gpointer, user_data_free_func: GDestroyNotify) guint;

pub extern fn g_dbus_connection_signal_unsubscribe(connection: ?*GDBusConnection, subscription_id: guint) void;

pub extern fn g_dbus_node_info_new_for_xml(xml_data: [*c]const gchar, @"error": [*c][*c]GError) [*c]GDBusNodeInfo;

pub extern fn g_dbus_node_info_unref(info: [*c]GDBusNodeInfo) void;

pub extern fn g_dbus_method_invocation_return_value(invocation: ?*GDBusMethodInvocation, parameters: ?*GVariant) void;

pub extern fn g_dbus_method_invocation_return_dbus_error(invocation: ?*GDBusMethodInvocation, error_name: [*c]const gchar, error_message: [*c]const gchar) void;

pub const GBusAcquiredCallback = ?*const fn (connection: ?*GDBusConnection, name: [*c]const gchar, user_data: gpointer) callconv(.c) void;

pub const GBusNameAcquiredCallback = ?*const fn (connection: ?*GDBusConnection, name: [*c]const gchar, user_data: gpointer) callconv(.c) void;

pub const GBusNameLostCallback = ?*const fn (connection: ?*GDBusConnection, name: [*c]const gchar, user_data: gpointer) callconv(.c) void;

pub extern fn g_bus_own_name(bus_type: GBusType, name: [*c]const gchar, flags: GBusNameOwnerFlags, bus_acquired_handler: GBusAcquiredCallback, name_acquired_handler: GBusNameAcquiredCallback, name_lost_handler: GBusNameLostCallback, user_data: gpointer, user_data_free_func: GDestroyNotify) guint;

pub extern fn g_bus_unown_name(owner_id: guint) void;

pub extern fn g_file_new_for_path(path: [*c]const u8) ?*GFile;

pub extern fn g_file_make_symbolic_link(file: ?*GFile, symlink_value: [*c]const u8, cancellable: [*c]GCancellable, @"error": [*c][*c]GError) gboolean;

pub const struct__GSettingsSchemaSource = opaque {};

pub const GSettingsSchemaSource = struct__GSettingsSchemaSource;

pub const struct__GSettingsSchema = opaque {};

pub const GSettingsSchema = struct__GSettingsSchema;

pub extern fn g_settings_schema_source_get_default() ?*GSettingsSchemaSource;

pub extern fn g_settings_schema_source_lookup(source: ?*GSettingsSchemaSource, schema_id: [*c]const gchar, recursive: gboolean) ?*GSettingsSchema;

pub extern fn g_settings_schema_unref(schema: ?*GSettingsSchema) void;

pub extern fn g_settings_schema_has_key(schema: ?*GSettingsSchema, name: [*c]const gchar) gboolean;

pub extern fn g_settings_new_full(schema: ?*GSettingsSchema, backend: ?*GSettingsBackend, path: [*c]const gchar) [*c]GSettings;

pub extern fn g_settings_get_string(settings: [*c]GSettings, key: [*c]const gchar) [*c]gchar;

pub extern fn g_settings_set_string(settings: [*c]GSettings, key: [*c]const gchar, value: [*c]const gchar) gboolean;

pub extern fn g_settings_get_boolean(settings: [*c]GSettings, key: [*c]const gchar) gboolean;

pub extern fn g_settings_set_boolean(settings: [*c]GSettings, key: [*c]const gchar, value: gboolean) gboolean;

pub extern fn g_settings_get_strv(settings: [*c]GSettings, key: [*c]const gchar) [*c][*c]gchar;

pub extern fn g_subprocess_new(flags: GSubprocessFlags, @"error": [*c][*c]GError, argv0: [*c]const gchar, ...) ?*GSubprocess;

pub extern fn g_subprocess_newv(argv: [*c]const [*c]const gchar, flags: GSubprocessFlags, @"error": [*c][*c]GError) ?*GSubprocess;

pub extern fn g_subprocess_send_signal(subprocess: ?*GSubprocess, signal_num: gint) void;

pub extern fn g_subprocess_force_exit(subprocess: ?*GSubprocess) void;

pub extern fn g_subprocess_wait_async(subprocess: ?*GSubprocess, cancellable: [*c]GCancellable, callback: GAsyncReadyCallback, user_data: gpointer) void;

pub extern fn g_subprocess_wait_finish(subprocess: ?*GSubprocess, result: ?*GAsyncResult, @"error": [*c][*c]GError) gboolean;

pub extern fn g_subprocess_get_successful(subprocess: ?*GSubprocess) gboolean;

pub extern fn g_subprocess_communicate_utf8_async(subprocess: ?*GSubprocess, stdin_buf: [*c]const u8, cancellable: [*c]GCancellable, callback: GAsyncReadyCallback, user_data: gpointer) void;

pub extern fn g_subprocess_communicate_utf8_finish(subprocess: ?*GSubprocess, result: ?*GAsyncResult, stdout_buf: [*c][*c]u8, stderr_buf: [*c][*c]u8, @"error": [*c][*c]GError) gboolean;

pub extern fn g_subprocess_launcher_new(flags: GSubprocessFlags) ?*GSubprocessLauncher;

pub extern fn g_subprocess_launcher_spawnv(self: ?*GSubprocessLauncher, argv: [*c]const [*c]const gchar, @"error": [*c][*c]GError) ?*GSubprocess;

pub extern fn g_subprocess_launcher_setenv(self: ?*GSubprocessLauncher, variable: [*c]const gchar, value: [*c]const gchar, overwrite: gboolean) void;

pub extern fn g_task_new(source_object: gpointer, cancellable: [*c]GCancellable, callback: GAsyncReadyCallback, callback_data: gpointer) ?*GTask;

pub extern fn g_task_set_task_data(task: ?*GTask, task_data: gpointer, task_data_destroy: GDestroyNotify) void;

pub const GTaskThreadFunc = ?*const fn (task: ?*GTask, source_object: gpointer, task_data: gpointer, cancellable: [*c]GCancellable) callconv(.c) void;

pub extern fn g_task_run_in_thread(task: ?*GTask, task_func: GTaskThreadFunc) void;

pub extern fn g_task_return_pointer(task: ?*GTask, result: gpointer, result_destroy: GDestroyNotify) void;

pub extern fn g_task_return_boolean(task: ?*GTask, result: gboolean) void;

pub extern fn g_task_return_new_error(task: ?*GTask, domain: GQuark, code: gint, format: [*c]const u8, ...) void;

pub extern fn g_task_propagate_pointer(task: ?*GTask, @"error": [*c][*c]GError) gpointer;

pub extern fn g_task_propagate_boolean(task: ?*GTask, @"error": [*c][*c]GError) gboolean;

pub const struct__PangoAttrList = opaque {};

pub const PangoAttrList = struct__PangoAttrList;

pub const struct__PangoLayout = opaque {};

pub const PangoLayout = struct__PangoLayout;

pub const PANGO_WRAP_WORD_CHAR: c_int = 2;

pub const PangoWrapMode = c_uint;

pub const PANGO_ELLIPSIZE_END: c_int = 3;

pub const PangoEllipsizeMode = c_uint;

pub extern fn pango_layout_is_ellipsized(layout: ?*PangoLayout) gboolean;

pub extern fn pango_parse_markup(markup_text: [*c]const u8, length: c_int, accel_marker: gunichar, attr_list: [*c]?*PangoAttrList, text: [*c][*c]u8, accel_char: [*c]gunichar, @"error": [*c][*c]GError) gboolean;

pub const struct__cairo = opaque {};

pub const cairo_t = struct__cairo;

pub const struct__cairo_surface = opaque {};

pub const cairo_surface_t = struct__cairo_surface;

pub const struct__cairo_pattern = opaque {};

pub const cairo_pattern_t = struct__cairo_pattern;

pub const CAIRO_STATUS_SUCCESS: c_int = 0;

pub const CAIRO_STATUS_WRITE_ERROR: c_int = 11;

pub const enum__cairo_status = c_uint;

pub const cairo_status_t = enum__cairo_status;

pub const CAIRO_FORMAT_ARGB32: c_int = 0;

pub const CAIRO_FORMAT_RGB24: c_int = 1;

pub const enum__cairo_format = c_int;

pub const cairo_format_t = enum__cairo_format;

pub const cairo_write_func_t = ?*const fn (closure: ?*anyopaque, data: [*c]const u8, length: c_uint) callconv(.c) cairo_status_t;

pub const struct__cairo_rectangle_int = extern struct {
    x: c_int = 0,
    y: c_int = 0,
    width: c_int = 0,
    height: c_int = 0,
};

pub const cairo_rectangle_int_t = struct__cairo_rectangle_int;

pub extern fn cairo_create(target: ?*cairo_surface_t) ?*cairo_t;

pub extern fn cairo_destroy(cr: ?*cairo_t) void;

pub extern fn cairo_save(cr: ?*cairo_t) void;

pub extern fn cairo_restore(cr: ?*cairo_t) void;

pub const CAIRO_OPERATOR_CLEAR: c_int = 0;

pub const CAIRO_OPERATOR_SOURCE: c_int = 1;

pub const enum__cairo_operator = c_uint;

pub const cairo_operator_t = enum__cairo_operator;

pub extern fn cairo_set_operator(cr: ?*cairo_t, op: cairo_operator_t) void;

pub extern fn cairo_set_source_rgb(cr: ?*cairo_t, red: f64, green: f64, blue: f64) void;

pub extern fn cairo_set_source_rgba(cr: ?*cairo_t, red: f64, green: f64, blue: f64, alpha: f64) void;

pub extern fn cairo_set_source_surface(cr: ?*cairo_t, surface: ?*cairo_surface_t, x: f64, y: f64) void;

pub extern fn cairo_set_line_width(cr: ?*cairo_t, width: f64) void;

pub extern fn cairo_translate(cr: ?*cairo_t, tx: f64, ty: f64) void;

pub extern fn cairo_scale(cr: ?*cairo_t, sx: f64, sy: f64) void;

pub extern fn cairo_move_to(cr: ?*cairo_t, x: f64, y: f64) void;

pub extern fn cairo_new_sub_path(cr: ?*cairo_t) void;

pub extern fn cairo_line_to(cr: ?*cairo_t, x: f64, y: f64) void;

pub extern fn cairo_arc(cr: ?*cairo_t, xc: f64, yc: f64, radius: f64, angle1: f64, angle2: f64) void;

pub extern fn cairo_rectangle(cr: ?*cairo_t, x: f64, y: f64, width: f64, height: f64) void;

pub extern fn cairo_close_path(cr: ?*cairo_t) void;

pub extern fn cairo_paint(cr: ?*cairo_t) void;

pub extern fn cairo_paint_with_alpha(cr: ?*cairo_t, alpha: f64) void;

pub extern fn cairo_stroke(cr: ?*cairo_t) void;

pub extern fn cairo_fill(cr: ?*cairo_t) void;

pub extern fn cairo_clip(cr: ?*cairo_t) void;

pub const CAIRO_FONT_SLANT_NORMAL: c_int = 0;

pub const enum__cairo_font_slant = c_uint;

pub const cairo_font_slant_t = enum__cairo_font_slant;

pub const CAIRO_FONT_WEIGHT_BOLD: c_int = 1;
pub const CAIRO_FONT_WEIGHT_NORMAL: c_int = 0;

pub const enum__cairo_font_weight = c_uint;

pub const cairo_font_weight_t = enum__cairo_font_weight;

pub extern fn cairo_select_font_face(cr: ?*cairo_t, family: [*c]const u8, slant: cairo_font_slant_t, weight: cairo_font_weight_t) void;

pub extern fn cairo_set_font_size(cr: ?*cairo_t, size: f64) void;

pub extern fn cairo_show_text(cr: ?*cairo_t, utf8: [*c]const u8) void;

pub extern fn cairo_get_source(cr: ?*cairo_t) ?*cairo_pattern_t;

pub extern fn cairo_status(cr: ?*cairo_t) cairo_status_t;

pub extern fn cairo_surface_destroy(surface: ?*cairo_surface_t) void;

pub extern fn cairo_surface_write_to_png(surface: ?*cairo_surface_t, filename: [*c]const u8) cairo_status_t;

pub extern fn cairo_surface_write_to_png_stream(surface: ?*cairo_surface_t, write_func: cairo_write_func_t, closure: ?*anyopaque) cairo_status_t;

pub extern fn cairo_surface_flush(surface: ?*cairo_surface_t) void;

pub extern fn cairo_surface_set_device_scale(surface: ?*cairo_surface_t, x_scale: f64, y_scale: f64) void;

pub extern fn cairo_image_surface_create(format: cairo_format_t, width: c_int, height: c_int) ?*cairo_surface_t;

pub extern fn cairo_image_surface_create_for_data(data: [*c]u8, format: cairo_format_t, width: c_int, height: c_int, stride: c_int) ?*cairo_surface_t;

pub extern fn cairo_image_surface_get_data(surface: ?*cairo_surface_t) [*c]u8;

pub extern fn cairo_image_surface_get_width(surface: ?*cairo_surface_t) c_int;

pub extern fn cairo_image_surface_get_height(surface: ?*cairo_surface_t) c_int;

pub extern fn cairo_image_surface_get_stride(surface: ?*cairo_surface_t) c_int;

pub const CAIRO_EXTEND_PAD: c_int = 3;

pub const enum__cairo_extend = c_uint;

pub const cairo_extend_t = enum__cairo_extend;

pub extern fn cairo_pattern_set_extend(pattern: ?*cairo_pattern_t, extend: cairo_extend_t) void;

pub const CAIRO_FILTER_BILINEAR: c_int = 4;

pub const enum__cairo_filter = c_uint;

pub const cairo_filter_t = enum__cairo_filter;

pub extern fn cairo_pattern_set_filter(pattern: ?*cairo_pattern_t, filter: cairo_filter_t) void;

pub const struct__cairo_region = opaque {};

pub const cairo_region_t = struct__cairo_region;

pub extern fn cairo_region_create() ?*cairo_region_t;

pub extern fn cairo_region_destroy(region: ?*cairo_region_t) void;

pub const GdkRectangle = cairo_rectangle_int_t;

pub const struct__GdkRGBA = extern struct {
    red: gdouble = 0,
    green: gdouble = 0,
    blue: gdouble = 0,
    alpha: gdouble = 0,
};

pub const GdkRGBA = struct__GdkRGBA;

pub const struct__GdkCursor = extern struct { _opaque: [0]usize = .{} };

pub const GdkCursor = struct__GdkCursor;

pub const struct__GdkVisual = extern struct { _opaque: [0]usize = .{} };

pub const GdkVisual = struct__GdkVisual;

pub const struct__GdkDevice = extern struct { _opaque: [0]usize = .{} };

pub const GdkDevice = struct__GdkDevice;

pub const struct__GdkDisplay = extern struct { _opaque: [0]usize = .{} };

pub const GdkDisplay = struct__GdkDisplay;

pub const struct__GdkScreen = extern struct { _opaque: [0]usize = .{} };

pub const GdkScreen = struct__GdkScreen;

pub const struct__GdkWindow = extern struct { _opaque: [0]usize = .{} };

pub const GdkWindow = struct__GdkWindow;

pub const struct__GdkAppLaunchContext = extern struct { _opaque: [0]usize = .{} };

pub const GdkAppLaunchContext = struct__GdkAppLaunchContext;

pub const struct__GdkSeat = extern struct { _opaque: [0]usize = .{} };

pub const GdkSeat = struct__GdkSeat;

pub const GDK_SHIFT_MASK: c_int = 1;

pub const GDK_CONTROL_MASK: c_int = 4;

pub const GDK_MOD1_MASK: c_int = 8;

pub const GDK_SUPER_MASK: c_int = 67108864;

pub const GDK_POINTER_MOTION_MASK: c_int = 4;

pub const GDK_BUTTON_PRESS_MASK: c_int = 256;

pub const GDK_BUTTON_RELEASE_MASK: c_int = 512;

pub const GDK_KEY_PRESS_MASK: c_int = 1024;

pub const GDK_ENTER_NOTIFY_MASK: c_int = 4096;

pub const GDK_LEAVE_NOTIFY_MASK: c_int = 8192;

pub const GDK_SCROLL_MASK: c_int = 2097152;

pub const GDK_SMOOTH_SCROLL_MASK: c_int = 8388608;

pub const GDK_WINDOW_TYPE_HINT_DIALOG: c_int = 1;

pub const GdkWindowTypeHint = c_uint;

pub extern fn gdk_device_get_position(device: ?*GdkDevice, screen: [*c]?*GdkScreen, x: [*c]gint, y: [*c]gint) void;

pub extern fn gdk_device_warp(device: ?*GdkDevice, screen: ?*GdkScreen, x: gint, y: gint) void;

pub const struct__GdkEventMotion = extern struct {
    type: GdkEventType = @import("std").mem.zeroes(GdkEventType),
    window: ?*GdkWindow = null,
    send_event: gint8 = 0,
    time: guint32 = 0,
    x: gdouble = 0,
    y: gdouble = 0,
    axes: [*c]gdouble = null,
    state: guint = 0,
    is_hint: gint16 = 0,
    device: ?*GdkDevice = null,
    x_root: gdouble = 0,
    y_root: gdouble = 0,
};

pub const GdkEventMotion = struct__GdkEventMotion;

pub const struct__GdkEventButton = extern struct {
    type: GdkEventType = @import("std").mem.zeroes(GdkEventType),
    window: ?*GdkWindow = null,
    send_event: gint8 = 0,
    time: guint32 = 0,
    x: gdouble = 0,
    y: gdouble = 0,
    axes: [*c]gdouble = null,
    state: guint = 0,
    button: guint = 0,
    device: ?*GdkDevice = null,
    x_root: gdouble = 0,
    y_root: gdouble = 0,
};

pub const GdkEventButton = struct__GdkEventButton;

pub const struct__GdkEventCrossing = extern struct {
    type: GdkEventType = @import("std").mem.zeroes(GdkEventType),
    window: ?*GdkWindow = null,
    send_event: gint8 = 0,
    subwindow: ?*GdkWindow = null,
    time: guint32 = 0,
    x: gdouble = 0,
    y: gdouble = 0,
    x_root: gdouble = 0,
    y_root: gdouble = 0,
    mode: GdkCrossingMode = @import("std").mem.zeroes(GdkCrossingMode),
    detail: GdkNotifyType = @import("std").mem.zeroes(GdkNotifyType),
    focus: gboolean = 0,
    state: guint = 0,
};

pub const GdkEventCrossing = struct__GdkEventCrossing;

pub const union__GdkEvent = opaque {};

pub const GdkEvent = union__GdkEvent;

pub const GDK_BUTTON_PRESS: c_int = 4;

pub const GDK_KEY_PRESS: c_int = 8;

pub const GdkEventType = c_int;

pub const GDK_SCROLL_UP: c_int = 0;

pub const GDK_SCROLL_LEFT: c_int = 2;

pub const GdkScrollDirection = c_uint;

pub const GDK_NOTIFY_INFERIOR: c_int = 2;

pub const GdkNotifyType = c_uint;

pub const GdkCrossingMode = c_uint;

pub extern fn gdk_event_get_coords(event: ?*const GdkEvent, x_win: [*c]gdouble, y_win: [*c]gdouble) gboolean;

pub extern fn gdk_event_get_button(event: ?*const GdkEvent, button: [*c]guint) gboolean;

pub extern fn gdk_event_get_keyval(event: ?*const GdkEvent, keyval: [*c]guint) gboolean;

pub extern fn gdk_event_get_scroll_direction(event: ?*const GdkEvent, direction: [*c]GdkScrollDirection) gboolean;

pub extern fn gdk_window_get_display(window: ?*GdkWindow) ?*GdkDisplay;

pub extern fn gdk_window_input_shape_combine_region(window: ?*GdkWindow, shape_region: ?*const cairo_region_t, offset_x: gint, offset_y: gint) void;

pub extern fn gdk_window_set_cursor(window: ?*GdkWindow, cursor: ?*GdkCursor) void;

pub extern fn gdk_window_get_origin(window: ?*GdkWindow, x: [*c]gint, y: [*c]gint) gint;

pub extern fn gdk_seat_get_pointer(seat: [*c]GdkSeat) ?*GdkDevice;

pub const struct__GdkMonitor = extern struct { _opaque: [0]usize = .{} };

pub const GdkMonitor = struct__GdkMonitor;

pub extern fn gdk_monitor_get_geometry(monitor: ?*GdkMonitor, geometry: [*c]GdkRectangle) void;

pub extern fn gdk_display_get_default() ?*GdkDisplay;

pub extern fn gdk_display_get_app_launch_context(display: ?*GdkDisplay) ?*GdkAppLaunchContext;

pub extern fn gdk_display_get_default_seat(display: ?*GdkDisplay) [*c]GdkSeat;

pub extern fn gdk_display_get_n_monitors(display: ?*GdkDisplay) c_int;

pub extern fn gdk_display_get_monitor(display: ?*GdkDisplay, monitor_num: c_int) ?*GdkMonitor;

pub extern fn gdk_display_get_primary_monitor(display: ?*GdkDisplay) ?*GdkMonitor;

pub extern fn gdk_display_get_monitor_at_point(display: ?*GdkDisplay, x: c_int, y: c_int) ?*GdkMonitor;

pub extern fn gdk_screen_get_rgba_visual(screen: ?*GdkScreen) ?*GdkVisual;

pub extern fn gdk_screen_get_default() ?*GdkScreen;

pub extern fn gdk_app_launch_context_set_timestamp(context: ?*GdkAppLaunchContext, timestamp: guint32) void;

pub extern fn gdk_rgba_parse(rgba: [*c]GdkRGBA, spec: [*c]const gchar) gboolean;

pub const GDK_COLORSPACE_RGB: c_int = 0;

pub const GdkColorspace = c_uint;

pub const struct__GdkPixbuf = extern struct { _opaque: [0]usize = .{} };

pub const GdkPixbuf = struct__GdkPixbuf;

pub extern fn gdk_pixbuf_get_pixels(pixbuf: ?*const GdkPixbuf) [*c]guchar;

pub extern fn gdk_pixbuf_get_width(pixbuf: ?*const GdkPixbuf) c_int;

pub extern fn gdk_pixbuf_get_height(pixbuf: ?*const GdkPixbuf) c_int;

pub extern fn gdk_pixbuf_get_rowstride(pixbuf: ?*const GdkPixbuf) c_int;

pub extern fn gdk_pixbuf_new(colorspace: GdkColorspace, has_alpha: gboolean, bits_per_sample: c_int, width: c_int, height: c_int) ?*GdkPixbuf;

pub extern fn gdk_pixbuf_new_from_file(filename: [*c]const u8, @"error": [*c][*c]GError) ?*GdkPixbuf;

pub extern fn gdk_pixbuf_new_from_file_at_scale(filename: [*c]const u8, width: c_int, height: c_int, preserve_aspect_ratio: gboolean, @"error": [*c][*c]GError) ?*GdkPixbuf;

pub extern fn gdk_pixbuf_save(pixbuf: ?*GdkPixbuf, filename: [*c]const u8, @"type": [*c]const u8, @"error": [*c][*c]GError, ...) gboolean;

pub extern fn gdk_pixbuf_apply_embedded_orientation(src: ?*GdkPixbuf) ?*GdkPixbuf;

pub const GDK_INTERP_BILINEAR: c_int = 2;

pub const GdkInterpType = c_uint;

pub extern fn gdk_pixbuf_scale_simple(src: ?*const GdkPixbuf, dest_width: c_int, dest_height: c_int, interp_type: GdkInterpType) ?*GdkPixbuf;

pub extern fn gdk_pixbuf_get_from_window(window: ?*GdkWindow, src_x: gint, src_y: gint, width: gint, height: gint) ?*GdkPixbuf;

pub extern fn gdk_cairo_set_source_rgba(cr: ?*cairo_t, rgba: [*c]const GdkRGBA) void;

pub extern fn gdk_cairo_set_source_pixbuf(cr: ?*cairo_t, pixbuf: ?*const GdkPixbuf, pixbuf_x: gdouble, pixbuf_y: gdouble) void;

pub extern fn gdk_cursor_new_from_name(display: ?*GdkDisplay, name: [*c]const gchar) ?*GdkCursor;

pub extern fn gdk_keyval_to_unicode(keyval: guint) guint32;

pub const GTK_ALIGN_FILL: c_int = 0;

pub const GTK_ALIGN_START: c_int = 1;

pub const GTK_ALIGN_END: c_int = 2;

pub const GTK_ALIGN_CENTER: c_int = 3;

pub const GtkAlign = c_uint;

pub const GTK_ICON_SIZE_MENU: c_int = 1;

pub const GTK_ICON_SIZE_LARGE_TOOLBAR: c_int = 3;

pub const GTK_ICON_SIZE_DIALOG: c_int = 6;

pub const GtkIconSize = c_uint;

pub const GTK_MESSAGE_QUESTION: c_int = 2;

pub const GtkMessageType = c_uint;

pub const GTK_ORIENTATION_HORIZONTAL: c_int = 0;

pub const GTK_ORIENTATION_VERTICAL: c_int = 1;

pub const GtkOrientation = c_uint;

pub const GTK_POS_RIGHT: c_int = 1;

pub const GTK_POS_BOTTOM: c_int = 3;

pub const GtkPositionType = c_uint;

pub const GTK_SELECTION_SINGLE: c_int = 1;

pub const GtkSelectionMode = c_uint;

pub const GTK_STATE_FLAG_NORMAL: c_int = 0;

pub const GtkStateFlags = c_uint;

pub const GTK_INPUT_PURPOSE_PASSWORD: c_int = 8;

pub const GtkInputPurpose = c_uint;

pub const GTK_POPOVER_CONSTRAINT_NONE: c_int = 0;

pub const GtkPopoverConstraint = c_uint;

pub const struct__GtkBorder = extern struct {
    left: gint16 = 0,
    right: gint16 = 0,
    top: gint16 = 0,
    bottom: gint16 = 0,
};

pub const GtkBorder = struct__GtkBorder;

pub const struct__GtkAdjustment = extern struct { _opaque: [0]usize = .{} };

pub const GtkAdjustment = struct__GtkAdjustment;

pub const struct__GtkSettings = extern struct { _opaque: [0]usize = .{} };

pub const GtkSettings = struct__GtkSettings;

pub const struct__GtkStyleContext = extern struct { _opaque: [0]usize = .{} };

pub const GtkStyleContext = struct__GtkStyleContext;

pub const struct__GtkWidget = extern struct { _opaque: [0]usize = .{} };

pub const GtkWidget = struct__GtkWidget;

pub const struct__GtkContainer = extern struct { _opaque: [0]usize = .{} };

pub const GtkContainer = struct__GtkContainer;

pub const struct__GtkBin = extern struct { _opaque: [0]usize = .{} };

pub const GtkBin = struct__GtkBin;

pub const struct__GtkWindow = extern struct { _opaque: [0]usize = .{} };

pub const GtkWindow = struct__GtkWindow;

pub const GtkAllocation = GdkRectangle;

pub extern fn gtk_widget_destroy(widget: [*c]GtkWidget) void;

pub extern fn gtk_widget_show(widget: [*c]GtkWidget) void;

pub extern fn gtk_widget_hide(widget: [*c]GtkWidget) void;

pub extern fn gtk_widget_show_all(widget: [*c]GtkWidget) void;

pub extern fn gtk_widget_set_no_show_all(widget: [*c]GtkWidget, no_show_all: gboolean) void;

pub extern fn gtk_widget_realize(widget: [*c]GtkWidget) void;

pub extern fn gtk_widget_queue_draw(widget: [*c]GtkWidget) void;

pub extern fn gtk_widget_set_can_focus(widget: [*c]GtkWidget, can_focus: gboolean) void;

pub extern fn gtk_widget_has_focus(widget: [*c]GtkWidget) gboolean;

pub extern fn gtk_widget_grab_focus(widget: [*c]GtkWidget) void;

pub extern fn gtk_widget_set_name(widget: [*c]GtkWidget, name: [*c]const gchar) void;

pub extern fn gtk_widget_set_sensitive(widget: [*c]GtkWidget, sensitive: gboolean) void;

pub extern fn gtk_widget_get_sensitive(widget: [*c]GtkWidget) gboolean;

pub extern fn gtk_widget_set_visible(widget: [*c]GtkWidget, visible: gboolean) void;

pub extern fn gtk_widget_get_visible(widget: [*c]GtkWidget) gboolean;

pub extern fn gtk_widget_set_app_paintable(widget: [*c]GtkWidget, app_paintable: gboolean) void;

pub extern fn gtk_widget_get_parent(widget: [*c]GtkWidget) [*c]GtkWidget;

pub extern fn gtk_widget_get_window(widget: [*c]GtkWidget) ?*GdkWindow;

pub extern fn gtk_widget_get_allocated_width(widget: [*c]GtkWidget) c_int;

pub extern fn gtk_widget_get_allocated_height(widget: [*c]GtkWidget) c_int;

pub extern fn gtk_widget_set_size_request(widget: [*c]GtkWidget, width: gint, height: gint) void;

pub extern fn gtk_widget_add_events(widget: [*c]GtkWidget, events: gint) void;

pub extern fn gtk_widget_set_opacity(widget: [*c]GtkWidget, opacity: f64) void;

pub extern fn gtk_widget_set_visual(widget: [*c]GtkWidget, visual: ?*GdkVisual) void;

pub extern fn gtk_widget_get_screen(widget: [*c]GtkWidget) ?*GdkScreen;

pub extern fn gtk_widget_get_display(widget: [*c]GtkWidget) ?*GdkDisplay;

pub extern fn gtk_widget_set_halign(widget: [*c]GtkWidget, @"align": GtkAlign) void;

pub extern fn gtk_widget_set_valign(widget: [*c]GtkWidget, @"align": GtkAlign) void;

pub extern fn gtk_widget_set_margin_start(widget: [*c]GtkWidget, margin: gint) void;

pub extern fn gtk_widget_set_margin_end(widget: [*c]GtkWidget, margin: gint) void;

pub extern fn gtk_widget_set_margin_top(widget: [*c]GtkWidget, margin: gint) void;

pub extern fn gtk_widget_set_margin_bottom(widget: [*c]GtkWidget, margin: gint) void;

pub extern fn gtk_widget_is_ancestor(widget: [*c]GtkWidget, ancestor: [*c]GtkWidget) gboolean;

pub extern fn gtk_widget_input_shape_combine_region(widget: [*c]GtkWidget, region: ?*cairo_region_t) void;

pub extern fn gtk_widget_trigger_tooltip_query(widget: [*c]GtkWidget) void;

pub extern fn gtk_widget_set_tooltip_text(widget: [*c]GtkWidget, text: [*c]const gchar) void;

pub extern fn gtk_widget_get_tooltip_text(widget: [*c]GtkWidget) [*c]gchar;

pub extern fn gtk_widget_get_style_context(widget: [*c]GtkWidget) [*c]GtkStyleContext;

pub const struct__GtkApplication = extern struct { _opaque: [0]usize = .{} };

pub const GtkApplication = struct__GtkApplication;

pub extern fn gtk_application_new(application_id: [*c]const gchar, flags: GApplicationFlags) [*c]GtkApplication;

pub extern fn gtk_application_add_window(application: [*c]GtkApplication, window: [*c]GtkWindow) void;

pub extern fn gtk_container_get_type() GType;

pub extern fn gtk_container_set_border_width(container: [*c]GtkContainer, border_width: guint) void;

pub extern fn gtk_container_add(container: [*c]GtkContainer, widget: [*c]GtkWidget) void;

pub extern fn gtk_container_get_children(container: [*c]GtkContainer) [*c]GList;

pub extern fn gtk_bin_get_child(bin: [*c]GtkBin) [*c]GtkWidget;

pub const GTK_WINDOW_TOPLEVEL: c_int = 0;

pub const GtkWindowType = c_uint;

pub const GTK_WIN_POS_CENTER: c_int = 1;

pub const GtkWindowPosition = c_uint;

pub extern fn gtk_window_new(@"type": GtkWindowType) [*c]GtkWidget;

pub extern fn gtk_window_set_title(window: [*c]GtkWindow, title: [*c]const gchar) void;

pub extern fn gtk_window_get_title(window: [*c]GtkWindow) [*c]const gchar;

pub extern fn gtk_window_set_role(window: [*c]GtkWindow, role: [*c]const gchar) void;

pub extern fn gtk_window_set_position(window: [*c]GtkWindow, position: GtkWindowPosition) void;

pub extern fn gtk_window_set_type_hint(window: [*c]GtkWindow, hint: GdkWindowTypeHint) void;

pub extern fn gtk_window_set_skip_taskbar_hint(window: [*c]GtkWindow, setting: gboolean) void;

pub extern fn gtk_window_set_skip_pager_hint(window: [*c]GtkWindow, setting: gboolean) void;

pub extern fn gtk_window_set_accept_focus(window: [*c]GtkWindow, setting: gboolean) void;

pub extern fn gtk_window_set_resizable(window: [*c]GtkWindow, resizable: gboolean) void;

pub extern fn gtk_window_is_active(window: [*c]GtkWindow) gboolean;

pub extern fn gtk_window_set_decorated(window: [*c]GtkWindow, setting: gboolean) void;

pub extern fn gtk_window_get_decorated(window: [*c]GtkWindow) gboolean;

pub extern fn gtk_window_set_icon_name(window: [*c]GtkWindow, name: [*c]const gchar) void;

pub extern fn gtk_window_set_modal(window: [*c]GtkWindow, modal: gboolean) void;

pub extern fn gtk_window_list_toplevels() [*c]GList;

pub extern fn gtk_window_present(window: [*c]GtkWindow) void;

pub extern fn gtk_window_maximize(window: [*c]GtkWindow) void;

pub extern fn gtk_window_unmaximize(window: [*c]GtkWindow) void;

pub extern fn gtk_window_set_keep_above(window: [*c]GtkWindow, setting: gboolean) void;

pub extern fn gtk_window_set_default_size(window: [*c]GtkWindow, width: gint, height: gint) void;

pub extern fn gtk_window_resize(window: [*c]GtkWindow, width: gint, height: gint) void;

pub const GTK_DIALOG_MODAL: c_int = 1;

pub const GTK_DIALOG_DESTROY_WITH_PARENT: c_int = 2;

pub const GtkDialogFlags = c_uint;

pub const GTK_RESPONSE_ACCEPT: c_int = -3;

pub const GTK_RESPONSE_DELETE_EVENT: c_int = -4;

pub const GTK_RESPONSE_OK: c_int = -5;

pub const GTK_RESPONSE_CANCEL: c_int = -6;

pub const GTK_RESPONSE_CLOSE: c_int = -7;

pub const struct__GtkDialog = extern struct { _opaque: [0]usize = .{} };

pub const GtkDialog = struct__GtkDialog;
// /nix/store/zc6camr52n5kyqs1a32dg4s4vxb57h4a-gtk+3-3.24.52-dev/include/gtk-3.0/gtk/gtkdialog.h:123:18: warning: struct demoted to opaque type - has opaque field

pub extern fn gtk_dialog_new() [*c]GtkWidget;

pub extern fn gtk_dialog_new_with_buttons(title: [*c]const gchar, parent: [*c]GtkWindow, flags: GtkDialogFlags, first_button_text: [*c]const gchar, ...) [*c]GtkWidget;

pub extern fn gtk_dialog_add_button(dialog: [*c]GtkDialog, button_text: [*c]const gchar, response_id: gint) [*c]GtkWidget;

pub extern fn gtk_dialog_set_default_response(dialog: [*c]GtkDialog, response_id: gint) void;

pub extern fn gtk_dialog_response(dialog: [*c]GtkDialog, response_id: gint) void;

pub extern fn gtk_dialog_run(dialog: [*c]GtkDialog) gint;

pub extern fn gtk_dialog_get_content_area(dialog: [*c]GtkDialog) [*c]GtkWidget;

pub const struct__GtkLabel = extern struct { _opaque: [0]usize = .{} };

pub const GtkLabel = struct__GtkLabel;

pub extern fn gtk_label_new(str: [*c]const gchar) [*c]GtkWidget;

pub extern fn gtk_label_set_text(label: [*c]GtkLabel, str: [*c]const gchar) void;

pub extern fn gtk_label_get_text(label: [*c]GtkLabel) [*c]const gchar;

pub extern fn gtk_label_set_markup(label: [*c]GtkLabel, str: [*c]const gchar) void;

pub extern fn gtk_label_get_use_markup(label: [*c]GtkLabel) gboolean;

pub extern fn gtk_label_set_ellipsize(label: [*c]GtkLabel, mode: PangoEllipsizeMode) void;

pub extern fn gtk_label_set_width_chars(label: [*c]GtkLabel, n_chars: gint) void;

pub extern fn gtk_label_set_max_width_chars(label: [*c]GtkLabel, n_chars: gint) void;

pub extern fn gtk_label_set_lines(label: [*c]GtkLabel, lines: gint) void;

pub extern fn gtk_label_set_line_wrap(label: [*c]GtkLabel, wrap: gboolean) void;

pub extern fn gtk_label_set_line_wrap_mode(label: [*c]GtkLabel, wrap_mode: PangoWrapMode) void;

pub extern fn gtk_label_set_selectable(label: [*c]GtkLabel, setting: gboolean) void;

pub extern fn gtk_label_set_angle(label: [*c]GtkLabel, angle: gdouble) void;

pub extern fn gtk_label_get_layout(label: [*c]GtkLabel) ?*PangoLayout;

pub extern fn gtk_label_set_xalign(label: [*c]GtkLabel, xalign: gfloat) void;

pub extern fn gtk_label_set_yalign(label: [*c]GtkLabel, yalign: gfloat) void;

pub const struct__GtkBox = extern struct { _opaque: [0]usize = .{} };

pub const GtkBox = struct__GtkBox;
// /nix/store/zc6camr52n5kyqs1a32dg4s4vxb57h4a-gtk+3-3.24.52-dev/include/gtk-3.0/gtk/gtkbox.h:65:21: warning: struct demoted to opaque type - has opaque field

pub extern fn gtk_box_new(orientation: GtkOrientation, spacing: gint) [*c]GtkWidget;

pub extern fn gtk_box_pack_start(box: [*c]GtkBox, child: [*c]GtkWidget, expand: gboolean, fill: gboolean, padding: guint) void;

pub extern fn gtk_box_pack_end(box: [*c]GtkBox, child: [*c]GtkWidget, expand: gboolean, fill: gboolean, padding: guint) void;

pub extern fn gtk_box_set_homogeneous(box: [*c]GtkBox, homogeneous: gboolean) void;

pub extern fn gtk_box_set_spacing(box: [*c]GtkBox, spacing: gint) void;

pub extern fn gtk_box_reorder_child(box: [*c]GtkBox, child: [*c]GtkWidget, position: gint) void;

pub extern fn gtk_box_set_center_widget(box: [*c]GtkBox, widget: [*c]GtkWidget) void;

pub const struct__GtkTreeIter = extern struct {
    stamp: gint = 0,
    user_data: gpointer = null,
    user_data2: gpointer = null,
    user_data3: gpointer = null,
};

pub const GtkTreeIter = struct__GtkTreeIter;

pub const struct__GtkTreeModel = extern struct { _opaque: [0]usize = .{} };

pub const GtkTreeModel = struct__GtkTreeModel;

pub extern fn gtk_tree_model_iter_n_children(tree_model: ?*GtkTreeModel, iter: [*c]GtkTreeIter) gint;

pub const struct__GtkEditable = extern struct { _opaque: [0]usize = .{} };

pub const GtkEditable = struct__GtkEditable;

pub const struct__GtkImage = extern struct { _opaque: [0]usize = .{} };

pub const GtkImage = struct__GtkImage;

pub extern fn gtk_image_new() [*c]GtkWidget;

pub extern fn gtk_image_new_from_pixbuf(pixbuf: ?*GdkPixbuf) [*c]GtkWidget;

pub extern fn gtk_image_new_from_icon_name(icon_name: [*c]const gchar, size: GtkIconSize) [*c]GtkWidget;

pub extern fn gtk_image_new_from_gicon(icon: ?*GIcon, size: GtkIconSize) [*c]GtkWidget;

pub extern fn gtk_image_set_from_file(image: [*c]GtkImage, filename: [*c]const gchar) void;

pub extern fn gtk_image_set_from_pixbuf(image: [*c]GtkImage, pixbuf: ?*GdkPixbuf) void;

pub extern fn gtk_image_set_from_icon_name(image: [*c]GtkImage, icon_name: [*c]const gchar, size: GtkIconSize) void;

pub extern fn gtk_image_set_pixel_size(image: [*c]GtkImage, pixel_size: gint) void;

pub const struct__GtkEntry = extern struct { _opaque: [0]usize = .{} };

pub const GtkEntry = struct__GtkEntry;

pub extern fn gtk_entry_new() [*c]GtkWidget;

pub extern fn gtk_entry_set_visibility(entry: [*c]GtkEntry, visible: gboolean) void;

pub extern fn gtk_entry_get_visibility(entry: [*c]GtkEntry) gboolean;

pub extern fn gtk_entry_set_activates_default(entry: [*c]GtkEntry, setting: gboolean) void;

pub extern fn gtk_entry_set_text(entry: [*c]GtkEntry, text: [*c]const gchar) void;

pub extern fn gtk_entry_get_text(entry: [*c]GtkEntry) [*c]const gchar;

pub extern fn gtk_entry_set_placeholder_text(entry: [*c]GtkEntry, text: [*c]const gchar) void;

pub extern fn gtk_entry_set_input_purpose(entry: [*c]GtkEntry, purpose: GtkInputPurpose) void;

pub extern fn gtk_entry_get_input_purpose(entry: [*c]GtkEntry) GtkInputPurpose;

pub const struct__GtkComboBox = extern struct { _opaque: [0]usize = .{} };

pub const GtkComboBox = struct__GtkComboBox;
// /nix/store/zc6camr52n5kyqs1a32dg4s4vxb57h4a-gtk+3-3.24.52-dev/include/gtk-3.0/gtk/gtkcombobox.h:59:15: warning: struct demoted to opaque type - has opaque field

pub extern fn gtk_combo_box_set_active(combo_box: [*c]GtkComboBox, index_: gint) void;

pub extern fn gtk_combo_box_get_model(combo_box: [*c]GtkComboBox) ?*GtkTreeModel;

pub extern fn gtk_combo_box_get_active_id(combo_box: [*c]GtkComboBox) [*c]const gchar;

pub extern fn gtk_combo_box_set_active_id(combo_box: [*c]GtkComboBox, active_id: [*c]const gchar) gboolean;

pub extern fn gtk_application_window_new(application: [*c]GtkApplication) [*c]GtkWidget;

pub const struct__GtkButton = extern struct { _opaque: [0]usize = .{} };

pub const GtkButton = struct__GtkButton;
// /nix/store/zc6camr52n5kyqs1a32dg4s4vxb57h4a-gtk+3-3.24.52-dev/include/gtk-3.0/gtk/gtkbutton.h:72:22: warning: struct demoted to opaque type - has opaque field

pub extern fn gtk_button_get_type() GType;

pub extern fn gtk_button_new() [*c]GtkWidget;

pub extern fn gtk_button_new_with_label(label: [*c]const gchar) [*c]GtkWidget;

pub extern fn gtk_button_new_from_icon_name(icon_name: [*c]const gchar, size: GtkIconSize) [*c]GtkWidget;

pub extern fn gtk_button_clicked(button: [*c]GtkButton) void;

pub extern fn gtk_button_set_label(button: [*c]GtkButton, label: [*c]const gchar) void;

pub extern fn gtk_button_get_label(button: [*c]GtkButton) [*c]const gchar;

pub extern fn gtk_button_set_alignment(button: [*c]GtkButton, xalign: gfloat, yalign: gfloat) void;

pub extern fn gtk_button_get_image(button: [*c]GtkButton) [*c]GtkWidget;

pub const struct__GtkToggleButton = extern struct { _opaque: [0]usize = .{} };

pub const GtkToggleButton = struct__GtkToggleButton;
// /nix/store/zc6camr52n5kyqs1a32dg4s4vxb57h4a-gtk+3-3.24.52-dev/include/gtk-3.0/gtk/gtktogglebutton.h:59:18: warning: struct demoted to opaque type - has opaque field

pub extern fn gtk_toggle_button_new() [*c]GtkWidget;

pub extern fn gtk_toggle_button_set_active(toggle_button: [*c]GtkToggleButton, is_active: gboolean) void;

pub extern fn gtk_toggle_button_get_active(toggle_button: [*c]GtkToggleButton) gboolean;

pub extern fn gtk_check_button_new_with_label(label: [*c]const gchar) [*c]GtkWidget;

pub const struct__GtkComboBoxText = extern struct { _opaque: [0]usize = .{} };

pub const GtkComboBoxText = struct__GtkComboBoxText;
// /nix/store/zc6camr52n5kyqs1a32dg4s4vxb57h4a-gtk+3-3.24.52-dev/include/gtk-3.0/gtk/gtkcomboboxtext.h:51:20: warning: struct demoted to opaque type - has opaque field

pub extern fn gtk_combo_box_text_new() [*c]GtkWidget;

pub extern fn gtk_combo_box_text_new_with_entry() [*c]GtkWidget;

pub extern fn gtk_combo_box_text_remove_all(combo_box: [*c]GtkComboBoxText) void;

pub extern fn gtk_combo_box_text_append(combo_box: [*c]GtkComboBoxText, id: [*c]const gchar, text: [*c]const gchar) void;

pub const struct__GtkCssProvider = extern struct { _opaque: [0]usize = .{} };

pub const GtkCssProvider = struct__GtkCssProvider;

pub extern fn gtk_css_provider_new() [*c]GtkCssProvider;

pub extern fn gtk_css_provider_load_from_data(css_provider: [*c]GtkCssProvider, data: [*c]const gchar, length: gssize, @"error": [*c][*c]GError) gboolean;

pub extern fn gtk_css_provider_load_from_path(css_provider: [*c]GtkCssProvider, path: [*c]const gchar, @"error": [*c][*c]GError) gboolean;

pub extern fn gtk_drawing_area_new() [*c]GtkWidget;

pub const struct__GtkEventBoxPrivate = extern struct { _opaque: [0]usize = .{} };

pub const GtkEventBoxPrivate = struct__GtkEventBoxPrivate;

pub const struct__GtkEventBox = extern struct { _opaque: [0]usize = .{} };

pub const GtkEventBox = struct__GtkEventBox;
// /nix/store/zc6camr52n5kyqs1a32dg4s4vxb57h4a-gtk+3-3.24.52-dev/include/gtk-3.0/gtk/gtkeventbox.h:63:15: warning: struct demoted to opaque type - has opaque field

pub extern fn gtk_event_box_new() [*c]GtkWidget;

pub extern fn gtk_event_box_set_visible_window(event_box: [*c]GtkEventBox, visible_window: gboolean) void;

pub const struct__GtkFlowBox = extern struct { _opaque: [0]usize = .{} };

pub const GtkFlowBox = struct__GtkFlowBox;
// /nix/store/zc6camr52n5kyqs1a32dg4s4vxb57h4a-gtk+3-3.24.52-dev/include/gtk-3.0/gtk/gtkflowbox.h:57:21: warning: struct demoted to opaque type - has opaque field

pub const struct__GtkFlowBoxChild = extern struct { _opaque: [0]usize = .{} };

pub const GtkFlowBoxChild = struct__GtkFlowBoxChild;
// /nix/store/zc6camr52n5kyqs1a32dg4s4vxb57h4a-gtk+3-3.24.52-dev/include/gtk-3.0/gtk/gtkflowbox.h:93:15: warning: struct demoted to opaque type - has opaque field

pub extern fn gtk_flow_box_child_new() [*c]GtkWidget;

pub extern fn gtk_flow_box_new() [*c]GtkWidget;

pub extern fn gtk_flow_box_set_homogeneous(box: [*c]GtkFlowBox, homogeneous: gboolean) void;

pub extern fn gtk_flow_box_set_row_spacing(box: [*c]GtkFlowBox, spacing: guint) void;

pub extern fn gtk_flow_box_set_column_spacing(box: [*c]GtkFlowBox, spacing: guint) void;

pub extern fn gtk_flow_box_set_min_children_per_line(box: [*c]GtkFlowBox, n_children: guint) void;

pub extern fn gtk_flow_box_set_max_children_per_line(box: [*c]GtkFlowBox, n_children: guint) void;

pub extern fn gtk_flow_box_set_activate_on_single_click(box: [*c]GtkFlowBox, single: gboolean) void;

pub extern fn gtk_flow_box_insert(box: [*c]GtkFlowBox, widget: [*c]GtkWidget, position: gint) void;

pub extern fn gtk_flow_box_get_child_at_index(box: [*c]GtkFlowBox, idx: gint) [*c]GtkFlowBoxChild;

pub extern fn gtk_flow_box_select_child(box: [*c]GtkFlowBox, child: [*c]GtkFlowBoxChild) void;

pub extern fn gtk_flow_box_unselect_all(box: [*c]GtkFlowBox) void;

pub extern fn gtk_flow_box_set_selection_mode(box: [*c]GtkFlowBox, mode: GtkSelectionMode) void;

pub extern fn gtk_flow_box_set_vadjustment(box: [*c]GtkFlowBox, adjustment: [*c]GtkAdjustment) void;

pub const GtkFlowBoxFilterFunc = ?*const fn (child: [*c]GtkFlowBoxChild, user_data: gpointer) callconv(.c) gboolean;

pub extern fn gtk_flow_box_set_filter_func(box: [*c]GtkFlowBox, filter_func: GtkFlowBoxFilterFunc, user_data: gpointer, destroy: GDestroyNotify) void;

pub extern fn gtk_flow_box_invalidate_filter(box: [*c]GtkFlowBox) void;

pub const GtkFlowBoxSortFunc = ?*const fn (child1: [*c]GtkFlowBoxChild, child2: [*c]GtkFlowBoxChild, user_data: gpointer) callconv(.c) gint;

pub extern fn gtk_flow_box_set_sort_func(box: [*c]GtkFlowBox, sort_func: GtkFlowBoxSortFunc, user_data: gpointer, destroy: GDestroyNotify) void;

pub extern fn gtk_flow_box_invalidate_sort(box: [*c]GtkFlowBox) void;

pub const struct__GtkGrid = extern struct { _opaque: [0]usize = .{} };

pub const GtkGrid = struct__GtkGrid;
// /nix/store/zc6camr52n5kyqs1a32dg4s4vxb57h4a-gtk+3-3.24.52-dev/include/gtk-3.0/gtk/gtkgrid.h:58:21: warning: struct demoted to opaque type - has opaque field

pub extern fn gtk_grid_new() [*c]GtkWidget;

pub extern fn gtk_grid_attach(grid: [*c]GtkGrid, child: [*c]GtkWidget, left: gint, top: gint, width: gint, height: gint) void;

pub extern fn gtk_grid_set_row_homogeneous(grid: [*c]GtkGrid, homogeneous: gboolean) void;

pub extern fn gtk_grid_set_row_spacing(grid: [*c]GtkGrid, spacing: guint) void;

pub extern fn gtk_grid_set_column_homogeneous(grid: [*c]GtkGrid, homogeneous: gboolean) void;

pub extern fn gtk_grid_set_column_spacing(grid: [*c]GtkGrid, spacing: guint) void;

pub const struct__GtkStyleProvider = extern struct { _opaque: [0]usize = .{} };

pub const GtkStyleProvider = struct__GtkStyleProvider;

pub extern fn gtk_style_context_add_provider_for_screen(screen: ?*GdkScreen, provider: ?*GtkStyleProvider, priority: guint) void;

pub extern fn gtk_style_context_remove_provider_for_screen(screen: ?*GdkScreen, provider: ?*GtkStyleProvider) void;

pub extern fn gtk_style_context_get_property(context: [*c]GtkStyleContext, property: [*c]const gchar, state: GtkStateFlags, value: [*c]GValue) void;

pub extern fn gtk_style_context_add_class(context: [*c]GtkStyleContext, class_name: [*c]const gchar) void;

pub extern fn gtk_style_context_remove_class(context: [*c]GtkStyleContext, class_name: [*c]const gchar) void;

pub extern fn gtk_style_context_has_class(context: [*c]GtkStyleContext, class_name: [*c]const gchar) gboolean;

pub extern fn gtk_style_context_get_border(context: [*c]GtkStyleContext, state: GtkStateFlags, border: [*c]GtkBorder) void;

pub const struct__GtkIconInfo = extern struct { _opaque: [0]usize = .{} };

pub const GtkIconInfo = struct__GtkIconInfo;

pub const struct__GtkIconTheme = extern struct { _opaque: [0]usize = .{} };

pub const GtkIconTheme = struct__GtkIconTheme;

pub const GTK_ICON_LOOKUP_FORCE_SIZE: c_int = 16;

pub const GtkIconLookupFlags = c_uint;

pub extern fn gtk_icon_theme_new() [*c]GtkIconTheme;

pub extern fn gtk_icon_theme_get_default() [*c]GtkIconTheme;

pub extern fn gtk_icon_theme_append_search_path(icon_theme: [*c]GtkIconTheme, path: [*c]const gchar) void;

pub extern fn gtk_icon_theme_set_custom_theme(icon_theme: [*c]GtkIconTheme, theme_name: [*c]const gchar) void;

pub extern fn gtk_icon_theme_load_icon(icon_theme: [*c]GtkIconTheme, icon_name: [*c]const gchar, size: gint, flags: GtkIconLookupFlags, @"error": [*c][*c]GError) ?*GdkPixbuf;

pub extern fn gtk_icon_theme_load_icon_for_scale(icon_theme: [*c]GtkIconTheme, icon_name: [*c]const gchar, size: gint, scale: gint, flags: GtkIconLookupFlags, @"error": [*c][*c]GError) ?*GdkPixbuf;

pub extern fn gtk_icon_theme_lookup_by_gicon(icon_theme: [*c]GtkIconTheme, icon: ?*GIcon, size: gint, flags: GtkIconLookupFlags) ?*GtkIconInfo;

pub extern fn gtk_icon_info_load_icon(icon_info: ?*GtkIconInfo, @"error": [*c][*c]GError) ?*GdkPixbuf;

pub extern fn gtk_init(argc: [*c]c_int, argv: [*c][*c][*c]u8) void;

pub extern fn gtk_init_check(argc: [*c]c_int, argv: [*c][*c][*c]u8) gboolean;

pub extern fn gtk_events_pending() gboolean;

pub extern fn gtk_main() void;

pub extern fn gtk_main_quit() void;

pub extern fn gtk_main_iteration() gboolean;

pub extern fn gtk_get_current_event_time() guint32;

pub extern fn gtk_get_event_widget(event: ?*GdkEvent) [*c]GtkWidget;

pub const struct__GtkPopover = extern struct { _opaque: [0]usize = .{} };

pub const GtkPopover = struct__GtkPopover;
// /nix/store/zc6camr52n5kyqs1a32dg4s4vxb57h4a-gtk+3-3.24.52-dev/include/gtk-3.0/gtk/gtkpopover.h:51:15: warning: struct demoted to opaque type - has opaque field

pub extern fn gtk_popover_new(relative_to: [*c]GtkWidget) [*c]GtkWidget;

pub extern fn gtk_popover_get_relative_to(popover: [*c]GtkPopover) [*c]GtkWidget;

pub extern fn gtk_popover_set_pointing_to(popover: [*c]GtkPopover, rect: [*c]const GdkRectangle) void;

pub extern fn gtk_popover_set_position(popover: [*c]GtkPopover, position: GtkPositionType) void;

pub extern fn gtk_popover_set_constrain_to(popover: [*c]GtkPopover, constraint: GtkPopoverConstraint) void;

pub extern fn gtk_popover_popup(popover: [*c]GtkPopover) void;

pub extern fn gtk_popover_popdown(popover: [*c]GtkPopover) void;

pub const GTK_BUTTONS_CANCEL: c_int = 3;

pub const GTK_BUTTONS_OK_CANCEL: c_int = 5;

pub const GtkButtonsType = c_uint;

pub extern fn gtk_message_dialog_new(parent: [*c]GtkWindow, flags: GtkDialogFlags, @"type": GtkMessageType, buttons: GtkButtonsType, message_format: [*c]const gchar, ...) [*c]GtkWidget;

pub const struct__GtkOverlay = extern struct { _opaque: [0]usize = .{} };

pub const GtkOverlay = struct__GtkOverlay;
// /nix/store/zc6camr52n5kyqs1a32dg4s4vxb57h4a-gtk+3-3.24.52-dev/include/gtk-3.0/gtk/gtkoverlay.h:58:15: warning: struct demoted to opaque type - has opaque field

pub extern fn gtk_overlay_new() [*c]GtkWidget;

pub extern fn gtk_overlay_add_overlay(overlay: [*c]GtkOverlay, widget: [*c]GtkWidget) void;

pub extern fn gtk_overlay_set_overlay_pass_through(overlay: [*c]GtkOverlay, widget: [*c]GtkWidget, pass_through: gboolean) void;

pub const struct__GtkProgressBar = extern struct { _opaque: [0]usize = .{} };

pub const GtkProgressBar = struct__GtkProgressBar;

pub extern fn gtk_progress_bar_get_type() GType;

pub extern fn gtk_progress_bar_new() [*c]GtkWidget;

pub extern fn gtk_progress_bar_set_fraction(pbar: [*c]GtkProgressBar, fraction: gdouble) void;

pub extern fn gtk_progress_bar_get_fraction(pbar: [*c]GtkProgressBar) gdouble;

pub const struct__GtkRange = extern struct { _opaque: [0]usize = .{} };

pub const GtkRange = struct__GtkRange;

pub extern fn gtk_range_set_value(range: [*c]GtkRange, value: gdouble) void;

pub extern fn gtk_range_get_value(range: [*c]GtkRange) gdouble;

pub const struct__GtkRevealer = extern struct { _opaque: [0]usize = .{} };

pub const GtkRevealer = struct__GtkRevealer;
// /nix/store/zc6camr52n5kyqs1a32dg4s4vxb57h4a-gtk+3-3.24.52-dev/include/gtk-3.0/gtk/gtkrevealer.h:58:15: warning: struct demoted to opaque type - has opaque field

pub const GTK_REVEALER_TRANSITION_TYPE_NONE: c_int = 0;

pub const GtkRevealerTransitionType = c_uint;

pub extern fn gtk_revealer_new() [*c]GtkWidget;

pub extern fn gtk_revealer_get_reveal_child(revealer: [*c]GtkRevealer) gboolean;

pub extern fn gtk_revealer_set_reveal_child(revealer: [*c]GtkRevealer, reveal_child: gboolean) void;

pub extern fn gtk_revealer_set_transition_type(revealer: [*c]GtkRevealer, transition: GtkRevealerTransitionType) void;

pub const struct__GtkScale = extern struct { _opaque: [0]usize = .{} };

pub const GtkScale = struct__GtkScale;

pub extern fn gtk_scale_new_with_range(orientation: GtkOrientation, min: gdouble, max: gdouble, step: gdouble) [*c]GtkWidget;

pub extern fn gtk_scale_set_digits(scale: [*c]GtkScale, digits: gint) void;

pub extern fn gtk_scale_set_draw_value(scale: [*c]GtkScale, draw_value: gboolean) void;

pub extern fn gtk_scale_set_value_pos(scale: [*c]GtkScale, pos: GtkPositionType) void;

pub const struct__GtkScrolledWindow = extern struct { _opaque: [0]usize = .{} };

pub const GtkScrolledWindow = struct__GtkScrolledWindow;
// /nix/store/zc6camr52n5kyqs1a32dg4s4vxb57h4a-gtk+3-3.24.52-dev/include/gtk-3.0/gtk/gtkscrolledwindow.h:67:15: warning: struct demoted to opaque type - has opaque field

pub const GTK_POLICY_AUTOMATIC: c_int = 1;

pub const GTK_POLICY_NEVER: c_int = 2;

pub const GtkPolicyType = c_uint;

pub extern fn gtk_scrolled_window_new(hadjustment: [*c]GtkAdjustment, vadjustment: [*c]GtkAdjustment) [*c]GtkWidget;

pub extern fn gtk_scrolled_window_get_vadjustment(scrolled_window: [*c]GtkScrolledWindow) [*c]GtkAdjustment;

pub extern fn gtk_scrolled_window_set_policy(scrolled_window: [*c]GtkScrolledWindow, hscrollbar_policy: GtkPolicyType, vscrollbar_policy: GtkPolicyType) void;

pub const struct__GtkSearchEntry = extern struct { _opaque: [0]usize = .{} };

pub const GtkSearchEntry = struct__GtkSearchEntry;

pub extern fn gtk_search_entry_new() [*c]GtkWidget;

pub extern fn gtk_separator_new(orientation: GtkOrientation) [*c]GtkWidget;

pub extern fn gtk_settings_get_default() [*c]GtkSettings;

pub const struct__GDesktopAppInfo = opaque {};

pub const GDesktopAppInfo = struct__GDesktopAppInfo;

pub extern fn g_desktop_app_info_get_type() GType;

pub extern fn g_desktop_app_info_new_from_keyfile(key_file: ?*GKeyFile) ?*GDesktopAppInfo;

pub extern fn g_desktop_app_info_get_filename(info: ?*GDesktopAppInfo) [*c]const u8;

pub extern fn g_desktop_app_info_new(desktop_id: [*c]const u8) ?*GDesktopAppInfo;

pub extern fn g_desktop_app_info_get_string(info: ?*GDesktopAppInfo, key: [*c]const u8) [*c]u8;

pub extern fn g_desktop_app_info_get_boolean(info: ?*GDesktopAppInfo, key: [*c]const u8) gboolean;

pub const GTK_LAYER_SHELL_LAYER_BACKGROUND: c_int = 0;

pub const GTK_LAYER_SHELL_LAYER_TOP: c_int = 2;

pub const GTK_LAYER_SHELL_LAYER_OVERLAY: c_int = 3;

pub const GtkLayerShellLayer = c_uint;

pub const GTK_LAYER_SHELL_EDGE_LEFT: c_int = 0;

pub const GTK_LAYER_SHELL_EDGE_RIGHT: c_int = 1;

pub const GTK_LAYER_SHELL_EDGE_TOP: c_int = 2;

pub const GTK_LAYER_SHELL_EDGE_BOTTOM: c_int = 3;

pub const GtkLayerShellEdge = c_uint;

pub const GTK_LAYER_SHELL_KEYBOARD_MODE_NONE: c_int = 0;

pub const GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE: c_int = 1;

pub const GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND: c_int = 2;

pub const GtkLayerShellKeyboardMode = c_uint;

pub extern fn gtk_layer_is_supported(...) gboolean;

pub extern fn gtk_layer_init_for_window(window: [*c]GtkWindow) void;

pub extern fn gtk_layer_set_namespace(window: [*c]GtkWindow, name_space: [*c]const u8) void;

pub extern fn gtk_layer_set_layer(window: [*c]GtkWindow, layer: GtkLayerShellLayer) void;

pub extern fn gtk_layer_set_monitor(window: [*c]GtkWindow, monitor: ?*GdkMonitor) void;

pub extern fn gtk_layer_set_anchor(window: [*c]GtkWindow, edge: GtkLayerShellEdge, anchor_to_edge: gboolean) void;

pub extern fn gtk_layer_set_margin(window: [*c]GtkWindow, edge: GtkLayerShellEdge, margin_size: c_int) void;

pub extern fn gtk_layer_set_exclusive_zone(window: [*c]GtkWindow, exclusive_zone: c_int) void;

pub extern fn gtk_layer_auto_exclusive_zone_enable(window: [*c]GtkWindow) void;

pub extern fn gtk_layer_set_keyboard_mode(window: [*c]GtkWindow, mode: GtkLayerShellKeyboardMode) void;

pub extern fn g_unix_signal_add(signum: gint, handler: GSourceFunc, user_data: gpointer) guint;

pub const GUnixFDSourceFunc = ?*const fn (fd: gint, condition: GIOCondition, user_data: gpointer) callconv(.c) gboolean;

pub extern fn g_unix_fd_add(fd: gint, condition: GIOCondition, function: GUnixFDSourceFunc, user_data: gpointer) guint;

pub const struct_wl_interface = extern struct {
    name: [*c]const u8 = null,
    version: c_int = 0,
    method_count: c_int = 0,
    methods: [*c]const struct_wl_message = null,
    event_count: c_int = 0,
    events: [*c]const struct_wl_message = null,
};

pub const struct_wl_message = extern struct {
    name: [*c]const u8 = null,
    signature: [*c]const u8 = null,
    types: [*c][*c]const struct_wl_interface = null,
};

pub const struct_wl_array = extern struct {
    size: usize = 0,
    alloc: usize = 0,
    data: ?*anyopaque = null,
};

pub const struct_wl_proxy = opaque {};
pub const wl_proxy = struct_wl_proxy;
pub const wl_interface = struct_wl_interface;

pub const struct_wl_display = opaque {};

pub extern fn wl_proxy_marshal_flags(proxy: ?*struct_wl_proxy, opcode: u32, interface: [*c]const struct_wl_interface, version: u32, flags: u32, ...) ?*struct_wl_proxy;

pub extern fn wl_proxy_destroy(proxy: ?*struct_wl_proxy) void;

pub extern fn wl_proxy_add_listener(proxy: ?*struct_wl_proxy, implementation: [*c]?*const fn () callconv(.c) void, data: ?*anyopaque) c_int;

pub extern fn wl_proxy_get_version(proxy: ?*struct_wl_proxy) u32;

pub const wl_object = opaque {};
pub const wl_argument = extern union {
    i: i32,
    u: u32,
    f: i32,
    s: [*c]const u8,
    o: ?*wl_object,
    n: u32,
    a: [*c]wl_array,
    h: i32,
};
pub extern fn wl_proxy_marshal_array_flags(proxy: ?*struct_wl_proxy, opcode: u32, interface: [*c]const struct_wl_interface, version: u32, flags: u32, args: [*c]wl_argument) ?*struct_wl_proxy;

pub extern fn wl_display_connect(name: [*c]const u8) ?*struct_wl_display;

pub extern fn wl_display_disconnect(display: ?*struct_wl_display) void;

pub extern fn wl_display_get_fd(display: ?*struct_wl_display) c_int;

pub extern fn wl_display_dispatch(display: ?*struct_wl_display) c_int;

pub extern fn wl_display_flush(display: ?*struct_wl_display) c_int;

pub extern fn wl_display_roundtrip(display: ?*struct_wl_display) c_int;

pub const struct_wl_buffer = opaque {};

pub const struct_wl_output = opaque {};

pub const struct_wl_registry = opaque {};

pub const struct_wl_seat = opaque {};

pub const struct_wl_shm = opaque {};

pub const struct_wl_shm_pool = opaque {};

pub extern const wl_registry_interface: struct_wl_interface;

pub extern const wl_shm_pool_interface: struct_wl_interface;

pub extern const wl_shm_interface: struct_wl_interface;

pub extern const wl_buffer_interface: struct_wl_interface;

pub extern const wl_seat_interface: struct_wl_interface;

pub extern const wl_output_interface: struct_wl_interface;

pub fn wl_display_get_registry(arg_wl_display_1: ?*struct_wl_display) callconv(.c) ?*struct_wl_registry {
    var wl_display_1 = arg_wl_display_1;
    _ = &wl_display_1;
    var registry: ?*struct_wl_proxy = undefined;
    _ = &registry;
    registry = wl_proxy_marshal_flags(@ptrCast(@alignCast(wl_display_1)), WL_DISPLAY_GET_REGISTRY, &wl_registry_interface, wl_proxy_get_version(@ptrCast(@alignCast(wl_display_1))), 0, @as(?*anyopaque, null));
    return @ptrCast(@alignCast(registry));
}

pub const struct_wl_registry_listener = extern struct {
    global: ?*const fn (data: ?*anyopaque, wl_registry: ?*struct_wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void = null,
    global_remove: ?*const fn (data: ?*anyopaque, wl_registry: ?*struct_wl_registry, name: u32) callconv(.c) void = null,
};

pub fn wl_registry_add_listener(arg_wl_registry_1: ?*struct_wl_registry, arg_listener: [*c]const struct_wl_registry_listener, arg_data: ?*anyopaque) callconv(.c) c_int {
    var wl_registry_1 = arg_wl_registry_1;
    _ = &wl_registry_1;
    var listener = arg_listener;
    _ = &listener;
    var data = arg_data;
    _ = &data;
    return wl_proxy_add_listener(@ptrCast(@alignCast(wl_registry_1)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn wl_registry_destroy(arg_wl_registry_1: ?*struct_wl_registry) callconv(.c) void {
    var wl_registry_1 = arg_wl_registry_1;
    _ = &wl_registry_1;
    wl_proxy_destroy(@ptrCast(@alignCast(wl_registry_1)));
}

pub fn wl_registry_bind(arg_wl_registry_1: ?*struct_wl_registry, arg_name: u32, arg_interface: [*c]const struct_wl_interface, arg_version: u32) callconv(.c) ?*anyopaque {
    var wl_registry_1 = arg_wl_registry_1;
    _ = &wl_registry_1;
    var name = arg_name;
    _ = &name;
    var interface = arg_interface;
    _ = &interface;
    var version = arg_version;
    _ = &version;
    var id: ?*struct_wl_proxy = undefined;
    _ = &id;
    id = wl_proxy_marshal_flags(@ptrCast(@alignCast(wl_registry_1)), WL_REGISTRY_BIND, interface, version, 0, name, interface.*.name, version, @as(?*anyopaque, null));
    return @ptrCast(@alignCast(id));
}

pub fn wl_shm_pool_create_buffer(arg_wl_shm_pool_1: ?*struct_wl_shm_pool, arg_offset: i32, arg_width: i32, arg_height: i32, arg_stride: i32, arg_format: u32) callconv(.c) ?*struct_wl_buffer {
    var wl_shm_pool_1 = arg_wl_shm_pool_1;
    _ = &wl_shm_pool_1;
    var offset = arg_offset;
    _ = &offset;
    var width = arg_width;
    _ = &width;
    var height = arg_height;
    _ = &height;
    var stride = arg_stride;
    _ = &stride;
    var format = arg_format;
    _ = &format;
    var id: ?*struct_wl_proxy = undefined;
    _ = &id;
    id = wl_proxy_marshal_flags(@ptrCast(@alignCast(wl_shm_pool_1)), WL_SHM_POOL_CREATE_BUFFER, &wl_buffer_interface, wl_proxy_get_version(@ptrCast(@alignCast(wl_shm_pool_1))), 0, @as(?*anyopaque, null), offset, width, height, stride, format);
    return @ptrCast(@alignCast(id));
}

pub fn wl_shm_pool_destroy(arg_wl_shm_pool_1: ?*struct_wl_shm_pool) callconv(.c) void {
    var wl_shm_pool_1 = arg_wl_shm_pool_1;
    _ = &wl_shm_pool_1;
    _ = wl_proxy_marshal_flags(@ptrCast(@alignCast(wl_shm_pool_1)), WL_SHM_POOL_DESTROY, null, wl_proxy_get_version(@ptrCast(@alignCast(wl_shm_pool_1))), @bitCast(@as(c_int, @as(c_int, 1) << @intCast(@as(c_int, 0)))));
}

pub const WL_SHM_FORMAT_ARGB8888: c_int = 0;

pub const WL_SHM_FORMAT_XRGB8888: c_int = 1;

pub const WL_SHM_FORMAT_XBGR8888: c_int = 875709016;

pub const WL_SHM_FORMAT_ABGR8888: c_int = 875708993;

pub fn wl_shm_destroy(arg_wl_shm_1: ?*struct_wl_shm) callconv(.c) void {
    var wl_shm_1 = arg_wl_shm_1;
    _ = &wl_shm_1;
    wl_proxy_destroy(@ptrCast(@alignCast(wl_shm_1)));
}

pub fn wl_shm_create_pool(arg_wl_shm_1: ?*struct_wl_shm, arg_fd: i32, arg_size: i32) callconv(.c) ?*struct_wl_shm_pool {
    var wl_shm_1 = arg_wl_shm_1;
    _ = &wl_shm_1;
    var fd = arg_fd;
    _ = &fd;
    var size = arg_size;
    _ = &size;
    var id: ?*struct_wl_proxy = undefined;
    _ = &id;
    id = wl_proxy_marshal_flags(@ptrCast(@alignCast(wl_shm_1)), WL_SHM_CREATE_POOL, &wl_shm_pool_interface, wl_proxy_get_version(@ptrCast(@alignCast(wl_shm_1))), 0, @as(?*anyopaque, null), fd, size);
    return @ptrCast(@alignCast(id));
}

pub fn wl_buffer_destroy(arg_wl_buffer_1: ?*struct_wl_buffer) callconv(.c) void {
    var wl_buffer_1 = arg_wl_buffer_1;
    _ = &wl_buffer_1;
    _ = wl_proxy_marshal_flags(@ptrCast(@alignCast(wl_buffer_1)), WL_BUFFER_DESTROY, null, wl_proxy_get_version(@ptrCast(@alignCast(wl_buffer_1))), @bitCast(@as(c_int, @as(c_int, 1) << @intCast(@as(c_int, 0)))));
}

pub fn wl_seat_destroy(arg_wl_seat_1: ?*struct_wl_seat) callconv(.c) void {
    var wl_seat_1 = arg_wl_seat_1;
    _ = &wl_seat_1;
    wl_proxy_destroy(@ptrCast(@alignCast(wl_seat_1)));
}

pub const WL_OUTPUT_MODE_CURRENT: c_int = 1;

pub const struct_wl_output_listener = extern struct {
    geometry: ?*const fn (data: ?*anyopaque, wl_output: ?*struct_wl_output, x: i32, y: i32, physical_width: i32, physical_height: i32, subpixel: i32, make: [*c]const u8, model: [*c]const u8, transform: i32) callconv(.c) void = null,
    mode: ?*const fn (data: ?*anyopaque, wl_output: ?*struct_wl_output, flags: u32, width: i32, height: i32, refresh: i32) callconv(.c) void = null,
    done: ?*const fn (data: ?*anyopaque, wl_output: ?*struct_wl_output) callconv(.c) void = null,
    scale: ?*const fn (data: ?*anyopaque, wl_output: ?*struct_wl_output, factor: i32) callconv(.c) void = null,
    name: ?*const fn (data: ?*anyopaque, wl_output: ?*struct_wl_output, name: [*c]const u8) callconv(.c) void = null,
    description: ?*const fn (data: ?*anyopaque, wl_output: ?*struct_wl_output, description: [*c]const u8) callconv(.c) void = null,
};

pub fn wl_output_add_listener(arg_wl_output_1: ?*struct_wl_output, arg_listener: [*c]const struct_wl_output_listener, arg_data: ?*anyopaque) callconv(.c) c_int {
    var wl_output_1 = arg_wl_output_1;
    _ = &wl_output_1;
    var listener = arg_listener;
    _ = &listener;
    var data = arg_data;
    _ = &data;
    return wl_proxy_add_listener(@ptrCast(@alignCast(wl_output_1)), @ptrCast(@alignCast(@constCast(listener))), data);
}

pub fn wl_output_destroy(arg_wl_output_1: ?*struct_wl_output) callconv(.c) void {
    var wl_output_1 = arg_wl_output_1;
    _ = &wl_output_1;
    wl_proxy_destroy(@ptrCast(@alignCast(wl_output_1)));
}

pub extern fn gdk_wayland_window_set_application_id(window: ?*GdkWindow, application_id: [*c]const u8) void;

pub const struct__PolkitAuthority = opaque {};

pub const PolkitAuthority = struct__PolkitAuthority;

pub const struct__PolkitSubject = opaque {};

pub const PolkitSubject = struct__PolkitSubject;

pub const struct__PolkitIdentity = opaque {};

pub const PolkitIdentity = struct__PolkitIdentity;

pub const struct__PolkitUnixUser = opaque {};

pub const PolkitUnixUser = struct__PolkitUnixUser;

pub const struct__PolkitDetails = opaque {};

pub const PolkitDetails = struct__PolkitDetails;

pub extern fn polkit_error_quark() GQuark;

pub const POLKIT_ERROR_FAILED: c_int = 0;

pub const POLKIT_ERROR_CANCELLED: c_int = 1;

pub extern fn polkit_unix_user_get_type() GType;

pub extern fn polkit_unix_user_get_uid(user: ?*PolkitUnixUser) gint;

pub extern fn polkit_unix_process_new_for_owner(pid: gint, start_time: guint64, uid: gint) ?*PolkitSubject;

pub extern fn polkit_unix_session_new(session_id: [*c]const gchar) ?*PolkitSubject;

pub extern fn polkit_unix_session_new_for_process_sync(pid: gint, cancellable: [*c]GCancellable, @"error": [*c][*c]GError) ?*PolkitSubject;

pub extern fn polkit_authority_get_sync(cancellable: [*c]GCancellable, @"error": [*c][*c]GError) ?*PolkitAuthority;

pub const struct__PolkitAgentListener = extern struct {
    parent_instance: GObject = @import("std").mem.zeroes(GObject),
};

pub const PolkitAgentListener = struct__PolkitAgentListener;

pub const struct__PolkitAgentSession = opaque {};

pub const PolkitAgentSession = struct__PolkitAgentSession;

pub const struct__PolkitAgentListenerClass = extern struct {
    parent_class: GObjectClass = @import("std").mem.zeroes(GObjectClass),
    initiate_authentication: ?*const fn (listener: [*c]PolkitAgentListener, action_id: [*c]const gchar, message: [*c]const gchar, icon_name: [*c]const gchar, details: ?*PolkitDetails, cookie: [*c]const gchar, identities: [*c]GList, cancellable: [*c]GCancellable, callback: GAsyncReadyCallback, user_data: gpointer) callconv(.c) void = null,
    initiate_authentication_finish: ?*const fn (listener: [*c]PolkitAgentListener, res: ?*GAsyncResult, @"error": [*c][*c]GError) callconv(.c) gboolean = null,
    _polkit_reserved0: ?*const fn () callconv(.c) void = null,
    _polkit_reserved1: ?*const fn () callconv(.c) void = null,
    _polkit_reserved2: ?*const fn () callconv(.c) void = null,
    _polkit_reserved3: ?*const fn () callconv(.c) void = null,
    _polkit_reserved4: ?*const fn () callconv(.c) void = null,
    _polkit_reserved5: ?*const fn () callconv(.c) void = null,
    _polkit_reserved6: ?*const fn () callconv(.c) void = null,
    _polkit_reserved7: ?*const fn () callconv(.c) void = null,
};

pub const PolkitAgentListenerClass = struct__PolkitAgentListenerClass;

pub extern fn polkit_agent_listener_get_type() GType;

pub const POLKIT_AGENT_REGISTER_FLAGS_NONE: c_int = 0;

pub const PolkitAgentRegisterFlags = c_uint;

pub extern fn polkit_agent_listener_register(listener: [*c]PolkitAgentListener, flags: PolkitAgentRegisterFlags, subject: ?*PolkitSubject, object_path: [*c]const gchar, cancellable: [*c]GCancellable, @"error": [*c][*c]GError) gpointer;

pub extern fn polkit_agent_listener_unregister(registration_handle: gpointer) void;

pub extern fn polkit_agent_session_new(identity: ?*PolkitIdentity, cookie: [*c]const gchar) ?*PolkitAgentSession;

pub extern fn polkit_agent_session_initiate(session: ?*PolkitAgentSession) void;

pub extern fn polkit_agent_session_response(session: ?*PolkitAgentSession, response: [*c]const gchar) void;

pub extern fn polkit_agent_session_cancel(session: ?*PolkitAgentSession) void;

pub const SIGINT = @as(c_int, 2);

pub const SIGTERM = @as(c_int, 15);

pub const SIGUSR1 = @as(c_int, 10);

pub const GDK_KEY_BackSpace = __helpers.promoteIntLiteral(c_int, 0xff08, .hex);

pub const GDK_KEY_Return = __helpers.promoteIntLiteral(c_int, 0xff0d, .hex);

pub const GDK_KEY_Escape = __helpers.promoteIntLiteral(c_int, 0xff1b, .hex);

pub const GDK_KEY_Left = __helpers.promoteIntLiteral(c_int, 0xff51, .hex);

pub const GDK_KEY_Up = __helpers.promoteIntLiteral(c_int, 0xff52, .hex);

pub const GDK_KEY_Right = __helpers.promoteIntLiteral(c_int, 0xff53, .hex);

pub const GDK_KEY_Down = __helpers.promoteIntLiteral(c_int, 0xff54, .hex);

pub const GDK_KEY_Page_Up = __helpers.promoteIntLiteral(c_int, 0xff55, .hex);

pub const GDK_KEY_Page_Down = __helpers.promoteIntLiteral(c_int, 0xff56, .hex);

pub const GDK_KEY_KP_Enter = __helpers.promoteIntLiteral(c_int, 0xff8d, .hex);

pub const GDK_KEY_Super_L = __helpers.promoteIntLiteral(c_int, 0xffeb, .hex);

pub const GDK_KEY_Super_R = __helpers.promoteIntLiteral(c_int, 0xffec, .hex);

pub const GTK_STYLE_PROVIDER_PRIORITY_APPLICATION = @as(c_int, 600);

pub const GTK_STYLE_PROVIDER_PRIORITY_USER = @as(c_int, 800);

pub const WL_DISPLAY_GET_REGISTRY = @as(c_int, 1);

pub const WL_REGISTRY_BIND = @as(c_int, 0);

pub const WL_SHM_POOL_CREATE_BUFFER = @as(c_int, 0);

pub const WL_SHM_POOL_DESTROY = @as(c_int, 1);

pub const WL_SHM_CREATE_POOL = @as(c_int, 0);

pub const WL_BUFFER_DESTROY = @as(c_int, 0);

pub const wl_array = struct_wl_array;

pub const wl_display = struct_wl_display;

pub const wl_buffer = struct_wl_buffer;

pub const wl_output = struct_wl_output;

pub const wl_registry = struct_wl_registry;

pub const wl_seat = struct_wl_seat;

pub const wl_shm = struct_wl_shm;

pub const wl_registry_listener = struct_wl_registry_listener;

pub const wl_output_listener = struct_wl_output_listener;

pub const GUnixFDList = extern struct { parent_instance: GObject, priv: ?*anyopaque };
pub const G_BUS_TYPE_SYSTEM: c_int = 1;
pub const GBusNameWatcherFlags = c_uint;
pub const GBusNameAppearedCallback = ?*const fn (?*GDBusConnection, [*c]const gchar, [*c]const gchar, gpointer) callconv(.c) void;
pub const GBusNameVanishedCallback = ?*const fn (?*GDBusConnection, [*c]const gchar, gpointer) callconv(.c) void;
pub extern fn g_bus_watch_name_on_connection(?*GDBusConnection, [*c]const gchar, GBusNameWatcherFlags, GBusNameAppearedCallback, GBusNameVanishedCallback, gpointer, GDestroyNotify) guint;
pub extern fn g_bus_unwatch_name(guint) void;
pub extern fn g_dbus_connection_is_closed(?*GDBusConnection) gboolean;
pub extern fn g_dbus_connection_set_exit_on_close(?*GDBusConnection, gboolean) void;
pub extern fn g_dbus_connection_call_with_unix_fd_list(?*GDBusConnection, [*c]const gchar, [*c]const gchar, [*c]const gchar, [*c]const gchar, ?*GVariant, ?*const GVariantType, GDBusCallFlags, gint, [*c]GUnixFDList, [*c]GCancellable, GAsyncReadyCallback, gpointer) void;
pub extern fn g_dbus_connection_call_with_unix_fd_list_finish(?*GDBusConnection, [*c][*c]GUnixFDList, ?*GAsyncResult, [*c][*c]GError) ?*GVariant;
pub extern fn g_unix_fd_list_get([*c]GUnixFDList, gint, [*c][*c]GError) gint;
pub extern fn g_variant_get_handle(?*GVariant) gint32;
pub extern fn g_variant_get_variant(?*GVariant) ?*GVariant;
pub extern fn g_file_read_link([*c]const gchar, [*c][*c]GError) [*c]gchar;
pub extern fn g_subprocess_launcher_take_fd(?*GSubprocessLauncher, gint, gint) void;

pub extern fn g_cancellable_is_cancelled([*c]GCancellable) gboolean;

// Native UPower property monitoring through GIO.
pub const GDBusProxy = extern struct {};
pub const GDBusProxyFlags = c_uint;
pub const G_DBUS_PROXY_FLAGS_DO_NOT_AUTO_START: GDBusProxyFlags = 4;
pub const G_DBUS_PROXY_FLAGS_GET_INVALIDATED_PROPERTIES: GDBusProxyFlags = 8;
pub extern fn g_dbus_proxy_new(?*GDBusConnection, GDBusProxyFlags, [*c]GDBusInterfaceInfo, [*c]const gchar, [*c]const gchar, [*c]const gchar, [*c]GCancellable, GAsyncReadyCallback, gpointer) void;
pub extern fn g_dbus_proxy_new_finish(?*GAsyncResult, [*c][*c]GError) [*c]GDBusProxy;
pub extern fn g_dbus_proxy_get_cached_property([*c]GDBusProxy, [*c]const gchar) ?*GVariant;
pub extern fn g_dbus_proxy_get_name_owner([*c]GDBusProxy) [*c]gchar;
pub extern fn g_dbus_proxy_get_connection([*c]GDBusProxy) ?*GDBusConnection;
pub extern fn g_variant_get_type_string(?*GVariant) [*c]const gchar;
pub extern fn g_variant_get_double(?*GVariant) f64;
pub extern fn g_variant_get_int64(?*GVariant) gint64;

pub extern fn g_variant_get_uint64(?*GVariant) u64;
pub extern fn g_variant_print(?*GVariant, gboolean) [*c]gchar;
pub extern fn g_variant_parse(?*const GVariantType, [*c]const gchar, [*c]const gchar, [*c][*c]const gchar, [*c][*c]GError) ?*GVariant;
pub extern fn g_variant_type_string_is_valid([*c]const gchar) gboolean;
pub extern fn g_uuid_string_random() [*c]gchar;

pub extern fn g_dbus_error_get_remote_error([*c]const GError) [*c]gchar;

pub extern fn gtk_dialog_get_widget_for_response([*c]GtkDialog, gint) [*c]GtkWidget;

pub extern fn g_variant_type_is_definite(?*const GVariantType) gboolean;

// Native portal broker: tuples and Unix file descriptor forwarding.
pub const GDBusMessage = opaque {};
pub extern fn g_variant_new_tuple([*c]const ?*GVariant, gsize) ?*GVariant;
pub extern fn g_dbus_method_invocation_get_message(?*GDBusMethodInvocation) ?*GDBusMessage;
pub extern fn g_dbus_message_get_unix_fd_list(?*GDBusMessage) [*c]GUnixFDList;
pub extern fn g_dbus_method_invocation_return_value_with_unix_fd_list(?*GDBusMethodInvocation, ?*GVariant, [*c]GUnixFDList) void;
pub extern fn g_unix_fd_list_new() [*c]GUnixFDList;
pub extern fn g_unix_fd_list_append([*c]GUnixFDList, gint, [*c][*c]GError) gint;
pub extern fn g_app_info_launch_default_for_uri_async([*c]const gchar, ?*GAppLaunchContext, [*c]GCancellable, GAsyncReadyCallback, gpointer) void;
pub extern fn g_app_info_launch_default_for_uri_finish(?*GAsyncResult, [*c][*c]GError) gboolean;
pub extern fn g_app_info_get_default_for_uri_scheme([*c]const gchar) ?*GAppInfo;
pub extern fn g_file_get_uri(?*GFile) [*c]gchar;
pub extern fn g_variant_ref(?*GVariant) ?*GVariant;
pub extern fn g_variant_take_ref(?*GVariant) ?*GVariant;
pub const GVariantBuilder = opaque {};
pub extern fn g_variant_builder_new(?*const GVariantType) ?*GVariantBuilder;
pub extern fn g_variant_builder_add(?*GVariantBuilder, [*c]const gchar, ...) void;
pub extern fn g_variant_builder_end(?*GVariantBuilder) ?*GVariant;
pub extern fn g_variant_builder_unref(?*GVariantBuilder) void;
pub const GNetworkMonitor = opaque {};
pub extern fn g_network_monitor_get_default() ?*GNetworkMonitor;
pub extern fn g_network_monitor_get_network_available(?*GNetworkMonitor) gboolean;
pub extern fn g_network_monitor_get_network_metered(?*GNetworkMonitor) gboolean;
pub extern fn g_network_monitor_get_connectivity(?*GNetworkMonitor) c_uint;
pub extern fn g_variant_new_array(?*const GVariantType, [*c]const ?*GVariant, gsize) ?*GVariant;
pub extern fn g_file_query_file_type(?*GFile, c_uint, [*c]GCancellable) c_uint;
pub const GSocketConnectable = opaque {};
pub extern fn g_network_address_new([*c]const gchar, u16) ?*GSocketConnectable;
pub extern fn g_network_monitor_can_reach_async(?*GNetworkMonitor, ?*GSocketConnectable, [*c]GCancellable, GAsyncReadyCallback, gpointer) void;
pub extern fn g_network_monitor_can_reach_finish(?*GNetworkMonitor, ?*GAsyncResult, [*c][*c]GError) gboolean;

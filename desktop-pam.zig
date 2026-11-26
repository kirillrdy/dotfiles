//! Linux-PAM application and module ABI, declared explicitly. libpam stays:
//! modules are shared objects it loads from /etc/pam.d policy. Tests compare
//! these declarations with the installed headers (tests/desktop-libc-abi.zig).
pub const pam_handle_t = opaque {};

pub const pam_message = extern struct {
    msg_style: c_int,
    msg: [*c]const u8,
};
pub const pam_response = extern struct {
    resp: [*c]u8,
    resp_retcode: c_int,
};
pub const pam_conv = extern struct {
    conv: ?*const fn (c_int, [*c]const [*c]const pam_message, [*c][*c]pam_response, ?*anyopaque) callconv(.c) c_int,
    appdata_ptr: ?*anyopaque,
};

pub extern fn pam_start(service: ?[*:0]const u8, user: ?[*:0]const u8, conversation: ?*const pam_conv, handle: ?*?*pam_handle_t) c_int;
pub extern fn pam_start_confdir(service: ?[*:0]const u8, user: ?[*:0]const u8, conversation: ?*const pam_conv, confdir: ?[*:0]const u8, handle: ?*?*pam_handle_t) c_int;
pub extern fn pam_end(handle: ?*pam_handle_t, status: c_int) c_int;
pub extern fn pam_authenticate(handle: ?*pam_handle_t, flags: c_int) c_int;
pub extern fn pam_acct_mgmt(handle: ?*pam_handle_t, flags: c_int) c_int;
pub extern fn pam_setcred(handle: ?*pam_handle_t, flags: c_int) c_int;
pub extern fn pam_open_session(handle: ?*pam_handle_t, flags: c_int) c_int;
pub extern fn pam_close_session(handle: ?*pam_handle_t, flags: c_int) c_int;
pub extern fn pam_set_item(handle: ?*pam_handle_t, item: c_int, value: ?*const anyopaque) c_int;
pub extern fn pam_get_item(handle: ?*const pam_handle_t, item: c_int, value: ?*?*const anyopaque) c_int;
pub extern fn pam_get_user(handle: ?*pam_handle_t, user: ?*?[*:0]const u8, prompt: ?[*:0]const u8) c_int;
pub extern fn pam_putenv(handle: ?*pam_handle_t, name_value: ?[*:0]const u8) c_int;
pub extern fn pam_getenv(handle: ?*pam_handle_t, name: ?[*:0]const u8) ?[*:0]const u8;
pub extern fn pam_getenvlist(handle: ?*pam_handle_t) [*c][*c]u8;
pub extern fn pam_set_data(handle: ?*pam_handle_t, name: ?[*:0]const u8, data: ?*anyopaque, cleanup: ?*const fn (?*pam_handle_t, ?*anyopaque, c_int) callconv(.c) void) c_int;
pub extern fn pam_get_data(handle: ?*const pam_handle_t, name: ?[*:0]const u8, data: ?*?*const anyopaque) c_int;

// Return codes.
pub const PAM_SUCCESS = 0;
pub const PAM_SYSTEM_ERR = 4;
pub const PAM_BUF_ERR = 5;
pub const PAM_USER_UNKNOWN = 10;
pub const PAM_SESSION_ERR = 14;
pub const PAM_CONV_ERR = 19;
pub const PAM_IGNORE = 25;
// Conversation message styles.
pub const PAM_PROMPT_ECHO_OFF = 1;
pub const PAM_PROMPT_ECHO_ON = 2;
pub const PAM_ERROR_MSG = 3;
pub const PAM_TEXT_INFO = 4;
// Flags.
pub const PAM_DISALLOW_NULL_AUTHTOK = 0x1;
pub const PAM_ESTABLISH_CRED = 0x2;
pub const PAM_DELETE_CRED = 0x4;
// Items.
pub const PAM_TTY = 3;
pub const PAM_AUTHTOK = 6;

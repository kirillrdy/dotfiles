//! PAM client definitions for authentication fixtures and tests.
pub const pam_handle_t = opaque {};
pub const PAM_SUCCESS = @as(c_int, 0);
pub const PAM_BUF_ERR = @as(c_int, 5);
pub const PAM_AUTH_ERR = @as(c_int, 7);
pub const PAM_USER_UNKNOWN = @as(c_int, 10);
pub const PAM_ACCT_EXPIRED = @as(c_int, 13);
pub const PAM_CONV_ERR = @as(c_int, 19);
pub const PAM_DISALLOW_NULL_AUTHTOK = @as(c_int, 0x0001);
pub const PAM_ERROR_MSG = @as(c_int, 3);
pub const PAM_TEXT_INFO = @as(c_int, 4);

pub const pam_message = extern struct {
    msg_style: c_int = 0,
    msg: [*c]const u8 = null,
};
pub const pam_response = extern struct {
    resp: [*c]u8 = null,
    resp_retcode: c_int = 0,
};
pub const pam_conv = extern struct {
    conv: ?*const fn (num_msg: c_int, msg: [*c][*c]const pam_message, resp: [*c][*c]pam_response, appdata_ptr: ?*anyopaque) callconv(.c) c_int = null,
    appdata_ptr: ?*anyopaque = null,
};

pub extern fn pam_start_confdir(service_name: [*c]const u8, user: [*c]const u8, pam_conversation: [*c]const pam_conv, confdir: [*c]const u8, pamh: [*c]?*pam_handle_t) c_int;
pub extern fn pam_end(pamh: ?*pam_handle_t, pam_status: c_int) c_int;
pub extern fn pam_authenticate(pamh: ?*pam_handle_t, flags: c_int) c_int;
pub extern fn pam_acct_mgmt(pamh: ?*pam_handle_t, flags: c_int) c_int;
pub extern fn pam_open_session(pamh: ?*pam_handle_t, flags: c_int) c_int;
pub extern fn pam_close_session(pamh: ?*pam_handle_t, flags: c_int) c_int;

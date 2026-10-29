//! Small POSIX C ABI surface for Linux desktop helpers.
//! Platform constants and common layouts come from Zig's standard library.
//! The remaining declarations are verified by test-libc-abi, without parsing
//! system headers during ordinary builds.
const std = @import("std");
// Linux/glibc statvfs layout on the desktop's 64-bit targets.
pub const struct_statvfs = extern struct {
    f_bsize: c_ulong = 0,
    f_frsize: c_ulong = 0,
    f_blocks: c_ulong = 0,
    f_bfree: c_ulong = 0,
    f_bavail: c_ulong = 0,
    f_files: c_ulong = 0,
    f_ffree: c_ulong = 0,
    f_favail: c_ulong = 0,
    f_fsid: c_ulong = 0,
    f_flag: c_ulong = 0,
    f_namemax: c_ulong = 0,
    f_type: c_uint = 0,
    __f_spare: [5]c_int = @splat(0),
};

pub extern fn statvfs(path: [*c]const u8, buf: [*c]struct_statvfs) c_int;

pub const __uid_t = c_uint;

pub const __ino_t = c_ulong;

pub const __off_t = c_long;

pub const __pid_t = c_int;

pub const __socklen_t = c_uint;

pub const socklen_t = __socklen_t;

pub extern fn close(__fd: c_int) c_int;

pub extern fn read(__fd: c_int, __buf: ?*anyopaque, __nbytes: usize) isize;

pub extern fn write(__fd: c_int, __buf: ?*const anyopaque, __n: usize) isize;

pub extern fn pipe2(__pipedes: [*c]c_int, __flags: c_int) c_int;

pub extern fn geteuid() __uid_t;

pub extern fn isatty(__fd: c_int) c_int;

pub extern fn unlink(__name: [*c]const u8) c_int;

pub extern fn fsync(__fd: c_int) c_int;

pub const time_t = std.c.time_t;

pub extern fn getenv(__name: [*c]const u8) [*c]u8;

pub extern fn mkdtemp(__template: [*c]u8) [*c]u8;

pub extern fn open(__file: [*c]const u8, __oflag: c_int, ...) c_int;

pub const struct_dirent = extern struct {
    d_ino: __ino_t = 0,
    d_off: __off_t = 0,
    d_reclen: c_ushort = 0,
    d_type: u8 = 0,
    d_name: [256]u8 = @import("std").mem.zeroes([256]u8),
};

pub const struct___dirstream = opaque {};

pub const DIR = struct___dirstream;

pub extern fn closedir(__dirp: ?*DIR) c_int;

pub extern fn opendir(__name: [*c]const u8) ?*DIR;

pub extern fn readdir(__dirp: ?*DIR) [*c]struct_dirent;

pub extern fn __errno_location() [*c]c_int;

pub extern fn rename(__old: [*c]const u8, __new: [*c]const u8) c_int;

pub extern fn snprintf(noalias __s: [*c]u8, __maxlen: usize, noalias __format: [*c]const u8, ...) c_int;

pub extern fn flock(fd: c_int, operation: c_int) c_int;

pub const WNOHANG: c_int = @intCast(std.c.W.NOHANG);

pub const O_RDONLY: c_int = @bitCast(@as(u32, @bitCast(@as(std.c.O, .{}))));

pub const O_WRONLY: c_int = @bitCast(@as(u32, @bitCast(@as(std.c.O, .{ .ACCMODE = .WRONLY }))));

pub const O_CREAT: c_int = @bitCast(@as(u32, @bitCast(@as(std.c.O, .{ .CREAT = true }))));

pub const O_TRUNC: c_int = @bitCast(@as(u32, @bitCast(@as(std.c.O, .{ .TRUNC = true }))));

pub const O_NONBLOCK: c_int = @bitCast(@as(u32, @bitCast(@as(std.c.O, .{ .NONBLOCK = true }))));

pub const O_NOFOLLOW: c_int = @bitCast(@as(u32, @bitCast(@as(std.c.O, .{ .NOFOLLOW = true }))));

pub const O_CLOEXEC: c_int = @bitCast(@as(u32, @bitCast(@as(std.c.O, .{ .CLOEXEC = true }))));

pub const LOCK_EX: c_int = @intCast(std.c.LOCK.EX);

pub const ENOENT: c_int = @intCast(@backingInt(std.c.E.NOENT));

pub const EINTR: c_int = @intCast(@backingInt(std.c.E.INTR));

pub const __sighandler_t = ?*const fn (c_int) callconv(.c) void;

pub extern fn signal(__sig: c_int, __handler: __sighandler_t) __sighandler_t;

pub const cc_t = u8;

pub const speed_t = c_uint;

pub const tcflag_t = c_uint;
const union_unnamed_32 = extern union {
    __ispeed: speed_t,
    c_ispeed: speed_t,
};
const union_unnamed_33 = extern union {
    __ospeed: speed_t,
    c_ospeed: speed_t,
};

pub const struct_termios = extern struct {
    c_iflag: tcflag_t = 0,
    c_oflag: tcflag_t = 0,
    c_cflag: tcflag_t = 0,
    c_lflag: tcflag_t = 0,
    c_line: cc_t = 0,
    c_cc: [32]cc_t = @import("std").mem.zeroes([32]cc_t),
    unnamed_0: union_unnamed_32 = @import("std").mem.zeroes(union_unnamed_32),
    unnamed_1: union_unnamed_33 = @import("std").mem.zeroes(union_unnamed_33),
};

pub extern fn tcgetattr(__fd: c_int, __termios_p: [*c]struct_termios) c_int;

pub extern fn tcsetattr(__fd: c_int, __optional_actions: c_int, __termios_p: [*c]const struct_termios) c_int;

pub extern fn cfmakeraw(__termios_p: [*c]struct_termios) void;

pub const nfds_t = c_ulong;

pub const struct_pollfd = std.c.pollfd;

pub extern fn poll(__fds: [*c]struct_pollfd, __nfds: nfds_t, __timeout: c_int) c_int;

pub const struct_tm = extern struct {
    tm_sec: c_int = 0,
    tm_min: c_int = 0,
    tm_hour: c_int = 0,
    tm_mday: c_int = 0,
    tm_mon: c_int = 0,
    tm_year: c_int = 0,
    tm_wday: c_int = 0,
    tm_yday: c_int = 0,
    tm_isdst: c_int = 0,
    tm_gmtoff: c_long = 0,
    tm_zone: [*c]const u8 = null,
};

pub extern fn time(__timer: [*c]time_t) time_t;

pub extern fn strftime(noalias __s: [*c]u8, __maxsize: usize, noalias __format: [*c]const u8, noalias __tp: [*c]const struct_tm) usize;

pub extern fn localtime_r(noalias __timer: [*c]const time_t, noalias __tp: [*c]struct_tm) [*c]struct_tm;

pub const SOCK_STREAM: c_int = @intCast(std.c.SOCK.STREAM);

pub const SOCK_CLOEXEC: c_int = @intCast(std.c.SOCK.CLOEXEC);

pub const sa_family_t = c_ushort;

pub const struct_sockaddr = extern struct {
    sa_family: sa_family_t = 0,
    sa_data: [14]u8 = @import("std").mem.zeroes([14]u8),
};

pub const MSG_NOSIGNAL: c_int = @intCast(std.c.MSG.NOSIGNAL);

pub const struct_sockaddr_un = extern struct {
    sun_family: sa_family_t = 0,
    sun_path: [108]u8 = @import("std").mem.zeroes([108]u8),
};

pub extern fn socket(__domain: c_int, __type: c_int, __protocol: c_int) c_int;

pub extern fn connect(fd: c_int, address: *const std.c.sockaddr, length: std.c.socklen_t) c_int;

pub extern fn send(__fd: c_int, __buf: ?*const anyopaque, __n: usize, __flags: c_int) isize;

pub extern fn prctl(__option: c_int, ...) c_int;

pub const SIGINT: c_int = @intCast(@backingInt(std.posix.SIG.INT));

pub const SIGTERM: c_int = @intCast(@backingInt(std.posix.SIG.TERM));

pub const SIGHUP: c_int = @intCast(@backingInt(std.posix.SIG.HUP));

pub const ISIG = @as(c_int, 0o000001);

pub const TCSAFLUSH = @as(c_int, 2);

pub const POLLIN: c_int = @intCast(std.c.POLL.IN);

pub const AF_UNIX: c_int = @intCast(std.c.AF.UNIX);

pub const PR_SET_DUMPABLE = @as(c_int, 4);

pub const pollfd = struct_pollfd;

pub const sockaddr = struct_sockaddr;

pub extern fn waitpid(__pid: __pid_t, __stat_loc: [*c]c_int, __options: c_int) __pid_t;

pub const __gid_t = c_uint;

pub const struct_passwd = extern struct {
    pw_name: [*c]u8 = null,
    pw_passwd: [*c]u8 = null,
    pw_uid: __uid_t = 0,
    pw_gid: __gid_t = 0,
    pw_gecos: [*c]u8 = null,
    pw_dir: [*c]u8 = null,
    pw_shell: [*c]u8 = null,
};

pub extern fn getpwuid(__uid: __uid_t) [*c]struct_passwd;

pub extern fn getuid() __uid_t;
pub const struct_ucred = extern struct { pid: c_int, uid: c_uint, gid: c_uint };
pub const SOL_SOCKET = std.c.SOL.SOCKET;
pub const SO_PEERCRED = std.c.SO.PEERCRED;
pub extern fn getsockopt(c_int, c_int, c_int, ?*anyopaque, *socklen_t) c_int;

pub extern fn getpid() __pid_t;

pub extern fn fork() __pid_t;

pub extern fn ftruncate(__fd: c_int, __length: __off_t) c_int;

pub extern fn raise(__sig: c_int) c_int;

pub extern fn memfd_create(__name: [*c]const u8, __flags: c_uint) c_int;

pub extern fn mmap(__addr: ?*anyopaque, __len: usize, __prot: c_int, __flags: c_int, __fd: c_int, __offset: __off_t) ?*anyopaque;

pub extern fn munmap(__addr: ?*anyopaque, __len: usize) c_int;

pub const PROT_READ = @as(c_int, 0x1);

pub const PROT_WRITE = @as(c_int, 0x2);

pub const MAP_SHARED = @as(c_int, 0x01);

pub const MFD_CLOEXEC = @as(c_uint, 1);

pub const MAP_FAILED = @as(?*anyopaque, @ptrFromInt(std.math.maxInt(usize)));

pub const SIGUSR1: c_int = @intCast(@backingInt(std.posix.SIG.USR1));

pub const STDOUT_FILENO = @as(c_int, 1);

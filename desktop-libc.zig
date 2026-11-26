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
pub const socklen_t = c_uint;
pub extern fn close(__fd: c_int) c_int;
pub extern fn read(__fd: c_int, __buf: ?*anyopaque, __nbytes: usize) isize;
pub extern fn write(__fd: c_int, __buf: ?*const anyopaque, __n: usize) isize;
pub extern fn pipe2(__pipedes: [*c]c_int, __flags: c_int) c_int;
pub extern fn geteuid() c_uint;
pub extern fn unlink(__name: [*c]const u8) c_int;
pub extern fn fsync(__fd: c_int) c_int;
pub const time_t = std.c.time_t;
pub extern fn getenv(__name: [*c]const u8) [*c]u8;
pub extern fn setenv(__name: [*c]const u8, __value: [*c]const u8, __replace: c_int) c_int;
pub extern fn mkdtemp(__template: [*c]u8) [*c]u8;
pub extern fn open(__file: [*c]const u8, __oflag: c_int, ...) c_int;

pub const struct_dirent = extern struct {
    d_ino: c_ulong = 0,
    d_off: c_long = 0,
    d_reclen: c_ushort = 0,
    d_type: u8 = 0,
    d_name: [256]u8 = @splat(0),

    pub fn name(self: *const struct_dirent) [:0]const u8 {
        // readdir only supplies bytes through the name's terminating NUL.
        return std.mem.span(@as([*:0]const u8, @ptrCast(&self.d_name)));
    }
};

pub const DIR = opaque {};
pub extern fn closedir(__dirp: ?*DIR) c_int;
pub extern fn opendir(__name: [*c]const u8) ?*DIR;
pub extern fn readdir(__dirp: ?*DIR) [*c]struct_dirent;
pub extern fn __errno_location() [*c]c_int;
pub extern fn rename(__old: [*c]const u8, __new: [*c]const u8) c_int;
pub extern fn snprintf(noalias __s: [*c]u8, __maxlen: usize, noalias __format: [*c]const u8, ...) c_int;
pub extern fn flock(fd: c_int, operation: c_int) c_int;
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
pub extern fn signal(__sig: c_int, __handler: ?*const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;
pub const pollfd = std.c.pollfd;
pub extern fn poll(__fds: [*c]pollfd, __nfds: c_ulong, __timeout: c_int) c_int;

// Only desktop-datetime.zig's test uses libc local time, as an oracle.
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

pub extern fn localtime_r(noalias __timer: [*c]const time_t, noalias __tp: [*c]struct_tm) [*c]struct_tm;
pub const SOCK_STREAM: c_int = @intCast(std.c.SOCK.STREAM);
pub const SOCK_CLOEXEC: c_int = @intCast(std.c.SOCK.CLOEXEC);

pub const sockaddr = extern struct {
    sa_family: c_ushort = 0,
    sa_data: [14]u8 = @splat(0),
};

pub const MSG_NOSIGNAL: c_int = @intCast(std.c.MSG.NOSIGNAL);

pub const struct_sockaddr_un = extern struct {
    sun_family: c_ushort = 0,
    sun_path: [108]u8 = @splat(0),
};

pub extern fn socket(__domain: c_int, __type: c_int, __protocol: c_int) c_int;
pub const AF_NETLINK: c_int = @intCast(std.c.AF.NETLINK);
pub const SOCK_DGRAM: c_int = @intCast(std.c.SOCK.DGRAM);
pub const SOCK_NONBLOCK: c_int = @intCast(std.c.SOCK.NONBLOCK);
pub const NETLINK_KOBJECT_UEVENT: c_int = 15;
pub const struct_sockaddr_nl = extern struct {
    nl_family: c_ushort = 0,
    nl_pad: c_ushort = 0,
    nl_pid: u32 = 0,
    nl_groups: u32 = 0,
};
pub extern fn bind(c_int, *const std.c.sockaddr, socklen_t) c_int;
pub extern fn recvfrom(c_int, ?*anyopaque, usize, c_int, [*c]std.c.sockaddr, [*c]socklen_t) isize;
pub extern fn connect(fd: c_int, address: *const std.c.sockaddr, length: std.c.socklen_t) c_int;
pub extern fn send(__fd: c_int, __buf: ?*const anyopaque, __n: usize, __flags: c_int) isize;
pub extern fn prctl(__option: c_int, ...) c_int;
pub const SIGINT: c_int = @intCast(@backingInt(std.posix.SIG.INT));
pub const SIGTERM: c_int = @intCast(@backingInt(std.posix.SIG.TERM));
pub const SIGHUP: c_int = @intCast(@backingInt(std.posix.SIG.HUP));
pub const AF_UNIX: c_int = @intCast(std.c.AF.UNIX);
pub const PR_SET_DUMPABLE = @as(c_int, 4);
pub extern fn waitpid(__pid: c_int, __stat_loc: [*c]c_int, __options: c_int) c_int;

pub const struct_passwd = extern struct {
    pw_name: [*c]u8 = null,
    pw_passwd: [*c]u8 = null,
    pw_uid: c_uint = 0,
    pw_gid: c_uint = 0,
    pw_gecos: [*c]u8 = null,
    pw_dir: [*c]u8 = null,
    pw_shell: [*c]u8 = null,
};

pub extern fn getpwuid(__uid: c_uint) [*c]struct_passwd;
pub extern fn getuid() c_uint;
pub const struct_ucred = extern struct { pid: c_int, uid: c_uint, gid: c_uint };
pub const SOL_SOCKET = std.c.SOL.SOCKET;
pub const SO_PEERCRED = std.c.SO.PEERCRED;
pub extern fn getsockopt(c_int, c_int, c_int, ?*anyopaque, *socklen_t) c_int;
pub extern fn getpid() c_int;
pub extern fn fork() c_int;
pub extern fn ftruncate(__fd: c_int, __length: c_long) c_int;
pub extern fn raise(__sig: c_int) c_int;
pub extern fn memfd_create(__name: [*c]const u8, __flags: c_uint) c_int;
pub extern fn mmap(__addr: ?*anyopaque, __len: usize, __prot: c_int, __flags: c_int, __fd: c_int, __offset: c_long) ?*anyopaque;
pub extern fn munmap(__addr: ?*anyopaque, __len: usize) c_int;
pub extern fn mlock(addr: ?*const anyopaque, len: usize) c_int;
pub extern fn munlock(addr: ?*const anyopaque, len: usize) c_int;
pub extern fn setsid() c_int;
pub const PROT_READ = @as(c_int, 0x1);
pub const PROT_WRITE = @as(c_int, 0x2);
pub const MAP_SHARED = @as(c_int, 0x01);
pub const MAP_PRIVATE = @as(c_int, 0x02);
pub const MFD_CLOEXEC = @as(c_uint, 1);
pub const MAP_FAILED = @as(?*anyopaque, @ptrFromInt(std.math.maxInt(usize)));
pub const STDOUT_FILENO = @as(c_int, 1);
pub const O_RDWR: c_int = @bitCast(@as(u32, @bitCast(@as(std.c.O, .{ .ACCMODE = .RDWR }))));
pub const LOCK_NB: c_int = @intCast(std.c.LOCK.NB);
pub const EEXIST: c_int = @intCast(@backingInt(std.c.E.EXIST));
pub const F_SETFD: c_int = std.c.F.SETFD;
pub const R_OK: c_int = std.c.R_OK;
pub extern fn getpwnam(__name: [*c]const u8) [*c]struct_passwd;
pub extern fn setpwent() void;
pub extern fn endpwent() void;
pub extern fn getpwent() [*c]struct_passwd;
pub extern fn getegid() c_uint;
pub extern fn setuid(__uid: c_uint) c_int;
pub extern fn setgid(__gid: c_uint) c_int;
pub extern fn initgroups(__user: [*c]const u8, __group: c_uint) c_int;
pub extern fn dup2(__fd: c_int, __fd2: c_int) c_int;
pub extern fn fcntl(__fd: c_int, __cmd: c_int, ...) c_int;
pub extern fn close_range(__fd: c_uint, __max_fd: c_uint, __flags: c_int) c_int;
pub extern fn socketpair(__domain: c_int, __type: c_int, __protocol: c_int, __fds: [*c]c_int) c_int;
pub extern fn execv(__path: [*c]const u8, __argv: [*c]const [*c]u8) c_int;
pub extern fn execve(__path: [*c]const u8, __argv: [*c]const [*c]u8, __envp: [*c]const [*c]u8) c_int;
pub extern fn _exit(__status: c_int) noreturn;
pub extern fn mkdir(__path: [*c]const u8, __mode: c_uint) c_int;
pub extern fn rmdir(__path: [*c]const u8) c_int;
pub extern fn access(__name: [*c]const u8, __type: c_int) c_int;
pub extern fn getrandom(__buffer: ?*anyopaque, __length: usize, __flags: c_uint) isize;

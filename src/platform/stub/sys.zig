//! OS services of the contract: clocks, randomness, files, directories,
//! descriptors, poll and local sockets. Descriptors are small integers
//! (a port maps its handles onto them); errors come from `Error`.

const std = @import("std");

pub const fd_t = i32;

const Error = error{
    AccessDenied,
    AddressInUse,
    BrokenPipe,
    CannotCreateTempDir,
    ConnectionRefused,
    ConnectionReset,
    DirNotEmpty,
    DiskQuota,
    FileTooBig,
    Interrupted,
    NameTooLong,
    NoSpaceLeft,
    NotDir,
    NotFound,
    OutOfMemory,
    PathAlreadyExists,
    PathTooLong,
    ReadOnlyFileSystem,
    SyscallFailed,
    Timeout,
    TooManyFds,
    WouldBlock,
};

pub const pollfd = extern struct { fd: fd_t, events: i16, revents: i16 };
pub const POLL = struct {
    pub const IN: i16 = 0x001;
    pub const OUT: i16 = 0x004;
    pub const ERR: i16 = 0x008;
    pub const HUP: i16 = 0x010;
    pub const NVAL: i16 = 0x020;
};

pub const DirEntry = struct { name: []u8, is_dir: bool };

// clocks and randomness
pub fn monoMs() i64 {
    return 0;
}
pub fn realtimeSec() i64 {
    return 0;
}
pub fn realtimeMs() i64 {
    return 0;
}
pub fn getRandom(buf: []u8) void {
    @memset(buf, 0);
}
pub fn monoNs() i64 {
    return 0;
}
pub fn sleepMs(ms: u64) void {
    _ = ms;
}
pub fn processId() u32 {
    return 0;
}
pub fn timeoutUntil(deadline_ms: ?i64) i32 {
    _ = deadline_ms;
    return -1;
}

// descriptors
pub fn read(fd: fd_t, buf: []u8) Error!usize {
    _ = .{ fd, buf };
    return error.SyscallFailed;
}
pub fn writeAll(fd: fd_t, buf: []const u8) Error!void {
    _ = .{ fd, buf };
    return error.SyscallFailed;
}
pub fn writeAllBlocking(fd: fd_t, buf: []const u8) Error!void {
    _ = .{ fd, buf };
    return error.SyscallFailed;
}
pub fn pipe() Error![2]fd_t {
    return error.SyscallFailed;
}
pub fn close(fd: fd_t) void {
    _ = fd;
}
pub fn poll(fds: []pollfd, timeout_ms: i32) Error!usize {
    _ = .{ fds, timeout_ms };
    return error.SyscallFailed;
}
pub fn waitReadable(fd: fd_t, deadline_ms: ?i64) Error!bool {
    _ = .{ fd, deadline_ms };
    return error.SyscallFailed;
}
pub fn fsync(fd: fd_t) void {
    _ = fd;
}
pub fn lockExclusive(fd: fd_t) Error!void {
    _ = fd;
    return error.SyscallFailed;
}

/// Map the whole file at `path` read-only; error.BadSize unless it holds
/// `min`..`max` bytes.
pub fn mapFile(path: []const u8, min: u64, max: u64) (Error || error{ BadSize, MmapFailed })![]const u8 {
    _ = .{ path, min, max };
    return error.NotFound;
}
pub fn unmapFile(d: []const u8) void {
    _ = d;
}

// files by path
pub fn openRead(path: []const u8) Error!fd_t {
    _ = path;
    return error.NotFound;
}
pub fn createWrite(path: []const u8) Error!fd_t {
    _ = path;
    return error.AccessDenied;
}
pub fn createExclusive(path: []const u8, mode: u32) Error!fd_t {
    _ = .{ path, mode };
    return error.AccessDenied;
}
pub fn writeFileExclusive(path: []const u8, data: []const u8, mode: u32) Error!void {
    _ = .{ path, data, mode };
    return error.AccessDenied;
}
pub fn writeFile(path: []const u8, data: []const u8) Error!void {
    _ = .{ path, data };
    return error.AccessDenied;
}
pub fn readFileAlloc(alloc: std.mem.Allocator, path: []const u8, max: usize) Error![]u8 {
    _ = .{ alloc, path, max };
    return error.NotFound;
}
pub fn readFileBuf(path: []const u8, buf: []u8) Error![]u8 {
    _ = .{ path, buf };
    return error.NotFound;
}
pub fn unlink(path: []const u8) Error!void {
    _ = path;
    return error.NotFound;
}
pub fn rename(old_path: []const u8, new_path: []const u8) Error!void {
    _ = .{ old_path, new_path };
    return error.NotFound;
}
pub fn mtimeSec(path: []const u8) ?i64 {
    _ = path;
    return null;
}
pub fn fileMode(path: []const u8) ?u32 {
    _ = path;
    return null;
}
pub fn symlink(target: []const u8, path: []const u8) Error!void {
    _ = .{ target, path };
    return error.AccessDenied;
}
pub fn fileSize(path: []const u8) Error!u64 {
    _ = path;
    return error.NotFound;
}

// directories
pub fn openDir(path: []const u8) Error!fd_t {
    _ = path;
    return error.NotFound;
}
pub fn mkdirMode(path: []const u8, mode: u32) void {
    _ = .{ path, mode };
}
pub fn mkdirAll(path: []const u8, mode: u32) void {
    _ = .{ path, mode };
}
pub fn makeTempDir(alloc: std.mem.Allocator, base: []const u8, prefix: []const u8) Error![]u8 {
    _ = .{ alloc, base, prefix };
    return error.CannotCreateTempDir;
}
pub fn removeTree(path: []const u8) void {
    _ = path;
}
pub fn listDir(alloc: std.mem.Allocator, path: []const u8) Error![]DirEntry {
    _ = .{ alloc, path };
    return error.NotFound;
}
pub fn freeNames(alloc: std.mem.Allocator, list: []const DirEntry) void {
    _ = .{ alloc, list };
}

// local sockets (one instance of a process, recording control)
pub fn socketUnixStream() Error!fd_t {
    return error.SyscallFailed;
}
pub fn connectUnix(fd: fd_t, path: []const u8) Error!void {
    _ = .{ fd, path };
    return error.ConnectionRefused;
}
pub fn listenUnix(path: []const u8) Error!fd_t {
    _ = path;
    return error.AddressInUse;
}
pub fn accept(fd: fd_t) Error!?fd_t {
    _ = fd;
    return error.WouldBlock;
}

/// Whether `fd` is a terminal (1: is standard output one?).
pub fn isTerminal(fd: fd_t) bool {
    _ = fd;
    return false;
}

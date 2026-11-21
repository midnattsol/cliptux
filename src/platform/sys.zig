//! Thin error-checked wrappers over raw linux syscalls (Zig 0.16 moved most
//! of these out of std.posix). This file re-exports the submodules in
//! sys/: time, io (open fds), fs (paths), dir, net (unix sockets), proc.

const common = @import("sys/common.zig");
const time = @import("sys/time.zig");
const io = @import("sys/io.zig");
const fs = @import("sys/fs.zig");
const dir = @import("sys/dir.zig");
const net = @import("sys/net.zig");
const proc = @import("sys/proc.zig");

pub const fd_t = common.fd_t;

// clocks and randomness
pub const monoMs = time.monoMs;
pub const realtimeSec = time.realtimeSec;
pub const realtimeMs = time.realtimeMs;
pub const getRandom = time.getRandom;
pub const timeoutUntil = time.timeoutUntil;

// open file descriptors
pub const pollfd = io.pollfd;
pub const POLL = io.POLL;
pub const MFD_CLOEXEC = io.MFD_CLOEXEC;
pub const read = io.read;
pub const write = io.write;
pub const writeAll = io.writeAll;
pub const writeAllBlocking = io.writeAllBlocking;
pub const pipe = io.pipe;
pub const close = io.close;
pub const poll = io.poll;
pub const waitReadable = io.waitReadable;
pub const memfdCreate = io.memfdCreate;
pub const ftruncate = io.ftruncate;
pub const ftruncateFd = io.ftruncateFd;
pub const mmapRw = io.mmapRw;
pub const munmap = io.munmap;
pub const fsync = io.fsync;
pub const fchmod = io.fchmod;
pub const dup2 = io.dup2;
pub const lockExclusive = io.lockExclusive;
pub const FileId = io.FileId;
pub const fileId = io.fileId;
pub const fdSize = io.fdSize;

// files by path
pub const openRead = fs.openRead;
pub const openRw = fs.openRw;
pub const openAppend = fs.openAppend;
pub const createWrite = fs.createWrite;
pub const createExclusive = fs.createExclusive;
pub const writeFileExclusive = fs.writeFileExclusive;
pub const writeFile = fs.writeFile;
pub const readFileAlloc = fs.readFileAlloc;
pub const unlink = fs.unlink;
pub const rename = fs.rename;
pub const mtimeSec = fs.mtimeSec;
pub const fileSize = fs.fileSize;

// directories
pub const openDir = dir.openDir;
pub const mkdir = dir.mkdir;
pub const mkdirMode = dir.mkdirMode;
pub const mkdirAll = dir.mkdirAll;
pub const makeTempDir = dir.makeTempDir;
pub const removeTree = dir.removeTree;
pub const DirEntry = dir.DirEntry;
pub const listDir = dir.listDir;
pub const freeNames = dir.freeNames;

// unix sockets
pub const socketUnixStream = net.socketUnixStream;
pub const connectUnix = net.connectUnix;
pub const connectUnixAbstract = net.connectUnixAbstract;
pub const socketPair = net.socketPair;
pub const listenUnix = net.listenUnix;
pub const accept = net.accept;
pub const sendWithFds = net.sendWithFds;
pub const recvWithFds = net.recvWithFds;

// processes
pub const getuid = proc.getuid;
pub const fork = proc.fork;
pub const setsid = proc.setsid;
pub const chdirRoot = proc.chdirRoot;
pub const exitProcess = proc.exitProcess;

// Reach every submodule's tests (a `test {}` block would count as one).
comptime {
    _ = common;
    _ = time;
    _ = io;
    _ = fs;
    _ = dir;
    _ = net;
    _ = proc;
}

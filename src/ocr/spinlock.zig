//! A small lock for short critical sections between threads (the OCR
//! engine and the history's background reading).

const std = @import("std");

/// A small lock for short critical sections between threads.
pub const SpinLock = struct {
    m: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *SpinLock) void {
        while (!self.m.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *SpinLock) void {
        self.m.unlock();
    }
};

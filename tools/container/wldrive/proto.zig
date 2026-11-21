//! Protocol constants and the output and global bookkeeping of
//! shotlet-wldrive: request and event opcodes of the virtual input and
//! screencopy protocols it speaks.

pub const vp_mgr = struct {
    pub const create_virtual_pointer = 0;
};
pub const vp = struct {
    pub const motion_absolute = 1;
    pub const button = 2;
    pub const axis = 3;
    pub const frame = 4;
    pub const axis_source = 5;
    pub const axis_discrete = 7;
};
pub const vk_mgr = struct {
    pub const create_virtual_keyboard = 0;
};
pub const vk = struct {
    pub const keymap = 0;
    pub const key = 1;
    pub const modifiers = 2;
};
pub const fake = struct {
    pub const authenticate = 0;
    pub const button = 2;
    pub const axis = 3;
    pub const pointer_motion_absolute = 9; // since 3
    pub const keyboard_key = 10; // since 4
};
pub const sc_mgr = struct {
    pub const capture_output = 0;
};
pub const sc_frame = struct {
    pub const copy = 0;
    pub const destroy = 1;
    pub const ev_buffer = 0;
    pub const ev_flags = 1;
    pub const ev_ready = 2;
    pub const ev_failed = 3;
    pub const ev_buffer_done = 6;
};

/// A wl_output: its logical place and size (xdg-output), scale and connector name.
pub const Output = struct {
    global: u32,
    id: u32 = 0,
    xdg: u32 = 0,
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    scale: i32 = 1,

    pub fn name(self: *const Output) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// The globals bound from the registry (0: not offered).
pub const Globals = struct {
    compositor: u32 = 0,
    shm: u32 = 0,
    seat: u32 = 0,
    xdg_output_mgr: u32 = 0,
    vp_mgr: u32 = 0,
    vk_mgr: u32 = 0,
    fake: u32 = 0,
    fake_version: u32 = 0,
    screencopy: u32 = 0,
    screencopy_version: u32 = 0,
};

//! SPA / PipeWire ABI: constants, C struct mirrors and the dynamically
//! loaded pw_* function table (all stable since 0.3).

const std = @import("std");

// --- constants ---
pub const SPA_TYPE_Id: u32 = 3;
pub const SPA_TYPE_Int: u32 = 4;
pub const SPA_TYPE_Object: u32 = 15;
pub const SPA_TYPE_Choice: u32 = 19;
pub const SPA_TYPE_Rectangle: u32 = 10;
pub const SPA_TYPE_Fraction: u32 = 11;

pub const SPA_TYPE_OBJECT_Format: u32 = 0x40003;
pub const SPA_PARAM_EnumFormat: u32 = 3;
pub const SPA_PARAM_Format: u32 = 4;
pub const SPA_PARAM_Meta: u32 = 6;
pub const SPA_TYPE_OBJECT_ParamMeta: u32 = 0x40005;
pub const SPA_PARAM_META_type: u32 = 1;
pub const SPA_PARAM_META_size: u32 = 2;
pub const SPA_META_VideoCrop: u32 = 2;

pub const SPA_CHUNK_FLAG_CORRUPTED: i32 = 1 << 0;

pub const SPA_FORMAT_mediaType: u32 = 1;
pub const SPA_FORMAT_mediaSubtype: u32 = 2;
pub const SPA_FORMAT_VIDEO_format: u32 = 0x20001;
pub const SPA_FORMAT_VIDEO_size: u32 = 0x20003;
pub const SPA_FORMAT_VIDEO_framerate: u32 = 0x20004;

pub const SPA_MEDIA_TYPE_video: u32 = 2;
pub const SPA_MEDIA_SUBTYPE_raw: u32 = 1;

pub const SPA_CHOICE_Range: u32 = 1;
pub const SPA_CHOICE_Enum: u32 = 3;

pub const VideoFormat = enum(u32) {
    RGBx = 7,
    BGRx = 8,
    RGBA = 11,
    BGRA = 12,
    _,
};

pub const PW_DIRECTION_INPUT: c_uint = 0;
pub const PW_STREAM_FLAG_AUTOCONNECT: c_uint = 1 << 0;
pub const PW_STREAM_FLAG_MAP_BUFFERS: c_uint = 1 << 2;

pub const PW_STREAM_STATE_ERROR: c_int = -1;

// --- C struct mirrors (stable ABI) ---
pub const SpaChunk = extern struct {
    offset: u32,
    size: u32,
    stride: i32,
    flags: i32,
};

pub const SpaData = extern struct {
    type: u32,
    flags: u32,
    fd: i64,
    mapoffset: u32,
    maxsize: u32,
    data: ?*anyopaque,
    chunk: ?*SpaChunk,
};

pub const SpaMeta = extern struct {
    type: u32,
    size: u32,
    data: ?*anyopaque,
};

/// spa_meta_region: a spa_region (position + size)
pub const SpaMetaRegion = extern struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const SpaBuffer = extern struct {
    n_metas: u32,
    n_datas: u32,
    metas: ?[*]SpaMeta,
    datas: ?[*]SpaData,
};

pub const PwBuffer = extern struct {
    buffer: ?*SpaBuffer,
    user_data: ?*anyopaque,
    size: u64,
    requested: u64,
    time: u64,
};

pub const SpaHook = extern struct {
    link_prev: ?*anyopaque = null,
    link_next: ?*anyopaque = null,
    funcs: ?*const anyopaque = null,
    data: ?*anyopaque = null,
    removed: ?*anyopaque = null,
    priv: ?*anyopaque = null,
};

pub const StreamEvents = extern struct {
    version: u32 = 2,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void = null,
    state_changed: ?*const fn (?*anyopaque, c_int, c_int, ?[*:0]const u8) callconv(.c) void = null,
    control_info: ?*const anyopaque = null,
    io_changed: ?*const anyopaque = null,
    param_changed: ?*const fn (?*anyopaque, u32, ?*const anyopaque) callconv(.c) void = null,
    add_buffer: ?*const anyopaque = null,
    remove_buffer: ?*const anyopaque = null,
    process: ?*const fn (?*anyopaque) callconv(.c) void = null,
    drained: ?*const anyopaque = null,
    command: ?*const anyopaque = null,
    trigger_done: ?*const anyopaque = null,
};

// --- dynamic API surface (pw_* symbols) ---
pub const Api = struct {
    init: *const fn (?*c_int, ?*anyopaque) callconv(.c) void,
    thread_loop_new: *const fn ([*:0]const u8, ?*const anyopaque) callconv(.c) ?*anyopaque,
    thread_loop_destroy: *const fn (?*anyopaque) callconv(.c) void,
    thread_loop_start: *const fn (?*anyopaque) callconv(.c) c_int,
    thread_loop_stop: *const fn (?*anyopaque) callconv(.c) void,
    thread_loop_lock: *const fn (?*anyopaque) callconv(.c) void,
    thread_loop_unlock: *const fn (?*anyopaque) callconv(.c) void,
    thread_loop_signal: *const fn (?*anyopaque, bool) callconv(.c) void,
    thread_loop_timed_wait: *const fn (?*anyopaque, c_int) callconv(.c) c_int,
    thread_loop_get_loop: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    context_new: *const fn (?*anyopaque, ?*anyopaque, usize) callconv(.c) ?*anyopaque,
    context_destroy: *const fn (?*anyopaque) callconv(.c) void,
    context_connect_fd: *const fn (?*anyopaque, c_int, ?*anyopaque, usize) callconv(.c) ?*anyopaque,
    core_disconnect: *const fn (?*anyopaque) callconv(.c) c_int,
    stream_new: *const fn (?*anyopaque, [*:0]const u8, ?*anyopaque) callconv(.c) ?*anyopaque,
    stream_destroy: *const fn (?*anyopaque) callconv(.c) void,
    stream_disconnect: *const fn (?*anyopaque) callconv(.c) c_int,
    stream_add_listener: *const fn (?*anyopaque, *SpaHook, *const StreamEvents, ?*anyopaque) callconv(.c) void,
    stream_connect: *const fn (?*anyopaque, c_uint, u32, c_uint, [*]const [*]const u8, u32) callconv(.c) c_int,
    stream_dequeue_buffer: *const fn (?*anyopaque) callconv(.c) ?*PwBuffer,
    stream_queue_buffer: *const fn (?*anyopaque, *PwBuffer) callconv(.c) c_int,
    stream_update_params: *const fn (?*anyopaque, [*]const [*]const u8, u32) callconv(.c) c_int,
};

/// Look up every Api field as `pw_<field name>`; null if any is missing.
pub fn loadApi(l: *std.DynLib) ?Api {
    var out: Api = undefined;
    const info = @typeInfo(Api).@"struct";
    inline for (info.field_names, info.field_types) |fld_name, fld_type| {
        const sym_name = "pw_" ++ fld_name;
        // DynLib.lookup requires a null-terminated name
        const ptr = l.lookup(fld_type, sym_name) orelse return null;
        @field(out, fld_name) = ptr;
    }
    return out;
}

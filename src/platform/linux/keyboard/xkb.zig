//! libxkbcommon ABI (opaque handles, plain C functions), dlopen'ed once
//! at runtime.

const std = @import("std");

pub const Ctx = opaque {};
pub const Keymap = opaque {};
pub const State = opaque {};
pub const ComposeTable = opaque {};
pub const ComposeState = opaque {};

pub const RuleNames = extern struct {
    rules: ?[*:0]const u8 = null,
    model: ?[*:0]const u8 = null,
    layout: ?[*:0]const u8 = null,
    variant: ?[*:0]const u8 = null,
    options: ?[*:0]const u8 = null,
};

pub const Api = struct {
    context_new: *const fn (c_int) callconv(.c) ?*Ctx,
    context_unref: *const fn (*Ctx) callconv(.c) void,
    keymap_new_from_string: *const fn (*Ctx, [*:0]const u8, c_int, c_int) callconv(.c) ?*Keymap,
    keymap_new_from_names: *const fn (*Ctx, *const RuleNames, c_int) callconv(.c) ?*Keymap,
    keymap_unref: *const fn (*Keymap) callconv(.c) void,
    keymap_key_repeats: *const fn (*Keymap, u32) callconv(.c) c_int,
    keymap_mod_get_index: *const fn (*Keymap, [*:0]const u8) callconv(.c) u32,
    state_new: *const fn (*Keymap) callconv(.c) ?*State,
    state_unref: *const fn (*State) callconv(.c) void,
    state_update_mask: *const fn (*State, u32, u32, u32, u32, u32, u32) callconv(.c) c_int,
    state_update_key: *const fn (*State, u32, c_int) callconv(.c) c_int,
    state_key_get_one_sym: *const fn (*State, u32) callconv(.c) u32,
    state_key_get_utf8: *const fn (*State, u32, [*]u8, usize) callconv(.c) c_int,
    state_mod_index_is_active: *const fn (*State, u32, c_int) callconv(.c) c_int,
    keysym_to_utf8: *const fn (u32, [*]u8, usize) callconv(.c) c_int,
    keysym_get_name: *const fn (u32, [*]u8, usize) callconv(.c) c_int,
    compose_table_new_from_locale: *const fn (*Ctx, [*:0]const u8, c_int) callconv(.c) ?*ComposeTable,
    compose_table_unref: *const fn (*ComposeTable) callconv(.c) void,
    compose_state_new: *const fn (*ComposeTable, c_int) callconv(.c) ?*ComposeState,
    compose_state_unref: *const fn (*ComposeState) callconv(.c) void,
    compose_state_feed: *const fn (*ComposeState, u32) callconv(.c) c_int,
    compose_state_reset: *const fn (*ComposeState) callconv(.c) void,
    compose_state_get_status: *const fn (*ComposeState) callconv(.c) c_int,
    compose_state_get_utf8: *const fn (*ComposeState, [*]u8, usize) callconv(.c) c_int,
    compose_state_get_one_sym: *const fn (*ComposeState) callconv(.c) u32,
};

pub const KEYMAP_FORMAT_TEXT_V1 = 1;
pub const STATE_MODS_EFFECTIVE = 1 << 3;
pub const MOD_INVALID: u32 = 0xffffffff;
pub const COMPOSE_FEED_ACCEPTED = 1;
pub const COMPOSE_COMPOSING = 1;
pub const COMPOSE_COMPOSED = 2;
pub const COMPOSE_CANCELLED = 3;

var lib: ?std.DynLib = null;
/// The resolved entry points; valid once `available` returned true.
pub var api: Api = undefined;
var lib_tried = false;

/// Load libxkbcommon once. False when it is not installed.
pub fn available() bool {
    if (lib_tried) return lib != null;
    lib_tried = true;
    lib = std.DynLib.open("libxkbcommon.so.0") catch {
        std.log.info("libxkbcommon not found; keyboard falls back to a US layout", .{});
        return false;
    };
    const info = @typeInfo(Api).@"struct";
    inline for (info.field_names, info.field_types) |fld_name, fld_type| {
        const ptr = lib.?.lookup(fld_type, "xkb_" ++ fld_name) orelse {
            std.log.warn("libxkbcommon lacks xkb_{s}; keyboard falls back to a US layout", .{fld_name});
            lib.?.close();
            lib = null;
            return false;
        };
        @field(api, fld_name) = ptr;
    }
    return true;
}

/// Whether libxkbcommon is loaded (without trying to load it).
pub fn loaded() bool {
    return lib != null;
}

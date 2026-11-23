//! The configuration model: the Config struct, its keys (fixed settings
//! plus one "shortcut_<action>" per editor action) and how each key's value
//! is serialized, plus the per-key hash baseline save() compares against.

const std = @import("std");
const binds = @import("../binds.zig");
const Action = binds.Action;
const n_actions = binds.n_actions;
const Bind = binds.Bind;

/// When the floating thumbnail shows up.
pub const Thumbnail = enum {
    after_save,
    after_copy_and_save,
    never,

    pub fn label(t: Thumbnail) []const u8 {
        return switch (t) {
            .after_save => "After Save",
            .after_copy_and_save => "After Copy and Save",
            .never => "Never",
        };
    }
};

/// When the magnifier shows while choosing an area: while Ctrl is held
/// (hold); all the while pointing and dragging (always); or never.
pub const Loupe = enum {
    hold,
    always,
    never,

    pub fn label(l: Loupe) []const u8 {
        return switch (l) {
            .hold => "While Holding Ctrl",
            .always => "Always",
            .never => "Never",
        };
    }

    /// The setting a config value names; older files' values read as hold.
    pub fn parse(value: []const u8) ?Loupe {
        if (isLegacy(value)) return .hold;
        return std.meta.stringToEnum(Loupe, value);
    }

    /// What older files called the settings that are hold now: only while
    /// dragging (selecting), when the pointer slows down (auto).
    pub fn isLegacy(value: []const u8) bool {
        for ([_][]const u8{ "selecting", "auto" }) |v| if (std.mem.eql(u8, value, v)) return true;
        return false;
    }
};

/// The magnifier's zoom levels: screen pixels per captured pixel, at
/// scale 1 (the lens keeps its size: more zoom shows fewer pixels).
pub const loupe_zooms = [_]u8{ 4, 8, 12, 16 };
pub const loupe_zoom_default: u8 = 8;

/// The zoom level nearest `v`.
pub fn nearestZoom(v: i64) u8 {
    var best = loupe_zooms[0];
    for (loupe_zooms) |z| {
        if (@abs(v - z) < @abs(v - best)) best = z;
    }
    return best;
}

pub const Config = struct {
    /// desktop notification after saving, when no thumbnail says so
    notify: bool = true,
    /// also copy to clipboard when saving to disk
    copy_on_save: bool = false,
    /// default stroke thickness (logical px, scaled by the UI)
    default_thickness: i32 = 3,
    /// default palette color index
    default_color: u3 = 0,
    /// override save directory; empty = XDG pictures dir
    save_dir: [256]u8 = @splat(0),
    save_dir_len: usize = 0,
    /// editor keybindings, indexed by Action
    binds: [n_actions]Bind = binds.default_binds,
    /// ScreenCast restore token (silent re-capture after first consent)
    sc_token: [512]u8 = @splat(0),
    sc_token_len: usize = 0,
    /// every new capture starts with the "beautify" frame on (else each
    /// starts without it; its style below is remembered either way)
    beautify_always: bool = false,
    beautify_background: u8 = 0,
    /// 0 none, 1 small, 2 medium, 3 large
    beautify_padding: u2 = 2,
    beautify_corners: bool = true,
    beautify_shadow: bool = true,
    /// the editor's first-run hint was shown
    hint_shown: bool = false,
    /// the floating thumbnail with more actions: after which results
    thumbnail: Thumbnail = .after_save,
    /// how long the thumbnail stays (it stays while hovered)
    quick_access_seconds: u16 = 8,
    /// keep copied and saved captures in $XDG_STATE_HOME/shotlet/history
    history: bool = true,
    /// at most this many captures...
    history_max: u16 = 50,
    /// ...taking at most this many MiB
    history_max_mb: u32 = 500,
    /// the magnifier while choosing an area, and its zoom (one of
    /// loupe_zooms)
    loupe: Loupe = .hold,
    loupe_zoom: u8 = loupe_zoom_default,
    /// hash of every key's value as last loaded or saved; save() writes
    /// only keys whose value differs. All zero (a Config not read from
    /// disk) means every key is written.
    base: [n_keys]u64 = @splat(0),

    /// Whether a capture that was saved (else only copied) gets a
    /// thumbnail.
    pub fn showsThumbnail(self: *const Config, saved: bool) bool {
        return switch (self.thumbnail) {
            .after_save => saved,
            .after_copy_and_save => true,
            .never => false,
        };
    }

    /// Whether any capture gets a thumbnail.
    pub fn thumbnails(self: *const Config) bool {
        return self.thumbnail != .never;
    }

    pub fn saveDir(self: *const Config) ?[]const u8 {
        if (self.save_dir_len == 0) return null;
        return self.save_dir[0..self.save_dir_len];
    }

    pub fn scToken(self: *const Config) ?[]const u8 {
        if (self.sc_token_len == 0) return null;
        return self.sc_token[0..self.sc_token_len];
    }

    pub fn setScToken(self: *Config, token: []const u8) void {
        const n = @min(token.len, self.sc_token.len);
        @memcpy(self.sc_token[0..n], token[0..n]);
        self.sc_token_len = n;
    }
};

// --- keys ---

pub const n_fixed_keys = 19;
/// `loupe`'s number among the keys
pub const loupe_key = 17;
/// an editor action's key: this, then the action's name
pub const bind_prefix = "shortcut_";
pub const n_keys = n_fixed_keys + n_actions;

const fixed_key_names = [n_fixed_keys][]const u8{
    "notify",
    "copy_on_save",
    "default_thickness",
    "default_color",
    "save_dir",
    // tokens from before multi-monitor capture ("screencast_token") restore
    // a single-monitor selection forever, so they are not read any more
    "screencast_restore_token",
    // "beautify" (the last capture's frame carried over to the next) is
    // not read any more: the frame is per capture unless "always"
    "beautify_always",
    "beautify_background",
    "beautify_padding",
    "beautify_corners",
    "beautify_shadow",
    "hint_shown",
    // "quick_access=false" from before still reads as never
    "thumbnail",
    "quick_access_seconds",
    "history",
    "history_max",
    "history_max_mb",
    "loupe",
    "loupe_zoom",
};

pub const padding_names = [4][]const u8{ "none", "small", "medium", "large" };

/// Name of key `k` ("notify", ..., "shortcut_pen", ...).
pub fn keyName(k: usize, buf: []u8) []const u8 {
    if (k < n_fixed_keys) return fixed_key_names[k];
    const names = comptime @typeInfo(Action).@"enum".field_names;
    inline for (names, 0..) |fld_name, i| {
        if (k - n_fixed_keys == i) return bind_prefix ++ fld_name;
    }
    _ = buf;
    unreachable;
}

fn boolText(v: bool) []const u8 {
    return if (v) "true" else "false";
}

fn intText(buf: []u8, v: anytype) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch unreachable;
}

/// Serialized value of key `k` in `cfg`.
pub fn formatValue(cfg: *const Config, k: usize, buf: []u8) []const u8 {
    return switch (k) {
        0 => boolText(cfg.notify),
        1 => boolText(cfg.copy_on_save),
        2 => intText(buf, cfg.default_thickness),
        3 => intText(buf, cfg.default_color),
        4 => cfg.saveDir() orelse "",
        5 => cfg.scToken() orelse "",
        6 => boolText(cfg.beautify_always),
        7 => intText(buf, cfg.beautify_background),
        8 => padding_names[cfg.beautify_padding],
        9 => boolText(cfg.beautify_corners),
        10 => boolText(cfg.beautify_shadow),
        11 => boolText(cfg.hint_shown),
        12 => @tagName(cfg.thumbnail),
        13 => intText(buf, cfg.quick_access_seconds),
        14 => boolText(cfg.history),
        15 => intText(buf, cfg.history_max),
        16 => intText(buf, cfg.history_max_mb),
        loupe_key => @tagName(cfg.loupe),
        18 => intText(buf, cfg.loupe_zoom),
        else => formatBind(cfg.binds[k - n_fixed_keys], buf),
    };
}

/// "Ctrl+Shift+Z" (app/accel.zig's notation), or "none".
fn formatBind(b: Bind, buf: []u8) []const u8 {
    const a = b.toAccel() orelse return "none";
    return a.format(buf) orelse "none";
}

pub fn valueHash(v: []const u8) u64 {
    // never 0, so an all-zero `base` unambiguously means "nothing loaded"
    return std.hash.Wyhash.hash(0x5107, v) | 1;
}

/// Record every key's current value as the baseline for the next save.
pub fn rememberBase(cfg: *Config) void {
    var buf: [64]u8 = undefined;
    for (0..n_keys) |k| cfg.base[k] = valueHash(formatValue(cfg, k, &buf));
}

test "the keys' numbering" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("loupe", keyName(loupe_key, &buf));
}

test "the magnifier's zoom snaps to a level" {
    try std.testing.expectEqual(@as(u8, 8), nearestZoom(9));
    try std.testing.expectEqual(@as(u8, 4), nearestZoom(-3));
    try std.testing.expectEqual(@as(u8, 16), nearestZoom(400));
}

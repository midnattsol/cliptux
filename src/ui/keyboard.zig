//! Keyboard translation for the Wayland window: evdev code + compositor
//! modifier state -> keysym and UTF-8 text in the user's real layout.
//!
//! libxkbcommon is dlopen'ed at runtime (zero build dependencies, like
//! libpipewire). When it is missing, or the compositor sends no usable
//! keymap, translation falls back to a built-in US table. Dead keys and
//! Compose sequences use the compose table of the locale in
//! LC_ALL / LC_CTYPE / LANG.
//!
//! Key repeat is driven by `Repeat`, a pure deadline tracker the window
//! polls with a monotonic clock (tests feed it a fake one).

const std = @import("std");
const linux = std.os.linux;

// --- libxkbcommon ABI (opaque handles, plain C functions) ---

const Ctx = opaque {};
const Keymap = opaque {};
const State = opaque {};
const ComposeTable = opaque {};
const ComposeState = opaque {};

pub const RuleNames = extern struct {
    rules: ?[*:0]const u8 = null,
    model: ?[*:0]const u8 = null,
    layout: ?[*:0]const u8 = null,
    variant: ?[*:0]const u8 = null,
    options: ?[*:0]const u8 = null,
};

const Api = struct {
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

const XKB_KEYMAP_FORMAT_TEXT_V1 = 1;
const XKB_STATE_MODS_EFFECTIVE = 1 << 3;
const XKB_MOD_INVALID: u32 = 0xffffffff;
const COMPOSE_FEED_ACCEPTED = 1;
const COMPOSE_COMPOSING = 1;
const COMPOSE_COMPOSED = 2;
const COMPOSE_CANCELLED = 3;

var lib: ?std.DynLib = null;
var api: Api = undefined;
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

// --- keysyms used by the fallback table and callers ---

pub const XK = struct {
    pub const BackSpace: u32 = 0xff08;
    pub const Tab: u32 = 0xff09;
    pub const ISO_Left_Tab: u32 = 0xfe20;
    pub const Return: u32 = 0xff0d;
    pub const Escape: u32 = 0xff1b;
    pub const Delete: u32 = 0xffff;
    pub const Home: u32 = 0xff50;
    pub const Left: u32 = 0xff51;
    pub const Up: u32 = 0xff52;
    pub const Right: u32 = 0xff53;
    pub const Down: u32 = 0xff54;
    pub const Page_Up: u32 = 0xff55;
    pub const Page_Down: u32 = 0xff56;
    pub const End: u32 = 0xff57;
    pub const Shift_L: u32 = 0xffe1;
    pub const Shift_R: u32 = 0xffe2;
    pub const Control_L: u32 = 0xffe3;
    pub const Control_R: u32 = 0xffe4;
    pub const Caps_Lock: u32 = 0xffe5;
    pub const Alt_L: u32 = 0xffe9;
    pub const Alt_R: u32 = 0xffea;
    pub const Super_L: u32 = 0xffeb;
    pub const Super_R: u32 = 0xffec;
    pub const F1: u32 = 0xffbe;
};

/// Result of translating one key event.
pub const Translated = struct {
    keysym: u32 = 0,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    caps: bool = false,
    text_buf: [16]u8 = @splat(0),
    text_len: u8 = 0,

    pub fn text(self: *const Translated) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    fn setText(self: *Translated, s: []const u8) void {
        // keys that only produce control characters (Enter, Tab, Esc,
        // Backspace, Delete) type nothing
        for (s) |ch| if (ch < 0x20 or ch == 0x7f) {
            self.text_len = 0;
            return;
        };
        const n = @min(s.len, self.text_buf.len);
        @memcpy(self.text_buf[0..n], s[0..n]);
        self.text_len = @intCast(n);
    }
};

pub const Keyboard = struct {
    ctx: ?*Ctx = null,
    keymap: ?*Keymap = null,
    state: ?*State = null,
    compose_table: ?*ComposeTable = null,
    compose: ?*ComposeState = null,
    mod_ctrl: u32 = XKB_MOD_INVALID,
    mod_shift: u32 = XKB_MOD_INVALID,
    mod_alt: u32 = XKB_MOD_INVALID,
    mod_caps: u32 = XKB_MOD_INVALID,

    /// raw wl_keyboard.modifiers masks (also used by the fallback, which
    /// assumes the conventional bit positions)
    depressed: u32 = 0,
    latched: u32 = 0,
    locked: u32 = 0,
    group: u32 = 0,

    repeat: Repeat = .{},

    /// Create the xkb context and the locale's compose table. Without
    /// libxkbcommon this is a no-op and translation uses the US table.
    pub fn init() Keyboard {
        var self: Keyboard = .{};
        if (!available()) return self;
        self.ctx = api.context_new(0);
        if (self.ctx) |ctx| {
            var loc_buf: [128]u8 = undefined;
            const loc = localeName(&loc_buf);
            self.compose_table = api.compose_table_new_from_locale(ctx, loc, 0);
            if (self.compose_table) |t| self.compose = api.compose_state_new(t, 0);
        }
        return self;
    }

    pub fn deinit(self: *Keyboard) void {
        self.dropKeymap();
        if (self.compose) |s| api.compose_state_unref(s);
        if (self.compose_table) |t| api.compose_table_unref(t);
        if (self.ctx) |c| api.context_unref(c);
        self.* = .{};
    }

    fn dropKeymap(self: *Keyboard) void {
        if (self.state) |s| api.state_unref(s);
        if (self.keymap) |k| api.keymap_unref(k);
        self.state = null;
        self.keymap = null;
    }

    pub fn hasXkb(self: *const Keyboard) bool {
        return self.state != null;
    }

    /// wl_keyboard.keymap: map the fd (read-only, private as the protocol
    /// requires) and compile it. Does not close fd.
    pub fn setKeymapFd(self: *Keyboard, format: u32, fd: i32, size: u32) void {
        if (self.ctx == null or format != XKB_KEYMAP_FORMAT_TEXT_V1 or size == 0) return;
        const rc = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
        if (linux.errno(rc) != .SUCCESS) {
            std.log.warn("keymap mmap failed; keeping the previous layout", .{});
            return;
        }
        const ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(rc);
        defer _ = linux.munmap(ptr, size);
        const mem = ptr[0..size];
        // the keymap string is NUL terminated within size; refuse otherwise
        const nul = std.mem.indexOfScalar(u8, mem, 0) orelse {
            std.log.warn("keymap is not NUL terminated; ignoring it", .{});
            return;
        };
        self.setKeymapString(mem[0..nul :0]);
    }

    pub fn setKeymapString(self: *Keyboard, keymap_text: [:0]const u8) void {
        const ctx = self.ctx orelse return;
        const km = api.keymap_new_from_string(ctx, keymap_text.ptr, XKB_KEYMAP_FORMAT_TEXT_V1, 0) orelse {
            std.log.warn("could not compile the compositor keymap; keeping the previous layout", .{});
            return;
        };
        self.adoptKeymap(km);
    }

    /// Compile a keymap from RMLVO names (tests, or no compositor keymap).
    pub fn setKeymapNames(self: *Keyboard, layout: [:0]const u8, variant: [:0]const u8) bool {
        const ctx = self.ctx orelse return false;
        const names: RuleNames = .{ .layout = layout.ptr, .variant = variant.ptr };
        const km = api.keymap_new_from_names(ctx, &names, 0) orelse return false;
        self.adoptKeymap(km);
        return true;
    }

    fn adoptKeymap(self: *Keyboard, km: *Keymap) void {
        const st = api.state_new(km) orelse {
            api.keymap_unref(km);
            return;
        };
        self.dropKeymap();
        self.keymap = km;
        self.state = st;
        self.mod_ctrl = api.keymap_mod_get_index(km, "Control");
        self.mod_shift = api.keymap_mod_get_index(km, "Shift");
        self.mod_alt = api.keymap_mod_get_index(km, "Mod1");
        self.mod_caps = api.keymap_mod_get_index(km, "Lock");
        // re-apply the current modifier state to the new keymap
        _ = api.state_update_mask(st, self.depressed, self.latched, self.locked, 0, 0, self.group);
        if (self.compose) |c| api.compose_state_reset(c);
    }

    /// wl_keyboard.modifiers
    pub fn updateMods(self: *Keyboard, depressed: u32, latched: u32, locked: u32, group: u32) void {
        self.depressed = depressed;
        self.latched = latched;
        self.locked = locked;
        self.group = group;
        if (self.state) |st| _ = api.state_update_mask(st, depressed, latched, locked, 0, 0, group);
    }

    /// Focus left the window: forget pending dead keys and stop repeating.
    pub fn leave(self: *Keyboard) void {
        self.repeat.stop();
        if (self.compose) |c| api.compose_state_reset(c);
    }

    fn modActive(self: *const Keyboard, idx: u32) bool {
        const st = self.state orelse return false;
        if (idx == XKB_MOD_INVALID) return false;
        return api.state_mod_index_is_active(st, idx, XKB_STATE_MODS_EFFECTIVE) > 0;
    }

    /// Translate an evdev key. `use_compose` feeds presses through the
    /// dead key / Compose machinery (off for synthesized repeats).
    pub fn translate(self: *Keyboard, code: u32, pressed: bool, use_compose: bool) Translated {
        var out: Translated = .{};
        const st = self.state orelse return self.translateFallback(code, pressed);
        const kc = code + 8;
        out.ctrl = self.modActive(self.mod_ctrl);
        out.shift = self.modActive(self.mod_shift);
        out.alt = self.modActive(self.mod_alt);
        out.caps = self.modActive(self.mod_caps);
        out.keysym = api.state_key_get_one_sym(st, kc);
        if (!pressed) return out;

        if (use_compose) if (self.compose) |cs| {
            if (api.compose_state_feed(cs, out.keysym) == COMPOSE_FEED_ACCEPTED) {
                switch (api.compose_state_get_status(cs)) {
                    COMPOSE_COMPOSING => return out, // dead key: no text yet
                    COMPOSE_COMPOSED => {
                        var buf: [64]u8 = undefined;
                        const n = api.compose_state_get_utf8(cs, &buf, buf.len);
                        const sym = api.compose_state_get_one_sym(cs);
                        if (sym != 0) out.keysym = sym;
                        api.compose_state_reset(cs);
                        if (!out.ctrl and n > 0) out.setText(buf[0..@intCast(@min(n, buf.len - 1))]);
                        return out;
                    },
                    COMPOSE_CANCELLED => {
                        api.compose_state_reset(cs);
                        return out;
                    },
                    else => {},
                }
            }
        };
        if (out.ctrl) return out;
        var buf: [64]u8 = undefined;
        const n = api.state_key_get_utf8(st, kc, &buf, buf.len);
        if (n > 0) out.setText(buf[0..@intCast(@min(n, buf.len - 1))]);
        return out;
    }

    fn translateFallback(self: *const Keyboard, code: u32, pressed: bool) Translated {
        var out: Translated = .{
            // conventional xkb modifier bits: Shift=0 Lock=1 Control=2 Mod1=3
            .shift = self.depressed & 1 != 0,
            .caps = self.locked & 2 != 0,
            .ctrl = self.depressed & 4 != 0,
            .alt = self.depressed & 8 != 0,
        };
        const upper = if (isLetter(code)) out.shift != out.caps else out.shift;
        const ch = usChar(code, upper);
        if (ch) |c| {
            out.keysym = c;
            if (pressed and !out.ctrl) {
                out.text_buf[0] = c;
                out.text_len = 1;
            }
        } else out.keysym = usSpecialSym(code);
        return out;
    }

    /// Whether holding this key auto-repeats (per the keymap).
    pub fn keyRepeats(self: *const Keyboard, code: u32) bool {
        if (self.keymap) |km| return api.keymap_key_repeats(km, code + 8) != 0;
        return switch (code) {
            29, 97, 42, 54, 56, 100, 125, 126, 58, 1 => false, // modifiers, caps, esc
            else => true,
        };
    }

    /// Human-readable name of the key at evdev `code` in the active layout
    /// with no modifiers: the character it types (upper-cased) or the
    /// keysym name. Falls back to `fallback` when unknown.
    pub fn keyName(self: *Keyboard, code: u32, buf: []u8, fallback: []const u8) []const u8 {
        const km = self.keymap orelse return fallback;
        // a scratch state with no modifiers, so the name does not depend on
        // what is held right now
        const st = api.state_new(km) orelse return fallback;
        defer api.state_unref(st);
        _ = api.state_update_mask(st, 0, 0, 0, 0, 0, self.group);
        const sym = api.state_key_get_one_sym(st, code + 8);
        return keysymLabel(sym, buf) orelse fallback;
    }
};

/// Printable label for a keysym: its character (upper-cased when it is a
/// lower-case letter), or its xkb name with dead_ stripped.
pub fn keysymLabel(sym: u32, buf: []u8) ?[]const u8 {
    if (sym == 0 or lib == null or buf.len < 8) return null;
    switch (sym) {
        XK.Return => return "Enter",
        XK.Escape => return "Esc",
        XK.BackSpace => return "Backspace",
        XK.Delete => return "Delete",
        ' ' => return "Space",
        else => {},
    }
    var u: [8]u8 = undefined;
    const n = api.keysym_to_utf8(sym, &u, u.len);
    if (n > 1) {
        const s = u[0..@intCast(n - 1)];
        if (s[0] >= 0x20 and s[0] != 0x7f) {
            const cp = std.unicode.utf8Decode(s) catch return copyOut(buf, s);
            const up = upperLatin(cp);
            const len = std.unicode.utf8Encode(up, buf) catch return copyOut(buf, s);
            return buf[0..len];
        }
    }
    const m = api.keysym_get_name(sym, buf.ptr, buf.len);
    if (m <= 0) return null;
    var name = buf[0..@intCast(@min(m, @as(c_int, @intCast(buf.len - 1))))];
    if (std.mem.startsWith(u8, name, "dead_")) name = name[5..];
    return name;
}

fn copyOut(buf: []u8, s: []const u8) ?[]const u8 {
    if (s.len > buf.len) return null;
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

/// Upper-case ASCII and Latin-1 letters (enough for key captions).
fn upperLatin(cp: u21) u21 {
    if (cp >= 'a' and cp <= 'z') return cp - 32;
    if (cp >= 0xe0 and cp <= 0xfe and cp != 0xf7) return cp - 32;
    return cp;
}

fn localeName(buf: []u8) [*:0]const u8 {
    for ([_][*:0]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |name| {
        if (std.c.getenv(name)) |v| {
            const s = std.mem.span(v);
            if (s.len > 0 and s.len < buf.len) {
                @memcpy(buf[0..s.len], s);
                buf[s.len] = 0;
                return buf[0..s.len :0];
            }
        }
    }
    return "C";
}

// --- US fallback table ---

fn isLetter(code: u32) bool {
    return (code >= 16 and code <= 25) or (code >= 30 and code <= 38) or (code >= 44 and code <= 50);
}

fn usChar(code: u32, upper: bool) ?u8 {
    const row = struct {
        fn pick(s: []const u8, u: []const u8, i: u32, up: bool) u8 {
            return if (up) u[i] else s[i];
        }
    };
    return switch (code) {
        2...13 => row.pick("1234567890-=", "!@#$%^&*()_+", code - 2, upper),
        16...27 => row.pick("qwertyuiop[]", "QWERTYUIOP{}", code - 16, upper),
        30...41 => row.pick("asdfghjkl;'`", "ASDFGHJKL:\"~", code - 30, upper),
        43...53 => row.pick("\\zxcvbnm,./", "|ZXCVBNM<>?", code - 43, upper),
        57 => ' ',
        else => null,
    };
}

fn usSpecialSym(code: u32) u32 {
    return switch (code) {
        1 => XK.Escape,
        14 => XK.BackSpace,
        15 => XK.Tab,
        28, 96 => XK.Return,
        29 => XK.Control_L,
        97 => XK.Control_R,
        42 => XK.Shift_L,
        54 => XK.Shift_R,
        56 => XK.Alt_L,
        100 => XK.Alt_R,
        58 => XK.Caps_Lock,
        59...68 => XK.F1 + (code - 59),
        87 => XK.F1 + 10,
        88 => XK.F1 + 11,
        102 => XK.Home,
        103 => XK.Up,
        104 => XK.Page_Up,
        105 => XK.Left,
        106 => XK.Right,
        107 => XK.End,
        108 => XK.Down,
        109 => XK.Page_Down,
        111 => XK.Delete,
        125 => XK.Super_L,
        126 => XK.Super_R,
        else => 0,
    };
}

// --- key repeat ---

/// Deadline-based key repeat, driven by wl_keyboard.repeat_info. The window
/// asks `timeoutMs` how long it may sleep and calls `due` when it wakes.
pub const Repeat = struct {
    /// repeats per second; 0 disables repeat
    rate: i32 = 25,
    /// ms before the first repeat
    delay: i32 = 600,
    code: u32 = 0,
    next_ms: i64 = 0,
    active: bool = false,

    pub fn setInfo(self: *Repeat, rate: i32, delay: i32) void {
        self.rate = @max(0, rate);
        self.delay = @max(0, delay);
        if (self.rate == 0) self.stop();
    }

    /// A key went down: (re)arm for it, or stop when it does not repeat.
    pub fn press(self: *Repeat, code: u32, repeats: bool, now_ms: i64) void {
        if (!repeats or self.rate == 0) {
            // a non-repeating key (e.g. Shift) does not cancel the held one
            return;
        }
        self.code = code;
        self.active = true;
        self.next_ms = now_ms + self.delay;
    }

    pub fn release(self: *Repeat, code: u32) void {
        if (self.active and self.code == code) self.stop();
    }

    pub fn stop(self: *Repeat) void {
        self.active = false;
        self.code = 0;
    }

    fn interval(self: *const Repeat) i64 {
        return @max(1, @divTrunc(1000, @as(i64, @max(1, self.rate))));
    }

    /// Milliseconds until the next repeat is due (0 when overdue), or null
    /// when nothing is repeating.
    pub fn timeoutMs(self: *const Repeat, now_ms: i64) ?i64 {
        if (!self.active) return null;
        return @max(0, self.next_ms - now_ms);
    }

    /// The key to synthesize when a repeat is due. Emits at most one per
    /// call; a stalled loop skips the backlog instead of flooding.
    pub fn due(self: *Repeat, now_ms: i64) ?u32 {
        if (!self.active or now_ms < self.next_ms) return null;
        self.next_ms += self.interval();
        if (self.next_ms <= now_ms) self.next_ms = now_ms + self.interval();
        return self.code;
    }
};

pub fn monotonicMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

// --- tests ---

const testing = std.testing;

fn testKeyboard(layout: [:0]const u8, locale: [*:0]const u8) ?Keyboard {
    if (!available()) return null;
    var kb: Keyboard = .{};
    kb.ctx = api.context_new(0) orelse return null;
    if (!kb.setKeymapNames(layout, "")) {
        kb.deinit();
        return null;
    }
    kb.compose_table = api.compose_table_new_from_locale(kb.ctx.?, locale, 0);
    if (kb.compose_table) |t| kb.compose = api.compose_state_new(t, 0);
    return kb;
}

/// press/release with modifier tracking done by xkb itself (what the
/// compositor would send as wl_keyboard.modifiers)
fn tap(kb: *Keyboard, code: u32) Translated {
    const st = kb.state.?;
    _ = api.state_update_key(st, code + 8, 1);
    const t = kb.translate(code, true, true);
    _ = api.state_update_key(st, code + 8, 0);
    return t;
}

fn hold(kb: *Keyboard, code: u32, down: bool) void {
    _ = api.state_update_key(kb.state.?, code + 8, if (down) 1 else 0);
}

test "xkb us layout" {
    var kb = testKeyboard("us", "en_US.UTF-8") orelse return error.SkipZigTest;
    defer kb.deinit();
    try testing.expectEqualStrings("a", tap(&kb, 30).text());
    try testing.expectEqual(@as(u32, 'a'), tap(&kb, 30).keysym);
    hold(&kb, 42, true);
    const big = tap(&kb, 30);
    try testing.expectEqualStrings("A", big.text());
    try testing.expect(big.shift);
    try testing.expectEqualStrings("@", tap(&kb, 3).text());
    hold(&kb, 42, false);
    // Enter types nothing but has a keysym
    const enter = tap(&kb, 28);
    try testing.expectEqual(XK.Return, enter.keysym);
    try testing.expectEqual(@as(u8, 0), enter.text_len);
    // Ctrl suppresses text
    hold(&kb, 29, true);
    const ctrl_c = tap(&kb, 46);
    hold(&kb, 29, false);
    try testing.expect(ctrl_c.ctrl);
    try testing.expectEqual(@as(u32, 'c'), ctrl_c.keysym);
    try testing.expectEqual(@as(u8, 0), ctrl_c.text_len);
}

test "xkb spanish layout: ñ, ¿, €, dead acute" {
    var kb = testKeyboard("es", "es_ES.UTF-8") orelse return error.SkipZigTest;
    defer kb.deinit();
    try testing.expectEqualStrings("ñ", tap(&kb, 39).text());
    try testing.expectEqual(@as(u32, 0xf1), tap(&kb, 39).keysym); // ntilde
    // ¡ on the key right of 0 (evdev 13), ¿ with Shift
    try testing.expectEqualStrings("¡", tap(&kb, 13).text());
    hold(&kb, 42, true);
    try testing.expectEqualStrings("¿", tap(&kb, 13).text());
    hold(&kb, 42, false);
    // AltGr+E = €
    hold(&kb, 100, true);
    try testing.expectEqualStrings("€", tap(&kb, 18).text());
    hold(&kb, 100, false);
    // dead acute (evdev 40) then a -> á; the dead key itself types nothing
    if (kb.compose != null) {
        const dead = tap(&kb, 40);
        try testing.expectEqual(@as(u8, 0), dead.text_len);
        try testing.expectEqualStrings("á", tap(&kb, 30).text());
        // dead acute then space -> a standalone accent (' or ´ per locale)
        _ = tap(&kb, 40);
        try testing.expect(tap(&kb, 57).text_len > 0);
        // dead acute then a key with no composition cancels, typing nothing
        _ = tap(&kb, 40);
        _ = tap(&kb, 3); // 2
        try testing.expectEqualStrings("e", tap(&kb, 18).text());
    }
}

test "key names follow the layout" {
    var kb = testKeyboard("es", "C") orelse return error.SkipZigTest;
    defer kb.deinit();
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("Ñ", kb.keyName(39, &buf, "?"));
    try testing.expectEqualStrings("Q", kb.keyName(16, &buf, "?"));
    try testing.expectEqualStrings("Enter", kb.keyName(28, &buf, "?"));
    // modifiers held right now do not change the caption
    hold(&kb, 42, true);
    try testing.expectEqualStrings("Ñ", kb.keyName(39, &buf, "?"));
    try testing.expect(!kb.keyRepeats(42));
    try testing.expect(kb.keyRepeats(30));
}

test "fallback US table without a keymap" {
    var kb: Keyboard = .{};
    var t = kb.translate(30, true, true);
    try testing.expectEqualStrings("a", t.text());
    kb.updateMods(1, 0, 0, 0); // Shift
    t = kb.translate(30, true, true);
    try testing.expectEqualStrings("A", t.text());
    try testing.expectEqualStrings("!", kb.translate(2, true, true).text());
    kb.updateMods(0, 0, 2, 0); // Caps Lock
    try testing.expectEqualStrings("A", kb.translate(30, true, true).text());
    try testing.expectEqualStrings("1", kb.translate(2, true, true).text());
    kb.updateMods(4, 0, 0, 0); // Ctrl
    t = kb.translate(30, true, true);
    try testing.expect(t.ctrl);
    try testing.expectEqual(@as(u8, 0), t.text_len);
    try testing.expectEqual(XK.Escape, kb.translate(1, true, true).keysym);
}

test "repeat timing with a fake clock" {
    var r: Repeat = .{};
    r.setInfo(25, 400); // 40 ms interval
    try testing.expect(r.timeoutMs(0) == null);
    r.press(30, true, 1000);
    try testing.expectEqual(@as(?i64, 400), r.timeoutMs(1000));
    try testing.expect(r.due(1399) == null);
    try testing.expectEqual(@as(?u32, 30), r.due(1400));
    try testing.expect(r.due(1420) == null);
    try testing.expectEqual(@as(?u32, 30), r.due(1440));
    // a stalled loop gets one repeat, not a burst
    try testing.expectEqual(@as(?u32, 30), r.due(3000));
    try testing.expect(r.due(3000) == null);
    // a non-repeating key (Shift) does not cancel the held one
    r.press(42, false, 3000);
    try testing.expect(r.active and r.code == 30);
    // releasing another key keeps repeating; releasing the held one stops
    r.release(31);
    try testing.expect(r.active);
    r.release(30);
    try testing.expect(r.timeoutMs(3000) == null);
    // focus loss
    r.press(30, true, 0);
    r.stop();
    try testing.expect(r.due(10_000) == null);
    // rate 0 disables repeat
    r.setInfo(0, 100);
    r.press(30, true, 0);
    try testing.expect(r.due(10_000) == null);
}

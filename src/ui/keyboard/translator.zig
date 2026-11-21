//! Keyboard translation for the Wayland window: evdev code + compositor
//! modifier state -> keysym and UTF-8 text, via xkb or the US fallback.

const std = @import("std");
const linux = std.os.linux;
const xkb = @import("xkb.zig");
const us = @import("us_layout.zig");
const XK = @import("keysyms.zig").XK;
const keysymLabel = @import("keysyms.zig").keysymLabel;
const Repeat = @import("repeat.zig").Repeat;

const api = &xkb.api;
const available = xkb.available;
const RuleNames = xkb.RuleNames;
const Ctx = xkb.Ctx;
const Keymap = xkb.Keymap;
const State = xkb.State;
const ComposeTable = xkb.ComposeTable;
const ComposeState = xkb.ComposeState;

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
    mod_ctrl: u32 = xkb.MOD_INVALID,
    mod_shift: u32 = xkb.MOD_INVALID,
    mod_alt: u32 = xkb.MOD_INVALID,
    mod_caps: u32 = xkb.MOD_INVALID,

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
        if (self.ctx == null or format != xkb.KEYMAP_FORMAT_TEXT_V1 or size == 0) return;
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
        const km = api.keymap_new_from_string(ctx, keymap_text.ptr, xkb.KEYMAP_FORMAT_TEXT_V1, 0) orelse {
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
        if (idx == xkb.MOD_INVALID) return false;
        return api.state_mod_index_is_active(st, idx, xkb.STATE_MODS_EFFECTIVE) > 0;
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
            if (feedCompose(cs, &out)) return out;
        };
        if (out.ctrl) return out;
        var buf: [64]u8 = undefined;
        const n = api.state_key_get_utf8(st, kc, &buf, buf.len);
        if (n > 0) out.setText(buf[0..@intCast(@min(n, buf.len - 1))]);
        return out;
    }

    /// Feed a press to the dead key / Compose state. True when the
    /// sequence consumed it (pending, composed into `out`, or cancelled).
    fn feedCompose(cs: *ComposeState, out: *Translated) bool {
        if (api.compose_state_feed(cs, out.keysym) != xkb.COMPOSE_FEED_ACCEPTED) return false;
        switch (api.compose_state_get_status(cs)) {
            xkb.COMPOSE_COMPOSING => return true, // dead key: no text yet
            xkb.COMPOSE_COMPOSED => {
                var buf: [64]u8 = undefined;
                const n = api.compose_state_get_utf8(cs, &buf, buf.len);
                const sym = api.compose_state_get_one_sym(cs);
                if (sym != 0) out.keysym = sym;
                api.compose_state_reset(cs);
                if (!out.ctrl and n > 0) out.setText(buf[0..@intCast(@min(n, buf.len - 1))]);
                return true;
            },
            xkb.COMPOSE_CANCELLED => {
                api.compose_state_reset(cs);
                return true;
            },
            else => return false,
        }
    }

    fn translateFallback(self: *const Keyboard, code: u32, pressed: bool) Translated {
        var out: Translated = .{
            // conventional xkb modifier bits: Shift=0 Lock=1 Control=2 Mod1=3
            .shift = self.depressed & 1 != 0,
            .caps = self.locked & 2 != 0,
            .ctrl = self.depressed & 4 != 0,
            .alt = self.depressed & 8 != 0,
        };
        const upper = if (us.isLetter(code)) out.shift != out.caps else out.shift;
        const ch = us.usChar(code, upper);
        if (ch) |c| {
            out.keysym = c;
            if (pressed and !out.ctrl) {
                out.text_buf[0] = c;
                out.text_len = 1;
            }
        } else out.keysym = us.usSpecialSym(code);
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

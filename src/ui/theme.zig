//! The look of every Shotlet surface ("Glass": translucent material over a
//! blurred backdrop, macOS-like metrics), in a light and a dark variant,
//! following the system's colour scheme and accent colour.
//!
//! Stable API (the editor, the Settings window and the after-capture
//! windows all use it):
//!
//!   Theme                 every colour (0xAARRGGBB) of one appearance;
//!                         the metrics are the `pub const`s below, in
//!                         logical pixels (multiply by the surface scale)
//!   Theme.get(dark, accent)   build one; accent null = system blue
//!   Prefs                 what the system asks for: dark, accent,
//!                         animations (false = reduce motion)
//!   Prefs.theme()         the Theme for those preferences
//!   readPrefs(conn)       ask org.freedesktop.portal.Settings once
//!                         (color-scheme, accent-color, enable-animations);
//!                         never fails: missing values keep the defaults
//!   watch(conn)           subscribe to SettingChanged
//!   applySignal(&prefs, msg)  fold a SettingChanged into prefs; true when
//!                         something the theme uses changed
//!   withAlpha(c, a), mix(a, b, t)  colour helpers
//!   contrast(a, b), legible(c, bg, min)  WCAG contrast; `c` darkened or
//!                         lightened until it reads on `bg`
//!
//! Colour-scheme values: 1 prefer dark, 2 prefer light, 0 no preference.
//! No preference is light, as GNOME and every other app on the desktop
//! read it.

const std = @import("std");
const dbus = @import("../platform/linux/dbus.zig");
const sys = @import("../platform/api.zig").sys;

// --- metrics (logical px) ---

/// floating toolbar: corner radius, inner padding, gap between controls
pub const bar_radius: f64 = 14;
pub const bar_pad: f64 = 6;
pub const bar_gap: f64 = 4;
/// square tool buttons and their corner radius
pub const button: f64 = 34;
pub const button_radius: f64 = 9;
/// icon box inside a button, and the icons' stroke (in 24-unit icon space)
pub const icon: f64 = 18;
pub const icon_stroke: f64 = 1.75;
/// separators between groups: 1 px wide, this tall, `sep_margin` each side
pub const sep_h: f64 = 20;
pub const sep_margin: f64 = 4;
/// popovers and menus
pub const popover_radius: f64 = 14;
pub const popover_pad: f64 = 14;
pub const menu_radius: f64 = 12;
pub const menu_pad: f64 = 6;
pub const menu_row: f64 = 30;
/// boxed-list cards (Settings), rows and switches
pub const card_radius: f64 = 12;
pub const row_h: f64 = 56;
pub const switch_w: f64 = 44;
pub const switch_h: f64 = 26;
/// backdrop blur under the material (CSS blur radius, roughly a sigma)
pub const backdrop_blur: f64 = 24;
/// keyboard focus ring: width and gap to the control
pub const focus_w: f64 = 2;
pub const focus_gap: f64 = 2;
/// type sizes
pub const font_label: f64 = 13;
pub const font_small: f64 = 12;
/// motion: durations of the ease-out transitions, ms
pub const motion_fast: i64 = 120;
pub const motion: i64 = 150;
pub const motion_slow: i64 = 180;
/// what is left of a disabled control's ink
pub const disabled_alpha: f64 = 0.3;
/// tooltips wait this long under a still pointer
pub const tooltip_delay: i64 = 500;

pub const default_accent: u32 = 0xFF0A84FF;
/// WCAG AA for text: what white text on a fill, and coloured text on a
/// window, must reach
pub const aa_text: f64 = 4.5;
/// the red fill of destructive buttons (white text on it reads: 5.4:1),
/// and pressed-looking on hover
pub const destructive_fill: u32 = 0xFFD70015;
/// the capture outside the selection is darkened by this (40%), or by
/// `capture_dim_dark` (55%) when the capture itself is dark
/// (editor/dim.zig)
pub const capture_dim: u32 = 0x66000000;
pub const capture_dim_dark: u32 = 0x8C000000;
pub const destructive_fill_hover: u32 = 0xFFB80012;

pub const Shadow = struct {
    color: u32,
    /// CSS-style blur radius and vertical offset, logical px
    blur: f64,
    dy: f64,
};

pub const Theme = struct {
    dark: bool,
    accent: u32,
    /// accent when hovered / pressed
    accent_hover: u32,
    /// text and icons on the accent
    on_accent: u32 = 0xFFFFFFFF,
    /// the accent as a fill under `on_accent` (darkened until white text
    /// reads on it), and when hovered
    accent_fill: u32,
    accent_fill_hover: u32,
    /// the accent as text on the window background (links)
    accent_text: u32,

    // --- floating material (toolbar, popovers, menus, tooltips) ---
    fg: u32,
    muted: u32,
    /// the translucent material, drawn over the blurred backdrop
    material: u32,
    /// the material as an opaque colour (gap rings, segmented thumbs)
    material_solid: u32,
    /// 0.5 px border of the material, and separators
    hairline: u32,
    hover: u32,
    pressed: u32,
    /// slider tracks and segmented-control troughs
    track: u32,
    /// the selected segment of a segmented control
    seg_on: u32,
    bar_shadow: Shadow,
    popover_shadow: Shadow,

    // --- the capture overlay ---
    /// the selection's two-tone edge: a light line inside a dark one, so
    /// it shows on any capture
    sel_edge: u32 = 0xE6FFFFFF,
    sel_edge_outer: u32 = 0x8C000000,
    handle: u32 = 0xFFFFFFFF,
    handle_shadow: u32 = 0x66000000,
    /// the size label and other pills drawn on the screenshot: nearly
    /// opaque, so the capture never shows through their text, with a
    /// hairline that keeps their edge on dark captures
    pill_bg: u32 = 0xEB1C1C1E,
    pill_line: u32 = 0x1FFFFFFF,
    pill_fg: u32 = 0xFFF5F5F7,
    /// secondary text on a pill (a tooltip's shortcut)
    pill_muted: u32 = 0xB3EBEBF5,

    // --- windows (Settings, history): GNOME-like boxed lists ---
    window_bg: u32,
    header_bg: u32,
    card: u32,
    line: u32,
    chip: u32,
    switch_off: u32,
    text: u32,
    text_muted: u32,
    view_sel: u32,
    /// panels of the after-capture windows, and their input fields
    panel: u32,
    field: u32,
    destructive: u32,

    pub fn get(dark: bool, accent_opt: ?u32) Theme {
        const accent = (accent_opt orelse default_accent) | 0xFF000000;
        var t = if (dark) dark_base else light_base;
        t.accent = accent;
        t.accent_hover = mix(accent, if (dark) 0xFFFFFFFF else 0xFF000000, 0.12);
        t.accent_fill = accentFill(accent);
        t.accent_fill_hover = mix(t.accent_fill, 0xFF000000, 0.12);
        t.accent_text = legible(accent, t.window_bg, aa_text);
        return t;
    }
};

/// The two appearances before the accent is applied (Theme.get sets
/// every accent field from the system's accent).
const dark_base: Theme = .{
    .dark = true,
    .accent = default_accent,
    .accent_hover = default_accent,
    .accent_fill = default_accent,
    .accent_fill_hover = default_accent,
    .accent_text = default_accent,
    .fg = 0xFFF5F5F7,
    .muted = 0xBFEBEBF5,
    .material = 0xCC242426,
    .material_solid = 0xFF2C2C2E,
    .hairline = 0x1FFFFFFF,
    .hover = 0x14FFFFFF,
    .pressed = 0x24FFFFFF,
    .track = 0x1FFFFFFF,
    .seg_on = 0xFF636366,
    .bar_shadow = .{ .color = 0x47000000, .blur = 40, .dy = 12 },
    .popover_shadow = .{ .color = 0x52000000, .blur = 50, .dy = 18 },
    .window_bg = 0xFF242424,
    .header_bg = 0xFF2E2E32,
    .card = 0xFF363636,
    .line = 0x14FFFFFF,
    .chip = 0x1AFFFFFF,
    .switch_off = 0x2EFFFFFF,
    .text = 0xFFFFFFFF,
    .text_muted = 0x99FFFFFF,
    .view_sel = 0x1AFFFFFF,
    .panel = 0xCC242426,
    .field = 0x14FFFFFF,
    .destructive = 0xFFFF453A,
};

const light_base: Theme = .{
    .dark = false,
    .accent = default_accent,
    .accent_hover = default_accent,
    .accent_fill = default_accent,
    .accent_fill_hover = default_accent,
    .accent_text = default_accent,
    .fg = 0xFF1D1D1F,
    .muted = 0xCC3C3C43,
    .material = 0xCCF6F6F8,
    .material_solid = 0xFFF2F2F7,
    .hairline = 0x1A000000,
    .hover = 0x0D000000,
    .pressed = 0x1A000000,
    .track = 0x14000000,
    .seg_on = 0xFFFFFFFF,
    .bar_shadow = .{ .color = 0x38000000, .blur = 40, .dy = 12 },
    .popover_shadow = .{ .color = 0x42000000, .blur = 50, .dy = 18 },
    .window_bg = 0xFFFAFAFB,
    .header_bg = 0xFFFFFFFF,
    .card = 0xFFFFFFFF,
    .line = 0x14000006,
    .chip = 0x12000006,
    .switch_off = 0x26000006,
    .text = 0xCC000006,
    .text_muted = 0x99000006,
    .view_sel = 0x12000006,
    .panel = 0xDBFAFAFC,
    .field = 0x0D000000,
    .destructive = 0xFFFF3B30,
};

/// What the desktop asks for.
pub const Prefs = struct {
    dark: bool = false,
    accent: ?u32 = null,
    /// org.gnome.desktop.interface enable-animations; false = reduce motion
    animations: bool = true,

    pub fn theme(self: Prefs) Theme {
        return Theme.get(self.dark, self.accent);
    }
};

/// `c` with its alpha replaced by `a`.
pub fn withAlpha(c: u32, a: u8) u32 {
    return (c & 0x00FFFFFF) | (@as(u32, a) << 24);
}

/// `c` with its alpha multiplied by `k` (0..1).
pub fn fade(c: u32, k: f64) u32 {
    const a: f64 = @floatFromInt(c >> 24);
    return withAlpha(c, @intFromFloat(@round(std.math.clamp(a * k, 0, 255))));
}

/// Channel-wise blend of two colours, alpha included.
pub fn mix(a: u32, b: u32, t: f64) u32 {
    const k = std.math.clamp(t, 0, 1);
    var out: u32 = 0;
    inline for (.{ 0, 8, 16, 24 }) |sh| {
        const ca: f64 = @floatFromInt((a >> sh) & 0xFF);
        const cb: f64 = @floatFromInt((b >> sh) & 0xFF);
        out |= @as(u32, @intFromFloat(@round(ca + (cb - ca) * k))) << sh;
    }
    return out;
}

/// WCAG relative luminance of an opaque colour (alpha ignored).
pub fn luminance(c: u32) f64 {
    var l: f64 = 0;
    inline for (.{ 16, 8, 0 }, .{ 0.2126, 0.7152, 0.0722 }) |sh, w| {
        const v = @as(f64, @floatFromInt((c >> sh) & 0xFF)) / 255;
        l += w * (if (v <= 0.03928) v / 12.92 else std.math.pow(f64, (v + 0.055) / 1.055, 2.4));
    }
    return l;
}

/// WCAG contrast ratio of two opaque colours, 1..21.
pub fn contrast(a: u32, b: u32) f64 {
    const la = luminance(a);
    const lb = luminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

/// `c`, darkened (on a light `bg`) or lightened (on a dark one) in small
/// steps until it reaches `min` contrast with `bg`; `c` itself when it
/// already does.
pub fn legible(c: u32, bg: u32, min: f64) u32 {
    // themes are also built at compile time (default field values)
    @setEvalBranchQuota(200_000);
    const toward: u32 = if (luminance(bg) > 0.18) 0xFF000000 else 0xFFFFFFFF;
    var k: f64 = 0;
    while (k <= 1) : (k += 1.0 / 64.0) {
        const out = mix(c | 0xFF000000, toward, k);
        if (contrast(out, bg) >= min) return out;
    }
    return toward;
}

/// The accent as a fill white text reads on (AA).
pub fn accentFill(accent: u32) u32 {
    return legible(accent, 0xFFFFFFFF, aa_text);
}

// --- org.freedesktop.portal.Settings ---

const portal_dest = "org.freedesktop.portal.Desktop";
const portal_path = "/org/freedesktop/portal/desktop";
const settings_iface = "org.freedesktop.portal.Settings";

const Key = enum { color_scheme, accent, animations };
const keys = [_]struct { ns: []const u8, key: []const u8 }{
    .{ .ns = "org.freedesktop.appearance", .key = "color-scheme" },
    .{ .ns = "org.freedesktop.appearance", .key = "accent-color" },
    .{ .ns = "org.gnome.desktop.interface", .key = "enable-animations" },
};

/// Read the appearance settings from the Settings portal, waiting at most
/// `timeout_ms` for all of them. Values the portal does not know (or no
/// portal at all) keep their defaults.
pub fn readPrefs(conn: *dbus.Connection, timeout_ms: i64) Prefs {
    var prefs: Prefs = .{};
    var serials: [keys.len]?u32 = @splat(null);
    for (keys, 0..) |k, i| {
        var m = dbus.Marshal.init(conn.alloc);
        defer m.deinit();
        m.putString(k.ns) catch return prefs;
        m.putString(k.key) catch return prefs;
        serials[i] = conn.callMethod(portal_dest, portal_path, settings_iface, "ReadOne", "ss", m.buf.items) catch return prefs;
    }
    const deadline = sys.monoMs() + timeout_ms;
    var left: usize = keys.len;
    while (left > 0) {
        var msg = (conn.readMessageDeadline(deadline) catch return prefs) orelse return prefs;
        const which = for (serials, 0..) |s, i| {
            if (s != null and msg.reply_serial != null and msg.reply_serial.? == s.?) break i;
        } else null;
        const i = which orelse {
            // not ours: leave it for whoever waits for it
            conn.pending.append(conn.alloc, msg) catch msg.deinit(conn.alloc);
            continue;
        };
        defer msg.deinit(conn.alloc);
        serials[i] = null;
        left -= 1;
        if (msg.type != .method_return) continue;
        var r = msg.reader();
        applyValue(&prefs, @fromBackingInt(@intCast(i)), &r) catch {};
    }
    return prefs;
}

/// Subscribe to the portal's SettingChanged signal.
pub fn watch(conn: *dbus.Connection) !void {
    try conn.addMatchOnce("type='signal',interface='org.freedesktop.portal.Settings',member='SettingChanged'");
}

/// Fold a SettingChanged signal into `prefs`. True when it changed a value
/// the theme uses.
pub fn applySignal(prefs: *Prefs, msg: *const dbus.Message) bool {
    if (!msg.isSignal(settings_iface, "SettingChanged")) return false;
    var r = msg.reader();
    const ns = r.readString() catch return false;
    const key = r.readString() catch return false;
    for (keys, 0..) |k, i| {
        if (!std.mem.eql(u8, k.ns, ns) or !std.mem.eql(u8, k.key, key)) continue;
        const before = prefs.*;
        applyValue(prefs, @fromBackingInt(@intCast(i)), &r) catch return false;
        return !std.meta.eql(before, prefs.*);
    }
    return false;
}

/// Read one setting's variant (unwrapping the nesting older portals add).
fn applyValue(prefs: *Prefs, which: Key, r: *dbus.Reader) !void {
    var sig = try r.readSignature();
    var depth: usize = 0;
    while (std.mem.eql(u8, sig, "v") and depth < 4) : (depth += 1) sig = try r.readSignature();
    switch (which) {
        .color_scheme => {
            if (!std.mem.eql(u8, sig, "u")) return error.BadType;
            prefs.dark = (try r.readU32()) == 1;
        },
        .accent => {
            if (!std.mem.eql(u8, sig, "(ddd)")) return error.BadType;
            r.pad(8);
            var c: [3]f64 = undefined;
            for (&c) |*v| v.* = @bitCast(try r.readU64());
            // out of range means "no accent set"
            for (c) |v| if (!(v >= 0 and v <= 1)) {
                prefs.accent = null;
                return;
            };
            var rgb: u32 = 0xFF000000;
            for (c, 0..) |v, i| rgb |= @as(u32, @intFromFloat(@round(v * 255))) << @intCast(16 - 8 * i);
            prefs.accent = rgb;
        },
        .animations => {
            if (!std.mem.eql(u8, sig, "b")) return error.BadType;
            prefs.animations = (try r.readU32()) != 0;
        },
    }
}

test "theme variants differ where they should" {
    const d = Theme.get(true, null);
    const l = Theme.get(false, 0xFF3584E4);
    try std.testing.expect(d.dark and !l.dark);
    try std.testing.expectEqual(default_accent, d.accent);
    try std.testing.expectEqual(@as(u32, 0xFF3584E4), l.accent);
    try std.testing.expect(d.fg != l.fg);
    try std.testing.expectEqual(@as(u32, 0x80FF0000), withAlpha(0xFFFF0000, 0x80));
    try std.testing.expectEqual(@as(u32, 0xFF808080), mix(0xFF000000, 0xFFFFFFFF, 0.5));
}

test "fills and text reach AA contrast, any accent" {
    for ([_]?u32{ null, 0xFF3584E4, 0xFFF6D32D, 0xFF2EC27E, 0xFFE01B24, 0xFF000000 }) |a| {
        for ([_]bool{ false, true }) |dark| {
            const t = Theme.get(dark, a);
            try std.testing.expect(contrast(t.on_accent, t.accent_fill) >= aa_text);
            try std.testing.expect(contrast(t.on_accent, t.accent_fill_hover) >= aa_text);
            try std.testing.expect(contrast(t.accent_text, t.window_bg) >= aa_text);
            try std.testing.expect(contrast(over(t.text_muted, t.window_bg), t.window_bg) >= aa_text);
        }
    }
    try std.testing.expect(contrast(0xFFFFFFFF, destructive_fill) >= aa_text);
    try std.testing.expect(contrast(0xFFFFFFFF, destructive_fill_hover) >= aa_text);
    // a colour that already reads is kept
    try std.testing.expectEqual(@as(u32, 0xFF1D1D1F), legible(0xFF1D1D1F, 0xFFFFFFFF, aa_text));
}

/// `top` composited over the opaque `bottom`.
fn over(top: u32, bottom: u32) u32 {
    return mix(bottom, top | 0xFF000000, @as(f64, @floatFromInt(top >> 24)) / 255);
}

test "portal values fold into prefs" {
    const alloc = std.testing.allocator;
    // color-scheme as ReadOne returns it: v(u)
    var m = dbus.Marshal.init(alloc);
    defer m.deinit();
    try m.putSignature("u");
    try m.putU32(2);
    var r: dbus.Reader = .{ .data = m.buf.items, .pos = 0 };
    var p: Prefs = .{};
    try applyValue(&p, .color_scheme, &r);
    try std.testing.expect(!p.dark);

    // accent-color, double-wrapped like Read: v(v((ddd)))
    var m2 = dbus.Marshal.init(alloc);
    defer m2.deinit();
    try m2.putSignature("v");
    try m2.putSignature("(ddd)");
    try m2.pad(8);
    for ([_]f64{ 1.0, 0.5, 0.0 }) |v| try m2.putU64(@bitCast(v));
    r = .{ .data = m2.buf.items, .pos = 0 };
    try applyValue(&p, .accent, &r);
    try std.testing.expectEqual(@as(u32, 0xFFFF8000), p.accent.?);
}

//! One pin window: its state, and its surface's size, place and input
//! region. The surface is the picture plus room for its shadow (`pad`),
//! grown to the right and down while the menu needs more room.

const std = @import("std");
const env_mod = @import("../env.zig");
const png = @import("../../gfx/png.zig");
const theme = @import("../../ui/theme.zig");
const window = @import("../../platform/api.zig").window;
const view = @import("view.zig");
const menu = @import("menu.zig");
const chrome = @import("chrome.zig");
const ipc = @import("ipc.zig");
const annotate = @import("annotate.zig");
const Env = env_mod.Env;
const Rect = @import("../../ui/shapes.zig").Rect;

/// shadow room around the picture, logical pixels
pub const pad = 14;
/// the menu's shadow (logical pixels), and the room it takes around the
/// menu (more below: it falls a little)
pub const menu_shadow = 10;
pub const menu_room = menu_shadow + menu_shadow / 2;

/// What the pointer is over.
pub const Hover = enum { none, picture, close, more, badge, menu };

pub const Pin = struct {
    gpa: std.mem.Allocator,
    env: Env,
    win: *window.Window,
    /// the picture (the caller's, which Annotate replaces in place)
    img: *png.Image,
    th: theme.Theme,
    /// a layer-shell surface (moved by its margins) rather than a toplevel
    layer: bool,
    born: i64,
    /// where its centre goes (logical); null: where the compositor puts it
    at: ?[2]i32 = null,
    /// first drawn (0: not yet): it fades in from there
    shown_ms: i64 = 0,
    /// "Right-click: Keep on Top" while young (GNOME without the extension)
    hint: bool = false,
    /// a plain window nothing keeps above: the menu offers its window menu
    plain: bool = false,
    margin: [4]i32 = .{ 120, 0, 0, 120 },
    // the surface in logical pixels (the menu's growth included); first
    // guess at scale 1, corrected once the real scale is known
    lw: u32 = 0,
    lh: u32 = 0,
    grow: [2]u32 = .{ 0, 0 },
    last_f: f64 = 0,
    zoom: f64 = 1,
    opacity: view.Opacity = .full,
    /// clicks go through it, but for its badge
    locked: bool = false,
    scaled: []u32 = &.{},
    scaled_w: u32 = 0,
    scaled_h: u32 = 0,
    hover: Hover = .none,
    /// the last pointer position on the surface (buffer pixels)
    pointer: [2]f64 = .{ 0, 0 },
    dirty: bool = true,
    /// the last frame drawn had nothing in motion (else one more follows
    /// once it all stops, at its end state)
    settled: bool = false,
    scroll_acc: f64 = 0,
    // layer shell: a drag in progress, from this pointer position (only
    // without relative pointer events), and the margins (top, left) it
    // has moved the pin to, unrounded
    drag_from: ?[2]f64 = null,
    drag_at: [2]f64 = .{ 0, 0 },
    drag_rel: bool = false,
    menu: menu.State = .{},
    region: [3]window.Rect = undefined,
    n_region: usize = std.math.maxInt(usize),
    ipc: ipc.Listener = .{},
    /// in the editor (Annotate): hidden until it comes back
    edit: ?annotate.Editing = null,
    quit: bool = false,

    pub fn deinit(p: *Pin) void {
        if (p.edit) |*e| e.deinit(p.gpa);
        p.ipc.close();
        p.gpa.free(p.scaled);
    }

    /// Buffer pixels per logical pixel.
    pub fn scale(p: *const Pin) f64 {
        return @as(f64, @floatFromInt(p.win.scale120)) / 120.0;
    }

    /// The picture's size on screen, buffer pixels.
    pub fn picSize(p: *const Pin) [2]u32 {
        return .{ view.zoomedSize(p.img.width, p.zoom), view.zoomedSize(p.img.height, p.zoom) };
    }

    /// The picture's place on the surface, logical pixels.
    pub fn picRect(p: *const Pin, k: f64) Rect {
        const s = p.picSize();
        return .{ .x = pad, .y = pad, .w = logical(s[0], k), .h = logical(s[1], k) };
    }

    /// The surface without the menu's growth, logical pixels.
    pub fn room(p: *const Pin, k: f64) [2]i32 {
        const r = p.picRect(k);
        return .{ r.w + 2 * pad, r.h + 2 * pad };
    }

    /// What the menu offers on this pin.
    pub fn offer(p: *const Pin) menu.Offer {
        return .{ .lock = p.win.passesClicks(), .keep_on_top = p.plain };
    }

    pub fn open(p: *Pin) !void {
        const win = p.win;
        // a layer surface is moved by hand: follow the pointer's own motion
        win.track_relative = p.layer;
        p.lw = p.img.width + 2 * pad;
        p.lh = p.img.height + 2 * pad;
        var title_buf: [48]u8 = undefined;
        const title = p.placeAt(&title_buf);
        if (p.layer) {
            try win.open(title, .{ .fullscreen = false, .transparent = true, .width = p.lw, .height = p.lh, .layer = .{
                .layer = .top,
                .anchor = .{ .top = true, .left = true },
                .width = p.lw,
                .height = p.lh,
                .margin = p.margin,
            } });
        } else {
            try win.open(title, .{ .fullscreen = false, .transparent = true, .width = p.lw, .height = p.lh });
        }
        win.report_leave = true;
        win.setCursor(.arrow) catch {};
    }

    /// With `at`: the margins (layer shell) and the title (the GNOME
    /// extension, which places the window proper: the picture) that put
    /// the picture's centre there, at the scale of the output under it.
    /// Returns the title.
    fn placeAt(p: *Pin, buf: []u8) []const u8 {
        const at = p.at orelse return "shotlet:pin";
        var s: u32 = 1;
        var origin: [2]i32 = .{ 0, 0 };
        for (p.win.outputList()) |o| {
            const r = o.logicalRect();
            const inside = at[0] >= r.x and at[0] < r.x + r.w and at[1] >= r.y and at[1] < r.y + r.h;
            if (o.id == 0 or !inside) continue;
            s = @intCast(@max(1, o.scale));
            origin = .{ r.x, r.y };
        }
        const w: i32 = @intCast((p.img.width + s - 1) / s);
        const h: i32 = @intCast((p.img.height + s - 1) / s);
        const x = at[0] - @divTrunc(w, 2);
        const y = at[1] - @divTrunc(h, 2);
        p.margin = .{ y - pad - origin[1], 0, 0, x - pad - origin[0] };
        return std.fmt.bufPrint(buf, "shotlet:pin:{d}:{d}", .{ x, y }) catch "shotlet:pin";
    }

    /// Resizes the surface when the picture, the menu's room or the
    /// scale changed, and keeps the input region current.
    pub fn fitWindow(p: *Pin, k: f64) !void {
        const rm = p.room(k);
        const want_w: u32 = @as(u32, @intCast(rm[0])) + p.grow[0];
        const want_h: u32 = @as(u32, @intCast(rm[1])) + p.grow[1];
        if (want_w != p.lw or want_h != p.lh or k != p.last_f) {
            p.lw = want_w;
            p.lh = want_h;
            p.last_f = k;
            const win = p.win;
            if (p.layer) try win.setLayerPlacement(0, p.lw, p.lh, p.margin) else try win.resizeTo(0, p.lw, p.lh);
            try win.setWindowGeometry(0, toWin(p.picRect(k)));
            p.dirty = true;
        }
        try p.updateRegion(k);
    }

    /// Where clicks land: the picture (only its badge while locked), the
    /// open menu; nothing while it is away in the editor.
    fn updateRegion(p: *Pin, k: f64) !void {
        var rs: [3]window.Rect = undefined;
        var n: usize = 0;
        if (p.edit == null) {
            const pic = p.picRect(k);
            rs[n] = toWin(if (p.locked) chrome.badgeRect(pic) else pic);
            n += 1;
            if (p.menu.open) {
                rs[n] = toWin(p.menu.rect());
                n += 1;
            }
        }
        if (n == p.n_region and std.mem.eql(u8, std.mem.sliceAsBytes(rs[0..n]), std.mem.sliceAsBytes(p.region[0..n]))) return;
        p.region = rs;
        p.n_region = n;
        try p.win.setInputRegion(0, rs[0..n]);
        p.dirty = true;
    }

    /// Opens the menu with its top-left near `anchor` (logical, on the
    /// surface), growing the surface when it does not fit.
    pub fn openMenu(p: *Pin, anchor: [2]i32, by_key: bool, now: i64) void {
        const k = p.scale();
        const lay = menu.layout(p.offer());
        const rm = p.room(k);
        const at = menu.place(anchor, lay.size(), rm, menu_room);
        p.menu.show(lay, at, if (by_key) 0 else null, now);
        p.grow = menu.growth(p.menu.rect(), rm, menu_room);
        p.dirty = true;
        // a floating surface's menu takes the keyboard while it is open,
        // as a popup would (some compositors drop the focus of a surface
        // that grows)
        if (p.layer) p.win.setLayerKeyboard(0, .exclusive) catch {};
        std.log.info("pin: menu open", .{});
    }

    pub fn closeMenu(p: *Pin, now: i64) void {
        if (!p.menu.open) return;
        p.menu.hide(now);
        p.dirty = true;
        if (p.layer) p.win.setLayerKeyboard(0, .on_demand) catch {};
        std.log.info("pin: menu closed", .{});
    }

    /// Once the menu has faded out, the surface gives its room back.
    pub fn settleMenu(p: *Pin, now: i64) void {
        if (p.menu.visible(now) or (p.grow[0] == 0 and p.grow[1] == 0)) return;
        p.grow = .{ 0, 0 };
        p.dirty = true;
    }

    pub fn setOpacity(p: *Pin, o: view.Opacity) void {
        if (o == p.opacity) return;
        p.opacity = o;
        p.dirty = true;
        std.log.info("pin: opacity {s}", .{o.label()});
    }

    pub fn setZoom(p: *Pin, z: f64) void {
        p.zoom = z;
        p.dirty = true;
    }
};

fn toWin(r: Rect) window.Rect {
    return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
}

/// `n` buffer pixels in logical pixels, rounded up.
pub fn logical(n: u32, k: f64) i32 {
    return @intFromFloat(@ceil(@as(f64, @floatFromInt(n)) / k));
}

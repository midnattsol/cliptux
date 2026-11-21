//! shotlet-wldrive's commands (listed in wldrive.zig): one function each.

const std = @import("std");
const kit = @import("shotlet");
const sys = kit.sys;
const Driver = @import("Driver.zig");
const Frame = @import("grab.zig").Frame;
const util = @import("util.zig");
const eql = util.eql;
const trimHex = util.trimHex;

const Args = std.mem.TokenIterator(u8, .any);

/// The next argument of a command.
fn arg(it: *Args) ![]const u8 {
    return it.next() orelse error.MissingArg;
}

/// Run one command line; its answer's value (empty for a plain `ok`).
pub fn run(d: *Driver, line: []const u8) ![]const u8 {
    defer d.drain() catch {};
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const cmd = it.next() orelse return "";
    if (eql(cmd, "key")) return key(d, &it);
    if (eql(cmd, "type")) return typeText(d, std.mem.trimStart(u8, line[cmd.len..], " \t"));
    if (eql(cmd, "move")) return move(d, &it);
    if (eql(cmd, "down") or eql(cmd, "up") or eql(cmd, "click")) return button(d, cmd, &it);
    if (eql(cmd, "wheel")) {
        try d.wheel(try std.fmt.parseInt(i32, try arg(&it), 10));
        return "";
    }
    if (eql(cmd, "monitors")) return monitors(d);
    if (eql(cmd, "shot")) return shot(d, &it);
    if (eql(cmd, "find") or eql(cmd, "findpng")) return find(d, cmd, &it);
    if (eql(cmd, "png") or eql(cmd, "pixel")) return image(d, cmd, &it);
    if (eql(cmd, "mkpng")) return mkpng(d, &it);
    if (eql(cmd, "textpng")) return textpng(d, line, &it);
    if (eql(cmd, "sleep")) {
        util.sleepMs(try std.fmt.parseInt(u32, try arg(&it), 10));
        return "";
    }
    if (eql(cmd, "quit")) return "";
    return error.UnknownCommand;
}

/// key COMBO [down|up]
fn key(d: *Driver, it: *Args) ![]const u8 {
    const combo = try arg(it);
    const mode = it.next() orelse "tap";
    var codes: [8]u32 = undefined;
    const n = try util.parseCombo(combo, &codes);
    if (!eql(mode, "up")) for (codes[0..n]) |c| try d.key(c, true);
    if (!eql(mode, "down")) {
        var i = n;
        while (i > 0) {
            i -= 1;
            try d.key(codes[i], false);
        }
    }
    return "";
}

/// type TEXT
fn typeText(d: *Driver, text: []const u8) ![]const u8 {
    for (text) |c| {
        const name: []const u8 = if (c == ' ') "space" else &.{c};
        const code = util.keyCode(name) orelse return error.UnknownKey;
        try d.key(code, true);
        try d.key(code, false);
    }
    return "";
}

/// move MON X Y
fn move(d: *Driver, it: *Args) ![]const u8 {
    const o = try d.monitor(try arg(it));
    const x = try std.fmt.parseFloat(f64, try arg(it));
    const y = try std.fmt.parseFloat(f64, try arg(it));
    try d.moveTo(@as(f64, @floatFromInt(o.x)) + x, @as(f64, @floatFromInt(o.y)) + y);
    return "";
}

/// down|up|click [BTN]
fn button(d: *Driver, cmd: []const u8, it: *Args) ![]const u8 {
    const name = it.next() orelse "left";
    const btn: u32 = if (eql(name, "left")) 0x110 else if (eql(name, "right")) 0x111 else if (eql(name, "middle")) 0x112 else return error.UnknownButton;
    if (!eql(cmd, "up")) try d.button(btn, true);
    if (!eql(cmd, "down")) try d.button(btn, false);
    return "";
}

/// monitors: "NAME:X,Y,WxH@SCALE ..."
fn monitors(d: *Driver) []const u8 {
    var w: usize = 0;
    for (d.outputs.items) |o| {
        const s = std.fmt.bufPrint(d.out[w..], "{s}{s}:{d},{d},{d}x{d}@{d}", .{ if (w > 0) " " else "", o.name(), o.x, o.y, o.w, o.h, o.scale }) catch break;
        w += s.len;
    }
    return d.out[0..w];
}

/// shot MON PATH
fn shot(d: *Driver, it: *Args) ![]const u8 {
    const o = try d.monitor(try arg(it));
    const path = try arg(it);
    const f = try d.grab(o);
    defer d.gpa.free(f.pixels);
    return d.writePng(path, f.pixels, f.width, f.height);
}

/// find MON | findpng PATH, then RRGGBB [TOL [MINW [X0 Y0 X1 Y1]]]
fn find(d: *Driver, cmd: []const u8, it: *Args) ![]const u8 {
    const what = try arg(it);
    const rgb = try std.fmt.parseInt(u32, trimHex(try arg(it)), 16);
    const tol = try std.fmt.parseInt(u32, it.next() orelse "24", 10);
    const min_w = try std.fmt.parseInt(u32, it.next() orelse "1", 10);
    const f: Frame = if (eql(cmd, "find")) try d.grab(try d.monitor(what)) else try loadFrame(d.gpa, what);
    defer d.gpa.free(f.pixels);
    if (it.next()) |first| {
        var region: [4]u32 = undefined;
        region[0] = try std.fmt.parseInt(u32, first, 10);
        for (region[1..]) |*v| v.* = try std.fmt.parseInt(u32, try arg(it), 10);
        util.maskOutside(f.pixels, f.width, region, rgb);
    }
    const box = try util.findBlob(d.gpa, f.pixels, f.width, f.height, rgb, tol, min_w);
    return std.fmt.bufPrint(&d.out, "{d} {d} {d} {d}", .{ (box[0] + box[2]) / 2, (box[1] + box[3]) / 2, box[2] - box[0] + 1, box[3] - box[1] + 1 });
}

/// A PNG file's pixels.
fn loadFrame(gpa: std.mem.Allocator, path: []const u8) !Frame {
    const data = try sys.readFileAlloc(gpa, path, 256 * 1024 * 1024);
    defer gpa.free(data);
    const img = try kit.png.decode(gpa, data);
    return .{ .pixels = img.pixels, .width = img.width, .height = img.height };
}

/// png PATH | pixel PATH X Y
fn image(d: *Driver, cmd: []const u8, it: *Args) ![]const u8 {
    const path = try arg(it);
    const data = try sys.readFileAlloc(d.gpa, path, 256 * 1024 * 1024);
    defer d.gpa.free(data);
    var img = try kit.png.decode(d.gpa, data);
    defer img.deinit(d.gpa);
    if (eql(cmd, "png")) return std.fmt.bufPrint(&d.out, "{d}x{d}", .{ img.width, img.height });
    const x = try std.fmt.parseInt(u32, try arg(it), 10);
    const y = try std.fmt.parseInt(u32, try arg(it), 10);
    if (x >= img.width or y >= img.height) return error.OutOfImage;
    return std.fmt.bufPrint(&d.out, "{x:0>8}", .{img.pixels[@as(usize, y) * img.width + x]});
}

/// mkpng PATH W H RRGGBB: a dark grey frame around a RRGGBB rectangle
fn mkpng(d: *Driver, it: *Args) ![]const u8 {
    const path = try arg(it);
    const w = try std.fmt.parseInt(u32, try arg(it), 10);
    const h = try std.fmt.parseInt(u32, try arg(it), 10);
    const rgb = try std.fmt.parseInt(u32, trimHex(try arg(it)), 16);
    const px = try d.gpa.alloc(u32, @as(usize, w) * h);
    defer d.gpa.free(px);
    for (px, 0..) |*p, i| {
        const x = i % w;
        const y = i / w;
        const inner = x >= w / 5 and x < w - w / 5 and y >= h / 5 and y < h - h / 5;
        p.* = if (inner) 0xFF000000 | rgb else 0xFF303030;
    }
    return d.writePng(path, px, w, h);
}

/// textpng PATH SIZE TEXT: black text on white, in Shotlet's own text
/// renderer
fn textpng(d: *Driver, line: []const u8, it: *Args) ![]const u8 {
    const path = try arg(it);
    const size = try std.fmt.parseFloat(f64, try arg(it));
    const first = try arg(it);
    const s = line[@intFromPtr(first.ptr) - @intFromPtr(line.ptr) ..];
    kit.text.init(d.gpa);
    defer kit.text.deinit();
    if (!kit.text.available()) return error.NoFont;
    const w: u32 = @intCast(kit.text.width(size, s) + 80);
    const h: u32 = @intFromFloat(size * 3);
    const px = try d.gpa.alloc(u32, @as(usize, w) * h);
    defer d.gpa.free(px);
    @memset(px, 0xFFFFFFFF);
    var c = kit.render.Canvas.init(px, w, h);
    kit.text.draw(&c, 40, @intFromFloat(size), size, 0xFF000000, s);
    return d.writePng(path, px, w, h);
}

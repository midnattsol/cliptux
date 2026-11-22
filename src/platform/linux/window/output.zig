//! Outputs (monitors): wl_output and zxdg_output_v1 state, each output's
//! logical rectangle in the compositor's desktop space, and unplugging.

const std = @import("std");
const wl = @import("../wayland.zig");
const window = @import("../window.zig");
const surface = @import("surface.zig");
const scale = @import("scale.zig");

const Window = window.Window;
const Rect = window.Rect;
const Surface = surface.Surface;
const max_outputs = window.max_outputs;

/// A wl_output the compositor announced.
pub const Output = struct {
    /// wl_output object id; 0 = empty slot
    id: u32 = 0,
    /// registry global name (stable identity of the output)
    global: u32 = 0,
    version: u32 = 0,
    xdg: u32 = 0, // zxdg_output_v1
    /// integer scale (wl_output.scale)
    scale: i32 = 1,
    /// logical rectangle in the compositor's desktop space
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    has_logical: bool = false,
    geo_x: i32 = 0,
    geo_y: i32 = 0,
    mode_w: i32 = 0,
    mode_h: i32 = 0,
    name_buf: [64]u8 = @splat(0),
    name_len: u8 = 0,
    desc_buf: [128]u8 = @splat(0),
    desc_len: u8 = 0,
    done: bool = false,

    pub fn name(self: *const Output) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn description(self: *const Output) []const u8 {
        return self.desc_buf[0..self.desc_len];
    }

    /// Logical rectangle: xdg_output when known, else derived from the
    /// wl_output geometry, current mode and integer scale.
    pub fn logicalRect(self: *const Output) Rect {
        if (self.has_logical and self.w > 0 and self.h > 0)
            return .{ .x = self.x, .y = self.y, .w = self.w, .h = self.h };
        const sc = @max(1, self.scale);
        return .{ .x = self.geo_x, .y = self.geo_y, .w = @divTrunc(self.mode_w, sc), .h = @divTrunc(self.mode_h, sc) };
    }
};

/// The known outputs; empty slots have id 0.
pub const Outputs = struct {
    list: [max_outputs]Output = @splat(.{}),

    pub fn slotOf(self: *const Outputs, obj: u32) ?usize {
        if (obj == 0) return null;
        for (self.list, 0..) |o, slot| if (o.id == obj) return slot;
        return null;
    }

    pub fn xdgSlotOf(self: *const Outputs, obj: u32) ?usize {
        if (obj == 0) return null;
        for (self.list, 0..) |o, slot| if (o.xdg == obj) return slot;
        return null;
    }

    /// The output a surface is fullscreen on: its assigned one, else the
    /// only output it entered.
    pub fn covering(self: *const Outputs, s: *const Surface) ?*const Output {
        var found: ?*const Output = null;
        for (&self.list, 0..) |*o, slot| {
            if (o.id == 0) continue;
            if (s.output != 0) {
                if (o.global == s.output) return o;
            } else if (s.entered & (@as(u32, 1) << @intCast(slot)) != 0) {
                if (found != null) return null;
                found = o;
            }
        }
        return found;
    }

    /// Slots of the known outputs, ordered left to right, top to bottom.
    pub fn sortedSlots(self: *const Outputs, buf: *[max_outputs]u8) []u8 {
        var n: usize = 0;
        for (self.list, 0..) |o, slot| if (o.id != 0) {
            buf[n] = @intCast(slot);
            n += 1;
        };
        const Ctx = struct {
            outs: []const Output,
            fn less(ctx: @This(), a: u8, b: u8) bool {
                const ra = ctx.outs[a].logicalRect();
                const rb = ctx.outs[b].logicalRect();
                return if (ra.x != rb.x) ra.x < rb.x else ra.y < rb.y;
            }
        };
        std.mem.sort(u8, buf[0..n], Ctx{ .outs = &self.list }, Ctx.less);
        return buf[0..n];
    }

    /// The output whose logical rectangle starts at x, y.
    pub fn atOrigin(self: *Outputs, x: i32, y: i32) ?*Output {
        for (&self.list) |*o| {
            if (o.id == 0) continue;
            const r = o.logicalRect();
            if (r.x == x and r.y == y) return o;
        }
        return null;
    }
};

/// Outputs currently known (empty slots filtered out by the caller via
/// `id != 0`).
pub fn outputList(w: *Window) []const Output {
    return &w.outputs.list;
}

/// Bind a wl_output global into a free slot.
pub fn add(w: *Window, name: u32, iface: []const u8, version: u32) !void {
    for (&w.outputs.list) |*o| {
        if (o.id != 0) continue;
        const v = @min(version, 4);
        o.* = .{ .global = name, .version = v };
        o.id = try w.conn.bind(w.globals.registry, name, iface, v);
        try ensureXdg(w, o);
        break;
    } else std.log.warn("more than {d} outputs; ignoring one", .{max_outputs});
}

fn ensureXdg(w: *Window, o: *Output) !void {
    const mgr = w.globals.xdg_output_manager;
    if (mgr == 0 or o.id == 0 or o.xdg != 0) return;
    o.xdg = w.conn.newId();
    try w.conn.request(mgr, wl.zxdg_output_manager_v1.get_xdg_output, &.{ .{ .new_id = o.xdg }, .{ .object = o.id } });
}

/// Ask for every known output's xdg_output; whether any output is known.
pub fn ensureAllXdg(w: *Window) !bool {
    var any_output = false;
    for (&w.outputs.list) |*o| if (o.id != 0) {
        any_output = true;
        try ensureXdg(w, o);
    };
    return any_output;
}

/// The output global `name` went away (unplugged).
pub fn remove(w: *Window, name: u32) !void {
    for (&w.outputs.list, 0..) |*o, slot| {
        if (o.id == 0 or o.global != name) continue;
        try dropSurfacesOn(w, slot, name);
        const c = &w.conn;
        if (o.xdg != 0) c.request(o.xdg, wl.zxdg_output_v1.destroy, &.{}) catch {};
        if (o.version >= 3) c.request(o.id, wl.wl_output.release, &.{}) catch {};
        o.* = .{};
        for (0..w.n_surfaces) |i| try scale.updateIntScale(w, @intCast(i));
        try c.flush();
        return;
    }
}

/// Forget the output in every surface's entered set and tear down the
/// surfaces fullscreened on it (never surface 0: the compositor moves
/// that one, and the classic API relies on it).
fn dropSurfacesOn(w: *Window, slot: usize, name: u32) !void {
    for (w.surfaces[0..w.n_surfaces], 0..) |*s, i| {
        s.entered &= ~(@as(u32, 1) << @intCast(slot));
        if (i != 0 and s.alive and s.output == name) {
            surface.destroy(w, @intCast(i));
            try w.queue.append(w.alloc, .{ .resize = .{ .w = 0, .h = 0, .surface = @intCast(i) } });
        }
    }
}

fn copyStr(dst: []u8, src: []const u8) u8 {
    const n = @min(dst.len, src.len, 255);
    @memcpy(dst[0..n], src[0..n]);
    return @intCast(n);
}

/// wl_output events.
pub fn handleOutput(w: *Window, slot: usize, opcode: u16, r: *wl.ArgReader) !void {
    const o = &w.outputs.list[slot];
    switch (opcode) {
        wl.wl_output.ev_geometry => {
            o.geo_x = try r.int();
            o.geo_y = try r.int();
            if (o.version < 2) o.done = true;
        },
        wl.wl_output.ev_mode => {
            const flags = try r.uint();
            const mw = try r.int();
            const mh = try r.int();
            if (flags & wl.wl_output.mode_current != 0) {
                o.mode_w = mw;
                o.mode_h = mh;
            }
        },
        wl.wl_output.ev_scale => o.scale = @max(1, try r.int()),
        wl.wl_output.ev_name => o.name_len = copyStr(&o.name_buf, try r.string()),
        wl.wl_output.ev_description => o.desc_len = copyStr(&o.desc_buf, try r.string()),
        wl.wl_output.ev_done => try changed(w, slot),
        else => {},
    }
}

/// zxdg_output_v1 events.
pub fn handleXdgOutput(w: *Window, slot: usize, opcode: u16, r: *wl.ArgReader) !void {
    const o = &w.outputs.list[slot];
    switch (opcode) {
        wl.zxdg_output_v1.ev_logical_position => {
            o.x = try r.int();
            o.y = try r.int();
            o.has_logical = true;
        },
        wl.zxdg_output_v1.ev_logical_size => {
            o.w = try r.int();
            o.h = try r.int();
            o.has_logical = true;
        },
        wl.zxdg_output_v1.ev_name => if (o.name_len == 0) {
            o.name_len = copyStr(&o.name_buf, try r.string());
        },
        wl.zxdg_output_v1.ev_done => try changed(w, slot),
        else => {},
    }
}

/// An output's state is complete: refresh surfaces placed on it.
fn changed(w: *Window, slot: usize) !void {
    const o = &w.outputs.list[slot];
    o.done = true;
    for (w.surfaces[0..w.n_surfaces], 0..) |*s, i| {
        if (!s.alive) continue;
        if (s.output != 0 and s.output == o.global) setOutputRect(s, o);
        try scale.updateIntScale(w, @intCast(i));
    }
}

/// Record the output's logical rectangle on a surface placed on it.
pub fn setOutputRect(s: *Surface, o: *const Output) void {
    const r = o.logicalRect();
    s.x = r.x;
    s.y = r.y;
    s.out_w = @intCast(@max(0, r.w));
    s.out_h = @intCast(@max(0, r.h));
}

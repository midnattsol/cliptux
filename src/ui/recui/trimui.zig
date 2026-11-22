//! `shotlet trim ROOT ID`: the trim window of a kept recording. Drag the
//! yellow handles on the filmstrip (or click it to move the playhead),
//! play the range, then Save trimmed: a new file next to the original,
//! kept and shown as a new thumbnail. `--range A,B --export` does it
//! without a window (tests, scripts).

const std = @import("std");
const env_mod = @import("../../app/env.zig");
const config = @import("../../app/config.zig");
const history = @import("../../app/history.zig");
const keep = @import("../../app/keep.zig");
const sys = @import("../../platform/sys.zig");
const png = @import("../../gfx/png.zig");
const text = @import("../../gfx/text.zig");
const render = @import("../../gfx/render.zig");
const window = @import("../window.zig");
const keepvid = @import("../../record/keepvid.zig");
const trim = @import("../../record/trim.zig");
const strip_mod = @import("../../record/strip.zig");
const draw = @import("trim_draw.zig");
const Env = env_mod.Env;

const Trim = struct {
    gpa: std.mem.Allocator,
    env: Env,
    root: []const u8,
    id: []const u8,
    info: keepvid.Info,
    strip: ?png.Image,
    /// frame number of each strip picture
    marks: [strip_mod.max]u64 = undefined,
    n_marks: usize = 0,
    st: draw.State,
    dragging: ?draw.Part = null,
    play_t0: i64 = 0,
    play_pos0: i64 = 0,
    pic_buf: []u32 = &.{},
    done: bool = false,

    /// The strip picture nearest to `ms`.
    fn pictureAt(self: *Trim, ms: i64) void {
        const s = self.strip orelse return;
        if (self.n_marks == 0) return;
        const frame: u64 = @intCast(@divTrunc(@max(ms, 0) * self.info.fps, 1000));
        var best: usize = 0;
        for (self.marks[0..self.n_marks], 0..) |m, i| if (m <= frame) {
            best = i;
        };
        const pw = s.width / @as(u32, @intCast(self.n_marks));
        if (self.pic_buf.len != @as(usize, pw) * s.height) {
            self.gpa.free(self.pic_buf);
            self.pic_buf = self.gpa.alloc(u32, @as(usize, pw) * s.height) catch return;
        }
        for (0..s.height) |y| @memcpy(self.pic_buf[y * pw ..][0..pw], s.pixels[y * s.width + best * pw ..][0..pw]);
        self.st.pic = self.pic_buf;
        self.st.pic_w = pw;
        self.st.pic_h = s.height;
    }

    fn seek(self: *Trim, ms: i64) void {
        self.st.pos_ms = std.math.clamp(ms, 0, self.info.duration_ms);
        self.pictureAt(self.st.pos_ms);
    }

    fn onPress(self: *Trim, x: i32, y: i32) void {
        const p = draw.hit(x, y, &self.st) orelse return;
        switch (p) {
            .play => self.togglePlay(),
            .cancel => self.done = true,
            .save => self.save(),
            .start, .end => self.dragging = p,
            .strip => {
                self.dragging = .strip;
                self.seek(draw.msAt(x, self.info.duration_ms));
            },
        }
    }

    fn onDrag(self: *Trim, x: i32) void {
        const d = self.dragging orelse return;
        const ms = draw.msAt(x, self.info.duration_ms);
        const min_len = 200;
        switch (d) {
            .start => {
                self.st.start_ms = std.math.clamp(ms, 0, self.st.end_ms - min_len);
                self.seek(self.st.start_ms);
            },
            .end => {
                self.st.end_ms = std.math.clamp(ms, self.st.start_ms + min_len, self.info.duration_ms);
                self.seek(self.st.end_ms);
            },
            .strip => self.seek(ms),
            else => {},
        }
    }

    fn togglePlay(self: *Trim) void {
        self.st.playing = !self.st.playing;
        if (!self.st.playing) return;
        if (self.st.pos_ms < self.st.start_ms or self.st.pos_ms >= self.st.end_ms - 50) self.seek(self.st.start_ms);
        self.play_t0 = sys.monoMs();
        self.play_pos0 = self.st.pos_ms;
    }

    fn tick(self: *Trim) void {
        if (!self.st.playing) return;
        const pos = self.play_pos0 + sys.monoMs() - self.play_t0;
        if (pos >= self.st.end_ms) {
            self.st.playing = false;
            self.seek(self.st.end_ms);
            return;
        }
        self.seek(pos);
    }

    fn save(self: *Trim) void {
        self.st.busy = "Saving\u{2026}";
        if (exportRange(self.gpa, self.env, &self.info, .{ .start_ms = self.st.start_ms, .end_ms = self.st.end_ms })) {
            self.done = true;
        } else |err| {
            std.log.warn("trim: failed: {t}", .{err});
            self.st.busy = if (err == error.NoFfmpeg) "Trimming videos needs the ffmpeg program" else "Could not trim";
        }
    }
};

/// Cut, keep the result and show its thumbnail.
pub fn exportRange(gpa: std.mem.Allocator, env: Env, info: *const keepvid.Info, r: trim.Range) !void {
    const envp: @import("../../encode/proc.zig").Envp = @ptrCast(env.envp);
    const dst = try trim.outputPath(gpa, info.path);
    defer gpa.free(dst);
    trim.cut(gpa, envp, info.path, dst, r) catch |err| {
        sys.unlink(dst) catch {};
        return err;
    };
    std.log.info("trim: wrote {s} ({d}-{d} ms)", .{ dst, r.start_ms, r.end_ms });
    const first = firstPicture(gpa, envp, dst, info) catch |err| {
        std.log.info("trim: no first picture ({t}); not kept", .{err});
        return;
    };
    defer gpa.free(first);
    const cfg = config.load(gpa, env.home);
    var strip: strip_mod.Strip = .{ .gpa = gpa };
    defer strip.deinit();
    var out = info.*;
    out.path = dst;
    out.duration_ms = r.end_ms - r.start_ms;
    out.frames = @intCast(@divTrunc(out.duration_ms * info.fps, 1000));
    out.strip = "";
    if (keepvid.store(gpa, env, &cfg, .{ .info = out, .first = first, .first_w = info.width, .first_h = info.height, .strip = &strip })) |k| {
        var rb: [1100]u8 = undefined;
        var ib: [40]u8 = undefined;
        const rz = std.fmt.bufPrintSentinel(&rb, "{s}", .{k.root()}, 0) catch return;
        const iz = std.fmt.bufPrintSentinel(&ib, "{s}", .{k.id.slice()}, 0) catch return;
        if (cfg.showsThumbnail(true)) keep.spawnSelf(env, &.{ "quick-video", rz.ptr, iz.ptr });
    }
}

fn firstPicture(gpa: std.mem.Allocator, envp: @import("../../encode/proc.zig").Envp, path: []const u8, info: *const keepvid.Info) ![]u32 {
    if (info.format == .mp4) return trim.frameAt(gpa, envp, path, 0, info.width, info.height);
    const data = try sys.readFileAlloc(gpa, path, 512 * 1024 * 1024);
    defer gpa.free(data);
    var d = try @import("../../encode/gifdec.zig").Decoder.init(gpa, data);
    defer d.deinit();
    const f = (try d.next()) orelse return error.NoFrame;
    return gpa.dupe(u32, f.pixels);
}

fn parseRange(s: []const u8) !trim.Range {
    const c = std.mem.indexOfScalar(u8, s, ',') orelse return error.BadRange;
    return .{ .start_ms = try std.fmt.parseInt(i64, s[0..c], 10), .end_ms = try std.fmt.parseInt(i64, s[c + 1 ..], 10) };
}

pub fn run(gpa: std.mem.Allocator, env: Env, root: []const u8, id: []const u8, opts: []const []const u8) !void {
    if (!history.Id.valid(id)) return error.BadId;
    const vi = keepvid.read(gpa, root, id) orelse return error.NotARecording;
    defer gpa.free(vi.buf);
    var range: trim.Range = .{ .start_ms = 0, .end_ms = vi.info.duration_ms };
    var headless = false;
    var i: usize = 0;
    while (i < opts.len) : (i += 1) {
        if (std.mem.eql(u8, opts[i], "--range") and i + 1 < opts.len) {
            range = try parseRange(opts[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, opts[i], "--export")) headless = true;
    }
    if (headless) return exportRange(gpa, env, &vi.info, range);
    try runWindow(gpa, env, root, id, vi.info, range);
}

fn runWindow(gpa: std.mem.Allocator, env: Env, root: []const u8, id: []const u8, info: keepvid.Info, range: trim.Range) !void {
    text.init(gpa);
    defer text.deinit();
    var t: Trim = .{ .gpa = gpa, .env = env, .root = root, .id = id, .info = info, .strip = null, .st = .{ .duration_ms = info.duration_ms, .start_ms = range.start_ms, .end_ms = range.end_ms, .pos_ms = range.start_ms } };
    defer gpa.free(t.pic_buf);
    var pbuf: [1200]u8 = undefined;
    if (sys.readFileAlloc(gpa, try history.entryPath(&pbuf, root, id, "strip.png"), 64 * 1024 * 1024)) |data| {
        defer gpa.free(data);
        t.strip = png.decode(gpa, data) catch null;
    } else |_| {}
    defer if (t.strip) |*s| s.deinit(gpa);
    var it = std.mem.splitScalar(u8, info.strip, ',');
    while (it.next()) |m| {
        if (t.n_marks == t.marks.len) break;
        t.marks[t.n_marks] = std.fmt.parseInt(u64, m, 10) catch continue;
        t.n_marks += 1;
    }
    if (t.strip) |s| {
        t.st.strip_px = s.pixels;
        t.st.strip_w = s.width;
        t.st.strip_h = s.height;
    }
    t.seek(range.start_ms);
    var win = try window.Window.init(gpa, env.runtime_dir, env.wayland_display);
    defer win.deinit();
    try win.open("Trim recording", .{ .fullscreen = false, .width = draw.width, .height = draw.height });
    win.setCursor(.arrow) catch {};
    std.log.info("trim: {s} ({d} ms)", .{ info.path, info.duration_ms });
    var dirty = true;
    while (!t.done) {
        if (try win.nextEventTimeout(win.pollTimeoutMs(if (t.st.playing) 30 else 200))) |ev| {
            try onEvent(&t, &win, ev);
            dirty = true;
        }
        while (win.queue.items.len > 0) try onEvent(&t, &win, try win.nextEvent());
        t.tick();
        if (dirty or t.st.playing) dirty = !try paint(&t, &win);
    }
}

fn onEvent(t: *Trim, win: *window.Window, ev: window.InputEvent) !void {
    const k = @as(f64, @floatFromInt(win.scale120)) / 120.0;
    switch (ev) {
        .close => t.done = true,
        .pointer_motion => |m| {
            const x: i32 = @intFromFloat(m.x / k);
            const y: i32 = @intFromFloat(m.y / k);
            t.onDrag(x);
            t.st.hover = if (t.dragging == null) draw.hit(x, y, &t.st) else t.dragging;
        },
        .pointer_button => |b| if (b.button == window.BTN_LEFT) {
            if (b.pressed) t.onPress(@intFromFloat(b.x / k), @intFromFloat(b.y / k)) else t.dragging = null;
        },
        .key => |key| if (key.pressed) switch (key.code) {
            window.KEY_ESC => t.done = true,
            window.KEY_SPACE => t.togglePlay(),
            window.KEY_ENTER => t.save(),
            else => {},
        },
        else => {},
    }
}

/// Draw a frame; false when the window was not ready for one.
fn paint(t: *Trim, win: *window.Window) !bool {
    if (win.frame_pending or win.width == 0) return false;
    const px = try win.backBuffer();
    var cv = render.Canvas.init(px, win.width, win.height);
    draw.paint(t.gpa, &cv, @as(f64, @floatFromInt(win.scale120)) / 120.0, &t.st);
    try win.present();
    return true;
}

test "trim ranges parse" {
    const r = try parseRange("1000,2500");
    try std.testing.expectEqual(@as(i64, 2500), r.end_ms);
    try std.testing.expectError(error.BadRange, parseRange("12"));
}

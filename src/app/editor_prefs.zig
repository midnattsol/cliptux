//! What the editor remembers between captures: the beautify frame's
//! style, whether every capture starts with it ("always apply"), whether
//! the first-run hint was shown and the magnifier's zoom. Beautify itself
//! is per capture.

const std = @import("std");
const config = @import("config.zig");
const Env = @import("env.zig").Env;

/// Store the editor's beautify style, "always apply", the first-run
/// hint flag and the magnifier's zoom, only the keys that changed (other settings in the file are
/// left alone).
pub fn remember(gpa: std.mem.Allocator, env: Env, cfg: *const config.Config, ed: anytype) void {
    const b = ed.beautify;
    var bg_buf: [8]u8 = undefined;
    var zoom_buf: [8]u8 = undefined;
    var changes: [7]config.Change = undefined;
    var n: usize = 0;
    const tf = struct {
        fn s(v: bool) []const u8 {
            return if (v) "true" else "false";
        }
    }.s;
    if (ed.beautify_always != cfg.beautify_always) {
        changes[n] = .{ .key = "beautify_always", .value = tf(ed.beautify_always) };
        n += 1;
    }
    if (b.bg != cfg.beautify_background) {
        changes[n] = .{ .key = "beautify_background", .value = std.fmt.bufPrint(&bg_buf, "{d}", .{b.bg}) catch "0" };
        n += 1;
    }
    if (b.padding != cfg.beautify_padding) {
        changes[n] = .{ .key = "beautify_padding", .value = config.padding_names[b.padding] };
        n += 1;
    }
    if (b.rounded != cfg.beautify_corners) {
        changes[n] = .{ .key = "beautify_corners", .value = tf(b.rounded) };
        n += 1;
    }
    if (b.shadow != cfg.beautify_shadow) {
        changes[n] = .{ .key = "beautify_shadow", .value = tf(b.shadow) };
        n += 1;
    }
    if (ed.hint_seen and !cfg.hint_shown) {
        changes[n] = .{ .key = "hint_shown", .value = "true" };
        n += 1;
    }
    if (ed.loupe.zoom != cfg.loupe_zoom) {
        changes[n] = .{ .key = "loupe_zoom", .value = std.fmt.bufPrint(&zoom_buf, "{d}", .{ed.loupe.zoom}) catch "8" };
        n += 1;
    }
    if (n == 0) return;
    config.update(gpa, env.home, changes[0..n]) catch |err|
        std.log.warn("could not save editor settings: {t}", .{err});
}

//! HSV and RGB (0xAARRGGBB), for the custom colour picker.

const std = @import("std");

pub fn hsvToRgb(h: f64, s: f64, v: f64) u32 {
    const c = v * s;
    const hp = @mod(h, 360.0) / 60.0;
    const x = c * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    var r: f64 = 0;
    var g: f64 = 0;
    var b: f64 = 0;
    if (hp < 1) {
        r = c;
        g = x;
    } else if (hp < 2) {
        r = x;
        g = c;
    } else if (hp < 3) {
        g = c;
        b = x;
    } else if (hp < 4) {
        g = x;
        b = c;
    } else if (hp < 5) {
        r = x;
        b = c;
    } else {
        r = c;
        b = x;
    }
    const m = v - c;
    const ri: u32 = @intFromFloat(@round((r + m) * 255.0));
    const gi: u32 = @intFromFloat(@round((g + m) * 255.0));
    const bi: u32 = @intFromFloat(@round((b + m) * 255.0));
    return 0xFF000000 | ri << 16 | gi << 8 | bi;
}

pub fn rgbToHsv(c: u32) [3]f64 {
    const r = ff(@intCast((c >> 16) & 0xFF)) / 255.0;
    const g = ff(@intCast((c >> 8) & 0xFF)) / 255.0;
    const b = ff(@intCast(c & 0xFF)) / 255.0;
    const mx = @max(r, @max(g, b));
    const mn = @min(r, @min(g, b));
    const d = mx - mn;
    var h: f64 = 0;
    if (d > 0) {
        if (mx == r) {
            h = 60.0 * @mod((g - b) / d, 6.0);
        } else if (mx == g) {
            h = 60.0 * ((b - r) / d + 2.0);
        } else {
            h = 60.0 * ((r - g) / d + 4.0);
        }
    }
    return .{ h, if (mx == 0) 0 else d / mx, mx };
}

// --- loupe ---

test "hsv round trip" {
    for ([_]u32{ 0xFFE03131, 0xFF339AF0, 0xFFFFFFFF, 0xFF000000, 0xFF51CF66, 0xFF15AABF }) |c| {
        const hsv = rgbToHsv(c);
        const back = hsvToRgb(hsv[0], hsv[1], hsv[2]);
        inline for (.{ 16, 8, 0 }) |sh| {
            const a: i32 = @intCast((c >> sh) & 0xFF);
            const b: i32 = @intCast((back >> sh) & 0xFF);
            try std.testing.expect(@abs(a - b) <= 1);
        }
    }
}

fn ff(v: i32) f64 {
    return @floatFromInt(v);
}

//! Local wall-clock time for file names, without libc's localtime: reads
//! TZ / /etc/localtime (TZif, parsed with std.tz) and evaluates the POSIX
//! TZ rule that TZif files carry for times past their last transition (or
//! that TZ itself may hold, e.g. "CET-1CEST,M3.5.0,M10.5.0/3").

const std = @import("std");
const sys = @import("../platform/sys.zig");

pub const LocalTime = struct {
    year: u16,
    month: u8, // 1-12
    day: u8, // 1-31
    hour: u8,
    minute: u8,
    second: u8,
};

/// Break `utc` (epoch seconds) into local time for the zone named by
/// `tz_env` (the TZ variable; null means /etc/localtime).
pub fn localTime(alloc: std.mem.Allocator, tz_env: ?[]const u8, utc: i64) LocalTime {
    return breakDown(utc + utcOffset(alloc, tz_env, utc));
}

pub fn breakDown(t: i64) LocalTime {
    const secs: u64 = @intCast(@max(0, t));
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return .{
        .year = yd.year,
        .month = md.month.numeric(),
        .day = @as(u8, md.day_index) + 1,
        .hour = ds.getHoursIntoDay(),
        .minute = ds.getMinutesIntoHour(),
        .second = ds.getSecondsIntoMinute(),
    };
}

/// Seconds east of UTC in effect at `utc`. Falls back to 0 (UTC) when no
/// zone information can be read.
pub fn utcOffset(alloc: std.mem.Allocator, tz_env: ?[]const u8, utc: i64) i32 {
    const tz = tz_env orelse return fileOffset(alloc, "/etc/localtime", utc) orelse 0;
    if (tz.len == 0) return 0; // TZ="" means UTC
    var name = tz;
    if (name[0] == ':') name = name[1..];
    if (name.len > 0 and name[0] == '/') return fileOffset(alloc, name, utc) orelse 0;
    // a zone name, unless it climbs out of the database
    if (name.len > 0 and std.mem.indexOf(u8, name, "..") == null) {
        var buf: [512]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "/usr/share/zoneinfo/{s}", .{name})) |path| {
            if (fileOffset(alloc, path, utc)) |off| return off;
        } else |_| {}
    }
    if (Rule.parse(tz)) |rule| return rule.offsetAt(utc);
    return 0;
}

fn fileOffset(alloc: std.mem.Allocator, path: []const u8, utc: i64) ?i32 {
    const data = sys.readFileAlloc(alloc, path, 1024 * 1024) catch return null;
    defer alloc.free(data);
    return tzifOffset(alloc, data, utc);
}

/// Offset from TZif bytes: the last transition at or before `utc`, or the
/// footer rule beyond the table.
pub fn tzifOffset(alloc: std.mem.Allocator, data: []const u8, utc: i64) ?i32 {
    var reader = std.Io.Reader.fixed(data);
    var tz = std.tz.Tz.parse(alloc, &reader) catch return null;
    defer tz.deinit();

    const ts = tz.transitions;
    if (ts.len > 0 and utc >= ts[0].ts) {
        if (utc < ts[ts.len - 1].ts or tz.footer == null) {
            var lo: usize = 0;
            var hi: usize = ts.len;
            while (hi - lo > 1) {
                const mid = (lo + hi) / 2;
                if (ts[mid].ts <= utc) lo = mid else hi = mid;
            }
            return ts[lo].timetype.offset;
        }
    }
    if (tz.footer) |f| {
        if (Rule.parse(f)) |rule| return rule.offsetAt(utc);
    }
    // before the first transition: the first standard-time type
    for (tz.timetypes) |tt| if (!tt.isDst()) return tt.offset;
    if (tz.timetypes.len > 0) return tz.timetypes[0].offset;
    return null;
}

/// A POSIX TZ rule: std offset [dst [offset] [,start[/time],end[/time]]].
pub const Rule = struct {
    /// seconds east of UTC (POSIX writes them west-positive)
    std_off: i32,
    dst_off: ?i32 = null,
    start: Date = .{},
    end: Date = .{},
    start_time: i32 = 7200,
    end_time: i32 = 7200,

    pub const Date = struct {
        kind: enum { month_week_day, julian1, julian0 } = .month_week_day,
        month: u8 = 3,
        week: u8 = 2,
        wday: u8 = 0,
        day: u16 = 0,
    };

    pub fn parse(s: []const u8) ?Rule {
        var p = Parser{ .s = s };
        if (!p.name()) return null;
        const std_west = p.offset() orelse return null;
        var rule = Rule{ .std_off = -std_west };
        if (p.done()) return rule;
        if (!p.name()) return null;
        var dst_west = std_west - 3600;
        if (!p.done() and p.peek() != ',') dst_west = p.offset() orelse return null;
        rule.dst_off = -dst_west;
        if (p.done()) {
            // no rule given: the POSIX default (US rules)
            rule.start = .{ .month = 3, .week = 2, .wday = 0 };
            rule.end = .{ .month = 11, .week = 1, .wday = 0 };
            return rule;
        }
        if (!p.eat(',')) return null;
        rule.start = p.date() orelse return null;
        if (p.eat('/')) rule.start_time = p.offset() orelse return null;
        if (!p.eat(',')) return null;
        rule.end = p.date() orelse return null;
        if (p.eat('/')) rule.end_time = p.offset() orelse return null;
        if (!p.done()) return null;
        return rule;
    }

    pub fn offsetAt(self: Rule, utc: i64) i32 {
        const dst = self.dst_off orelse return self.std_off;
        const year = breakDown(utc + self.std_off).year;
        // transition instants in UTC: start is given in standard time,
        // end in daylight time
        const start = dateToDays(year, self.start) * 86400 + self.start_time - self.std_off;
        const end = dateToDays(year, self.end) * 86400 + self.end_time - dst;
        const in_dst = if (start < end)
            utc >= start and utc < end
        else // southern hemisphere: DST spans the new year
            !(utc >= end and utc < start);
        return if (in_dst) dst else self.std_off;
    }
};

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn done(p: *const Parser) bool {
        return p.i >= p.s.len;
    }
    fn peek(p: *const Parser) u8 {
        return p.s[p.i];
    }
    fn eat(p: *Parser, c: u8) bool {
        if (p.done() or p.s[p.i] != c) return false;
        p.i += 1;
        return true;
    }
    /// a zone abbreviation: 3+ letters, or <...> quoted
    fn name(p: *Parser) bool {
        if (p.eat('<')) {
            const close = std.mem.indexOfScalarPos(u8, p.s, p.i, '>') orelse return false;
            p.i = close + 1;
            return true;
        }
        const start = p.i;
        while (!p.done() and std.ascii.isAlphabetic(p.s[p.i])) p.i += 1;
        return p.i - start >= 3;
    }
    fn number(p: *Parser) ?i32 {
        const start = p.i;
        var v: i32 = 0;
        while (!p.done() and std.ascii.isDigit(p.s[p.i]) and p.i - start < 4) : (p.i += 1) {
            v = v * 10 + (p.s[p.i] - '0');
        }
        if (p.i == start) return null;
        return v;
    }
    /// [+-]hh[:mm[:ss]] in seconds
    fn offset(p: *Parser) ?i32 {
        var sign: i32 = 1;
        if (p.eat('-')) sign = -1 else _ = p.eat('+');
        const h = p.number() orelse return null;
        if (h > 167) return null;
        var secs = h * 3600;
        if (p.eat(':')) {
            secs += (p.number() orelse return null) * 60;
            if (p.eat(':')) secs += p.number() orelse return null;
        }
        return sign * secs;
    }
    fn date(p: *Parser) ?Rule.Date {
        if (p.eat('M')) {
            const m = p.number() orelse return null;
            if (!p.eat('.')) return null;
            const w = p.number() orelse return null;
            if (!p.eat('.')) return null;
            const d = p.number() orelse return null;
            if (m < 1 or m > 12 or w < 1 or w > 5 or d > 6) return null;
            return .{ .month = @intCast(m), .week = @intCast(w), .wday = @intCast(d) };
        }
        if (p.eat('J')) {
            const n = p.number() orelse return null;
            if (n < 1 or n > 365) return null;
            return .{ .kind = .julian1, .day = @intCast(n) };
        }
        const n = p.number() orelse return null;
        if (n > 365) return null;
        return .{ .kind = .julian0, .day = @intCast(n) };
    }
};

fn isLeap(y: i64) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

fn monthDays(y: i64, m: u8) u8 {
    const t = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return if (m == 2 and isLeap(y)) 29 else t[m - 1];
}

/// Days since 1970-01-01 for a civil date (proleptic Gregorian).
fn daysFromCivil(y0: i64, m: u8, d: u8) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn dateToDays(year: i64, d: Rule.Date) i64 {
    const jan1 = daysFromCivil(year, 1, 1);
    switch (d.kind) {
        .julian0 => return jan1 + d.day,
        .julian1 => {
            // 1..365, February 29 is never counted
            const skip_leap: i64 = if (isLeap(year) and d.day >= 60) 1 else 0;
            return jan1 + d.day - 1 + skip_leap;
        },
        .month_week_day => {
            const first = daysFromCivil(year, d.month, 1);
            const first_wday = @mod(first + 4, 7); // 1970-01-01 was a Thursday
            var day = @mod(@as(i64, d.wday) - first_wday + 7, 7) + 1 + (@as(i64, d.week) - 1) * 7;
            while (day > monthDays(year, d.month)) day -= 7;
            return first + day - 1;
        },
    }
}

test "POSIX TZ rules" {
    const jan = 1768478400; // 2026-01-15 12:00 UTC
    const jul = 1782907200; // 2026-07-01 12:00 UTC
    const cet = Rule.parse("CET-1CEST,M3.5.0,M10.5.0/3").?;
    try std.testing.expectEqual(@as(i32, 3600), cet.offsetAt(jan));
    try std.testing.expectEqual(@as(i32, 7200), cet.offsetAt(jul));
    // 2026-03-29 is the last Sunday of March; DST starts 01:00 UTC
    try std.testing.expectEqual(@as(i32, 3600), cet.offsetAt(1774745999));
    try std.testing.expectEqual(@as(i32, 7200), cet.offsetAt(1774746000));

    const aus = Rule.parse("AEST-10AEDT,M10.1.0,M4.1.0/3").?;
    try std.testing.expectEqual(@as(i32, 39600), aus.offsetAt(jan));
    try std.testing.expectEqual(@as(i32, 36000), aus.offsetAt(jul));

    try std.testing.expectEqual(@as(i32, 0), Rule.parse("UTC0").?.offsetAt(jul));
    try std.testing.expectEqual(@as(i32, 12600), Rule.parse("<+0330>-3:30").?.offsetAt(jul));
    try std.testing.expectEqual(@as(i32, -4 * 3600), Rule.parse("EST5EDT").?.offsetAt(jul));
    try std.testing.expect(Rule.parse("X") == null);
    try std.testing.expect(Rule.parse("CET-1CEST,M13.5.0,M10.5.0") == null);

    try std.testing.expectEqual(@as(i32, 0), utcOffset(std.testing.allocator, "", jul));
    try std.testing.expectEqual(@as(i32, 7200), utcOffset(std.testing.allocator, "CET-1CEST,M3.5.0,M10.5.0/3", jul));
}

test "TZif from the system database agrees with its rule" {
    const alloc = std.testing.allocator;
    const data = sys.readFileAlloc(alloc, "/usr/share/zoneinfo/Europe/Berlin", 1024 * 1024) catch return error.SkipZigTest;
    defer alloc.free(data);
    try std.testing.expectEqual(@as(?i32, 3600), tzifOffset(alloc, data, 1768478400));
    try std.testing.expectEqual(@as(?i32, 7200), tzifOffset(alloc, data, 1782907200));
    // far beyond any table: the footer rule decides
    try std.testing.expectEqual(@as(?i32, 7200), tzifOffset(alloc, data, 4102488000 + 182 * 86400));
    try std.testing.expectEqual(@as(i32, 7200), utcOffset(alloc, "Europe/Berlin", 1782907200));
    try std.testing.expectEqual(@as(i32, 7200), utcOffset(alloc, ":Europe/Berlin", 1782907200));
}

test "civil dates" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try std.testing.expectEqual(@as(i64, 20454), daysFromCivil(2026, 1, 1));
    const lt = breakDown(1782907200 + 7200);
    try std.testing.expectEqual(LocalTime{ .year = 2026, .month = 7, .day = 1, .hour = 14, .minute = 0, .second = 0 }, lt);
}

const weekdays = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// "Just now", "4 min ago", "Today 11:02", "Yesterday", "Wed", "Nov 3".
/// Both times are local seconds (UTC plus the zone's offset).
pub fn relTime(buf: []u8, now: i64, then: i64) []const u8 {
    const d = now - then;
    if (d < 60) return "Just now";
    if (d < 3600) return std.fmt.bufPrint(buf, "{d} min ago", .{@divFloor(d, 60)}) catch "";
    const day_now = @divFloor(now, 86400);
    const day_then = @divFloor(then, 86400);
    const lt = breakDown(then);
    if (day_now == day_then) return std.fmt.bufPrint(buf, "Today {d:0>2}:{d:0>2}", .{ lt.hour, lt.minute }) catch "";
    if (day_now - day_then == 1) return "Yesterday";
    if (day_now - day_then < 7) return weekdays[@intCast(@mod(day_then, 7))];
    return std.fmt.bufPrint(buf, "{s} {d}", .{ months[lt.month - 1], lt.day }) catch "";
}

test "relative capture times" {
    var b: [32]u8 = undefined;
    const now: i64 = 1763740953; // Fri 2025-11-21 16:02:33
    try std.testing.expectEqualStrings("Just now", relTime(&b, now, now - 5));
    try std.testing.expectEqualStrings("4 min ago", relTime(&b, now, now - 4 * 60 - 10));
    try std.testing.expectEqualStrings("Today 11:02", relTime(&b, now, now - 5 * 3600));
    try std.testing.expectEqualStrings("Yesterday", relTime(&b, now, now - 86400));
    try std.testing.expectEqualStrings("Wed", relTime(&b, now, now - 2 * 86400));
    try std.testing.expectEqualStrings("Nov 3", relTime(&b, now, now - 18 * 86400));
}

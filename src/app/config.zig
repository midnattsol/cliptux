//! Persistent configuration: simple key=value file at
//! ~/.config/cliptux/config, written atomically on change.

const std = @import("std");
const sys = @import("../platform/sys.zig");

pub const Action = enum {
    select,
    pen,
    line,
    arrow,
    rect,
    ellipse,
    highlight,
    pixelate,
    counter,
    text,
    copy,
    save,
    undo,
    redo,

    pub fn label(self: Action) []const u8 {
        return switch (self) {
            .select => "Select tool",
            .pen => "Pencil",
            .line => "Line",
            .arrow => "Arrow",
            .rect => "Rectangle",
            .ellipse => "Ellipse",
            .highlight => "Highlighter",
            .pixelate => "Pixelate",
            .counter => "Counter badge",
            .text => "Text",
            .copy => "Copy and exit",
            .save => "Save and exit",
            .undo => "Undo",
            .redo => "Redo",
        };
    }
};

pub const n_actions = @typeInfo(Action).@"enum".fields.len;

pub const Bind = struct {
    code: u32 = 0, // evdev key code; 0 = unbound
    ctrl: bool = false,
    shift: bool = false,

    pub fn matches(self: Bind, code: u32, ctrl: bool, shift: bool) bool {
        return self.code != 0 and self.code == code and self.ctrl == ctrl and self.shift == shift;
    }
};

pub const default_binds = [n_actions]Bind{
    .{ .code = 47 }, // V select
    .{ .code = 25 }, // P pen
    .{ .code = 38 }, // L line
    .{ .code = 30 }, // A arrow
    .{ .code = 19 }, // R rect
    .{ .code = 18 }, // E ellipse
    .{ .code = 35 }, // H highlight
    .{ .code = 45 }, // X pixelate
    .{ .code = 49 }, // N counter
    .{ .code = 20 }, // T text
    .{ .code = 46, .ctrl = true }, // Ctrl+C copy
    .{ .code = 31, .ctrl = true }, // Ctrl+S save
    .{ .code = 44, .ctrl = true }, // Ctrl+Z undo
    .{ .code = 44, .ctrl = true, .shift = true }, // Ctrl+Shift+Z redo
};

/// Human-readable name for an evdev key code (US-position based).
pub fn keyCodeName(code: u32) []const u8 {
    return switch (code) {
        1 => "Esc",
        2...11 => |c| ([_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" })[c - 2],
        12 => "-",
        13 => "=",
        14 => "Backspace",
        15 => "Tab",
        16...25 => |c| ([_][]const u8{ "Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P" })[c - 16],
        28 => "Enter",
        30...38 => |c| ([_][]const u8{ "A", "S", "D", "F", "G", "H", "J", "K", "L" })[c - 30],
        44...50 => |c| ([_][]const u8{ "Z", "X", "C", "V", "B", "N", "M" })[c - 44],
        51 => ",",
        52 => ".",
        53 => "/",
        57 => "Space",
        59...68 => |c| ([_][]const u8{ "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10" })[c - 59],
        87 => "F11",
        88 => "F12",
        102 => "Home",
        103 => "Up",
        104 => "PgUp",
        105 => "Left",
        106 => "Right",
        107 => "End",
        108 => "Down",
        109 => "PgDn",
        110 => "Insert",
        111 => "Delete",
        else => "key?",
    };
}

/// Format a binding like "Ctrl+Shift+Z". Returns slice of buf.
pub fn bindName(b: Bind, buf: []u8) []const u8 {
    if (b.code == 0) return "unset";
    return std.fmt.bufPrint(buf, "{s}{s}{s}", .{
        if (b.ctrl) "Ctrl+" else "",
        if (b.shift) "Shift+" else "",
        keyCodeName(b.code),
    }) catch "?";
}

pub const Config = struct {
    /// desktop notification after copy/save
    notify: bool = true,
    /// also copy to clipboard when saving to disk
    copy_on_save: bool = false,
    /// default stroke thickness (logical px, scaled by the UI)
    default_thickness: i32 = 3,
    /// default palette color index
    default_color: u3 = 0,
    /// override save directory; empty = XDG pictures dir
    save_dir: [256]u8 = @splat(0),
    save_dir_len: usize = 0,
    /// editor keybindings, indexed by Action
    binds: [n_actions]Bind = default_binds,
    /// ScreenCast restore token (silent re-capture after first consent)
    sc_token: [512]u8 = @splat(0),
    sc_token_len: usize = 0,

    pub fn saveDir(self: *const Config) ?[]const u8 {
        if (self.save_dir_len == 0) return null;
        return self.save_dir[0..self.save_dir_len];
    }

    pub fn scToken(self: *const Config) ?[]const u8 {
        if (self.sc_token_len == 0) return null;
        return self.sc_token[0..self.sc_token_len];
    }

    pub fn setScToken(self: *Config, token: []const u8) void {
        const n = @min(token.len, self.sc_token.len);
        @memcpy(self.sc_token[0..n], token[0..n]);
        self.sc_token_len = n;
    }
};

fn configPath(home: []const u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{s}/.config/cliptux/config", .{home});
}

pub fn load(alloc: std.mem.Allocator, home: []const u8) Config {
    var cfg = Config{};
    var path_buf: [512]u8 = undefined;
    const path = configPath(home, &path_buf) catch return cfg;
    const data = sys.readFileAlloc(alloc, path, 64 * 1024) catch return cfg;
    defer alloc.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq], " \t");
        const value = std.mem.trim(u8, trimmed[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "notify")) {
            cfg.notify = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "copy_on_save")) {
            cfg.copy_on_save = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "default_thickness")) {
            cfg.default_thickness = std.fmt.parseInt(i32, value, 10) catch cfg.default_thickness;
            cfg.default_thickness = std.math.clamp(cfg.default_thickness, 1, 32);
        } else if (std.mem.eql(u8, key, "default_color")) {
            const v = std.fmt.parseInt(u8, value, 10) catch 0;
            cfg.default_color = @intCast(@min(v, 7));
        } else if (std.mem.eql(u8, key, "save_dir")) {
            const n = @min(value.len, cfg.save_dir.len);
            @memcpy(cfg.save_dir[0..n], value[0..n]);
            cfg.save_dir_len = n;
        } else if (std.mem.eql(u8, key, "screencast_token")) {
            const n = @min(value.len, cfg.sc_token.len);
            @memcpy(cfg.sc_token[0..n], value[0..n]);
            cfg.sc_token_len = n;
        } else if (std.mem.startsWith(u8, key, "bind_")) {
            const name = key["bind_".len..];
            inline for (@typeInfo(Action).@"enum".fields, 0..) |fld, i| {
                if (std.mem.eql(u8, name, fld.name)) {
                    cfg.binds[i] = parseBind(value);
                }
            }
        }
    }
    return cfg;
}

fn parseBind(value: []const u8) Bind {
    var b = Bind{};
    var rest = value;
    while (true) {
        if (std.mem.startsWith(u8, rest, "ctrl+")) {
            b.ctrl = true;
            rest = rest["ctrl+".len..];
        } else if (std.mem.startsWith(u8, rest, "shift+")) {
            b.shift = true;
            rest = rest["shift+".len..];
        } else break;
    }
    b.code = std.fmt.parseInt(u32, rest, 10) catch 0;
    return b;
}

pub fn save(alloc: std.mem.Allocator, home: []const u8, cfg: *const Config) !void {
    var dir_buf: [512]u8 = undefined;
    const cfg_dir = try std.fmt.bufPrint(&dir_buf, "{s}/.config", .{home});
    sys.mkdir(cfg_dir);
    const app_dir = try std.fmt.bufPrint(&dir_buf, "{s}/.config/cliptux", .{home});
    sys.mkdir(app_dir);

    var content_list: std.ArrayList(u8) = .empty;
    defer content_list.deinit(alloc);
    const head = try std.fmt.allocPrint(alloc,
        \\# cliptux configuration
        \\notify={s}
        \\copy_on_save={s}
        \\default_thickness={d}
        \\default_color={d}
        \\save_dir={s}
        \\screencast_token={s}
        \\
    , .{
        if (cfg.notify) "true" else "false",
        if (cfg.copy_on_save) "true" else "false",
        cfg.default_thickness,
        cfg.default_color,
        cfg.saveDir() orelse "",
        cfg.scToken() orelse "",
    });
    defer alloc.free(head);
    try content_list.appendSlice(alloc, head);
    inline for (@typeInfo(Action).@"enum".fields, 0..) |fld, i| {
        const b = cfg.binds[i];
        const line = try std.fmt.allocPrint(alloc, "bind_{s}={s}{s}{d}\n", .{
            fld.name,
            if (b.ctrl) "ctrl+" else "",
            if (b.shift) "shift+" else "",
            b.code,
        });
        defer alloc.free(line);
        try content_list.appendSlice(alloc, line);
    }
    const content = content_list.items;

    var path_buf: [512]u8 = undefined;
    const path = try configPath(home, &path_buf);
    var tmp_buf: [520]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
    try sys.writeFile(tmp, content);
    try sys.rename(tmp, path);
}

test "bind parse and format roundtrip" {
    const b = parseBind("ctrl+shift+44");
    try std.testing.expect(b.ctrl and b.shift and b.code == 44);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Ctrl+Shift+Z", bindName(b, &buf));
    try std.testing.expectEqualStrings("unset", bindName(.{}, &buf));
    const plain = parseBind("25");
    try std.testing.expect(!plain.ctrl and plain.code == 25);
    // malformed input degrades to unbound, never crashes
    try std.testing.expect(parseBind("ctrl+banana").code == 0);
    try std.testing.expect(parseBind("").code == 0);
}

test "config save/load roundtrip" {
    const alloc = std.testing.allocator;
    const home = "/tmp/cliptux-test-home";
    sys.mkdir(home);
    defer {
        var buf: [256]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/.config/cliptux/config", .{home}) catch unreachable;
        sys.unlink(p) catch {};
    }

    var cfg = Config{};
    cfg.notify = false;
    cfg.copy_on_save = true;
    cfg.default_thickness = 9;
    cfg.default_color = 5;
    cfg.binds[@intFromEnum(Action.pen)] = .{ .code = 33, .ctrl = true };
    cfg.setScToken("tok-123");
    try save(alloc, home, &cfg);

    const loaded = load(alloc, home);
    try std.testing.expectEqual(false, loaded.notify);
    try std.testing.expectEqual(true, loaded.copy_on_save);
    try std.testing.expectEqual(@as(i32, 9), loaded.default_thickness);
    try std.testing.expectEqual(@as(u3, 5), loaded.default_color);
    try std.testing.expect(loaded.binds[@intFromEnum(Action.pen)].matches(33, true, false));
    try std.testing.expectEqualStrings("tok-123", loaded.scToken().?);
}

test "config roundtrip parse" {
    const alloc = std.testing.allocator;
    _ = alloc;
    var cfg = Config{};
    cfg.notify = false;
    cfg.default_thickness = 7;
    // just exercise the formatting path with a buffer
    var buf: [256]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "notify={s} t={d}", .{ if (cfg.notify) "true" else "false", cfg.default_thickness });
    try std.testing.expect(std.mem.indexOf(u8, s, "false") != null);
}

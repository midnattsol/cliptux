//! The shapes of the command table (commands.zig): what each command
//! takes, says about itself and shows in help, the man page and the
//! shell completions.

/// Every command the dispatcher runs; one table entry each.
pub const Id = enum {
    shot,
    area,
    text,
    fullscreen,
    screens,
    previous,
    window,
    scroll,
    timer,
    record,
    edit,
    pin,
    history,
    history_clear,
    settings,
    daemon,
    gnome_integration,
    gnome_status,
    gnome_install,
    gnome_uninstall,
    gnome_shortcut,
    permissions,
    permissions_reset,
    help,
    // internal: started by Shotlet itself, the GNOME extension or by hand
    // while developing
    quick,
    quick_video,
    trim,
    toast,
    test_window,
    test_grab,
    test_font,
    test_decode,
};

/// Where a command shows in the overview; `internal` ones do not.
pub const Group = enum {
    capture,
    record,
    edit_pin,
    history,
    settings,
    other,
    internal,

    pub fn title(g: Group) []const u8 {
        return switch (g) {
            .capture => "Capture",
            .record => "Record",
            .edit_pin => "Edit & pin",
            .history => "History",
            .settings => "Settings & integration",
            .other => "Other",
            .internal => "Internal",
        };
    }
};

/// What a value must look like.
pub const Kind = enum {
    string,
    file,
    /// an integer within `min`..`max`
    int,
    /// one of `choices`
    choice,
    /// X,Y,W,H in integers
    rect,
};

/// Who sees an option: everyone, developers (help lists them apart, the
/// completions leave them out) or no one (plumbing between processes).
pub const Visibility = enum { normal, dev, hidden };

pub const Option = struct {
    /// without the leading "--"
    long: []const u8,
    short: ?u8 = null,
    /// the value's placeholder ("SECONDS"); null for a flag
    value: ?[]const u8 = null,
    kind: Kind = .string,
    /// the values `choice` accepts, or the ones completions suggest
    choices: []const []const u8 = &.{},
    min: i64 = 0,
    max: i64 = 1 << 31,
    help: []const u8,
    default: ?[]const u8 = null,
    vis: Visibility = .normal,
};

/// A positional argument.
pub const Arg = struct {
    name: []const u8,
    help: []const u8,
    kind: Kind = .string,
    choices: []const []const u8 = &.{},
    min: i64 = 0,
    max: i64 = 1 << 31,
    required: bool = false,
    /// takes every remaining argument
    repeat: bool = false,
    /// accepted but not documented (plumbing)
    hidden: bool = false,
};

pub const Example = struct {
    /// the arguments after "shotlet "
    cmd: []const u8,
    what: []const u8,
};

pub const Command = struct {
    id: Id,
    name: []const u8,
    aliases: []const []const u8 = &.{},
    group: Group,
    /// one line, for the overview and the completions
    summary: []const u8,
    /// the synopsis lines, each after "shotlet "
    usage: []const []const u8,
    /// paragraphs, for the command's own help and the man page
    description: []const u8 = "",
    options: []const Option = &.{},
    args: []const Arg = &.{},
    subs: []const Command = &.{},
    examples: []const Example = &.{},
    /// its arguments go to it unchecked (internal commands keep their own
    /// parsing)
    passthrough: bool = false,

    pub fn internal(c: *const Command) bool {
        return c.group == .internal;
    }

    pub fn findOption(c: *const Command, long: []const u8) ?*const Option {
        for (c.options) |*o| if (eql(o.long, long)) return o;
        return null;
    }

    pub fn findShort(c: *const Command, short: u8) ?*const Option {
        for (c.options) |*o| if (o.short == short) return o;
        return null;
    }

    pub fn findSub(c: *const Command, name: []const u8) ?*const Command {
        for (c.subs) |*s| if (s.named(name)) return s;
        return null;
    }

    pub fn named(c: *const Command, name: []const u8) bool {
        if (eql(c.name, name)) return true;
        for (c.aliases) |a| if (eql(a, name)) return true;
        return false;
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return @import("std").mem.eql(u8, a, b);
}

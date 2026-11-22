//! Reads the command line against the command table: which command,
//! its options (`--opt value`, `--opt=value`, `-o value`, `--` ends
//! them) and arguments, checked; or help, the version, or what is wrong.

const std = @import("std");
const spec = @import("spec.zig");
const commands = @import("commands.zig");
const suggest = @import("suggest.zig");
const value_mod = @import("value.zig");
const Command = spec.Command;

/// A command and the subcommands chosen under it; empty for `shotlet`.
pub const Chain = struct {
    items: [3]*const Command = undefined,
    len: usize = 0,

    pub fn of(c: *const Command) Chain {
        var ch: Chain = .{};
        ch.push(c);
        return ch;
    }

    pub fn push(ch: *Chain, c: *const Command) void {
        ch.items[ch.len] = c;
        ch.len += 1;
    }

    pub fn leaf(ch: *const Chain) ?*const Command {
        return if (ch.len == 0) null else ch.items[ch.len - 1];
    }

    pub fn slice(ch: *const Chain) []const *const Command {
        return ch.items[0..ch.len];
    }
};

pub const Opt = struct {
    option: *const spec.Option,
    value: ?[:0]const u8,
};

pub const Parsed = struct {
    chain: Chain,
    positionals: []const [:0]const u8 = &.{},
    opts: []const Opt = &.{},
    /// the positionals, then the options as `--long [value]` in their
    /// order; a passthrough command's arguments as given
    rest: []const [:0]const u8,
    /// started as `shotlet --from-shell ...` (the GNOME extension)
    shell_launch: bool = false,

    pub fn id(p: *const Parsed) spec.Id {
        return p.chain.leaf().?.id;
    }

    pub fn flag(p: *const Parsed, long: []const u8) bool {
        for (p.opts) |o| if (std.mem.eql(u8, o.option.long, long)) return true;
        return false;
    }

    /// The option's last value.
    pub fn value(p: *const Parsed, long: []const u8) ?[:0]const u8 {
        var v: ?[:0]const u8 = null;
        for (p.opts) |o| if (std.mem.eql(u8, o.option.long, long)) {
            v = o.value;
        };
        return v;
    }
};

pub const Failure = struct {
    pub const Kind = enum { unknown_command, unknown_option, missing_value, bad_value, unexpected_value, extra_arg, missing_arg };
    kind: Kind,
    chain: Chain,
    /// the word at fault (or the missing argument's name)
    token: []const u8,
    /// the option or argument a bad value was for
    what: []const u8 = "",
    /// what a value should look like
    detail: []const u8 = "",
    suggestion: ?[]const u8 = null,
};

pub const Outcome = union(enum) {
    run: Parsed,
    overview,
    help: Chain,
    version,
    fail: Failure,
};

pub fn isHelp(a: []const u8) bool {
    return std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h");
}

const top_options = [_][]const u8{ "--help", "--version", "--daemon" };

/// `args` without the program name. Errors only when out of memory.
pub fn parse(arena: std.mem.Allocator, args: []const [:0]const u8) !Outcome {
    if (args.len == 0) return .{ .run = .{ .chain = .of(commands.default), .rest = &.{} } };
    const first = args[0];
    if (isHelp(first)) return .overview;
    if (eql(first, "--version") or eql(first, "-V")) return .version;
    if (eql(first, "help")) return helpFor(args[1..]);
    // the GNOME Shell extension: `shotlet --from-shell ID ...`
    if (eql(first, "--from-shell")) return command(arena, .of(commands.find("shot").?), args, true);
    const cmd = commands.find(first) orelse return .{ .fail = unknownTop(first) };
    return command(arena, .of(cmd), args[1..], false);
}

fn unknownTop(word: []const u8) Failure {
    if (word.len > 1 and word[0] == '-')
        return .{ .kind = .unknown_option, .chain = .{}, .token = word, .suggestion = suggest.closest(word, &top_options) };
    return .{ .kind = .unknown_command, .chain = .{}, .token = word, .suggestion = suggest.closest(word, &topNames()) };
}

/// The user-facing top-level names, for suggestions.
fn topNames() [visibleCount()][]const u8 {
    var names: [visibleCount()][]const u8 = undefined;
    var n: usize = 0;
    for (&commands.all) |*c| if (!c.internal()) {
        names[n] = c.name;
        n += 1;
    };
    return names;
}

fn visibleCount() usize {
    var n: usize = 0;
    for (&commands.all) |*c| n += @intFromBool(!c.internal());
    return n;
}

/// `shotlet help [COMMAND [SUBCOMMAND]]`
fn helpFor(words: []const [:0]const u8) Outcome {
    var chain: Chain = .{};
    for (words) |w| {
        if (isHelp(w)) return .{ .help = .of(commands.find("help").?) };
        const next = if (chain.leaf()) |c| c.findSub(w) else commands.find(w);
        const found = next orelse return .{ .fail = unknownIn(chain, w) };
        if (chain.len == chain.items.len) break;
        chain.push(found);
    }
    return if (chain.len == 0) .overview else .{ .help = chain };
}

fn unknownIn(chain: Chain, word: []const u8) Failure {
    const leaf = chain.leaf() orelse return unknownTop(word);
    var names: [8][]const u8 = undefined;
    const n = @min(names.len, leaf.subs.len);
    for (leaf.subs[0..n], 0..) |s, i| names[i] = s.name;
    return .{ .kind = .unknown_command, .chain = chain, .token = word, .suggestion = suggest.closest(word, names[0..n]) };
}

fn command(arena: std.mem.Allocator, chain: Chain, args: []const [:0]const u8, shell: bool) !Outcome {
    if (chain.leaf().?.passthrough) return .{ .run = .{ .chain = chain, .rest = args } };
    var st: State = .{ .arena = arena, .chain = chain };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (try st.token(args, &i)) |out| return out;
    }
    return st.finish(shell);
}

const State = struct {
    arena: std.mem.Allocator,
    chain: Chain,
    positionals: std.ArrayList([:0]const u8) = .empty,
    opts: std.ArrayList(Opt) = .empty,
    end_of_options: bool = false,

    fn leaf(st: *const State) *const Command {
        return st.chain.leaf().?;
    }

    fn fail(st: *const State, kind: Failure.Kind, word: []const u8) Outcome {
        return .{ .fail = .{ .kind = kind, .chain = st.chain, .token = word } };
    }

    fn token(st: *State, args: []const [:0]const u8, i: *usize) !?Outcome {
        const a = args[i.*];
        if (st.end_of_options) return st.positional(a);
        if (eql(a, "--")) {
            st.end_of_options = true;
            return null;
        }
        if (isHelp(a)) return .{ .help = st.chain };
        if (std.mem.startsWith(u8, a, "--")) return st.long(args, i);
        if (a.len > 1 and a[0] == '-') return st.short(args, i);
        return st.positional(a);
    }

    fn long(st: *State, args: []const [:0]const u8, i: *usize) !?Outcome {
        const a = args[i.*];
        const eq_at = std.mem.indexOfScalar(u8, a, '=');
        const name = a[2 .. eq_at orelse a.len];
        const opt = st.leaf().findOption(name) orelse return st.unknownOption(a[0 .. eq_at orelse a.len]);
        if (opt.value == null) {
            if (eq_at != null) return st.badOption(.unexpected_value, a[0..eq_at.?], opt);
            try st.opts.append(st.arena, .{ .option = opt, .value = null });
            return null;
        }
        const v: [:0]const u8 = if (eq_at) |at| try st.arena.dupeSentinel(u8, a[at + 1 ..], 0) else blk: {
            if (i.* + 1 >= args.len) return st.badOption(.missing_value, a, opt);
            i.* += 1;
            break :blk args[i.*];
        };
        return st.optionValue(opt, v);
    }

    fn short(st: *State, args: []const [:0]const u8, i: *usize) !?Outcome {
        const a = args[i.*];
        const opt = (if (a.len == 2) st.leaf().findShort(a[1]) else null) orelse return st.unknownOption(a);
        if (opt.value == null) {
            try st.opts.append(st.arena, .{ .option = opt, .value = null });
            return null;
        }
        if (i.* + 1 >= args.len) return st.badOption(.missing_value, a, opt);
        i.* += 1;
        return st.optionValue(opt, args[i.*]);
    }

    fn optionValue(st: *State, opt: *const spec.Option, v: [:0]const u8) !?Outcome {
        if (try value_mod.check(st.arena, opt.kind, opt.choices, opt.min, opt.max, v)) |detail| {
            var f = st.fail(.bad_value, v);
            f.fail.what = try std.fmt.allocPrint(st.arena, "--{s}", .{opt.long});
            f.fail.detail = detail;
            return f;
        }
        try st.opts.append(st.arena, .{ .option = opt, .value = v });
        return null;
    }

    fn badOption(st: *const State, kind: Failure.Kind, token_: []const u8, opt: *const spec.Option) Outcome {
        var f = st.fail(kind, token_);
        f.fail.detail = opt.value orelse "";
        return f;
    }

    fn unknownOption(st: *const State, word: []const u8) Outcome {
        var names: [24][]const u8 = undefined;
        var n: usize = 0;
        for (st.leaf().options) |o| if (o.vis != .hidden and n < names.len) {
            names[n] = std.mem.concat(st.arena, u8, &.{ "--", o.long }) catch break;
            n += 1;
        };
        var f = st.fail(.unknown_option, word);
        f.fail.suggestion = suggest.closest(word, names[0..n]);
        return f;
    }

    fn positional(st: *State, a: [:0]const u8) !?Outcome {
        const c = st.leaf();
        if (c.subs.len > 0 and st.positionals.items.len == 0 and st.opts.items.len == 0 and st.chain.len < st.chain.items.len) {
            if (c.findSub(a)) |s| {
                st.chain.push(s);
                return null;
            }
            if (c.args.len == 0) return .{ .fail = unknownIn(st.chain, a) };
        }
        const arg = argAt(c, st.positionals.items.len) orelse return st.fail(.extra_arg, a);
        if (try value_mod.check(st.arena, arg.kind, arg.choices, arg.min, arg.max, a)) |detail| {
            var f = st.fail(.bad_value, a);
            f.fail.what = arg.name;
            f.fail.detail = detail;
            return f;
        }
        try st.positionals.append(st.arena, a);
        return null;
    }

    fn finish(st: *State, shell: bool) !Outcome {
        for (st.leaf().args, 0..) |arg, i| {
            if (arg.required and i >= st.positionals.items.len) return st.fail(.missing_arg, arg.name);
        }
        var rest: std.ArrayList([:0]const u8) = .empty;
        try rest.appendSlice(st.arena, st.positionals.items);
        for (st.opts.items) |o| {
            try rest.append(st.arena, try std.fmt.allocPrintSentinel(st.arena, "--{s}", .{o.option.long}, 0));
            if (o.value) |v| try rest.append(st.arena, v);
        }
        return .{ .run = .{
            .chain = st.chain,
            .positionals = st.positionals.items,
            .opts = st.opts.items,
            .rest = rest.items,
            .shell_launch = shell,
        } };
    }
};

/// The argument spec for the `i`th positional, if one takes it.
fn argAt(c: *const Command, i: usize) ?*const spec.Arg {
    if (i < c.args.len) return &c.args[i];
    if (c.args.len > 0 and c.args[c.args.len - 1].repeat) return &c.args[c.args.len - 1];
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

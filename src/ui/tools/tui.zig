//! How the tools' controls look and read: names for scripts, labels and
//! shortcuts for tooltips and menus, icons, and their place on the
//! toolbar, the colour popover and the More menu.

const std = @import("std");
const config = @import("../../app/config.zig");
const icons = @import("../icons.zig");
const ui = @import("../editor_ui.zig");
const editor_mod = @import("../editor.zig");
const tools = @import("mod.zig");

const Editor = editor_mod.Editor;
const Ext = tools.Ext;
const Icon = icons.Icon;

/// Script names (`button NAME`).
pub fn name(e: Ext) []const u8 {
    return switch (e) {
        .aspect => |a| switch (a) {
            .free => "aspect_free",
            .square => "aspect_square",
            .wide => "aspect_wide",
            .classic => "aspect_classic",
        },
        .picked => |i| (&picked_names)[@min(i, picked_names.len - 1)],
        else => @tagName(e),
    };
}

const picked_names = [_][]const u8{ "picked0", "picked1", "picked2", "picked3", "picked4", "picked5" };

/// Where a control named `n` lives, when it is one of the tools'.
pub fn nameLayer(n: []const u8) ?ui.Layer {
    for ([_][]const u8{ "copy_text", "redact_sensitive", "pin" }) |m| if (std.mem.eql(u8, m, n)) return .menu;
    for (picked_names) |m| if (std.mem.eql(u8, m, n)) return .popover;
    return null;
}

fn actionOf(e: Ext) ?config.Action {
    return switch (e) {
        .eyedropper => .eyedropper,
        .crop => .crop,
        .copy_text => .copy_text,
        .redact_sensitive => .redact_sensitive,
        .pin => .pin,
        else => null,
    };
}

pub fn label(ed: *const Editor, e: Ext, kb: []u8) ui.Label {
    const n: []const u8, const fixed: []const u8 = switch (e) {
        .eyedropper => .{ "Colour picker", "" },
        .crop => .{ "Crop", "" },
        .copy_text => .{ "Copy text", "" },
        .redact_sensitive => .{ "Redact sensitive data", "" },
        .pin => .{ "Pin to screen", "" },
        .crop_apply => .{ "Apply crop", "Enter" },
        .crop_cancel => .{ "Cancel crop", "Esc" },
        .aspect => |a| .{ switch (a) {
            .free => "Free",
            .square => "1:1",
            .wide => "16:9",
            .classic => "4:3",
        }, "" },
        .picked => .{ "Use this colour", "" },
    };
    const key = if (actionOf(e)) |a| config.bindName(ed.binds[@backingInt(a)], kb) else fixed;
    return .{ .name = n, .key = if (std.mem.eql(u8, key, "unset")) "" else key };
}

pub fn icon(e: Ext) ?Icon {
    return switch (e) {
        .eyedropper => .eyedropper,
        .crop => .crop,
        .copy_text => .scan_text,
        .redact_sensitive => .shield,
        .pin => .pin,
        .crop_apply => .check,
        .crop_cancel => .close,
        .aspect, .picked => null,
    };
}

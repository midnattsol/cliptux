//! The command line's tests.

test {
    _ = @import("commands.zig");
    _ = @import("suggest.zig");
    _ = @import("value.zig");
    _ = @import("text.zig");
    _ = @import("errors.zig");
    _ = @import("parse_test.zig");
    _ = @import("help_test.zig");
    _ = @import("complete_test.zig");
}

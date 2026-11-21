//! Settings window: a header bar with a view switcher (General, Editor,
//! Shortcuts, Recording) over boxed-list cards, in the system's light or
//! dark look (theme.zig). Persisted to ~/.config/shotlet/config. Keyboard:
//! Tab / Shift+Tab and arrows move focus, Space / Enter activate, Esc
//! closes.
//!
//! Facade over settings/: model (views, hits, state), focus (Tab order,
//! key map), widgets (the drawing kit settings_modes.zig and
//! recui/settings_rec.zig build on), pages (each view's cards), draw (the
//! frame and header), actions (what a control does) and app (the loop).

const model = @import("settings/model.zig");
const widgets = @import("settings/widgets.zig");

pub const Hit = model.Hit;
pub const Region = model.Region;

pub const Ui = widgets.Ui;
pub const Card = widgets.Card;
pub const Row = widgets.Row;
pub const groupTitle = widgets.groupTitle;
pub const beginCard = widgets.beginCard;
pub const rowBegin = widgets.rowBegin;
pub const endCard = widgets.endCard;
pub const rowTitle = widgets.rowTitle;
pub const switchRow = widgets.switchRow;
pub const chipButton = widgets.chipButton;
pub const valueStepper = widgets.valueStepper;
pub const keyCaps = widgets.keyCaps;

pub const run = @import("settings/app.zig").run;

comptime {
    _ = @import("settings/focus.zig");
    _ = @import("settings/pages.zig");
}

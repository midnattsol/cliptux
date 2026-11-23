//! Editor chrome in the "Glass" look (theme.zig): the selection overlay,
//! one floating toolbar over a blurred copy of the screenshot, the colour
//! and size popover, the More menu, the beautify panel, the custom colour
//! picker, the magnifier loupe, tooltips, the help overlay and the copy
//! notice. Every piece has a footprint so the editor repaints only those
//! rectangles (collectOverlays must cover everything drawChrome draws).
//!
//! Facade over editor_ui/: buttons (the control model and labels),
//! toolbar_layout and popover_layout, hit (pointer and focus queries),
//! overlays (footprints), draw_chrome, selection, draw_toolbar,
//! draw_popover, material (blurred backdrop, shadow, hairline), picker,
//! loupe, tooltip, notice and strip (the capture modes before a
//! selection).

const buttons = @import("editor_ui/buttons.zig");
const pop_fade = @import("editor_ui/pop_fade.zig");
const toolbar_layout = @import("editor_ui/toolbar_layout.zig");
const popover_layout = @import("editor_ui/popover_layout.zig");
const hit = @import("editor_ui/hit.zig");
const overlays = @import("editor_ui/overlays.zig");
const draw_chrome = @import("editor_ui/draw_chrome.zig");
const selection = @import("editor_ui/selection.zig");
const draw_toolbar = @import("editor_ui/draw_toolbar.zig");
const draw_popover = @import("editor_ui/draw_popover.zig");
const material = @import("editor_ui/material.zig");
const picker = @import("editor_ui/picker.zig");
const loupe = @import("editor_ui/loupe.zig");
const loupe_hint = @import("editor_ui/loupe_hint.zig");
const tooltip = @import("editor_ui/tooltip.zig");
const notice = @import("editor_ui/notice.zig");

pub const Seg = buttons.Seg;
pub const PopClosing = pop_fade.Closing;
pub const beginPopoverClose = pop_fade.begin;
pub const ButtonKind = buttons.ButtonKind;
pub const Layer = buttons.Layer;
pub const Button = buttons.Button;
pub const Popover = buttons.Popover;
pub const Label = buttons.Label;
pub const tool_list = buttons.tool_list;
pub const buttonName = buttons.buttonName;
pub const nameLayer = buttons.nameLayer;
pub const disabledWhy = buttons.disabledWhy;

pub const Backdrop = material.Backdrop;
pub const Slot = material.Slot;
pub const n_slots = material.n_slots;
pub const shadowFootprint = material.shadowFootprint;
pub const drawMaterial = material.drawMaterial;

pub const Item = toolbar_layout.Item;
pub const layoutToolbar = toolbar_layout.layoutToolbar;

pub const moveFocus = hit.moveFocus;
pub const buttonAt = hit.buttonAt;
pub const onChrome = hit.onChrome;
pub const popoverContains = hit.popoverContains;
pub const sliderValue = hit.sliderValue;
pub const animating = hit.animating;
pub const hoverAmount = hit.hoverAmount;

pub const collectOverlays = overlays.collectOverlays;
pub const drawChrome = draw_chrome.drawChrome;
pub const drawPill = draw_chrome.drawPill;
pub const hoverHandle = selection.hoverHandle;
pub const drawSelectionChrome = selection.drawSelectionChrome;
pub const focusRing = draw_toolbar.focusRing;
pub const drawToolbar = draw_toolbar.drawToolbar;
pub const tooltipDueMs = tooltip.tooltipDueMs;

pub const PickPart = picker.PickPart;
pub const Picker = picker.Picker;
pub const pickPartAt = picker.pickPartAt;
pub const pickAt = picker.pickAt;
pub const pickerColor = picker.pickerColor;
pub const pickerFrom = picker.pickerFrom;
pub const pickerKey = picker.pickerKey;
pub const hsvToRgb = picker.hsvToRgb;
pub const rgbToHsv = picker.rgbToHsv;

pub const LoupeState = loupe.State;
pub const loupeWanted = loupe.wanted;
pub const loupeActive = loupe.active;
pub const loupeCapturing = loupe.capturing;
pub const syncLoupe = loupe.sync;
pub const loupeDueMs = loupe.dueMs;
pub const loupeColor = loupe.colorAt;
pub const loupeCopied = loupe.copied;
pub const loupePointed = loupe.pointed;
pub const loupeHeld = loupe.held;
pub const loupeEdgeDragged = loupe_hint.edgeDragged;
pub const loupeNudged = loupe.nudged;
pub const drawCopyNotice = notice.drawCopyNotice;

// keep the submodules' tests reachable from the test root
comptime {
    _ = buttons;
    _ = @import("editor_ui/strip.zig");
    _ = loupe;
    _ = @import("editor_ui/loupe_place.zig");
    _ = @import("editor_ui/loupe_hold.zig");
}

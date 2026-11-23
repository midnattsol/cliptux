# Pointer cursor scenarios of tools/e2e.sh (sourced by its inner side,
# with its helpers): the editor's cursor over a selection, while dragging
# it and over its handles. Debug builds log each cursor shown; GNOME
# draws its own through cursor-shape-v1, and SHOTLET_NO_CURSOR_SHAPE=1
# makes shotlet draw them instead, here on a monitor at 2x: drawn at
# twice the size. The shots show the pointer.
#   cursors  cursors-drawn

scenario_cursors() { cursor_checks "via cursor-shape"; }

scenario_cursors_drawn() {
    "$ROOT/tools/e2e/monitors.sh" Meta-0=2 >"$OUT/layout.txt" || fail "monitor layout"
    export SHOTLET_NO_CURSOR_SHAPE=1
    cursor_checks "drawn at 2x"
}

# cursor_checks HOW: the shapes, each logged as "cursor: KIND HOW"
# (positions in the monitor's pixels)
cursor_checks() {
    drv_ready Meta-0
    drv move 0 800 450
    run_shotlet cur
    share_dialog 0 && wait_editor 10 || { fail "editor"; exit 1; }
    check "selecting: crosshair" wait_log 3 "cursor: crosshair $1"
    drag 0 300 200 0 900 600
    drv move 0 600 400 && drv sleep 300
    check "over the selection: open hand" wait_log 3 "cursor: grab $1"
    shot 0 grab
    drv down && drv move 0 610 410 && drv move 0 620 420 && drv sleep 300
    check "dragging it: closed hand" wait_log 3 "cursor: grabbing $1"
    shot 0 grabbing
    drv up && drv sleep 300
    check "  ... open again once let go" test "$(grep -c "cursor: grab $1" "$SHOT_LOG")" -ge 2
    # moved by (20, 20): the right edge's middle and the bottom-right corner
    drv move 0 920 420 && drv sleep 300
    check "on an edge: sideways resize" wait_log 3 "cursor: resize_ew $1"
    shot 0 resize-ew
    drv move 0 920 620 && drv sleep 300
    check "on a corner: diagonal resize" wait_log 3 "cursor: resize_nwse $1"
    shot 0 resize-nwse
    keys esc
}

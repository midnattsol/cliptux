# Portal capture scenarios of tools/e2e.sh (sourced by its inner side,
# with its helpers: drv, check, share_dialog, ...): the ScreenCast portal's
# first consent and its restore token, cancelling it, several monitors
# and mixed, fractional and integer scales.
#   capture  cancel  multimon  mixed  fractional  integer

scenario_capture() {
    drv_ready Meta-0
    drv move 0 800 450
    capture_first
    capture_silent
    capture_shortcut
}

# the portal's dialog, then the editor and its copy
capture_first() {
    run_shotlet first
    check "portal dialog shown and accepted" share_dialog 0
    check "editor opened after Share" wait_editor 10
    shot 0 editor
    # the editor shows the captured desktop dimmed: not a flat colour
    drv pixel "$OUT/editor.png" 400 300; a=$VAL
    drv pixel "$OUT/editor.png" 1300 700; b=$VAL
    check "editor shows the real desktop" test "$a" != "$b"
    drag 0 200 200 0 400 350 0 600 500
    drv key enter
    sleep 0.5
    shot 0 closed
    drv pixel "$OUT/closed.png" 400 300
    check "Enter closes the editor" test "$VAL" != "$a"
    check "clipboard holds a PNG while shotlet serves it" clip_png "$OUT/clip.png"
    check "copied PNG has the selection's size" eq "$(png_size "$OUT/clip.png")" 400x300
    check "shotlet keeps serving the clipboard" alive
    check "restore token stored" grep -q screencast_restore_token "$HOME/.config/shotlet/config"
    check "registered with the portal as $APP_ID" grep -q "portal identity: $APP_ID (registry)" "$SHOT_LOG"
    check "  ... which keys the screen-cast grant" eq "$(perm_apps screencast)" "$APP_ID"
}

# the restore token: no dialog; a new copy takes the clipboard over
capture_silent() {
    first_pid=$SHOT_PID
    t0=$(date +%s%N)
    run_shotlet second
    check "second capture is silent (restore token)" wait_editor 5
    t1=$(date +%s%N)
    echo "  second capture: $(((t1 - t0) / 1000000)) ms to editor"
    drv key esc
    check "Esc with nothing to cancel quits" wait_exit 5
    check "  ... with status 0" eq "$RC" 0
    SHOT_PID=$first_pid
    check "first instance still owns the clipboard" clip_png "$OUT/clip2.png"
    # copying again hands the clipboard over; the old server exits
    run_shotlet third
    wait_editor 5
    prev=$first_pid
    drag 0 100 100 0 300 200
    drv key ctrl+c
    sleep 1
    check "Ctrl+C copies too" eq "$(clip_png "$OUT/clip3.png" && png_size "$OUT/clip3.png")" 200x100
    SHOT_PID=$prev
    check "previous clipboard server exits when replaced" wait_exit 5
}

# as a GNOME custom shortcut starts it: its own session, no terminal, no
# systemd scope; the registered identity alone must find the stored grant
# again
capture_shortcut() {
    SHOT_LOG=$OUT/shortcut.log
    setsid -f env SHOTLET_EDITOR_DUMP="$OUT/shortcut" "$BIN" </dev/null >"$SHOT_LOG" 2>&1
    check "a shortcut-style launch is silent too" wait_log 8 "startup: capture="
    sleep 0.8
    drv key esc
    sleep 1
    check "  ... with no new grant (still one, under $APP_ID)" eq "$(perm_apps screencast)" "$APP_ID"
}

scenario_cancel() {
    drv_ready Meta-0
    drv move 0 800 450
    run_shotlet cancel
    wait_button 0
    sleep 0.5
    shot 0 dialog
    drv key esc
    check "Esc in the dialog ends shotlet" wait_exit 5
    check "  ... with status 0" eq "$RC" 0
    check "  ... saying it was cancelled" grep -q "capture cancelled" "$SHOT_LOG"
    check "  ... without trying the Screenshot portal" not_grep screenshot "$SHOT_LOG"
    sleep 1
    shot 0 after
    check "no further dialog appears" no_find 0 "$accent"
    check "no restore token stored" not_grep screencast_restore_token "$HOME/.config/shotlet/config"
}

scenario_multimon() {
    drv_ready Meta-0 Meta-1
    drv move 0 800 450
    run_shotlet multi
    check "picker shows both monitors; both shared" share_dialog 0 "0 1"
    check "editor opened" wait_editor 10
    check "  ... capturing both monitors" grep -q "monitors=2" "$SHOT_LOG"
    shot 0 editor0
    shot 1 editor1
    # 1400..1800 x 300..500 in desktop coordinates: across the seam
    drag 0 1400 300 0 1599 400 1 100 450 1 200 500
    sleep 0.3
    shot 0 sel0
    shot 1 sel1
    # the "400 × 200" pill (its #f5f5f7 text) only next to the toolbar
    check "size label shown on the toolbar's monitor" drv find 0 f5f5f7 3
    check "  ... and not repeated on the other" no_find_exact 1 f5f5f7 3
    drv key enter
    sleep 1
    check "selection across both monitors is copied whole" eq "$(clip_png "$OUT/clip.png" && png_size "$OUT/clip.png")" 400x200
    check "one editor surface per monitor (first)" eq "$(png_size "$OUT/multi-frame.png")" 1600x900
    check "one editor surface per monitor (second)" eq "$(png_size "$OUT/multi-frame-1.png")" 1280x720
}

scenario_mixed() {
    # Meta-0 2560x1440 at 2 (1280x720 logical), Meta-1 1280x720 at 1
    "$ROOT/tools/e2e/monitors.sh" Meta-0=2 Meta-1=1 >"$OUT/layout.txt" || fail "monitor layout"
    drv_ready Meta-0 Meta-1
    drv move 0 1280 720
    run_shotlet mixed
    check "both monitors shared" share_dialog 0 "0 1" 2
    check "editor opened" wait_editor 10
    # the stitched image uses the sharpest density (2): the 1x monitor
    # is upscaled, so 480x300 logical across the seam is 960x600
    # (the driver addresses a monitor in its physical pixels)
    drag 0 2000 400 0 2550 700 1 100 450 1 200 500
    sleep 0.3
    shot 0 sel0
    shot 1 sel1
    drv key ctrl+c
    sleep 1
    check "mixed-scale selection exported at 2x" eq "$(clip_png "$OUT/clip.png" && png_size "$OUT/clip.png")" 960x600
    run_shotlet again
    check "a second capture needs no dialog" wait_editor 5
    echo "  warm, through the portal: $(grep -o "startup: .*" "$SHOT_LOG")"
    keys esc
}

scenario_fractional() { hidpi_scenario; }
scenario_integer() { hidpi_scenario; }
# Meta-0 2560x1440 at 1.5 (mutter's nearest: 1.4953) or 2
hidpi_scenario() {
    if [ "$scenario" = integer ]; then
        "$ROOT/tools/e2e/monitors.sh" Meta-0=2 Meta-1=1 >"$OUT/layout.txt" || fail "monitor layout"
        export SHOTLET_NO_FRACTIONAL=1 # wl_output.scale + set_buffer_scale
    else
        "$ROOT/tools/e2e/monitors.sh" Meta-0=1.5 Meta-1=1 >"$OUT/layout.txt" || fail "monitor layout"
    fi
    drv_ready Meta-0 Meta-1
    drv move 0 1280 720
    run_shotlet hidpi
    check "both monitors shared" share_dialog 0 "0 1" "$([ "$scenario" = integer ] && echo 2 || echo 1)"
    check "editor opened" wait_editor 10
    drag 0 300 300 0 900 700 0 1500 900
    sleep 0.3
    shot 0 sel
    drv key ctrl+c
    sleep 0.5
    check "selection maps 1:1 to physical pixels" eq "$(clip_png "$OUT/clip.png" && png_size "$OUT/clip.png")" 1200x600
    check "buffer covers the panel exactly" eq "$(png_size "$OUT/hidpi-frame.png")" 2560x1440
    check "the 1x monitor keeps a 1x buffer" eq "$(png_size "$OUT/hidpi-frame-1.png")" 1280x720
    # the toolbar's Copy button (the accent-filled one, wider than the
    # active tool's) copies on click
    run_shotlet close
    wait_editor 5
    drag 0 300 300 0 1500 900
    sleep 0.3
    shot 0 toolbar
    cx=
    drv find 0 "$accent_fill" 24 40 && read -r cx cy _ <<<"$VAL"
    check "toolbar Copy button found" test -n "$cx"
    click 0 "$cx" "$cy"
    sleep 1
    check "a click on a toolbar button hits it" eq "$(clip_png "$OUT/clip2.png" && png_size "$OUT/clip2.png")" 1200x600
}

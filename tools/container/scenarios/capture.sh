# Capture scenarios of the container suite (sourced by scenarios.sh, with
# lib.sh's helpers): direct capture on one and two outputs, rotated
# outputs, the ScreenCast portal and a GIF recording through it, and
# `probe` for debugging.
#   probe  capture  multimon  rotated  portal  record

scenario_probe() {
    if [ -n "${CTR_PROBE:-}" ]; then eval "$CTR_PROBE"; fi
    wayland-info >"$OUT/wayland-info.txt" 2>&1
    drv monitors; echo "monitors: $VAL"
    shot 0 probe && echo "shot: $VAL"
}

scenario_capture() {
    no_quick_cfg
    check "a window to capture is up" start_droptarget
    portal_capture first nodialog
    check "the editor opened, with no dialog" grep -q "startup: capture=" "$SHOT_LOG"
    if [ "$COMP" = kwin ]; then
        check "  ... captured directly by KWin (the installed .desktop file authorizes it)" grep -q "capture path: direct (KWin ScreenShot2)" "$SHOT_LOG"
    else
        m=$(grep -o "capture path: direct ([a-z-]*)" "$SHOT_LOG" | grep -o "([a-z-]*)")
        check "  ... captured directly ${m:-(not)}" test -n "$m"
    fi
    no_consent
    wait_exit 5
    check "Enter copied the selection" clip_png "$OUT/clip.png"
    check "  ... 400x300" eq "$(png_size "$OUT/clip.png")" 400x300
    drv pixel "$OUT/clip.png" 200 150
    # the droptarget's colour (dde7f0), as captured
    check "  ... showing the window that was on screen" eq "$VAL" ffdde7f0
}

scenario_multimon() {
    no_quick_cfg
    drv monitors; echo "  monitors: $VAL" >&2
    start_droptarget
    # the stitched picture has the highest scale of the two: on wlroots
    # (scale 1 and 2) a selection on the first output doubles
    if [ "$COMP" = kwin ]; then want1=200x150 want0=400x300; else want1=400x300 want0=800x600; fi
    run_shotlet first
    check "two outputs$([ "$COMP" = kwin ] || echo ", scale 1 and 2"): the editor opens with no dialog" wait_editor 20
    check "  ... both captured directly" grep -q "direct capture: 2 outputs" "$SHOT_LOG"
    no_consent
    check "  ... the editor covers both outputs" grep -q "editor: 2 surfaces" "$SHOT_LOG"
    select_on 1 100 100 300 250 && keys enter
    wait_exit 5
    check "  ... a selection on the second output copies its pixels ($want1)" eq "$(clip_png "$OUT/clip1.png" && png_size "$OUT/clip1.png")" "$want1"
    drv pixel "$OUT/clip1.png" 20 20; p1=$VAL
    run_shotlet second
    wait_editor 20
    select_on 0 200 200 600 500 && keys enter
    wait_exit 5
    check "  ... and one on the first output ($want0)" eq "$(clip_png "$OUT/clip0.png" && png_size "$OUT/clip0.png")" "$want0"
    drv pixel "$OUT/clip0.png" 100 100
    check "  ... each showing its own output (the app is on the first only)" test "$VAL" = ffdde7f0 -a "$p1" != ffdde7f0
}

scenario_rotated() {
    # outputs turned 90 degrees and flipped upside down: the picture
    # must come out the way each output shows it. A pin (a 300x200
    # test picture, red inside 60..240 x 40..160) sits at 134,134 of
    # each output's top-left
    no_quick_cfg
    start_droptarget
    drv mkpng "$OUT/small.png" 300 200 ff2020
    drv monitors; echo "  monitors: $VAL" >&2
    for mon in 0 1; do
        run_shotlet "pin$mon" pin "$OUT/small.png"
        wait_log 5 "pin: showing" || { fail "pin on output $mon"; return; }
        sleep 0.5
        # pins open on the focused output: move it there first
        [ "$mon" = 0 ] && { drv move 1 300 300; drv click; sleep 0.3; }
    done
    sleep 0.5
    shot 0 screen0; shot 1 screen1
    for mon in 0 1; do
        drv find "$mon" ff2020 40 20 >/dev/null 2>&1 && echo "  output $mon: red at $VAL (screenshot)" >&2
        run_shotlet "cap$mon"
        wait_editor 20 || { fail "editor"; return; }
        select_on "$mon" 220 190 340 280 && keys enter
        wait_exit 5
        clip_png "$OUT/clip$mon.png"
        drv findpng "$OUT/clip$mon.png" ff2020 40 20 >/dev/null 2>&1; r=$VAL
        drv pixel "$OUT/clip$mon.png" 60 45
        check "output $mon ($(echo $MONITORS | cut -d' ' -f$((mon + 1)))): the pin comes out where the output shows it" eq "$VAL" ffff2020
    done
}

scenario_portal() {
    # the portal when direct capture is off (wlroots: SHOTLET_NO_DIRECT)
    # or refused (KWin: Shotlet not installed, so no .desktop file)
    no_quick_cfg
    start_droptarget
    portal_capture first
    wait_exit 5
    if [ "$COMP" = kwin ]; then
        check "KWin refuses direct capture to an app it has no .desktop file for" grep -q "KWin refused" "$SHOT_LOG"
        check "  ... so the portal asks which screen (its dialog)" test "$DIALOGS" -ge 1
    else
        n1=$(wc -l <"$HOME/chooser.log" 2>/dev/null || echo 0)
        check "with direct capture off, the portal asks which output (the chooser ran)" test "$n1" -ge 1
    fi
    check "  ... the capture went through it" grep -q "capture path: portal (ScreenCast)" "$SHOT_LOG"
    check "  ... and a restore token was stored" grep -q "^screencast_restore_token=" "$XDG_CONFIG_HOME/shotlet/config"
    check "  ... Enter copied the selection" eq "$(clip_png "$OUT/clip.png" && png_size "$OUT/clip.png")" 400x300
    portal_capture second nodialog
    wait_exit 5
    check "the second capture works, with no dialog to answer" grep -q "startup: capture=" "$SHOT_LOG"
    if [ "$COMP" != kwin ]; then
        n2=$(wc -l <"$HOME/chooser.log" 2>/dev/null || echo 0)
        check "  ... silently: the restore token skipped the chooser" eq "$n2" "$n1"
    fi
}

# rec_gif NAME: a 2 s GIF of an area with the pointer moving across it
rec_gif() {
    run_shotlet "$1" record --region 100,100,320,200 --seconds 2 --no-countdown --no-control --gif
    local x
    for x in 150 200 250 300 350 300 250; do drv move 0 "$x" 180; drv sleep 200; done
    wait_exit 30
}

scenario_record() {
    # a GIF recording through xdg-desktop-portal-wlr (the image has no
    # ffmpeg): one chooser, then none (restore token); the file checked
    # byte by byte
    rec_gif rec-first
    n1=$(wc -l <"$HOME/chooser.log" 2>/dev/null || echo 0)
    check "a recording goes through the portal" grep -q "recording: source ScreenCast portal" "$SHOT_LOG"
    f=$(grep -o "recording: saved [^ ]*" "$SHOT_LOG" | cut -d' ' -f3)
    check "  ... into a GIF" eq "$(head -c 6 "$f" 2>/dev/null)" GIF89a
    check "  ... of the area's size" eq "$(od -An -tu2 -j6 -N4 "$f" | tr -s ' ')" " 320 200"
    check "  ... with several pictures" test "$(grep -c $'\x21\xf9\x04' "$f" 2>/dev/null)" -ge 2
    check "  ... after one output chooser" test "$n1" -ge 1
    rec_gif rec-second
    n2=$(wc -l <"$HOME/chooser.log" 2>/dev/null || echo 0)
    check "a second recording asks nothing (restore token)" eq "$n2" "$n1"
    check "  ... and records" grep -q "recording: saved" "$SHOT_LOG"
}

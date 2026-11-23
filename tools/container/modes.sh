# The capture modes in the container suite, sourced by scenarios.sh (its
# helpers: drv, run_shotlet, check, ...): `shotlet fullscreen` and
# `shotlet screens` copy without the editor, through direct capture;
# `shotlet window` is KWin's window picker (ScreenShot2.CaptureInteractive,
# authorized by the installed desktop entry), and on wlroots an area
# selection with a note that windows are not offered. Then the editor's
# mode strip, and a click on a window selecting it on KWin. Last,
# `shotlet scroll`: the region picker (direct capture), and with
# SHOTLET_NO_DIRECT=1 the notice that it cannot run here, exit status 1.
mkdir -p "$XDG_CONFIG_HOME/shotlet"
printf 'thumbnail=never\nafter_fullscreen=copy\nwindow_shadow=false\n' >"$XDG_CONFIG_HOME/shotlet/config"
check "a window to capture is up" start_droptarget
run_shotlet fullscreen fullscreen
check "shotlet fullscreen captures directly, with no editor" wait_log 15 "capture copied to the clipboard"
check "  ... the whole screen on the clipboard (${MW}x${MH})" eq "$(clip_png "$OUT/full.png" && png_size "$OUT/full.png")" "${MW}x${MH}"
check "  ... showing the window on screen" eval 'drv pixel "$OUT/full.png" $((MW / 2)) $((MH / 2)) && test "$VAL" = ffdde7f0'
kill "$SHOT_PID" 2>/dev/null
run_shotlet window window
if [ "$COMP" = kwin ]; then
    sleep 2
    click 0 $((MW / 2)) $((MH / 2))
    check "shotlet window: KWin's picker, a click captures the window" wait_log 15 "capture copied to the clipboard"
    check "  ... by KWin's ScreenShot2" grep -q "window capture: KWin gave" "$SHOT_LOG"
    check "  ... the window's own pixels" eval 'clip_png "$OUT/window.png" && drv pixel "$OUT/window.png" 100 100 && test "${VAL:2:6}" = dde7f0'
else
    check "shotlet window: no windows to pick on $COMP, an area instead" wait_editor 15
    check "  ... saying so" grep -q "window capture: not offered here" "$SHOT_LOG"
    keys esc
fi
kill "$SHOT_PID" 2>/dev/null
# area capture: the mode strip, and a click on a window selects it where
# the compositor says where windows are (KWin, through a one-off script)
run_shotlet area area
check "shotlet: the editor for an area" wait_editor 15
shot 0 strip
# the chosen mode: the accent's darker fill (Shotlet's default blue, or
# Breeze's on KDE, read from the portal)
check "  ... with the mode strip at the bottom (Area chosen)" eval 'find_ 0 0974df 24 20 0 $((MH - 140)) "$MW" "$MH" || find_ 0 2c7da7 24 20 0 $((MH - 140)) "$MW" "$MH"'
click 0 $((MW / 2)) $((MH / 2))
if [ "$COMP" = kwin ]; then
    check "  ... KWin said where the windows were" grep -qE "windows: [1-9][0-9]* where the capture was taken" "$SHOT_LOG"
    check "  ... a click selects the window under it" wait_log 5 "window clicked: "
    keys enter
    wsize=$(grep -o "window clicked: [0-9]*x[0-9]*" "$SHOT_LOG" | tail -1 | grep -o "[0-9]*x[0-9]*")
    sleep 1
    check "  ... and Enter copies exactly it (${wsize:-?})" eval 'clip_png "$OUT/winclick.png" && eq "$(png_size "$OUT/winclick.png")" "$wsize"'
else
    sleep 0.5
    check "  ... no windows to click on $COMP: a click selects nothing" not_log "window clicked: "
    keys esc
fi
kill "$SHOT_PID" 2>/dev/null
# a scrolling capture: direct capture here, so the region picker; with
# direct capture turned off nothing captures while the person scrolls:
# it says so before any picker, and exits 1
run_shotlet scroll scroll
check "shotlet scroll: the region picker (direct capture)" wait_log 15 "scrolling capture: pick a region"
sleep 1
keys esc
check "  ... Esc cancels it" wait_exit 10
SHOTLET_NO_DIRECT=1 run_shotlet scroll-off scroll
check "without direct capture, shotlet scroll exits 1" eval 'wait_exit 10 && { wait "$SHOT_PID"; test $? = 1; }'
check "  ... saying why on stderr" grep -qF "shotlet scroll: Scrolling capture isn’t available here. This desktop doesn’t let Shotlet capture while you scroll." "$SHOT_LOG"
check "  ... and on the screen" wait_log 10 "toast: Scrolling capture isn.t available here"
check "  ... no region picker" eval '! grep -q "pick a region" "$SHOT_LOG"'

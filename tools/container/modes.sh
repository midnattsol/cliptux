# The capture modes in the container suite, sourced by scenarios.sh (its
# helpers: drv, run_shotlet, check, ...): `shotlet fullscreen` and
# `shotlet screens` copy without the editor, through direct capture;
# `shotlet window` is KWin's window picker (ScreenShot2.CaptureInteractive,
# authorized by the installed desktop entry), and on wlroots an area
# selection with a note that windows are not offered.
mkdir -p "$XDG_CONFIG_HOME/shotlet"
printf 'quick_access=false\nafter_fullscreen=copy\nwindow_shadow=false\n' >"$XDG_CONFIG_HOME/shotlet/config"
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

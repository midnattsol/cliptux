# Why a scrolling capture stops, sourced by tools/e2e/modes.sh (its
# helpers: modes_start, mode_cfg, wait_clip, stop_fill):
#
#   modes-scroll-stops  light: a page whose wheel does nothing pauses with
#                       "didn't move" (C continues to the end); one that
#                       jumps pauses with "couldn't match" (Continue, then
#                       scrolling back lines it up and keeps what was
#                       stitched); the height limit; Esc cancels a pause
#   modes-scroll-dark   the same in the dark appearance
#
# Each state of the control is filmed into $OUT/hud-*.png (the card
# cropped out with ImageMagick when it is there).

scheme=light
[ "$scenario" = modes-scroll-dark ] && scheme=dark
ctl=$OUT/page.ctl

hud_shot() { # hud_shot NAME: the screen, and the control cropped from it
    shot 0 "hud-$1-$scheme"
    command -v convert >/dev/null &&
        convert "$OUT/hud-$1-$scheme.png" -crop 304x396+896+280 +repage "$OUT/hud-$1-$scheme-card.png" 2>/dev/null
    return 0
}
page_mode() { # page_mode MODE: the page back at the top, then misbehaving
    echo "goto 0" >"$ctl"
    sleep 0.4
    echo "$1" >"$ctl"
    sleep 0.3
}
picks=0
start_scroll() { # pick the region and start
    picks=$((picks + 1))
    drv key ctrl+super+print
    shell_wait 10 "scrolling capture: pick a region" $picks || { fail "the region picker ($picks)"; return 1; }
    sleep 2
    drag 0 300 300 0 600 500 0 900 700
    sleep 0.3
    keys enter
}
editors=0
copy_result() { # copy_result NAME: the editor opened on it; Enter copies it
    editors=$((editors + 1))
    shell_wait 10 "startup: capture=" $editors || return 1
    sleep 1
    keys enter
    wait_clip "$1" 10
}
# continue_at: the Continue button (the accent, narrower than Stop)
continue_at() {
    drv find 0 "$stop_fill" 24 40 $hud_row && read -r cx cy cw _ <<<"$VAL" && [ "$cw" -lt 120 ]
}

modes_start Meta-0
gsettings set org.gnome.desktop.interface color-scheme "$([ $scheme = dark ] && echo prefer-dark || echo default)"
mode_cfg copy
: >"$OUT/page.log"
: >"$ctl"
"$PYGTK" "$ROOT/tools/e2e/scrolltarget.py" 3000 "$ctl" >>"$OUT/page.log" 2>>"$OUT/page.err" &
for i in $(seq 1 50); do grep -q "^viewport" "$OUT/page.log" && break; sleep 0.2; done
sleep 1
vp=$(grep "^viewport" "$OUT/page.log" | tail -1 | cut -d' ' -f2)
check "a long page is up (viewport ${vp:-?} px, $scheme)" test -n "$vp"
want=$((400 + 3000 - ${vp:-0}))

# the wheel does nothing: paused, saying so; C carries on to the end
page_mode lock
start_scroll
check "a page that does not move pauses the capture" shell_wait 20 "stopped: didnt_move (The page didn" 1
sleep 0.5
hud_shot paused-didnt-move
check "  ... offering Continue beside Finish and Cancel" continue_at
: >"$ctl"
sleep 0.3
keys c
check "  ... C continues" shell_wait 5 "continuing after didnt_move" 1
check "  ... to the end of the page" shell_wait 60 "stopped: end_of_page (Reached the end of the page)" 1
sleep 0.2
hud_shot done-end
check "  ... and the editor has all of it (~$want px)" copy_result end
h=$(png_size "$OUT/end.png"); h=${h#*x}
check "  ... ${h} px tall" test "${h:-0}" -ge $((want - 2)) -a "${h:-0}" -le $((want + 2))
clear_clip
sleep 1.1

# every notch jumps two views: nothing lines up; Continue, then scrolling
# back a little lines it up, keeping what was stitched
page_mode jump
start_scroll
check "a page that jumps pauses: couldn't match" shell_wait 30 "stopped: no_match (Couldn" 1
sleep 0.5
hud_shot paused-no-match
if continue_at; then
    check "  ... Continue on the control" eval 'click 0 "$cx" "$cy" && shell_wait 5 "continuing after no_match" 1'
else
    fail "  ... Continue on the control"
fi
sleep 0.6
hud_shot realign
echo "goto 100" >"$ctl"
check "  ... scrolling back lines it up again" shell_wait 10 "lined up again" 1
check "  ... and it goes on to the end" shell_wait 60 "stopped: end_of_page" 2
check "  ... the editor has the whole page (~$want px)" copy_result jumped
h=$(png_size "$OUT/jumped.png"); h=${h#*x}
check "  ... ${h} px tall" test "${h:-0}" -ge $((want - 2)) -a "${h:-0}" -le $((want + 2))
check "  ... the marker band exactly once" eq "$(drv runs "$OUT/jumped.png" 5 ff00ff 8 && echo "$VAL")" 1
clear_clip
sleep 1.1

# the height limit (scroll_max_height=1000)
mode_cfg copy scroll_max_height=1000
page_mode ""
start_scroll
sleep 1.2
hud_shot running
check "the height limit stops it, saying so" shell_wait 30 "stopped: height_limit (Stopped at the 1" 1
sleep 0.2
hud_shot done-limit
check "  ... and the editor has 1000 px" eval 'copy_result limit && eq "$(png_size "$OUT/limit.png")" 600x1000'
clear_clip
sleep 1.1

# Esc on a pause cancels: no editor
mode_cfg copy
page_mode lock
start_scroll
shell_wait 20 "stopped: didnt_move" 2
sleep 0.3
keys esc
check "Esc on a pause cancels" shell_wait 5 "scrolling capture: cancelled" 1
sleep 2
check "  ... with no editor" eq "$(shell_count "startup: capture=")" "$editors"

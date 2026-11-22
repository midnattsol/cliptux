# The capture modes' end-to-end scenarios, sourced by tools/e2e.sh inside
# its private GNOME session (its helpers: drv, keys, drag, check, ...).
# Every one runs with the Shotlet extension, which binds a shortcut per
# mode and starts the shotlet under test (shotlet-path).
#
#   modes-screen  Ctrl+Print (the monitor under the pointer), Ctrl+Shift+
#                 Print (all screens), Shift+Super+Print (the previous
#                 area); after_fullscreen copy, thumbnail, editor, save
#   modes-timer   `shotlet timer 3`: the shell's countdown, not captured
#   modes-window  Super+Print, click a window: exactly the window, its
#                 corners transparent; with the shadow around it
#   modes-scroll  Ctrl+Super+Print on a long GTK page: scrolled and
#                 stitched to the right height, the marker once
#   modes-keys    `shotlet gnome-integration shortcut MODE KEY`

# the scrolling capture's Stop and Continue: the desktop's accent (GNOME's
# blue, 3584e4) darkened for their white labels (theme.accentFill)
stop_fill=2f76cb
# the control's bottom row (its buttons), the control right of a region
# at 300,300 600x400: away from the page in its preview
hud_row="896 600 1200 660"

mode_cfg() { # mode_cfg AFTER [KEY=VALUE...]: Shotlet's settings
    mkdir -p "$HOME/.config/shotlet"
    { printf 'thumbnail=never\nafter_fullscreen=%s\n' "$1"; shift; printf '%s\n' "$@"; } >"$HOME/.config/shotlet/config"
}
modes_start() { # the driver, the extension pointed at this shotlet
    drv_start "$@" || { fail "driver"; exit 1; }
    drv key esc
    drv move 0 800 450
    ext_gsettings set shotlet-path "'$BIN'"
    plain_desktop
    # the extension is up (its keys bound) once it owns its bus name
    local i
    for i in $(seq 1 50); do shell1_prop ModeShortcuts | grep -q "fullscreen=" && break; sleep 0.2; done
    sleep 0.5
}
# clip_size NAME: the clipboard's PNG (saved as NAME.png), WxH
clip_size() { clip_png "$OUT/$1.png" && png_size "$OUT/$1.png"; }
# wait_clip NAME SECONDS: until the clipboard holds a PNG
wait_clip() {
    local i
    for i in $(seq 1 $(($2 * 4))); do clip_png "$OUT/$1.png" && return 0; sleep 0.25; done
    return 1
}
saved_in_history() { # a history entry says it was saved to ~/Pictures
    local i
    for i in $(seq 1 20); do
        grep -lq "saved=$HOME/Pictures/shotlet-" "$XDG_STATE_HOME"/shotlet/history/*/meta 2>/dev/null && return 0
        sleep 0.25
    done
    return 1
}
clear_clip() { timeout 5 wl-copy -- "nothing" & sleep 0.5; }

case $scenario in
modes-screen)
    modes_start Meta-0 Meta-1
    mode_cfg copy
    touch "$OUT/marker"
    # the pointer on the second monitor (1280x720, right of the first)
    drv move 1 640 360
    sleep 0.3
    drv key ctrl+print
    check "Ctrl+Print captures the monitor under the pointer" wait_clip screen 10
    check "  ... all of it, and only it (1280x720)" eq "$(png_size "$OUT/screen.png")" 1280x720
    drv pixel "$OUT/screen.png" 640 400
    check "  ... the desktop's pixels" near "$VAL" "$BG"
    check "  ... with no editor" not_grep "startup: capture=" "$HL_SHELL_LOG"
    check "  ... and no consent dialog" no_dialog
    check "  ... the capture files gone" capture_dir_empty
    new_pngs | grep -v "/shotlet/history/" >"$OUT/new-pngs.txt"
    check "  ... and no PNG written but the history's" test ! -s "$OUT/new-pngs.txt"
    clear_clip
    drv move 0 800 450
    sleep 0.3
    drv key ctrl+print
    check "on the first monitor: that one (1600x900)" eval 'wait_clip screen0 10 && eq "$(png_size "$OUT/screen0.png")" 1600x900'
    clear_clip
    sleep 1.1
    drv key ctrl+shift+print
    check "Ctrl+Shift+Print captures every monitor (2880x900)" eval 'wait_clip all 10 && eq "$(png_size "$OUT/all.png")" 2880x900'
    clear_clip
    sleep 1.1
    # `shotlet fullscreen` from a terminal asks the extension too
    run_shotlet cli fullscreen
    check "shotlet fullscreen hands the capture to the extension" wait_exit 5
    check "  ... which copies the monitor" eval 'wait_clip cli 10 && eq "$(png_size "$OUT/cli.png")" 1600x900'
    clear_clip
    sleep 1.1

    # the previous area: none yet, then the last selection copied
    free_print
    drv key print
    shell_wait 10 "startup: capture=" 1
    sleep 0.8
    drag 0 300 200 0 500 300 0 700 450
    keys enter
    check "an area copied in the editor (400x250)" eval 'wait_clip area 5 && eq "$(png_size "$OUT/area.png")" 400x250'
    check "  ... is remembered for this monitor layout" test -s "$XDG_STATE_HOME/shotlet/last-area"
    clear_clip
    sleep 1.1
    drv key shift+super+print
    check "Shift+Super+Print opens the editor on it" shell_wait 10 "startup: capture=" 2
    sleep 0.8
    shot 0 previous
    keys enter
    check "  ... where Enter copies the same area" eval 'wait_clip previous 5 && eq "$(png_size "$OUT/previous.png")" 400x250'
    clear_clip
    sleep 1.1

    # after a screen capture: the editor, the area already selected
    mode_cfg editor
    drv key ctrl+print
    check "after_fullscreen=editor opens the editor" shell_wait 10 "startup: capture=" 3
    sleep 0.8
    keys enter
    check "  ... with the monitor selected" eval 'wait_clip ed 5 && eq "$(png_size "$OUT/ed.png")" 1600x900'
    sleep 1.1
    # after a screen capture: the thumbnail
    mode_cfg thumbnail
    drv key ctrl+print
    check "after_fullscreen=thumbnail shows the floating thumbnail" shell_wait 10 "quick access: showing" 1
    check "  ... and keeps the capture in the history" eval 'ls "$XDG_STATE_HOME"/shotlet/history/*/image.png >/dev/null 2>&1'
    check "  ... and copies it, like an area copied in the editor" eval 'wait_clip thumb 10 && eq "$(png_size "$OUT/thumb.png")" 1600x900'
    clear_clip
    sleep 1.1
    # after a screen capture: saved, like Save in the editor
    mode_cfg save
    drv key ctrl+print
    check "after_fullscreen=save writes the monitor to ~/Pictures" eval 'for i in $(seq 1 40); do f=$(ls "$HOME"/Pictures/shotlet-*.png 2>/dev/null | head -1); [ -n "$f" ] && break; sleep 0.25; done; eq "$(png_size "$f")" 1600x900'
    check "  ... remembering where in the history" saved_in_history
    ;;
modes-timer)
    modes_start Meta-0
    mode_cfg copy
    t0=$(date +%s%N)
    run_shotlet timer timer 3
    check "shotlet timer 3 hands it to the extension" wait_exit 5
    sleep 1
    shot 0 countdown
    check "  ... which counts down on screen" eval 'drv pixel "$OUT/countdown.png" 770 420 && ! near "$VAL" "$BG" 2>/dev/null' 
    check "  ... and then opens the editor" shell_wait 10 "startup: capture=" 1
    t1=$(date +%s%N)
    check "  ... after about 3 s ($(((t1 - t0) / 1000000)) ms)" test $(((t1 - t0) / 1000000)) -ge 3000
    sleep 0.8
    drag 0 700 350 0 900 550
    keys enter
    check "the countdown is not in the capture" eval 'wait_clip timer 5 && drv pixel "$OUT/timer.png" 100 100 && near "$VAL" "$BG"'
    ;;
modes-window)
    modes_start Meta-0
    mode_cfg copy window_shadow=false
    TARGET_SIZE=640x480 start_target || { fail "target window"; exit 1; }
    sleep 1
    drv key super+print
    check "Super+Print starts the window picker" shell_wait 10 "picking one of" 1
    drv move 0 790 440
    sleep 0.5
    shot 0 picker
    check "  ... the window under the pointer lights up" drv find 0 0a84ff 40 200
    click 0 800 450
    check "a click captures that window" wait_clip window 10
    read -r ww wh <<<"$(grep -o "captured a [0-9]*x[0-9]* window" "$HL_SHELL_LOG" | tail -1 | grep -o "[0-9]*x[0-9]*" | tr x ' ')"
    check "  ... exactly the window (${ww}x${wh})" eq "$(png_size "$OUT/window.png")" "${ww}x${wh}"
    check "  ... the size it asked for, give or take its frame" test "${ww:-0}" -ge 640 -a "${ww:-0}" -le 700
    drv pixel "$OUT/window.png" 0 0
    check "  ... its rounded corner see-through" test $((16#${VAL:0:2})) -lt 64
    drv pixel "$OUT/window.png" $((ww / 2)) $((wh / 2))
    check "  ... and its inside opaque" test "${VAL:0:2}" = ff
    check "  ... with no editor and no dialog" eval 'not_grep "startup: capture=" "$HL_SHELL_LOG" && no_dialog'
    check "  ... and no PNG left behind" capture_dir_empty
    clear_clip
    sleep 1.1
    mode_cfg copy window_shadow=true
    drv key super+print
    shell_wait 10 "picking one of" 2
    click 0 800 450
    check "with the shadow: the window on a larger transparent canvas" wait_clip shadow 10
    s=$(png_size "$OUT/shadow.png"); sw=${s%x*} sh=${s#*x}
    check "  ... (${sw}x${sh}, 56 px more each way)" eq "$sw $sh" "$((ww + 56)) $((wh + 56))"
    drv pixel "$OUT/shadow.png" 0 0
    check "  ... transparent at its corner" test "${VAL:0:2}" = 00
    drv pixel "$OUT/shadow.png" $((sw / 2)) $((sh - 20))
    check "  ... a soft shadow below the window" eval 'a=$((16#${VAL:0:2})); test $a -gt 0 -a $a -lt 255'
    sleep 1.1
    drv key super+print
    shell_wait 10 "picking one of" 3
    keys esc
    sleep 1
    check "Esc in the picker cancels" eq "$(shell_count "captured a ")" 2
    ;;
modes-scroll)
    modes_start Meta-0
    mode_cfg copy
    : >"$OUT/page.log"
    "$PYGTK" "$ROOT/tools/e2e/scrolltarget.py" 3000 >>"$OUT/page.log" 2>>"$OUT/page.err" &
    for i in $(seq 1 50); do grep -q "^viewport" "$OUT/page.log" && break; sleep 0.2; done
    sleep 1
    vp=$(grep "^viewport" "$OUT/page.log" | tail -1 | cut -d' ' -f2)
    check "a long page is up (viewport ${vp:-?} px)" test -n "$vp"
    drv key ctrl+super+print
    check "Ctrl+Super+Print opens the region picker" shell_wait 10 "scrolling capture: pick a region" 1
    sleep 2
    drag 0 300 300 0 600 500 0 900 700
    sleep 0.3
    shot 0 region
    keys enter
    check "Enter starts scrolling the region" shell_wait 10 "scrolling capture of 600x400" 1
    check "  ... the page scrolls by itself" eval 'for i in $(seq 1 50); do grep -q "^scrolled [1-9]" "$OUT/page.log" && break; sleep 0.2; done; grep -q "^scrolled [1-9]" "$OUT/page.log"'
    sleep 1
    shot 0 scrolling
    check "  ... beside the control showing it grow" drv find 0 "$stop_fill" 24 100 $hud_row
    check "it stops at the end of the page, and says so" shell_wait 60 "stopped: end_of_page (Reached the end of the page)" 1
    check "  ... and opens the tall image in the editor" shell_wait 10 "startup: capture=" 1
    check "  ... the virtual pointer gone with the session" shell_wait 5 "scrolling capture ended" 1
    sleep 1
    shot 0 editor
    drv pixel "$OUT/editor.png" 520 450
    check "  ... at full size, not shrunk to fit (600 px wide)" test "${VAL:2:6}" != 101010
    drv pixel "$OUT/editor.png" 800 450; before=$VAL
    drv move 0 800 450
    drv wheel 8
    sleep 0.8
    shot 0 editor-scrolled
    drv pixel "$OUT/editor-scrolled.png" 800 450
    check "  ... where the wheel scrolls it" test "$VAL" != "$before"
    keys enter
    check "Enter copies the stitched image" wait_clip tall 10
    s=$(png_size "$OUT/tall.png"); tw=${s%x*} th=${s#*x}
    want=$((400 + 3000 - vp))
    check "  ... ${tw}x${th}: the region's width" eq "$tw" 600
    check "  ... and the page's height through the region (~$want)" test "${th:-0}" -ge $((want - 2)) -a "${th:-0}" -le $((want + 2))
    check "  ... the marker band exactly once" eq "$(drv runs "$OUT/tall.png" 5 ff00ff 8 && echo "$VAL")" 1
    ;;
modes-scroll-manual)
    # scroll_auto=false: the person scrolls, Shotlet follows, Stop ends it
    modes_start Meta-0
    mode_cfg copy scroll_auto=false
    : >"$OUT/page.log"
    "$PYGTK" "$ROOT/tools/e2e/scrolltarget.py" 3000 "$OUT/page.ctl" >>"$OUT/page.log" 2>>"$OUT/page.err" &
    for i in $(seq 1 50); do grep -q "^viewport" "$OUT/page.log" && break; sleep 0.2; done
    sleep 1
    drv key ctrl+super+print
    shell_wait 10 "scrolling capture: pick a region" 1
    sleep 2
    drag 0 300 300 0 600 500 0 900 700
    keys enter
    check "the region is captured while the person scrolls" shell_wait 10 "the person scrolls" 1
    sleep 1
    for i in $(seq 1 10); do drv move 0 600 500; drv wheel 2; sleep 0.6; done
    check "  ... the page moved by hand" grep -q "^scrolled [1-9]" "$OUT/page.log"
    shot 0 manual-running
    # too far in one go: a warning, and scrolling back lines it up again
    at=$(grep "^scrolled" "$OUT/page.log" | tail -1 | cut -d' ' -f2)
    echo "goto 2500" >"$OUT/page.ctl"
    check "  ... a jump past what lines up warns: couldn't match" shell_wait 10 "warning: no_match (Couldn" 1
    shot 0 manual-warning
    echo "goto $((${at:-0} + 40))" >"$OUT/page.ctl"
    check "  ... scrolling back lines it up again" shell_wait 10 "lined up again" 1
    drv find 0 "$stop_fill" 24 100 $hud_row && read -r bx by _ <<<"$VAL"
    check "Stop on the control ends it" eval 'click 0 "$bx" "$by" && shell_wait 15 "startup: capture=" 1'
    check "  ... logged as the person's stop" shell_wait 2 "stopped: user_stopped" 1
    sleep 1
    keys enter
    check "  ... and the editor copies what was scrolled" wait_clip manual 10
    s=$(png_size "$OUT/manual.png"); mh=${s#*x}
    check "  ... taller than the region (${s})" test "${mh:-0}" -gt 800
    check "  ... with no part twice (the marker at most once)" test "$(drv runs "$OUT/manual.png" 5 ff00ff 8 && echo "$VAL")" -le 1
    ;;
modes-keys)
    modes_start Meta-0
    mode_cfg copy
    "$BIN" gnome-integration shortcut window '<Ctrl><Alt>w' >"$OUT/set.log" 2>&1
    check "gnome-integration shortcut window KEY sets that mode's key" eq "$(ext_gsettings get window-shortcut)" "['<Ctrl><Alt>w']"
    sleep 0.5
    drv key ctrl+alt+w
    check "  ... which starts the window picker" shell_wait 10 "picking one of" 1
    keys esc
    "$BIN" gnome-integration shortcut screens none >>"$OUT/set.log" 2>&1
    check "  ... none unbinds it" eq "$(ext_gsettings get screens-shortcut)" "@as []"
    sleep 1.1
    drv key ctrl+shift+print
    sleep 2
    check "  ... and its old key does nothing" not_grep "capture mode: 2880" "$HL_SHELL_LOG"
    # Settings: the after-capture choice, and recording a mode's key
    SHOTLET_SETTINGS_FOCUS=14 run_shotlet settings settings
    wait_log 10 "keyboard focus"
    sleep 1.2 # the window fades in and is raised by the extension
    keys space
    check "Settings cycles what a screen capture does" wait_file_line 3 "^after_fullscreen=save" "$HOME/.config/shotlet/config"
    keys esc
    wait_exit 5
    SHOTLET_SETTINGS_VIEW=shortcuts SHOTLET_SETTINGS_FOCUS=1 run_shotlet settings-keys settings
    wait_log 10 "keyboard focus"
    sleep 0.5
    keys enter
    sleep 0.3
    keys ctrl+shift+f
    sleep 1
    check "Settings records a capture mode's shortcut" eq "$(ext_gsettings get fullscreen-shortcut)" "['<Ctrl><Shift>f']"
    keys esc
    wait_exit 5
    # a mode key that GNOME's screenshot tool holds stays unbound
    ext_gsettings set fullscreen-shortcut "['<Shift>Print']"
    sleep 0.5
    "$BIN" gnome-integration shortcut >"$OUT/status.log" 2>&1
    check "a key GNOME's screenshot tool holds stays unbound (and says so)" grep -q "fullscreen.*GNOME" "$OUT/status.log"
    ;;
modes-scroll-stops | modes-scroll-dark) . "$ROOT/tools/e2e/scroll.sh" ;;
esac

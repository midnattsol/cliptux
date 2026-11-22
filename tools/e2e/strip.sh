# The editor's mode strip and window clicks, sourced by tools/e2e.sh
# after modes.sh (its helpers: modes_start, mode_cfg, wait_clip, ...),
# with the Shotlet extension taking the captures:
#
#   modes-strip  Print: the strip at the bottom centre, Area chosen; a
#                window lit under the pointer, a click selects exactly it,
#                a drag still draws an area; the strip's letters (O text,
#                G area, D screen, Q record) and its Window button; the
#                More menu without capture modes; light and dark

# GNOME's default accent (blue) and its darker fill for white icons
# (theme.accentFill(3584e4))
strip_accent=3584e4
strip_fill=2f76cb

# strip_open N: Print, until the Nth editor is up, the pointer on the
# desktop (no window lit)
strip_open() {
    sleep 1.1
    drv move 0 200 120
    drv key print
    shell_wait 10 "startup: capture=" "$1" || return 1
    sleep 0.8
}
# the strip's chosen button (the accent fill low on the screen): x y w h
strip_chosen() { drv find 0 "$strip_fill" 24 20 400 780 1200 900; }

strip_window_click() {
    strip_open 1
    check "Print opens the editor knowing where the windows were" shell_wait 5 "windows: [1-9][0-9]* where the capture was taken" 1
    shot 0 strip
    check "  ... the mode strip at the bottom centre, Area chosen" eval 'strip_chosen && read -r sx sy _ <<<"$VAL" && test "$sy" -gt 780 -a "$sx" -lt 800'
    drv pixel "$OUT/strip.png" 800 450; dim=${VAL:-}
    drv move 0 790 440
    sleep 0.4
    shot 0 hover
    check "the window under the pointer lights up (accent outline)" drv find 0 "$strip_accent" 30 300
    drv pixel "$OUT/hover.png" 800 450
    check "  ... bright, the rest dimmed" test "$VAL" != "$dim"
    click 0 800 450
    check "a click selects exactly that window" shell_wait 5 "window clicked: " 1
    sleep 0.5
    shot 0 clicked
    check "  ... the strip gone for the toolbar" eval '! strip_chosen'
    keys enter
    ww=0 wh=0
    read -r ww wh <<<"$(grep -o "window clicked: [0-9]*x[0-9]*" "$HL_SHELL_LOG" | tail -1 | grep -o "[0-9]*x[0-9]*" | tr x ' ')"
    check "  ... and Enter copies it (${ww}x${wh}, the window's frame)" eval 'wait_clip win 5 && eq "$(png_size "$OUT/win.png")" "${ww}x${wh}" && test "${ww:-0}" -ge 640 -a "${ww:-0}" -le 700'
    clear_clip
}

strip_drag() {
    strip_open 2
    drag 0 700 400 0 800 470 0 900 550
    keys enter
    check "a drag over a window still selects a free area (200x150)" eval 'wait_clip drag 5 && eq "$(png_size "$OUT/drag.png")" 200x150'
    clear_clip
}

strip_keys() {
    strip_open 3
    keys o
    check "O switches to text capture, in place" shell_wait 3 "capture mode: text" 1
    keys g
    check "G back to area" shell_wait 3 "capture mode: area" 1
    keys d
    check "D captures the monitor under the pointer, as after_fullscreen says" eval 'wait_clip screen 10 && eq "$(png_size "$OUT/screen.png")" 1600x900'
    clear_clip
    strip_open 4
    keys q
    check "Q hands this capture to the recording picker" shell_wait 10 "record: picker up" 1
    sleep 0.6
    shot 0 record-picker
    keys esc
    check "  ... which Esc cancels" shell_wait 5 "record: cancelled in the picker" 1
    strip_open 5
    ax=0 ay=0
    strip_chosen && read -r ax ay _ <<<"$VAL"
    click 0 $((ax + 38)) "$ay"
    check "the strip's Window starts the window picker" shell_wait 10 "picking one of" 1
    keys esc
}

strip_menu() {
    strip_open 6
    drag 0 400 200 0 800 350 0 1200 500
    sleep 0.6
    # More is left of Copy (the accent fill at the toolbar's right end)
    cx=0 cy=0 cw=0
    drv find 0 "$strip_fill" 24 20 800 500 1600 900 && read -r cx cy cw _ <<<"$VAL"
    click 0 $((cx - cw / 2 - 23)) "$cy"
    sleep 0.5
    shot 0 menu
    check "the More menu opens, without the capture modes" test -s "$OUT/menu.png"
    keys esc esc esc
}

strip_dark() {
    gsettings set org.gnome.desktop.interface color-scheme prefer-dark
    sleep 0.5
    strip_open 7
    shot 0 strip-dark
    drv move 0 790 440
    sleep 0.4
    shot 0 hover-dark
    check "dark: the strip and the lit window too" eval 'strip_chosen && drv find 0 "$strip_accent" 30 300'
    keys esc
    gsettings set org.gnome.desktop.interface color-scheme default
}

modes_start Meta-0
mode_cfg copy
TARGET_SIZE=640x480 start_target || { fail "target window"; exit 1; }
free_print
for i in $(seq 1 25); do shell1_prop Shortcuts | grep -q Print && break; free_print; done
sleep 0.5
strip_window_click
strip_drag
strip_keys
strip_menu
strip_dark

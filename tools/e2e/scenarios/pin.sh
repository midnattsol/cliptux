# Pin scenarios of tools/e2e.sh (sourced by its inner side, with its
# helpers): a pinned picture kept above by the GNOME extension, where it
# opens, and its menu: opacity, Copy, Lock, Annotate, Close All Pins.
#   pin

# a 300x200 red picture pinned with its centre at 500,300: the picture at
# 350..650 x 200..400, clear of the middle of the screen (where GNOME
# would put wl-paste's window, which then does not get the keyboard: it
# would be covered by a window kept above). Its menu, opened by a
# right-click at 400,250, has its top-left there (it does not fit beside the pointer: the pin grows):
# rows from 6 px down, 30 px each, separators 9 px, the opacity block
# 54 px (four 60 px segments 22 px below its top); no Keep on Top.
PIN_MENU_X=400 PIN_MENU_Y=250
pin_menu_point() { # pin_menu_point ITEM: where to click it
    local x=$((PIN_MENU_X + 128)) y
    case $1 in
    copy) y=21 ;; save) y=51 ;; annotate) y=81 ;;
    full) x=$((PIN_MENU_X + 38)); y=141 ;; half) x=$((PIN_MENU_X + 158)); y=141 ;;
    lock) y=183 ;; close) y=222 ;; close-all) y=252 ;;
    esac
    echo "$x $((PIN_MENU_Y + y))"
}

# pin_at CX CY: the red picture's centre is there (within a pixel), 1:1
pin_at() { pin_at_in "$1" "$2"; }
pin_at_in() { # pin_at_in CX CY [X0 Y0 X1 Y1]: looking only in that box
    local cx cy w h
    drv find 0 ff2020 40 20 "${@:3}" || return 1
    read -r cx cy w h <<<"$VAL"
    echo "  red picture at $VAL" >&2
    [ "${cx#-}" -ge $(($1 - 1)) ] && [ "$cx" -le $(($1 + 1)) ] && [ "$cy" -ge $(($2 - 1)) ] && [ "$cy" -le $(($2 + 1)) ] &&
        [ "$w $h" = "300 200" ]
}

scenario_pin() {
    drv_ready Meta-0
    check "another app is up" start_target
    "$PYGTK" "$ROOT/tools/e2e/mkpng.py" "$OUT/red.png" 300 200 ff2020
    pin_place
    pin_menu
    pin_opacity
    pin_copy
    pin_lock
    pin_annotate
    pin_close_all
    pin_dark_menu
}

pin_place() {
    run_shotlet pin1 pin "$OUT/red.png" --at 500,300
    check "a pin opens" wait_log 5 "pin: showing .*kept above by the GNOME extension"
    sleep 1
    shot 0 pinned
    check "  ... where it was asked to (its centre at 500,300), 1:1" pin_at 500 300
}

# pin_right_click: the menu, the pointer on the pin a moment first (as a
# hand gets there: a window that just mapped under a still pointer gets
# the pointer once it moves)
pin_right_click() {
    drv move 0 $((PIN_MENU_X + 30)) $((PIN_MENU_Y + 30))
    sleep 0.3
    click 0 "$PIN_MENU_X" "$PIN_MENU_Y" right
}

pin_menu() {
    pin_right_click
    check "right-click opens the pin's menu" wait_log 3 "pin: menu open"
    sleep 0.5
    shot 0 menu-light
    check "  ... beside the pointer, in the light material" drv find 0 f2f2f7 3 200 "$PIN_MENU_X" "$PIN_MENU_Y" $((PIN_MENU_X + 300)) $((PIN_MENU_Y + 300))
    keys esc
    check "  ... Esc closes it" wait_log 3 "pin: menu closed"
    check "  ... and only it" alive
    drv move 0 500 300
    sleep 0.3
    shot 0 hover
    click 0 603 219
    check "the ⋯ button on hover opens it too" eq "$(grep -c "pin: menu open" "$SHOT_LOG")" 2
    keys esc
    wait_log 3 "pin: menu closed"
}

pin_opacity() {
    pin_right_click
    wait_log 3 "pin: menu open" && sleep 0.4
    read -r x y <<<"$(pin_menu_point half)"
    click 0 "$x" "$y"
    check "the menu's 50% makes the pin see-through" wait_log 3 "pin: opacity 50%"
    sleep 0.5
    shot 0 half
    check "  ... the red shows half" no_find_exact 0 ff2020 40 20 300 150 700 450
    drv pixel "$OUT/half.png" 500 300
    check "  ... over what lies below" test "${VAL:2:2}" != ff
    keys 1
    check "the 1 key makes it opaque again" wait_log 3 "pin: opacity 100%"
    sleep 0.4
    check "  ... red again" drv find 0 ff2020 40 20
}

pin_copy() {
    keys ctrl+c
    check "Ctrl+C on the pin copies the picture" wait_log 3 "pin: copied"
    sleep 1
    check "  ... as a 300x200 PNG" eq "$(clip_png "$OUT/clip.png" && png_size "$OUT/clip.png")" 300x200
}

pin_lock() {
    keys ctrl+l
    check "Ctrl+L locks the pin in place" wait_log 3 "pin: locked in place"
    sleep 0.3
    n0=$(grep -c "^click" "$OUT/target.log")
    # (GNOME goes by the new input region once the pointer has been away)
    drv move 0 800 700
    sleep 0.3
    drv move 0 440 320
    sleep 0.3
    click 0 460 330
    sleep 0.5
    check "  ... clicks on it reach the app below" test "$(grep -c "^click" "$OUT/target.log")" -gt "$n0"
    check "  ... and it stays" drv find 0 ff2020 40 20
    drv move 0 631 219
    sleep 0.4
    shot 0 locked
    click 0 631 219
    check "its badge unlocks it" wait_log 3 "pin: unlocked"
}

# Annotate from the menu of a second pin, at 1250,250 (picture at
# 1100..1400 x 150..350): it steps aside while the editor (the picture in
# the middle of the screen) is up, and shows the editor's Copy
pin_annotate() {
    run_shotlet pin2 pin "$OUT/red.png" --at 1250,250
    wait_log 5 "pin: showing"
    sleep 1
    PIN_MENU_X=1150 PIN_MENU_Y=200
    pin_right_click
    wait_log 3 "pin: menu open" && sleep 0.4
    read -r x y <<<"$(pin_menu_point annotate)"
    click 0 "$x" "$y"
    check "Annotate opens the picture in the editor" wait_log 10 "edit: showing"
    sleep 1.5
    shot 0 annotating
    check "  ... the pin stepping aside" no_find_exact 0 ff2020 40 20 1050 100 1450 400
    keys enter
    check "  ... and its Copy comes back to the pin" wait_log 10 "pin: updated from the editor \(300x200\)"
    sleep 1.5
    shot 0 annotated
    check "  ... which shows again where it was" pin_at_in 1250 250 1000 50 1600 450
}

# Close All Pins from the second pin's menu closes the first one too
pin_close_all() {
    local first=$OUT/pin1.log
    pin_right_click
    wait_log 3 "pin: menu open" && sleep 0.4
    read -r x y <<<"$(pin_menu_point close-all)"
    click 0 "$x" "$y"
    check "Close All Pins closes this pin" wait_log 3 "pin: closed"
    check "  ... and the other one" wait_file_line 3 "pin: closed" "$first"
    sleep 0.5
    shot 0 all-closed
    check "  ... from the screen" no_find_exact 0 ff2020 40 20
    PIN_MENU_X=400 PIN_MENU_Y=250
}

# the menu in the dark appearance
pin_dark_menu() {
    gsettings set org.gnome.desktop.interface color-scheme prefer-dark
    run_shotlet pin3 pin "$OUT/red.png" --at 500,300
    wait_log 5 "pin: showing"
    sleep 1
    pin_right_click
    wait_log 3 "pin: menu open"
    drv move 0 $((PIN_MENU_X + 128)) $((PIN_MENU_Y + 51))
    sleep 0.5
    shot 0 menu-dark
    check "in the dark appearance the menu is dark" drv find 0 2c2c2e 3 200 "$PIN_MENU_X" "$PIN_MENU_Y" $((PIN_MENU_X + 300)) $((PIN_MENU_Y + 300))
    keys esc esc
    check "Esc closes the menu, then the pin" wait_log 3 "pin: closed"
}

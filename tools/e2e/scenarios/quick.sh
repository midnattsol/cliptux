# After-capture scenarios of tools/e2e.sh (sourced by its inner side,
# with its helpers): the floating thumbnail with and without the GNOME
# extension, Annotate, the history panel and the settings window.
#   quick  quick-plain  settings  annotate  history

# with the Shotlet GNOME Shell extension (HL_EXTENSIONS)
scenario_quick() {
    quick_cfg
    drv_ready Meta-0
    quick_shown
    quick_copy
    quick_click_through
    quick_drop_texture
    quick_drop_file
    quick_pin
}

quick_shown() {
    check "another app is up and focused" start_target
    drv move 0 800 450
    red_capture first first
    check "thumbnail process starts after Copy" wait_log 10 "quick access: showing"
    check "  ... placed by the GNOME extension" grep -q "placed by the GNOME extension" "$SHOT_LOG"
    sleep 1.5
    shot 0 thumb
    check "thumbnail shows bottom-left" drv find 0 ff453a 40 4 0 700 300 900
    check "  ... above the other app (not covered)" drv find 0 ff453a 40 4 0 700 300 900
    keys a b c
    check "the other app keeps the keyboard focus (typing reaches it)" target_said 3 "^text abc"
}

# hover: the veil and buttons; Copy
quick_copy() {
    read -r x y <<<"$(card_point 120 75)"
    drv move 0 "$x" "$y"
    sleep 0.4
    shot 0 hover
    : >"$OUT/clip-before"
    timeout 5 wl-copy -- "something else" &
    sleep 0.5
    read -r x y <<<"$(card_point 177 23)"  # Copy: the second button until saved
    click 0 "$x" "$y"
    sleep 1
    check "thumbnail Copy puts the PNG back on the clipboard" eq "$(clip_png "$OUT/clip.png" && png_size "$OUT/clip.png")" 500x300
    shot 0 copied
}

# a click beside the card (its transparent margin) reaches the app
quick_click_through() {
    : >"$OUT/target.clicks"
    n0=$(grep -c "^click" "$OUT/target.log")
    click 0 16 884
    sleep 0.5
    check "a click beside the thumbnail reaches the window below" test "$(grep -c "^click" "$OUT/target.log")" -gt "$n0"
    click 0 800 300
    sleep 0.8
    shot 0 after-click
    check "  ... and the thumbnail stays above it" drv find 0 ff453a 40 4 0 700 300 900
}

# drag out into the app
quick_drop_texture() {
    drag_card_out
    check "dragging the thumbnail drops the image into a GTK app" target_said 5 "^drop texture 500 300"
    check "  ... and the thumbnail goes away" any_log 5 "quick access: dropped"
    sleep 0.5
    shot 0 dropped
    check "  ... from the screen" no_find_exact 0 ff453a 40 4 0 700 300 900
}

# as a file: an app that asks for text/uri-list
quick_drop_file() {
    check "a drop target for files is up" start_droptarget text/uri-list
    n=$(shown_count)
    red_capture third
    new_card "$n"
    drag_card_out
    check "  ... and as a file (text/uri-list)" drop_said 5 "^drop text/uri-list [0-9]+ file:///"
    f=$(grep -o "file://[^ ]*" "$OUT/drop.log" | head -1 | sed 's|^file://||')
    check "  ... naming a PNG named after the capture time" eq "$(png_size "$f")" 500x300
    # only the one started above: the path is also in this script's argv
    kill "$DROP_PID" 2>/dev/null
}

# pin: a second capture, pinned
quick_pin() {
    n=$(shown_count)
    red_capture second
    new_card "$n"
    read -r x y <<<"$(card_point 120 75)"
    drv move 0 "$x" "$y"
    sleep 0.3
    read -r x y <<<"$(card_point $((240 - 21)) $((150 - 21)))"
    click 0 "$x" "$y"
    check "Pin opens a pinned window" any_log 5 "pin: showing"
    sleep 1
    shot 0 pinned
    click 0 1500 100
    sleep 0.8
    shot 0 pinned-after-click
    check "  ... that stays above after clicking the app" drv find 0 ff453a 40 4
}

scenario_quick_plain() {
    # no extension: the thumbnail is an ordinary window, still usable
    quick_cfg
    drv_ready Meta-0
    start_target
    drv move 0 800 450
    red_capture plain first
    check "thumbnail shown without the extension" wait_log 10 "quick access: showing .*plain window"
    sleep 1.5
    shot 0 thumb
    check "  ... somewhere on screen" drv find 0 ff453a 40 4
    check "  ... with the integration hint" grep -q "no Shotlet GNOME Shell extension" "$SHOT_LOG"
    keys ctrl+c
    sleep 1
    check "  ... and its Ctrl+C copies" eq "$(clip_png "$OUT/clip.png" && png_size "$OUT/clip.png")" 500x300
    keys esc
    check "Esc closes it" wait_log 5 "quick access: closed"
}

# open_settings N KEY...: the settings window with its N-th control
# focused, KEYs pressed on it, closed with Esc
open_settings() {
    local n=$1; shift
    SHOTLET_SETTINGS_FOCUS=$n SHOTLET_DUMP_FRAME=$OUT/settings-$n run_shotlet "settings-$n" settings
    sleep 2
    keys "$@"
    sleep 0.5
    keys esc
    wait_exit 5
}
# the quick-access, history and GNOME integration settings, from the
# keyboard (SHOTLET_SETTINGS_FOCUS=n focuses the n-th control: 3 Reset
# permissions (4 while a token is stored: 3 is Choose again), 4 magnifier
# choice, 5 thumbnail choice, 7 seconds +, 13 Clear history, 15 Enable)
scenario_settings() {
    drv_ready Meta-0
    cfgf=$HOME/.config/shotlet/config
    settings_reset
    printf 'loupe=auto\n' >>"$cfgf"
    open_settings 4
    check "an older magnifier choice is written as while holding Ctrl" grep -q "^loupe=hold" "$cfgf"
    open_settings 4 space
    check "the magnifier choice goes to always" grep -q "^loupe=always" "$cfgf"
    open_settings 5 space
    check "the thumbnail choice goes to after Copy and Save" grep -q "^thumbnail=after_copy_and_save" "$cfgf"
    open_settings 7 enter
    check "  ... and + makes it stay longer" grep -q "^quick_access_seconds=10" "$cfgf"
    mkdir -p "$HOME/.local/state/shotlet/history/1795280000000-0000abcd"
    open_settings 13 enter
    check "Clear history asks first" test -e "$HOME/.local/state/shotlet/history/1795280000000-0000abcd"
    open_settings 13 enter enter
    check "  ... and a second press empties it" test ! -e "$HOME/.local/state/shotlet/history/1795280000000-0000abcd"
    open_settings 15 enter
    check "Enable installs the GNOME Shell extension" test -f "$HOME/.local/share/gnome-shell/extensions/shotlet@midnattsol.github.io/extension.js"
    check "  ... enabled for the next login" eval "gsettings get org.gnome.shell enabled-extensions | grep -q shotlet@midnattsol.github.io"
    settings_snapped
}

# Maximized, then tiled, the window is square and edge to edge (its
# corners are its own background); floating again, it is back on the
# desktop at its size
settings_snapped() {
    run_shotlet settings-snap settings
    sleep 2
    keys super+up
    sleep 1.5
    shot 0 settings-max
    check "maximized Settings reaches the screen's corners" same_px settings-max 0 899 300 899
    check "  ... both bottom ones" same_px settings-max 1599 899 300 899
    keys super+left
    sleep 1.5
    shot 0 settings-tiled
    check "tiled left, it fills its half to the corner" same_px settings-tiled 0 899 40 899
    keys super+down
    sleep 1.5
    shot 0 settings-floating
    check "  ... and floats again on the desktop" eval '! same_px settings-floating 0 899 460 500 2>/dev/null'
    check "  ... at its size" same_px settings-floating 460 500 1140 500
    keys esc
    wait_exit 5
}
same_px() { # same_px SHOT X0 Y0 X1 Y1: two pixels of a screenshot match
    local a
    drv pixel "$OUT/$1.png" "$2" "$3" || return 1
    a=$VAL
    drv pixel "$OUT/$1.png" "$4" "$5" || return 1
    [ "$a" = "$VAL" ] || { echo "  $a is not $VAL" >&2; return 1; }
}

# Reset permissions: Shotlet's grant and token go, another app's stays
settings_reset() {
    mkdir -p "$HOME/.config/shotlet"
    printf 'screencast_restore_token=e2e-token\nnotify=true\n' >>"$cfgf"
    perm SetPermission screencast true e2e-ours "$APP_ID" "['yes']" >/dev/null
    perm SetPermission screencast true e2e-other org.example.Other "['yes']" >/dev/null
    perm SetPermission screencast true e2e-anon "" "['yes']" >/dev/null
    open_settings 4 enter
    check "Reset permissions forgets the restore token" not_grep "screencast_restore_token=e2e" "$cfgf"
    check "  ... keeping the other settings" grep -q "^notify=true" "$cfgf"
    check "  ... removes Shotlet's screen-cast grant" eq "$(perm Lookup screencast e2e-ours)" ""
    check "  ... and leaves other apps' alone" eq "$(perm_apps screencast | tr '\n' ' ')" " org.example.Other "
    check "  ... saying so" grep -q "permissions reset from Settings: Forgot the screens and 1 permission" "$OUT/settings-4.log"
}

scenario_annotate() {
    # Annotate on the thumbnail reopens the editor with the shapes
    # still editable; its Copy updates the same capture
    quick_cfg
    drv_ready Meta-0
    start_target
    drv move 0 800 450
    red_capture first first
    check "thumbnail shown" wait_log 10 "quick access: showing"
    sleep 1
    clip_png "$OUT/orig.png"
    drv pixel "$OUT/orig.png" 150 140
    check "the copy has the red rectangle" test "${VAL:2:6}" = ff453a
    read -r x y <<<"$(card_point 120 75)"
    drv move 0 "$x" "$y"
    sleep 0.3
    read -r x y <<<"$(card_point 187 129)"
    click 0 "$x" "$y"
    check "Annotate reopens the editor" any_log 10 "editing [0-9a-f-]+ again"
    sleep 1.5
    shot 0 reopened
    # the 500x300 capture sits centred: the rectangle at 650..800, 400..480
    check "  ... with the previous annotations" drv find 0 ff453a 40 4 600 350 1000 550
    keys v
    click 0 725 440
    drv sleep 200
    keys delete
    sleep 0.3
    shot 0 deleted
    check "  ... which can be selected and deleted" no_find_exact 0 ff453a 40 4 600 350 1000 550
    keys enter
    sleep 1.5
    clip_png "$OUT/edited.png"
    check "  ... and Copy gives the edited image" eq "$(png_size "$OUT/edited.png")" 500x300
    drv pixel "$OUT/edited.png" 150 140
    check "  ... without the rectangle" test "${VAL:2:6}" != ff453a
    n=$(ls "$HOME/.local/state/shotlet/history" | wc -l)
    check "  ... updating the same history entry" eq "$n" 1
}

scenario_history() {
    quick_cfg
    drv_ready Meta-0
    drv move 0 800 450
    history_kept
    history_panel
    history_restart
}

# a copied and a saved capture
history_kept() {
    red_capture one first
    wait_log 10 "quick access: showing"
    sleep 0.5
    n=$(shown_count)
    run_shotlet two
    wait_editor 10
    drag 0 100 100 0 300 250
    keys ctrl+s
    new_card "$n"
    n=$(ls "$HOME/.local/state/shotlet/history" | wc -l)
    check "copied and saved captures are kept" eq "$n" 2
    grep -l "saved=" "$HOME"/.local/state/shotlet/history/*/meta >/dev/null
    check "  ... the saved one with its path" test $? = 0
}

# the Recent captures panel: Enter copies, Delete removes
history_panel() {
    pkill -f "shotlet quick" 2>/dev/null
    SHOTLET_DUMP_FRAME=$OUT/panel run_shotlet panel history
    check "Recent captures lists both" wait_log 5 "history: 2 captures"
    check "  ... search on, or shown disabled without Tesseract" wait_log 5 "text search off|text search on"
    sleep 1
    shot 0 panel
    keys tab
    sleep 0.2
    shot 0 picked
    keys enter
    sleep 0.5
    check "Enter copies the picked capture" wait_log 5 "history: copied"
    check "  ... as a PNG" clip_png "$OUT/hclip.png"
    keys delete
    check "Delete removes it" wait_log 5 "history: deleted"
    sleep 0.3
    shot 0 after-delete
    keys esc esc
    wait_exit 5
}

# the panel's Clear history (in the footer, away from close) asks first:
# Esc backs out, Clear clears
history_clear_asks() {
    local hist=$HOME/.local/state/shotlet/history
    # the panel: its light or dark card, the biggest blob of its colour
    drv find 0 fafafc 3 200 || drv find 0 242426 3 200 || { fail "the history panel on screen"; return; }
    read -r cx cy w h <<<"$VAL"
    local bottom=$((cy + h / 2)) right=$((cx + w / 2))
    click 0 "$cx" $((bottom - 22))
    check "Clear history asks first" wait_log 3 "history: asking before clearing 1 captures"
    shot 0 clear-asks
    check "  ... keeping the captures meanwhile" eq "$(ls "$hist" | wc -l)" 1
    keys esc
    check "  ... Esc backs out" wait_log 3 "history: clearing cancelled"
    check "  ... leaving the panel open" alive
    click 0 "$cx" $((bottom - 22))
    click 0 $((right - 44)) $((bottom - 22))
    check "  ... and its Clear clears" wait_log 3 "history: cleared"
    check "  ... every capture" eq "$(ls "$hist" 2>/dev/null | wc -l)" 0
}

history_restart() {
    pkill -f "shotlet (quick|history|pin)" 2>/dev/null
    sleep 0.5
    run_shotlet again history
    check "the history survives a restart" wait_log 5 "history: 1 captures"
    sleep 1
    history_clear_asks
    keys esc esc
    wait_exit 5
    "$BIN" history clear >/dev/null 2>&1
    run_shotlet cleared history
    check "history clear empties it" wait_log 5 "history: 0 captures"
    keys esc
    wait_exit 5
}

# Desktop helpers of tools/e2e.sh's inner side (sourced after lib.sh):
# the GNOME integration, the desktop, other apps and the thumbnail.

# --- the GNOME integration's captures: the shell starts shotlet, whose
# output lands in the compositor log
shell_count() { grep -c "$1" "$HL_SHELL_LOG" 2>/dev/null; }
shell_wait() { # shell_wait SECONDS PATTERN COUNT: until PATTERN shows COUNT times
    local i
    for i in $(seq 1 $(($1 * 50))); do
        [ "$(shell_count "$2")" -ge "$3" ] && return 0
        sleep 0.02
    done
    return 1
}
ext_gsettings() { # ext_gsettings get|set KEY [VALUE]: the extension's settings
    gsettings --schemadir "$XDG_DATA_HOME/gnome-shell/extensions/shotlet@midnattsol.github.io/schemas" \
        "$1" org.gnome.shell.extensions.shotlet "${@:2}"
}
shell1_prop() {
    gdbus call --session --dest dev.shotlet.Shell1 --object-path /dev/shotlet/Shell1 \
        --method org.freedesktop.DBus.Properties.Get dev.shotlet.Shell1 "$1" 2>/dev/null
}
# every file written since $OUT/marker under HOME, the runtime dir,
# /dev/shm and right in /tmp (other tools' trees below /tmp are not
# ours) that is a PNG: the capture must never be one of them
new_pngs() {
    { find "$HOME" "$XDG_RUNTIME_DIR" /dev/shm -xdev -newer "$OUT/marker" -type f -user "$(id -u)" 2>/dev/null
      find /tmp -maxdepth 1 -newer "$OUT/marker" -type f -user "$(id -u)" 2>/dev/null; } |
        while read -r f; do
            [ "$(head -c 8 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ] && echo "$f"
        done
}
no_dialog() { # the portal's consent dialogs never came up
    eq "$(perm_apps screencast)$(perm_apps screenshot)" "" &&
        ! grep -qiE "screencast|screenshot portal" "$HL_SHELL_LOG" "$OUT"/*.log 2>/dev/null
}
capture_dir_empty() { [ -z "$(ls -A "$XDG_RUNTIME_DIR/shotlet" 2>/dev/null)" ]; }
# a plain blue desktop: known content to find in the capture
BG=2a5db0
plain_desktop() {
    gsettings set org.gnome.desktop.background picture-uri ''
    gsettings set org.gnome.desktop.background picture-uri-dark ''
    gsettings set org.gnome.desktop.background picture-options none
    gsettings set org.gnome.desktop.background color-shading-type solid
    gsettings set org.gnome.desktop.background primary-color "#$BG"
}
near() { # near AARRGGBB RRGGBB: within 6 per channel
    local a=${1:2:6} b=$2 i
    for i in 0 2 4; do
        local d=$((16#${a:$i:2} - 16#${b:$i:2}))
        [ ${d#-} -le 6 ] || { echo "  $a is not $b" >&2; return 1; }
    done
}
# the extension's key: GNOME's screenshot UI holds Print by default, so
# the extension leaves it alone; tests give Print to the extension
free_print() {
    gsettings set org.gnome.shell.keybindings show-screenshot-ui "[]"
    sleep 0.5
}

# --- another app: a maximized GTK window reporting focus, typing,
# clicks and drops (tools/e2e/target.py) on $OUT/target.log
TGT_PID=
start_target() { # start_target [MIME...]
    local i
    : >"$OUT/target.log"
    env ${TGT_DEBUG:+WAYLAND_DEBUG=client} "$PYGTK" "$ROOT/tools/e2e/target.py" "$@" >>"$OUT/target.log" 2>>"$OUT/target.err" &
    TGT_PID=$!
    for i in $(seq 1 50); do grep -q "^active True" "$OUT/target.log" && return 0; sleep 0.2; done
    return 1
}
# a window taking drops (tools/e2e/droptarget.zig) on $OUT/drop.log
start_droptarget() { # start_droptarget [MIME...]
    local i
    : >"$OUT/drop.log"
    "$E2E_DROPTARGET" "$@" >>"$OUT/drop.log" 2>>"$OUT/drop.err" &
    DROP_PID=$!
    for i in $(seq 1 50); do grep -q "^ready" "$OUT/drop.log" && { sleep 0.8; return 0; }; sleep 0.2; done
    return 1
}
drop_said() { # drop_said SECONDS PATTERN
    local i
    for i in $(seq 1 $(($1 * 10))); do
        grep -qE "$2" "$OUT/drop.log" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}
target_said() { # target_said SECONDS PATTERN
    local i
    for i in $(seq 1 $(($1 * 10))); do
        grep -qE "$2" "$OUT/target.log" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}
# the thumbnail stack's newest card: bottom-left, 32 px from the
# edges, 240x150 (8 px window gap + 28 px shadow margin; monitor 0 is 1600x900, no bottom panel)
CARD_X0=36 CARD_Y1=864
card_point() { # card_point DX DY: a point DX right, DY up from the card's bottom-left
    echo "$((CARD_X0 + $1)) $((CARD_Y1 - $2))"
}
# drag the newest card out by hand, up and over to the middle of monitor 0
drag_card_out() {
    read -r x y <<<"$(card_point 120 75)"
    slow_drag 0 "$x" "$y" $((x + 40)) $((y - 40)) 400 500 600 400 800 300
}
# a capture with a red filled rectangle in it, copied with Enter
red_capture() { # red_capture NAME [first]
    run_shotlet "$1"
    if [ "${2:-}" = first ]; then share_dialog 0 || return 1; fi
    wait_editor 10 || return 1
    drag 0 400 200 0 700 400 0 900 500
    keys r f
    drag 0 500 300 0 650 380 0 800 420
    sleep 0.3
    keys enter
}
quick_cfg() { # settings for the quick-access scenarios
    mkdir -p "$HOME/.config/shotlet"
    printf 'quick_access_seconds=600\nthumbnail=after_copy_and_save\n' >>"$HOME/.config/shotlet/config"
}

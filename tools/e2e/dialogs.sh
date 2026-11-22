# Portal dialog helpers for tools/e2e.sh (sourced by its inner side).

# --- portal dialogs (xdg-desktop-portal-gnome), found by colour
accent=3584e4 # Adwaita's accent: default buttons, checkboxes
# the editor's fills under white text: that accent darkened for contrast
# (theme.accentFill)
accent_fill=2f76cb
# wait_button MON [SECONDS]: wait for an accent-coloured button (at
# least 40 px wide) on MON; its centre lands in BX, BY
wait_button() {
    local i w h
    BX=
    for i in $(seq 1 $((${2:-10} * 5))); do
        # a button, not a selected monitor tile's frame (tall)
        if drv find "$1" "$accent" 24 40 2>/dev/null; then
            read -r BX BY w h <<<"$VAL"
            [ "$h" -le 100 ] && return 0
        fi
        sleep 0.2
    done
    echo "  no dialog button on monitor $1" >&2
    return 1
}
# wait_chooser MON: the editor's Copy button wears a shade of the accent,
# so first let the editor close, then wait for the dialog's button
wait_chooser() {
    local i
    for i in $(seq 1 25); do
        drv find "$1" "$accent" 24 40 2>/dev/null || break
        sleep 0.2
    done
    wait_button "$@"
}
# press_button MON: click the button until its dialog goes away
press_button() {
    local try
    for try in 1 2 3; do
        click "$1" "$BX" "$BY"
        sleep 1
        drv find "$1" "$accent" 24 40 2>/dev/null || return 0
        local h
        read -r BX BY _ h <<<"$VAL"
        [ "$h" -le 100 ] || return 0
    done
    return 1
}
# share_dialog MON [TILES [SCALE]]: on the ScreenCast picker, tick the
# monitor TILES (0 1: for multi-monitor pickers, where nothing is
# preselected and Share starts disabled), then press Share
share_dialog() {
    local mon=$1 tiles=${2:-} sc=${3:-1} t cx cy
    if [ -n "$tiles" ]; then
        # Share is disabled: the first accent blob is the "Remember"
        # checkbox; the tiles sit below it
        local i
        for i in $(seq 1 50); do drv find "$mon" "$accent" 24 10 2>/dev/null && break; sleep 0.2; done
        [ -n "$VAL" ] || return 1
        sleep 0.5
        drv find "$mon" "$accent" 24 10 || return 1
        read -r cx cy _ <<<"$VAL"
        for t in $tiles; do
            case $t in
                0) click "$mon" $((cx - 42 * sc)) $((cy + 193 * sc)) ;;
                1) click "$mon" $((cx + 240 * sc)) $((cy + 173 * sc)) ;;
            esac || return 1
        done
    fi
    wait_button "$mon" || return 1
    sleep 0.5 # let the dialog finish mapping before clicking
    shot "$mon" dialog
    press_button "$mon"
}

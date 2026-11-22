# The editor's open and close with GNOME's window animations on, without
# the extension (which skips them) and with it: filmed frame by frame
# (shotlet-drive's film and cut), every frame must be the desktop, the
# editor or a cross-fade of the two. A ghost is any other frame: mutter
# zooming or shrinking the editor's frozen picture of the desktop over
# the live one, or the top bar gone while nothing covers its place.
#   blink  blink-ext
# Env: BLINK_FRAMES=1 keeps every filmed frame as PNG under $OUT (not
# only those of a cut with a ghost).

# film_cut NAME: stop filming; the verdict in $VAL ("frames N ghosts G
# ...", echoed); the frames stay under $OUT/NAME when it found a ghost
film_cut() {
    local dir=$OUT/$1
    mkdir -p "$dir"
    drv cut "$dir"
    echo "  $1: $VAL"
    [ -z "${BLINK_FRAMES:-}" ] && [ "$(ghosts)" = 0 ] && rm -rf "$dir"
}
ghosts() { local v=$VAL; v=${v#*ghosts }; echo "${v%% *}"; }

# blink_round NAME SELECT KEY...: open the editor filmed, select an
# area when SELECT is 1, then close it with KEY
blink_round() {
    local name=$1 select=$2; shift 2
    drv move 0 800 450
    drv sleep 300
    drv film 0 || return 1
    run_shotlet "$name"
    wait_editor 10 || { fail "$name: the editor did not open"; return 1; }
    sleep 0.4
    film_cut "$name-open"
    BLINK_OPEN=$(ghosts)
    [ "$select" = 1 ] && drag 0 300 200 0 600 400 0 900 600
    sleep 0.6
    drv film 0 || return 1
    keys "$@"
    sleep 1
    film_cut "$name-close"
    BLINK_CLOSE=$(ghosts)
}

# the first capture asks for consent: not filmed
blink_consent() {
    gsettings set org.gnome.desktop.interface enable-animations true
    drv_ready Meta-0
    sleep 1.5
    run_shotlet consent
    share_dialog 0 || { fail "the share dialog"; return 1; }
    wait_editor 10 && keys esc
    wait_exit 5
    sleep 1
}

# Without the extension mutter zooms the editor in as it maps it (the
# open is reported, not checked: see vanish.zig); its close shows a
# clear last frame, so the shrinking effect has nothing to show.
scenario_blink() {
    blink_consent || return
    blink_round esc 0 esc
    echo "  open without the extension: $BLINK_OPEN ghost frames (mutter's map zoom)"
    check "Esc: the editor closes without ghost frames ($BLINK_CLOSE)" test "$BLINK_CLOSE" = 0
    check "  ... and quits" wait_exit 5
    blink_round copy 1 enter
    check "Copy: the editor closes without ghost frames ($BLINK_CLOSE)" test "$BLINK_CLOSE" = 0
    check "  ... and copies" clip_png "$OUT/clip.png"
}

# With the extension, which skips mutter's effects for the editor: the
# open too
scenario_blink_ext() {
    blink_consent || return
    blink_round esc 0 esc
    check "Esc: the editor opens without ghost frames ($BLINK_OPEN)" test "$BLINK_OPEN" = 0
    check "  ... and closes without them ($BLINK_CLOSE)" test "$BLINK_CLOSE" = 0
    blink_round copy 1 enter
    check "Copy: the editor closes without ghost frames ($BLINK_CLOSE)" test "$BLINK_CLOSE" = 0
}

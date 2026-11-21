#!/bin/bash
# End-to-end tests: real shotlet, real portals, real PipeWire, driven by a
# virtual keyboard and pointer, inside a private headless GNOME session
# (tools/e2e/session.sh). Nothing touches the desktop you are logged into.
#
# usage: tools/e2e.sh [SHOTLET DRIVE] [SCENARIO...]
#        zig build e2e [-- SCENARIO...]
# SHOTLET/DRIVE default to zig-out/bin/shotlet and zig-out/bin/shotlet-drive
# (zig build e2e-driver). Scenarios: see `scenarios` below; default all.
# Prints PASS/FAIL/SKIP per check; exits 1 when anything failed. Skips
# (exit 0) when gnome-shell, PipeWire or the portals are not installed.
# Env: E2E_OUT=dir keeps logs and screenshots there (default: a temp dir,
#      removed when everything passed).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)

scenarios="capture cancel multimon mixed fractional integer keyboard clipboard saveas daemon fallback ime quick quick-plain annotate history settings shell shell-owner shell-mixed shell-tray shell-terminal modes-screen modes-timer modes-window modes-scroll modes-scroll-manual modes-keys"

# ---------------------------------------------------------------- inner side
if [ "${1:-}" = "--inner" ]; then
    scenario=$2
    BIN=$E2E_BIN DRIVE=$E2E_DRIVE OUT=$E2E_OUT/$scenario
    mkdir -p "$OUT"
    cd "$HOME"
    failed=0
    pass() { echo "PASS $scenario: $*"; }
    fail() { echo "FAIL $scenario: $*"; failed=1; }
    skip() { echo "SKIP $scenario: $*"; }
    check() { # check DESCRIPTION COMMAND...
        local what=$1; shift
        if "$@"; then pass "$what"; else fail "$what"; fi
    }

    # --- the input driver, as a coprocess (mutter ends its session on exit)
    DRV_PID=
    drv_start() {
        coproc DRV { "$DRIVE" "$@" 2>>"$OUT/drive.log"; }
        DRV_PID=$DRV_PID
        local ans
        read -r -t 20 ans <&"${DRV[0]}" || ans="err no answer"
        [ "$ans" = "ok ready" ] || { echo "driver: $ans" >&2; return 1; }
    }
    # drv CMD...: run one driver command; its value lands in $VAL
    VAL=
    drv() {
        local ans
        echo "$*" >&"${DRV[1]}"
        read -r -t 30 ans <&"${DRV[0]}" || ans="err no answer"
        echo "> $* -> $ans" >>"$OUT/drive.log"
        case $ans in
            ok*) VAL=${ans#ok}; VAL=${VAL# }; return 0 ;;
            *) VAL=; echo "driver: $* -> $ans" >&2; return 1 ;;
        esac
    }
    drv_stop() { drv quit >/dev/null 2>&1; wait "$DRV_PID" 2>/dev/null; }
    keys() { local k; for k in "$@"; do drv key "$k" || return 1; done; }
    click() { drv move "$1" "$2" "$3" && drv sleep 120 && drv click "${4:-left}"; }
    drag() { # drag MON X0 Y0 [MON] X1 Y1 ...: press, visit each point, release
        local mon=$1
        drv move "$mon" "$2" "$3" && drv sleep 100 && drv down || return 1
        shift 3
        while [ $# -ge 3 ]; do drv move "$1" "$2" "$3" || return 1; shift 3; done
        drv sleep 100 && drv up
    }
    shot() { drv shot "$1" "$OUT/$2.png" >/dev/null; }
    slow_drag() { # slow_drag MON X0 Y0 X1 Y1 ...: like a hand, a pause per point
        local mon=$1
        # mutter only gives a window that just moved under a still pointer
        # the pointer on the next motion: arrive in two steps
        drv move "$mon" $(($2 - 4)) "$3" && drv sleep 150 &&
            drv move "$mon" "$2" "$3" && drv sleep 150 && drv down || return 1
        shift 3
        while [ $# -ge 2 ]; do drv move "$mon" "$1" "$2" && drv sleep 200 || return 1; shift 2; done
        drv sleep 300 && drv up
    }
    shown_count() { cat "$OUT"/*.log 2>/dev/null | grep -cE "quick access: (showing|added)"; }
    # new_card N: wait until more than N thumbnails were shown in all
    new_card() {
        local i
        for i in $(seq 1 100); do [ "$(shown_count)" -gt "$1" ] && { sleep 1; return 0; }; sleep 0.1; done
        return 1
    }
    any_log() { # any_log SECONDS PATTERN: in any shotlet log of this scenario
        local i
        for i in $(seq 1 $(($1 * 10))); do
            grep -qE "$2" "$OUT"/*.log 2>/dev/null && return 0
            sleep 0.1
        done
        return 1
    }

    # --- shotlet
    SHOT_PID=
    run_shotlet() { # run_shotlet NAME ARGS...: start in the background
        local name=$1; shift
        SHOT_LOG=$OUT/$name.log
        SHOTLET_EDITOR_DUMP=$OUT/$name "$BIN" "$@" >"$SHOT_LOG" 2>&1 &
        SHOT_PID=$!
    }
    alive() { kill -0 "$SHOT_PID" 2>/dev/null; }
    wait_exit() { # wait_exit SECONDS: true when shotlet exited; status in $RC
        local i
        for i in $(seq 1 $(($1 * 10))); do
            alive || { wait "$SHOT_PID"; RC=$?; return 0; }
            sleep 0.1
        done
        RC=; return 1
    }
    wait_log() { # wait_log SECONDS PATTERN
        local i
        for i in $(seq 1 $(($1 * 10))); do
            grep -qE "$2" "$SHOT_LOG" 2>/dev/null && return 0
            sleep 0.1
        done
        return 1
    }
    # the editor is up once every surface has keyboard or pointer input
    wait_editor() { wait_log "${1:-10}" "startup: capture=" && sleep 0.8; }
    stop_shotlet() { alive && kill "$SHOT_PID" 2>/dev/null; wait "$SHOT_PID" 2>/dev/null; }
    png_size() { drv png "$1" && echo "$VAL"; }
    clip_png() { # clip_png FILE: the clipboard's image/png into FILE
        timeout 5 wl-paste -n -t image/png >"$1" 2>/dev/null &&
            [ "$(head -c 8 "$1" | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ]
    }
    not_grep() { ! grep -q "$1" "$2" 2>/dev/null; }
    no_find_exact() { ! drv find "$@" 2>/dev/null; }
    no_find() { ! drv find "$1" "$2" 24 10 2>/dev/null; }
    gdbus_owner() {
        gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
            --method org.freedesktop.DBus.NameHasOwner "$1" 2>/dev/null | grep -q true
    }
    sni() { # sni METHOD ARGS...: call the daemon's StatusNotifierItem
        local m=$1; shift
        gdbus call --session --dest io.github.midnattsol.Shotlet --object-path /StatusNotifierItem \
            --method "org.kde.StatusNotifierItem.$m" "$@" >/dev/null
    }
    eq() { [ "$1" = "$2" ] || { echo "  expected '$2', got '$1'" >&2; return 1; }; }
    # the identity xdg-desktop-portal stores consent under (no test hook:
    # shotlet registers it through org.freedesktop.host.portal.Registry)
    APP_ID=io.github.midnattsol.Shotlet
    perm() { # perm METHOD ARGS...: call the portal permission store
        local m=$1; shift
        gdbus call --session --dest org.freedesktop.impl.portal.PermissionStore \
            --object-path /org/freedesktop/impl/portal/PermissionStore \
            --method "org.freedesktop.impl.portal.PermissionStore.$m" "$@" 2>/dev/null
    }
    # perm_apps TABLE: every app id with an entry in TABLE, one per line
    perm_apps() {
        local id
        for id in $(perm List "$1" | grep -o "'[^']*'" | tr -d "'"); do
            perm Lookup "$1" "$id" | tee -a "$OUT/permissions.txt" | grep -o "'[^']*': \[" | sed "s/': \[//; s/^'//"
        done | sort -u
    }

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

    # --- portal dialogs (xdg-desktop-portal-gnome), found by colour
    accent=3584e4 # Adwaita's accent: default buttons, checkboxes
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
    # wait_chooser MON: the editor's Copy button wears the accent too, so
    # first let the editor close, then wait for the dialog's button
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
        printf 'quick_access_seconds=600\n' >>"$HOME/.config/shotlet/config"
    }

    case $scenario in
    capture | cancel | multimon | mixed | fractional | integer | keyboard | clipboard | saveas | daemon | fallback | ime | shell*)
        # these check what happens without the floating thumbnail
        mkdir -p "$HOME/.config/shotlet"
        printf 'quick_access=false\n' >"$HOME/.config/shotlet/config"
        ;;
    esac

    case $scenario in
    quick | annotate | history)
        # these load the extension for the floating windows but follow
        # shotlet started here: its captures go through the portal (the
        # extension cannot start this shotlet: Capture() is refused)
        ext_gsettings set shotlet-path "'/nonexistent/shotlet'"
        ;;
    esac

    case $scenario in
    quick)
        # with the Shotlet GNOME Shell extension (HL_EXTENSIONS)
        quick_cfg
        drv_start Meta-0 || { fail "driver"; exit 1; }
        drv key esc
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
        # hover: the veil and buttons; Copy
        read -r x y <<<"$(card_point 120 75)"
        drv move 0 "$x" "$y"
        sleep 0.4
        shot 0 hover
        : >"$OUT/clip-before"
        timeout 5 wl-copy -- "something else" &
        sleep 0.5
        read -r x y <<<"$(card_point 60 23)"
        click 0 "$x" "$y"
        sleep 1
        check "thumbnail Copy puts the PNG back on the clipboard" eq "$(clip_png "$OUT/clip.png" && png_size "$OUT/clip.png")" 500x300
        shot 0 copied
        # a click beside the card (its transparent margin) reaches the app
        : >"$OUT/target.clicks"
        n0=$(grep -c "^click" "$OUT/target.log")
        click 0 16 884
        sleep 0.5
        check "a click beside the thumbnail reaches the window below" test "$(grep -c "^click" "$OUT/target.log")" -gt "$n0"
        click 0 800 300
        sleep 0.8
        shot 0 after-click
        check "  ... and the thumbnail stays above it" drv find 0 ff453a 40 4 0 700 300 900
        # drag out into the app
        read -r x y <<<"$(card_point 120 75)"
        slow_drag 0 "$x" "$y" $((x + 40)) $((y - 40)) 400 500 600 400 800 300
        check "dragging the thumbnail drops the image into a GTK app" target_said 5 "^drop texture 500 300"
        check "  ... and the thumbnail goes away" any_log 5 "quick access: dropped"
        sleep 0.5
        shot 0 dropped
        check "  ... from the screen" no_find_exact 0 ff453a 40 4 0 700 300 900
        # as a file: an app that asks for text/uri-list
        check "a drop target for files is up" start_droptarget text/uri-list
        n=$(shown_count)
        red_capture third
        new_card "$n"
        read -r x y <<<"$(card_point 120 75)"
        slow_drag 0 "$x" "$y" $((x + 40)) $((y - 40)) 400 500 600 400 800 300
        check "  ... and as a file (text/uri-list)" drop_said 5 "^drop text/uri-list [0-9]+ file:///"
        f=$(grep -o "file://[^ ]*" "$OUT/drop.log" | head -1 | sed 's|^file://||')
        check "  ... naming a PNG named after the capture time" eq "$(png_size "$f")" 500x300
        # only the one started above: the path is also in this script's argv
        kill "$DROP_PID" 2>/dev/null

        # pin: a second capture, pinned
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
        ;;
    shell)
        # stock GNOME: Print opens GNOME's screenshot tool. install offers
        # Print to Shotlet (GNOME's tool moves to Shift+Super+S), the key
        # then captures without any prompt, uninstall restores it all
        drv_start Meta-0 || { fail "driver"; exit 1; }
        drv key esc
        drv move 0 800 450
        plain_desktop
        check "the extension leaves GNOME's Print alone" shell_wait 5 "Print is GNOME's screenshot shortcut" 1
        shell1_prop BlockedShortcuts >"$OUT/blocked.txt"
        check "  ... and says so on the bus" grep -q "Print" "$OUT/blocked.txt"
        dump_keys() { for k in show-screenshot-ui screenshot screenshot-window show-screen-recording-ui; do
            echo "$k $(gsettings get org.gnome.shell.keybindings $k) [$(dconf read /org/gnome/shell/keybindings/$k)]"; done; }
        dump_keys >"$OUT/keys-before.txt"
        "$BIN" gnome-integration install </dev/null >"$OUT/install.log" 2>&1
        check "install gives Print to Shotlet" grep -q "Print now captures with Shotlet" "$OUT/install.log"
        check "  ... moving GNOME's screenshot tool to Shift+Super+S" eq "$(gsettings get org.gnome.shell.keybindings show-screenshot-ui)" "['<Shift><Super>s']"
        check "  ... and no other GNOME shortcut" eq "$(gsettings get org.gnome.shell.keybindings screenshot) $(gsettings get org.gnome.shell.keybindings screenshot-window)" "['<Shift>Print'] ['<Alt>Print']"
        check "  ... the extension binds Print" eval 'shell1_prop Shortcuts | grep -q Print'
        check "  ... pointing it at this shotlet" eq "$(ext_gsettings get shotlet-path)" "'$BIN'"
        "$BIN" gnome-integration status >"$OUT/status.log" 2>&1
        check "status: captures through the integration" grep -q "capture: through the GNOME integration (no prompts)" "$OUT/status.log"
        # the capture
        touch "$OUT/marker"
        sleep 1
        t0=$(date +%s%N)
        drv key print
        check "Print opens Shotlet's editor" shell_wait 10 "startup: capture=" 1
        t1=$(date +%s%N)
        echo "  key to editor (measured outside): $(((t1 - t0) / 1000000)) ms; shotlet says: $(grep -o "key press to editor [0-9]*ms.*" "$HL_SHELL_LOG" | tail -1)"
        sleep 0.8
        shot 0 editor
        check "  ... without any consent dialog" no_dialog
        check "  ... or dialog button on screen" no_find 0 "$accent"
        check "  ... the capture file is gone once read" capture_dir_empty
        check "  ... and no capture was written anywhere else" eq "$(new_pngs)" ""
        check "  ... the capture directory is private" eq "$(stat -c %a "$XDG_RUNTIME_DIR/shotlet")" 700
        drv pixel "$OUT/editor.png" 800 600
        check "  ... the editor shows the desktop (dimmed blue)" test "${VAL:2:6}" != "$BG"
        drag 0 400 300 0 600 400 0 800 500
        keys enter
        sleep 1
        check "Copy gives the selection" eq "$(clip_png "$OUT/clip.png" && png_size "$OUT/clip.png")" 400x200
        drv pixel "$OUT/clip.png" 200 100
        check "  ... with the desktop's pixels, not the cursor or a dim" near "$VAL" "$BG"
        # anyone else asking over the bus is refused
        gdbus call --session --dest dev.shotlet.Shell1 --object-path /dev/shotlet/Shell1 \
            --method dev.shotlet.Shell1.Capture >"$OUT/gdbus.txt" 2>&1
        check "Capture() from another program is refused" grep -q "AccessDenied" "$OUT/gdbus.txt"
        sleep 1
        check "  ... and takes no screenshot" eq "$(shell_count "startup: capture=")" 1
        check "  ... nor leaves a file" capture_dir_empty
        "$BIN" gnome-integration uninstall >"$OUT/uninstall.log" 2>&1
        dump_keys >"$OUT/keys-after.txt"
        check "uninstall gives GNOME its screenshot keys back exactly" cmp -s "$OUT/keys-before.txt" "$OUT/keys-after.txt"
        check "  ... and the extension is gone" test ! -e "$XDG_DATA_HOME/gnome-shell/extensions/shotlet@midnattsol.github.io"
        ;;
    shell-owner)
        # GNOME's screenshot tool off Print and a custom shortcut running
        # shotlet on Print: install moves that shortcut to the extension
        drv_start Meta-0 || { fail "driver"; exit 1; }
        drv key esc
        drv move 0 800 450
        gsettings set org.gnome.shell.keybindings show-screenshot-ui "[]"
        CK=/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/
        CKS=org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$CK
        gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "['$CK']"
        gsettings set "$CKS" name 'Shotlet'
        gsettings set "$CKS" command "$BIN"
        gsettings set "$CKS" binding 'Print'
        dump() { dconf dump /org/gnome/settings-daemon/plugins/media-keys/; dconf dump /org/gnome/shell/keybindings/; }
        dump >"$OUT/before.txt"
        "$BIN" gnome-integration install </dev/null >"$OUT/install.log" 2>&1
        check "install moves the custom shortcut running shotlet" grep -q "Moved" "$OUT/install.log"
        check "  ... off GNOME's custom shortcuts" eq "$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings)" "@as []"
        check "  ... to the extension's key" eq "$(ext_gsettings get capture-shortcut)" "['Print']"
        check "  ... which it binds" eval 'shell1_prop Shortcuts | grep -q Print'
        check "  ... leaving GNOME's shortcuts alone" eq "$(gsettings get org.gnome.shell.keybindings show-screenshot-ui)" "@as []"
        drv key print
        check "Print opens Shotlet's editor" shell_wait 10 "startup: capture=" 1
        check "  ... without any consent dialog" no_dialog
        sleep 0.8
        keys esc
        "$BIN" gnome-integration uninstall >"$OUT/uninstall.log" 2>&1
        dump >"$OUT/after.txt"
        check "uninstall puts the custom shortcut back exactly" cmp -s "$OUT/before.txt" "$OUT/after.txt"
        ;;
    shell-mixed)
        # Meta-0 2560x1440 at 2 (1280x720 logical), Meta-1 1280x720 at 1:
        # the shell paints the stage at 2, Shotlet maps both monitors on it
        plain_desktop
        "$ROOT/tools/e2e/monitors.sh" Meta-0=2 Meta-1=1 >"$OUT/layout.txt" || fail "monitor layout"
        drv_start Meta-0 Meta-1 || { fail "driver"; exit 1; }
        drv key esc
        drv move 0 1280 720
        free_print
        touch "$OUT/marker"
        drv key print
        check "Print opens the editor on both monitors" shell_wait 10 "startup: capture=" 1
        check "  ... capturing both" grep -q "monitors=2 through the GNOME integration" "$HL_SHELL_LOG"
        echo "  $(grep -o "key press to editor [0-9]*ms.*" "$HL_SHELL_LOG" | tail -1)"
        sleep 0.8
        shot 0 editor0
        shot 1 editor1
        check "  ... with no consent dialog" no_dialog
        check "  ... the capture file is gone" capture_dir_empty
        check "  ... nothing written elsewhere" eq "$(new_pngs)" ""
        # 480x300 logical across the seam, from the top: monitor 0's top
        # bar (it is the primary) on the left, plain desktop on the right
        drag 0 2000 0 0 2550 300 1 100 450 1 200 300
        sleep 0.3
        shot 0 sel0
        keys ctrl+c
        sleep 1
        check "the selection is exported at 2x" eq "$(clip_png "$OUT/clip.png" && png_size "$OUT/clip.png")" 960x600
        drv pixel "$OUT/clip.png" 100 8
        check "  ... the 2x monitor's top bar on the left" test "${VAL:2:6}" != "$BG"
        drv pixel "$OUT/clip.png" 100 300
        check "  ... the desktop below it" near "$VAL" "$BG"
        drv pixel "$OUT/clip.png" 800 8
        check "  ... the 1x monitor (no top bar) on the right" near "$VAL" "$BG"
        drv pixel "$OUT/clip.png" 559 8; a=$VAL
        drv pixel "$OUT/clip.png" 561 8; b=$VAL
        check "  ... meeting at the seam (x=560)" eval 'test "${a:2:6}" != "$BG" && near "$b" "$BG"'
        # once more, everything warm (the portal running, as in a session)
        sleep 1
        drv key print
        check "a second Print captures too" shell_wait 10 "startup: capture=" 2
        echo "  warm: $(grep -o "key press to editor [0-9]*ms.*" "$HL_SHELL_LOG" | tail -1)"
        sleep 0.8
        keys esc
        ;;
    shell-tray)
        # the tray's Take screenshot asks the extension (Capture()), which
        # takes the shot and starts the editor; no prompt, no child capture
        drv_start Meta-0 || { fail "driver"; exit 1; }
        drv key esc
        drv move 0 800 450
        run_shotlet daemon --daemon -f
        sleep 1
        ext_gsettings set shotlet-path "'$BIN'"
        sni Activate 0 0
        check "tray Activate captures through the extension" shell_wait 10 "startup: capture=" 1
        check "  ... with no consent dialog" no_dialog
        sleep 0.8
        keys esc
        sleep 1.2
        gdbus call --session --dest io.github.midnattsol.Shotlet --object-path /MenuBar \
            --method com.canonical.dbusmenu.Event 1 clicked "<0>" 0 >/dev/null 2>&1
        check "  ... and so does the menu's Take screenshot" shell_wait 10 "startup: capture=" 2
        sleep 0.8
        keys esc
        sleep 1.2
        # rate limit: two asks at once give one capture
        sni Activate 0 0
        sni Activate 0 0
        sleep 3
        check "two asks at once start one capture" eq "$(shell_count "startup: capture=")" 3
        check "  ... the other one declined" grep -q "Error.Busy" "$SHOT_LOG"
        check "  ... and no portal capture child" not_grep "screencast" "$SHOT_LOG"
        keys esc
        check "the daemon keeps running" alive
        ;;
    shell-terminal)
        # `shotlet` from a terminal asks the extension too
        drv_start Meta-0 || { fail "driver"; exit 1; }
        drv key esc
        drv move 0 800 450
        ext_gsettings set shotlet-path "'$BIN'"
        t0=$(date +%s%N)
        run_shotlet term
        check "shotlet hands the capture to the extension" wait_exit 5
        check "  ... and exits with status 0" eq "$RC" 0
        check "  ... saying so" grep -q "capture handed to the GNOME integration" "$SHOT_LOG"
        check "the extension's shotlet opens the editor" shell_wait 10 "startup: capture=" 1
        t1=$(date +%s%N)
        echo "  launch to editor: $(((t1 - t0) / 1000000)) ms"
        check "  ... with no consent dialog" no_dialog
        sleep 0.8
        keys esc
        # an older or broken integration: the portal path as before
        ext_gsettings set shotlet-path "'/nonexistent/shotlet'"
        sleep 1.2
        run_shotlet portal
        check "if the extension cannot capture, the portal asks" share_dialog 0
        check "  ... and the editor opens" wait_editor 10
        keys esc
        ;;
    quick-plain)
        # no extension: the thumbnail is an ordinary window, still usable
        quick_cfg
        drv_start Meta-0 || { fail "driver"; exit 1; }
        drv key esc
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
        ;;
    settings)
        # the quick-access, history and GNOME integration settings, from
        # the keyboard (SHOTLET_SETTINGS_FOCUS=n focuses the n-th control:
        # 3 thumbnail switch, 5 seconds +, 11 Clear history, 13 Enable)
        drv_start Meta-0 || { fail "driver"; exit 1; }
        drv key esc
        cfgf=$HOME/.config/shotlet/config
        open_settings() { # open_settings N KEY...
            local n=$1; shift
            SHOTLET_SETTINGS_FOCUS=$n SHOTLET_DUMP_FRAME=$OUT/settings-$n run_shotlet "settings-$n" settings
            sleep 2
            keys "$@"
            sleep 0.5
            keys esc
            wait_exit 5
        }
        open_settings 3 space
        check "the thumbnail switch turns quick access off" grep -q "^quick_access=false" "$cfgf"
        open_settings 5 enter
        check "  ... and + makes it stay longer" grep -q "^quick_access_seconds=10" "$cfgf"
        mkdir -p "$HOME/.local/state/shotlet/history/1795280000000-0000abcd"
        open_settings 11 enter
        check "Clear history empties it" test ! -e "$HOME/.local/state/shotlet/history/1795280000000-0000abcd"
        open_settings 13 enter
        check "Enable installs the GNOME Shell extension" test -f "$HOME/.local/share/gnome-shell/extensions/shotlet@midnattsol.github.io/extension.js"
        ;;
    annotate)
        # Annotate on the thumbnail reopens the editor with the shapes
        # still editable; its Copy updates the same capture
        quick_cfg
        drv_start Meta-0 || { fail "driver"; exit 1; }
        drv key esc
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
        ;;
    history)
        quick_cfg
        drv_start Meta-0 || { fail "driver"; exit 1; }
        drv key esc
        drv move 0 800 450
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
        pkill -f "shotlet quick" 2>/dev/null
        SHOTLET_DUMP_FRAME=$OUT/panel run_shotlet panel history
        check "Recent captures lists both" wait_log 5 "history: 2 captures"
        check "  ... without a search field when Tesseract is missing" wait_log 5 "text search off|text search on"
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
        pkill -f "shotlet (quick|history|pin)" 2>/dev/null
        sleep 0.5
        run_shotlet again history
        check "the history survives a restart" wait_log 5 "history: 1 captures"
        keys esc esc
        wait_exit 5
        "$BIN" history clear >/dev/null 2>&1
        run_shotlet cleared history
        check "history clear empties it" wait_log 5 "history: 0 captures"
        keys esc
        wait_exit 5
        ;;
    capture)
        drv_start Meta-0 || { fail "driver"; exit 1; }
        drv key esc # leave the overview the session starts in
        drv move 0 800 450
        run_shotlet first
        check "portal dialog shown and accepted" share_dialog 0
        check "editor opened after Share" wait_editor 10
        shot 0 editor
        # the editor shows the captured desktop dimmed: not a flat colour
        drv pixel "$OUT/editor.png" 400 300; a=$VAL
        drv pixel "$OUT/editor.png" 1300 700; b=$VAL
        check "editor shows the real desktop" test "$a" != "$b"
        drag 0 200 200 0 400 350 0 600 500
        drv key enter
        sleep 0.5
        shot 0 closed
        drv pixel "$OUT/closed.png" 400 300
        check "Enter closes the editor" test "$VAL" != "$a"
        check "clipboard holds a PNG while shotlet serves it" clip_png "$OUT/clip.png"
        check "copied PNG has the selection's size" eq "$(png_size "$OUT/clip.png")" 400x300
        check "shotlet keeps serving the clipboard" alive
        check "restore token stored" grep -q screencast_restore_token "$HOME/.config/shotlet/config"
        check "registered with the portal as $APP_ID" grep -q "portal identity: $APP_ID (registry)" "$SHOT_LOG"
        check "  ... which keys the screen-cast grant" eq "$(perm_apps screencast)" "$APP_ID"
        first_pid=$SHOT_PID
        t0=$(date +%s%N)
        run_shotlet second
        check "second capture is silent (restore token)" wait_editor 5
        t1=$(date +%s%N)
        echo "  second capture: $(((t1 - t0) / 1000000)) ms to editor"
        drv key esc
        check "Esc with nothing to cancel quits" wait_exit 5
        check "  ... with status 0" eq "$RC" 0
        SHOT_PID=$first_pid
        check "first instance still owns the clipboard" clip_png "$OUT/clip2.png"
        # copying again hands the clipboard over; the old server exits
        run_shotlet third
        wait_editor 5
        prev=$first_pid
        drag 0 100 100 0 300 200
        drv key ctrl+c
        sleep 1
        check "Ctrl+C copies too" eq "$(clip_png "$OUT/clip3.png" && png_size "$OUT/clip3.png")" 200x100
        SHOT_PID=$prev
        check "previous clipboard server exits when replaced" wait_exit 5
        # as a GNOME custom shortcut starts it: its own session, no
        # terminal, no systemd scope; the registered identity alone must
        # find the stored grant again
        SHOT_LOG=$OUT/shortcut.log
        setsid -f env SHOTLET_EDITOR_DUMP="$OUT/shortcut" "$BIN" </dev/null >"$SHOT_LOG" 2>&1
        check "a shortcut-style launch is silent too" wait_log 8 "startup: capture="
        sleep 0.8
        drv key esc
        sleep 1
        check "  ... with no new grant (still one, under $APP_ID)" eq "$(perm_apps screencast)" "$APP_ID"
        ;;
    cancel)
        drv_start Meta-0 || { fail "driver"; exit 1; }
        drv key esc
        drv move 0 800 450
        run_shotlet cancel
        wait_button 0
        sleep 0.5
        shot 0 dialog
        drv key esc
        check "Esc in the dialog ends shotlet" wait_exit 5
        check "  ... with status 0" eq "$RC" 0
        check "  ... saying it was cancelled" grep -q "capture cancelled" "$SHOT_LOG"
        check "  ... without trying the Screenshot portal" not_grep screenshot "$SHOT_LOG"
        sleep 1
        shot 0 after
        check "no further dialog appears" no_find 0 "$accent"
        check "no restore token stored" not_grep screencast_restore_token "$HOME/.config/shotlet/config"
        ;;
    multimon)
        drv_start Meta-0 Meta-1 || { fail "driver"; exit 1; }
        drv key esc
        drv move 0 800 450
        run_shotlet multi
        check "picker shows both monitors; both shared" share_dialog 0 "0 1"
        check "editor opened" wait_editor 10
        check "  ... capturing both monitors" grep -q "monitors=2" "$SHOT_LOG"
        shot 0 editor0
        shot 1 editor1
        # 1400..1800 x 300..500 in desktop coordinates: across the seam
        drag 0 1400 300 0 1599 400 1 100 450 1 200 500
        sleep 0.3
        shot 0 sel0
        shot 1 sel1
        # the "400 × 200" pill (its #f5f5f7 text) only next to the toolbar
        check "size label shown on the toolbar's monitor" drv find 0 f5f5f7 3
        check "  ... and not repeated on the other" no_find_exact 1 f5f5f7 3
        drv key enter
        sleep 1
        check "selection across both monitors is copied whole" eq "$(clip_png "$OUT/clip.png" && png_size "$OUT/clip.png")" 400x200
        check "one editor surface per monitor (first)" eq "$(png_size "$OUT/multi-frame.png")" 1600x900
        check "one editor surface per monitor (second)" eq "$(png_size "$OUT/multi-frame-1.png")" 1280x720
        ;;
    mixed)
        # Meta-0 2560x1440 at 2 (1280x720 logical), Meta-1 1280x720 at 1
        "$ROOT/tools/e2e/monitors.sh" Meta-0=2 Meta-1=1 >"$OUT/layout.txt" || fail "monitor layout"
        drv_start Meta-0 Meta-1 || { fail "driver"; exit 1; }
        drv key esc
        drv move 0 1280 720
        run_shotlet mixed
        check "both monitors shared" share_dialog 0 "0 1" 2
        check "editor opened" wait_editor 10
        # the stitched image uses the sharpest density (2): the 1x monitor
        # is upscaled, so 480x300 logical across the seam is 960x600
        # (the driver addresses a monitor in its physical pixels)
        drag 0 2000 400 0 2550 700 1 100 450 1 200 500
        sleep 0.3
        shot 0 sel0
        shot 1 sel1
        drv key ctrl+c
        sleep 1
        check "mixed-scale selection exported at 2x" eq "$(clip_png "$OUT/clip.png" && png_size "$OUT/clip.png")" 960x600
        run_shotlet again
        check "a second capture needs no dialog" wait_editor 5
        echo "  warm, through the portal: $(grep -o "startup: .*" "$SHOT_LOG")"
        keys esc
        ;;
    fractional | integer)
        # Meta-0 2560x1440 at 1.5 (mutter's nearest: 1.4953) or 2
        if [ "$scenario" = integer ]; then
            "$ROOT/tools/e2e/monitors.sh" Meta-0=2 Meta-1=1 >"$OUT/layout.txt" || fail "monitor layout"
            export SHOTLET_NO_FRACTIONAL=1 # wl_output.scale + set_buffer_scale
        else
            "$ROOT/tools/e2e/monitors.sh" Meta-0=1.5 Meta-1=1 >"$OUT/layout.txt" || fail "monitor layout"
        fi
        drv_start Meta-0 Meta-1 || { fail "driver"; exit 1; }
        drv key esc
        drv move 0 1280 720
        run_shotlet hidpi
        check "both monitors shared" share_dialog 0 "0 1" "$([ "$scenario" = integer ] && echo 2 || echo 1)"
        check "editor opened" wait_editor 10
        drag 0 300 300 0 900 700 0 1500 900
        sleep 0.3
        shot 0 sel
        drv key ctrl+c
        sleep 0.5
        check "selection maps 1:1 to physical pixels" eq "$(clip_png "$OUT/clip.png" && png_size "$OUT/clip.png")" 1200x600
        check "buffer covers the panel exactly" eq "$(png_size "$OUT/hidpi-frame.png")" 2560x1440
        check "the 1x monitor keeps a 1x buffer" eq "$(png_size "$OUT/hidpi-frame-1.png")" 1280x720
        # the toolbar's Copy button (the accent-coloured one, wider than
        # the active tool's) copies on click
        run_shotlet close
        wait_editor 5
        drag 0 300 300 0 1500 900
        sleep 0.3
        shot 0 toolbar
        cx=
        drv find 0 "$accent" 24 40 && read -r cx cy _ <<<"$VAL"
        check "toolbar Copy button found" test -n "$cx"
        click 0 "$cx" "$cy"
        sleep 1
        check "a click on a toolbar button hits it" eq "$(clip_png "$OUT/clip2.png" && png_size "$OUT/clip2.png")" 1200x600
        ;;
    keyboard)
        # Spanish layout (HL_LAYOUT=es): ñ is the key right of L, ´ a dead
        # key right of it, ¿ is Shift + the key left of Backspace, ? is
        # Shift + the key right of 0, € is AltGr+E
        drv_start Meta-0 || { fail "driver"; exit 1; }
        drv key esc
        drv move 0 800 450
        run_shotlet kb
        share_dialog 0 && wait_editor 10 || { fail "editor"; exit 1; }
        drag 0 200 200 0 700 500
        keys t
        click 0 260 260
        drv sleep 200
        keys semicolon a n d apostrophe u space shift+equal shift+q u apostrophe e space t a l shift+minus space altgr+e
        sleep 0.3
        shot 0 typed
        keys ctrl+a ctrl+c
        sleep 0.3
        check "Spanish text with dead keys and AltGr" eq "$(timeout 5 wl-paste -n)" "ñandú ¿Qué tal? €"
        # key repeat: hold a key past the repeat delay
        keys end
        drv hold l 1500
        sleep 0.3
        shot 0 held
        # text past the selection (x >= 702) is dimmed, as it will be cut
        check "live text inside the selection is bright" drv find 0 ff453a 30 1 400 230 700 290
        check "  ... and dimmed past its edge (not exported)" no_find_exact 0 ff453a 30 1 703 230 1600 290
        keys ctrl+a ctrl+c
        sleep 0.3
        n=$(timeout 5 wl-paste -n | grep -o l | wc -l)
        echo "  held 'l' for 1.5 s: $n characters"
        check "held key repeats" test "$n" -gt 10
        check "  ... and stops on release" test "$n" -lt 120
        # Esc leaves text editing but keeps the editor
        keys esc
        sleep 0.3
        check "Esc ends text editing, editor stays" alive
        shot 0 text-done
        # Ctrl+Z removes the text, Ctrl+Shift+Z brings it back: the first
        # red blob in reading order is the text (y ~260) when it is there,
        # else the toolbar's red swatch below the selection
        red_y() { drv find 0 ff453a 40 && read -r _ y _ <<<"$VAL" && echo "$y"; }
        check "text is drawn" test "$(red_y)" -lt 400
        keys ctrl+z
        sleep 0.3
        shot 0 undone
        check "Ctrl+Z undoes the text" test "$(red_y)" -gt 400
        keys ctrl+shift+z
        sleep 0.3
        shot 0 redone
        check "Ctrl+Shift+Z redoes it" test "$(red_y)" -lt 400
        keys enter
        sleep 1
        check "  ... the annotated selection" eq "$(clip_png "$OUT/kb.png" && png_size "$OUT/kb.png")" 500x300

        # Shift squares a selection: a 300x100 drag becomes 300x300
        run_shotlet shift
        wait_editor 5
        drv move 0 100 100 && drv sleep 100 && drv down
        drv key shift down
        drv move 0 300 180
        drv move 0 400 200
        drv sleep 100
        drv up
        drv key shift up
        sleep 0.3
        shot 0 shift
        keys enter
        sleep 1
        check "Shift squares the selection" eq "$(clip_png "$OUT/shift.png" && png_size "$OUT/shift.png")" 300x300

        # Space moves the selection while dragging: from 500,300 drag to
        # 600,400; with Space held move by 100,100; then on to 800,600
        run_shotlet space
        wait_editor 5
        drv move 0 500 300 && drv sleep 100 && drv down
        drv move 0 600 400
        drv key space down
        drv move 0 650 450
        drv move 0 700 500
        drv key space up
        drv move 0 800 600
        drv sleep 100
        drv up
        sleep 0.3
        shot 0 space
        keys enter
        sleep 1
        check "Space moves the selection while dragging" eq "$(clip_png "$OUT/space.png" && png_size "$OUT/space.png")" 200x200

        # Esc: first drops the selection, then quits
        run_shotlet esc
        wait_editor 5
        drag 0 100 100 0 300 300
        keys r
        keys esc
        sleep 0.3
        check "Esc with a tool and a selection keeps the editor" alive
        keys esc esc
        check "  ... further Esc presses quit" wait_exit 3
        check "  ... with status 0" eq "$RC" 0

        # Ctrl+S saves to ~/Pictures and closes
        run_shotlet save
        wait_editor 5
        drag 0 100 100 0 260 220
        keys ctrl+s
        check "Ctrl+S closes" wait_exit 5
        f=$(ls "$HOME"/Pictures/shotlet-*.png 2>/dev/null | head -1)
        check "Ctrl+S wrote ~/Pictures/shotlet-*.png" test -n "$f"
        check "  ... of the selection's size" eq "$(png_size "$f")" 160x120
        ;;
    clipboard)
        drv_start Meta-0 || { fail "driver"; exit 1; }
        drv key esc
        drv move 0 800 450
        run_shotlet clip
        share_dialog 0 && wait_editor 10 || { fail "editor"; exit 1; }
        drag 0 200 200 0 700 500
        keys t
        click 0 260 260
        drv sleep 200
        # paste in: wl-copy offers text the way other apps do
        timeout 5 wl-copy -- "pegado €ñ¿ 漢字 👍" &
        sleep 0.5
        keys ctrl+v
        sleep 0.3
        keys ctrl+a ctrl+c
        sleep 0.3
        check "paste then copy round-trips non-ASCII text" eq "$(timeout 5 wl-paste -n)" "pegado €ñ¿ 漢字 👍"
        keys home shift+right shift+right shift+right ctrl+x
        sleep 0.3
        check "Ctrl+X cuts the selected characters" eq "$(timeout 5 wl-paste -n)" "peg"
        keys ctrl+a ctrl+c
        sleep 0.3
        check "  ... out of the text" eq "$(timeout 5 wl-paste -n)" "ado €ñ¿ 漢字 👍"
        shot 0 text
        keys esc enter
        sleep 1
        check "Enter copies the image after text editing" eq "$(clip_png "$OUT/img.png" && png_size "$OUT/img.png")" 500x300
        # the image stays pasteable, repeatedly, while shotlet serves it
        check "  ... and pastes again" clip_png "$OUT/img2.png"
        check "  ... as the same bytes" cmp -s "$OUT/img.png" "$OUT/img2.png"
        check "  ... from a still running shotlet" alive
        timeout 5 wl-copy -- "other" &
        sleep 0.5
        check "shotlet exits once another app takes the clipboard" wait_exit 5
        ;;
    saveas)
        drv_start Meta-0 || { fail "driver"; exit 1; }
        drv key esc
        drv move 0 800 450
        run_shotlet saveas
        share_dialog 0 && wait_editor 10 || { fail "editor"; exit 1; }
        drag 0 300 300 0 500 450
        keys ctrl+shift+s
        # the GTK file chooser: its Save button is the accent-coloured blob
        check "Ctrl+Shift+S opens the file chooser" wait_chooser 0 15
        sleep 0.5
        shot 0 chooser
        # the proposed name is selected, minus the extension
        keys e 2 e minus s a v e enter
        check "Save As closes after the chooser" wait_exit 10
        check "  ... with status 0" eq "$RC" 0
        ls -la "$HOME/Pictures" >"$OUT/pictures.txt"
        check "  ... writing the chosen file" eq "$(png_size "$HOME/Pictures/e2e-save.png")" 200x150
        run_shotlet cancel
        wait_editor 5
        drag 0 300 300 0 500 450
        keys ctrl+shift+s
        wait_chooser 0 15
        sleep 0.5
        keys esc
        sleep 1
        shot 0 cancelled
        check "cancelling the chooser writes nothing" eq "$(ls "$HOME/Pictures" | wc -l)" 1
        if alive; then
            check "  ... and returns to the editor" test "$(drv find 0 ff453a 40 && echo found)" = found
            keys ctrl+shift+s
            wait_chooser 0 15
            sleep 0.5
            keys a g a i n enter
            check "  ... which can still save" wait_exit 10
            check "  ... the same selection" eq "$(png_size "$HOME/Pictures/again.png")" 200x150
        else
            wait "$SHOT_PID"; RC=$?
            fail "  ... and returns to the editor (shotlet exited, status $RC)"
        fi
        ;;
    daemon)
        # headless GNOME has no StatusNotifierWatcher (that needs the
        # AppIndicator extension): the daemon must just wait for one.
        # Here the test plays the tray host and calls the item directly.
        drv_start Meta-0 || { fail "driver"; exit 1; }
        drv key esc
        drv move 0 800 450
        run_shotlet daemon --daemon -f
        sleep 2
        check "daemon runs without a StatusNotifierWatcher" alive
        daemon_pid=$SHOT_PID
        check "  ... owning io.github.midnattsol.Shotlet" gdbus_owner io.github.midnattsol.Shotlet
        run_shotlet second --daemon -f
        check "a second daemon exits at once" wait_exit 3
        check "  ... with status 0" eq "$RC" 0
        check "  ... saying one already runs" grep -q "already running" "$SHOT_LOG"
        "$BIN" --daemon >"$OUT/detached.log" 2>&1
        check "detaching (no -f) returns at once" eq "$?" 0
        sleep 1
        SHOT_PID=$daemon_pid SHOT_LOG=$OUT/daemon.log
        check "  ... and the first daemon is unaffected" alive
        # a tray host showing up later (extension enabled, panel restart)
        drv sni-watcher 5000
        check "daemon registers its item once a tray host appears" test -n "$VAL"
        check "  ... (logged)" wait_log 3 "tray icon registered"
        sni Activate 0 0
        check "tray Activate starts a capture" share_dialog 0
        check "  ... opening the editor" wait_log 10 "startup: capture="
        sleep 0.8
        keys esc
        sleep 1
        check "  ... whose Esc leaves the daemon running" alive
        gdbus call --session --dest io.github.midnattsol.Shotlet --object-path /MenuBar \
            --method com.canonical.dbusmenu.Event 4 clicked "<0>" 0 >/dev/null 2>&1
        check "menu Quit ends the daemon" wait_exit 5
        check "  ... with status 0" eq "$RC" 0
        ;;
    fallback)
        # no ScreenCast portal backend: shotlet falls back to the Screenshot
        # portal. GNOME asks consent only from the focused app (its app id,
        # from the portal, must match the focused window's .desktop app):
        # the windowless first request is refused or unanswered, then
        # shotlet asks again from its own small window. Shotlet registers
        # its app id with the portal (Registry), and the harness installs
        # its .desktop file under that id.
        mkdir -p "$HOME/.config/xdg-desktop-portal"
        printf '[preferred]\ndefault=gnome;gtk;\norg.freedesktop.impl.portal.ScreenCast=none\n' \
            >"$HOME/.config/xdg-desktop-portal/portals.conf"
        drv_start Meta-0 || { fail "driver"; exit 1; }
        drv key esc
        drv move 0 800 450
        # wait_permission_window: shotlet's own window (dark, 640 px wide)
        wait_permission_window() {
            local i
            for i in $(seq 1 15); do
                drv find 0 1d2125 0 300 2>/dev/null && return 0
                alive || return 1
                sleep 1
            done
            return 1
        }
        run_shotlet fallback-esc
        check "ScreenCast unavailable: Screenshot portal tried" wait_log 10 "trying the screenshot portal"
        check "no consent yet: shotlet asks from its own window (within 15 s)" wait_permission_window
        keys esc
        check "  ... where Esc ends quietly" wait_exit 5
        check "  ... with status 0" eq "$RC" 0

        run_shotlet fallback
        wait_permission_window
        sleep 0.5
        keys enter
        # GNOME's access dialog: Deny has the focus; Tab to Allow
        sleep 1.5
        shot 0 access-dialog
        keys tab enter
        check "granting GNOME's consent dialog opens the editor" wait_log 15 "startup: capture="
        sleep 0.8
        shot 0 editor
        # the retaken capture must not show our permission window
        drv pixel "$OUT/editor.png" 800 400
        check "  ... without our own window in the capture" test "$VAL" != ff1d2125
        keys esc
        check "  ... and Esc quits" wait_exit 5
        check "the screenshot consent is stored under $APP_ID" eq "$(perm_apps screenshot)" "$APP_ID"
        run_shotlet granted
        check "with consent stored, capture is direct" wait_log 10 "startup: capture="
        ms=$(grep -o "startup: capture=[0-9]*" "$SHOT_LOG" | grep -o "[0-9]*$")
        check "  ... and quick (${ms:-?} ms, no permission window)" test "${ms:-99999}" -lt 4000
        keys esc
        wait_exit 5
        ;;
    ime)
        # IBus Hangul behind gnome-shell's text-input-v3: composition shows
        # as preedit, committed syllables become text
        if ! ibus engine 2>/dev/null | grep -q hangul; then
            skip "no IBus Hangul engine (install ibus-hangul)"
            exit 0
        fi
        drv_start Meta-0 || { fail "driver"; exit 1; }
        drv key esc
        drv move 0 800 450
        run_shotlet ime
        share_dialog 0 && wait_editor 10 || { fail "editor"; exit 1; }
        drag 0 200 200 0 700 500
        keys t
        click 0 260 260
        drv sleep 300
        keys "#122" # Hangul key: Latin -> Hangul mode
        keys g k s
        sleep 0.3
        shot 0 preedit
        # (preedit.png: the composing syllable drawn white on dark)
        keys space g k s r m f space
        sleep 0.3
        shot 0 committed
        keys ctrl+a ctrl+c
        sleep 0.3
        check "IME composition commits Hangul text" eq "$(timeout 5 wl-paste -n)" "한 한글 "
        keys esc enter
        sleep 1
        check "  ... and the annotated image is copied" clip_png "$OUT/ime.png"
        ;;
    modes-*) . "$ROOT/tools/e2e/modes.sh" ;; # the capture modes
    *)
        skip "unknown scenario"
        ;;
    esac
    stop_shotlet
    pkill -P $$ 2>/dev/null
    cp "$HL_SHELL_LOG" "$OUT/shell.log" 2>/dev/null
    exit $failed
fi

# ---------------------------------------------------------------- outer side
BIN=${1:-}
if [ -n "$BIN" ] && [ -x "$BIN" ] && [ -n "${2:-}" ] && [ -x "$2" ]; then
    DRIVE=$2; shift 2
    # zig build e2e passes the drop target too; it is not beside the driver
    if [ -n "${1:-}" ] && [ -x "$1" ]; then DROPTARGET=$1; shift; fi
else
    BIN=$ROOT/zig-out/bin/shotlet DRIVE=$ROOT/zig-out/bin/shotlet-drive
fi
DROPTARGET=${DROPTARGET:-$(dirname "$DRIVE")/shotlet-droptarget}
want=${*:-$scenarios}

missing=
for t in gnome-shell dbus-run-session pipewire wireplumber gdbus wl-paste wl-copy; do
    command -v "$t" >/dev/null || missing="$missing $t"
done
for f in /usr/libexec/xdg-desktop-portal /usr/libexec/xdg-desktop-portal-gnome; do
    [ -x "$f" ] || missing="$missing ${f##*/}"
done
if [ -n "$missing" ]; then
    echo "SKIP e2e: missing$missing"
    exit 0
fi
for f in "$BIN" "$DRIVE"; do
    [ -x "$f" ] || { echo "e2e: $f not built (zig build e2e-driver)" >&2; exit 2; }
done
BIN=$(realpath "$BIN") DRIVE=$(realpath "$DRIVE")
[ -x "$DROPTARGET" ] && DROPTARGET=$(realpath "$DROPTARGET")
# a Python with GTK 4 bindings plays "another app" (python3-gi, gir1.2-gtk-4.0)
PYGTK=
for p in /usr/bin/python3 python3; do
    "$p" -c 'import gi; gi.require_version("Gtk", "4.0")' 2>/dev/null && { PYGTK=$p; break; }
done
export PYGTK

keep=${E2E_OUT:+1}
E2E_OUT=${E2E_OUT:-$(mktemp -d -t shotlet-e2e-out.XXXXXX)}
mkdir -p "$E2E_OUT"
E2E_OUT=$(realpath "$E2E_OUT")
rm -f "$E2E_OUT/results.txt"
export E2E_BIN=$BIN E2E_DRIVE=$DRIVE E2E_DROPTARGET=$DROPTARGET E2E_OUT

total_fail=0
# the extension ships its settings schema compiled: it must match the XML
if command -v glib-compile-schemas >/dev/null; then
    sdir=$ROOT/gnome-extension/shotlet@midnattsol.github.io/schemas
    tmp=$(mktemp -d)
    cp "$sdir"/*.gschema.xml "$tmp/" && glib-compile-schemas --strict "$tmp" &&
        if cmp -s "$tmp/gschemas.compiled" "$sdir/gschemas.compiled"; then
            echo "PASS schema: gschemas.compiled matches the XML" | tee -a "$E2E_OUT/results.txt"
        else
            echo "FAIL schema: gschemas.compiled is stale (glib-compile-schemas $sdir)" | tee -a "$E2E_OUT/results.txt"
            total_fail=1
        fi
    rm -rf "$tmp"
fi
for s in $want; do
    # each scenario gets a fresh session: its own HOME, portal state,
    # monitors and keyboard layout
    mons="1600x900" layout=""
    case $s in
        multimon | modes-screen) mons="1600x900 1280x720" ;;
        mixed | fractional | integer | shell-mixed) mons="2560x1440 1280x720" ;;
        keyboard | clipboard) layout=es ;;
    esac
    # GNOME maps windows (and portal callers) to apps through installed
    # .desktop files whose Exec exists: install Shotlet's, as install.sh does
    sed "s|^Exec=shotlet|Exec=$BIN|" "$ROOT/io.github.midnattsol.Shotlet.desktop" >"$E2E_OUT/io.github.midnattsol.Shotlet.desktop"
    ibus= apps=$E2E_OUT/io.github.midnattsol.Shotlet.desktop exts=
    [ "$s" = ime ] && ibus=hangul
    case $s in quick | annotate | history | shell* | modes-*) exts=$ROOT/gnome-extension/shotlet@midnattsol.github.io ;; esac
    HL_MONITORS=$mons HL_LAYOUT=$layout HL_IBUS=$ibus HL_APPS=$apps HL_EXTENSIONS=$exts timeout 300 \
        "$ROOT/tools/e2e/session.sh" "$ROOT/tools/e2e.sh" --inner "$s" \
        2> >(grep -v -e '^dbus-daemon\[' >>"$E2E_OUT/stderr.log") |
        while IFS= read -r line; do
            # session services print to the same stream; keep results only
            case $line in
                PASS* | FAIL* | SKIP* | "  "*) echo "$line" | tee -a "$E2E_OUT/results.txt" ;;
                *) echo "$line" >>"$E2E_OUT/stderr.log" ;;
            esac
        done
    rc=${PIPESTATUS[0]}
    if [ "$rc" = 77 ]; then
        echo "SKIP $s: no headless session (see $E2E_OUT/stderr.log)"
    elif [ "$rc" != 0 ]; then
        total_fail=1
        grep -q "^FAIL $s" "$E2E_OUT/results.txt" || echo "FAIL $s: exit status $rc" | tee -a "$E2E_OUT/results.txt"
    fi
done

passed=$(grep -c '^PASS' "$E2E_OUT/results.txt" 2>/dev/null)
failed=$(grep -c '^FAIL' "$E2E_OUT/results.txt" 2>/dev/null)
if [ "$total_fail" = 0 ] && [ -z "$keep" ]; then
    rm -rf "$E2E_OUT"
    echo "e2e: ${passed:-0} passed, ${failed:-0} failed"
else
    echo "e2e: ${passed:-0} passed, ${failed:-0} failed (logs: $E2E_OUT)"
fi
exit $total_fail

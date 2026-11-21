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

scenarios="capture cancel multimon mixed fractional integer keyboard clipboard saveas daemon fallback ime"

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
        gdbus call --session --dest org.midnattsol.shotlet --object-path /StatusNotifierItem \
            --method "org.kde.StatusNotifierItem.$m" "$@" >/dev/null
    }
    eq() { [ "$1" = "$2" ] || { echo "  expected '$2', got '$1'" >&2; return 1; }; }

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

    case $scenario in
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
        check "  ... owning org.midnattsol.shotlet" gdbus_owner org.midnattsol.shotlet
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
        gdbus call --session --dest org.midnattsol.shotlet --object-path /MenuBar \
            --method com.canonical.dbusmenu.Event 4 clicked "<0>" 0 >/dev/null 2>&1
        check "menu Quit ends the daemon" wait_exit 5
        check "  ... with status 0" eq "$RC" 0
        ;;
    fallback)
        # no ScreenCast portal backend: shotlet falls back to the Screenshot
        # portal. GNOME asks consent only from the focused app (its app id,
        # from the portal, must match the focused window's .desktop app):
        # the windowless first request is refused or unanswered, then
        # shotlet asks again from its own small window. The session gives
        # the portal the app id "shotlet" (a real session gets it from
        # shotlet's systemd scope) and installs shotlet.desktop.
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
    *)
        skip "unknown scenario"
        ;;
    esac
    stop_shotlet
    pkill -P $$ 2>/dev/null
    exit $failed
fi

# ---------------------------------------------------------------- outer side
BIN=${1:-}
if [ -n "$BIN" ] && [ -x "$BIN" ] && [ -n "${2:-}" ] && [ -x "$2" ]; then
    DRIVE=$2; shift 2
else
    BIN=$ROOT/zig-out/bin/shotlet DRIVE=$ROOT/zig-out/bin/shotlet-drive
fi
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

keep=${E2E_OUT:+1}
E2E_OUT=${E2E_OUT:-$(mktemp -d -t shotlet-e2e-out.XXXXXX)}
mkdir -p "$E2E_OUT"
E2E_OUT=$(realpath "$E2E_OUT")
rm -f "$E2E_OUT/results.txt"
export E2E_BIN=$BIN E2E_DRIVE=$DRIVE E2E_OUT

total_fail=0
for s in $want; do
    # each scenario gets a fresh session: its own HOME, portal state,
    # monitors and keyboard layout
    mons="1600x900" layout=""
    case $s in
        multimon) mons="1600x900 1280x720" ;;
        mixed | fractional | integer) mons="2560x1440 1280x720" ;;
        keyboard | clipboard) layout=es ;;
    esac
    ibus= apps= app_id=
    [ "$s" = ime ] && ibus=hangul
    if [ "$s" = fallback ]; then
        # GNOME maps windows to apps through .desktop files whose Exec exists
        sed "s|^Exec=.*|Exec=$BIN --daemon|" "$ROOT/shotlet.desktop" >"$E2E_OUT/shotlet.desktop"
        apps=$E2E_OUT/shotlet.desktop app_id=shotlet
    fi
    HL_MONITORS=$mons HL_LAYOUT=$layout HL_IBUS=$ibus HL_APPS=$apps HL_PORTAL_APP_ID=$app_id timeout 300 \
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

# Scenarios for tools/container/inner.sh (sourced once the session is up:
# WAYLAND_DISPLAY and the bus point at it; pass/fail/skip/check, COMP,
# SCEN, OUT, NMON are set).

BIN=${SHOTLET_BIN:-$BINDIR/shotlet} DRIVE=$BINDIR/shotlet-wldrive DROP=$BINDIR/shotlet-droptarget

# --- the input driver, as a coprocess
DRV_PID=
drv_start() {
    coproc DRV { "$DRIVE" 2>>"$OUT/drive.log"; }
    DRV_PID=$DRV_PID
    local ans
    read -r -t 20 ans <&"${DRV[0]}" || ans="err no answer"
    [ "$ans" = "ok ready" ] || { echo "driver: $ans" >&2; return 1; }
}
VAL=
drv() { # drv CMD...: one driver command; its value lands in $VAL
    local ans
    echo "$*" >&"${DRV[1]}"
    read -r -t 30 ans <&"${DRV[0]}" || ans="err no answer"
    echo "> $* -> $ans" >>"$OUT/drive.log"
    case $ans in
        ok*) VAL=${ans#ok}; VAL=${VAL# }; return 0 ;;
        *) VAL=; echo "driver: $* -> $ans" >&2; return 1 ;;
    esac
}
keys() { local k; for k in "$@"; do drv key "$k" || return 1; done; }
click() { drv move "$1" "$2" "$3" && drv sleep 120 && drv click "${4:-left}"; }
shot() { drv shot "$1" "$OUT/$2.png" >/dev/null; }
find_() { drv find "$@" >/dev/null 2>&1; }
no_find() { ! drv find "$@" >/dev/null 2>&1; }
slow_drag() { # slow_drag MON X0 Y0 X1 Y1 ...: a pause per point, like a hand
    local mon=$1
    drv move "$mon" $(($2 - 4)) "$3" && drv sleep 150 &&
        drv move "$mon" "$2" "$3" && drv sleep 150 && drv down || return 1
    shift 3
    while [ $# -ge 2 ]; do drv move "$mon" "$1" "$2" && drv sleep 200 || return 1; shift 2; done
    drv sleep 300 && drv up
}
# a drag from X0 Y0 to X1 Y1 on MON, arriving like a hand (KWin's fake
# input can leave the press at an earlier pointer position otherwise)
select_on() { # select_on MON X0 Y0 X1 Y1
    drv move "$1" $(($2 - 8)) "$3" && drv sleep 100 && drv move "$1" $(($2 - 4)) "$3" && drv sleep 100 &&
        drv move "$1" "$2" "$3" && drv sleep 150 && drv down &&
        drv move "$1" $((($2 + $4) / 2)) $((($3 + $5) / 2)) && drv move "$1" "$4" "$5" && drv sleep 100 && drv up && drv sleep 200
}
eq() { [ "$1" = "$2" ] || { echo "  expected '$2', got '$1'" >&2; return 1; }; }

# --- shotlet
SHOT_PID=
run_shotlet() { # run_shotlet NAME ARGS...: in the background, log in $OUT/NAME.log
    local name=$1; shift
    SHOT_LOG=$OUT/$name.log
    "$BIN" "$@" >"$SHOT_LOG" 2>&1 &
    SHOT_PID=$!
}
alive() { kill -0 "$SHOT_PID" 2>/dev/null; }
wait_exit() { # wait_exit SECONDS
    local i
    for i in $(seq 1 $(($1 * 10))); do alive || return 0; sleep 0.1; done
    return 1
}
wait_log() { # wait_log SECONDS PATTERN [FILE]
    local i
    for i in $(seq 1 $(($1 * 10))); do
        grep -qE "$2" "${3:-$SHOT_LOG}" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}
any_log() { # any_log SECONDS PATTERN: in any shotlet log of this run
    local i
    for i in $(seq 1 $(($1 * 10))); do
        cat "$OUT"/shotlet-*.log 2>/dev/null | grep -qE "$2" && return 0
        sleep 0.1
    done
    return 1
}
wait_editor() { wait_log "${1:-10}" "startup: capture=" && sleep 0.8; }
clip_png() { # clip_png FILE: the clipboard's image/png into FILE
    timeout 5 wl-paste -n -t image/png >"$1" 2>/dev/null &&
        [ "$(head -c 8 "$1" | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ]
}
png_size() { drv png "$1" && echo "$VAL"; }
not_log() { ! cat "$OUT"/shotlet-*.log 2>/dev/null | grep -qE "$1"; }

# --- another app: a window that reports clicks, typing and drops
start_droptarget() { # start_droptarget [MIME...]
    local i
    : >"$OUT/drop.log"
    "$DROP" "$@" >>"$OUT/drop.log" 2>>"$OUT/drop.err" &
    for i in $(seq 1 50); do grep -q "^ready" "$OUT/drop.log" && { sleep 0.8; return 0; }; sleep 0.2; done
    return 1
}
drop_said() { wait_log "$1" "$2" "$OUT/drop.log"; }

# monitor 0's logical size in MW, MH
mon_size() {
    drv monitors
    local g=${VAL%% *}
    g=${g#*:}; g=${g#*,}; g=${g#*,}; g=${g%@*}
    MW=${g%x*} MH=${g#*x}
}

quick_cfg() {
    mkdir -p "$XDG_CONFIG_HOME/shotlet"
    printf 'quick_access_seconds=600\n' >>"$XDG_CONFIG_HOME/shotlet/config"
}
no_quick_cfg() {
    mkdir -p "$XDG_CONFIG_HOME/shotlet"
    printf 'quick_access=false\n' >>"$XDG_CONFIG_HOME/shotlet/config"
}

# a capture of a test picture (red in a grey frame), copied with Enter;
# the copy lands in $OUT/NAME.png, its size in CAP_SIZE
red_capture() { # red_capture NAME
    [ -f "$OUT/red.png" ] || drv mkpng "$OUT/red.png" 1600 900 ff2020 || return 1
    run_shotlet "$1" shot --from "$OUT/red.png" --sel 200,100,800,500
    wait_editor 10 || return 1
    keys enter
    any_log 10 "quick access: (showing|added)" || return 1
    sleep 0.5
    clip_png "$OUT/$1.png" && CAP_SIZE=$(png_size "$OUT/$1.png")
}
# the newest thumbnail card: layer shell bottom-left, 8 px from the edges
# plus 28 px of shadow room; 240x150
card_point() { echo "$((36 + $1)) $((MH - 36 - $2))"; }
card_red() { find_ 0 ff2020 40 20 0 $((MH - 220)) 320 "$MH"; }

# xdg-desktop-portal-kde's screen chooser: tick the first screen, Share.
# Found by its ticked "Allow restoring on future sessions" box (Breeze's
# light accent); the rest sits at fixed offsets from it.
DIALOGS=0
# Its tiles: with one output "New Virtual Output", "Rectangular Region",
# Virtual-0; with two "Full Workspace" comes first and the screens move.
kde_share_dialog() { # kde_share_dialog [TILES]: tick screens 0 (default), 1
    local i x y t
    for i in $(seq 1 75); do
        drv find 0 b4daef 10 8 >/dev/null 2>&1 && break
        alive || return 1
        sleep 0.2
    done
    [ -n "$VAL" ] || return 1
    read -r x y _ <<<"$VAL"
    sleep 0.5
    shot 0 "dialog-$DIALOGS"
    DIALOGS=$((DIALOGS + 1))
    for t in ${1:-0}; do
        case $NMON:$t in
            1:0) click 0 $((x + 240)) $((y - 211)) ;;
            2:0) click 0 $((x + 488)) $((y - 211)) ;;
            2:1) click 0 $((x + 230)) $((y - 77)) ;;
        esac || return 1
        sleep 0.4
    done
    shot 0 "dialog-$DIALOGS-ticked"
    click 0 $((x + 396)) $((y + 47))
}

# direct capture asked nobody: no portal chooser ran, no KDE dialog was
# answered, the portal was never used
no_consent() {
    check "  ... and nobody was asked (no chooser, no dialog, no portal)" \
        test ! -s "$HOME/chooser.log" -a "$DIALOGS" = 0 -a -z "$(grep "capture path: portal" "$OUT"/*.log)"
}

# a real capture through the portal: a 400x300 selection, copied. On KWin
# the portal's dialog is answered unless it is NODIALOG (a restore token
# should make it silent)
portal_capture() { # portal_capture NAME [nodialog | TILES]
    run_shotlet "$1"
    if [ "$COMP" = kwin ] && [ "${2:-}" != nodialog ]; then kde_share_dialog "${2:-}" || return 1; fi
    wait_editor 20 || return 1
    drv move 0 200 200 && drv down && drv move 0 400 350 && drv move 0 600 500 && drv up && drv sleep 200 &&
        keys enter
}

run_scenario() {
    if [ "$COMP" = kwin ] && [ -z "${CTR_RENDER_NODE:-}" ]; then
        skip "KWin without a GPU render node composites with QPainter: no screenshots, no screencasts"
        return
    fi
    if { [ "$1" = portal ] || [ "$1" = record ]; } && [ -z "${CTR_RENDER_NODE:-}" ]; then
        # xdg-desktop-portal-wlr needs dmabuf-capable screencopy (GLES2 on
        # a render node)
        skip "the portal's screencast needs a GPU render node (/dev/dri/renderD*)"
        return
    fi
    if [ "$1" = probe ] && [ -n "${CTR_PROBE0:-}" ]; then eval "$CTR_PROBE0"; fi
    drv_start || { fail "input driver"; return; }
    mon_size
    case $1 in
    probe)
        if [ -n "${CTR_PROBE:-}" ]; then eval "$CTR_PROBE"; fi
        wayland-info >"$OUT/wayland-info.txt" 2>&1
        drv monitors; echo "monitors: $VAL"
        shot 0 probe && echo "shot: $VAL"
        ;;
    capture)
        no_quick_cfg
        check "a window to capture is up" start_droptarget
        portal_capture first nodialog
        check "the editor opened, with no dialog" grep -q "startup: capture=" "$SHOT_LOG"
        if [ "$COMP" = kwin ]; then
            check "  ... captured directly by KWin (the installed .desktop file authorizes it)" grep -q "capture path: direct (KWin ScreenShot2)" "$SHOT_LOG"
        else
            m=$(grep -o "capture path: direct ([a-z-]*)" "$SHOT_LOG" | grep -o "([a-z-]*)")
            check "  ... captured directly ${m:-(not)}" test -n "$m"
        fi
        no_consent
        wait_exit 5
        check "Enter copied the selection" clip_png "$OUT/clip.png"
        check "  ... 400x300" eq "$(png_size "$OUT/clip.png")" 400x300
        drv pixel "$OUT/clip.png" 200 150
        # the droptarget's colour (dde7f0), as captured
        check "  ... showing the window that was on screen" eq "$VAL" ffdde7f0
        ;;
    multimon)
        no_quick_cfg
        drv monitors; echo "  monitors: $VAL" >&2
        start_droptarget
        # the stitched picture has the highest scale of the two: on wlroots
        # (scale 1 and 2) a selection on the first output doubles
        if [ "$COMP" = kwin ]; then want1=200x150 want0=400x300; else want1=400x300 want0=800x600; fi
        run_shotlet first
        check "two outputs$([ "$COMP" = kwin ] || echo ", scale 1 and 2"): the editor opens with no dialog" wait_editor 20
        check "  ... both captured directly" grep -q "direct capture: 2 outputs" "$SHOT_LOG"
        no_consent
        check "  ... the editor covers both outputs" grep -q "editor: 2 surfaces" "$SHOT_LOG"
        select_on 1 100 100 300 250 && keys enter
        wait_exit 5
        check "  ... a selection on the second output copies its pixels ($want1)" eq "$(clip_png "$OUT/clip1.png" && png_size "$OUT/clip1.png")" "$want1"
        drv pixel "$OUT/clip1.png" 20 20; p1=$VAL
        run_shotlet second
        wait_editor 20
        select_on 0 200 200 600 500 && keys enter
        wait_exit 5
        check "  ... and one on the first output ($want0)" eq "$(clip_png "$OUT/clip0.png" && png_size "$OUT/clip0.png")" "$want0"
        drv pixel "$OUT/clip0.png" 100 100
        check "  ... each showing its own output (the app is on the first only)" test "$VAL" = ffdde7f0 -a "$p1" != ffdde7f0
        ;;
    rotated)
        # outputs turned 90 degrees and flipped upside down: the picture
        # must come out the way each output shows it. A pin (a 300x200
        # test picture, red inside 60..240 x 40..160) sits at 134,134 of
        # each output's top-left
        no_quick_cfg
        start_droptarget
        drv mkpng "$OUT/small.png" 300 200 ff2020
        drv monitors; echo "  monitors: $VAL" >&2
        for mon in 0 1; do
            run_shotlet "pin$mon" pin "$OUT/small.png"
            wait_log 5 "pin: showing" || { fail "pin on output $mon"; return; }
            sleep 0.5
            # pins open on the focused output: move it there first
            [ "$mon" = 0 ] && { drv move 1 300 300; drv click; sleep 0.3; }
        done
        sleep 0.5
        shot 0 screen0; shot 1 screen1
        for mon in 0 1; do
            drv find "$mon" ff2020 40 20 >/dev/null 2>&1 && echo "  output $mon: red at $VAL (screenshot)" >&2
            run_shotlet "cap$mon"
            wait_editor 20 || { fail "editor"; return; }
            select_on "$mon" 220 190 340 280 && keys enter
            wait_exit 5
            clip_png "$OUT/clip$mon.png"
            drv findpng "$OUT/clip$mon.png" ff2020 40 20 >/dev/null 2>&1; r=$VAL
            drv pixel "$OUT/clip$mon.png" 60 45
            check "output $mon ($(echo $MONITORS | cut -d' ' -f$((mon + 1)))): the pin comes out where the output shows it" eq "$VAL" ffff2020
        done
        ;;
    portal)
        # the portal when direct capture is off (wlroots: SHOTLET_NO_DIRECT)
        # or refused (KWin: Shotlet not installed, so no .desktop file)
        no_quick_cfg
        start_droptarget
        portal_capture first
        wait_exit 5
        if [ "$COMP" = kwin ]; then
            check "KWin refuses direct capture to an app it has no .desktop file for" grep -q "KWin refused" "$SHOT_LOG"
            check "  ... so the portal asks which screen (its dialog)" test "$DIALOGS" -ge 1
        else
            n1=$(wc -l <"$HOME/chooser.log" 2>/dev/null || echo 0)
            check "with direct capture off, the portal asks which output (the chooser ran)" test "$n1" -ge 1
        fi
        check "  ... the capture went through it" grep -q "capture path: portal (ScreenCast)" "$SHOT_LOG"
        check "  ... and a restore token was stored" grep -q "^screencast_restore_token=" "$XDG_CONFIG_HOME/shotlet/config"
        check "  ... Enter copied the selection" eq "$(clip_png "$OUT/clip.png" && png_size "$OUT/clip.png")" 400x300
        portal_capture second nodialog
        wait_exit 5
        check "the second capture works, with no dialog to answer" grep -q "startup: capture=" "$SHOT_LOG"
        if [ "$COMP" != kwin ]; then
            n2=$(wc -l <"$HOME/chooser.log" 2>/dev/null || echo 0)
            check "  ... silently: the restore token skipped the chooser" eq "$n2" "$n1"
        fi
        ;;
    record)
        # a GIF recording through xdg-desktop-portal-wlr (the image has no
        # ffmpeg): one chooser, then none (restore token); the file checked
        # byte by byte
        rec_gif() {
            run_shotlet "$1" record --region 100,100,320,200 --seconds 2 --no-countdown --no-control --gif
            local x
            for x in 150 200 250 300 350 300 250; do drv move 0 "$x" 180; drv sleep 200; done
            wait_exit 30
        }
        rec_gif rec-first
        n1=$(wc -l <"$HOME/chooser.log" 2>/dev/null || echo 0)
        check "a recording goes through the portal" grep -q "recording: source ScreenCast portal" "$SHOT_LOG"
        f=$(grep -o "recording: saved [^ ]*" "$SHOT_LOG" | cut -d' ' -f3)
        check "  ... into a GIF" eq "$(head -c 6 "$f" 2>/dev/null)" GIF89a
        check "  ... of the area's size" eq "$(od -An -tu2 -j6 -N4 "$f" | tr -s ' ')" " 320 200"
        check "  ... with several pictures" test "$(grep -c $'\x21\xf9\x04' "$f" 2>/dev/null)" -ge 2
        check "  ... after one output chooser" test "$n1" -ge 1
        rec_gif rec-second
        n2=$(wc -l <"$HOME/chooser.log" 2>/dev/null || echo 0)
        check "a second recording asks nothing (restore token)" eq "$n2" "$n1"
        check "  ... and records" grep -q "recording: saved" "$SHOT_LOG"
        ;;
    quick)
        quick_cfg
        check "another app is up and focused" start_droptarget
        red_capture shotlet-first
        check "the thumbnail appears after Copy" any_log 10 "quick access: showing"
        check "  ... as a layer-shell surface" any_log 1 "quick access: showing .*\(layer shell\)"
        sleep 1
        shot 0 thumb
        check "  ... bottom-left, above the other app" card_red
        keys a b c
        check "the other app keeps the keyboard (typing reaches it)" drop_said 3 "^text c"
        n0=$(grep -c "^click" "$OUT/drop.log")
        click 0 14 $((MH - 14))
        sleep 0.5
        check "a click beside the card (its shadow) reaches the app below" test "$(grep -c "^click" "$OUT/drop.log")" -gt "$n0"
        click 0 $((MW / 2)) $((MH / 2))
        sleep 0.5
        check "  ... and the thumbnail stays above it" card_red
        read -r x y <<<"$(card_point 120 75)"
        drv move 0 "$x" "$y"; sleep 0.4
        shot 0 hover
        timeout 5 wl-copy -- "something else"
        read -r x y <<<"$(card_point 60 23)"
        click 0 "$x" "$y"
        sleep 1
        drv move 0 $((MW / 2)) $((MH / 3)); sleep 0.3
        keys a
        if [ "$COMP" = kwin ]; then
            # KWin keeps the keyboard on a layer surface that clicked and
            # then went back to no keyboard interactivity
            check "after a click on the card and leaving it, typing does not run its shortcuts (A: Annotate)" \
                any_log 3 "key ignored, the pointer is elsewhere"
        else
            check "after a click on the card, once the pointer leaves it, typing reaches the app again" drop_said 3 "^text a"
        fi
        check "  ... (no editor opened)" not_log "editing .* again"
        # (wl-paste maps a surface of its own on KWin, which moves the focus)
        check "the card's Copy puts the PNG back on the clipboard" eq "$(clip_png "$OUT/clip.png" && png_size "$OUT/clip.png")" "$CAP_SIZE"
        read -r x y <<<"$(card_point 120 75)"
        slow_drag 0 "$x" "$y" $((x + 40)) $((y - 40)) 400 500 600 400 800 300
        check "dragging the card drops the PNG into the app" drop_said 5 "^drop image/png [0-9]+ 89504e47"
        check "  ... and the thumbnail goes away" any_log 5 "quick access: dropped"
        sleep 0.8
        shot 0 dropped
        check "  ... from the screen" no_find 0 ff2020 40 20 0 $((MH - 220)) 320 "$MH"
        ;;
    pin)
        quick_cfg
        start_droptarget
        red_capture shotlet-first
        any_log 10 "quick access: showing"
        sleep 1
        read -r x y <<<"$(card_point 120 75)"
        drv move 0 "$x" "$y"; sleep 0.3
        read -r x y <<<"$(card_point 219 129)"
        click 0 "$x" "$y"
        check "the card's Pin opens a pin" any_log 5 "pin: showing"
        check "  ... as a layer-shell surface" any_log 1 "pin: showing .*layer shell"
        sleep 1
        shot 0 pinned
        # 1:1 at margin 120,120 plus 14 px of shadow room
        drv findpng "$OUT/shotlet-first.png" ff2020 40 20; read -r ex ey ew eh <<<"$VAL"
        drv find 0 ff2020 40 20; read -r cx0 cy0 w0 h0 <<<"$VAL"
        check "  ... at its place, 1:1" eq "$cx0 $cy0 $w0 $h0" "$((ex + 134)) $((ey + 134)) $ew $eh"
        click 0 $((MW - 40)) 40
        sleep 0.5
        check "  ... above the app after clicking the app" find_ 0 ff2020 40 20
        keys a
        check "  ... which keeps the keyboard" drop_said 3 "^text a"
        # drag the pin by its picture: +200, +100
        slow_drag 0 400 400 450 420 500 450 550 470 600 500
        sleep 0.8
        shot 0 pin-moved
        drv find 0 ff2020 40 20; read -r cx1 cy1 _ <<<"$VAL"
        echo "  pin centre ${cx0},${cy0} -> ${cx1},${cy1}" >&2
        check "dragging the pin moves it with the pointer (+200, +100)" \
            test $((cx1 - cx0)) -ge 190 -a $((cx1 - cx0)) -le 210 -a $((cy1 - cy0)) -ge 90 -a $((cy1 - cy0)) -le 110
        keys b
        sleep 0.3
        grep -q "^text b" "$OUT/drop.log" && echo "  (after the drag the app has the keyboard)" >&2
        click 0 $((cx1 + 100)) $((cy1 + 50)); sleep 0.3
        keys c
        sleep 0.3
        grep -q "^text c" "$OUT/drop.log" && echo "  (after a click on the pin the app has the keyboard)" >&2
        keys esc
        check "Esc closes the pin" any_log 5 "pin: closed"
        ;;
    history)
        quick_cfg
        start_droptarget
        red_capture shotlet-one
        any_log 10 "quick access: showing"
        pkill -f "shotlet quick" 2>/dev/null
        run_shotlet shotlet-panel history
        check "Recent captures lists the capture" wait_log 5 "history: 1 captures"
        sleep 1.5
        shot 0 panel
        keys tab enter
        check "Enter copies the picked capture" wait_log 5 "history: copied"
        # Esc drops the pick, a second one closes; the process stays to
        # serve the copy until another app copies
        keys esc esc
        sleep 0.5
        shot 0 closed
        check "Esc twice closes the panel" no_find 0 ff2020 40 20
        check "  ... the copy is a PNG" clip_png "$OUT/hclip.png"
        check "  ... of the capture's size" eq "$(png_size "$OUT/hclip.png")" "$CAP_SIZE"
        timeout 5 wl-copy -- "something else"
        check "  ... which then exits once another app copies" wait_exit 5
        ;;
    ocr)
        quick_cfg
        start_droptarget
        if ! ldconfig -p | grep -q libtesseract; then skip "no libtesseract in the image"; return; fi
        drv textpng "$OUT/en.png" 40 "Quarterly invoice from Midnattsol" || { fail "text picture"; return; }
        drv textpng "$OUT/es.png" 40 "Canción del año en España" || { fail "text picture"; return; }
        for f in en es; do
            drv png "$OUT/$f.png"
            run_shotlet "shotlet-$f" shot --from "$OUT/$f.png" --sel "0,0,${VAL%x*},${VAL#*x}"
            wait_editor 10 && keys enter
            any_log 10 "quick access: (showing|added)"
            sleep 0.5
        done
        pkill -f "shotlet quick" 2>/dev/null
        LANG=es_ES.UTF-8 run_shotlet shotlet-panel history
        check "the panel has a search field (Tesseract found)" wait_log 5 "text search on"
        check "  ... and reads both captures" wait_log 60 "history: read the text of 2 captures"
        grep "text of" "$SHOT_LOG" | sed 's/^/  /' >&2
        # Esc clears a search (with an empty one it would close the panel)
        searched=
        search() { [ -n "$searched" ] && keys esc; searched=1; drv type "$*"; sleep 0.6; }
        search invoice
        check "search 'invoice' finds the English capture" wait_log 3 "search 'invoice': 1 shown"
        search midnattsol quarterly
        check "search 'midnattsol quarterly' (every word) finds it" wait_log 3 "search 'midnattsol quarterly': 1 shown"
        search cancion
        check "search 'cancion' finds 'Canción' (accents folded)" wait_log 3 "search 'cancion': 1 shown"
        search espana
        check "search 'espana' finds 'España'" wait_log 3 "search 'espana': 1 shown"
        search zebra
        check "search 'zebra' finds nothing" wait_log 3 "search 'zebra': 0 shown"
        shot 0 search
        keys esc esc esc
        wait_exit 5
        ;;
    *) echo "unknown scenario $1" >&2; return 2 ;;
    esac
    pkill -f "shotlet (quick|history|pin)" 2>/dev/null
    drv quit
}

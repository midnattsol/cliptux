# Helpers of the container scenarios (sourced by scenarios.sh once the
# session is up): the input driver, the shotlet under test, another app,
# the thumbnail and the portal's dialogs.

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

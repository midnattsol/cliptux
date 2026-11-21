# Core helpers of tools/e2e.sh's inner side (sourced inside the private
# session, with scenario, OUT, BIN and DRIVE set): results, the input
# driver, the shotlet under test and the portal permission store.

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
# drv_ready MON...: the driver on those monitors, out of the overview the
# session starts in; the scenario ends when it cannot start
drv_ready() {
    drv_start "$@" || { fail "driver"; exit 1; }
    drv key esc
}
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

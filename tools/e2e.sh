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

scenarios="capture blink blink-ext cancel multimon mixed fractional integer keyboard clipboard saveas daemon fallback ime quick quick-plain annotate history settings shell shell-owner shell-mixed shell-tray shell-terminal modes-screen modes-timer modes-window modes-scroll modes-scroll-manual modes-scroll-stops modes-scroll-dark modes-keys tools rec-shell rec-pick rec-gif rec-trim rec-settings rec-portal perms perms-shell gnome-install"

# ---------------------------------------------------------------- inner side
# (tools/e2e/lib.sh and desktop.sh: the helpers; tools/e2e/scenarios/*.sh:
# one scenario_NAME function per scenario, dashes as underscores)

# the scenario's settings, before anything starts
prepare_scenario() {
    case $scenario in
    capture | blink* | cancel | multimon | mixed | fractional | integer | keyboard | clipboard | saveas | daemon | fallback | ime | shell* | perms* | gnome-install)
        # these check what happens without the floating thumbnail
        mkdir -p "$HOME/.config/shotlet"
        printf 'thumbnail=never\n' >"$HOME/.config/shotlet/config"
        ;;
    esac
    case $scenario in
    quick | annotate | history | blink-ext)
        # these load the extension for the floating windows but follow
        # shotlet started here: its captures go through the portal (the
        # extension cannot start this shotlet: Capture() is refused)
        ext_gsettings set shotlet-path "'/nonexistent/shotlet'"
        ;;
    esac
}

run_scenario() {
    case $scenario in
    tools) . "$ROOT/tools/e2e/tools.sh" ;; # the editor's extra tools
    modes-*) . "$ROOT/tools/e2e/modes.sh" ;; # the capture modes
    rec-*) . "$ROOT/tools/e2e/record.sh" ;; # screen recording
    *)
        if declare -F "scenario_${scenario//-/_}" >/dev/null; then
            "scenario_${scenario//-/_}"
        else
            skip "unknown scenario"
        fi
        ;;
    esac
}

if [ "${1:-}" = "--inner" ]; then
    scenario=$2
    BIN=$E2E_BIN DRIVE=$E2E_DRIVE OUT=$E2E_OUT/$scenario
    mkdir -p "$OUT"
    cd "$HOME"
    failed=0
    . "$ROOT/tools/e2e/lib.sh"
    . "$ROOT/tools/e2e/desktop.sh"
    # portal dialogs (xdg-desktop-portal-gnome): wait_button, share_dialog...
    . "$ROOT/tools/e2e/dialogs.sh"
    for f in "$ROOT"/tools/e2e/scenarios/*.sh; do . "$f"; done
    prepare_scenario
    run_scenario
    stop_shotlet
    pkill -P $$ 2>/dev/null
    cp "$HL_SHELL_LOG" "$OUT/shell.log" 2>/dev/null
    exit $failed
fi

# ---------------------------------------------------------------- outer side
# missing_tools: what the suite needs and this system lacks, space-led
missing_tools() {
    local t f missing=
    for t in gnome-shell dbus-run-session pipewire wireplumber gdbus wl-paste wl-copy; do
        command -v "$t" >/dev/null || missing="$missing $t"
    done
    for f in /usr/libexec/xdg-desktop-portal /usr/libexec/xdg-desktop-portal-gnome; do
        [ -x "$f" ] || missing="$missing ${f##*/}"
    done
    echo "$missing"
}

# a Python with GTK 4 bindings plays "another app" (python3-gi, gir1.2-gtk-4.0)
find_pygtk() {
    local p
    for p in /usr/bin/python3 python3; do
        "$p" -c 'import gi; gi.require_version("Gtk", "4.0")' 2>/dev/null && { echo "$p"; return; }
    done
}

# the extension ships its settings schema compiled: it must match the XML
check_schema() {
    command -v glib-compile-schemas >/dev/null || return 0
    local sdir=$ROOT/gnome-extension/shotlet@midnattsol.github.io/schemas tmp
    tmp=$(mktemp -d)
    cp "$sdir"/*.gschema.xml "$tmp/" && glib-compile-schemas --strict "$tmp" &&
        if cmp -s "$tmp/gschemas.compiled" "$sdir/gschemas.compiled"; then
            echo "PASS schema: gschemas.compiled matches the XML" | tee -a "$E2E_OUT/results.txt"
        else
            echo "FAIL schema: gschemas.compiled is stale (glib-compile-schemas $sdir)" | tee -a "$E2E_OUT/results.txt"
            total_fail=1
        fi
    rm -rf "$tmp"
}

# session_env SCENARIO: the session it wants in mons, layout, ibus, apps
# and exts (monitors, keyboard layout, input method, .desktop files and
# GNOME Shell extensions)
session_env() {
    mons="1600x900" layout=""
    case $1 in
        multimon | modes-screen) mons="1600x900 1280x720" ;;
        mixed | fractional | integer | shell-mixed) mons="2560x1440 1280x720" ;;
        keyboard | clipboard) layout=es ;;
    esac
    # GNOME maps windows (and portal callers) to apps through installed
    # .desktop files whose Exec exists: install Shotlet's, as install.sh does
    sed "s|^Exec=shotlet|Exec=$BIN|" "$ROOT/io.github.midnattsol.Shotlet.desktop" >"$E2E_OUT/io.github.midnattsol.Shotlet.desktop"
    ibus= apps=$E2E_OUT/io.github.midnattsol.Shotlet.desktop exts=
    [ "$1" = ime ] && ibus=hangul
    case $1 in quick | annotate | history | blink-ext | shell* | perms-shell | modes-* | rec-shell | rec-pick | rec-gif | rec-trim | rec-bench) exts=$ROOT/gnome-extension/shotlet@midnattsol.github.io ;; esac
}

# run_session SCENARIO: the scenario in a fresh session (its own HOME,
# portal state, monitors and keyboard layout); returns its exit status
run_session() {
    session_env "$1"
    HL_MONITORS=$mons HL_LAYOUT=$layout HL_IBUS=$ibus HL_APPS=$apps HL_EXTENSIONS=$exts timeout 300 \
        "$ROOT/tools/e2e/session.sh" "$ROOT/tools/e2e.sh" --inner "$1" \
        2> >(grep -v -e '^dbus-daemon\[' >>"$E2E_OUT/stderr.log") |
        while IFS= read -r line; do
            # session services print to the same stream; keep results only
            case $line in
                PASS* | FAIL* | SKIP* | "  "*) echo "$line" | tee -a "$E2E_OUT/results.txt" ;;
                *) echo "$line" >>"$E2E_OUT/stderr.log" ;;
            esac
        done
    return "${PIPESTATUS[0]}"
}

# the totals; the logs go unless something failed or E2E_OUT was given
summary() {
    local passed failed
    passed=$(grep -c '^PASS' "$E2E_OUT/results.txt" 2>/dev/null)
    failed=$(grep -c '^FAIL' "$E2E_OUT/results.txt" 2>/dev/null)
    if [ "$total_fail" = 0 ] && [ -z "$keep" ]; then
        rm -rf "$E2E_OUT"
        echo "e2e: ${passed:-0} passed, ${failed:-0} failed"
    else
        echo "e2e: ${passed:-0} passed, ${failed:-0} failed (logs: $E2E_OUT)"
    fi
}

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

missing=$(missing_tools)
if [ -n "$missing" ]; then
    echo "SKIP e2e: missing$missing"
    exit 0
fi
for f in "$BIN" "$DRIVE"; do
    [ -x "$f" ] || { echo "e2e: $f not built (zig build e2e-driver)" >&2; exit 2; }
done
BIN=$(realpath "$BIN") DRIVE=$(realpath "$DRIVE")
[ -x "$DROPTARGET" ] && DROPTARGET=$(realpath "$DROPTARGET")
PYGTK=$(find_pygtk)
export PYGTK

keep=${E2E_OUT:+1}
E2E_OUT=${E2E_OUT:-$(mktemp -d -t shotlet-e2e-out.XXXXXX)}
mkdir -p "$E2E_OUT"
E2E_OUT=$(realpath "$E2E_OUT")
rm -f "$E2E_OUT/results.txt"
export E2E_BIN=$BIN E2E_DRIVE=$DRIVE E2E_DROPTARGET=$DROPTARGET E2E_OUT

total_fail=0
check_schema
for s in $want; do
    run_session "$s"
    rc=$?
    if [ "$rc" = 77 ]; then
        echo "SKIP $s: no headless session (see $E2E_OUT/stderr.log)"
    elif [ "$rc" != 0 ]; then
        total_fail=1
        grep -q "^FAIL $s" "$E2E_OUT/results.txt" || echo "FAIL $s: exit status $rc" | tee -a "$E2E_OUT/results.txt"
    fi
done
summary
exit $total_fail

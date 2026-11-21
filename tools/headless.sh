#!/bin/bash
# usage: dbus-run-session -- tools/headless.sh zig-out/bin/shotlet shot --from IMG.png --smoke 1500
# Runs shotlet inside a private, invisible headless gnome-shell.
# Env: HL_MONITORS="1600x900 1280x720" (virtual monitors), HL_KEEP=1 keeps $HOME.
set -u
BIN=$1; shift
export HOME=$(mktemp -d)
export XDG_RUNTIME_DIR=$(mktemp -d); chmod 700 "$XDG_RUNTIME_DIR"
MONS=()
for m in ${HL_MONITORS:-1600x900}; do MONS+=(--virtual-monitor "$m"); done
WAYLAND_DEBUG=${HL_WLDEBUG:-0} gnome-shell --headless --no-x11 "${MONS[@]}" --wayland-display wayland-hl >"$HOME/shell.log" 2>&1 &
SP=$!
for i in $(seq 1 75); do [ -S "$XDG_RUNTIME_DIR/wayland-hl" ] && break; sleep 0.2; done
sleep 1
export WAYLAND_DISPLAY=wayland-hl
timeout 40 "$BIN" "$@"; rc=$?
if kill -0 $SP 2>/dev/null; then echo "compositor: alive"; else echo "compositor: DIED"; fi
kill $SP 2>/dev/null; wait $SP 2>/dev/null
echo "exit=$rc"
echo "--- compositor log (filtered)"
grep -iE "wayland|protocol|client|shotlet" "$HOME/shell.log" | tail -15
echo "HOME=$HOME"

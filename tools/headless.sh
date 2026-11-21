#!/bin/bash
# usage: dbus-run-session -- tools/headless.sh zig-out/bin/shotlet shot --from IMG.png --smoke 1500
# Runs shotlet inside a private, invisible headless gnome-shell.
# Env: HL_MONITORS="1600x900 1280x720" (virtual monitors), HL_KEEP=1 keeps $HOME,
#      HL_TIMEOUT=40 seconds before the run is killed (portal dialogs cannot be
#      clicked here, so runs that wait on one end at shotlet's own deadline).
set -u
BIN=$1; shift
export HOME=$(mktemp -d)
export XDG_RUNTIME_DIR=$(mktemp -d); chmod 700 "$XDG_RUNTIME_DIR"
# keep every XDG location inside the throwaway home
export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
export XDG_DATA_HOME="$HOME/.local/share" XDG_CACHE_HOME="$HOME/.cache"
unset XDG_PICTURES_DIR
MONS=()
for m in ${HL_MONITORS:-1600x900}; do MONS+=(--virtual-monitor "$m"); done
WAYLAND_DEBUG=${HL_WLDEBUG:-0} gnome-shell --headless --no-x11 "${MONS[@]}" --wayland-display wayland-hl >"$HOME/shell.log" 2>&1 &
SP=$!
for i in $(seq 1 75); do [ -S "$XDG_RUNTIME_DIR/wayland-hl" ] && break; sleep 0.2; done
sleep 1
export WAYLAND_DISPLAY=wayland-hl
timeout "${HL_TIMEOUT:-40}" "$BIN" "$@"; rc=$?
if kill -0 $SP 2>/dev/null; then echo "compositor: alive"; else echo "compositor: DIED"; fi
kill $SP 2>/dev/null; wait $SP 2>/dev/null
echo "exit=$rc"
echo "--- compositor log (filtered)"
grep -iE "wayland|protocol|client|shotlet" "$HOME/shell.log" | tail -15
echo "HOME=$HOME"

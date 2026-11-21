#!/bin/bash
# usage: tools/e2e/session.sh CMD [ARGS...]
# Runs CMD inside a private, invisible GNOME session: its own HOME,
# XDG_RUNTIME_DIR, session bus (dbus-run-session), PipeWire + WirePlumber,
# and a headless gnome-shell with virtual monitors. Portals
# (xdg-desktop-portal + -gnome) are D-Bus activated on the private bus.
# Nothing here can reach the caller's desktop: WAYLAND_DISPLAY, DISPLAY and
# the session bus address are replaced before anything starts.
# Env: HL_MONITORS="1600x900 1280x720"  virtual monitors
#      HL_LAYOUT=es                     XKB layout (gsettings input-sources)
#      HL_IBUS=hangul                   IBus engine as the input source
#      HL_KEEP=1                        keep the temp HOME (prints it)
# Inside CMD: WAYLAND_DISPLAY, DBUS_SESSION_BUS_ADDRESS, HOME,
# XDG_RUNTIME_DIR point at the private session; HL_SHELL_LOG is the
# compositor log.
set -u
if [ -z "${HL_INNER:-}" ]; then
    command -v gnome-shell >/dev/null && command -v dbus-run-session >/dev/null || {
        echo "session.sh: gnome-shell or dbus-run-session missing" >&2; exit 77; }
    HOME=$(mktemp -d -t shotlet-e2e.XXXXXX) || exit 1
    export HOME
    export XDG_RUNTIME_DIR="$HOME/run"; mkdir -m 700 "$XDG_RUNTIME_DIR"
    export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
    export XDG_DATA_HOME="$HOME/.local/share" XDG_CACHE_HOME="$HOME/.cache"
    mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$HOME/Pictures"
    export XDG_CURRENT_DESKTOP=GNOME XDG_SESSION_TYPE=wayland XDG_SESSION_DESKTOP=gnome
    # no FUSE mounts (gvfs) to outlive the session or block cleaning up
    export GSETTINGS_BACKEND=dconf GTK_A11Y=none NO_AT_BRIDGE=1 GVFS_DISABLE_FUSE=1 GIO_USE_VFS=local
    # predictable dialog labels and messages
    export LANG=C.UTF-8 LANGUAGE=C; unset LC_ALL LC_MESSAGES LC_CTYPE LC_TIME LC_NUMERIC LC_MONETARY LC_PAPER LC_NAME LC_ADDRESS LC_TELEPHONE LC_MEASUREMENT LC_IDENTIFICATION
    unset WAYLAND_DISPLAY DISPLAY DBUS_SESSION_BUS_ADDRESS PIPEWIRE_REMOTE \
        PULSE_SERVER XDG_PICTURES_DIR SSH_AUTH_SOCK GNOME_KEYRING_CONTROL \
        SESSION_MANAGER XAUTHORITY GTK_IM_MODULE QT_IM_MODULE XMODIFIERS
    export HL_INNER=1
    # the private bus daemon's activation chatter is noise here
    dbus-run-session -- "$0" "$@" 2> >(grep -v '^dbus-daemon\[' >&2); rc=$?
    # processes the private bus started (portals, ...) may linger a moment
    pkill -u "$(id -u)" -f "$HOME" 2>/dev/null; sleep 0.2
    if [ -n "${HL_KEEP:-}" ]; then echo "HOME=$HOME" >&2; else rm -rf "$HOME"; fi
    exit $rc
fi

# --- inside the private bus
export WAYLAND_DISPLAY=wayland-hl
export HL_SHELL_LOG="$HOME/shell.log"
pids=()
cleanup() {
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
    wait 2>/dev/null
    # the document portal mounts a FUSE file system in the runtime dir
    for mnt in "$XDG_RUNTIME_DIR/doc" "$XDG_RUNTIME_DIR/gvfs"; do
        mountpoint -q "$mnt" 2>/dev/null && fusermount3 -u -z "$mnt" 2>/dev/null
    done
}
trap cleanup EXIT
pipewire >"$HOME/pipewire.log" 2>&1 & pids+=($!)
for i in $(seq 1 50); do [ -S "$XDG_RUNTIME_DIR/pipewire-0" ] && break; sleep 0.1; done
wireplumber >"$HOME/wireplumber.log" 2>&1 & pids+=($!)
dbus-update-activation-environment HOME XDG_RUNTIME_DIR XDG_CONFIG_HOME \
    XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_CURRENT_DESKTOP \
    XDG_SESSION_TYPE WAYLAND_DISPLAY GSETTINGS_BACKEND GTK_A11Y NO_AT_BRIDGE \
    GVFS_DISABLE_FUSE GIO_USE_VFS \
    LANG LANGUAGE
# no welcome tour, no animations (screenshots and timings stay stable)
gsettings set org.gnome.shell welcome-dialog-last-shown-version '999'
gsettings set org.gnome.desktop.interface enable-animations false
if [ -n "${HL_LAYOUT:-}" ]; then
    gsettings set org.gnome.desktop.input-sources sources "[('xkb','$HL_LAYOUT')]"
fi
# HL_IBUS=engine: an IBus input method as the only input source (gnome-shell
# then offers text-input-v3 backed by it)
if [ -n "${HL_IBUS:-}" ] && command -v ibus-daemon >/dev/null; then
    # a fixed address: ibus derives its address file from DISPLAY and
    # crashes without one (ibus_write_address); DISPLAY points nowhere
    export IBUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/ibus"
    DISPLAY=:4242 ibus-daemon --panel disable --address="$IBUS_ADDRESS" \
        >"$HOME/ibus.log" 2>&1 & pids+=($!)
    for i in $(seq 1 50); do ibus engine >/dev/null 2>&1 && break; sleep 0.1; done
    gsettings set org.gnome.desktop.input-sources sources "[('ibus','$HL_IBUS')]"
fi
MONS=()
for m in ${HL_MONITORS:-1600x900}; do MONS+=(--virtual-monitor "$m"); done
WAYLAND_DEBUG=${HL_WLDEBUG:-0} gnome-shell --headless --no-x11 "${MONS[@]}" \
    --wayland-display wayland-hl >"$HL_SHELL_LOG" 2>&1 & pids+=($!)
for i in $(seq 1 100); do
    [ -S "$XDG_RUNTIME_DIR/wayland-hl" ] && gdbus introspect --session \
        --dest org.gnome.Mutter.RemoteDesktop --object-path /org/gnome/Mutter/RemoteDesktop \
        >/dev/null 2>&1 && break
    sleep 0.2
done
[ -S "$XDG_RUNTIME_DIR/wayland-hl" ] || { echo "session.sh: gnome-shell did not start" >&2; tail "$HL_SHELL_LOG" >&2; exit 77; }
sleep 1
"$@"

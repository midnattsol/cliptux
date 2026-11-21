#!/bin/bash
# Inside the container (tools/container/run.sh): a private session bus,
# PipeWire + WirePlumber, one headless compositor and its portal backend,
# then one scenario against the real shotlet binary.
#
# usage: inner.sh COMPOSITOR SCENARIO      (sway | labwc | kwin)
# Logs and screenshots go to /out. Prints PASS/FAIL/SKIP lines.
set -u
COMP=$1 SCEN=$2
CTR=/opt/shotlet/ctr
BINDIR=/opt/shotlet/bin
OUT=/out

if [ -z "${CTR_INNER:-}" ]; then
    [ -n "${SHOTLET_CONTAINER:-}" ] || { echo "inner.sh: only inside the container" >&2; exit 2; }
    export HOME=${HOME:-/tmp/home}
    mkdir -p "$HOME"
    export XDG_RUNTIME_DIR=$HOME/run
    mkdir -m 700 -p "$XDG_RUNTIME_DIR"
    export XDG_CONFIG_HOME=$HOME/.config XDG_STATE_HOME=$HOME/.local/state \
        XDG_DATA_HOME=$HOME/.local/share XDG_CACHE_HOME=$HOME/.cache
    mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$HOME/Pictures"
    export LANG=C.UTF-8 XDG_SESSION_TYPE=wayland
    unset WAYLAND_DISPLAY DISPLAY DBUS_SESSION_BUS_ADDRESS
    # the e2e helpers (droptarget) refuse to run outside a private session
    export HL_INNER=1 CTR_INNER=1
    exec dbus-run-session -- "$0" "$@" 2> >(grep -v '^dbus-daemon\[' >&2)
fi

# ------------------------------------------------------------- the session
pids=()
cleanup() {
    for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done
    pkill -P $$ 2>/dev/null
    wait 2>/dev/null
}
trap cleanup EXIT

# a stuck scenario leaves a process list behind (run.sh stops it at 300 s)
( sleep 270; ps -eo pid,ppid,stat,wchan:24,etime,args >"$OUT/stuck-ps.txt" ) &
pids+=($!)

failed=0
pass() { echo "PASS $COMP $SCEN: $*"; }
fail() { echo "FAIL $COMP $SCEN: $*"; failed=1; }
skip() { echo "SKIP $COMP $SCEN: $*"; }
check() { # check DESCRIPTION COMMAND...
    local what=$1; shift
    if "$@"; then pass "$what"; else fail "$what"; fi
}

pipewire >"$OUT/pipewire.log" 2>&1 & pids+=($!)
for i in $(seq 1 50); do [ -S "$XDG_RUNTIME_DIR/pipewire-0" ] && break; sleep 0.1; done
wireplumber >"$OUT/wireplumber.log" 2>&1 & pids+=($!)

# MONITORS="WxH[@SCALE] ...": the outputs a scenario wants (default one)
MONITORS=${MONITORS:-1600x900}
case $SCEN in
    multimon) MONITORS="1600x900 1280x720@2" ;;
esac
set -- $MONITORS
NMON=$#

mkdir -p "$XDG_CONFIG_HOME/xdg-desktop-portal" "$XDG_CONFIG_HOME/xdg-desktop-portal-wlr"
xkbcli compile-keymap --layout us >"$HOME/keymap.xkb"
export WLDRIVE_KEYMAP=$HOME/keymap.xkb

# wlr-randr: size, place and scale the headless outputs left to right
layout_wlr() {
    local x=0 i=1 m mode scale name
    for m in $MONITORS; do
        mode=${m%@*} scale=1
        [ "$m" != "$mode" ] && scale=${m#*@}
        name=HEADLESS-$i
        wlr-randr --output "$name" --custom-mode "$mode" --pos "$x,0" --scale "$scale" >>"$OUT/compositor.log" 2>&1 || return 1
        x=$((x + ${mode%x*} / scale))
        i=$((i + 1))
    done
}

wait_socket() {
    local i
    for i in $(seq 1 100); do
        WAYLAND_DISPLAY=$(cd "$XDG_RUNTIME_DIR" && ls wayland-* 2>/dev/null | grep -v lock | head -1)
        [ -n "$WAYLAND_DISPLAY" ] && return 0
        sleep 0.1
    done
    return 1
}

# wlroots: headless outputs, GLES2 on the render node when there is one
# (xdg-desktop-portal-wlr needs dmabuf-capable screencopy), else pixman
wlr_env() {
    export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1
    if [ -n "${CTR_RENDER_NODE:-}" ]; then
        export WLR_RENDERER=gles2 WLR_RENDER_DRM_DEVICE=$CTR_RENDER_NODE
    else
        export WLR_RENDERER=pixman
    fi
}

case $COMP in
    sway)
        export XDG_CURRENT_DESKTOP=sway
        wlr_env
        cat >"$HOME/sway.conf" <<'EOF'
default_border none
focus_follows_mouse no
seat * hide_cursor 0
EOF
        sway -c "$HOME/sway.conf" >"$OUT/compositor.log" 2>&1 & pids+=($!)
        wait_socket || { fail "sway did not start"; exit 1; }
        export WAYLAND_DISPLAY SWAYSOCK=$(ls "$XDG_RUNTIME_DIR"/sway-ipc.* 2>/dev/null | head -1)
        for i in $(seq 2 "$NMON"); do swaymsg create_output >/dev/null; done
        sleep 0.5
        layout_wlr || { fail "could not lay out the outputs"; exit 1; }
        ;;
    labwc)
        export XDG_CURRENT_DESKTOP=wlroots:labwc
        wlr_env
        export WLR_HEADLESS_OUTPUTS=$NMON
        mkdir -p "$XDG_CONFIG_HOME/labwc"
        cat >"$XDG_CONFIG_HOME/labwc/rc.xml" <<'EOF'
<?xml version="1.0"?>
<labwc_config>
  <focus><followMouse>no</followMouse></focus>
  <windowRules>
    <windowRule identifier="shotlet-droptarget"><action name="Maximize"/></windowRule>
  </windowRules>
</labwc_config>
EOF
        labwc >"$OUT/compositor.log" 2>&1 & pids+=($!)
        wait_socket || { fail "labwc did not start"; exit 1; }
        export WAYLAND_DISPLAY
        sleep 0.5
        layout_wlr || { fail "could not lay out the outputs"; exit 1; }
        ;;
    kwin)
        # (not KDE_FULL_SESSION: kwin_wayland crashes on start with it)
        export XDG_CURRENT_DESKTOP=KDE KDE_SESSION_VERSION=6
        # fake input and screenshots for the driver
        export KWIN_WAYLAND_NO_PERMISSION_CHECKS=1 KWIN_SCREENSHOT_NO_PERMISSION_CHECKS=1
        # OpenGL on the render node when there is one (screenshots and
        # screencasts need it), else QPainter
        [ -n "${CTR_RENDER_NODE:-}" ] || export KWIN_COMPOSE=Q
        export QT_QPA_PLATFORM=wayland
        mode=${1%@*}
        kwin_wayland --virtual --no-lockscreen --socket wayland-kw --output-count "$NMON" \
            --width "${mode%x*}" --height "${mode#*x}" >"$OUT/compositor.log" 2>&1 & pids+=($!)
        for i in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/wayland-kw" ] && break; sleep 0.1; done
        [ -S "$XDG_RUNTIME_DIR/wayland-kw" ] || { fail "kwin did not start"; tail "$OUT/compositor.log" >&2; exit 1; }
        export WAYLAND_DISPLAY=wayland-kw
        sleep 1
        # kwin wakes xdg-desktop-portal while it starts, before its socket
        # is in the activation environment: the KDE backend dies then and
        # the portal never retries. Stop both; the bus restarts them later.
        pkill -f /usr/libexec/xdg-desktop-portal 2>/dev/null
        sleep 0.3
        ;;
    *) echo "inner.sh: unknown compositor $COMP" >&2; exit 2 ;;
esac

# xdg-desktop-portal-wlr: the "chooser" is a script that logs each call
# and names the first output (or $HOME/chooser-output), no dialog
cat >"$XDG_CONFIG_HOME/xdg-desktop-portal-wlr/config" <<EOF
[screencast]
chooser_type=simple
chooser_cmd=$CTR/chooser.sh
EOF
case $COMP in
    sway | labwc) printf '[preferred]\ndefault=wlr\n' >"$XDG_CONFIG_HOME/xdg-desktop-portal/portals.conf" ;;
    kwin) printf '[preferred]\ndefault=kde\n' >"$XDG_CONFIG_HOME/xdg-desktop-portal/portals.conf" ;;
esac
# xdg-desktop-portal's test hook naming the client's app (a real session
# derives it from the app's systemd scope): restore tokens are per app
export XDG_DESKTOP_PORTAL_TEST_APP_ID=${CTR_PORTAL_APP_ID:-shotlet}
vars=()
for v in HOME XDG_RUNTIME_DIR XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME \
    XDG_CACHE_HOME XDG_CURRENT_DESKTOP XDG_SESSION_TYPE WAYLAND_DISPLAY LANG \
    QT_QPA_PLATFORM XDG_DESKTOP_PORTAL_TEST_APP_ID SWAYSOCK KDE_SESSION_VERSION; do
    [ -n "${!v:-}" ] && vars+=("$v")
done
dbus-update-activation-environment "${vars[@]}"

. "$CTR/scenarios.sh"
run_scenario "$SCEN"
exit $failed

# Scenarios for tools/container/inner.sh (sourced once the session is up:
# WAYLAND_DISPLAY and the bus point at it; pass/fail/skip/check, COMP,
# SCEN, OUT, NMON are set). The helpers are in lib.sh, each scenario is a
# scenario_NAME function (dashes as underscores) in scenarios/*.sh.

. "$CTR/lib.sh"
for f in "$CTR"/scenarios/*.sh; do . "$f"; done

# unrunnable_reason SCENARIO: why it cannot run in this container, if so
unrunnable_reason() {
    if [ "$COMP" = kwin ] && [ -z "${CTR_RENDER_NODE:-}" ]; then
        echo "KWin without a GPU render node composites with QPainter: no screenshots, no screencasts"
    elif { [ "$1" = portal ] || [ "$1" = record ]; } && [ -z "${CTR_RENDER_NODE:-}" ]; then
        # xdg-desktop-portal-wlr needs dmabuf-capable screencopy (GLES2 on
        # a render node)
        echo "the portal's screencast needs a GPU render node (/dev/dri/renderD*)"
    fi
}

run_scenario() {
    local why
    why=$(unrunnable_reason "$1")
    if [ -n "$why" ]; then
        skip "$why"
        return
    fi
    if [ "$1" = probe ] && [ -n "${CTR_PROBE0:-}" ]; then eval "$CTR_PROBE0"; fi
    drv_start || { fail "input driver"; return; }
    mon_size
    case $1 in
    modes) . "$CTR/modes.sh" ;;
    *)
        if declare -F "scenario_${1//-/_}" >/dev/null; then
            "scenario_${1//-/_}"
        else
            echo "unknown scenario $1" >&2
            return 2
        fi
        ;;
    esac
    pkill -f "shotlet (quick|history|pin)" 2>/dev/null
    drv quit
}

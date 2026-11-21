# Background scenarios of tools/e2e.sh (sourced by its inner side, with
# its helpers): the tray daemon and the Screenshot portal fallback.
#   daemon  fallback

scenario_daemon() {
    # headless GNOME has no StatusNotifierWatcher (that needs the
    # AppIndicator extension): the daemon must just wait for one.
    # Here the test plays the tray host and calls the item directly.
    drv_ready Meta-0
    drv move 0 800 450
    run_shotlet daemon --daemon -f
    sleep 2
    check "daemon runs without a StatusNotifierWatcher" alive
    daemon_pid=$SHOT_PID
    check "  ... owning io.github.midnattsol.Shotlet" gdbus_owner io.github.midnattsol.Shotlet
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
    gdbus call --session --dest io.github.midnattsol.Shotlet --object-path /MenuBar \
        --method com.canonical.dbusmenu.Event 4 clicked "<0>" 0 >/dev/null 2>&1
    check "menu Quit ends the daemon" wait_exit 5
    check "  ... with status 0" eq "$RC" 0
}

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

scenario_fallback() {
    # no ScreenCast portal backend: shotlet falls back to the Screenshot
    # portal. GNOME asks consent only from the focused app (its app id,
    # from the portal, must match the focused window's .desktop app):
    # the windowless first request is refused or unanswered, then
    # shotlet asks again from its own small window. Shotlet registers
    # its app id with the portal (Registry), and the harness installs
    # its .desktop file under that id.
    mkdir -p "$HOME/.config/xdg-desktop-portal"
    printf '[preferred]\ndefault=gnome;gtk;\norg.freedesktop.impl.portal.ScreenCast=none\n' \
        >"$HOME/.config/xdg-desktop-portal/portals.conf"
    drv_ready Meta-0
    drv move 0 800 450
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
    check "the screenshot consent is stored under $APP_ID" eq "$(perm_apps screenshot)" "$APP_ID"
    run_shotlet granted
    check "with consent stored, capture is direct" wait_log 10 "startup: capture="
    ms=$(grep -o "startup: capture=[0-9]*" "$SHOT_LOG" | grep -o "[0-9]*$")
    check "  ... and quick (${ms:-?} ms, no permission window)" test "${ms:-99999}" -lt 4000
    keys esc
    wait_exit 5
}

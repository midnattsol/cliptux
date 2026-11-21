# Capture permission scenarios of tools/e2e.sh (sourced by its inner
# side, with its helpers): `shotlet permissions` and its reset after a
# portal grant, the GNOME integration capturing with none, and a fresh
# `gnome-integration install` that loads at the next login.
#   perms  perms-shell  gnome-install

EXT_UUID=shotlet@midnattsol.github.io

# a portal grant, what `permissions` says about it, and its reset
scenario_perms() {
    drv_ready Meta-0
    drv move 0 800 450
    run_shotlet first
    check "the first capture asks (portal)" share_dialog 0
    wait_editor 10
    keys esc
    wait_exit 5
    perms_seed
    "$BIN" permissions >"$OUT/status.txt" 2>&1
    check "permissions: the last capture went through the portal" grep -q "^last capture:  through the screen-sharing portal" "$OUT/status.txt"
    check "  ... a restore token is stored" grep -q "^restore token: stored" "$OUT/status.txt"
    check "  ... but not shown" not_grep "$(sed -n 's/^screencast_restore_token=//p' "$HOME/.config/shotlet/config")" "$OUT/status.txt"
    check "  ... one screen-cast grant, one from older versions" grep -q "^screen cast:   1 permission for $APP_ID, 1 from older versions" "$OUT/status.txt"
    check "  ... and the screenshot permission" grep -q "^screenshot:    1 permission for $APP_ID" "$OUT/status.txt"
    perms_dry_run
    perms_reset
    run_shotlet second
    check "the next capture asks again" share_dialog 0
    wait_editor 10
    keys esc
}

# other apps' entries, an older version's grant and Shotlet's "yes" for
# the Screenshot portal, next to the real grant
perms_seed() {
    perm SetPermission screencast true e2e-other org.example.Other "['yes']" >/dev/null
    perm SetPermission screencast true e2e-anon "" "['yes']" >/dev/null
    perm SetPermission screencast true e2e-old cliptux "['yes']" >/dev/null
    perm SetPermission screenshot true screenshot org.example.Other "['yes']" >/dev/null
    perm SetPermission screenshot true screenshot "$APP_ID" "['yes']" >/dev/null
}

perms_dry_run() {
    "$BIN" permissions reset --dry-run >"$OUT/dry.txt" 2>&1
    check "reset --dry-run lists what would go" grep -q "Would remove a screen-cast permission of $APP_ID" "$OUT/dry.txt"
    check "  ... and changes nothing" eq "$(perm_apps screencast | tr '\n' ' ')" " cliptux $APP_ID org.example.Other "
    check "  ... not even the token" grep -q "^screencast_restore_token=." "$HOME/.config/shotlet/config"
}

perms_reset() {
    "$BIN" permissions reset >"$OUT/reset.txt" 2>&1
    check "reset removes Shotlet's grants (current and older)" eq "$(perm_apps screencast | tr '\n' ' ')" " org.example.Other "
    check "  ... and its screenshot permission only" eq "$(perm_apps screenshot | tr '\n' ' ')" "org.example.Other "
    check "  ... and the token" not_grep "^screencast_restore_token=." "$HOME/.config/shotlet/config"
    check "  ... saying so" grep -q "Removed the stored restore token" "$OUT/reset.txt"
    "$BIN" permissions >"$OUT/status2.txt" 2>&1
    check "permissions then shows none" grep -q "^screen cast:   none" "$OUT/status2.txt"
}

# with the extension: no permission at all
scenario_perms_shell() {
    drv_ready Meta-0
    drv move 0 800 450
    ext_gsettings set shotlet-path "'$BIN'"
    "$BIN" permissions >"$OUT/before.txt" 2>&1
    check "permissions: captures go through the GNOME integration" grep -q "^capture now:   through the GNOME integration" "$OUT/before.txt"
    run_shotlet term
    check "a capture is handed to the extension" wait_exit 5
    check "  ... which opens the editor" shell_wait 10 "startup: capture=" 1
    sleep 0.8
    keys esc
    sleep 1
    "$BIN" permissions >"$OUT/after.txt" 2>&1
    check "permissions: the last capture used the GNOME integration" grep -q "^last capture:  through the GNOME integration (no permission used)" "$OUT/after.txt"
    check "  ... which stored no permission" grep -q "^screen cast:   none" "$OUT/after.txt"
    check "  ... none in the store at all" eq "$(perm_apps screencast)$(perm_apps screenshot)" ""
}

# a copied extension the running shell does not know: enabled for the
# next login, then active, and the first capture through it finishes the
# setup
scenario_gnome_install() {
    drv_ready Meta-0
    "$BIN" gnome-integration status >"$OUT/status0.txt" 2>&1
    check "status: not installed" grep -q "extension $EXT_UUID: not installed" "$OUT/status0.txt"
    install_twice
    "$BIN" gnome-integration status >"$OUT/status1.txt" 2>&1
    check "status: loads at the next login" grep -q "extension $EXT_UUID: installed, loads at your next login" "$OUT/status1.txt"
    "$BIN" permissions >"$OUT/perms.txt" 2>&1
    check "permissions hints at logging in again" grep -q "^hint: the GNOME integration is installed but not loaded yet: log out and back in" "$OUT/perms.txt"
    check "the shortcut answer waits for it" grep -q move "$XDG_STATE_HOME/shotlet/gnome-setup-pending"
    drv_stop
    check "a new login (the private shell restarted)" restart_shell
    drv_ready Meta-0
    drv move 0 800 450
    "$BIN" gnome-integration status >"$OUT/status2.txt" 2>&1
    check "status: active" grep -q "extension $EXT_UUID: active" "$OUT/status2.txt"
    finish_setup
}

install_twice() {
    "$BIN" gnome-integration install </dev/null >"$OUT/install.log" 2>&1
    check "install copies the extension" test -f "$XDG_DATA_HOME/gnome-shell/extensions/$EXT_UUID/metadata.json"
    check "  ... puts it in enabled-extensions" eval "gsettings get org.gnome.shell enabled-extensions | grep -q $EXT_UUID"
    check "  ... and says it loads at the next login" grep -q "It loads at your next login" "$OUT/install.log"
    "$BIN" gnome-integration install </dev/null >"$OUT/install2.log" 2>&1
    check "installing again lists it once" eq "$(gsettings get org.gnome.shell enabled-extensions | grep -o "$EXT_UUID" | wc -l)" 1
}

finish_setup() {
    run_shotlet term
    check "the first capture goes through the extension" shell_wait 15 "startup: capture=" 1
    sleep 0.8
    keys esc
    check "  ... and finishes the setup: Print goes to Shotlet" shell_wait 15 "Print now captures with Shotlet" 1
    check "  ... once" test ! -e "$XDG_STATE_HOME/shotlet/gnome-setup-pending"
    check "  ... the extension binds Print" eval 'shell1_prop Shortcuts | grep -q Print'
}

# log in again: this session's gnome-shell (the bus owner of
# org.gnome.Shell on the private bus, never another one) stops and a new
# one starts, which discovers the copied extension
restart_shell() {
    local pid i
    pid=$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.GetConnectionUnixProcessID org.gnome.Shell 2>/dev/null | grep -o '[0-9]\+' | tail -1)
    [ -n "$pid" ] || return 1
    kill "$pid"
    for i in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$pid" 2>/dev/null && return 1
    gnome-shell --headless --no-x11 --virtual-monitor 1600x900 --wayland-display wayland-hl >>"$HL_SHELL_LOG" 2>&1 &
    for i in $(seq 1 100); do
        [ -S "$XDG_RUNTIME_DIR/wayland-hl" ] && gdbus introspect --session \
            --dest org.gnome.Mutter.RemoteDesktop --object-path /org/gnome/Mutter/RemoteDesktop \
            >/dev/null 2>&1 && break
        sleep 0.2
    done
    sleep 2
    gdbus_owner dev.shotlet.Shell1
}

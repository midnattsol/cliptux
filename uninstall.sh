#!/bin/sh
# Remove what install.sh installed. Settings ($XDG_CONFIG_HOME/shotlet) and
# the capture history ($XDG_STATE_HOME/shotlet) are kept; delete those
# directories by hand to forget them too.
# Env: PREFIX (default ~/.local), XDG_DATA_HOME, XDG_CONFIG_HOME.
set -eu

app_id=io.github.midnattsol.Shotlet
prefix=${PREFIX:-$HOME/.local}
data=${XDG_DATA_HOME:-$HOME/.local/share}
config=${XDG_CONFIG_HOME:-$HOME/.config}

pkill -f "$prefix/bin/shotlet --daemon" 2>/dev/null || true
if [ -d "$data/gnome-shell/extensions/shotlet@midnattsol.github.io" ] && [ -x "$prefix/bin/shotlet" ]; then
    "$prefix/bin/shotlet" gnome-integration uninstall || true
fi
rm -f "$prefix/bin/shotlet" \
    "$data/applications/$app_id.desktop" "$data/applications/shotlet.desktop" \
    "$data/icons/hicolor/scalable/apps/$app_id.svg" "$data/icons/hicolor/scalable/apps/shotlet.svg" \
    "$config/autostart/$app_id.desktop" "$config/autostart/shotlet.desktop"
command -v update-desktop-database >/dev/null && update-desktop-database -q "$data/applications" || true
echo "Shotlet removed (settings and history kept in $config/shotlet and ${XDG_STATE_HOME:-$HOME/.local/state}/shotlet)"

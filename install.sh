#!/bin/sh
# Install Shotlet for the current user (into ~/.local; nothing needs root).
#
# usage: ./install.sh [--autostart] [--gnome-extension | --no-gnome-extension]
#   --autostart            start the tray daemon at login
#   --gnome-extension      install the GNOME Shell integration without asking
#   --no-gnome-extension   do not offer it
# Env: PREFIX (default ~/.local), XDG_DATA_HOME, XDG_CONFIG_HOME.
# Run it from a release tarball, or from the source tree after
# `zig build -Doptimize=safe`. Settings and history are never touched.
set -eu

app_id=io.github.midnattsol.Shotlet
here=$(cd "$(dirname "$0")" && pwd)
autostart=no
extension=ask
for arg in "$@"; do
    case $arg in
        --autostart) autostart=yes ;;
        --gnome-extension) extension=yes ;;
        --no-gnome-extension) extension=no ;;
        -h | --help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "install.sh: unknown option $arg" >&2; exit 2 ;;
    esac
done

if [ -x "$here/zig-out/bin/shotlet" ]; then
    bin=$here/zig-out/bin/shotlet
elif [ -x "$here/shotlet" ]; then
    bin=$here/shotlet
else
    echo "install.sh: no shotlet binary; build it first: zig build -Doptimize=safe" >&2
    exit 1
fi

prefix=${PREFIX:-$HOME/.local}
data=${XDG_DATA_HOME:-$HOME/.local/share}
config=${XDG_CONFIG_HOME:-$HOME/.config}

install -Dm755 "$bin" "$prefix/bin/shotlet"
# an absolute Exec: launchers and GNOME's app matching need it to resolve
mkdir -p "$data/applications"
sed "s|^Exec=shotlet|Exec=$prefix/bin/shotlet|" "$here/$app_id.desktop" >"$data/applications/$app_id.desktop"
chmod 644 "$data/applications/$app_id.desktop"
install -Dm644 "$here/assets/icon.svg" "$data/icons/hicolor/scalable/apps/$app_id.svg"
install -Dm644 "$here/assets/icon-symbolic.svg" "$data/icons/hicolor/symbolic/apps/$app_id-symbolic.svg"
# files of versions before the app id
rm -f "$data/applications/shotlet.desktop" "$data/icons/hicolor/scalable/apps/shotlet.svg"
if [ -f "$config/autostart/shotlet.desktop" ]; then
    rm -f "$config/autostart/shotlet.desktop"
    autostart=yes
fi
command -v update-desktop-database >/dev/null && update-desktop-database -q "$data/applications" || true
# KDE: KWin finds the file's X-KDE-DBUS-Restricted-Interfaces (screenshots
# without a dialog) through the KService cache
command -v kbuildsycoca6 >/dev/null && kbuildsycoca6 >/dev/null 2>&1 || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$data/icons/hicolor" 2>/dev/null || true
echo "installed $prefix/bin/shotlet, $app_id.desktop and its icon"

# the man page and the shell completions, generated from the binary
sl=$prefix/bin/shotlet
mkdir -p "$data/man/man1" "$data/bash-completion/completions" "$data/zsh/site-functions" "$config/fish/completions"
"$sl" man-page >"$data/man/man1/shotlet.1"
"$sl" completions bash >"$data/bash-completion/completions/shotlet"
"$sl" completions zsh >"$data/zsh/site-functions/_shotlet"
"$sl" completions fish >"$config/fish/completions/shotlet.fish"
echo "installed man shotlet and completions for bash, zsh and fish"
echo "  zsh: add $data/zsh/site-functions to fpath (before compinit) if it is not there"

if [ "$autostart" = yes ]; then
    mkdir -p "$config/autostart"
    sed -e "s|^Exec=shotlet --daemon|Exec=$prefix/bin/shotlet --daemon|" \
        -e '/^Actions=/d' -e '/^\[Desktop Action/,$d' -e '/^$/d' \
        "$here/$app_id.desktop" >"$config/autostart/$app_id.desktop"
    echo "X-GNOME-Autostart-enabled=true" >>"$config/autostart/$app_id.desktop"
    echo "the tray daemon starts at login ($config/autostart/$app_id.desktop)"
fi

case ":${XDG_CURRENT_DESKTOP:-}:" in
    *:GNOME:* | *:gnome:*)
        if [ "$extension" = ask ]; then
            if [ -t 0 ]; then
                printf 'Install the GNOME Shell integration (keeps the thumbnail and pins above other windows)? [Y/n] '
                read -r answer || answer=n
                case $answer in [nN]*) extension=no ;; *) extension=yes ;; esac
            else
                extension=no
                echo "GNOME: run 'shotlet gnome-integration install' to keep the thumbnail and pins above other windows"
            fi
        fi
        [ "$extension" = yes ] && "$prefix/bin/shotlet" gnome-integration install || true
        ;;
esac

case ":$PATH:" in
    *":$prefix/bin:"*) ;;
    *) echo "note: $prefix/bin is not in PATH; add it to run 'shotlet' from a terminal" ;;
esac

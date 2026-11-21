# Shotlet

Fast screenshot tool for **Linux on Wayland** with a Flameshot-style
annotation editor. Written in Zig, zero build dependencies — it speaks the
Wayland and DBus wire protocols directly.

- Instant capture (~0.3s) via the ScreenCast portal + PipeWire, with a
  Screenshot-portal fallback. One consent dialog ever.
- Multi-monitor: every monitor you share in the picker is captured and
  laid out as on your desktop, at the sharpest monitor's pixel density.
- Region selection, then annotate: pencil, line, arrow, rectangle, ellipse,
  highlighter, pixelate, counter badges, text. Undo/redo, 8 colors,
  mouse-wheel thickness.
- Copies straight to the clipboard (nothing written to disk), saves to
  your Pictures folder, or asks where to save (Save As, through the
  desktop's file chooser). `Enter`/`Ctrl+C` copy, `Ctrl+S` save, `Esc`
  quits. Saved files are named `shotlet-YYYYMMDD-HHMMSS.png` in local
  time and never overwrite an existing file (`-2`, `-3`, ... are added).
- Tray icon with menu, and a Settings window with rebindable shortcuts.

Shotlet was called **cliptux** until its rename; settings in
`~/.config/cliptux` (or `$XDG_CONFIG_HOME/cliptux`) are moved to the new
place on first run.

Built GNOME-first (where grim/slurp/flameshot struggle); any compositor
with the standard portals should work.

## Install

Requires Zig 0.17 to build. At runtime: a Wayland session with
xdg-desktop-portal (PipeWire recommended for fast capture).

```sh
zig build -Doptimize=safe
install -Dm755 zig-out/bin/shotlet ~/.local/bin/shotlet
install -Dm644 shotlet.desktop ~/.local/share/applications/shotlet.desktop
install -Dm644 shotlet.svg ~/.local/share/icons/hicolor/scalable/apps/shotlet.svg
```

Or grab a prebuilt binary (x86_64 / arm64) from the
[releases](../../releases) page — built against glibc 2.31, so they run on
any distro from around 2020 onward (Ubuntu 20.04+, Debian 11+, etc.).

## Usage

```sh
shotlet            # capture + editor
shotlet --daemon   # tray icon (autostart: copy shotlet.desktop to ~/.config/autostart)
shotlet settings   # preferences and shortcut bindings
```

Tip: bind a key to `shotlet` in GNOME Settings > Keyboard > Custom Shortcuts.

On GNOME the tray needs the AppIndicator extension. The first capture shows
a one-time screen-share picker: select every monitor you want captured.
The choice is remembered. Cancelling the picker just ends the capture.

## Files

| What | Where |
| --- | --- |
| Settings | `$XDG_CONFIG_HOME/shotlet/config` (default `~/.config/shotlet/config`), mode 0600 |
| Daemon log | `$XDG_STATE_HOME/shotlet/daemon.log` (default `~/.local/state/shotlet`), rotated at 1 MiB |
| Screenshots | the `save_dir` setting, else your XDG Pictures folder (`XDG_PICTURES_DIR` / `user-dirs.dirs`), else `~/Pictures` |

The settings file is plain `key=value`. Shotlet only rewrites the keys it
changes, so editing it by hand while Shotlet runs is safe.

## License

GPL-3.0 — see [LICENSE](LICENSE).

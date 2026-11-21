# Shotlet

Fast screenshot tool for **Linux on Wayland** with a Flameshot-style
annotation editor. Written in Zig, zero build dependencies — it speaks the
Wayland and DBus wire protocols directly.

- Instant capture (~0.3s) via the ScreenCast portal + PipeWire, with a
  Screenshot-portal fallback. One consent dialog ever.
- Multi-monitor: every monitor you share in the picker is captured and
  laid out as on your desktop, at the sharpest monitor's pixel density.
- Region selection (with a magnifier), then annotate: pencil, line, arrow,
  rectangle (outline, filled, rounded), ellipse, highlighter, blur,
  pixelate, solid redaction, counter badges, editable multi-line text.
  Every annotation can be selected again to move, resize, recolour or
  delete. Undo/redo, 8 colours plus a custom picker, mouse-wheel size,
  and a "beautify" frame (gradient, solid or transparent background,
  padding, rounded corners, shadow).
- Copies straight to the clipboard (nothing written to disk), saves to
  your Pictures folder, or asks where to save (Save As, through the
  desktop's file chooser). `Enter`/`Ctrl+C` copy and close, `Ctrl+S`
  save, `Esc` cancels then quits. Saved files are named `shotlet-YYYYMMDD-HHMMSS.png` in local
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

## Editor shortcuts

Defaults follow CleanShot X and Flameshot where they agree; the tool keys
and the main actions can be rebound in `shotlet settings`. Press `?` in
the editor for the full list.

| Key | Action |
| --- | --- |
| Drag | select a region (`Shift` square, `Alt` from the centre, hold `Space` to move it) |
| `Enter` / `Ctrl+C` | copy to the clipboard and close |
| `Ctrl+S` / `Ctrl+Shift+S` | save / save as |
| `Esc` / right click | cancel the current action; `Esc` again closes |
| `V` `P` `L` `A` `R` `E` `M` | select, pen, line, arrow, rectangle, ellipse, marker |
| `X` (again) | blur, then pixelate, then solid redaction |
| `N` `T` | counter badge, text |
| `F` | outline / filled / rounded (text: background) |
| `B` | beautify frame |
| `1`-`8`, `9` | preset colours, custom colour |
| wheel, `-` `=` | size |
| `Shift` while drawing | square, circle, 45° lines and arrows (`Alt`: from the centre) |
| arrows, `Shift`+arrows | move the selection or shape by 1 / 10 px (`Alt`: resize) |
| `Delete`, `Ctrl+D`, `Ctrl+]` | delete, duplicate, bring to front |
| `Ctrl+Z` / `Ctrl+Shift+Z`, `Ctrl+Y` | undo / redo |
| `Tab`, `Enter` | move through the toolbar, activate |
| Text: `Ctrl+Enter` or `Esc` | finish editing (`Enter` is a new line) |

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

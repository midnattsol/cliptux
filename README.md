# cliptux

Fast screenshot tool for **Linux on Wayland** with a Flameshot-style
annotation editor. Written in Zig, zero build dependencies — it speaks the
Wayland and DBus wire protocols directly.

- Instant capture (~0.3s) via the ScreenCast portal + PipeWire, with a
  Screenshot-portal fallback. One consent dialog ever.
- Region selection, then annotate: pencil, line, arrow, rectangle, ellipse,
  highlighter, pixelate, counter badges, text. Undo/redo, 8 colors,
  mouse-wheel thickness.
- Copies straight to the clipboard (nothing written to disk) or saves to
  your Pictures folder. `Enter`/`Ctrl+C` copy, `Ctrl+S` save, `Esc` quits.
- Tray icon with menu, and a Settings window with rebindable shortcuts.

Built GNOME-first (where grim/slurp/flameshot struggle); any compositor
with the standard portals should work.

## Install

Requires Zig 0.16 to build. At runtime: a Wayland session with
xdg-desktop-portal (PipeWire recommended for fast capture).

```sh
zig build -Doptimize=ReleaseSafe
install -Dm755 zig-out/bin/cliptux ~/.local/bin/cliptux
install -Dm644 cliptux.desktop ~/.local/share/applications/cliptux.desktop
install -Dm644 cliptux.svg ~/.local/share/icons/hicolor/scalable/apps/cliptux.svg
```

Or grab a prebuilt binary (x86_64 / arm64) from the
[releases](../../releases) page — built against glibc 2.31, so they run on
any distro from around 2020 onward (Ubuntu 20.04+, Debian 11+, etc.).

## Usage

```sh
cliptux            # capture + editor
cliptux --daemon   # tray icon (autostart: copy cliptux.desktop to ~/.config/autostart)
cliptux settings   # preferences and shortcut bindings
```

Tip: bind a key to `cliptux` in GNOME Settings > Keyboard > Custom Shortcuts.

On GNOME the tray needs the AppIndicator extension. The first capture shows
a one-time screen-share consent dialog; the choice is remembered.

## License

GPL-3.0 — see [LICENSE](LICENSE).

# Shotlet

Fast screenshot tool for **Linux on Wayland** with a Flameshot-style
annotation editor. Written in Zig, zero build dependencies — it speaks the
Wayland and DBus wire protocols directly.

- Instant capture (~0.3s). No dialog at all on wlroots compositors (Sway,
  Hyprland, labwc, river...) and KDE Plasma, which let Shotlet capture
  directly; elsewhere the ScreenCast portal + PipeWire (Screenshot-portal
  fallback), with one consent dialog ever.
- Multi-monitor: every monitor you share in the picker is captured and
  laid out as on your desktop, at the sharpest monitor's pixel density.
- Region selection (with a magnifier), then annotate: pencil, line, arrow,
  rectangle (outline, filled, rounded), ellipse, highlighter, blur,
  pixelate, solid redaction, counter badges, editable multi-line text.
  Every annotation can be selected again to move, resize, recolour or
  delete. Undo/redo, 11 colours plus a custom picker, mouse-wheel size,
  and a "beautify" frame (gradient, solid or transparent background,
  padding, rounded corners, shadow).
- One floating toolbar in a translucent, blurred material; colour, size
  and style in a popover, the rest under More. Light or dark and the
  accent colour follow the desktop (Settings portal), and transitions
  stop when the desktop asks for reduced motion.
- Copies straight to the clipboard (nothing written to disk), saves to
  your Pictures folder, or asks where to save (Save As, through the
  desktop's file chooser). `Enter`/`Ctrl+C` copy and close, `Ctrl+S`
  save, `Esc` cancels then quits. Saved files are named `shotlet-YYYYMMDD-HHMMSS.png` in local
  time and never overwrite an existing file (`-2`, `-3`, ... are added).
- After Copy or Save, a floating thumbnail (as in CleanShot X) stays in
  the bottom-left corner for a few seconds: copy it again, save it, drag
  it into any app, annotate it again, pin it to the screen. Every copied
  or saved capture is kept in a Recent captures panel.
- Tray icon with menu, and a Settings window (general, editor and
  shortcut views) with rebindable shortcuts and a save folder picker.

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
./install.sh               # into ~/.local; --autostart starts the tray at login
./uninstall.sh             # removes it again (settings and history are kept)
```

`install.sh` puts `shotlet` in `~/.local/bin`, its desktop entry
(`io.github.midnattsol.Shotlet.desktop`) and icon in `~/.local/share`, and
on GNOME offers the Shell integration (`--gnome-extension` /
`--no-gnome-extension` to answer up front). Or grab a prebuilt binary
(x86_64 / arm64) from the [releases](../../releases) page — built against
glibc 2.31, so they run on any distro from around 2020 onward (Ubuntu
20.04+, Debian 11+, etc.); the tarball has the same `install.sh`.

Shotlet's app id is `io.github.midnattsol.Shotlet`. It tells
xdg-desktop-portal so at start (the portal's `Registry`, 1.19 and later;
older portals learn it from a systemd scope), which is what lets GNOME
remember the screen-sharing and screenshot consent however Shotlet is
started. Consent given to versions before this id is not carried over:
expect to be asked once more after updating.

Direct capture, no dialog: on wlroots compositors Shotlet reads every
monitor itself (`ext-image-copy-capture-v1`, else `wlr-screencopy`). On
KDE Plasma, KWin lets it take screenshots because the installed desktop
entry declares `X-KDE-DBUS-Restricted-Interfaces=org.kde.KWin.ScreenShot2`;
KWin matches the running executable against that entry's `Exec`, so this
works for the `shotlet` that `install.sh` put in `~/.local/bin` (run from
the source tree it is refused and the portal asks instead). Settings shows
"captured directly (no prompts)" when this is what happened. The log
says `capture path: direct (...)` or `capture path: portal (...)`.

## Usage

```sh
shotlet            # capture + editor
shotlet --daemon   # tray icon (autostart: ./install.sh --autostart)
shotlet settings   # preferences and shortcut bindings
shotlet window     # other capture modes: see Capture modes below
```

Tip: bind a key to `shotlet` in GNOME Settings > Keyboard > Custom Shortcuts
(on GNOME, the integration below brings its own shortcut).

```sh
shotlet history                       # Recent captures (history clear: forget them)
shotlet pin FILE.png                  # pin an image to the screen
shotlet gnome-integration install     # GNOME: no prompts; thumbnail and pins above
shotlet gnome-integration shortcut '<Shift><Super>s'   # its capture key
```

## Capture modes

| Mode | Command | GNOME shortcut |
| --- | --- | --- |
| Area (select in the editor) | `shotlet` | `Print` |
| Screen under the pointer | `shotlet fullscreen` | `Ctrl+Print` |
| All screens | `shotlet screens` | `Ctrl+Shift+Print` |
| Previous area | `shotlet previous` | `Shift+Super+Print` |
| Window | `shotlet window` | `Super+Print` |
| Scrolling capture | `shotlet scroll` | `Ctrl+Super+Print` |
| Self-timer (3, 5 or 10 s, then an area) | `shotlet timer [S]` | `Ctrl+Shift+Super+Print` |

Every mode takes `--delay S`. With the GNOME integration each mode has its
own shortcut (none of them is one of GNOME's; a key GNOME's screenshot
tool holds is left unbound and `shotlet gnome-integration shortcut` says
so); change one in Settings › Shortcuts or with
`shotlet gnome-integration shortcut window '<Super>w'` (`none` turns it
off). Elsewhere, bind the commands in your desktop's keyboard settings.
The editor's More menu and the tray menu start a window, scrolling or
timed capture too.

- **Screen, all screens, window** skip the region selection and do what
  `after_fullscreen` says (Settings › General › Capture modes): `thumbnail`
  (the default: the floating thumbnail and the history), `copy`, or
  `editor` (with that screen selected). The screen is the one under the
  pointer on GNOME; elsewhere the first one.
- **Previous area** opens the editor with the last selection you copied or
  saved already selected. It is remembered per monitor layout
  (`$XDG_STATE_HOME/shotlet/last-area`), so it never lands on a different
  set of monitors.
- **Window**, as on macOS: the windows are outlined, the one under the
  pointer lights up, a click captures just that window at its native
  resolution, also where other windows cover it, with its own rounded
  corners on a transparent background and a soft shadow
  (`window_shadow=false` for none; with beautify on, it sits on the
  beautify background instead). On GNOME the extension paints the window
  from its own surface; on KDE it is KWin's window picker
  (`ScreenShot2.CaptureInteractive`, authorized by the desktop entry like
  the other screenshots). wlroots compositors tell clients nothing about
  windows: there it selects an area instead.
- **Scrolling capture**: drag over what scrolls, then Start (or Enter).
  Shotlet turns the wheel there step by step and stitches the frames
  (sticky headers and footers kept once, repeated rows handled, frames
  verified pixel by pixel) until the page stops moving, you press Stop,
  or the image reaches `scroll_max_height=20000` px; a small control
  beside the region shows the image growing. The result opens in the
  editor, where a tall image fits the screen's width and the wheel scrolls
  it (Ctrl+wheel: size). On GNOME the extension scrolls (see below); on
  wlroots Shotlet uses the virtual pointer (`zwlr_virtual_pointer_v1`)
  and direct capture; on KDE, unless KWin offers Shotlet its fake input,
  you scroll yourself and Shotlet captures as the content moves (also
  with `scroll_auto=false`).
- **Self-timer**: a small countdown in the middle of the screen, gone
  before the capture; on GNOME the shell draws it and it never takes the
  keyboard focus, so a menu left open for it stays open. Click it to
  cancel. `timer_seconds=5` in the settings (3, 5, 10).

## After a capture

After Copy or Save the editor closes and a 240×150 thumbnail appears in
the bottom-left corner for 8 seconds (longer while the pointer is on it);
later captures stack above it. On hover:

| Control | Action |
| --- | --- |
| Copy / Save | copy to the clipboard again / save to the screenshots folder |
| right-click | menu, with Save As... |
| pencil | annotate: reopens the editor with the annotations still editable |
| pin | pin the capture to the screen |
| × | close |
| drag | drop the image into any app (offered as `image/png` and as a file, `text/uri-list`) |

Keyboard (after clicking it): `Ctrl+C`, `Ctrl+S`, `Ctrl+Shift+S`, `E`
annotate, `P` pin, `Esc`/`Delete` close, `Tab` and `Enter` to reach every
button. Turn it off with `quick_access=false` (Copy and Save then behave as
before); `quick_access_seconds=8` sets how long it stays.

**Pins** show the capture at 1:1 in a frameless window: scroll (or `-`
`=` `0`) to zoom, drag to move, `Esc` or the × to close. Any number of
them.

**Recent captures** (`shotlet history`, or the tray menu) lists the last
captures that were copied or saved, newest first, with when they were
taken. Pick one to copy, save, annotate, pin or delete it (`Enter` copies,
`Delete` removes); "Clear" empties the history. When Tesseract is
installed (`libtesseract.so.5`, plus its language data, e.g.
`tesseract-ocr-eng`), captures are read in the background and a search
field finds them by their text (`SHOTLET_OCR_LANG=eng+spa` for other
languages); without it there is no search field. Settings: `history=false`
keeps nothing, `history_max=50` captures and `history_max_mb=500` cap it.
All of these are also in `shotlet settings` (General), with Clear history
and the GNOME integration's state.

### Where the floating windows go (and GNOME)

A Wayland app cannot place its own window or keep it above others.
Compositors with the `wlr-layer-shell` protocol (KDE Plasma, Sway,
Hyprland, and other wlroots compositors) let Shotlet put the thumbnail in
an overlay layer anchored to the bottom-left corner, never taking the
keyboard unless clicked, and pins in the top layer; that is used
automatically.

GNOME's mutter has no such protocol (and will not add it), so Shotlet
ships a small GNOME Shell extension (`gnome-extension/`, GNOME 45 to 50)
that does it for Shotlet's windows only: it places the thumbnail
bottom-left on the monitor under the pointer, keeps it and pins above
other windows on every workspace, leaves them out of Alt+Tab, and hands the keyboard focus straight
back to the app you were in when the thumbnail appears. Install it with
`shotlet gnome-integration install` (or the link on the thumbnail):
GNOME Shell on Wayland only picks up a newly installed extension at your
next login. `shotlet gnome-integration status` tells whether it is active.

### Captures without prompts on GNOME

With the extension active, capturing never shows a consent dialog:
installing the extension is the consent. The extension takes the
screenshot itself, inside GNOME Shell, and starts Shotlet's editor on it:

- **Its own shortcut**, `capture-shortcut` in its settings, default
  `Print`. On stock GNOME, Print opens GNOME's screenshot tool:
  `shotlet gnome-integration install` offers to give Print to Shotlet
  (it asks on a terminal, yes by default; the Enable button in Settings
  just does it and says so), moving GNOME's screenshot tool to
  Shift+Super+S when nothing else uses that key. Only the GNOME shortcuts
  holding Print change, what they held is remembered
  (`~/.config/shotlet/gnome-moved-keys`), and `uninstall` restores them
  exactly. Decline, and the extension leaves the key alone and binds
  nothing (Settings and `status` say so); pick another key with
  `shotlet gnome-integration shortcut '<Shift><Super>s'` (`none` for no
  key). install also finds custom shortcuts that run `shotlet`, offers
  to move them to the extension's key, and `uninstall` puts them back.
- **`shotlet` and the tray's Take screenshot** ask the extension
  (`dev.shotlet.Shell1.Capture()`), so they need no prompt either.

How it stays safe: no D-Bus method returns screen contents. `Capture()`
only starts the same flow, which ends in Shotlet's editor on screen; it is
honoured only for a caller whose executable is the shotlet binary the
extension starts, one capture at a time and at most one a second, never
while the screen is locked. The pixels go from
`Shell.Screenshot.screenshot_area` (every monitor at its own scale, a few
strips of it encoded in parallel; no cursor, and no flash or shutter
sound: those belong to GNOME's screenshot UI) into fresh 0600 files in
`$XDG_RUNTIME_DIR/shotlet` (a 0700 directory the extension checks is
its own), and nowhere else; Shotlet opens them without following
symlinks, refuses files that are not private and its own, and deletes
them as soon as they are read (leftovers from a Shotlet that failed to
start are deleted after a minute). Sandboxed (Flatpak) apps cannot reach
the extension's bus name or that directory.

The capture modes keep to the same rules. `CaptureMode(mode, delay)` is
`Capture()` for a mode, with the same caller check and rate limit. A
window capture's picker runs in the shell and its PNG takes the same
path. A scrolling capture is a session the shotlet binary opens with
`ScrollBegin` on one region of one monitor; only that bus connection may
step or end it, one session at a time, never on the lock screen, and only
while Shotlet's scrolling control is on screen. Each step returns the id
of a fresh 0600 capture file of that region, nothing else. To scroll,
the extension creates a virtual pointer for that session only: it puts
the pointer in the middle of the region, turns the wheel there (at most
10 notches a step, 25 steps a second) and puts the pointer back at the
end; the device is dropped when the session ends, when Shotlet's
connection goes away, after 30 s without a step or after 5 minutes.

When the extension is missing, older, or cannot capture, Shotlet uses the
screen-sharing portal as before. `shotlet gnome-integration status` and
Settings › General say which way captures go.

Timings in the private headless GNOME (software rendering, release
build), from the key press to the editor on screen, through the
extension: one 1600×900 monitor 68–75 ms (40–45 ms of it in the shell);
2560×1440 at 2 next to 1280×720 at 1, about 230 ms. The portal path with
its remembered grant takes 52–66 ms and about 225 ms from the start of
`shotlet` (plus launching it, and GNOME's screen-sharing indicator
flashes), and seconds with its dialog the first time.

Without the extension everything still works, but the thumbnail is an
ordinary window wherever GNOME opens it (and it takes the keyboard focus,
as any new window does), and a pin stays above other windows only if you
choose "Always on Top" in its window menu (right-click the pin). The
thumbnail never covers more than itself: around the cards it lets clicks
through to the window below.

On GNOME the tray needs the AppIndicator extension. Without the GNOME
integration, the first capture shows
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
| Previous area | `$XDG_STATE_HOME/shotlet/last-area`: the last selection per monitor layout |
| Daemon log | `$XDG_STATE_HOME/shotlet/daemon.log` (default `~/.local/state/shotlet`), rotated at 1 MiB |
| Screenshots | the `save_dir` setting, else your XDG Pictures folder (`XDG_PICTURES_DIR` / `user-dirs.dirs`), else `~/Pictures` |
| Recent captures | `$XDG_STATE_HOME/shotlet/history/<id>/`: `image.png`, `thumb.png`, `meta` (time, size, saved path, recognised text), `source.png` + `doc` (to annotate again); private (0700/0600) |
| Thumbnails with the history off, dragged files | `$XDG_CACHE_HOME/shotlet/` (`quick/`, `drag/`) |
| GNOME Shell extension | `~/.local/share/gnome-shell/extensions/shotlet@midnattsol.github.io` |

The settings file is plain `key=value`. Shotlet only rewrites the keys it
changes, so editing it by hand while Shotlet runs is safe.

## Tests

```sh
zig build test --summary all   # unit tests (+ a portal test on a private dbus-daemon)
zig build e2e                  # end-to-end suite, see below
zig build e2e -- keyboard ime  # only some scenarios
```

The end-to-end suite runs the real binary against real portal dialogs,
PipeWire and the clipboard, inside a private, invisible GNOME session
(`tools/e2e/session.sh`: its own `HOME`, session bus, PipeWire and
`gnome-shell --headless` with virtual monitors). Nothing reaches the desktop
you are logged into. `shotlet-drive` (`tools/e2e/drive.zig`) holds a Mutter
RemoteDesktop session for a virtual keyboard and pointer, and ScreenCast
streams to aim the pointer and screenshot each monitor. `tools/e2e.sh`
prints PASS/FAIL per check and skips when the session cannot run.

Needs `gnome-shell`, `xdg-desktop-portal-gnome`, `pipewire`, `wireplumber`,
`wl-clipboard`, `python3` and `gdbus`; the IME scenario also uses
`ibus-hangul` (skipped without it), and the quick-access scenarios
(`quick`, `quick-plain`, `annotate`, `history`) use Python's GTK 4
bindings for "another app" (`tools/e2e/target.py`: focus, clicks, drops;
`python3-gi gir1.2-gtk-4.0`). They load the bundled GNOME Shell extension
into the private session (`HL_EXTENSIONS`), except `quick-plain`, which
checks the fallback without it. So do the prompt-free capture scenarios:
`shell` (stock bindings: install takes Print, Print captures with no
dialog and nothing in the permission store, the capture files gone and
no PNG written anywhere else, the pixels, a Capture() from another
program refused, uninstall restoring GNOME's keys), `shell-owner`
(a custom shortcut running shotlet on Print, moved and put back),
`shell-mixed` (two monitors at scales 2
and 1, checked across the seam), `shell-tray` (the tray's Activate and
menu, the rate limit) and `shell-terminal` (`shotlet` from a terminal,
and the portal when the extension cannot capture). The capture modes'
scenarios (`tools/e2e/modes.sh`) also run with the extension:
`modes-screen` (two monitors: the one under the pointer, all screens,
the previous area, each `after_fullscreen`), `modes-timer` (the countdown
on screen but not in the capture), `modes-window` (a 640x480 GTK window
captured at exactly its size with see-through corners, then with its
shadow), `modes-scroll` (a 3000 px GTK page scrolled and stitched to the
expected height, its marker band exactly once, scrolling in the editor),
`modes-scroll-manual` (the person scrolls, Stop ends it)
and `modes-keys` (per-mode shortcuts from the command line and Settings). The portal scenarios
run without the extension. On Debian/Ubuntu:
`apt install gnome-shell xdg-desktop-portal-gnome pipewire wireplumber wl-clipboard ibus-hangul python3-gi gir1.2-gtk-4.0`.
`E2E_OUT=dir` keeps the logs and screenshots of a run. CI runs the suite
nightly and on demand (`.github/workflows/e2e.yml`), never on pull requests.

```sh
zig build e2e-container                 # sway, labwc and KWin, in containers
zig build e2e-container -- labwc        # one compositor
zig build e2e-container -- kwin:pin     # one scenario
```

The container suite (`tools/container/`) covers what GNOME cannot: the
layer-shell thumbnail, pins and history panel on wlroots (sway, labwc) and
KWin; direct capture with no dialog (wlr-screencopy, KWin's ScreenShot2
authorized by Shotlet's installed desktop entry, never by KWin's
permission-check overrides), two outputs at mixed scales and rotated or
flipped outputs; the portal path (`xdg-desktop-portal-wlr` with direct
capture turned off by `SHOTLET_NO_DIRECT=1`, `xdg-desktop-portal-kde` when
Shotlet is not installed and KWin refuses it) with restore tokens; and the
text search with Tesseract (English and Spanish); `modes`: screen
capture without the editor and window capture (KWin's picker; an area on
wlroots). Scenarios count the
consent prompts: zero on the direct path. Shotlet is installed in each
container with `install.sh`. Each scenario runs in a throwaway
container (Debian trixie, `--rm`, no network) with its own session bus,
PipeWire and a headless compositor; nothing is installed on the host and
nothing reaches its display, bus or PipeWire. The image
(`shotlet-e2e:trixie`, about 1.5 GB) is built from
`tools/container/Containerfile` on first use; `docker rmi
shotlet-e2e:trixie` removes it. Docker or Podman is needed (without
either the suite skips).

`shotlet-wldrive` (`tools/container/wldrive.zig`) is the input driver:
wlroots' virtual pointer and keyboard plus screencopy, or KWin's fake input
plus its ScreenShot2 D-Bus interface, authorized like Shotlet by a desktop
entry. The wlroots portal's output chooser is a script that answers
without a dialog and logs each call; the KDE portal's dialog is clicked
through. A GPU render node (`/dev/dri/renderD*`, passed to the container
when the host has one, never a display node; `CTR_GPU=0` to not pass it)
is needed by `xdg-desktop-portal-wlr` (dmabuf-capable screencopy) and by
KWin (screenshots and screencasts only when compositing with OpenGL);
without one, the wlroots portal scenarios and KWin skip, and the rest,
direct capture on wlroots included, runs on software rendering. Debian
trixie's wlroots offers only wlr-screencopy; `Containerfile.sid` builds
`shotlet-e2e:sid` (sway on a newer wlroots) for the
ext-image-copy-capture path: `CTR_IMAGE=shotlet-e2e:sid
tools/container/run.sh sway:capture sway:multimon sway:rotated`. CI runs it nightly and on demand
(`.github/workflows/e2e-container.yml`).

## License

GPL-3.0 — see [LICENSE](LICENSE).

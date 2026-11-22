# Platform layer

Shotlet runs on Linux only today, but the code is split so that a Windows
or macOS port is a new directory under `src/platform/`, not a rewrite of
the editor. This note is the map: what is portable, what is not, the
seams between the two and how a backend is chosen.

## The rule

```
src/platform/linux/   everything that speaks Wayland, D-Bus, the portals,
                      PipeWire, GNOME Shell, KWin, wlroots or raw Linux
                      syscalls (the only place std.os.linux may appear)
src/platform/api/     the seams' platform-neutral types (input events,
                      key codes, layer placement, appearance, capture
                      results...): plain data, no OS code
src/platform/api.zig  the seam: picks the backend at compile time,
                      checks it implements the contract, re-exports it
src/platform/stub/    a do-nothing backend that only has to compile; used
                      by `zig build check-portable`, never shipped
everything else       the portable core
```

The core imports `platform/api.zig` (and `platform/api/*.zig` for types),
never a file under `platform/linux/` and never `std.os.linux`.
`zig build check-layers` enforces it (it runs with `zig build test`), and
`zig build check-portable` compiles the core for `x86_64-windows` and
`aarch64-macos` against the stub backend to prove it builds without Linux.

## Backend selection

- **Compile time, by OS.** `api.zig` switches on `builtin.os.tag`:
  `.linux` → `linux/backend.zig`; any other OS stops with
  `@compileError("shotlet: no platform backend for <os> yet ...")` at the
  seam. A build option (`-Dplatform-stub`, set only by `check-portable`)
  selects `stub/backend.zig` instead. The selected backend is a plain
  struct of declarations: no vtables, so drawing, input and the event loop
  cost exactly what they did when they called Wayland directly.
- **The contract is checked.** `api/contract.zig` lists every declaration
  the core may use, by seam; `api.zig` asserts at compile time that the
  backend has each one (a missing one is a compile error naming the seam
  and the declaration, not an error deep inside the editor).
- **Run time, among desktops.** Inside the Linux backend, as before: the
  GNOME Shell extension when active, KWin's ScreenShot2, wlroots
  screencopy, then the xdg-desktop-portal; PipeWire, libxkbcommon,
  fontconfig, Tesseract and the video libraries are dlopened when
  present. Runtime choice uses ordinary `switch`/`if` on detected
  capabilities (`linux/env` and friends); a vtable is used only where
  several implementations must coexist in one run (none needed so far).

## The seams

| Seam | What the core gets | Linux implementation |
| --- | --- | --- |
| **Window** (`Window`, `api/input.zig`) | software-rendered surfaces (one, or one per output), back buffers and present, input events (pointer, keys as evdev code + keysym + UTF-8, IME preedit), cursors, scale and outputs, layer placement (anchors, keyboard focus) for floating cards, move/maximize/minimize, input regions | `linux/window/` on the raw Wayland client (`linux/wayland/`), xdg-shell, wlr-layer-shell, text-input-v3, `linux/keyboard/` (dlopened libxkbcommon) |
| **Clipboard & drag-and-drop** (methods of `Window`) | own the clipboard (PNG, text, any mime list), read it, accept drops, drag a file out | `wl_data_device` in `linux/window/{clipboard,data_device,drag}.zig` |
| **Session** (`Session`, `desktop`) | a handle to the desktop session's services, opened once per process | the D-Bus session bus with the app's identity (`linux/portal/app_scope.zig`) |
| **Desktop integration** (`desktop`) | appearance (accent, dark, reduced motion, text scale) read and watched, notifications, "show in Files", file chooser (save as, pick a folder), parent handle for dialogs, tray, global shortcuts / shell integration status and install | Settings/FileChooser/Notification portals, FileManager1, StatusNotifierItem, the GNOME Shell extension (`linux/gnome/`), KWin (`linux/kde/`) |
| **Capture** (`capture`) | the frozen frame of every monitor, window frames for click-a-window, a window's own pixels, the capture path taken, permissions status and reset, frames and wheel for scrolling capture | the extension, KWin ScreenShot2, wlroots screencopy, ScreenCast + PipeWire, Screenshot portal with the first-run dialog, permission store (`linux/capture/`, `linux/pw/`, `linux/portal/`) |
| **Screen recording** (`record`) | a source of timed BGRA frames and sound for an area, start/pause/stop | the extension's recorder or a ScreenCast portal session, PipeWire streams |
| **OS services** (`sys`) | clocks, sleep, randomness, files and directories, fds/pipes/poll, local sockets (one-instance IPC), process spawn/daemonize, memory maps, env | raw syscalls (`linux/sys/`) |
| **Threads** (`sync`) | a mutex and an event usable from foreign threads | futexes |
| **Dynamic libraries & engines** (`libs`, `ocr`, `fonts`) | candidate file names of optional libraries (WebP, TurboJPEG, libav*, VA-API), OCR (`available`, `recognizeTsv`), font discovery | `lib<name>.so.<v>`, Tesseract, fontconfig and XDG font dirs |

Encoders (GIF, MP4 via libav or the ffmpeg program), the document model,
annotations, rendering, text shaping, OCR post-processing, redaction,
history, config, the command table, the quick-access and history UIs,
scroll stitching and the recording UI stay in the core and use only the
seams above.

## Where things live

| Before | After |
| --- | --- |
| `platform/{wayland,dbus,portal,pw,pwstream,permstore,sys}*` | `platform/linux/` (same names) |
| `platform/ocr.zig` | `platform/linux/tesseract.zig` |
| `ui/window.zig`, `ui/window/`, `ui/keyboard.zig`, `ui/keyboard/` | `platform/linux/window*`, `platform/linux/keyboard*` (keysyms: `platform/api/keysyms.zig`) |
| `ui/window.zig`'s `InputEvent`, `Key`, key codes, `Rect`, `Cursor`, `Layer` | `platform/api/input.zig` |
| `app/gnome*`, `app/gsettings.zig`, `app/accel.zig`, `app/shellcap.zig`, `app/modes/{shell_bus,gnome_keys}.zig`, `record/shellrec.zig` | `platform/linux/gnome/` |
| `app/direct_kwin.zig`, `app/winrects/kwin.zig` | `platform/linux/kde/` |
| `app/scroll/inject_wl.zig` | `platform/linux/wlroots/` |
| `app/direct*`, `app/first_run.zig`, `app/shot/screencast.zig`, `app/winrects.zig`, `app/modes/window_direct.zig`, `app/scroll/source.zig`, `app/capture_path.zig`, `app/permissions.zig`, `app/perms/` | `platform/linux/capture/` |
| `record/{portal_rec,source,engine,frames,audio,sync}.zig` | `platform/linux/record/` |
| `app/{tray*,daemon,filemanager}.zig`, appearance reading from `ui/theme.zig` | `platform/linux/desktop/` |
| `app/devtools.zig`, `src/testkit.zig`'s Linux parts | `platform/linux/` |

The table is the plan; `zig build check-layers` is the truth.

## Porting

A Windows or macOS backend is `src/platform/<os>/backend.zig` exporting
every declaration in `api/contract.zig`, plus one line in `api.zig`'s
switch. `stub/backend.zig` is the template: it has every declaration with
the right type and no behaviour. `zig build check-portable` already
proves the core compiles for both targets; a port makes the stub real.

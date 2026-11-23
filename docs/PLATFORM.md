# Platform layer

Shotlet runs on Linux only today, but the code is split so that a Windows
or macOS port is a new directory under `src/platform/`, not a rewrite of
the editor. This note is the map: what is portable, what is not, the
seams between the two and how a backend is chosen.

## The rule

```
src/platform/api.zig    the seam: picks the backend at compile time,
                        checks it against the contract, re-exports it
src/platform/api/       the seams' platform-neutral types (input events,
                        keys and buttons, floating-surface placement,
                        appearance, capture paths, recording frames...):
                        plain data the core defines
src/platform/stub/      the contract: every declaration the core may use,
                        with its type and no behaviour; compiled by
                        `zig build check-portable`, never shipped
src/platform/linux/     the Linux backend: everything that speaks Wayland,
                        D-Bus, the portals, PipeWire, GNOME Shell, KWin,
                        wlroots or raw syscalls (the only place
                        std.os.linux may appear)
everything else         the portable core
```

The core imports `platform/api.zig` (and `platform/api/*.zig` for types),
never a file under `platform/linux/`, never `std.os.linux`, never the raw
`api.backend`. Two build steps hold the line, both run by `zig build test`:

- `zig build check-layers` (tools/check-layers.sh) fails on any of those
  outside `src/platform/linux`, and on code there (not comments) that
  names Wayland or D-Bus, X keysyms or evdev codes (`KEY_*`, `BTN_*`),
  or holds a GTK accelerator (`<Super>`). Its allowlist (tools/layers-allowlist.txt)
  is empty and may only stay so. The e2e drivers' module root
  (`src/testkit.zig`, Linux tooling) is the one file that takes the Linux
  plumbing, through `api.backend.native`.
- `zig build check-portable` compiles the whole program and its tests
  for `x86_64-windows` and `aarch64-macos` against the stub backend
  (analysis only, nothing is emitted). It catches what text cannot, like
  `std.DynLib` (no Windows support in std) or `c_ulong` being 32 bits.

## Backend selection

- **Compile time, by OS.** `api.zig` switches on `builtin.os.tag`:
  `.linux` is `linux/backend.zig`; any other OS stops there with one
  error: `shotlet: no platform backend for windows yet. A port adds
  src/platform/windows/backend.zig ...` (try `zig build
  -Dtarget=x86_64-windows`). The `platform_options.stub` build option,
  set only by check-portable, selects `stub/backend.zig` instead.
- **Plain declarations, no vtables.** A backend is a struct of
  declarations; the core calls them directly, so drawing, input and the
  event loop cost what they did when they called Wayland directly.
  Backend types (`Window`, `desktop.Session`, `record.Stream`...) are
  used by value or pointer like any struct.
- **The contract is checked.** `api/contract.zig` asserts at compile time
  that the backend has every declaration the stub has, and every type
  there has the stub type's declarations and fields (a missing one is
  `platform contract: backend.window.Window.flush is missing from the
  backend`). The stub is the contract written down; check-portable
  proves the core uses nothing beyond it.
- **Run time, among Linux desktops: inside the backend**, as before. The
  GNOME Shell extension when it runs, the compositor directly (KWin's
  ScreenShot2, wlroots screencopy), then the ScreenCast portal over
  PipeWire, then the Screenshot portal; libpipewire, libxkbcommon,
  fontconfig, Tesseract and the video libraries are opened when present.
  Ordinary `if`s on detected capabilities, in `linux/capture.zig`,
  `linux/record.zig`, `linux/shell.zig`.

## The seams

Each is `api.<name>`; the stub file of the same name lists it in full.

| Seam | The core gets | Linux |
| --- | --- | --- |
| `window` | `Window`: one surface or one per output (`open`, `openOutputs`, `openOnOutputAt`), back buffers and `present*`, events (`nextEvent*`, `pollTimeoutMs`, `pollFd`, `flush`), cursors, input method (`setTextInput`, `preedit`), roles (move, maximize, minimize, the `maximized` and `tiled` states, input region and whether clicks pass outside it (`passesClicks`), geometry, title, floating-surface placement and keyboard), `parentHandle` for dialogs, `keyName`; clipboard (`setClipboard*`, `claimClipboardSource`, `serveClipboard`, `clipboardText`, `clipboardAccepted`) and drag and drop (`startDrag`, `accept_mimes`/`dropped`); `Surface`, `Output`. Types in `api/window.zig` and `api/keys.zig`: a key as `KeyCode` (the physical key) + the layout's character + UTF-8, `Button` | `linux/window/` on the raw Wayland client, `linux/keyboard/` (libxkbcommon; `evdev.zig` and `keysymChar` translate) |
| `desktop` | `Addresses` (where the session's services are, opaque: `Env.session`, `tag()`) and `addresses`, `Session` (`connect`, `connectBrief`, `identify`), appearance (`readAppearance`, `watchAppearance`, `pump`), file dialogs (`askSavePath`, `chooseFolder`, `dialogChoice`), `notify`, `revealFile`, `pollFd`/`hasPending`, the tray `daemon` | D-Bus session bus, Settings/FileChooser portals, Notifications, FileManager1, StatusNotifierItem |
| `shell` | the shell integration: `applies`, `active`, `activeNow`, `state`, `words` (how Settings names it), `install`, `captureInfo`, `note`, `requestCapture`, `loadHanded`, `place`, `finishPendingSetup`, `runCli`, the capture modes' global shortcuts by name, in `app/accel.zig`'s notation (`shortcutStore`, `getShortcut`, `setShortcut`, `setTimerSeconds`) | the Shotlet GNOME Shell extension (`linux/gnome/`; GTK's accelerators in `gnome/gtk_accel.zig`) |
| `capture` | `screens` (every monitor frozen, asking where needed), `warmup`, `windows`/`canCaptureWindow`/`captureWindow`, `ScrollSource`/`openScroll`/`scrollSupport` (whether a scrolling capture can run, asked before the region is picked), the capture `Path` (`remember`, `lastPath`), `resetPermissions`/`resetSummary`, `permissionsCli` | `linux/capture/` (direct, ScreenCast + PipeWire, Screenshot portal, first-run window, permission store), `linux/kde/`, `linux/wlroots/` |
| `record` | `open` a `Source` for an area (its `Stream`: `addVideo`, `addAudio`, `failed`, `videoFrames`, `close`), `shellHasControls`, `pickInShell`, `watchStop`, `pollStop`; frame types in `api/record.zig` | the extension's recorder or a ScreenCast session, PipeWire streams |
| `sys` | clocks, sleep, futex, randomness, files, directories, descriptors, pipes, `poll`, local sockets, mapped files, `isTerminal`, `processId` (POSIX-shaped: a port maps handles onto small integers) | raw syscalls (`linux/sys/`) |
| `proc` | programs with pipes (`spawn`, `output`, `which`), Shotlet itself detached (`spawnSelf`), `processEnv`, `hwEncodeDevices` | fork/exec, `/proc/self/exe`, VA-API render nodes |
| `libs` | optional libraries by base name and version (`open`, `Lib.lookup`) | `lib<name>.so.<v>` with `std.DynLib` |
| `fonts` | `Db`: the UI faces and a face for a codepoint | fontconfig, else the XDG font directories |
| `ocr` | `available`, `recognize`, `recognizeTsv` | Tesseract (`src/ocr/tesseract.zig`, portable code over `libs`) |
| `devtools` | `shotlet test-window` and friends | Wayland/portal/PipeWire probes |

The core keeps: the editor, the document model and annotations, gfx
(rendering, text shaping, codecs), the encoders (GIF; MP4 through libav
or the ffmpeg program, which go through `libs` and `proc`), OCR
post-processing and search, redaction, history, config, the command
table, the quick-access, history, pin, settings and recording UIs,
scroll stitching, the recording engine (timeline, frames, sound mixing),
and the capture flow around them (`app/shot.zig` asks the shell, then
`capture.screens`).

What the core says in its own terms, and each backend translates:

- **Keys.** `api/keys.zig`'s `KeyCode` names a physical key by its place
  on a US keyboard (`.q` is the key left of W on any layout); a key event
  also carries `char`, the character it stands for in the active layout
  (Shift and Caps Lock applied, not Ctrl), and the text it types. Letter
  shortcuts that follow the layout (Settings' Q, the scrolling capture's
  C, global shortcuts) use `char`; the editor's binds and the mode
  strip's letters use the physical key. Linux maps evdev codes in
  `linux/keyboard/evdev.zig` and keysyms in `keysymChar`.
- **Shortcuts.** `app/accel.zig`: "Shift+Super+S" (modifiers Ctrl, Shift,
  Alt, Super, then `KeyCode.name`). The shell seam takes and gives that
  notation; GNOME's settings keep GTK's ("<Shift><Super>s"), converted in
  `linux/gnome/gtk_accel.zig`. The editor's binds are written as
  `shortcut_<action>=Ctrl+F`; a config file's older
  `bind_<action>=ctrl+33` (evdev numbers, `app/config/legacy_keys.zig`)
  still loads and is rewritten at the next save.
- **The session.** `Env.session` is the backend's `desktop.Addresses`
  (Linux: the D-Bus session bus and the Wayland display), handed back
  through `Env` (`Window.init(gpa, env)`); per-session sockets use its
  `tag()`.
- **The integration's name.** `shell.words()`: what Settings calls the
  integration, what gets installed, the command that manages it, the
  desktop's screenshot key and where to bind a key to a command.

Still Linux-flavoured in the core: the `gnome-integration` command and
its help (`cli/cmds_more.zig`, dispatched to `shell.runCli`), and a few
messages outside the Settings window (the thumbnail's hint, the
recording picker's tooltips, log lines) that name GNOME.

## Where things moved

| Before | After |
| --- | --- |
| `platform/{wayland,dbus,portal,pw,pwstream,permstore,sys}*`, `portal_test.zig` | `platform/linux/` (same names) |
| `ui/window*`, `ui/keyboard*` | `platform/linux/window*`, `platform/linux/keyboard*` (types: `api/window.zig`) |
| `platform/ocr.zig` | `ocr/tesseract.zig` (+ `ocr/search.zig`, `ocr/spinlock.zig`) |
| `gfx/fontdb.zig` | `platform/linux/fonts.zig` (types: `api/fonts.zig`) |
| `encode/proc.zig` | `platform/linux/proc.zig` |
| `app/gnome*`, `gnome_bundle.zig`, `gsettings.zig`, `shellcap.zig`, `modes/{shell_bus,gnome_keys}.zig`, `record/shellrec.zig` | `platform/linux/gnome/` |
| `app/direct_kwin.zig`, `app/winrects/kwin.zig` | `platform/linux/kde/{screenshot2,winrects}.zig` |
| `app/scroll/inject_wl.zig` | `platform/linux/wlroots/inject.zig` |
| `app/{direct*,first_run,winrects,capture_path,permissions}.zig`, `app/perms/`, `app/shot/screencast.zig`, `app/modes/window_direct.zig`, `app/scroll/source.zig` | `platform/linux/capture/` |
| `record/{portal_rec,source}.zig` | `platform/linux/record/` |
| `app/{tray*,daemon,filemanager}.zig`, `app/shot/dialog.zig`, the Settings portal half of `ui/theme.zig`, the bus address from `main.zig` | `platform/linux/desktop/` |
| `app/devtools.zig` | `platform/linux/devtools.zig` |

## Porting

A Windows or macOS backend is `src/platform/<os>/backend.zig` exporting
every declaration of `stub/backend.zig`, plus one line in `api.zig`'s
switch. Copy the stub and make it real, seam by seam; the contract check
names whatever is still missing, and the build already knows the core
compiles for the target (`zig build check-portable`). The behaviour a
declaration must have is in the stub's doc comments and, in full, in the
Linux implementation it mirrors (`linux/window.zig` describes surfaces,
events and the input method; `linux/capture.zig` the capture chain).

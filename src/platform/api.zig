//! The seam between the portable core and the platform backend (see
//! docs/PLATFORM.md). The core reaches the operating system and the
//! desktop only through the declarations re-exported here; their
//! platform-neutral types live in api/.
//!
//! The backend is picked at compile time by the target OS, and checked
//! against the contract (api/contract.zig) so a missing piece is reported
//! here, by name, instead of deep inside the editor. No vtables: the core
//! calls the backend's functions directly.

const builtin = @import("builtin");
const options = @import("platform_options");
const contract = @import("api/contract.zig");

/// The selected backend: Linux, or the compile-only stub that
/// `zig build check-portable` builds the core against.
pub const backend = if (options.stub) @import("stub/backend.zig") else switch (builtin.os.tag) {
    .linux => @import("linux/backend.zig"),
    else => @compileError("shotlet: no platform backend for " ++ @tagName(builtin.os.tag) ++
        " yet. A port adds src/platform/" ++ @tagName(builtin.os.tag) ++
        "/backend.zig implementing src/platform/stub/backend.zig's declarations (docs/PLATFORM.md)."),
};

comptime {
    contract.check(backend);
}

/// Clocks, files, directories, pipes and local sockets.
pub const sys = backend.sys;

/// Windows: surfaces, input, cursors, outputs, clipboard and drag and
/// drop (`Window`), with the neutral types of api/window.zig.
pub const window = backend.window;

/// Child processes: programs with pipes (ffmpeg), Shotlet itself
/// detached, hardware encode devices.
pub const proc = backend.proc;

/// The desktop session: appearance, file dialogs, notifications, "show
/// in Files" (`Session`, with the neutral types of api/desktop.zig).
pub const desktop = backend.desktop;

/// The shell integration (Linux: the GNOME Shell extension): captures
/// without prompts, global shortcuts, keeping floating windows above.
pub const shell = backend.shell;

/// Screen capture: every monitor frozen, window frames, window capture,
/// scrolling-capture frames, permissions.
pub const capture = backend.capture;

/// Screen recording: the source of an area's pictures and sound, the
/// shell's own controls.
pub const record = backend.record;

/// Development commands of the backend (`shotlet test-window` ...);
/// false when `cmd` is none of them.
pub const devtools = backend.devtools;

/// Font discovery: the UI faces and a face for a codepoint (api/fonts.zig).
pub const fonts = backend.fonts;

/// Text recognition: available, recognize, recognizeTsv (Linux:
/// Tesseract, src/ocr/tesseract.zig).
pub const ocr = backend.ocr;

/// Optional shared libraries opened at run time (image codecs, libav*).
pub const libs = backend.libs;

test {
    _ = backend;
    _ = contract;
}

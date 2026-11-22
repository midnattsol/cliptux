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

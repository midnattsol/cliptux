//! Minimal PNG codec: enough to decode portal screenshots and other common
//! PNGs (gray/RGB/palette/gray+alpha/RGBA at 1-16 bits, tRNS,
//! plain or Adam7 interlaced) and encode annotated output (8-bit RGB). Pixels are
//! exchanged as 0xAARRGGBB u32 values (matching wl_shm xrgb8888 layout on
//! little-endian).
//!
//! The decoder treats its input as untrusted: chunk lengths, IHDR fields
//! and the decompressed size are all bounded before anything is allocated.
//! The encoder picks a filter per row (minimum sum of absolute
//! differences) and, for large images, deflates bands of rows on several
//! threads, joining them into one zlib stream.

const dec = @import("png/decode.zig");
const enc = @import("png/encode.zig");

pub const Image = dec.Image;
pub const max_side = dec.max_side;
pub const max_pixels = dec.max_pixels;
pub const decode = dec.decode;

pub const EncodeOptions = enc.EncodeOptions;
pub const encode = enc.encode;
pub const encodeWith = enc.encodeWith;

comptime {
    _ = @import("png/chunks.zig");
    _ = @import("png/filters.zig");
    _ = @import("png/decode.zig");
    _ = @import("png/bands.zig");
    _ = @import("png/encode.zig");
    _ = @import("png/testing.zig");
}

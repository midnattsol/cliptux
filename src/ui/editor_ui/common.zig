//! Small helpers shared by the editor chrome's modules.

/// An integer as f64.
pub fn ff(v: i32) f64 {
    return @floatFromInt(v);
}

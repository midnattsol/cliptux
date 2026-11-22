//! The platform contract, checked at compile time: a backend must have
//! every declaration the stub backend (src/platform/stub/backend.zig)
//! has, and every type there must have the same declarations and fields.
//! The stub is the contract written down: each declaration with the type
//! the core uses and no behaviour; `zig build check-portable` compiles the
//! core against it for Windows and macOS, so the core cannot use anything
//! the stub (and so the contract) leaves out.

const std = @import("std");
const stub = @import("../stub/backend.zig");

/// Fail the build unless `Backend` has everything the contract names.
pub fn check(comptime Backend: type) void {
    if (Backend == stub) return;
    @setEvalBranchQuota(200_000);
    checkType(stub, Backend, "backend");
}

fn checkType(comptime Want: type, comptime Have: type, comptime path: []const u8) void {
    if (@typeInfo(Want) == .@"struct") {
        inline for (std.meta.fieldNames(Want)) |f| if (!hasMember(Have, f))
            @compileError("platform contract: " ++ path ++ "." ++ f ++ " (a field) is missing from the backend");
    }
    if (!hasDecls(Want)) return;
    inline for (std.meta.declarations(Want)) |d| {
        if (!hasMember(Have, d))
            @compileError("platform contract: " ++ path ++ "." ++ d ++ " is missing from the backend");
        const w = @field(Want, d);
        // shared types (from api/) are the same type on both sides
        if (@TypeOf(w) == type and hasDecls(w) and w != @field(Have, d))
            checkType(w, @field(Have, d), path ++ "." ++ d);
    }
}

fn hasDecls(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
}

fn hasMember(comptime T: type, comptime name: []const u8) bool {
    if (!hasDecls(T)) return false;
    if (@hasDecl(T, name)) return true;
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum" => @hasField(T, name),
        else => false,
    };
}

test "the stub satisfies itself and a missing declaration is caught" {
    comptime check(stub);
    const Partial = struct {
        pub const sys = struct {};
    };
    try std.testing.expect(!hasMember(Partial.sys, "monoMs"));
    try std.testing.expect(hasMember(stub.sys, "monoMs"));
}

//! Sensitive-data detectors: what they must find and what they must leave.

const std = @import("std");
const detect = @import("detect.zig");
const Kind = detect.Kind;

fn expectFinds(text: []const u8, want: []const struct { []const u8, Kind }) !void {
    const got = try detect.find(std.testing.allocator, text);
    defer std.testing.allocator.free(got);
    if (got.len != want.len) {
        std.debug.print("in \"{s}\": found {d}, want {d}\n", .{ text, got.len, want.len });
        for (got) |m| std.debug.print("  {t}: \"{s}\"\n", .{ m.kind, text[m.start..m.end] });
        return error.TestUnexpectedResult;
    }
    for (got, want) |m, w| {
        try std.testing.expectEqualStrings(w[0], text[m.start..m.end]);
        try std.testing.expectEqual(w[1], m.kind);
    }
}

fn expectNone(text: []const u8) !void {
    return expectFinds(text, &.{});
}

test "e-mail addresses" {
    try expectFinds("Write to jane.doe+news@mail.example.co.uk today.", &.{.{ "jane.doe+news@mail.example.co.uk", .email }});
    try expectFinds("(ops@corp.io)", &.{.{ "ops@corp.io", .email }});
    try expectNone("user@localhost or @handle or a@b.c");
}

test "card numbers pass Luhn" {
    try expectFinds("Card: 4111 1111 1111 1111 exp 12/29", &.{.{ "4111 1111 1111 1111", .card }});
    try expectFinds("5500-0000-0000-0004", &.{.{ "5500-0000-0000-0004", .card }});
    try expectFinds("378282246310005", &.{.{ "378282246310005", .card }});
    // a long number failing the check is no card (nor a phone)
    try expectNone("order 4111 1111 1111 1112");
    try std.testing.expect(detect.luhn("79927398713"));
    try std.testing.expect(!detect.luhn("79927398710"));
}

test "IBANs pass mod 97" {
    try expectFinds("IBAN: GB82 WEST 1234 5698 7654 32.", &.{.{ "GB82 WEST 1234 5698 7654 32", .iban }});
    try expectFinds("ES9121000418450200051332", &.{.{ "ES9121000418450200051332", .iban }});
    try expectNone("GB82 WEST 1234 5698 7654 33");
    try std.testing.expect(detect.ibanValid("DE89370400440532013000"));
    try std.testing.expect(!detect.ibanValid("DE89370400440532013001"));
}

test "phone numbers" {
    try expectFinds("Call +34 612 345 678 now", &.{.{ "+34 612 345 678", .phone }});
    try expectFinds("Tel. (555) 123-4567", &.{.{ "(555) 123-4567", .phone }});
    try expectFinds("+1-202-555-0143", &.{.{ "+1-202-555-0143", .phone }});
    try expectNone("on 2026-11-21 at 10:30, version 1.2.3, 42 items, 1600 x 900");
    try expectNone("build 12345");
}

test "IP addresses" {
    try expectFinds("server 192.168.1.20 and 10.0.0.1:8080", &.{ .{ "192.168.1.20", .ip }, .{ "10.0.0.1", .ip } });
    try expectFinds("addr fe80::1ff:fe23:4567:890a here", &.{.{ "fe80::1ff:fe23:4567:890a", .ip }});
    try expectNone("version 1.2.3.4.5 and 300.1.1.1 and 3.14");
}

test "tokens: JWTs, known prefixes and random-looking strings" {
    try expectFinds("Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U", &.{.{ "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U", .jwt }});
    try expectFinds("key sk-proj-a8F3kL0qZ9xY2mN7 done", &.{.{ "sk-proj-a8F3kL0qZ9xY2mN7", .api_key }});
    try expectFinds("ghp_16C7e42F292c6912E7710c838347Ae178B4a", &.{.{ "ghp_16C7e42F292c6912E7710c838347Ae178B4a", .api_key }});
    try expectFinds("AKIAIOSFODNN7EXAMPLE", &.{.{ "AKIAIOSFODNN7EXAMPLE", .api_key }});
    try expectFinds("secret=Zx81qPn4Lr7Vb2Kt9Wy3Hc6Jd0Fg5Ms", &.{.{ "Zx81qPn4Lr7Vb2Kt9Wy3Hc6Jd0Fg5Ms", .token }});
    // long words and identifiers are not random
    try expectNone("internationalization_and_localization counterrevolutionaries");
    try expectNone("getElementsByTagNameAndClassName2");
    try expectNone("sk-short ghp_ x AKIA");
}

test "entropy" {
    try std.testing.expectApproxEqAbs(@as(f64, 0), detect.entropy("aaaa"), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2), detect.entropy("abcd"), 1e-9);
    try std.testing.expect(detect.entropy("Zx81qPn4Lr7Vb2Kt9Wy3Hc6Jd0Fg5Ms") > 4.0);
}

test "a sentence with several kinds, in order" {
    try expectFinds("Mail bob@x.org from 8.8.8.8 with 4242424242424242.", &.{ .{ "bob@x.org", .email }, .{ "8.8.8.8", .ip }, .{ "4242424242424242", .card } });
}

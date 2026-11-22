//! Native DBus client: speaks the wire protocol directly over the session bus
//! unix socket. No libdbus. Little-endian only (x86_64/aarch64 linux).
//!
//! Facade over dbus/: address (bus address lists), marshal (body builder),
//! reader (unmarshalling), message (model and headers), auth (SASL),
//! transport (framing and fd passing) and connection.

const address = @import("dbus/address.zig");
const marshal = @import("dbus/marshal.zig");
const reader = @import("dbus/reader.zig");
const message = @import("dbus/message.zig");
const transport = @import("dbus/transport.zig");
const connection = @import("dbus/connection.zig");

pub const MessageType = message.MessageType;
pub const Message = message.Message;
pub const Marshal = marshal.Marshal;
pub const Value = reader.Value;
pub const Reader = reader.Reader;
pub const Address = address.Address;
pub const parseAddresses = address.parseAddresses;
pub const isFatal = transport.isFatal;
pub const default_reply_timeout_ms = transport.default_reply_timeout_ms;
pub const Connection = connection.Connection;

comptime {
    _ = address;
    _ = marshal;
    _ = reader;
    _ = message;
    _ = @import("dbus/auth.zig");
    _ = transport;
    _ = connection;
}

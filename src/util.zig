const std = @import("std");

/// Formats a byte slice as printable ASCII, replacing bytes outside the
/// printable ASCII range (0x20–0x7e) with \xNN escape sequences.
/// Use with the `{f}` format specifier, not `{s}`.
///
/// Example:
///   std.log.info("host={f}", .{escapedStr(hostname)});
pub const EscapedStr = struct {
    bytes: []const u8,

    pub fn format(self: EscapedStr, writer: anytype) !void {
        for (self.bytes) |b| {
            if (b >= 0x20 and b <= 0x7e) {
                try writer.writeByte(b);
            } else {
                try writer.print("\\x{x:0>2}", .{b});
            }
        }
    }
};

pub fn escapedStr(bytes: []const u8) EscapedStr {
    return .{ .bytes = bytes };
}

test "EscapedStr: printable ASCII passes through unchanged" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try escapedStr("hello world").format(stream.writer());
    try std.testing.expectEqualStrings("hello world", stream.getWritten());
}

test "EscapedStr: non-printable bytes are escaped" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try escapedStr("\x00\x01\x7f").format(stream.writer());
    try std.testing.expectEqualStrings("\\x00\\x01\\x7f", stream.getWritten());
}

test "EscapedStr: mixed printable and non-printable" {
    var buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try escapedStr("host\x00name").format(stream.writer());
    try std.testing.expectEqualStrings("host\\x00name", stream.getWritten());
}

test "EscapedStr: empty slice produces empty output" {
    var buf: [8]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try escapedStr("").format(stream.writer());
    try std.testing.expectEqualStrings("", stream.getWritten());
}

//! Encoder for gesture reporting mode (DEC private mode 2035): trackpad
//! gestures delivered to the application as `CSI < type ; fingers ;
//! phase ; x ; y ; mag G`. The protocol is defined in
//! PROTOCOL-GESTURES.md of the companion tmux fork
//! (github.com/pszypowicz/tmux).

const std = @import("std");
const point = @import("../terminal/point.zig");
const Binding = @import("Binding.zig");

/// A discrete gesture event for protocol encoding. Version 0 of the
/// protocol only carries discrete events: continuous gestures (pinch)
/// are stepped by the caller and every step is one event.
pub const Event = struct {
    /// The discrete gesture trigger being reported.
    gesture: Binding.Gesture,

    /// Number of fingers, 0 if not applicable.
    fingers: u8 = 0,

    /// Viewport cell under the pointer. Encoded 1-based per the SGR
    /// mouse convention; null encodes as `0;0` (unknown).
    cell: ?point.Coordinate = null,

    /// Signed magnitude: pinch steps (negative in, positive out), 0
    /// for gestures without one. The gesture field alone identifies
    /// pinch direction; the magnitude is redundant for single steps
    /// but carries multi-step batches.
    mag: i32 = 0,

    /// The wire `type` parameter.
    fn typeCode(self: Event) u8 {
        return switch (self.gesture) {
            .@"swipe-left" => 1,
            .@"swipe-right" => 2,
            .@"swipe-up" => 3,
            .@"swipe-down" => 4,
            .@"pinch-in", .@"pinch-out" => 5,
            .@"smart-magnify" => 6,
        };
    }
};

/// Encode the gesture event to the writer. The caller is responsible
/// for gating on the gesture_report terminal mode; this function
/// always produces output.
pub fn encode(
    writer: *std.Io.Writer,
    event: Event,
) std.Io.Writer.Error!void {
    const x: u32, const y: u32 = if (event.cell) |c|
        .{ @as(u32, c.x) + 1, c.y + 1 }
    else
        .{ 0, 0 };

    // The phase parameter is always 0 (discrete) in protocol v0.
    try writer.print(
        "\x1B[<{d};{d};0;{d};{d};{d}G",
        .{ event.typeCode(), event.fingers, x, y, event.mag },
    );
}

test "gesture_encode: discrete swipe with cell" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer, .{
        .gesture = .@"swipe-left",
        .fingers = 2,
        .cell = .{ .x = 4, .y = 9 },
    });
    try std.testing.expectEqualStrings("\x1B[<1;2;0;5;10;0G", writer.buffered());
}

test "gesture_encode: unknown cell encodes 0;0" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer, .{ .gesture = .@"smart-magnify", .fingers = 2 });
    try std.testing.expectEqualStrings("\x1B[<6;2;0;0;0;0G", writer.buffered());
}

test "gesture_encode: pinch steps carry signed magnitude" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer, .{ .gesture = .@"pinch-in", .fingers = 2, .mag = -1 });
    try std.testing.expectEqualStrings("\x1B[<5;2;0;0;0;-1G", writer.buffered());

    var writer2: std.Io.Writer = .fixed(&buf);
    try encode(&writer2, .{ .gesture = .@"pinch-out", .fingers = 2, .mag = 1 });
    try std.testing.expectEqualStrings("\x1B[<5;2;0;0;0;1G", writer2.buffered());
}

test "gesture_encode: all swipe directions map to distinct types" {
    const cases = [_]struct { g: Binding.Gesture, t: u8 }{
        .{ .g = .@"swipe-left", .t = 1 },
        .{ .g = .@"swipe-right", .t = 2 },
        .{ .g = .@"swipe-up", .t = 3 },
        .{ .g = .@"swipe-down", .t = 4 },
    };
    for (cases) |case| {
        var buf: [64]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try encode(&writer, .{ .gesture = case.g, .fingers = 3 });
        var expected: [64]u8 = undefined;
        const exp = try std.mem.print(
            &expected,
            "\x1B[<{d};3;0;0;0;0G",
            .{case.t},
        );
        try std.testing.expectEqualStrings(exp, writer.buffered());
    }
}

test "gesture_encode: worst case fits WriteReq.Small" {
    // termio.Message.WriteReq.Small holds 38 bytes, and a sequence with
    // large cell coordinates and a multi-digit magnitude must still fit.
    // termio is not imported here to avoid a cycle, so the limit is
    // hardcoded. An oversized sequence would fail to encode, and
    // Surface.gestureReport would log that and drop it.
    var buf: [38]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer, .{
        .gesture = .@"pinch-out",
        .fingers = 4,
        .cell = .{ .x = 9998, .y = 99998 },
        .mag = -12345,
    });
    try std.testing.expect(writer.buffered().len <= 38);
}

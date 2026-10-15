const std = @import("std");

pub const frame_length = 36;
pub const addresses = [_]u7{ 0x37, 0x38, 0x39, 0x3a };

// Physical electrode order E1..E8 to CY8CMBR3108 CS channel.
pub const electrode_to_sensor = [_]u3{ 3, 2, 7, 6, 4, 5, 0, 1 };

pub fn encode(sequence: u8, buttons: u7, boards: [4]?[8]u8) [frame_length]u8 {
    std.debug.assert(sequence < 0xff);

    var frame: [frame_length]u8 = @splat(0);
    frame[0] = 0xff;
    frame[1] = sequence;
    frame[3] = buttons;

    for (boards, 0..) |maybe_counts, board_index| {
        if (maybe_counts) |counts| {
            frame[2] |= @as(u8, 1) << @intCast(board_index);
            for (electrode_to_sensor, 0..) |sensor, electrode_index| {
                frame[4 + board_index * 8 + electrode_index] = @min(counts[sensor], 0xfe);
            }
        }
    }
    return frame;
}

test "frame order, invalid boards, and reserved SYNC byte" {
    const counts = [8]u8{ 0, 1, 2, 3, 4, 5, 6, 255 };
    const frame = encode(0xfe, 0x7f, .{ counts, null, null, null });

    try std.testing.expectEqual(@as(usize, 36), frame.len);
    try std.testing.expectEqual(@as(u8, 0xff), frame[0]);
    try std.testing.expectEqual(@as(u8, 0xfe), frame[1]);
    try std.testing.expectEqual(@as(u8, 0x01), frame[2]);
    try std.testing.expectEqual(@as(u8, 0x7f), frame[3]);
    try std.testing.expectEqualSlices(u8, &.{ 3, 2, 0xfe, 6, 4, 5, 0, 1 }, frame[4..12]);
    for (frame[12..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

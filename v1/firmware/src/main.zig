const microzig = @import("microzig");
const hal = microzig.hal;
const usb = microzig.core.usb;
const Device = @import("Cy8cmbr3108.zig");
const protocol = @import("protocol.zig");
const i2c = hal.i2c.instance.I2C1;

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

const pins = hal.pins.GlobalConfiguration{
    .GPIO26 = .{ .function = .I2C1_SDA, .pull = .up },
    .GPIO27 = .{ .function = .I2C1_SCL, .pull = .up },
};

pub fn main() void {
    _ = pins.apply();
    i2c.apply(.{ .clock_config = hal.clock_config, .baud_rate = 400_000 });

    var port: UsbPort = .{};
    port.init();

    var next_slot = nowUs();
    var sequence: u8 = 0;
    while (true) {
        port.poll();
        const now = nowUs();
        if (now < next_slot) continue;

        const missed_slots = (now - next_slot) / frame_period_us;
        next_slot += (missed_slots + 1) * frame_period_us;
        sequence = @intCast((@as(u64, sequence) + missed_slots) % 255);

        var boards: [4]?[8]u8 = .{ null, null, null, null };
        for (protocol.addresses, 0..) |address, board| {
            boards[board] = Device.readDifferenceCounts(address) catch null;
            port.poll();
        }

        // Buttons are not connected yet, so all seven button bits are zero.
        const frame = protocol.encode(sequence, 0, boards);
        _ = port.trySendPacket(&frame);
        sequence = if (sequence == 254) 0 else sequence + 1;
    }
}

const usb_config: usb.Config = .{
    .bcd_usb = .v1_10,
    .device_triple = .unspecified,
    .vendor = .{ .id = 0x2e8a, .str = "Raspberry Pi" },
    .product = .{ .id = 0x000a, .str = "XLAIR-controller_V1" },
    .bcd_device = .from(1, 0),
    .serial = "controller-v1",
    .max_supported_packet_size = 64,
    .configurations = &.{.{
        .attributes = .{ .self_powered = false },
        .max_current_ma = 100,
        .Drivers = struct { cdc: usb.drivers.CDC },
    }},
};

const UsbPort = @import("usb_cdc.zig").Port(usb_config);

const frame_period_us: u64 = 5_000;

fn nowUs() u64 {
    return @backingInt(hal.time.get_time_since_boot());
}

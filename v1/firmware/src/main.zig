const microzig = @import("microzig");
const hal = microzig.hal;
const usb = microzig.core.usb;
const Device = @import("Cy8cmbr3108.zig");
const sensitivity = @import("build_options").sensitivity;
const protocol = @import("protocol.zig");
const i2c = hal.i2c.instance.I2C1;

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

const pins = hal.pins.GlobalConfiguration{
    .GPIO21 = .{ .name = "side_button_0", .direction = .in, .pull = .up },
    .GPIO20 = .{ .name = "side_button_1", .direction = .in, .pull = .up },
    .GPIO19 = .{ .name = "side_button_2", .direction = .in, .pull = .up },
    .GPIO18 = .{ .name = "side_button_3", .direction = .in, .pull = .up },
    .GPIO26 = .{ .function = .I2C1_SDA, .pull = .up },
    .GPIO27 = .{ .function = .I2C1_SCL, .pull = .up },
};

pub fn main() void {
    const gpio = pins.apply();
    i2c.apply(.{ .clock_config = hal.clock_config, .baud_rate = 400_000 });

    port.init();

    // The IC may NACK until its I2C interface is ready after power-up.
    sleepWithUsbPoll(20);
    var board_states: [protocol.addresses.len]BoardState = @splat(.{});
    for (protocol.addresses, 0..) |address, board| {
        board_states[board].tryInitialize(address);
        port.poll();
    }

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
            if (board_states[board].ready) boards[board] = Device.readDifferenceCounts(address) catch null;
            port.poll();
        }

        var buttons: u7 = 0;
        if (gpio.side_button_0.read() == 0) buttons |= 1 << 0;
        if (gpio.side_button_1.read() == 0) buttons |= 1 << 1;
        if (gpio.side_button_2.read() == 0) buttons |= 1 << 2;
        if (gpio.side_button_3.read() == 0) buttons |= 1 << 3;
        const frame = protocol.encode(sequence, buttons, boards);
        _ = port.trySendPacket(&frame);
        sequence = if (sequence == 254) 0 else sequence + 1;

        // Retry one unavailable board after sending the current frame.
        for (protocol.addresses, 0..) |address, board| {
            const state = &board_states[board];
            if (state.ready or nowUs() < state.retry_at_us) continue;
            state.tryInitialize(address);
            break;
        }
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
var port: UsbPort = .{};

const frame_period_us: u64 = 5_000;
const init_retry_period_us: u64 = 1_000_000;

const BoardState = struct {
    ready: bool = false,
    retry_at_us: u64 = 0,

    fn tryInitialize(self: *@This(), address: u7) void {
        var device = Device.init(address, sleepWithUsbPoll);
        self.ready = if (device.ensureRuntimeConfiguration(sensitivity)) |_| true else |_| false;
        self.retry_at_us = nowUs() + init_retry_period_us;
    }
};

fn sleepWithUsbPoll(ms: u32) void {
    const deadline = hal.time.deadline_in_ms(ms);
    while (!deadline.is_reached_by(hal.time.get_time_since_boot())) port.poll();
}

fn nowUs() u64 {
    return @backingInt(hal.time.get_time_since_boot());
}

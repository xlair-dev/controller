const std = @import("std");
const microzig = @import("microzig");
const hal = microzig.hal;
const usb = microzig.core.usb;
const Device = @import("Cy8cmbr3108.zig");
const i2c = hal.i2c.instance.I2C1;

pub const panic = microzig.panic;
pub const std_options = microzig.std_options(.{});

comptime {
    _ = microzig.export_startup();
}

// Pico physical pins 31 (SDA) and 32 (SCL).
const pins = hal.pins.GlobalConfiguration{
    .GPIO26 = .{ .function = .I2C1_SDA, .pull = .up },
    .GPIO27 = .{ .function = .I2C1_SCL, .pull = .up },
};

pub fn main() void {
    _ = pins.apply();
    i2c.apply(.{ .clock_config = hal.clock_config, .baud_rate = 100_000 });
    console.port.init();

    const connect_deadline = hal.time.deadline_in_ms(3000);
    while (!console.port.configured() and !connect_deadline.is_reached_by(hal.time.get_time_since_boot())) {
        console.port.poll();
    }
    sleepPolling(&console, 400);
    console.write("CY8CMBR3108 address setup\r\n") catch {};

    var session: AddressSetupSession = .{ .console = &console };
    session.scan() catch {};
    while (true) {
        if (console.readByte()) |byte| session.onByte(byte) catch {};
    }
}

const usb_config: usb.Config = .{
    .bcd_usb = .v1_10,
    .device_triple = .unspecified,
    .vendor = .{ .id = 0x2e8a, .str = "Raspberry Pi" },
    .product = .{ .id = 0x000a, .str = "XLAIR-controller_V1_setup" },
    .bcd_device = .from(1, 0),
    .serial = "controller-v1-setup",
    .max_supported_packet_size = 64,
    .configurations = &.{
        .{
            .attributes = .{ .self_powered = false },
            .max_current_ma = 100,
            .Drivers = struct { cdc: usb.drivers.CDC },
        },
    },
};

const UsbPort = @import("usb_cdc.zig").Port(usb_config);

const Console = struct {
    const Self = @This();

    port: UsbPort = .{},

    fn readByte(self: *Self) ?u8 {
        self.port.poll();
        var byte: [1]u8 = undefined;
        return if (self.port.read(&byte) == 1) byte[0] else null;
    }

    fn write(self: *Self, bytes: []const u8) std.Io.Writer.Error!void {
        if (bytes.len == 0) return;
        const deadline = hal.time.deadline_in_ms(100);
        var remaining = bytes;
        while (remaining.len > 0) {
            if (deadline.is_reached_by(hal.time.get_time_since_boot())) return error.WriteFailed;
            self.port.poll();
            if (!self.port.configured()) return error.WriteFailed;
            const sent = self.port.write(remaining);
            remaining = remaining[sent..];
            if (sent > 0 and !self.flushUntil(deadline)) return error.WriteFailed;
        }
    }

    fn flushUntil(self: *Self, deadline: microzig.drivers.time.Deadline) bool {
        while (!deadline.is_reached_by(hal.time.get_time_since_boot())) {
            self.port.poll();
            if (self.port.flush()) return true;
            if (!self.port.configured()) return false;
        }
        return false;
    }

    const PrintWriter = struct {
        console: *Self,
        writer: std.Io.Writer,

        fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *PrintWriter = @alignCast(@fieldParentPtr("writer", writer));
            try self.console.write(writer.buffered());
            writer.end = 0;

            for (data[0 .. data.len - 1]) |bytes| try self.console.write(bytes);
            const repeated = data[data.len - 1];
            for (0..splat) |_| try self.console.write(repeated);
            return std.Io.Writer.countSplat(data, splat);
        }
    };

    fn print(self: *Self, comptime fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
        var buffer: [64]u8 = undefined;
        var output: PrintWriter = .{
            .console = self,
            .writer = .{ .vtable = &.{ .drain = PrintWriter.drain }, .buffer = &buffer },
        };
        try output.writer.print(fmt, args);
        try output.writer.flush();
    }
};

var console: Console = .{};

fn sleepPolling(console_: *Console, ms: u32) void {
    const deadline = hal.time.deadline_in_ms(ms);
    while (!deadline.is_reached_by(hal.time.get_time_since_boot())) console_.port.poll();
}

// The device driver takes a callback without context.
fn sleepMs(ms: u32) void {
    sleepPolling(&console, ms);
}

// no register on an unknown device is modified.
fn addressResponds(console_: *Console, addr: u7, attempts: usize) bool {
    var byte: [1]u8 = undefined;
    for (0..attempts) |attempt| {
        console_.port.poll();
        i2c.read_blocking(@fromBackingInt(addr), &byte, .from_ms(25)) catch {
            if (attempt + 1 < attempts) sleepPolling(console_, 5);
            continue;
        };
        return true;
    }
    return false;
}

fn isCy8cmbr3108(addr: u7) bool {
    var device = Device.init(addr, sleepMs);
    return device.is3108();
}

fn changeAddress(port: *Console, from: u7, to: u7) !void {
    if (!isCy8cmbr3108(from)) return error.SourceNotCY8CMBR3108;
    if (from == to) return;
    if (addressResponds(port, to, 3)) return error.DestinationInUse;

    var device = Device.init(from, sleepMs);
    device.changeAddress(to) catch |err| {
        if (device.last_command_error) |code| {
            port.print("Device error: 0x{X:0>2}\r\n", .{code}) catch {};
        }
        return err;
    };
}

fn parseAddress(input: []const u8) ?u7 {
    const value = std.fmt.parseInt(u7, input, 0) catch return null;
    return if (value >= 0x08 and value <= 0x77) value else null;
}

const AddressSetupSession = struct {
    const Self = @This();

    console: *Console,
    from_address: ?u7 = null,
    line: [16]u8 = undefined,
    line_len: usize = 0,
    excess_chars: usize = 0,
    last_was_cr: bool = false,

    fn scan(self: *Self) std.Io.Writer.Error!void {
        self.from_address = null;
        try self.console.write("\r\nfound: ");
        var any = false;
        for (0x08..0x78) |number| {
            const addr: u7 = @intCast(number);
            if (!addressResponds(self.console, addr, 1)) continue;
            if (any) try self.console.write(", ");
            try self.console.print("0x{X:0>2}", .{addr});
            any = true;
        }
        if (!any) try self.console.write("(none)");
        try self.console.write("\r\n(Enter/r = rescan)\r\nfrom: ");
    }

    fn onInput(self: *Self, input: []const u8) std.Io.Writer.Error!void {
        if (input.len == 0 or std.mem.eql(u8, input, "r")) return self.scan();

        if (self.from_address) |from| {
            const to = parseAddress(input) orelse {
                try self.console.write("enter an address from 0x08 to 0x77 (8 to 119; Enter = cancel)\r\nto: ");
                return;
            };
            try self.console.print("0x{X:0>2} -> 0x{X:0>2} ... ", .{ from, to });
            if (changeAddress(self.console, from, to)) {
                try self.console.write(if (from == to) "unchanged\r\n" else "OK\r\n");
            } else |err| {
                try self.console.print("FAILED: {s}\r\n", .{@errorName(err)});
            }
            return self.scan();
        }

        const from = parseAddress(input) orelse {
            try self.console.write("enter an address (e.g. 0x37 or 55), or r to rescan\r\nfrom: ");
            return;
        };
        if (!isCy8cmbr3108(from)) {
            try self.console.write("error: no CY8CMBR3108 at that address\r\nfrom: ");
            return;
        }
        self.from_address = from;
        try self.console.write("to: ");
    }

    fn submitLine(self: *Self) std.Io.Writer.Error!void {
        defer {
            self.line_len = 0;
            self.excess_chars = 0;
        }
        try self.console.write("\r\n");
        if (self.excess_chars > 0) {
            try self.console.write("input too long\r\n");
            try self.console.write(if (self.from_address == null) "from: " else "to: ");
        } else {
            try self.onInput(std.mem.trim(u8, self.line[0..self.line_len], " \t"));
        }
    }

    fn onByte(self: *Self, byte: u8) std.Io.Writer.Error!void {
        if (byte == '\n' and self.last_was_cr) {
            self.last_was_cr = false;
            return;
        }
        self.last_was_cr = byte == '\r';
        switch (byte) {
            '\r', '\n' => try self.submitLine(),
            0x08, 0x7f => {
                if (self.excess_chars > 0) {
                    self.excess_chars -= 1;
                } else if (self.line_len > 0) {
                    self.line_len -= 1;
                    try self.console.write("\x08 \x08");
                }
            },
            else => {
                if (self.line_len < self.line.len) {
                    self.line[self.line_len] = byte;
                    self.line_len += 1;
                    try self.console.write(&.{byte});
                } else {
                    self.excess_chars += 1;
                }
            },
        }
    }
};

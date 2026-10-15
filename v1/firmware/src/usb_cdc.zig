const microzig = @import("microzig");
const hal = microzig.hal;
const usb = microzig.core.usb;

pub fn Port(comptime config: usb.Config) type {
    const UsbController = usb.DeviceController(config, .{.{ .cdc = .{} }});
    const UsbDevice = hal.usb.Polled(.{});

    return struct {
        const Self = @This();

        controller: UsbController = .init,
        device: UsbDevice = undefined,

        pub fn init(self: *Self) void {
            self.device = UsbDevice.init();
        }

        pub fn poll(self: *Self) void {
            self.device.poll(&self.controller);
        }

        pub fn configured(self: *Self) bool {
            return self.controller.drivers() != null;
        }

        pub fn read(self: *Self, dst: []u8) usize {
            const cdc = self.activeCdc() orelse return 0;
            return cdc.read(dst);
        }

        /// Queues as many bytes as fit in CDC's TX buffer, without waiting.
        pub fn write(self: *Self, bytes: []const u8) usize {
            const cdc = self.activeCdc() orelse return 0;
            return cdc.write(bytes);
        }

        /// Starts transmission when possible; false means data is still buffered.
        pub fn flush(self: *Self) bool {
            const cdc = self.activeCdc() orelse return false;
            return cdc.flush();
        }

        fn activeCdc(self: *Self) ?*usb.drivers.CDC {
            const drivers = self.controller.drivers() orelse return null;
            return &drivers.cdc;
        }
    };
}

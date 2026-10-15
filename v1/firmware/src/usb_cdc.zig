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

        /// Send one USB packet now, or drop it if the endpoint is busy.
        pub fn trySendPacket(self: *Self, packet: []const u8) bool {
            const cdc = self.activeCdc() orelse return false;
            // MicroZig CDC exposes its single-packet TX state but has no try-send API.
            if (packet.len == 0 or packet.len > cdc.tx_data.len) return false;
            if (cdc.tx_end != 0 or !cdc.tx_ready.load(.seq_cst)) return false;
            if (cdc.write(packet) != packet.len or !cdc.flush()) {
                cdc.tx_end = 0;
                return false;
            }
            return true;
        }

        fn activeCdc(self: *Self) ?*usb.drivers.CDC {
            const drivers = self.controller.drivers() orelse return null;
            return &drivers.cdc;
        }
    };
}

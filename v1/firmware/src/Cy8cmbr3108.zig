const Self = @This();

address: u7,
sleep_ms: *const fn (u32) void,
last_command_error: ?u8 = null,

pub fn init(address: u7, sleep_ms: *const fn (u32) void) Self {
    return .{ .address = address, .sleep_ms = sleep_ms };
}

/// Read all eight difference counts in one transaction for the runtime loop.
pub fn readDifferenceCounts(address: u7) hal.i2c.Error![8]u8 {
    const start = [1]u8{reg.difference_count_sensor0};
    var registers: [16]u8 = undefined;
    try i2c.write_then_read_blocking(@fromBackingInt(address), &start, &registers, .from_ms(2));

    var counts: [8]u8 = undefined;
    // Difference-count registers are two bytes apart; button counts use the low byte.
    for (&counts, 0..) |*count, sensor| count.* = registers[2 * sensor];
    return counts;
}

pub fn is3108(self: *Self) bool {
    if ((self.read8(reg.family_id) catch return false) != expected_family_id) return false;

    var bytes: [2]u8 = undefined;
    self.readRegs(reg.device_id, &bytes) catch return false;
    const device_id = @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
    return device_id == expected_device_id;
}

pub fn changeAddress(self: *Self, to: u7) !void {
    self.last_command_error = null;
    if (try self.read8(reg.i2c_addr) != to) try self.write8(reg.i2c_addr, to);
    if (try self.read8(reg.i2c_addr) != to) return error.AddressWriteMismatch;

    try self.command(opcode.calculate_crc);
    var crc: [2]u8 = undefined;
    try self.readRegs(reg.calc_crc, &crc);
    try self.writeRegs(reg.config_crc, &crc);
    try self.command(opcode.save_config);

    // Reset may take effect before the I2C ACK is returned.
    self.write8(reg.ctrl_cmd, opcode.reset) catch {};
    self.sleep_ms(800);

    self.address = to;
    if (!self.is3108()) return error.NewAddressNotFound;
    if (try self.read8(reg.i2c_addr) != to) return error.NewAddressMismatch;
}

fn readRegs(self: *Self, register: u8, dst: []u8) hal.i2c.Error!void {
    const prefix = [1]u8{register};
    var last_error: hal.i2c.Error = error.Timeout;
    for (0..3) |_| {
        if (i2c.write_then_read_blocking(@fromBackingInt(self.address), &prefix, dst, .from_ms(25))) {
            return;
        } else |err| {
            last_error = err;
            self.sleep_ms(5);
        }
    }
    return last_error;
}

fn read8(self: *Self, register: u8) hal.i2c.Error!u8 {
    var byte: [1]u8 = undefined;
    try self.readRegs(register, &byte);
    return byte[0];
}

fn writeRegs(self: *Self, register: u8, data: []const u8) hal.i2c.Error!void {
    if (data.len > 2) unreachable;
    var packet: [3]u8 = undefined;
    packet[0] = register;
    @memcpy(packet[1..][0..data.len], data);

    var last_error: hal.i2c.Error = error.Timeout;
    for (0..3) |_| {
        if (i2c.write_blocking(@fromBackingInt(self.address), packet[0 .. 1 + data.len], .from_ms(25))) {
            return;
        } else |err| {
            last_error = err;
            self.sleep_ms(5);
        }
    }
    return last_error;
}

fn write8(self: *Self, register: u8, value: u8) hal.i2c.Error!void {
    try self.writeRegs(register, &.{value});
}

fn waitIdle(self: *Self) bool {
    const deadline = hal.time.deadline_in_ms(3000);
    while (!deadline.is_reached_by(hal.time.get_time_since_boot())) {
        if ((self.read8(reg.ctrl_cmd) catch 0xff) == 0) return true;
        self.sleep_ms(20);
    }
    return false;
}

fn command(self: *Self, code: u8) !void {
    if (!self.waitIdle()) return error.ControllerBusyOrUnreachable;
    try self.write8(reg.ctrl_cmd, code);
    if (code == opcode.save_config) self.sleep_ms(250); // NVM save takes about 220 ms.
    if (!self.waitIdle()) return error.CommandTimeout;

    if ((try self.read8(reg.ctrl_cmd_status) & 1) != 0) {
        self.last_command_error = self.read8(reg.ctrl_cmd_err) catch 0xff;
        return error.DeviceCommandFailed;
    }
}

const microzig = @import("microzig");
const hal = microzig.hal;
const i2c = hal.i2c.instance.I2C1;

// CY8CMBR3108 register start addresses (Registers TRM, sections 1.4.3 and 1.5).
// https://www.infineon.com/assets/row/public/documents/30/57/infineon-cy8cmbr3xxx-capsense-express-controllers-registers-trm-additionaltechnicalinformation-en.pdf
const reg = struct {
    const sensor_en: u8 = 0x00;
    const fss_en: u8 = 0x02;
    const toggle_en: u8 = 0x04;
    const led_on_en: u8 = 0x06;
    const sensitivity0: u8 = 0x08;
    const sensitivity1: u8 = 0x09;
    const base_threshold0: u8 = 0x0c;
    const base_threshold1: u8 = 0x0d;
    const finger_threshold2: u8 = 0x0e;
    const finger_threshold3: u8 = 0x0f;
    const finger_threshold4: u8 = 0x10;
    const finger_threshold5: u8 = 0x11;
    const finger_threshold6: u8 = 0x12;
    const finger_threshold7: u8 = 0x13;
    const sensor_debounce: u8 = 0x1c;
    const button_hys: u8 = 0x1d;
    const button_lbr: u8 = 0x1f;
    const button_nnt: u8 = 0x20;
    const button_nt: u8 = 0x21;
    const prox_en: u8 = 0x26;
    const prox_cfg: u8 = 0x27;
    const prox_cfg2: u8 = 0x28;
    const prox_touch_th0: u8 = 0x2a;
    const prox_touch_th1: u8 = 0x2c;
    const prox_resolution0: u8 = 0x2e;
    const prox_resolution1: u8 = 0x2f;
    const prox_hys: u8 = 0x30;
    const prox_lbr: u8 = 0x32;
    const prox_nnt: u8 = 0x33;
    const prox_nt: u8 = 0x34;
    const prox_positive_th0: u8 = 0x35;
    const prox_positive_th1: u8 = 0x36;
    const prox_negative_th0: u8 = 0x39;
    const prox_negative_th1: u8 = 0x3a;
    const led_on_time: u8 = 0x3d;
    const buzzer_cfg: u8 = 0x3e;
    const buzzer_on_time: u8 = 0x3f;
    const gpo_cfg: u8 = 0x40;
    const pwm_dutycycle_cfg0: u8 = 0x41;
    const pwm_dutycycle_cfg1: u8 = 0x42;
    const pwm_dutycycle_cfg2: u8 = 0x43;
    const pwm_dutycycle_cfg3: u8 = 0x44;
    const spo_cfg: u8 = 0x4c;
    const device_cfg0: u8 = 0x4d;
    const device_cfg1: u8 = 0x4e;
    const device_cfg2: u8 = 0x4f;
    const device_cfg3: u8 = 0x50;
    const i2c_addr: u8 = 0x51;
    const refresh_ctrl: u8 = 0x52;
    const state_timeout: u8 = 0x55;
    const scratchpad0: u8 = 0x7a;
    const scratchpad1: u8 = 0x7b;
    const config_crc: u8 = 0x7e;
    const gpo_output_state: u8 = 0x80;
    const sensor_id: u8 = 0x82;
    const ctrl_cmd: u8 = 0x86;
    const ctrl_cmd_status: u8 = 0x88;
    const ctrl_cmd_err: u8 = 0x89;
    const system_status: u8 = 0x8a;
    const prev_ctrl_cmd_code: u8 = 0x8c;
    const family_id: u8 = 0x8f;
    const device_id: u8 = 0x90;
    const device_rev: u8 = 0x92;
    const calc_crc: u8 = 0x94;
    const total_working_sns: u8 = 0x97;
    const sns_cp_high: u8 = 0x98;
    const sns_vdd_short: u8 = 0x9a;
    const sns_gnd_short: u8 = 0x9c;
    const sns_sns_short: u8 = 0x9e;
    const cmod_shield_test: u8 = 0xa0;
    const button_stat: u8 = 0xaa;
    const latched_button_stat: u8 = 0xac;
    const prox_stat: u8 = 0xae;
    const latched_prox_stat: u8 = 0xaf;
    const sync_counter0: u8 = 0xb9;
    const difference_count_sensor0: u8 = 0xba;
    const difference_count_sensor1: u8 = 0xbc;
    const difference_count_sensor2: u8 = 0xbe;
    const difference_count_sensor3: u8 = 0xc0;
    const difference_count_sensor4: u8 = 0xc2;
    const difference_count_sensor5: u8 = 0xc4;
    const difference_count_sensor6: u8 = 0xc6;
    const difference_count_sensor7: u8 = 0xc8;
    const gpo_data: u8 = 0xda;
    const sync_counter1: u8 = 0xdb;
    const debug_sensor_id: u8 = 0xdc;
    const debug_cp: u8 = 0xdd;
    const debug_difference_count0: u8 = 0xde;
    const debug_baseline0: u8 = 0xe0;
    const debug_raw_count0: u8 = 0xe2;
    const debug_avg_raw_count0: u8 = 0xe4;
    const sync_counter2: u8 = 0xe7;
};

// 1.5.80 CTRL_CMD
const opcode = struct {
    // The device calculates a CRC checksum over the configuration data in this register map and compares the result with the content of CONFIG_CRC.
    // If the two values match, the device saves the configuration and the CRC checksum to nonvolatile memory.
    const save_config: u8 = 0x02;

    // The device calculates a CRC checksum over the configuration data in this register map and places the result in the CALC_CRC register.
    // Note that this command is only for test and debug, and its use is not recommended for production configurations.
    // Use EzClick or Host APIs to calculate CRC for production configurations. Refer CY8CMBR3xxx Design Guide for more details.
    const calculate_crc: u8 = 0x03;

    // The device discontinues scanning and enters the low power mode.
    // The device will exit this mode upon an I2C address match event.
    const enter_low_power_mode: u8 = 0x07;

    // The device sets the contents of LATCHED_BUTTON_STAT and LATCHED_PROX_STAT to 0 and sets the contents of LIFTOFF_SLIDER1_POSITION and LIFTOFF_SLIDER2_POSITION to 0xFF.
    const clear_latched_data: u8 = 0x08;

    // The device resets the Advanced Low Pass filter for proximity sensor PS0
    const reset_prox0_filter: u8 = 0x09;

    // The device resets the Advanced Low Pass filter for proximity sensor PS1
    const reset_prox1_filter: u8 = 0x0a;

    // The device resets itself
    const reset: u8 = 0xff;
};

const expected_family_id: u8 = 0x9a;
const expected_device_id: u16 = 0x0a03;

const std = @import("std");
const microzig = @import("microzig");

const MicroBuild = microzig.MicroBuild(.{
    .rp2xxx = true,
});

pub fn build(b: *std.Build) void {
    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    const firmware = mb.add_firmware(.{
        .name = "v1_firmware",
        .target = mb.ports.rp2xxx.boards.raspberrypi.pico,
        .optimize = .ReleaseSmall,
        .root_source_file = b.path("src/main.zig"),
    });

    mb.install_firmware(firmware, .{});

    const flash = b.addSystemCommand(&.{ "picotool", "load", "-x" });
    flash.addFileArg(firmware.get_emitted_bin(null));
    flash.has_side_effects = true;

    const run_step = b.step("run", "Flash and run on the Pico");
    run_step.dependOn(&flash.step);
}

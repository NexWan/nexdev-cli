const std = @import("std");
const zz = @import("zigzag");
const tui = @import("tui.zig");

pub fn main(init: std.process.Init) !void {
    var program = try zz.Program(tui.Model).initWithOptions(init.gpa, init.io, init.environ_map, .{
        .mouse = true,
    });
    defer program.deinit();
    try program.run();
}

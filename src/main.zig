//! Executable entrypoint for the NexDev CLI.
//!
//! The application behavior lives in `tui.zig`; this file intentionally stays
//! small so process startup remains easy to find.

const std = @import("std");
const zz = @import("zigzag");
const tui = @import("tui.zig");

/// Starts the ZigZag program with the TUI model and enables mouse events.
pub fn main(init: std.process.Init) !void {
    var program = try zz.Program(tui.Model).initWithOptions(init.gpa, init.io, init.environ_map, .{
        .mouse = true,
    });
    defer program.deinit();
    try program.run();
}

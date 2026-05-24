const std = @import("std");
const upstream = @import("zigzag_upstream");
const keyboard = upstream.input.keyboard;

const paste_start_marker = "\x1b[200~";
const paste_end_marker = "\x1b[201~";

pub const InputParser = struct {
    allocator: std.mem.Allocator,
    buffer: std.array_list.Managed(u8),

    pub fn init(allocator: std.mem.Allocator) InputParser {
        return .{
            .allocator = allocator,
            .buffer = std.array_list.Managed(u8).init(allocator),
        };
    }

    pub fn deinit(self: *InputParser) void {
        self.buffer.deinit();
    }

    pub fn parseChunk(
        self: *InputParser,
        result_allocator: std.mem.Allocator,
        data: []const u8,
    ) ![]keyboard.ParseResult {
        try self.buffer.appendSlice(data);

        var results = std.array_list.Managed(keyboard.ParseResult).init(result_allocator);
        errdefer results.deinit();

        var offset: usize = 0;
        while (offset < self.buffer.items.len) {
            const available = self.buffer.items[offset..];

            if (startsPasteSequence(available)) {
                if (std.mem.indexOf(u8, available[paste_start_marker.len..], paste_end_marker)) |end_offset| {
                    const paste_content = available[paste_start_marker.len .. paste_start_marker.len + end_offset];
                    const owned_paste = try result_allocator.dupe(u8, paste_content);
                    try results.append(.{
                        .key = .{ .key = .{ .paste = owned_paste } },
                    });
                    offset += paste_start_marker.len + end_offset + paste_end_marker.len;
                    continue;
                }

                break;
            }

            if (isPasteSequencePrefix(available)) {
                break;
            }

            const parsed = keyboard.parse(available);
            if (parsed.consumed == 0) break;

            if (parsed.result != .none) {
                try results.append(parsed.result);
            }
            offset += parsed.consumed;
        }

        if (offset > 0) {
            self.discard(offset);
        }

        return results.toOwnedSlice();
    }

    fn discard(self: *InputParser, count: usize) void {
        if (count >= self.buffer.items.len) {
            self.buffer.clearRetainingCapacity();
            return;
        }

        const remaining = self.buffer.items.len - count;
        std.mem.copyForwards(u8, self.buffer.items[0..remaining], self.buffer.items[count..]);
        self.buffer.shrinkRetainingCapacity(remaining);
    }
};

fn startsPasteSequence(data: []const u8) bool {
    return data.len >= paste_start_marker.len and std.mem.startsWith(u8, data, paste_start_marker);
}

fn isPasteSequencePrefix(data: []const u8) bool {
    if (data.len >= paste_start_marker.len) return false;
    return std.mem.startsWith(u8, paste_start_marker, data);
}

test "buffers bracketed paste across chunks" {
    var parser = InputParser.init(std.testing.allocator);
    defer parser.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const first = try parser.parseChunk(allocator, "\x1b[200~hello\n");
    try std.testing.expectEqual(@as(usize, 0), first.len);

    const second = try parser.parseChunk(allocator, "world\x1b[201~");
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expect(second[0] == .key);
    try std.testing.expect(second[0].key.key == .paste);
    try std.testing.expectEqualStrings("hello\nworld", second[0].key.key.paste);
}

test "keeps paste end marker from becoming escape" {
    var parser = InputParser.init(std.testing.allocator);
    defer parser.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    _ = try parser.parseChunk(allocator, "\x1b[200~body");
    const events = try parser.parseChunk(allocator, "\x1b[201~");

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expect(events[0] == .key);
    try std.testing.expect(events[0].key.key == .paste);
    try std.testing.expectEqualStrings("body", events[0].key.key.paste);
}

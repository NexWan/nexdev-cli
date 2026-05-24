const std = @import("std");

pub const Role = enum { user, assistant, tool, system };

pub const MessageState = enum { complete, streaming, failed };

pub const ChatMessage = struct {
    id: u64,
    role: Role,
    text: []u8,
    state: MessageState,

    pub fn deinit(self: *ChatMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

pub const AgentDelta = struct { message_id: u64, bytes: []const u8 };

pub const AgentDone = struct { message_id: u64 };

pub const AgentFailed = struct { message_id: u64, reason: []const u8 };

pub const UiMode = enum {
    chat,
    select_model,
    select_reasoning,
    select_sandbox,
    select_agents,
    create_agent_name,
    create_agent_description,
    create_agent_behavior,
    create_agent_model,
};

pub const ModelOption = enum {
    gpt_5_5,
    gpt_5_4,
    gpt_5_4_mini,
    gpt_5_3_codex,
};

pub const ReasoningOption = enum { low, medium, high };

pub const SandboxOption = enum { read_only, workspace_write, danger_full_access };

pub const AgentOption = enum { create, list, view };

pub const SlashAction = enum { model, reasoning, sandbox, agents, clear };

pub const SlashCommand = struct {
    name: []const u8,
    description: []const u8,
};

pub const slash_commands = [_]SlashCommand{
    .{ .name = "/model", .description = "Select a model" },
    .{ .name = "/reasoning", .description = "Set reasoning effort" },
    .{ .name = "/sandbox", .description = "Set filesystem sandbox" },
    .{ .name = "/agents", .description = "Configure agent related settings" },
    .{ .name = "/clear", .description = "Clear the chat history" },
};

pub const demo_response =
    "This is a simulated agent response. The UI is appending small chunks on " ++
    "timer ticks, which is the same shape you would use when draining a real " ++
    "backend or RPC event queue.";

pub const logo =
    "             *                             \n" ++
    "     *++   +  +                            \n" ++
    "   %     +*     ++          ++             \n" ++
    "     +++++++*+                  +          \n" ++
    " ++   +   ++                      +        \n" ++
    "     ++   +         * + +          +       \n" ++
    "        ++   ++     + + +      ++   +      \n" ++
    "        *       ++          ++       +     \n" ++
    "                ++         +=              \n" ++
    "       +     ++               ++*     +    \n" ++
    "         +                        +   *    \n" ++
    "      +                          + +   #   \n" ++
    "    @     =                      +     @   \n" ++
    "   +                                       \n" ++
    "   +                                     + \n" ++
    "    +    +                              +  \n" ++
    "           +     +*       ++      +        \n" ++
    "                    *++*+     ++           ";

pub fn modelOptionLabel(option: ModelOption) []const u8 {
    return switch (option) {
        .gpt_5_5 => "GPT-5.5",
        .gpt_5_4 => "GPT-5.4",
        .gpt_5_4_mini => "GPT-5.4 Mini",
        .gpt_5_3_codex => "GPT-5.3 Codex",
    };
}

pub fn modelOptionDescription(option: ModelOption) []const u8 {
    return switch (option) {
        .gpt_5_5 => "Frontier model",
        .gpt_5_4 => "Everyday strong model",
        .gpt_5_4_mini => "Fast small model",
        .gpt_5_3_codex => "Coding-optimized",
    };
}

pub fn reasoningOptionLabel(option: ReasoningOption) []const u8 {
    return switch (option) {
        .low => "low",
        .medium => "medium",
        .high => "high",
    };
}

pub fn reasoningOptionDescription(option: ReasoningOption) []const u8 {
    return switch (option) {
        .low => "Fast responses",
        .medium => "Balanced default",
        .high => "Deeper reasoning",
    };
}

pub fn sandboxOptionLabel(option: SandboxOption) []const u8 {
    return switch (option) {
        .read_only => "read-only",
        .workspace_write => "workspace-write",
        .danger_full_access => "danger-full-access",
    };
}

pub fn sandboxOptionDescription(option: SandboxOption) []const u8 {
    return switch (option) {
        .read_only => "Inspect files only",
        .workspace_write => "Write inside workspace",
        .danger_full_access => "No filesystem sandbox",
    };
}

pub fn agentOptionLabel(option: AgentOption) []const u8 {
    return switch (option) {
        .create => "Create",
        .list => "List",
        .view => "View",
    };
}

pub fn agentOptionDescription(option: AgentOption) []const u8 {
    return switch (option) {
        .create => "Create a new agent",
        .list => "List existing agents",
        .view => "View existing agent settings",
    };
}

pub fn resolveSlashAction(command: []const u8) ?SlashAction {
    if (command.len == 0 or command[0] != '/') return null;

    const query = command[1..];
    var match_count: usize = 0;
    var result: ?SlashAction = null;

    if (std.mem.startsWith(u8, "model", query)) {
        match_count += 1;
        result = .model;
    }
    if (std.mem.startsWith(u8, "reasoning", query)) {
        match_count += 1;
        result = .reasoning;
    }
    if (std.mem.startsWith(u8, "sandbox", query)) {
        match_count += 1;
        result = .sandbox;
    }
    if (std.mem.startsWith(u8, "agents", query)) {
        match_count += 1;
        result = .agents;
    }
    if (std.mem.startsWith(u8, "clear", query)) {
        match_count += 1;
        result = .clear;
    }

    return if (match_count == 1) result else null;
}

pub fn padRight(allocator: std.mem.Allocator, text: []const u8, width: usize) ![]const u8 {
    if (text.len >= width) return allocator.dupe(u8, text[0..width]);

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try out.appendSlice(text);
    try out.appendNTimes(' ', width - text.len);
    return out.toOwnedSlice();
}

test "resolve slash action supports exact and unique prefixes" {
    try std.testing.expectEqual(SlashAction.model, resolveSlashAction("/model").?);
    try std.testing.expectEqual(SlashAction.model, resolveSlashAction("/m").?);
    try std.testing.expectEqual(SlashAction.reasoning, resolveSlashAction("/reasoning").?);
    try std.testing.expectEqual(SlashAction.sandbox, resolveSlashAction("/s").?);
    try std.testing.expectEqual(SlashAction.agents, resolveSlashAction("/agents").?);
    try std.testing.expectEqual(SlashAction.agents, resolveSlashAction("/a").?);
    try std.testing.expectEqual(SlashAction.clear, resolveSlashAction("/clear").?);
}

test "resolve slash action rejects unknown and ambiguous commands" {
    try std.testing.expect(resolveSlashAction("/") == null);
    try std.testing.expect(resolveSlashAction("/missing") == null);
    try std.testing.expect(resolveSlashAction("model") == null);
}

test "pad right pads and truncates" {
    const allocator = std.testing.allocator;

    const padded = try padRight(allocator, "hi", 4);
    defer allocator.free(padded);
    try std.testing.expectEqualStrings("hi  ", padded);

    const truncated = try padRight(allocator, "hello", 3);
    defer allocator.free(truncated);
    try std.testing.expectEqualStrings("hel", truncated);
}

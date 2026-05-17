const std = @import("std");
const zz = @import("zigzag");
const app = @import("nexdev_cli");
const rpc = @import("zig_rpc");

const ChatMessage = app.ChatMessage;
const AgentDelta = app.AgentDelta;
const AgentDone = app.AgentDone;
const AgentFailed = app.AgentFailed;
const UiMode = app.UiMode;
const ModelOption = app.ModelOption;
const ReasoningOption = app.ReasoningOption;
const logo = app.logo;
const slash_commands = app.slash_commands;
const modelOptionLabel = app.modelOptionLabel;
const modelOptionDescription = app.modelOptionDescription;
const reasoningOptionLabel = app.reasoningOptionLabel;
const reasoningOptionDescription = app.reasoningOptionDescription;
const resolveSlashAction = app.resolveSlashAction;
const padRight = app.padRight;

const Model = struct {
    allocator: std.mem.Allocator,
    messages: std.array_list.Managed(ChatMessage),
    composer: zz.TextInput,
    transcript: zz.Viewport,
    show_commands: bool,

    next_id: u64,
    pending_response_id: ?u64,
    pending_response_text: ?[]u8,
    status: []const u8,
    response_cursor: usize,

    mode: UiMode,
    model_list: zz.List(ModelOption),
    reasoning_list: zz.List(ReasoningOption),
    active_model: []const u8,
    active_reasoning: []const u8,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        window_size: zz.msg.WindowSize,
        tick: zz.msg.Tick,

        agent_delta: AgentDelta,
        agent_done: AgentDone,
        agent_failed: AgentFailed,
    };

    pub fn init(self: *Model, ctx: *zz.Context) zz.Cmd(Msg) {
        const allocator = ctx.persistent_allocator;

        self.* = .{
            .allocator = allocator,
            .messages = std.array_list.Managed(ChatMessage).init(allocator),
            .composer = zz.TextInput.init(allocator),
            .transcript = zz.Viewport.init(allocator, ctx.width, ctx.height -| 4),
            .show_commands = false,
            .next_id = 1,
            .pending_response_id = null,
            .pending_response_text = null,
            .status = "idle",
            .response_cursor = 0,
            .mode = .chat,
            .model_list = zz.List(ModelOption).init(allocator),
            .reasoning_list = zz.List(ReasoningOption).init(allocator),
            .active_model = modelOptionLabel(.gpt_5_5),
            .active_reasoning = reasoningOptionLabel(.medium),
        };
        self.composer.setPrompt("> ");
        self.composer.setPlaceholder("Type your message...");
        self.composer.text_style = self.composer.text_style.fg(.green).bold(true);
        self.composer.prompt_style = self.composer.prompt_style.fg(.green).bold(true);
        self.composer.placeholder_style = self.composer.placeholder_style.fg(.green).bold(true);
        self.composer.cursor_style = self.composer.cursor_style.fg(.black).bg(.green).bold(true);

        self.transcript.setWrap(true);
        self.transcript.setShowScrollbar(false);
        self.initSelectionLists();

        self.resize(ctx.width, ctx.height);
        self.rebuildTranscript() catch {};

        return .{ .set_title = "NexDev - CLI" };
    }

    pub fn deinit(self: *Model) void {
        for (self.messages.items) |*message| {
            message.deinit(self.allocator);
        }
        self.freePendingResponseText();
        self.messages.deinit();
        self.composer.deinit();
        self.transcript.deinit();
        self.model_list.deinit();
        self.reasoning_list.deinit();
    }

    pub fn update(self: *Model, msg: Msg, ctx: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |key| return self.handleKey(key, ctx),
            .window_size => |size| {
                self.resize(size.width, size.height);
                self.rebuildTranscript() catch {};
                return .none;
            },
            .tick => {
                return self.pollAgent();
            },
            .agent_delta => |delta| {
                self.applyAgentDelta(delta) catch {
                    self.status = "stream failed";
                };
                return .none;
            },
            .agent_done => |done| {
                if (self.pending_response_id == done.message_id) {
                    self.pending_response_id = null;
                    self.freePendingResponseText();
                    self.status = "idle";
                    self.markMessageComplete(done.message_id);
                }
                self.rebuildTranscript() catch {};
                return .none;
            },
            .agent_failed => |failed| {
                self.applyAgentFailure(failed) catch {};
                return .none;
            },
        }
    }

    fn handleKey(self: *Model, key: zz.KeyEvent, ctx: *zz.Context) zz.Cmd(Msg) {
        if (key.modifiers.ctrl and key.key.eql(.{ .char = 'c' })) {
            return .quit;
        }

        return switch (self.mode) {
            .chat => self.handleChatKey(key, ctx),
            .select_model => self.handleModelSelectionKey(key),
            .select_reasoning => self.handleReasoningSelectionKey(key),
        };
    }

    fn handleChatKey(self: *Model, key: zz.KeyEvent, ctx: *zz.Context) zz.Cmd(Msg) {
        switch (key.key) {
            .escape => return .quit,
            .page_up, .page_down, .home, .end => {
                self.transcript.handleKey(key);
                return .none;
            },
            .enter => return self.handleComposerSubmit(ctx),
            else => {},
        }

        self.composer.handleKey(key);

        const value = self.composer.getValue();
        self.show_commands = std.mem.startsWith(u8, value, "/");

        return .none;
    }

    fn handleModelSelectionKey(self: *Model, key: zz.KeyEvent) zz.Cmd(Msg) {
        switch (key.key) {
            .escape => {
                self.mode = .chat;
                self.status = "idle";
                return .none;
            },
            .enter => {
                if (self.model_list.selectedValue()) |value| {
                    self.active_model = modelOptionLabel(value);
                    self.mode = .chat;
                    self.status = "model updated";
                }
                return .none;
            },
            else => {
                self.model_list.handleKey(key);
                return .none;
            },
        }
    }

    fn handleReasoningSelectionKey(self: *Model, key: zz.KeyEvent) zz.Cmd(Msg) {
        switch (key.key) {
            .escape => {
                self.mode = .chat;
                self.status = "idle";
                return .none;
            },
            .enter => {
                if (self.reasoning_list.selectedValue()) |value| {
                    self.active_reasoning = reasoningOptionLabel(value);
                    self.mode = .chat;
                    self.status = "reasoning updated";
                }
                return .none;
            },
            else => {
                self.reasoning_list.handleKey(key);
                return .none;
            },
        }
    }

    fn handleComposerSubmit(self: *Model, ctx: *zz.Context) zz.Cmd(Msg) {
        const raw = self.composer.getValue();
        const trimmed = std.mem.trim(u8, raw, " \t\n\r");

        if (std.mem.startsWith(u8, trimmed, "/")) {
            return self.handleSlashCommand(trimmed);
        }

        return self.submit(ctx);
    }

    fn handleSlashCommand(self: *Model, command: []const u8) zz.Cmd(Msg) {
        self.show_commands = false;

        const action = resolveSlashAction(command) orelse {
            self.status = if (std.mem.eql(u8, command, "/"))
                "type a more specific command"
            else
                "unknown slash command";
            return .none;
        };

        self.composer.setValue("") catch {};

        switch (action) {
            .model => {
                self.prepareModelSelection();
                self.mode = .select_model;
                self.status = "select a model";
            },
            .reasoning => {
                self.prepareReasoningSelection();
                self.mode = .select_reasoning;
                self.status = "select reasoning effort";
            },
            .clear => {
                self.clearSession();
                self.status = "session cleared";
            },
        }

        return .none;
    }

    fn submit(self: *Model, ctx: *zz.Context) zz.Cmd(Msg) {
        if (self.pending_response_id != null) {
            self.status = "busy - please wait...";
            return .none;
        }

        const raw = self.composer.getValue();
        const trimmed = std.mem.trim(u8, raw, " \t\n\r");

        if (trimmed.len == 0) return .none;

        const user_id = self.next_id;
        self.next_id += 1;
        const assistant_id = self.next_id;
        self.next_id += 1;

        const user_text = self.allocator.dupe(u8, trimmed) catch return .none;

        self.messages.append(.{
            .id = user_id,
            .role = .user,
            .text = user_text,
            .state = .complete,
        }) catch {
            self.allocator.free(user_text);
            return .none;
        };

        const empty = self.allocator.dupe(u8, "") catch return .none;
        self.messages.append(.{
            .id = assistant_id,
            .role = .assistant,
            .text = empty,
            .state = .streaming,
        }) catch {
            self.allocator.free(empty);
            return .none;
        };

        self.pending_response_id = assistant_id;
        self.status = "Calling Python...";
        self.response_cursor = 0;
        self.freePendingResponseText();

        const response_text = self.requestPythonResponse(ctx, assistant_id, user_text) catch {
            self.applyAgentFailure(.{ .message_id = assistant_id, .reason = "RPC request failed" }) catch {};
            return .none;
        };

        self.pending_response_text = response_text;

        self.composer.setValue("") catch {};
        self.status = "Thinking...";
        self.rebuildTranscript() catch {};
        self.transcript.gotoBottom();

        return zz.Cmd(Msg).everyMs(50);
    }

    fn clearSession(self: *Model) void {
        for (self.messages.items) |*message| {
            message.deinit(self.allocator);
        }
        self.messages.clearRetainingCapacity();
        self.pending_response_id = null;
        self.freePendingResponseText();
        self.response_cursor = 0;
        self.mode = .chat;
        self.show_commands = false;
        self.composer.setValue("") catch {};
        self.transcript.setContent("") catch {};
    }

    fn pollAgent(self: *Model) zz.Cmd(Msg) {
        const response_id = self.pending_response_id orelse return .none;
        const response_text = self.pending_response_text orelse return .none;

        if (self.response_cursor >= response_text.len) {
            return zz.Cmd(Msg).send(.{ .agent_done = .{ .message_id = response_id } });
        }

        const chunk_size: usize = 5;
        const start = self.response_cursor;
        const end = @min(response_text.len, start + chunk_size);
        self.response_cursor = end;

        return zz.Cmd(Msg).send(.{
            .agent_delta = .{
                .message_id = response_id,
                .bytes = response_text[start..end],
            },
        });
    }

    fn applyAgentDelta(self: *Model, delta: AgentDelta) !void {
        if (self.pending_response_id != delta.message_id) return;

        for (self.messages.items) |*msg| {
            if (msg.id == delta.message_id) {
                const old = msg.text;
                msg.text = try std.mem.concat(self.allocator, u8, &.{ old, delta.bytes });
                self.allocator.free(old);
                msg.state = .streaming;
                self.status = "streaming";
                break;
            }
        }

        try self.rebuildTranscript();
        self.transcript.gotoBottom();
    }

    fn requestPythonResponse(self: *Model, ctx: *const zz.Context, message_id: u64, text: []const u8) ![]u8 {
        var client = try rpc.SubprocessClient.init(ctx.allocator, ctx.io, &.{ "python3", "./mod/test.py" }, .{});
        defer client.deinit();

        var conn = client.connection();
        try conn.sendRequest(.{ .integer = @intCast(message_id) }, "message.received", .{
            .message_id = message_id,
            .text = text,
        });
        try client.closeInput();

        var response_message = try conn.readMessage();
        defer response_message.deinit();

        const response = try response_message.asResponse();
        if (response.rpc_error != null) {
            return error.RpcPeerError;
        }

        const response_text = try response.asText();
        const owned_text = try self.allocator.dupe(u8, response_text);
        errdefer self.allocator.free(owned_text);
        try expectExitedZero(try client.wait());
        return owned_text;
    }

    fn expectExitedZero(term: std.process.Child.Term) !void {
        switch (term) {
            .exited => |code| if (code == 0) return else return error.ChildExitedNonZero,
            else => return error.ChildDidNotExitNormally,
        }
    }

    fn freePendingResponseText(self: *Model) void {
        if (self.pending_response_text) |text| {
            self.allocator.free(text);
            self.pending_response_text = null;
        }
    }

    fn applyAgentFailure(self: *Model, failed: AgentFailed) !void {
        if (self.pending_response_id != failed.message_id) return;

        for (self.messages.items) |*msg| {
            if (msg.id == failed.message_id) {
                const old = msg.text;
                msg.text = try std.mem.concat(self.allocator, u8, &.{ old, "\n\nError: ", failed.reason });
                self.allocator.free(old);
                msg.state = .failed;
                break;
            }
        }

        self.pending_response_id = null;
        self.status = "failed";
        try self.rebuildTranscript();
        self.transcript.gotoBottom();
    }

    fn markMessageComplete(self: *Model, message_id: u64) void {
        for (self.messages.items) |*msg| {
            if (msg.id == message_id) {
                msg.state = .complete;
                return;
            }
        }
    }

    fn rebuildTranscript(self: *Model) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        const writer = &out.writer;

        for (self.messages.items, 0..) |msg, idx| {
            if (idx > 0) try writer.writeAll("\n\n");

            const label = switch (msg.role) {
                .user => "You",
                .assistant => "Agent",
                .tool => "Tool",
                .system => "System",
            };

            try writer.print("{s}: {s}", .{ label, msg.text });

            if (msg.state == .streaming) {
                try writer.writeAll(" _");
            } else if (msg.state == .failed) {
                try writer.writeAll(" [Failed]");
            }
        }

        const rendered = try out.toOwnedSlice();
        defer self.allocator.free(rendered);
        try self.transcript.setContent(rendered);
    }

    pub fn view(self: *const Model, ctx: *const zz.Context) []const u8 {
        const allocator = ctx.allocator;

        const transcript_view = self.transcript.view(allocator) catch "";
        const composer_view = self.composer.view(allocator) catch "";

        const green = (zz.Style{}).fg(.green).bold(true);
        const pink = (zz.Style{}).fg(zz.Color.fromRgb(255, 132, 190)).bold(true);
        const dim = (zz.Style{}).fg(.gray(10));

        const logo_view = pink.render(allocator, logo) catch logo;
        const intro_raw = std.fmt.allocPrint(
            allocator,
            "\nWelcome to NexDev - CLI\n\n\nModel: {s}\n\nReasoning Effort: {s}\n\nStatus: {s}",
            .{ self.active_model, self.active_reasoning, self.status },
        ) catch "Welcome to NexDev - CLI";
        const intro_view = green.render(allocator, intro_raw) catch intro_raw;

        const top = zz.join.horizontalSep(
            allocator,
            .top,
            "      ",
            &.{ logo_view, intro_view },
        ) catch intro_view;

        const top_height: u16 = 24;
        const top_block = zz.place.place(
            allocator,
            ctx.width,
            top_height,
            .left,
            .top,
            top,
        ) catch top;

        const separator = dim.render(
            allocator,
            "Enter sends | Esc quits | PageUp/PageDown scroll",
        ) catch "Enter sends | Esc quits | PageUp/PageDown scroll";

        const center_view = switch (self.mode) {
            .chat => transcript_view,
            .select_model => self.renderSelectionPanel(
                allocator,
                ctx.width,
                "Select Model",
                self.active_model,
                self.model_list.view(allocator) catch "",
            ) catch transcript_view,
            .select_reasoning => self.renderSelectionPanel(
                allocator,
                ctx.width,
                "Select Reasoning",
                self.active_reasoning,
                self.reasoning_list.view(allocator) catch "",
            ) catch transcript_view,
        };
        const input_line = green.render(allocator, composer_view) catch composer_view;
        const slash_popup = if (self.show_commands)
            self.renderSlashCommandPopup(allocator) catch ""
        else
            "";

        const body = zz.join.vertical(
            allocator,
            .left,
            &.{ top_block, center_view, slash_popup, separator, input_line },
        ) catch top_block;

        return body;
    }

    fn renderSelectionPanel(
        self: *const Model,
        allocator: std.mem.Allocator,
        width: u16,
        title: []const u8,
        current: []const u8,
        list_view: []const u8,
    ) ![]const u8 {
        _ = self;
        const green = (zz.Style{}).fg(.green).bold(true);
        const dim = (zz.Style{}).fg(.gray(10));

        const title_view = try green.render(allocator, title);
        const current_raw = try std.fmt.allocPrint(allocator, "Current: {s}", .{current});
        const current_view = try dim.render(allocator, current_raw);
        const help_view = try dim.render(allocator, "Enter selects | Esc cancels");

        const content = try zz.join.vertical(
            allocator,
            .left,
            &.{ title_view, current_view, "", list_view, "", help_view },
        );

        const panel = (zz.Style{})
            .borderAll(.rounded)
            .borderForeground(.green)
            .paddingAll(1)
            .width(72)
            .render(allocator, content) catch content;

        return zz.place.place(allocator, width, 10, .center, .middle, panel);
    }

    fn renderSlashCommandPopup(self: *const Model, allocator: std.mem.Allocator) ![]const u8 {
        const value = self.composer.getValue();
        const query = if (value.len > 1) value[1..] else "";

        const border = (zz.Style{})
            .fg(.gray(14))
            .bold(true)
            .inline_style(true);
        const active = (zz.Style{})
            .fg(.green)
            .bold(true)
            .inline_style(true);
        const text = (zz.Style{})
            .fg(.gray(18))
            .inline_style(true);
        const muted = (zz.Style{})
            .fg(.gray(10))
            .inline_style(true);

        var rows: std.Io.Writer.Allocating = .init(allocator);
        const writer = &rows.writer;

        const width: usize = 58;
        try writer.writeAll(try border.render(allocator, "+----------------------------------------------------------+"));
        try writer.writeByte('\n');

        const title = if (query.len == 0)
            " slash commands"
        else
            try std.fmt.allocPrint(allocator, " slash commands matching \"{s}\"", .{query});
        try writer.writeAll(try border.render(allocator, "|"));
        try writer.writeAll(try muted.render(allocator, try padRight(allocator, title, width)));
        try writer.writeAll(try border.render(allocator, "|"));

        var shown: usize = 0;
        for (slash_commands) |cmd| {
            const command_key = cmd.name[1..];
            if (query.len > 0 and !std.mem.startsWith(u8, command_key, query)) continue;

            try writer.writeByte('\n');
            try writer.writeAll(try border.render(allocator, "|"));

            const line = try std.fmt.allocPrint(
                allocator,
                " {s:<14} {s}",
                .{ cmd.name, cmd.description },
            );
            const styled_line = if (shown == 0)
                try active.render(allocator, try padRight(allocator, line, width))
            else
                try text.render(allocator, try padRight(allocator, line, width));
            try writer.writeAll(styled_line);
            try writer.writeAll(try border.render(allocator, "|"));
            shown += 1;
        }

        if (shown == 0) {
            try writer.writeByte('\n');
            try writer.writeAll(try border.render(allocator, "|"));
            try writer.writeAll(try muted.render(allocator, try padRight(allocator, " No matching commands", width)));
            try writer.writeAll(try border.render(allocator, "|"));
        }

        try writer.writeByte('\n');
        try writer.writeAll(try border.render(allocator, "+----------------------------------------------------------+"));

        return rows.toOwnedSlice();
    }

    fn initSelectionLists(self: *Model) void {
        self.model_list.height = 6;
        self.model_list.cursor_style = self.model_list.cursor_style.fg(.green).bold(true);
        self.model_list.selected_style = self.model_list.selected_style.fg(.green);
        self.model_list.status_message = "Enter to select";
        self.model_list.addItems(&.{
            zz.List(ModelOption).Item.withDescription(.gpt_5_5, modelOptionLabel(.gpt_5_5), modelOptionDescription(.gpt_5_5)),
            zz.List(ModelOption).Item.withDescription(.gpt_5_4, modelOptionLabel(.gpt_5_4), modelOptionDescription(.gpt_5_4)),
            zz.List(ModelOption).Item.withDescription(.gpt_5_4_mini, modelOptionLabel(.gpt_5_4_mini), modelOptionDescription(.gpt_5_4_mini)),
            zz.List(ModelOption).Item.withDescription(.gpt_5_3_codex, modelOptionLabel(.gpt_5_3_codex), modelOptionDescription(.gpt_5_3_codex)),
        }) catch {};

        self.reasoning_list.height = 5;
        self.reasoning_list.cursor_style = self.reasoning_list.cursor_style.fg(.green).bold(true);
        self.reasoning_list.selected_style = self.reasoning_list.selected_style.fg(.green);
        self.reasoning_list.status_message = "Enter to select";
        self.reasoning_list.addItems(&.{
            zz.List(ReasoningOption).Item.withDescription(.low, reasoningOptionLabel(.low), reasoningOptionDescription(.low)),
            zz.List(ReasoningOption).Item.withDescription(.medium, reasoningOptionLabel(.medium), reasoningOptionDescription(.medium)),
            zz.List(ReasoningOption).Item.withDescription(.high, reasoningOptionLabel(.high), reasoningOptionDescription(.high)),
        }) catch {};

        self.prepareModelSelection();
        self.prepareReasoningSelection();
    }

    fn prepareModelSelection(self: *Model) void {
        self.model_list.gotoFirst();
        for (self.model_list.items.items, 0..) |item, index| {
            if (std.mem.eql(u8, modelOptionLabel(item.value), self.active_model)) {
                self.model_list.cursor = index;
                break;
            }
        }
        self.model_list.selectCurrent();
    }

    fn prepareReasoningSelection(self: *Model) void {
        self.reasoning_list.gotoFirst();
        for (self.reasoning_list.items.items, 0..) |item, index| {
            if (std.mem.eql(u8, reasoningOptionLabel(item.value), self.active_reasoning)) {
                self.reasoning_list.cursor = index;
                break;
            }
        }
        self.reasoning_list.selectCurrent();
    }

    pub fn resize(self: *Model, width: u16, height: u16) void {
        const top_height: u16 = 24;
        const footer_height: u16 = 2;
        const transcript_height = height -| top_height -| footer_height;

        self.transcript.setSize(width, transcript_height);
        self.composer.setWidth(width -| 2);
    }
};

pub fn main(init: std.process.Init) !void {
    var program = try zz.Program(Model).init(init.gpa, init.io, init.environ_map);
    defer program.deinit();
    try program.run();
}

const std = @import("std");
const zz = @import("zigzag");

const Role = enum { user, assistant, tool, system };

const MessageState = enum { complete, streaming, failed };

const demo_response =
    "This is a simulated agent response. The UI is appending small chunks on " ++
    "timer ticks, which is the same shape you would use when draining a real " ++
    "backend or RPC event queue.";

const logo =
    "                %%                                      \n" ++
    "       %%%    %%  %%                                    \n" ++
    "    %      .%@      % @%%%                              \n" ++
    "   %       #%%%    %%                  %%               \n" ++
    "  %  %%# %%%%%%%%%                        %%            \n" ++
    "  %%   %%   :%%%                            %%          \n" ++
    "      %%     %*            % % %              %         \n" ++
    "         %% %   %          % % %               %        \n" ++
    "           %      %%%        % @       %%%      %       \n" ++
    "           %         %%%            %%%         %%      \n" ++
    "          %          @%%          %%%            %      \n" ++
    "         @@       @%%+               @%%%        %      \n" ++
    "         %   %% %%                       %%@ %    %     \n" ++
    "        %=  # %                                %  %     \n" ++
    "       :%    * %                           % %%   %     \n" ++
    "      %@     @                             % @     %    \n" ++
    "     %        %                             %       %   \n" ++
    "    %                                                %  \n" ++
    "    %                                                %  \n" ++
    "     %                                               %  \n" ++
    "       %%%@  %                               %%%%%%%    \n" ++
    "              %%    #%%%%        %%%@%     %%           \n" ++
    "                          %%%@%%        @               ";

const ChatMessage = struct {
    id: u64,
    role: Role,
    text: []u8,
    state: MessageState,

    pub fn deinit(self: *ChatMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

const AgentDelta = struct { message_id: u64, bytes: []const u8 };

const AgentDone = struct { message_id: u64 };

const AgentFailed = struct { message_id: u64, reason: []const u8 };

const Model = struct {
    allocator: std.mem.Allocator,
    messages: std.array_list.Managed(ChatMessage),
    composer: zz.TextInput,
    transcript: zz.Viewport,

    next_id: u64,
    pending_response_id: ?u64,
    status: []const u8,
    demo_cursor: usize,

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
            .next_id = 1,
            .pending_response_id = null,
            .status = "idle",
            .demo_cursor = 0,
        };

        self.composer.setPrompt("> ");
        self.composer.setPlaceholder("Type your message...");
        self.composer.text_style = self.composer.text_style.fg(.green).bold(true);
        self.composer.prompt_style = self.composer.prompt_style.fg(.green).bold(true);
        self.composer.placeholder_style = self.composer.placeholder_style.fg(.green).bold(true);
        self.composer.cursor_style = self.composer.cursor_style.fg(.black).bg(.green).bold(true);

        self.transcript.setWrap(true);
        self.transcript.setShowScrollbar(false);

        self.resize(ctx.width, ctx.height);
        self.rebuildTranscript() catch {};

        return .{ .set_title = "NexDev - CLI" };
    }

    pub fn deinit(self: *Model) void {
        for (self.messages.items) |*message| {
            message.deinit(self.allocator);
        }
        self.messages.deinit();
        self.composer.deinit();
        self.transcript.deinit();
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
                self.applyAgentDelta(delta) catch {};
                return .none;
            },
            .agent_done => |done| {
                if (self.pending_response_id == done.message_id) {
                    self.pending_response_id = null;
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

        switch (key.key) {
            .escape => return .quit,
            .page_up, .page_down, .home, .end => {
                self.transcript.handleKey(key);
                return .none;
            },
            .enter => return self.submit(ctx),
            else => {},
        }

        self.composer.handleKey(key);

        return .none;
    }

    fn submit(self: *Model, ctx: *zz.Context) zz.Cmd(Msg) {
        if (self.pending_response_id != null) {
            self.status = "busy - please wait...";
            return .none;
        }

        _ = ctx;
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

        self.composer.setValue("") catch {};
        self.pending_response_id = assistant_id;
        self.status = "Thinking...";
        self.demo_cursor = 0;
        self.rebuildTranscript() catch {};
        self.transcript.gotoBottom();

        return zz.Cmd(Msg).everyMs(50);
    }

    fn pollAgent(self: *Model) zz.Cmd(Msg) {
        const response_id = self.pending_response_id orelse return .none;

        if (self.demo_cursor >= demo_response.len) {
            return zz.Cmd(Msg).send(.{ .agent_done = .{ .message_id = response_id } });
        }

        const chunk_size: usize = 5;
        const start = self.demo_cursor;
        const end = @min(demo_response.len, start + chunk_size);
        self.demo_cursor = end;

        return zz.Cmd(Msg).send(.{
            .agent_delta = .{
                .message_id = response_id,
                .bytes = demo_response[start..end],
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
            "\nWelcome to NexDev - CLI\n\n\nModel: GPT demo\n\nReasoning Effort: medium\n\nStatus: {s}",
            .{self.status},
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

        const input_line = green.render(allocator, composer_view) catch composer_view;

        const body = zz.join.vertical(
            allocator,
            .left,
            &.{ top_block, transcript_view, separator, input_line },
        ) catch top_block;

        return body;
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

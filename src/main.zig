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
const SandboxOption = app.SandboxOption;
const logo = app.logo;
const slash_commands = app.slash_commands;
const modelOptionLabel = app.modelOptionLabel;
const modelOptionDescription = app.modelOptionDescription;
const reasoningOptionLabel = app.reasoningOptionLabel;
const reasoningOptionDescription = app.reasoningOptionDescription;
const sandboxOptionLabel = app.sandboxOptionLabel;
const sandboxOptionDescription = app.sandboxOptionDescription;
const resolveSlashAction = app.resolveSlashAction;
const padRight = app.padRight;

const compact_header_height: u16 = 3;
const logo_header_height: u16 = 18;
const footer_height: u16 = 3;

const RpcChatMessage = struct {
    role: []const u8,
    content: []const u8,
};

const AgentTaskResult = union(enum) {
    text: []u8,
    failure: []u8,

    fn deinit(self: AgentTaskResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .text => |value| allocator.free(value),
            .failure => |value| allocator.free(value),
        }
    }
};

const AgentTask = struct {
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    npm_path: []u8,
    message_id: u64,
    model: []u8,
    reasoning_effort: []u8,
    sandbox_mode: []u8,
    text: []u8,
    history: []RpcChatMessage,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    result: ?AgentTaskResult = null,

    fn start(
        allocator: std.mem.Allocator,
        environ_map: *const std.process.Environ.Map,
        npm_path: []const u8,
        message_id: u64,
        model: []const u8,
        reasoning_effort: []const u8,
        sandbox_mode: []const u8,
        text: []const u8,
        history: []const RpcChatMessage,
    ) !*AgentTask {
        const task = try allocator.create(AgentTask);
        errdefer allocator.destroy(task);

        const owned_text = try allocator.dupe(u8, text);
        errdefer allocator.free(owned_text);

        const owned_npm_path = try allocator.dupe(u8, npm_path);
        errdefer allocator.free(owned_npm_path);

        const owned_model = try allocator.dupe(u8, model);
        errdefer allocator.free(owned_model);

        const owned_reasoning_effort = try allocator.dupe(u8, reasoning_effort);
        errdefer allocator.free(owned_reasoning_effort);

        const owned_sandbox_mode = try allocator.dupe(u8, sandbox_mode);
        errdefer allocator.free(owned_sandbox_mode);

        const owned_history = try allocator.alloc(RpcChatMessage, history.len);
        errdefer allocator.free(owned_history);

        var initialized: usize = 0;
        errdefer {
            for (owned_history[0..initialized]) |entry| {
                allocator.free(entry.content);
            }
        }

        for (history, 0..) |entry, index| {
            owned_history[index] = .{
                .role = entry.role,
                .content = try allocator.dupe(u8, entry.content),
            };
            initialized += 1;
        }

        task.* = .{
            .allocator = allocator,
            .environ_map = environ_map,
            .npm_path = owned_npm_path,
            .message_id = message_id,
            .model = owned_model,
            .reasoning_effort = owned_reasoning_effort,
            .sandbox_mode = owned_sandbox_mode,
            .text = owned_text,
            .history = owned_history,
        };
        errdefer task.freeOwned();

        task.thread = try std.Thread.spawn(.{}, run, .{task});
        return task;
    }

    fn takeResult(self: *AgentTask) ?AgentTaskResult {
        if (!self.done.load(.acquire)) return null;
        const result = self.result orelse return null;
        self.result = null;
        return result;
    }

    fn deinit(self: *AgentTask) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.result) |result| {
            result.deinit(self.allocator);
            self.result = null;
        }
        self.freeOwned();
        self.allocator.destroy(self);
    }

    fn freeOwned(self: *AgentTask) void {
        self.allocator.free(self.text);
        self.allocator.free(self.npm_path);
        self.allocator.free(self.model);
        self.allocator.free(self.reasoning_effort);
        self.allocator.free(self.sandbox_mode);
        for (self.history) |entry| {
            self.allocator.free(entry.content);
        }
        self.allocator.free(self.history);
    }

    fn run(self: *AgentTask) void {
        var io_instance: std.Io.Threaded = .init(self.allocator, .{});
        defer io_instance.deinit();

        const task_result = requestTypeScriptResponse(
            self.allocator,
            io_instance.io(),
            self.environ_map,
            self.npm_path,
            self.message_id,
            self.model,
            self.reasoning_effort,
            self.sandbox_mode,
            self.text,
            self.history,
        ) catch |err| AgentTaskResult{
            .failure = std.fmt.allocPrint(
                self.allocator,
                "RPC request failed: {s}",
                .{@errorName(err)},
            ) catch self.allocator.dupe(u8, "RPC request failed") catch unreachable,
        };

        self.result = task_result;
        self.done.store(true, .release);
    }
};

const Model = struct {
    allocator: std.mem.Allocator,
    messages: std.array_list.Managed(ChatMessage),
    composer: zz.TextInput,
    transcript: zz.Viewport,
    header_height: u16,
    show_commands: bool,

    next_id: u64,
    pending_response_id: ?u64,
    pending_response_text: ?[]u8,
    agent_task: ?*AgentTask,
    status: []const u8,
    response_cursor: usize,
    thinking_phase: u8,

    mode: UiMode,
    model_list: zz.List(ModelOption),
    reasoning_list: zz.List(ReasoningOption),
    sandbox_list: zz.List(SandboxOption),
    active_model: []const u8,
    active_reasoning: []const u8,
    active_sandbox: []const u8,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        mouse: zz.MouseEvent,
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
            .transcript = zz.Viewport.init(allocator, ctx.width, transcriptHeight(ctx.height)),
            .header_height = headerHeight(ctx.height),
            .show_commands = false,
            .next_id = 1,
            .pending_response_id = null,
            .pending_response_text = null,
            .agent_task = null,
            .status = "idle",
            .response_cursor = 0,
            .thinking_phase = 0,
            .mode = .chat,
            .model_list = zz.List(ModelOption).init(allocator),
            .reasoning_list = zz.List(ReasoningOption).init(allocator),
            .sandbox_list = zz.List(SandboxOption).init(allocator),
            .active_model = modelOptionLabel(.gpt_5_5),
            .active_reasoning = reasoningOptionLabel(.medium),
            .active_sandbox = sandboxOptionLabel(.workspace_write),
        };
        self.composer.setPrompt("> ");
        self.composer.setPlaceholder("Type your message...");
        self.composer.text_style = self.composer.text_style.fg(.green).bold(true);
        self.composer.prompt_style = self.composer.prompt_style.fg(.green).bold(true);
        self.composer.placeholder_style = self.composer.placeholder_style.fg(.green).bold(true);
        self.composer.cursor_style = self.composer.cursor_style.fg(.black).bg(.green).bold(true);

        self.transcript.setWrap(true);
        self.transcript.setShowScrollbar(true);
        self.initSelectionLists();

        self.resize(ctx.width, ctx.height);
        self.rebuildTranscript() catch {};

        return .{ .set_title = "NexDev - CLI" };
    }

    pub fn deinit(self: *Model) void {
        for (self.messages.items) |*message| {
            message.deinit(self.allocator);
        }
        self.freeAgentTask();
        self.freePendingResponseText();
        self.messages.deinit();
        self.composer.deinit();
        self.transcript.deinit();
        self.model_list.deinit();
        self.reasoning_list.deinit();
        self.sandbox_list.deinit();
    }

    pub fn update(self: *Model, msg: Msg, ctx: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |key| return self.handleKey(key, ctx),
            .mouse => |mouse| return self.handleMouse(mouse),
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

    fn handleMouse(self: *Model, mouse: zz.MouseEvent) zz.Cmd(Msg) {
        if (self.mode != .chat) return .none;
        if (!self.isTranscriptMouseEvent(mouse)) return .none;

        switch (mouse.button) {
            .wheel_up => self.transcript.scrollUp(3),
            .wheel_down => self.transcript.scrollDown(3),
            else => {},
        }

        return .none;
    }

    fn isTranscriptMouseEvent(self: *const Model, mouse: zz.MouseEvent) bool {
        const transcript_top = self.header_height;
        const transcript_bottom = transcript_top + self.transcript.height;
        return mouse.y >= transcript_top and mouse.y < transcript_bottom;
    }

    fn handleKey(self: *Model, key: zz.KeyEvent, ctx: *zz.Context) zz.Cmd(Msg) {
        if (key.modifiers.ctrl and key.key.eql(.{ .char = 'c' })) {
            return .quit;
        }

        return switch (self.mode) {
            .chat => self.handleChatKey(key, ctx),
            .select_model => self.handleModelSelectionKey(key),
            .select_reasoning => self.handleReasoningSelectionKey(key),
            .select_sandbox => self.handleSandboxSelectionKey(key),
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

    fn handleSandboxSelectionKey(self: *Model, key: zz.KeyEvent) zz.Cmd(Msg) {
        switch (key.key) {
            .escape => {
                self.mode = .chat;
                self.status = "idle";
                return .none;
            },
            .enter => {
                if (self.sandbox_list.selectedValue()) |value| {
                    self.active_sandbox = sandboxOptionLabel(value);
                    self.mode = .chat;
                    self.status = "sandbox updated";
                }
                return .none;
            },
            else => {
                self.sandbox_list.handleKey(key);
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
            .sandbox => {
                self.prepareSandboxSelection();
                self.mode = .select_sandbox;
                self.status = "select sandbox mode";
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
        self.status = "Calling TypeScript...";
        self.response_cursor = 0;
        self.thinking_phase = 0;
        self.freePendingResponseText();
        self.freeAgentTask();

        const history = self.rpcHistory(ctx.allocator, assistant_id) catch {
            self.applyAgentFailure(.{ .message_id = assistant_id, .reason = "RPC request failed" }) catch {};
            return .none;
        };
        defer ctx.allocator.free(history);

        const npm_path = resolveExecutable(ctx.allocator, ctx.io, ctx.environ_map, "npm") catch {
            self.applyAgentFailure(.{ .message_id = assistant_id, .reason = "Could not find npm in PATH" }) catch {};
            return .none;
        };
        defer ctx.allocator.free(npm_path);

        self.agent_task = AgentTask.start(
            std.heap.smp_allocator,
            ctx.environ_map,
            npm_path,
            assistant_id,
            self.active_model,
            self.active_reasoning,
            self.active_sandbox,
            user_text,
            history,
        ) catch {
            self.applyAgentFailure(.{ .message_id = assistant_id, .reason = "Failed to start TypeScript RPC task" }) catch {};
            return .none;
        };

        self.composer.setValue("") catch {};
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
        self.freeAgentTask();
        self.response_cursor = 0;
        self.thinking_phase = 0;
        self.mode = .chat;
        self.show_commands = false;
        self.composer.setValue("") catch {};
        self.transcript.setContent("") catch {};
    }

    fn pollAgent(self: *Model) zz.Cmd(Msg) {
        const response_id = self.pending_response_id orelse return .none;
        const response_text = self.pending_response_text orelse {
            const task = self.agent_task orelse return .none;
            const task_result = task.takeResult() orelse {
                self.updateThinkingPlaceholder(response_id) catch {};
                return zz.Cmd(Msg).everyMs(100);
            };
            defer task_result.deinit(task.allocator);
            defer self.freeAgentTask();

            switch (task_result) {
                .text => |text| {
                    self.replaceMessageText(response_id, "") catch {};
                    self.pending_response_text = self.allocator.dupe(u8, text) catch {
                        self.applyAgentFailure(.{ .message_id = response_id, .reason = "Out of memory" }) catch {};
                        return .none;
                    };
                    self.status = "streaming";
                },
                .failure => |reason| {
                    self.replaceMessageText(response_id, "") catch {};
                    self.applyAgentFailure(.{ .message_id = response_id, .reason = reason }) catch {};
                    return .none;
                },
            }

            return zz.Cmd(Msg).everyMs(50);
        };

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

    fn rpcHistory(self: *const Model, allocator: std.mem.Allocator, pending_message_id: u64) ![]RpcChatMessage {
        var count: usize = 0;
        for (self.messages.items) |msg| {
            if (msg.id == pending_message_id) continue;
            if (msg.state != .complete) continue;
            count += 1;
        }

        const history = try allocator.alloc(RpcChatMessage, count);
        var index: usize = 0;
        for (self.messages.items) |msg| {
            if (msg.id == pending_message_id) continue;
            if (msg.state != .complete) continue;

            history[index] = .{
                .role = rpcRoleName(msg.role),
                .content = msg.text,
            };
            index += 1;
        }

        return history;
    }

    fn rpcRoleName(role: app.Role) []const u8 {
        return switch (role) {
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
            .system => "system",
        };
    }

    fn freePendingResponseText(self: *Model) void {
        if (self.pending_response_text) |text| {
            self.allocator.free(text);
            self.pending_response_text = null;
        }
    }

    fn freeAgentTask(self: *Model) void {
        if (self.agent_task) |task| {
            task.deinit();
            self.agent_task = null;
        }
    }

    fn replaceMessageText(self: *Model, message_id: u64, text: []const u8) !void {
        for (self.messages.items) |*msg| {
            if (msg.id == message_id) {
                const old = msg.text;
                msg.text = try self.allocator.dupe(u8, text);
                self.allocator.free(old);
                return;
            }
        }
    }

    fn updateThinkingPlaceholder(self: *Model, message_id: u64) !void {
        const frames = [_][]const u8{
            "Thinking.",
            "Thinking..",
            "Thinking...",
            "Thinking....",
        };
        const frame_index = (@as(usize, self.thinking_phase) / 2) % frames.len;
        self.thinking_phase +%= 1;
        const frame = frames[frame_index];

        try self.replaceMessageText(message_id, frame);
        self.status = frame;
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

        const separator = dim.render(
            allocator,
            "Enter sends | Esc quits | Mouse wheel/PageUp/PageDown scroll",
        ) catch "Enter sends | Esc quits | Mouse wheel/PageUp/PageDown scroll";

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
            .select_sandbox => self.renderSelectionPanel(
                allocator,
                ctx.width,
                "Select Sandbox",
                self.active_sandbox,
                self.sandbox_list.view(allocator) catch "",
            ) catch transcript_view,
        };
        const input_line = green.render(allocator, composer_view) catch composer_view;
        const slash_popup = if (self.show_commands)
            self.renderSlashCommandPopup(allocator) catch ""
        else
            "";

        const top_block = self.renderHeader(allocator, ctx.width, pink, green, dim) catch "NexDev - CLI";

        const body = if (self.show_commands)
            zz.join.vertical(
                allocator,
                .left,
                &.{ top_block, center_view, slash_popup, separator, input_line },
            ) catch top_block
        else
            zz.join.vertical(
                allocator,
                .left,
                &.{ top_block, center_view, separator, input_line },
            ) catch top_block;

        return body;
    }

    fn renderHeader(
        self: *const Model,
        allocator: std.mem.Allocator,
        width: u16,
        title_style: zz.Style,
        meta_style: zz.Style,
        dim_style: zz.Style,
    ) ![]const u8 {
        const title = try title_style.render(allocator, "NexDev - CLI");
        const meta_raw = try std.fmt.allocPrint(
            allocator,
            "Model: {s} | Reasoning: {s} | Sandbox: {s} | Status: {s}",
            .{ self.active_model, self.active_reasoning, self.active_sandbox, self.status },
        );
        const meta = try meta_style.render(allocator, meta_raw);
        const rule = try dim_style.render(allocator, "Chat history is kept in memory for this session");

        const content = if (self.header_height == logo_header_height) blk: {
            const logo_view = try title_style.render(allocator, logo);
            const status_view = try zz.join.vertical(
                allocator,
                .left,
                &.{ title, meta, rule },
            );

            break :blk try zz.join.horizontalSep(
                allocator,
                .top,
                "      ",
                &.{ logo_view, status_view },
            );
        } else try zz.join.vertical(
            allocator,
            .left,
            &.{ title, meta, rule },
        );

        return zz.place.place(allocator, width, self.header_height, .left, .top, content);
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

        self.sandbox_list.height = 5;
        self.sandbox_list.cursor_style = self.sandbox_list.cursor_style.fg(.green).bold(true);
        self.sandbox_list.selected_style = self.sandbox_list.selected_style.fg(.green);
        self.sandbox_list.status_message = "Enter to select";
        self.sandbox_list.addItems(&.{
            zz.List(SandboxOption).Item.withDescription(.read_only, sandboxOptionLabel(.read_only), sandboxOptionDescription(.read_only)),
            zz.List(SandboxOption).Item.withDescription(.workspace_write, sandboxOptionLabel(.workspace_write), sandboxOptionDescription(.workspace_write)),
            zz.List(SandboxOption).Item.withDescription(.danger_full_access, sandboxOptionLabel(.danger_full_access), sandboxOptionDescription(.danger_full_access)),
        }) catch {};

        self.prepareModelSelection();
        self.prepareReasoningSelection();
        self.prepareSandboxSelection();
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

    fn prepareSandboxSelection(self: *Model) void {
        self.sandbox_list.gotoFirst();
        for (self.sandbox_list.items.items, 0..) |item, index| {
            if (std.mem.eql(u8, sandboxOptionLabel(item.value), self.active_sandbox)) {
                self.sandbox_list.cursor = index;
                break;
            }
        }
        self.sandbox_list.selectCurrent();
    }

    pub fn resize(self: *Model, width: u16, height: u16) void {
        self.header_height = headerHeight(height);
        self.transcript.setSize(width, transcriptHeight(height));
        self.composer.setWidth(width -| 2);
    }
};

fn requestTypeScriptResponse(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    npm_path: []const u8,
    message_id: u64,
    model: []const u8,
    reasoning_effort: []const u8,
    sandbox_mode: []const u8,
    text: []const u8,
    history: []const RpcChatMessage,
) !AgentTaskResult {
    var client = try rpc.SubprocessClient.init(allocator, io, &.{ npm_path, "run", "--silent", "agent:rpc" }, .{
        .environ_map = environ_map,
    });
    defer client.deinit();

    var conn = client.connection();
    try conn.sendRequest(.{ .integer = @intCast(message_id) }, "message.received", .{
        .message_id = message_id,
        .model = model,
        .reasoning_effort = reasoning_effort,
        .sandbox_mode = sandbox_mode,
        .text = text,
        .messages = history,
    });
    try client.closeInput();

    var response_message = try conn.readMessage();
    defer response_message.deinit();

    const response = try response_message.asResponse();
    if (response.rpc_error) |rpc_error| {
        const owned_error = try allocator.dupe(u8, rpc_error.message);
        errdefer allocator.free(owned_error);
        try expectExitedZero(try client.wait());
        return .{ .failure = owned_error };
    }

    const response_text = try response.asText();
    const owned_text = try allocator.dupe(u8, response_text);
    errdefer allocator.free(owned_text);
    try expectExitedZero(try client.wait());
    return .{ .text = owned_text };
}

fn resolveExecutable(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    name: []const u8,
) ![]u8 {
    for (name) |char| {
        if (char == '/') return allocator.dupe(u8, name);
    }

    const path_value = environ_map.get("PATH") orelse return error.FileNotFound;
    var path_iter = std.mem.splitScalar(u8, path_value, ':');
    while (path_iter.next()) |dir| {
        if (dir.len == 0) continue;

        const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, name });
        errdefer allocator.free(candidate);

        std.Io.Dir.accessAbsolute(io, candidate, .{ .execute = true }) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.PermissionDenied, error.BadPathName => {
                allocator.free(candidate);
                continue;
            },
            else => return err,
        };

        return candidate;
    }

    return error.FileNotFound;
}

fn expectExitedZero(term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| if (code == 0) return else return error.ChildExitedNonZero,
        else => return error.ChildDidNotExitNormally,
    }
}

fn headerHeight(height: u16) u16 {
    return if (height > logo_header_height + footer_height)
        logo_header_height
    else
        compact_header_height;
}

fn transcriptHeight(height: u16) u16 {
    return height -| headerHeight(height) -| footer_height;
}

pub fn main(init: std.process.Init) !void {
    var program = try zz.Program(Model).initWithOptions(init.gpa, init.io, init.environ_map, .{
        .mouse = true,
    });
    defer program.deinit();
    try program.run();
}

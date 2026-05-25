//! ZigZag TUI model for the NexDev CLI.
//!
//! This file owns the terminal UI lifecycle: state initialization, input
//! handling, view rendering, transcript updates, and bridging user actions to
//! the agent runtime module.

const std = @import("std");
const zz = @import("zigzag");
const app = @import("nexdev_cli");
const agent_runtime = @import("agent.zig");

const ChatMessage = app.ChatMessage;
const AgentDelta = app.AgentDelta;
const AgentDone = app.AgentDone;
const AgentFailed = app.AgentFailed;
const UiMode = app.UiMode;
const ModelOption = app.ModelOption;
const ReasoningOption = app.ReasoningOption;
const SandboxOption = app.SandboxOption;
const AgentOption = app.AgentOption;
const logo = app.logo;
const slash_commands = app.slash_commands;
const modelOptionLabel = app.modelOptionLabel;
const modelOptionDescription = app.modelOptionDescription;
const reasoningOptionLabel = app.reasoningOptionLabel;
const reasoningOptionDescription = app.reasoningOptionDescription;
const sandboxOptionLabel = app.sandboxOptionLabel;
const sandboxOptionDescription = app.sandboxOptionDescription;
const agentOptionLabel = app.agentOptionLabel;
const agentOptionDescription = app.agentOptionDescription;
const resolveSlashAction = app.resolveSlashAction;
const padRight = app.padRight;

const compact_header_height: u16 = 3;
const logo_header_height: u16 = 18;
const footer_height: u16 = 3;

const RpcChatMessage = agent_runtime.RpcChatMessage;
const AgentDraft = agent_runtime.AgentDraft;
const AgentConfig = agent_runtime.AgentConfig;
const AgentTask = agent_runtime.AgentTask;

/// Complete ZigZag model for the interactive chat UI.
pub const Model = struct {
    // Allocator and owned UI widgets.
    allocator: std.mem.Allocator,
    messages: std.array_list.Managed(ChatMessage),
    composer: zz.TextInput,
    behavior_text: zz.TextArea,
    transcript: zz.Viewport,
    header_height: u16,
    show_commands: bool,

    // Runtime response state for the pending assistant message.
    next_id: u64,
    pending_response_id: ?u64,
    pending_response_text: ?[]u8,
    agent_task: ?*AgentTask,
    status: []const u8,
    response_cursor: usize,
    thinking_phase: u8,

    // Current mode and selection controls.
    mode: UiMode,
    model_list: zz.List(ModelOption),
    reasoning_list: zz.List(ReasoningOption),
    sandbox_list: zz.List(SandboxOption),
    agent_list: zz.List(AgentOption),
    agent_record_list: zz.List(usize),
    agent_records: std.array_list.Managed(AgentConfig),
    active_model: []const u8,
    active_reasoning: []const u8,
    active_sandbox: []const u8,
    active_agent_action: []const u8,
    active_agent: ?AgentConfig,
    agent_draft: AgentDraft,
    workspace_path: ?[:0]u8,
    home_path: ?[]u8,

    /// Message types delivered to the ZigZag update loop.
    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        paste: []const u8,
        mouse: zz.MouseEvent,
        window_size: zz.msg.WindowSize,
        tick: zz.msg.Tick,

        agent_delta: AgentDelta,
        agent_done: AgentDone,
        agent_failed: AgentFailed,
    };

    /// Initializes widgets, default selections, and the initial viewport layout.
    pub fn init(self: *Model, ctx: *zz.Context) zz.Cmd(Msg) {
        const allocator = ctx.persistent_allocator;
        const workspace_path: ?[:0]u8 = std.process.currentPathAlloc(ctx.io, allocator) catch null;
        const home_path: ?[]u8 = if (ctx.environ_map.get("HOME") orelse ctx.environ_map.get("USERPROFILE")) |home|
            allocator.dupe(u8, home) catch null
        else
            null;

        self.* = .{
            .allocator = allocator,
            .messages = std.array_list.Managed(ChatMessage).init(allocator),
            .composer = zz.TextInput.init(allocator),
            .behavior_text = zz.TextArea.init(allocator),
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
            .agent_list = zz.List(AgentOption).init(allocator),
            .agent_record_list = zz.List(usize).init(allocator),
            .agent_records = std.array_list.Managed(AgentConfig).init(allocator),
            .active_model = modelOptionLabel(.gpt_5_5),
            .active_reasoning = reasoningOptionLabel(.medium),
            .active_sandbox = sandboxOptionLabel(.workspace_write),
            .active_agent_action = "none",
            .active_agent = null,
            .agent_draft = .{},
            .workspace_path = workspace_path,
            .home_path = home_path,
        };
        self.composer.setPrompt("> ");
        self.composer.setPlaceholder("Type your message...");
        self.composer.text_style = self.composer.text_style.fg(.green).bold(true);
        self.composer.prompt_style = self.composer.prompt_style.fg(.green).bold(true);
        self.composer.placeholder_style = self.composer.placeholder_style.fg(.green).bold(true);
        self.composer.cursor_style = self.composer.cursor_style.fg(.black).bg(.green).bold(true);
        self.behavior_text.placeholder = "Paste or type behavior. Ctrl+Enter continues.";
        self.behavior_text.word_wrap = true;
        self.behavior_text.text_style = self.behavior_text.text_style.fg(.green);
        self.behavior_text.placeholder_style = self.behavior_text.placeholder_style.fg(.gray(10));
        self.behavior_text.cursor_style = self.behavior_text.cursor_style.fg(.black).bg(.green).bold(true);
        self.behavior_text.blur();

        self.transcript.setWrap(true);
        self.transcript.setShowScrollbar(true);
        self.initSelectionLists();

        self.resize(ctx.width, ctx.height);
        self.rebuildTranscript() catch {};

        return .{ .set_title = "NexDev - CLI" };
    }

    /// Releases all owned messages, widgets, agent records, and active tasks.
    pub fn deinit(self: *Model) void {
        for (self.messages.items) |*message| {
            message.deinit(self.allocator);
        }
        self.freeAgentTask();
        self.freePendingResponseText();
        self.agent_draft.deinit(self.allocator);
        if (self.workspace_path) |path| self.allocator.free(path);
        if (self.home_path) |path| self.allocator.free(path);
        self.clearActiveAgent();
        self.clearAgentRecords();
        self.messages.deinit();
        self.composer.deinit();
        self.behavior_text.deinit();
        self.transcript.deinit();
        self.model_list.deinit();
        self.reasoning_list.deinit();
        self.sandbox_list.deinit();
        self.agent_list.deinit();
        self.agent_record_list.deinit();
        self.agent_records.deinit();
    }

    /// Central event dispatcher called by ZigZag.
    pub fn update(self: *Model, msg: Msg, ctx: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |key| return self.handleKey(key, ctx),
            .paste => |text| return self.handlePaste(text),
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

    // Routes mouse wheel events to the transcript when chat mode is active.
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

    // Checks whether a mouse event falls inside the transcript viewport.
    fn isTranscriptMouseEvent(self: *const Model, mouse: zz.MouseEvent) bool {
        const transcript_top = 0;
        const transcript_bottom = transcript_top + self.transcript.height;
        return mouse.y >= transcript_top and mouse.y < transcript_bottom;
    }

    // Dispatches keyboard input according to the active UI mode.
    fn handleKey(self: *Model, key: zz.KeyEvent, ctx: *zz.Context) zz.Cmd(Msg) {
        if (key.modifiers.ctrl and key.key.eql(.{ .char = 'c' })) {
            return .quit;
        }

        return switch (self.mode) {
            .chat => self.handleChatKey(key, ctx),
            .select_model => self.handleModelSelectionKey(key),
            .select_reasoning => self.handleReasoningSelectionKey(key),
            .select_sandbox => self.handleSandboxSelectionKey(key),
            .select_agents => self.handleAgentSelectionKey(key, ctx),
            .select_agent => self.handleAgentRecordSelectionKey(key),
            .create_agent_name, .create_agent_description, .create_agent_behavior, .create_agent_model => self.handleAgentWizardKey(key, ctx),
        };
    }

    // Sends pasted text to whichever input widget currently owns editing.
    fn handlePaste(self: *Model, text: []const u8) zz.Cmd(Msg) {
        const paste_key = zz.KeyEvent{ .key = .{ .paste = text } };

        switch (self.mode) {
            .chat => {
                self.composer.handleKey(paste_key);
                const value = self.composer.getValue();
                self.show_commands = std.mem.startsWith(u8, value, "/");
            },
            .create_agent_name, .create_agent_description, .create_agent_model => {
                self.composer.handleKey(paste_key);
                self.show_commands = false;
            },
            .create_agent_behavior => {
                self.behavior_text.handleKey(paste_key);
                self.show_commands = false;
            },
            else => {},
        }

        return .none;
    }

    // Handles composer input, transcript navigation, and chat submission.
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

    // Handles the `/model` selector.
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

    // Handles the `/reasoning` selector.
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

    // Handles the `/sandbox` selector.
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

    // Handles the `/agents` action selector.
    fn handleAgentSelectionKey(self: *Model, key: zz.KeyEvent, ctx: *zz.Context) zz.Cmd(Msg) {
        switch (key.key) {
            .escape => {
                self.mode = .chat;
                self.status = "idle";
                return .none;
            },
            .enter => {
                if (self.agent_list.selectedValue()) |value| {
                    self.active_agent_action = agentOptionLabel(value);
                    switch (value) {
                        .create => self.startAgentCreation(),
                        .list => self.openAgentList(ctx),
                        .view => {
                            self.mode = .chat;
                            self.status = agentSelectionStatus(value);
                        },
                    }
                }
                return .none;
            },
            else => {
                self.agent_list.handleKey(key);
                return .none;
            },
        }
    }

    // Handles selecting one persisted agent record.
    fn handleAgentRecordSelectionKey(self: *Model, key: zz.KeyEvent) zz.Cmd(Msg) {
        switch (key.key) {
            .escape => {
                self.mode = .chat;
                self.status = "idle";
                return .none;
            },
            .enter => {
                if (self.agent_record_list.selectedValue()) |index| {
                    self.selectAgentRecord(index) catch {
                        self.status = "failed to select agent";
                        return .none;
                    };
                    self.mode = .chat;
                    self.status = "agent selected";
                    self.rebuildTranscript() catch {};
                    self.transcript.gotoBottom();
                } else {
                    self.status = "no agent selected";
                }
                return .none;
            },
            else => {
                self.agent_record_list.handleKey(key);
                return .none;
            },
        }
    }

    // Handles create-agent wizard keys except for the multiline behavior step.
    fn handleAgentWizardKey(self: *Model, key: zz.KeyEvent, ctx: *zz.Context) zz.Cmd(Msg) {
        if (self.mode == .create_agent_behavior) {
            return self.handleAgentBehaviorKey(key, ctx);
        }

        switch (key.key) {
            .escape => {
                self.cancelAgentCreation();
                return .none;
            },
            .enter => return self.submitAgentWizardStep(ctx),
            else => {
                self.composer.handleKey(key);
                self.show_commands = false;
                return .none;
            },
        }
    }

    // Handles the multiline behavior editor in the create-agent wizard.
    fn handleAgentBehaviorKey(self: *Model, key: zz.KeyEvent, ctx: *zz.Context) zz.Cmd(Msg) {
        if (key.modifiers.ctrl and key.key.eql(.{ .char = 'd' })) {
            return self.submitAgentWizardStep(ctx);
        }

        switch (key.key) {
            .escape => {
                self.cancelAgentCreation();
                return .none;
            },
            .enter => {
                if (key.modifiers.ctrl) {
                    return self.submitAgentWizardStep(ctx);
                }

                self.behavior_text.handleKey(key);
                return .none;
            },
            else => {
                self.behavior_text.handleKey(key);
                self.show_commands = false;
                return .none;
            },
        }
    }

    // Distinguishes slash commands from normal chat messages on Enter.
    fn handleComposerSubmit(self: *Model, ctx: *zz.Context) zz.Cmd(Msg) {
        const raw = self.composer.getValue();
        const trimmed = std.mem.trim(u8, raw, " \t\n\r");

        if (std.mem.startsWith(u8, trimmed, "/")) {
            return self.handleSlashCommand(trimmed);
        }

        return self.submit(ctx);
    }

    // Applies a resolved slash command by switching mode or clearing state.
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
            .agents => {
                self.prepareAgentSelection();
                self.mode = .select_agents;
                self.status = "select agent action";
            },
            .clear => {
                self.clearSession();
                self.status = "session cleared";
            },
        }

        return .none;
    }

    // Adds the user message, starts an agent task, and begins polling ticks.
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

        const node_path = agent_runtime.resolveExecutable(ctx.allocator, ctx.io, ctx.environ_map, "node") catch {
            self.applyAgentFailure(.{ .message_id = assistant_id, .reason = "Could not find node in PATH" }) catch {};
            return .none;
        };
        defer ctx.allocator.free(node_path);

        const agent_entrypoint = agent_runtime.resolveAgentEntrypoint(ctx.allocator, ctx.io, ctx.environ_map) catch {
            self.applyAgentFailure(.{ .message_id = assistant_id, .reason = "Could not find bundled TypeScript agent runtime" }) catch {};
            return .none;
        };
        defer ctx.allocator.free(agent_entrypoint);

        self.agent_task = AgentTask.start(
            std.heap.smp_allocator,
            ctx.environ_map,
            node_path,
            agent_entrypoint,
            assistant_id,
            self.activeModelLabel(),
            self.active_reasoning,
            self.active_sandbox,
            self.activeAgentBehavior(),
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

    // Clears transient chat state while keeping reusable widgets allocated.
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
        self.composer.setPlaceholder("Type your message...");
        self.behavior_text.setValue("") catch {};
        self.behavior_text.blur();
        self.agent_draft.deinit(self.allocator);
        self.transcript.setContent("") catch {};
    }

    // Polls the background agent task and converts its result into UI events.
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

    // Appends streamed text to the pending assistant message.
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

    // Builds the completed-message history sent to the agent runtime.
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

    // Maps local role enum values to JSON-RPC role strings.
    fn rpcRoleName(role: app.Role) []const u8 {
        return switch (role) {
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
            .system => "system",
        };
    }

    // Frees any buffered response text that is being streamed into the UI.
    fn freePendingResponseText(self: *Model) void {
        if (self.pending_response_text) |text| {
            self.allocator.free(text);
            self.pending_response_text = null;
        }
    }

    // Joins and frees the active background task if one exists.
    fn freeAgentTask(self: *Model) void {
        if (self.agent_task) |task| {
            task.deinit();
            self.agent_task = null;
        }
    }

    // Replaces one transcript message body with an owned copy of `text`.
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

    // Animates a simple placeholder while the blocking agent task is running.
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

    // Marks the pending assistant message as failed and appends the reason.
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

    // Marks a streamed assistant message complete once all chunks are applied.
    fn markMessageComplete(self: *Model, message_id: u64) void {
        for (self.messages.items) |*msg| {
            if (msg.id == message_id) {
                msg.state = .complete;
                return;
            }
        }
    }

    // Re-renders the transcript viewport from the in-memory message list.
    fn rebuildTranscript(self: *Model) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        const writer = &out.writer;

        const title_style = (zz.Style{}).fg(zz.Color.fromRgb(255, 132, 190)).bold(true);
        const dim_style = (zz.Style{}).fg(.gray(10));

        const header = try self.renderHeader(
            self.allocator,
            self.transcript.width,
            title_style,
            dim_style,
        );
        defer self.allocator.free(header);
        try writer.writeAll(header);

        for (self.messages.items) |msg| {
            try writer.writeAll("\n\n");

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

    /// Builds the full terminal frame for the current UI mode.
    pub fn view(self: *const Model, ctx: *const zz.Context) []const u8 {
        const allocator = ctx.allocator;

        const transcript_view = self.transcript.view(allocator) catch "";
        const composer_view = self.composer.view(allocator) catch "";

        const green = (zz.Style{}).fg(.green).bold(true);
        const pink = (zz.Style{}).fg(zz.Color.fromRgb(255, 132, 190)).bold(true);
        const dim = (zz.Style{}).fg(.gray(10));

        const footer_status = self.renderFooterStatus(allocator, green, ctx.width) catch "";
        const separator_text = modeFooterText(self.mode);
        const separator = dim.render(allocator, separator_text) catch separator_text;

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
            .select_agents => self.renderSelectionPanel(
                allocator,
                ctx.width,
                "Agents",
                self.active_agent_action,
                self.agent_list.view(allocator) catch "",
            ) catch transcript_view,
            .select_agent => self.renderSelectionPanel(
                allocator,
                ctx.width,
                "Select Agent",
                self.activeAgentLabel(),
                self.agent_record_list.view(allocator) catch "",
            ) catch transcript_view,
            .create_agent_name, .create_agent_description, .create_agent_behavior, .create_agent_model => self.renderAgentWizardPanel(
                allocator,
                ctx.width,
            ) catch transcript_view,
        };
        const input_line = if (self.mode == .create_agent_behavior)
            ""
        else
            green.render(allocator, composer_view) catch composer_view;
        const slash_popup = if (self.show_commands)
            self.renderSlashCommandPopup(allocator) catch ""
        else
            "";

        const top_block = self.renderHeader(allocator, ctx.width, pink, dim) catch "NexDev - CLI";

        const body = if (self.mode == .chat)
            if (self.show_commands)
                zz.join.vertical(
                    allocator,
                    .left,
                    &.{ center_view, slash_popup, footer_status, separator, input_line },
                ) catch center_view
            else
                zz.join.vertical(
                    allocator,
                    .left,
                    &.{ center_view, footer_status, separator, input_line },
                ) catch center_view
        else if (self.show_commands)
            zz.join.vertical(
                allocator,
                .left,
                &.{ top_block, center_view, slash_popup, footer_status, separator, input_line },
            ) catch top_block
        else
            zz.join.vertical(
                allocator,
                .left,
                &.{ top_block, center_view, footer_status, separator, input_line },
            ) catch top_block;

        return body;
    }

    // Renders the compact or logo header depending on terminal height.
    fn renderHeader(
        self: *const Model,
        allocator: std.mem.Allocator,
        width: u16,
        title_style: zz.Style,
        dim_style: zz.Style,
    ) ![]const u8 {
        const title = try title_style.render(allocator, "NexDev - CLI");
        defer allocator.free(title);
        const rule = try dim_style.render(allocator, "Chat history is kept in memory for this session");
        defer allocator.free(rule);

        const content = if (self.header_height == logo_header_height) blk: {
            const logo_view = try title_style.render(allocator, logo);
            defer allocator.free(logo_view);
            const status_view = try zz.join.vertical(
                allocator,
                .left,
                &.{ title, rule },
            );
            defer allocator.free(status_view);

            break :blk try zz.join.horizontalSep(
                allocator,
                .top,
                "      ",
                &.{ logo_view, status_view },
            );
        } else try zz.join.vertical(
            allocator,
            .left,
            &.{ title, rule },
        );
        defer allocator.free(content);

        return zz.place.place(allocator, width, self.header_height, .left, .top, content);
    }

    // Renders the fixed session metadata row above the footer shortcuts.
    fn renderFooterStatus(
        self: *const Model,
        allocator: std.mem.Allocator,
        style: zz.Style,
        width: u16,
    ) ![]const u8 {
        const workspace = try self.renderWorkspaceLabel(allocator);
        defer allocator.free(workspace);

        const raw = try std.fmt.allocPrint(
            allocator,
            "Model: {s} | Agent: {s} | Reasoning: {s} | Sandbox: {s} | Status: {s} | Workspace: {s}",
            .{ self.activeModelLabel(), self.activeAgentLabel(), self.active_reasoning, self.active_sandbox, self.status, workspace },
        );
        defer allocator.free(raw);

        const truncated = try truncateAscii(allocator, raw, width);
        defer allocator.free(truncated);

        return style.render(allocator, truncated);
    }

    // Returns the active workspace with the home directory shortened to `~`.
    fn renderWorkspaceLabel(self: *const Model, allocator: std.mem.Allocator) ![]const u8 {
        const path = self.workspace_path orelse return allocator.dupe(u8, "(unknown)");
        const home = self.home_path orelse return allocator.dupe(u8, path);
        if (home.len == 0) return allocator.dupe(u8, path);

        if (std.mem.eql(u8, path, home)) {
            return allocator.dupe(u8, "~");
        }

        if (path.len > home.len and std.mem.startsWith(u8, path, home) and isPathSeparator(path[home.len])) {
            return std.fmt.allocPrint(allocator, "~{s}", .{path[home.len..]});
        }

        return allocator.dupe(u8, path);
    }

    // Wraps a list component in the common centered selector panel.
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

    // Renders the current create-agent wizard step.
    fn renderAgentWizardPanel(
        self: *const Model,
        allocator: std.mem.Allocator,
        width: u16,
    ) ![]const u8 {
        const green = (zz.Style{}).fg(.green).bold(true);
        const dim = (zz.Style{}).fg(.gray(10));

        const title_view = try green.render(allocator, "Create Agent");
        const step_view = try dim.render(allocator, agentWizardStepLabel(self.mode));
        const prompt_view = try std.fmt.allocPrint(allocator, "{s}: {s}", .{
            agentWizardFieldLabel(self.mode),
            agentWizardPrompt(self.mode),
        });
        const name_view = try std.fmt.allocPrint(allocator, "Name: {s}", .{self.agent_draft.name orelse "(not set)"});
        const description_view = try std.fmt.allocPrint(allocator, "Description: {s}", .{self.agent_draft.description orelse "(not set)"});
        const behavior_view = if (self.agent_draft.behavior) |behavior|
            try std.fmt.allocPrint(allocator, "Behavior: {d} chars", .{behavior.len})
        else
            try std.fmt.allocPrint(allocator, "Behavior: {s}", .{"(not set)"});
        const model_view = try std.fmt.allocPrint(allocator, "Model: {s}", .{self.agent_draft.model orelse "(not set)"});
        const help_view = try dim.render(allocator, agentWizardHelp(self.mode));

        const content = if (self.mode == .create_agent_behavior) blk: {
            const editor_view = try self.behavior_text.view(allocator);
            break :blk try zz.join.vertical(
                allocator,
                .left,
                &.{
                    title_view,
                    step_view,
                    "",
                    prompt_view,
                    "",
                    name_view,
                    description_view,
                    behavior_view,
                    model_view,
                    "",
                    editor_view,
                    "",
                    help_view,
                },
            );
        } else try zz.join.vertical(
            allocator,
            .left,
            &.{
                title_view,
                step_view,
                "",
                prompt_view,
                "",
                name_view,
                description_view,
                behavior_view,
                model_view,
                "",
                help_view,
            },
        );

        const panel = (zz.Style{})
            .borderAll(.rounded)
            .borderForeground(.green)
            .paddingAll(1)
            .width(72)
            .render(allocator, content) catch content;

        return zz.place.place(allocator, width, agentWizardPanelHeight(self.mode), .center, .middle, panel);
    }

    // Renders slash-command suggestions below the transcript.
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

    // Populates selector lists and applies the shared green selection styling.
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

        self.agent_list.height = 5;
        self.agent_list.cursor_style = self.agent_list.cursor_style.fg(.green).bold(true);
        self.agent_list.selected_style = self.agent_list.selected_style.fg(.green);
        self.agent_list.status_message = "Enter to select";
        self.agent_list.addItems(&.{
            zz.List(AgentOption).Item.withDescription(.create, agentOptionLabel(.create), agentOptionDescription(.create)),
            zz.List(AgentOption).Item.withDescription(.list, agentOptionLabel(.list), agentOptionDescription(.list)),
            zz.List(AgentOption).Item.withDescription(.view, agentOptionLabel(.view), agentOptionDescription(.view)),
        }) catch {};

        self.agent_record_list.height = 8;
        self.agent_record_list.cursor_style = self.agent_record_list.cursor_style.fg(.green).bold(true);
        self.agent_record_list.selected_style = self.agent_record_list.selected_style.fg(.green);
        self.agent_record_list.status_message = "Enter to use agent";

        self.prepareModelSelection();
        self.prepareReasoningSelection();
        self.prepareSandboxSelection();
        self.prepareAgentSelection();
    }

    // Moves the model list cursor to the active model.
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

    // Moves the reasoning list cursor to the active effort.
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

    // Moves the sandbox list cursor to the active sandbox.
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

    // Moves the agent action list cursor to the last selected action.
    fn prepareAgentSelection(self: *Model) void {
        self.agent_list.gotoFirst();
        for (self.agent_list.items.items, 0..) |item, index| {
            if (std.mem.eql(u8, agentOptionLabel(item.value), self.active_agent_action)) {
                self.agent_list.cursor = index;
                break;
            }
        }
        self.agent_list.selectCurrent();
    }

    // Moves the persisted-agent list cursor to the active agent when possible.
    fn prepareAgentRecordSelection(self: *Model) void {
        self.agent_record_list.gotoFirst();
        if (self.active_agent) |active| {
            for (self.agent_records.items, 0..) |record, index| {
                if (std.mem.eql(u8, record.path, active.path)) {
                    self.agent_record_list.cursor = index;
                    break;
                }
            }
        }
        self.agent_record_list.selectCurrent();
    }

    // Loads persisted agents from disk and opens the record selector.
    fn openAgentList(self: *Model, ctx: *zz.Context) void {
        self.clearAgentRecords();

        agent_runtime.loadAgentRecords(
            self.allocator,
            ctx.io,
            ctx.environ_map,
            &self.agent_records,
        ) catch {
            self.clearAgentRecords();
            self.mode = .chat;
            self.status = "failed to load agents";
            return;
        };

        for (self.agent_records.items, 0..) |record, index| {
            self.agent_record_list.addItem(.withDescription(index, record.name, record.description)) catch {
                self.clearAgentRecords();
                self.mode = .chat;
                self.status = "failed to build agent list";
                return;
            };
        }

        self.prepareAgentRecordSelection();
        self.mode = .select_agent;
        self.status = if (self.agent_records.items.len == 0) "no agents found" else "select agent";
    }

    // Clones the selected persisted agent into active session state.
    fn selectAgentRecord(self: *Model, index: usize) !void {
        if (index >= self.agent_records.items.len) return error.InvalidAgentSelection;

        const selected = try self.agent_records.items[index].clone(self.allocator);
        self.clearActiveAgent();
        self.active_agent = selected;

        self.appendSystemNotice(
            "Agent \"{s}\" selected.",
            .{self.active_agent.?.name},
        ) catch {};
    }

    // Returns the header label for the active agent.
    fn activeAgentLabel(self: *const Model) []const u8 {
        return if (self.active_agent) |agent| agent.name else "none";
    }

    // Agent-specific model settings override the global model selector.
    fn activeModelLabel(self: *const Model) []const u8 {
        if (self.active_agent) |agent| {
            if (agent.model.len > 0) return agent.model;
        }
        return self.active_model;
    }

    // Returns the selected agent instructions, or empty instructions otherwise.
    fn activeAgentBehavior(self: *const Model) []const u8 {
        if (self.active_agent) |agent| return agent.behavior;
        return "";
    }

    // Frees the active agent clone.
    fn clearActiveAgent(self: *Model) void {
        if (self.active_agent) |*agent| {
            agent.deinit(self.allocator);
            self.active_agent = null;
        }
    }

    // Frees loaded agent records and clears the selector items.
    fn clearAgentRecords(self: *Model) void {
        for (self.agent_records.items) |*record| {
            record.deinit(self.allocator);
        }
        self.agent_records.clearRetainingCapacity();
        self.agent_record_list.clear();
    }

    // Enters the first step of the create-agent wizard.
    fn startAgentCreation(self: *Model) void {
        self.agent_draft.deinit(self.allocator);
        self.mode = .create_agent_name;
        self.status = "enter agent name";
        self.show_commands = false;
        self.composer.setValue("") catch {};
        self.composer.setPlaceholder("Agent name");
        self.behavior_text.setValue("") catch {};
        self.behavior_text.blur();
    }

    // Leaves the create-agent wizard and discards draft data.
    fn cancelAgentCreation(self: *Model) void {
        self.agent_draft.deinit(self.allocator);
        self.mode = .chat;
        self.status = "agent creation canceled";
        self.composer.setValue("") catch {};
        self.composer.setPlaceholder("Type your message...");
        self.behavior_text.setValue("") catch {};
        self.behavior_text.blur();
    }

    // Validates and stores the current create-agent wizard step.
    fn submitAgentWizardStep(self: *Model, ctx: *zz.Context) zz.Cmd(Msg) {
        if (self.mode == .create_agent_behavior) {
            return self.submitAgentBehaviorStep();
        }

        const raw = self.composer.getValue();
        const trimmed = std.mem.trim(u8, raw, " \t\n\r");
        if (trimmed.len == 0) {
            self.status = agentWizardRequiredStatus(self.mode);
            return .none;
        }

        switch (self.mode) {
            .create_agent_name => {
                self.replaceAgentDraftField(&self.agent_draft.name, trimmed) catch {
                    self.status = "failed to save agent name";
                    return .none;
                };
                self.mode = .create_agent_description;
                self.status = "enter agent description";
                self.composer.setValue("") catch {};
                self.composer.setPlaceholder("Agent description");
            },
            .create_agent_description => {
                self.replaceAgentDraftField(&self.agent_draft.description, trimmed) catch {
                    self.status = "failed to save description";
                    return .none;
                };
                self.mode = .create_agent_behavior;
                self.status = "enter agent behavior";
                self.composer.setValue("") catch {};
                self.behavior_text.setValue("") catch {};
                self.behavior_text.focus();
            },
            .create_agent_model => {
                if (!agent_runtime.isKnownModelLabel(trimmed)) {
                    self.status = "unknown agent model";
                    return .none;
                }

                self.replaceAgentDraftField(&self.agent_draft.model, trimmed) catch {
                    self.status = "failed to save model";
                    return .none;
                };

                const saved_path = agent_runtime.saveAgentDraft(
                    self.allocator,
                    ctx.io,
                    ctx.environ_map,
                    self.agent_draft,
                ) catch {
                    self.status = "failed to persist agent";
                    return .none;
                };
                defer self.allocator.free(saved_path);

                self.appendSystemNotice(
                    "Created agent \"{s}\".\nSaved to: {s}",
                    .{ self.agent_draft.name.?, saved_path },
                ) catch {};
                self.agent_draft.deinit(self.allocator);
                self.mode = .chat;
                self.status = "agent created";
                self.composer.setValue("") catch {};
                self.composer.setPlaceholder("Type your message...");
                self.behavior_text.setValue("") catch {};
                self.behavior_text.blur();
                self.rebuildTranscript() catch {};
                self.transcript.gotoBottom();
            },
            else => {},
        }

        return .none;
    }

    // Stores the multiline behavior step and advances to model entry.
    fn submitAgentBehaviorStep(self: *Model) zz.Cmd(Msg) {
        const raw = self.behavior_text.getValue(self.allocator) catch {
            self.status = "failed to read behavior";
            return .none;
        };
        defer self.allocator.free(raw);

        const trimmed = std.mem.trim(u8, raw, " \t\n\r");
        if (trimmed.len == 0) {
            self.status = agentWizardRequiredStatus(self.mode);
            return .none;
        }

        self.replaceAgentDraftField(&self.agent_draft.behavior, trimmed) catch {
            self.status = "failed to save behavior";
            return .none;
        };
        self.mode = .create_agent_model;
        self.status = "enter agent model";
        self.composer.setValue("") catch {};
        self.composer.setPlaceholder(self.active_model);
        self.behavior_text.setValue("") catch {};
        self.behavior_text.blur();

        return .none;
    }

    // Replaces one owned draft field with a trimmed copy.
    fn replaceAgentDraftField(self: *Model, field: *?[]u8, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        if (field.*) |old| self.allocator.free(old);
        field.* = owned;
    }

    // Adds a system message to the transcript for local UI notices.
    fn appendSystemNotice(self: *Model, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.allocator, fmt, args);
        errdefer self.allocator.free(text);

        const id = self.next_id;
        self.next_id += 1;
        try self.messages.append(.{
            .id = id,
            .role = .system,
            .text = text,
            .state = .complete,
        });
    }

    /// Recomputes component sizes after terminal resize.
    pub fn resize(self: *Model, width: u16, height: u16) void {
        self.header_height = headerHeight(height);
        self.transcript.setSize(width, transcriptHeight(height));
        self.composer.setWidth(width -| 2);
        self.behavior_text.setSize(agentBehaviorEditorWidth(width), agentBehaviorEditorHeight(height));
    }
};

// Status text used after choosing an agent action.
fn agentSelectionStatus(option: AgentOption) []const u8 {
    return switch (option) {
        .create => "agent create selected",
        .list => "agent list selected",
        .view => "agent view selected",
    };
}

// Truncates footer text with an ASCII ellipsis so it stays on one terminal row.
fn truncateAscii(allocator: std.mem.Allocator, text: []const u8, width: u16) ![]const u8 {
    const max_width: usize = width;
    if (max_width == 0) return allocator.dupe(u8, "");
    if (text.len <= max_width) return allocator.dupe(u8, text);
    if (max_width <= 3) return allocator.dupe(u8, text[0..max_width]);

    return std.fmt.allocPrint(allocator, "{s}...", .{text[0 .. max_width - 3]});
}

// Accepts POSIX and Windows separators for home-relative workspace labels.
fn isPathSeparator(char: u8) bool {
    return char == '/' or char == '\\';
}

// Footer help text for the active mode.
fn modeFooterText(mode: UiMode) []const u8 {
    return switch (mode) {
        .chat => "Enter sends | Esc quits | Mouse wheel/PageUp/PageDown scroll",
        .select_model, .select_reasoning, .select_sandbox, .select_agents, .select_agent => "Enter selects | Esc cancels",
        .create_agent_behavior => "Enter inserts newline | Ctrl+D or Ctrl+Enter continues | Esc cancels",
        .create_agent_name, .create_agent_description, .create_agent_model => "Enter continues | Esc cancels",
    };
}

// Human-readable create-agent wizard step indicator.
fn agentWizardStepLabel(mode: UiMode) []const u8 {
    return switch (mode) {
        .create_agent_name => "Step 1 of 4",
        .create_agent_description => "Step 2 of 4",
        .create_agent_behavior => "Step 3 of 4",
        .create_agent_model => "Step 4 of 4",
        else => "",
    };
}

// Field label for the active create-agent wizard step.
fn agentWizardFieldLabel(mode: UiMode) []const u8 {
    return switch (mode) {
        .create_agent_name => "Name",
        .create_agent_description => "Description",
        .create_agent_behavior => "Behavior",
        .create_agent_model => "Model",
        else => "",
    };
}

// Prompt text for the active create-agent wizard step.
fn agentWizardPrompt(mode: UiMode) []const u8 {
    return switch (mode) {
        .create_agent_name => "Enter a short display name for this agent",
        .create_agent_description => "Describe when this agent should be used",
        .create_agent_behavior => "Describe how this agent should behave",
        .create_agent_model => "Enter the model this agent should use",
        else => "",
    };
}

// Validation status when the active wizard field is empty.
fn agentWizardRequiredStatus(mode: UiMode) []const u8 {
    return switch (mode) {
        .create_agent_name => "agent name is required",
        .create_agent_description => "agent description is required",
        .create_agent_behavior => "agent behavior is required",
        .create_agent_model => "agent model is required",
        else => "value is required",
    };
}

// Help text shown inside the create-agent wizard panel.
fn agentWizardHelp(mode: UiMode) []const u8 {
    return if (mode == .create_agent_behavior)
        "Enter inserts newline | Ctrl+D or Ctrl+Enter continues | Esc cancels"
    else
        "Enter continues | Esc cancels";
}

// Panel height is taller for the multiline behavior editor.
fn agentWizardPanelHeight(mode: UiMode) u16 {
    return if (mode == .create_agent_behavior) 24 else 14;
}

// Computes a bounded editor width so the wizard remains usable on small terminals.
fn agentBehaviorEditorWidth(width: u16) u16 {
    var editor_width = width -| 8;
    if (editor_width > 68) editor_width = 68;
    if (editor_width < 20) editor_width = 20;
    return editor_width;
}

// Computes a bounded editor height for the multiline behavior step.
fn agentBehaviorEditorHeight(height: u16) u16 {
    var editor_height = height / 3;
    if (editor_height > 12) editor_height = 12;
    if (editor_height < 8) editor_height = 8;
    return editor_height;
}

// Chooses between compact and logo header layouts.
fn headerHeight(height: u16) u16 {
    return if (height > logo_header_height + footer_height)
        logo_header_height
    else
        compact_header_height;
}

// Leaves room for header and footer when sizing the transcript viewport.
fn transcriptHeight(height: u16) u16 {
    return height -| footer_height;
}

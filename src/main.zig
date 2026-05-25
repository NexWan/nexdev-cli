const std = @import("std");
const builtin = @import("builtin");
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

const RpcChatMessage = struct {
    role: []const u8,
    content: []const u8,
};

const AgentDraft = struct {
    name: ?[]u8 = null,
    description: ?[]u8 = null,
    behavior: ?[]u8 = null,
    model: ?[]u8 = null,

    fn deinit(self: *AgentDraft, allocator: std.mem.Allocator) void {
        if (self.name) |value| allocator.free(value);
        if (self.description) |value| allocator.free(value);
        if (self.behavior) |value| allocator.free(value);
        if (self.model) |value| allocator.free(value);
        self.* = .{};
    }
};

const AgentConfig = struct {
    name: []u8,
    description: []u8,
    behavior: []u8,
    model: []u8,
    path: []u8,

    fn deinit(self: *AgentConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.behavior);
        allocator.free(self.model);
        allocator.free(self.path);
        self.* = undefined;
    }

    fn clone(self: AgentConfig, allocator: std.mem.Allocator) !AgentConfig {
        const name = try allocator.dupe(u8, self.name);
        errdefer allocator.free(name);

        const description = try allocator.dupe(u8, self.description);
        errdefer allocator.free(description);

        const behavior = try allocator.dupe(u8, self.behavior);
        errdefer allocator.free(behavior);

        const model = try allocator.dupe(u8, self.model);
        errdefer allocator.free(model);

        const path = try allocator.dupe(u8, self.path);
        errdefer allocator.free(path);

        return .{
            .name = name,
            .description = description,
            .behavior = behavior,
            .model = model,
            .path = path,
        };
    }
};

const AgentFileJson = struct {
    version: u32 = 1,
    name: []const u8,
    description: []const u8,
    behavior: []const u8,
    model: []const u8,
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
    node_path: []u8,
    agent_entrypoint: []u8,
    message_id: u64,
    model: []u8,
    reasoning_effort: []u8,
    sandbox_mode: []u8,
    system_instruction: []u8,
    text: []u8,
    history: []RpcChatMessage,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    result: ?AgentTaskResult = null,

    fn start(
        allocator: std.mem.Allocator,
        environ_map: *const std.process.Environ.Map,
        node_path: []const u8,
        agent_entrypoint: []const u8,
        message_id: u64,
        model: []const u8,
        reasoning_effort: []const u8,
        sandbox_mode: []const u8,
        system_instruction: []const u8,
        text: []const u8,
        history: []const RpcChatMessage,
    ) !*AgentTask {
        const task = try allocator.create(AgentTask);
        errdefer allocator.destroy(task);

        const owned_text = try allocator.dupe(u8, text);
        errdefer allocator.free(owned_text);

        const owned_node_path = try allocator.dupe(u8, node_path);
        errdefer allocator.free(owned_node_path);

        const owned_agent_entrypoint = try allocator.dupe(u8, agent_entrypoint);
        errdefer allocator.free(owned_agent_entrypoint);

        const owned_model = try allocator.dupe(u8, model);
        errdefer allocator.free(owned_model);

        const owned_reasoning_effort = try allocator.dupe(u8, reasoning_effort);
        errdefer allocator.free(owned_reasoning_effort);

        const owned_sandbox_mode = try allocator.dupe(u8, sandbox_mode);
        errdefer allocator.free(owned_sandbox_mode);

        const owned_system_instruction = try allocator.dupe(u8, system_instruction);
        errdefer allocator.free(owned_system_instruction);

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
            .node_path = owned_node_path,
            .agent_entrypoint = owned_agent_entrypoint,
            .message_id = message_id,
            .model = owned_model,
            .reasoning_effort = owned_reasoning_effort,
            .sandbox_mode = owned_sandbox_mode,
            .system_instruction = owned_system_instruction,
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
        self.allocator.free(self.node_path);
        self.allocator.free(self.agent_entrypoint);
        self.allocator.free(self.model);
        self.allocator.free(self.reasoning_effort);
        self.allocator.free(self.sandbox_mode);
        self.allocator.free(self.system_instruction);
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
            self.node_path,
            self.agent_entrypoint,
            self.message_id,
            self.model,
            self.reasoning_effort,
            self.sandbox_mode,
            self.system_instruction,
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
    behavior_text: zz.TextArea,
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
    agent_list: zz.List(AgentOption),
    agent_record_list: zz.List(usize),
    agent_records: std.array_list.Managed(AgentConfig),
    active_model: []const u8,
    active_reasoning: []const u8,
    active_sandbox: []const u8,
    active_agent_action: []const u8,
    active_agent: ?AgentConfig,
    agent_draft: AgentDraft,

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

    pub fn init(self: *Model, ctx: *zz.Context) zz.Cmd(Msg) {
        const allocator = ctx.persistent_allocator;

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

    pub fn deinit(self: *Model) void {
        for (self.messages.items) |*message| {
            message.deinit(self.allocator);
        }
        self.freeAgentTask();
        self.freePendingResponseText();
        self.agent_draft.deinit(self.allocator);
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
            .select_agents => self.handleAgentSelectionKey(key, ctx),
            .select_agent => self.handleAgentRecordSelectionKey(key),
            .create_agent_name, .create_agent_description, .create_agent_behavior, .create_agent_model => self.handleAgentWizardKey(key, ctx),
        };
    }

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

        const node_path = resolveExecutable(ctx.allocator, ctx.io, ctx.environ_map, "node") catch {
            self.applyAgentFailure(.{ .message_id = assistant_id, .reason = "Could not find node in PATH" }) catch {};
            return .none;
        };
        defer ctx.allocator.free(node_path);

        const agent_entrypoint = resolveAgentEntrypoint(ctx.allocator, ctx.io, ctx.environ_map) catch {
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
            "Model: {s} | Agent: {s} | Reasoning: {s} | Sandbox: {s} | Status: {s}",
            .{ self.activeModelLabel(), self.activeAgentLabel(), self.active_reasoning, self.active_sandbox, self.status },
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

    fn openAgentList(self: *Model, ctx: *zz.Context) void {
        self.clearAgentRecords();

        loadAgentRecords(
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

    fn activeAgentLabel(self: *const Model) []const u8 {
        return if (self.active_agent) |agent| agent.name else "none";
    }

    fn activeModelLabel(self: *const Model) []const u8 {
        if (self.active_agent) |agent| {
            if (agent.model.len > 0) return agent.model;
        }
        return self.active_model;
    }

    fn activeAgentBehavior(self: *const Model) []const u8 {
        if (self.active_agent) |agent| return agent.behavior;
        return "";
    }

    fn clearActiveAgent(self: *Model) void {
        if (self.active_agent) |*agent| {
            agent.deinit(self.allocator);
            self.active_agent = null;
        }
    }

    fn clearAgentRecords(self: *Model) void {
        for (self.agent_records.items) |*record| {
            record.deinit(self.allocator);
        }
        self.agent_records.clearRetainingCapacity();
        self.agent_record_list.clear();
    }

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

    fn cancelAgentCreation(self: *Model) void {
        self.agent_draft.deinit(self.allocator);
        self.mode = .chat;
        self.status = "agent creation canceled";
        self.composer.setValue("") catch {};
        self.composer.setPlaceholder("Type your message...");
        self.behavior_text.setValue("") catch {};
        self.behavior_text.blur();
    }

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
                if (!isKnownModelLabel(trimmed)) {
                    self.status = "unknown agent model";
                    return .none;
                }

                self.replaceAgentDraftField(&self.agent_draft.model, trimmed) catch {
                    self.status = "failed to save model";
                    return .none;
                };

                const saved_path = saveAgentDraft(
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

    fn replaceAgentDraftField(self: *Model, field: *?[]u8, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        if (field.*) |old| self.allocator.free(old);
        field.* = owned;
    }

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

    pub fn resize(self: *Model, width: u16, height: u16) void {
        self.header_height = headerHeight(height);
        self.transcript.setSize(width, transcriptHeight(height));
        self.composer.setWidth(width -| 2);
        self.behavior_text.setSize(agentBehaviorEditorWidth(width), agentBehaviorEditorHeight(height));
    }
};

fn agentSelectionStatus(option: AgentOption) []const u8 {
    return switch (option) {
        .create => "agent create selected",
        .list => "agent list selected",
        .view => "agent view selected",
    };
}

fn modeFooterText(mode: UiMode) []const u8 {
    return switch (mode) {
        .chat => "Enter sends | Esc quits | Mouse wheel/PageUp/PageDown scroll",
        .select_model, .select_reasoning, .select_sandbox, .select_agents, .select_agent => "Enter selects | Esc cancels",
        .create_agent_behavior => "Enter inserts newline | Ctrl+D or Ctrl+Enter continues | Esc cancels",
        .create_agent_name, .create_agent_description, .create_agent_model => "Enter continues | Esc cancels",
    };
}

fn agentWizardStepLabel(mode: UiMode) []const u8 {
    return switch (mode) {
        .create_agent_name => "Step 1 of 4",
        .create_agent_description => "Step 2 of 4",
        .create_agent_behavior => "Step 3 of 4",
        .create_agent_model => "Step 4 of 4",
        else => "",
    };
}

fn agentWizardFieldLabel(mode: UiMode) []const u8 {
    return switch (mode) {
        .create_agent_name => "Name",
        .create_agent_description => "Description",
        .create_agent_behavior => "Behavior",
        .create_agent_model => "Model",
        else => "",
    };
}

fn agentWizardPrompt(mode: UiMode) []const u8 {
    return switch (mode) {
        .create_agent_name => "Enter a short display name for this agent",
        .create_agent_description => "Describe when this agent should be used",
        .create_agent_behavior => "Describe how this agent should behave",
        .create_agent_model => "Enter the model this agent should use",
        else => "",
    };
}

fn agentWizardRequiredStatus(mode: UiMode) []const u8 {
    return switch (mode) {
        .create_agent_name => "agent name is required",
        .create_agent_description => "agent description is required",
        .create_agent_behavior => "agent behavior is required",
        .create_agent_model => "agent model is required",
        else => "value is required",
    };
}

fn isKnownModelLabel(value: []const u8) bool {
    inline for (std.meta.fields(ModelOption)) |field| {
        const option: ModelOption = @enumFromInt(field.value);
        if (std.mem.eql(u8, modelOptionLabel(option), value)) return true;
    }
    return false;
}

fn agentWizardHelp(mode: UiMode) []const u8 {
    return if (mode == .create_agent_behavior)
        "Enter inserts newline | Ctrl+D or Ctrl+Enter continues | Esc cancels"
    else
        "Enter continues | Esc cancels";
}

fn agentWizardPanelHeight(mode: UiMode) u16 {
    return if (mode == .create_agent_behavior) 24 else 14;
}

fn agentBehaviorEditorWidth(width: u16) u16 {
    var editor_width = width -| 8;
    if (editor_width > 68) editor_width = 68;
    if (editor_width < 20) editor_width = 20;
    return editor_width;
}

fn agentBehaviorEditorHeight(height: u16) u16 {
    var editor_height = height / 3;
    if (editor_height > 12) editor_height = 12;
    if (editor_height < 8) editor_height = 8;
    return editor_height;
}

fn loadAgentRecords(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    records: *std.array_list.Managed(AgentConfig),
) !void {
    const data_dir = try resolveAppDataDir(allocator, environ_map);
    defer allocator.free(data_dir);

    const agents_dir_path = try std.fs.path.join(allocator, &.{ data_dir, "agents" });
    defer allocator.free(agents_dir_path);

    var agents_dir = std.Io.Dir.openDirAbsolute(io, agents_dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer agents_dir.close(io);

    var iterator = agents_dir.iterateAssumeFirstIteration();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        const bytes = agents_dir.readFileAlloc(io, entry.name, allocator, .limited(1024 * 1024)) catch continue;
        defer allocator.free(bytes);

        const record = parseAgentConfig(allocator, agents_dir_path, entry.name, bytes) catch continue;
        try records.append(record);
    }

    std.mem.sort(AgentConfig, records.items, {}, agentConfigLessThan);
}

fn parseAgentConfig(
    allocator: std.mem.Allocator,
    agents_dir_path: []const u8,
    filename: []const u8,
    bytes: []const u8,
) !AgentConfig {
    var parsed = try std.json.parseFromSlice(AgentFileJson, allocator, bytes, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const path = try std.fs.path.join(allocator, &.{ agents_dir_path, filename });
    errdefer allocator.free(path);

    const name = try allocator.dupe(u8, parsed.value.name);
    errdefer allocator.free(name);

    const description = try allocator.dupe(u8, parsed.value.description);
    errdefer allocator.free(description);

    const behavior = try allocator.dupe(u8, parsed.value.behavior);
    errdefer allocator.free(behavior);

    const model = try allocator.dupe(u8, parsed.value.model);
    errdefer allocator.free(model);

    return .{
        .name = name,
        .description = description,
        .behavior = behavior,
        .model = model,
        .path = path,
    };
}

fn agentConfigLessThan(_: void, lhs: AgentConfig, rhs: AgentConfig) bool {
    return std.ascii.lessThanIgnoreCase(lhs.name, rhs.name);
}

fn saveAgentDraft(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    draft: AgentDraft,
) ![]u8 {
    const name = draft.name orelse return error.MissingAgentName;
    const description = draft.description orelse return error.MissingAgentDescription;
    const behavior = draft.behavior orelse return error.MissingAgentBehavior;
    const model = draft.model orelse return error.MissingAgentModel;

    const data_dir = try resolveAppDataDir(allocator, environ_map);
    defer allocator.free(data_dir);

    const agents_dir = try std.fs.path.join(allocator, &.{ data_dir, "agents" });
    defer allocator.free(agents_dir);

    try std.Io.Dir.cwd().createDirPath(io, agents_dir);

    const slug = try agentFileSlug(allocator, name);
    defer allocator.free(slug);

    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;
    try std.json.Stringify.value(.{
        .version = 1,
        .name = name,
        .description = description,
        .behavior = behavior,
        .model = model,
    }, .{ .whitespace = .indent_2 }, writer);
    try writer.writeByte('\n');

    const json_bytes = try out.toOwnedSlice();
    defer allocator.free(json_bytes);

    return writeUniqueAgentFile(allocator, io, agents_dir, slug, json_bytes);
}

fn resolveAppDataDir(
    allocator: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
) ![]u8 {
    if (environ_map.get("NEXDEV_CLI_DATA_DIR")) |data_dir| {
        if (data_dir.len > 0) return allocator.dupe(u8, data_dir);
    }

    if (builtin.os.tag == .windows) {
        if (environ_map.get("LOCALAPPDATA")) |local_app_data| {
            if (local_app_data.len > 0) {
                return std.fs.path.join(allocator, &.{ local_app_data, "nexdev-cli" });
            }
        }

        const home = environ_map.get("HOME") orelse environ_map.get("USERPROFILE") orelse return error.MissingHomeDirectory;
        return std.fs.path.join(allocator, &.{ home, "AppData", "Local", "nexdev-cli" });
    }

    const home = environ_map.get("HOME") orelse return error.MissingHomeDirectory;
    if (builtin.os.tag == .macos) {
        return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "nexdev-cli" });
    }

    if (environ_map.get("XDG_DATA_HOME")) |data_home| {
        if (data_home.len > 0) {
            return std.fs.path.join(allocator, &.{ data_home, "nexdev-cli" });
        }
    }

    return std.fs.path.join(allocator, &.{ home, ".local", "share", "nexdev-cli" });
}

fn agentFileSlug(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;
    var previous_dash = false;

    for (name) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            try writer.writeByte(std.ascii.toLower(char));
            previous_dash = false;
            continue;
        }

        if (!previous_dash and out.written().len > 0) {
            try writer.writeByte('-');
            previous_dash = true;
        }
    }

    while (out.written().len > 0 and out.written()[out.written().len - 1] == '-') {
        out.shrinkRetainingCapacity(out.written().len - 1);
    }

    if (out.written().len == 0) {
        try writer.writeAll("agent");
    }

    return out.toOwnedSlice();
}

fn writeUniqueAgentFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    agents_dir: []const u8,
    slug: []const u8,
    json_bytes: []const u8,
) ![]u8 {
    var index: usize = 0;
    while (index < 1000) : (index += 1) {
        const filename = if (index == 0)
            try std.fmt.allocPrint(allocator, "{s}.json", .{slug})
        else
            try std.fmt.allocPrint(allocator, "{s}-{d}.json", .{ slug, index + 1 });
        defer allocator.free(filename);

        const path = try std.fs.path.join(allocator, &.{ agents_dir, filename });
        errdefer allocator.free(path);

        std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = json_bytes,
            .flags = .{ .exclusive = true },
        }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                allocator.free(path);
                continue;
            },
            else => return err,
        };

        return path;
    }

    return error.TooManyAgentFiles;
}

test "agent file slug normalizes names" {
    const allocator = std.testing.allocator;

    const slug = try agentFileSlug(allocator, "  Research Agent!  ");
    defer allocator.free(slug);
    try std.testing.expectEqualStrings("research-agent", slug);

    const fallback = try agentFileSlug(allocator, "!!!");
    defer allocator.free(fallback);
    try std.testing.expectEqualStrings("agent", fallback);
}

test "agent model validation rejects pasted headings" {
    try std.testing.expect(isKnownModelLabel("GPT-5.5"));
    try std.testing.expect(!isKnownModelLabel("## Primary Responsibilities"));
}

test "agent config parser reads persisted agent json" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "version": 1,
        \\  "name": "Review Agent",
        \\  "description": "Reviews code",
        \\  "behavior": "Find issues",
        \\  "model": "GPT-5.5"
        \\}
    ;

    var config = try parseAgentConfig(allocator, "/tmp/agents", "review-agent.json", json);
    defer config.deinit(allocator);

    try std.testing.expectEqualStrings("Review Agent", config.name);
    try std.testing.expectEqualStrings("Reviews code", config.description);
    try std.testing.expectEqualStrings("Find issues", config.behavior);
    try std.testing.expectEqualStrings("GPT-5.5", config.model);
    try std.testing.expectEqualStrings("/tmp/agents/review-agent.json", config.path);
}

fn requestTypeScriptResponse(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    node_path: []const u8,
    agent_entrypoint: []const u8,
    message_id: u64,
    model: []const u8,
    reasoning_effort: []const u8,
    sandbox_mode: []const u8,
    system_instruction: []const u8,
    text: []const u8,
    history: []const RpcChatMessage,
) !AgentTaskResult {
    var client = try rpc.SubprocessClient.init(allocator, io, &.{ node_path, "--experimental-strip-types", agent_entrypoint }, .{
        .environ_map = environ_map,
    });
    defer client.deinit();

    var conn = client.connection();
    try conn.sendRequest(.{ .integer = @intCast(message_id) }, "message.received", .{
        .message_id = message_id,
        .model = model,
        .reasoning_effort = reasoning_effort,
        .sandbox_mode = sandbox_mode,
        .system_instruction = system_instruction,
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
    if (hasPathSeparator(name)) return allocator.dupe(u8, name);

    const path_value = environ_map.get("PATH") orelse return error.FileNotFound;
    const path_separator: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var path_iter = std.mem.splitScalar(u8, path_value, path_separator);
    while (path_iter.next()) |dir| {
        if (dir.len == 0) continue;

        if (try resolveExecutableInDir(allocator, io, dir, name)) |candidate| {
            return candidate;
        }

        if (builtin.os.tag == .windows and !std.mem.endsWith(u8, name, ".exe")) {
            const exe_name = try std.fmt.allocPrint(allocator, "{s}.exe", .{name});
            defer allocator.free(exe_name);

            if (try resolveExecutableInDir(allocator, io, dir, exe_name)) |candidate| {
                return candidate;
            }
        }
    }

    return error.FileNotFound;
}

fn hasPathSeparator(path: []const u8) bool {
    for (path) |char| {
        if (char == '/' or char == '\\') return true;
    }

    return false;
}

fn resolveExecutableInDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: []const u8,
    name: []const u8,
) !?[]u8 {
    const candidate = try std.fs.path.join(allocator, &.{ dir, name });
    errdefer allocator.free(candidate);

    if (canExecutePath(io, candidate)) return candidate;
    allocator.free(candidate);
    return null;
}

fn resolveAgentEntrypoint(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
) ![]u8 {
    if (environ_map.get("NEXDEV_CLI_AGENT_ENTRYPOINT")) |entrypoint| {
        if (entrypoint.len > 0) return allocator.dupe(u8, entrypoint);
    }

    if (environ_map.get("NEXDEV_CLI_LIB_DIR")) |lib_dir| {
        if (lib_dir.len > 0) {
            const candidate = try std.fs.path.join(allocator, &.{ lib_dir, "agent", "rpc-module.ts" });
            if (canAccessPath(io, candidate)) return candidate;
            allocator.free(candidate);
        }
    }

    const exe_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(exe_dir);

    const lib_adjacent_candidate = try std.fs.path.join(allocator, &.{ exe_dir, "..", "agent", "rpc-module.ts" });
    if (canAccessPath(io, lib_adjacent_candidate)) return lib_adjacent_candidate;
    allocator.free(lib_adjacent_candidate);

    const installed_candidate = try std.fs.path.join(allocator, &.{ exe_dir, "..", "lib", "nexdev-cli", "agent", "rpc-module.ts" });
    if (canAccessPath(io, installed_candidate)) return installed_candidate;
    allocator.free(installed_candidate);

    const portable_candidate = try std.fs.path.join(allocator, &.{ exe_dir, "agent", "rpc-module.ts" });
    if (canAccessPath(io, portable_candidate)) return portable_candidate;
    allocator.free(portable_candidate);

    const dev_candidate = "agent/rpc-module.ts";
    if (canAccessPath(io, dev_candidate)) {
        return allocator.dupe(u8, dev_candidate);
    }

    return error.FileNotFound;
}

fn canExecutePath(io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{ .execute = true }) catch return false;
        return true;
    }

    std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    return true;
}

fn canAccessPath(io: std.Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
        return true;
    }

    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
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

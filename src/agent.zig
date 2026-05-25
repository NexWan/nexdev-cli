const std = @import("std");
const builtin = @import("builtin");
const app = @import("nexdev_cli");
const rpc = @import("zig_rpc");

const ModelOption = app.ModelOption;
const modelOptionLabel = app.modelOptionLabel;

pub const RpcChatMessage = struct {
    role: []const u8,
    content: []const u8,
};

pub const AgentDraft = struct {
    name: ?[]u8 = null,
    description: ?[]u8 = null,
    behavior: ?[]u8 = null,
    model: ?[]u8 = null,

    pub fn deinit(self: *AgentDraft, allocator: std.mem.Allocator) void {
        if (self.name) |value| allocator.free(value);
        if (self.description) |value| allocator.free(value);
        if (self.behavior) |value| allocator.free(value);
        if (self.model) |value| allocator.free(value);
        self.* = .{};
    }
};

pub const AgentConfig = struct {
    name: []u8,
    description: []u8,
    behavior: []u8,
    model: []u8,
    path: []u8,

    pub fn deinit(self: *AgentConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.behavior);
        allocator.free(self.model);
        allocator.free(self.path);
        self.* = undefined;
    }

    pub fn clone(self: AgentConfig, allocator: std.mem.Allocator) !AgentConfig {
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

pub const AgentTaskResult = union(enum) {
    text: []u8,
    failure: []u8,

    pub fn deinit(self: AgentTaskResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .text => |value| allocator.free(value),
            .failure => |value| allocator.free(value),
        }
    }
};

pub const AgentTask = struct {
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

    pub fn start(
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

    pub fn takeResult(self: *AgentTask) ?AgentTaskResult {
        if (!self.done.load(.acquire)) return null;
        const result = self.result orelse return null;
        self.result = null;
        return result;
    }

    pub fn deinit(self: *AgentTask) void {
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

pub fn loadAgentRecords(
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

pub fn saveAgentDraft(
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

pub fn isKnownModelLabel(value: []const u8) bool {
    inline for (std.meta.fields(ModelOption)) |field| {
        const option: ModelOption = @enumFromInt(field.value);
        if (std.mem.eql(u8, modelOptionLabel(option), value)) return true;
    }
    return false;
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

pub fn resolveExecutable(
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

pub fn resolveAgentEntrypoint(
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

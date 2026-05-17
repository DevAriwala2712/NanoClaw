const std = @import("std");

pub const Role = enum {
    planner,
    executor,
};

pub const ModelQuantization = enum {
    q4_0,
    q4_1,
    q5_0,
    q5_1,
    q8_0,
};

pub const TaskSensitivity = enum {
    sensitive,
    moderate,
    trivial,
};

pub const TaskPayload = struct {
    prompt: []const u8,
    sensitivity: TaskSensitivity,
    max_tokens: u32 = 512,
};

pub const ExecutionLocation = enum {
    local,
    cloud,
};

pub const RoutingDecision = struct {
    location: ExecutionLocation,
    reason: []const u8,
};

pub const InferenceResult = struct {
    output: []const u8,
    tokens_generated: u32,
    vram_used_mb: u32,
};

pub const ModelSpec = struct {
    path: []const u8,
    quantization: ModelQuantization,
    max_vram_mb: u32,
    context_tokens: u32,
};

pub const InferenceRuntime = struct {
    allocator: std.mem.Allocator,
    planner_loaded: bool = false,
    executor_loaded: bool = false,
    current_role: ?Role = null,
    used_vram_mb: u32 = 0,
    total_vram_mb: u32 = 0,
    models: std.StringHashMapUnmanaged(ModelSpec),
    context_budget: u32 = 4096,
    context_used: u32 = 0,
    total_inferences: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) InferenceRuntime {
        return .{
            .allocator = allocator,
            .models = .{},
        };
    }

    pub fn deinit(self: *InferenceRuntime) void {
        var iter = self.models.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.models.deinit(self.allocator);
    }

    pub fn setBudget(self: *InferenceRuntime, total_mb: u32) void {
        self.total_vram_mb = total_mb;
    }

    pub fn setContextBudget(self: *InferenceRuntime, tokens: u32) void {
        self.context_budget = tokens;
    }

    pub fn vramAvailable(self: *InferenceRuntime) u32 {
        if (self.used_vram_mb >= self.total_vram_mb) return 0;
        return self.total_vram_mb - self.used_vram_mb;
    }

    pub fn registerModel(self: *InferenceRuntime, role: Role, spec: ModelSpec) !void {
        const key = try self.allocator.dupe(u8, @tagName(role));
        try self.models.put(self.allocator, key, spec);
    }

    fn getModel(self: *InferenceRuntime, role: Role) ?ModelSpec {
        return self.models.get(@tagName(role));
    }

    pub fn load(self: *InferenceRuntime, role: Role) !void {
        const spec = self.getModel(role) orelse {
            std.debug.print("[inference] no model registered for {s}, using demo mode\n", .{@tagName(role)});
            switch (role) {
                .planner => self.planner_loaded = true,
                .executor => self.executor_loaded = true,
            }
            self.current_role = role;
            return;
        };

        if (self.vramAvailable() < spec.max_vram_mb) {
            std.debug.print("[inference] VRAM budget exceeded: {}+{} > {} MB\n", .{
                self.used_vram_mb,
                spec.max_vram_mb,
                self.total_vram_mb,
            });
            return error.VRAMExceeded;
        }

        std.debug.print("[inference] loading {s} model: {s} ({s}, {}MB, {} ctx tokens)\n", .{
            @tagName(role),
            spec.path,
            @tagName(spec.quantization),
            spec.max_vram_mb,
            spec.context_tokens,
        });

        try self.llamaLoad(spec);

        switch (role) {
            .planner => self.planner_loaded = true,
            .executor => self.executor_loaded = true,
        }
        self.used_vram_mb += spec.max_vram_mb;
        self.current_role = role;

        if (spec.context_tokens < self.context_budget) {
            self.context_budget = spec.context_tokens;
        }
    }

    fn llamaLoad(self: *InferenceRuntime, spec: ModelSpec) !void {
        _ = self;
        std.debug.print("[llama] initializing model with {s} quantization, {} context\n", .{
            @tagName(spec.quantization),
            spec.context_tokens,
        });
    }

    pub fn unload(self: *InferenceRuntime, role: Role) void {
        if (self.current_role != role) return;

        const spec = self.getModel(role) orelse {
            std.debug.print("[inference] unloading {s} (demo mode)\n", .{@tagName(role)});
            switch (role) {
                .planner => self.planner_loaded = false,
                .executor => self.executor_loaded = false,
            }
            self.current_role = null;
            return;
        };

        std.debug.print("[inference] unloading {s} model: {s}\n", .{ @tagName(role), spec.path });
        std.debug.print("[llama] freeing {}MB VRAM\n", .{spec.max_vram_mb});

        switch (role) {
            .planner => self.planner_loaded = false,
            .executor => self.executor_loaded = false,
        }
        self.used_vram_mb -= spec.max_vram_mb;
        self.current_role = null;
    }

    pub fn status(self: InferenceRuntime) void {
        std.debug.print(
            "[inference] planner={} executor={} role={any} vram={}/{}MB ctx={}/{} infer#={}\n",
            .{
                self.planner_loaded,
                self.executor_loaded,
                self.current_role,
                self.used_vram_mb,
                self.total_vram_mb,
                self.context_used,
                self.context_budget,
                self.total_inferences,
            },
        );
    }

    pub fn canSwap(self: *InferenceRuntime, from_role: Role, to_role: Role) bool {
        const from_spec = self.getModel(from_role) orelse return true;
        const to_spec = self.getModel(to_role) orelse return true;

        const freed_vram = if (self.current_role == from_role) from_spec.max_vram_mb else 0;
        const available = self.vramAvailable() + freed_vram;

        return available >= to_spec.max_vram_mb;
    }

    pub fn route(self: *InferenceRuntime, task: TaskPayload) RoutingDecision {
        switch (task.sensitivity) {
            .sensitive => {
                return .{ .location = .local, .reason = "PII/password handling requires local processing" };
            },
            .moderate => {
                const vram_available = self.vramAvailable();
                if (vram_available < 500) {
                    return .{ .location = .cloud, .reason = "insufficient VRAM for moderate task" };
                }
                return .{ .location = .local, .reason = "moderate task fits in VRAM budget" };
            },
            .trivial => {
                return .{ .location = .local, .reason = "trivial task handled locally" };
            },
        }
    }

    fn inferCloud(self: *InferenceRuntime, task: TaskPayload, endpoint: []const u8) !InferenceResult {
        self.total_inferences += 1;

        const endpoint_label = if (endpoint.len == 0) "cloud" else endpoint;
        const output = try std.fmt.allocPrint(
            self.allocator,
            "[{s}] delegated {s} task: {} tokens",
            .{ endpoint_label, @tagName(task.sensitivity), task.max_tokens },
        );

        return .{
            .output = output,
            .tokens_generated = task.max_tokens,
            .vram_used_mb = self.used_vram_mb,
        };
    }

    pub fn inferRouted(self: *InferenceRuntime, task: TaskPayload, decision: RoutingDecision, cloud_endpoint: []const u8) !InferenceResult {
        switch (decision.location) {
            .local => return self.infer(task),
            .cloud => return self.inferCloud(task, cloud_endpoint),
        }
    }

    fn parseCommandLine(allocator: std.mem.Allocator, command: []const u8) ![]const []const u8 {
        var argv_list: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer {
            for (argv_list.items) |arg| allocator.free(arg);
            argv_list.deinit(allocator);
        }

        var it = try std.process.ArgIteratorGeneral(.{ .single_quotes = true }).init(allocator, command);
        defer it.deinit();

        while (it.next()) |arg| {
            try argv_list.append(allocator, try allocator.dupe(u8, arg));
        }

        if (argv_list.items.len == 0) return error.InvalidLocalLlmCommand;
        return try argv_list.toOwnedSlice(allocator);
    }

    fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
        for (argv) |arg| allocator.free(arg);
        allocator.free(argv);
    }

    fn localLlmTimeoutMs(self: *InferenceRuntime) !u64 {
        const default_timeout_ms: u64 = 20_000;
        const timeout_text = std.process.getEnvVarOwned(self.allocator, "LOCAL_LLM_TIMEOUT_MS") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return default_timeout_ms,
            else => return err,
        };
        defer self.allocator.free(timeout_text);

        const trimmed = std.mem.trim(u8, timeout_text, " \t\r\n");
        const parsed = std.fmt.parseUnsigned(u64, trimmed, 10) catch return error.InvalidLocalLlmTimeout;
        if (parsed == 0) return error.InvalidLocalLlmTimeout;
        return parsed;
    }

    fn tryExternalInference(self: *InferenceRuntime, task: TaskPayload) !?[]const u8 {
        const cmd = std.process.getEnvVarOwned(self.allocator, "LOCAL_LLM_CMD") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return null,
            else => return err,
        };
        defer self.allocator.free(cmd);

        const command = std.mem.trim(u8, cmd, " \t\r\n");
        if (command.len == 0) return error.InvalidLocalLlmCommand;

        const argv = try parseCommandLine(self.allocator, command);
        defer freeArgv(self.allocator, argv);

        var child = std.process.Child.init(argv, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        errdefer _ = child.kill() catch {};

        if (child.stdin) |*stdin_pipe| {
            try stdin_pipe.writeAll(task.prompt);
            try stdin_pipe.writeAll("\n");
            stdin_pipe.close();
            child.stdin = null;
        } else {
            return error.ChildStdinUnavailable;
        }

        const max_output_bytes: usize = @max(8 * 1024, @as(usize, task.max_tokens) * 16);
        const timeout_ms = try self.localLlmTimeoutMs();
        const started_ms = std.time.milliTimestamp();

        var poller = std.Io.poll(self.allocator, enum { stdout, stderr }, .{
            .stdout = child.stdout.?,
            .stderr = child.stderr.?,
        });
        defer poller.deinit();

        while (true) {
            const now_ms = std.time.milliTimestamp();
            if (now_ms > started_ms) {
                const elapsed = @as(u64, @intCast(now_ms - started_ms));
                if (elapsed >= timeout_ms) {
                    _ = child.kill() catch |err| switch (err) {
                        error.AlreadyTerminated => {},
                        else => return err,
                    };
                    _ = child.wait() catch {};
                    return error.LocalLlmTimeout;
                }
            }

            const keep_polling = try poller.pollTimeout(50 * std.time.ns_per_ms);
            if (poller.reader(.stdout).bufferedLen() > max_output_bytes) return error.StdoutStreamTooLong;
            if (poller.reader(.stderr).bufferedLen() > max_output_bytes) return error.StderrStreamTooLong;
            if (!keep_polling) break;
        }

        const term = try child.wait();
        const stdout_buf = try poller.toOwnedSlice(.stdout);
        errdefer self.allocator.free(stdout_buf);
        const stderr_buf = try poller.toOwnedSlice(.stderr);
        defer self.allocator.free(stderr_buf);

        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    const stderr_trimmed = std.mem.trim(u8, stderr_buf, " \t\r\n");
                    if (stderr_trimmed.len > 0) {
                        std.debug.print("[inference] local llm exited with code {}: {s}\n", .{ code, stderr_trimmed });
                    } else {
                        std.debug.print("[inference] local llm exited with code {}\n", .{code});
                    }
                    return error.LocalLlmProcessFailed;
                }
            },
            else => return error.LocalLlmProcessFailed,
        }

        const trimmed = std.mem.trim(u8, stdout_buf, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyModelOutput;

        if (trimmed.ptr == stdout_buf.ptr and trimmed.len == stdout_buf.len) {
            return stdout_buf;
        }

        const output = try self.allocator.dupe(u8, trimmed);
        self.allocator.free(stdout_buf);
        return output;
    }

    pub fn infer(self: *InferenceRuntime, task: TaskPayload) !InferenceResult {
        if (self.current_role == null) {
            return error.NoModelLoaded;
        }

        if (self.context_used + task.max_tokens > self.context_budget) {
            std.debug.print("[inference] context budget would be exceeded: {}+{}>{}\n", .{
                self.context_used,
                task.max_tokens,
                self.context_budget,
            });
            return error.ContextBudgetExceeded;
        }

        // Attempt to use an external local LLM bridge if configured. This is a
        // non-fatal attempt: if the bridge is not configured or not yet
        // implemented it returns null and we fall back to the demo stub below.
        const ext_out = try self.tryExternalInference(task);
        if (ext_out) |out| {
            // external bridge returned a heap-allocated buffer owned by this
            // runtime's allocator. Return it as the inference output.
            self.total_inferences += 1;
            self.context_used += task.max_tokens;
            return InferenceResult{
                .output = out,
                .tokens_generated = task.max_tokens,
                .vram_used_mb = self.used_vram_mb,
            };
        }

        // Fall back to demo/stub behaviour
        self.total_inferences += 1;
        self.context_used += task.max_tokens;

        const role_name = @tagName(self.current_role.?);
        const sens_name = @tagName(task.sensitivity);

        std.debug.print("[inference] {s} processing {s} task: {s}...\n", .{
            role_name,
            sens_name,
            if (task.prompt.len > 40) task.prompt[0..40] else task.prompt,
        });

        const output = try std.fmt.allocPrint(
            self.allocator,
            "[{s} inferred {s} task: {} tokens]",
            .{ role_name, sens_name, task.max_tokens },
        );

        return InferenceResult{
            .output = output,
            .tokens_generated = task.max_tokens,
            .vram_used_mb = self.used_vram_mb,
        };
    }
};

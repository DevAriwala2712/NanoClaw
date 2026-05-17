const std = @import("std");
const config = @import("config.zig");
const sandbox = @import("runtime/sandbox.zig");
const timeout = @import("runtime/timeout.zig");
const rollback = @import("runtime/rollback.zig");
const inference = @import("inference/runtime.zig");
const memory = @import("memory/hierarchy.zig");
const phase2_memory = @import("memory.zig");
const skills = @import("skills/runtime.zig");
const tools = @import("tools/fallback.zig");

pub const App = struct {
    allocator: std.mem.Allocator,
    cfg: config.RuntimeConfig,
    sbx: sandbox.Sandbox,
    journal: rollback.Journal,
    llm: inference.InferenceRuntime,
    mem: memory.HierarchicalMemory,
    skill_rt: skills.SkillRuntime,
    router: tools.AutoCorrector,

    pub fn init(allocator: std.mem.Allocator, cfg: config.RuntimeConfig) !App {
        var llm = inference.InferenceRuntime.init(allocator);
        llm.setBudget(cfg.vram_budget_mb);
        llm.setContextBudget(4096);

        try llm.registerModel(.planner, .{
            .path = "models/smollm-1.7b-q4_0.gguf",
            .quantization = .q4_0,
            .max_vram_mb = 1100,
            .context_tokens = 2048,
        });

        try llm.registerModel(.executor, .{
            .path = "models/smollm-360m-q4_1.gguf",
            .quantization = .q4_1,
            .max_vram_mb = 450,
            .context_tokens = 1024,
        });

        return .{
            .allocator = allocator,
            .cfg = cfg,
            .sbx = sandbox.Sandbox.init(allocator),
            .journal = rollback.Journal.init(allocator),
            .llm = llm,
            .mem = memory.HierarchicalMemory.init(allocator),
            .skill_rt = skills.SkillRuntime.init(allocator),
            .router = try tools.AutoCorrector.init(allocator),
        };
    }

    pub fn deinit(self: *App) void {
        self.router.deinit();
        self.skill_rt.deinit();
        self.mem.deinit();
        self.llm.deinit();
        self.journal.deinit();
        config.deinit(self.allocator, &self.cfg);
    }

    pub fn run(self: *App) !void {
        return self.runWithPrompt(null);
    }

    fn parseCommandLine(allocator: std.mem.Allocator, command: []const u8) ![]const []const u8 {
        var first_line: []const u8 = "";
        var line_it = std.mem.splitScalar(u8, command, '\n');
        while (line_it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0) {
                if (std.mem.startsWith(u8, trimmed, "```")) {
                    continue;
                }
                first_line = trimmed;
                break;
            }
        }
        if (first_line.len == 0) return error.EmptyCommand;

        var argv_list: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer {
            for (argv_list.items) |arg| allocator.free(arg);
            argv_list.deinit(allocator);
        }

        var it = std.process.ArgIteratorGeneral(.{ .single_quotes = true }).init(allocator, first_line) catch |err| {
            if (err == error.MismatchedQuote) {
                // fallback to naive space-splitting to prevent crashing on LLM hallucinations
                var split_it = std.mem.tokenizeAny(u8, first_line, " \t\r\n");
                while (split_it.next()) |arg| {
                    if (std.mem.eql(u8, arg, "|") or std.mem.eql(u8, arg, "&&") or std.mem.eql(u8, arg, ";") or std.mem.eql(u8, arg, ">") or std.mem.eql(u8, arg, "<")) {
                        break;
                    }
                    try argv_list.append(allocator, try allocator.dupe(u8, arg));
                }
                if (argv_list.items.len == 0) return error.EmptyCommand;
                return try argv_list.toOwnedSlice(allocator);
            }
            return err;
        };
        defer it.deinit();

        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "|") or std.mem.eql(u8, arg, "&&") or std.mem.eql(u8, arg, ";") or std.mem.eql(u8, arg, ">") or std.mem.eql(u8, arg, "<")) {
                break;
            }
            try argv_list.append(allocator, try allocator.dupe(u8, arg));
        }

        if (argv_list.items.len == 0) return error.EmptyCommand;
        return try argv_list.toOwnedSlice(allocator);
    }

    fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
        for (argv) |arg| allocator.free(arg);
        allocator.free(argv);
    }

    pub fn printStatus(self: *App) !void {
        const local_cmd = std.process.getEnvVarOwned(self.allocator, "LOCAL_LLM_CMD") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => null,
            else => return err,
        };
        defer if (local_cmd) |cmd| self.allocator.free(cmd);

        const has_local_bridge = local_cmd != null and std.mem.trim(u8, local_cmd.?, " \t\r\n").len > 0;
        const llm_mode = if (has_local_bridge) "local-subprocess" else "stub";

        std.debug.print(
            "=== NanoClaw Status ===\n" ++
                "LLM mode: {s}\n" ++
                "LOCAL_LLM_CMD: {s}\n" ++
                "VRAM budget: {} MB\n" ++
                "Cloud endpoint: {s}\n" ++
                "=======================\n",
            .{
                llm_mode,
                if (has_local_bridge) local_cmd.? else "(not set)",
                self.cfg.vram_budget_mb,
                if (self.cfg.cloud_endpoint.len == 0) "(none)" else self.cfg.cloud_endpoint,
            },
        );
    }

    pub fn runWithPrompt(self: *App, runtime_prompt: ?[]const u8) !void {
        try self.journal.beginTxn("phase1");
        try self.journal.recordSnapshot("pre", "nanoclaw-next.conf");
        try self.journal.record("phase1:start");
        std.debug.print("\n=== NanoClaw-Next Phase 1 Runtime Cycle ===\n\n", .{});

        // record pre-execution checkpoint
        try self.journal.recordCheckpoint(self.llm.used_vram_mb, self.mem.size(), self.skill_rt.registeredCount());

        // ---- Phase 1a: Planner model load with VRAM budget check ----
        std.debug.print("--- [1a] Loading Planner Model ---\n", .{});
        const planner_vram_needed: u32 = 1100;
        if (self.llm.vramAvailable() < planner_vram_needed) {
            std.debug.print("[fatal] insufficient VRAM for planner: {} < {} MB\n", .{
                self.llm.vramAvailable(),
                planner_vram_needed,
            });
            try self.journal.rollbackTxn("phase1");
            try self.journal.flushToFile(self.cfg.rollback_log_path);
            return error.InsufficientVRAM;
        }
        self.llm.load(.planner) catch |err| {
            std.debug.print("[inference] planner load failed: {}\n", .{err});
            try self.journal.rollbackTxn("phase1");
            try self.journal.flushToFile(self.cfg.rollback_log_path);
            return err;
        };
        try self.journal.record("phase1:planner:loaded");
        self.llm.status();

        // record planner-loaded checkpoint
        try self.journal.recordCheckpoint(self.llm.used_vram_mb, self.mem.size(), self.skill_rt.registeredCount());

        // ---- Phase 1b: Task creation and sensitivity routing ----
        std.debug.print("\n--- [1b] Task Routing ---\n", .{});
        const runtime_prompt_val = runtime_prompt orelse "List all files in the current directory and check system info";
        const planner_instruction = try std.fmt.allocPrint(self.allocator,
            "You are an AI planner for a CLI agent. Break down the user's intent into a step-by-step plan. Output ONLY the plan, no conversational filler. Intent: {s}",
            .{runtime_prompt_val}
        );
        defer self.allocator.free(planner_instruction);

        const task = inference.TaskPayload{
            .prompt = planner_instruction,
            .sensitivity = .moderate,
            .max_tokens = 256,
        };

        const route = self.llm.route(task);
        std.debug.print("[router] task sensitivity={s}, decided: {s} ({s})\n", .{
            @tagName(task.sensitivity),
            @tagName(route.location),
            route.reason,
        });
        try self.journal.record("phase1:route");

        // ---- Phase 1c: Planner inference ----
        std.debug.print("\n--- [1c] Planner Inference ---\n", .{});
        const plan = try self.llm.inferRouted(task, route, self.cfg.cloud_endpoint);
        defer self.allocator.free(plan.output);
        std.debug.print("[planner] output: {s}\n", .{plan.output});
        try self.journal.record("phase1:planner:infer");

        // store in session memory
        try self.mem.put("task:current", task.prompt);
        try self.mem.put("plan:result", plan.output);
        std.debug.print("[memory] stored plan in session ({} entries)\n", .{self.mem.sessionCount()});

        // ---- Phase 1d: Memory consolidation ----
        std.debug.print("\n--- [1d] Memory Consolidation ---\n", .{});
        try self.mem.consolidate();
        try self.journal.record("phase1:memory:consolidate");

        // register a built-in skill
        try self.skill_rt.register(.{
            .name = "file-lister",
            .version = "1.0.0",
            .capabilities = &.{
                .{ .syscall = .file_read, .allowed = true, .name = "read directory" },
            },
        });
        try self.journal.record("phase1:skills:registered");

        // record mid-execution checkpoint
        try self.journal.recordCheckpoint(self.llm.used_vram_mb, self.mem.size(), self.skill_rt.registeredCount());

        // ---- Phase 1e: Role swap (unload planner, load executor) ----
        std.debug.print("\n--- [1e] Role Swap: Planner -> Executor ---\n", .{});
        if (!self.llm.canSwap(.planner, .executor)) {
            std.debug.print("[fatal] cannot swap from planner to executor (VRAM constraint)\n", .{});
            try self.journal.rollbackTxn("phase1");
            try self.journal.flushToFile(self.cfg.rollback_log_path);
            return error.RoleSwapFailed;
        }
        self.llm.unload(.planner);
        try self.journal.record("phase1:planner:unloaded");

        const executor_vram_needed: u32 = 450;
        if (self.llm.vramAvailable() < executor_vram_needed) {
            std.debug.print("[fatal] insufficient VRAM for executor: {} < {} MB\n", .{
                self.llm.vramAvailable(),
                executor_vram_needed,
            });
            try self.journal.rollbackTxn("phase1");
            try self.journal.flushToFile(self.cfg.rollback_log_path);
            return error.InsufficientVRAM;
        }
        self.llm.load(.executor) catch |err| {
            std.debug.print("[inference] executor load failed: {}\n", .{err});
            try self.journal.rollbackTxn("phase1");
            try self.journal.flushToFile(self.cfg.rollback_log_path);
            return err;
        };
        try self.journal.record("phase1:executor:loaded");
        self.llm.status();

        // record role-swap checkpoint
        try self.journal.recordCheckpoint(self.llm.used_vram_mb, self.mem.size(), self.skill_rt.registeredCount());

        // ---- Phase 1f: Executor inference (generate concrete command) ----
        std.debug.print("\n--- [1f] Executor Inference ---\n", .{});
        const command_prompt = runtime_prompt orelse "ls -la";
        const executor_instruction = try std.fmt.allocPrint(self.allocator, 
            "You are a terminal executor. Convert this intent into EXACTLY ONE single unix command. Output ONLY the raw executable and its arguments. DO NOT chain or combine multiple commands. NO markdown, NO explanation, NO shell operators (;, &&, |, >, etc).\nIntent: {s}\nPlan: {s}", 
            .{command_prompt, plan.output}
        );
        defer self.allocator.free(executor_instruction);
        
        const exec_task = inference.TaskPayload{
            .prompt = executor_instruction,
            .sensitivity = .trivial,
            .max_tokens = 64,
        };
        const exec_route = self.llm.route(exec_task);
        const exec_plan = try self.llm.inferRouted(exec_task, exec_route, self.cfg.cloud_endpoint);
        defer self.allocator.free(exec_plan.output);
        std.debug.print("[executor] output: {s}\n", .{exec_plan.output});
        try self.journal.record("phase1:executor:infer");

        // refine to knowledge for future sessions
        try self.mem.refineToKnowledge("executor:last-task", exec_plan.output);
        try self.journal.record("phase1:memory:refine");

        // ---- Phase 1g: Tool auto-correction ----
        std.debug.print("\n--- [1g] Tool Auto-Correction ---\n", .{});
        const parsed_args = try parseCommandLine(self.allocator, exec_plan.output);
        defer freeArgv(self.allocator, parsed_args);

        var cmd_args_list: std.ArrayListUnmanaged([]const u8) = .{};
        defer cmd_args_list.deinit(self.allocator);

        const raw_tool = parsed_args[0];
        const normalized = self.router.normalize(raw_tool);
        std.debug.print("[autocorrect] resolved '{s}' -> '{s}'\n", .{ raw_tool, normalized });

        try cmd_args_list.append(self.allocator, normalized);
        for (parsed_args[1..]) |arg| {
            try cmd_args_list.append(self.allocator, arg);
        }

        const cmd_args = try cmd_args_list.toOwnedSlice(self.allocator);
        defer self.allocator.free(cmd_args);

        _ = try self.skill_rt.execute("file-lister", cmd_args[0]);
        try self.journal.record("phase1:skills:execute");

        // ---- Phase 1h: Sandbox execution with timeout ----
        std.debug.print("\n--- [1h] Sandbox Execution ---\n", .{});
        const budget = timeout.Budget.begin(self.cfg.timeout.soft_ms, self.cfg.timeout.hard_ms);
        const result = try self.sbx.runWithBudget(.{
            .name = "tool.dispatch",
            .args = cmd_args[0..],
        }, self.cfg.safety, budget);

        if (result.timed_out) {
            std.debug.print("[sandbox] execution timed out\n", .{});
            try self.journal.record("phase1:sandbox:timeout");
            try self.journal.recordSnapshot("timeout", self.cfg.rollback_log_path);
            try self.journal.rollbackTxn("phase1");
            try self.journal.flushToFile(self.cfg.rollback_log_path);
            return error.RuntimeTimeout;
        }

        std.debug.print("[sandbox] exit code: {}\n", .{result.exit_code});
        try self.journal.record("phase1:sandbox:ok");

        // ---- Phase 1i: Finalize ----
        std.debug.print("\n--- [1i] Finalize ---\n", .{});
        try self.journal.record("phase1:complete");
        try self.journal.recordSnapshot("post", self.cfg.rollback_log_path);
        try self.journal.recordCheckpoint(self.llm.used_vram_mb, self.mem.size(), self.skill_rt.registeredCount());
        try self.journal.commitTxn("phase1");
        try self.journal.flushToFile(self.cfg.rollback_log_path);

        std.debug.print("\n=== Phase 1 Runtime Cycle Complete ===\n", .{});
        std.debug.print("  VRAM: {}/{} MB used\n", .{ self.llm.used_vram_mb, self.llm.total_vram_mb });
        std.debug.print("  Memory: {} session, {} summaries, {} knowledge\n", .{
            self.mem.sessionCount(),
            self.mem.summaryCount(),
            self.mem.knowledgeCount(),
        });
        std.debug.print("  Skills: {} registered\n", .{self.skill_rt.registeredCount()});
        std.debug.print("  Corrections: {}\n", .{self.router.correctionCount()});
        std.debug.print("  Exit code: {}\n", .{result.exit_code});
    }

    pub fn selftest(self: *App) !void {
        std.debug.print("[selftest] Phase 1 self-test suite\n", .{});
        var passed: u32 = 0;
        var failed: u32 = 0;

        // ---- Safety defaults ----
        if (!self.cfg.safety.offline_only) {
            std.debug.print("[FAIL] safety: offline_only not true\n", .{});
            failed += 1;
        } else if (self.cfg.safety.allow_shell) {
            std.debug.print("[FAIL] safety: allow_shell should be false\n", .{});
            failed += 1;
        } else if (self.cfg.safety.allow_network) {
            std.debug.print("[FAIL] safety: allow_network should be false\n", .{});
            failed += 1;
        } else {
            std.debug.print("[PASS] safety defaults\n", .{});
            passed += 1;
        }

        // ---- Policy enforcement ----
        {
            var policy_ok = false;
            _ = self.sbx.runWithBudget(.{
                .name = "shell",
                .args = &.{ "curl", "https://example.com" },
            }, self.cfg.safety, timeout.Budget.begin(self.cfg.timeout.soft_ms, self.cfg.timeout.hard_ms)) catch |err| {
                if (err == error.NetworkExecutionDenied or err == error.ShellExecutionDenied) {
                    policy_ok = true;
                }
            };
            if (!policy_ok) {
                std.debug.print("[FAIL] policy enforcement: network/shell not denied\n", .{});
                failed += 1;
            } else {
                std.debug.print("[PASS] policy enforcement\n", .{});
                passed += 1;
            }
        }

        // ---- Sandbox execution ----
        {
            const exec_res = try self.sbx.runWithBudget(.{
                .name = "tool.dispatch",
                .args = &.{ "echo", "selftest" },
            }, self.cfg.safety, timeout.Budget.begin(self.cfg.timeout.soft_ms, self.cfg.timeout.hard_ms));
            if (exec_res.exit_code != 0) {
                std.debug.print("[FAIL] sandbox execution: exit code {}\n", .{exec_res.exit_code});
                failed += 1;
            } else {
                std.debug.print("[PASS] sandbox execution\n", .{});
                passed += 1;
            }
        }

        // ---- Phase 1a: Inference runtime (VRAM tracking, model registration) ----
        {
            var test_llm = inference.InferenceRuntime.init(self.allocator);
            defer test_llm.deinit();
            test_llm.setBudget(2048);

            try test_llm.registerModel(.planner, .{
                .path = "test-planner.gguf",
                .quantization = .q4_0,
                .max_vram_mb = 1100,
                .context_tokens = 2048,
            });

            try test_llm.registerModel(.executor, .{
                .path = "test-executor.gguf",
                .quantization = .q4_1,
                .max_vram_mb = 450,
                .context_tokens = 1024,
            });

            // VRAM budget should be 2048, planner 1100 + executor 450 = 1550 < 2048
            try test_llm.load(.planner);
            try test_llm.load(.executor);
            if (test_llm.used_vram_mb != 1550) {
                std.debug.print("[FAIL] inference: VRAM tracking expected 1550 got {}\n", .{test_llm.used_vram_mb});
                failed += 1;
            } else {
                std.debug.print("[PASS] inference VRAM tracking\n", .{});
                passed += 1;
            }

            // VRAM exceeded test
            test_llm.total_vram_mb = 100;
            if (test_llm.load(.planner)) {
                std.debug.print("[FAIL] inference: should have exceeded VRAM\n", .{});
                failed += 1;
            } else |_| {
                std.debug.print("[PASS] inference VRAM exceeded\n", .{});
                passed += 1;
            }

            // Sensitivity routing
            const sensitive_task = inference.TaskPayload{ .prompt = "password reset", .sensitivity = .sensitive, .max_tokens = 100 };
            const route = test_llm.route(sensitive_task);
            if (route.location != .local) {
                std.debug.print("[FAIL] inference: sensitive task should route local\n", .{});
                failed += 1;
            } else {
                std.debug.print("[PASS] inference sensitivity routing\n", .{});
                passed += 1;
            }

            test_llm.setBudget(400);
            const cloud_route = test_llm.route(.{ .prompt = "heavy research", .sensitivity = .moderate, .max_tokens = 128 });
            if (cloud_route.location != .cloud) {
                std.debug.print("[FAIL] inference: low VRAM should route moderate task cloud\n", .{});
                failed += 1;
            } else {
                std.debug.print("[PASS] inference cloud routing\n", .{});
                passed += 1;
            }

            // Role swap
            test_llm.total_vram_mb = 2048;
            test_llm.used_vram_mb = 0;
            try test_llm.load(.planner);
            const can_swap = test_llm.canSwap(.planner, .executor);
            if (!can_swap) {
                std.debug.print("[FAIL] inference: should be able to swap planner->executor\n", .{});
                failed += 1;
            } else {
                std.debug.print("[PASS] inference role swap\n", .{});
                passed += 1;
            }

            // Context budget
            test_llm.setBudget(2048);
            test_llm.setContextBudget(512);
            const infer_task = inference.TaskPayload{ .prompt = "test", .sensitivity = .trivial, .max_tokens = 256 };
            const infer_result = try test_llm.infer(infer_task);
            defer test_llm.allocator.free(infer_result.output);
            std.debug.print("[PASS] inference context budget\n", .{});
            passed += 1;
        }

        // ---- Phase 1b: Hierarchical memory ----
        {
            var test_mem = memory.HierarchicalMemory.init(self.allocator);
            defer test_mem.deinit();

            try test_mem.put("test-key", "test-value");
            const got = test_mem.get("test-key");
            if (got == null or !std.mem.eql(u8, got.?, "test-value")) {
                std.debug.print("[FAIL] memory: put/get failed\n", .{});
                failed += 1;
            } else {
                std.debug.print("[PASS] memory put/get\n", .{});
                passed += 1;
            }

            try test_mem.refineToKnowledge("persistent-key", "persistent-value");
            if (test_mem.knowledgeCount() != 1) {
                std.debug.print("[FAIL] memory: refineToKnowledge failed\n", .{});
                failed += 1;
            } else {
                std.debug.print("[PASS] memory refineToKnowledge\n", .{});
                passed += 1;
            }

            const ctx = try test_mem.jitLoad(self.allocator, 4096);
            defer self.allocator.free(ctx);
            if (ctx.len == 0) {
                std.debug.print("[FAIL] memory: jitLoad should return knowledge\n", .{});
                failed += 1;
            } else {
                std.debug.print("[PASS] memory jitLoad\n", .{});
                passed += 1;
            }

            // consolidation
            try test_mem.consolidate();
            std.debug.print("[PASS] memory consolidate\n", .{});
            passed += 1;

            // search
            try test_mem.put("alpha", "beta gamma delta");
            const results = try test_mem.search("gamma", 5);
            defer self.allocator.free(results);
            if (results.len == 0) {
                std.debug.print("[FAIL] memory: search should find 'gamma'\n", .{});
                failed += 1;
            } else {
                std.debug.print("[PASS] memory search\n", .{});
                passed += 1;
            }
        }

        // ---- Phase 2 foundation: guarded memory manager ----
        {
            var manager = try phase2_memory.MemoryManager.init(self.allocator, "state/memory.log");
            defer manager.deinit();

            if (!manager.canAcceptWrites()) {
                std.debug.print("[FAIL] memory manager: should accept writes before shutdown\n", .{});
                failed += 1;
            } else {
                std.debug.print("[PASS] memory manager lifecycle guard (pre-shutdown)\n", .{});
                passed += 1;
            }

            try manager.writeRecordCreate("selftest-key", "selftest-value");
            manager.shutdown();

            if (manager.canAcceptWrites()) {
                std.debug.print("[FAIL] memory manager: should reject writes after shutdown\n", .{});
                failed += 1;
            } else {
                std.debug.print("[PASS] memory manager lifecycle guard (shutdown)\n", .{});
                passed += 1;
            }

            if (manager.writeRecordCreate("late-key", "late-value")) {
                std.debug.print("[FAIL] memory manager: write should fail after shutdown\n", .{});
                failed += 1;
            } else |err| {
                if (err == error.ShutdownInProgress) {
                    std.debug.print("[PASS] memory manager rejects writes during shutdown\n", .{});
                    passed += 1;
                } else {
                    std.debug.print("[FAIL] memory manager: unexpected error after shutdown: {}\n", .{err});
                    failed += 1;
                }
            }
        }

        // ---- Phase 1c: Skills runtime ----
        {
            var test_skills = skills.SkillRuntime.init(self.allocator);
            defer test_skills.deinit();

            try test_skills.register(.{
                .name = "test-skill",
                .version = "1.0.0",
                .capabilities = &.{
                    .{ .syscall = .file_read, .allowed = true, .name = "read" },
                },
            });

            if (!test_skills.isRegistered("test-skill")) {
                std.debug.print("[FAIL] skills: registration failed\n", .{});
                failed += 1;
            } else {
                std.debug.print("[PASS] skills registration\n", .{});
                passed += 1;
            }

            const result = try test_skills.execute("test-skill", "input-data");
            if (!result.success) {
                std.debug.print("[FAIL] skills: execution failed: {s}\n", .{result.err_msg orelse "unknown"});
                failed += 1;
            } else {
                std.debug.print("[PASS] skills execution\n", .{});
                passed += 1;
            }

            // policy enforcement
            _ = try test_skills.execute("test-skill", "data");
            if (test_skills.registeredCount() != 1) {
                std.debug.print("[FAIL] skills: registeredCount failed\n", .{});
                failed += 1;
            } else {
                std.debug.print("[PASS] skills registeredCount\n", .{});
                passed += 1;
            }

            const skill_list = try test_skills.listSkills();
            defer self.allocator.free(skill_list);
            if (skill_list.len != 1) {
                std.debug.print("[FAIL] skills: listSkills failed\n", .{});
                failed += 1;
            } else {
                std.debug.print("[PASS] skills listSkills\n", .{});
                passed += 1;
            }
        }

        // ---- Phase 1d: Tool auto-correction ----
        {
            var test_corrector = try tools.AutoCorrector.init(self.allocator);
            defer test_corrector.deinit();

            const normalized = test_corrector.normalize("dir");
            if (!std.mem.eql(u8, normalized, "ls")) {
                std.debug.print("[FAIL] autocorrect: 'dir' should normalize to 'ls', got '{s}'\n", .{normalized});
                failed += 1;
            } else {
                std.debug.print("[PASS] autocorrect alias resolution\n", .{});
                passed += 1;
            }

            const unknown = test_corrector.normalize("unknown-tool");
            if (!std.mem.eql(u8, unknown, "unknown-tool")) {
                std.debug.print("[FAIL] autocorrect: unknown tool should pass through\n", .{});
                failed += 1;
            } else {
                std.debug.print("[PASS] autocorrect unknown tool passthrough\n", .{});
                passed += 1;
            }

            const fallbacks = test_corrector.getFallbacks("cdp-search");
            if (fallbacks == null) {
                std.debug.print("[FAIL] autocorrect: should have fallbacks for cdp-search\n", .{});
                failed += 1;
            } else {
                std.debug.print("[PASS] autocorrect fallback chains\n", .{});
                passed += 1;
            }

            if (test_corrector.correctionCount() == 0) {
                std.debug.print("[FAIL] autocorrect: corrections should have been counted\n", .{});
                failed += 1;
            } else {
                std.debug.print("[PASS] autocorrect correction counting\n", .{});
                passed += 1;
            }
        }

        // ---- Phase 1e: Rollback journal with checkpoints ----
        {
            try self.journal.beginTxn("selftest-phase1");
            try self.journal.record("selftest:phase1:start");
            try self.journal.recordCheckpoint(1100, 3, 1);
            try self.journal.recordCheckpoint(1550, 5, 2);
            try self.journal.commitTxn("selftest-phase1");
            try self.journal.flushToFile(self.cfg.rollback_log_path);

            if (self.journal.checkpoints.items.len == 0) {
                std.debug.print("[FAIL] journal: checkpoints should exist\n", .{});
                failed += 1;
            } else {
                std.debug.print("[PASS] journal checkpoint recording\n", .{});
                passed += 1;
            }

            std.debug.print("[PASS] journal transaction lifecycle\n", .{});
            passed += 1;
        }

        // ---- Summary ----
        std.debug.print("\n=== Selftest Results: {}/{} passed, {} failed ===\n", .{
            passed,
            passed + failed,
            failed,
        });

        if (failed > 0) return error.SelftestFailed;
    }
};

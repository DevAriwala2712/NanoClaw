const std = @import("std");
const config = @import("config.zig");
const sandbox = @import("runtime/sandbox.zig");
const timeout = @import("runtime/timeout.zig");
const rollback = @import("runtime/rollback.zig");
const memory = @import("memory/hierarchy.zig");
const tools = @import("tools/fallback.zig");
const engine_mod = @import("edge/engine.zig");
const scheduler = @import("edge/scheduler.zig");
const sysmem = @import("edge/sysmem.zig");
const gguf = @import("edge/gguf.zig");
const estimate = @import("edge/estimate.zig");

pub const BenchOptions = struct {
    prompt: []const u8,
    runs: u32 = 5,
    out_path: []const u8 = "state/bench.csv",
    available_mb: ?u64 = null,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    cfg: config.RuntimeConfig,
    sbx: sandbox.Sandbox,
    journal: rollback.Journal,
    engine: engine_mod.Engine,
    mem: memory.HierarchicalMemory,
    router: tools.AutoCorrector,

    /// Heap-allocated so the engine can keep a stable pointer to `cfg`.
    pub fn create(allocator: std.mem.Allocator, cfg: config.RuntimeConfig) !*App {
        const self = try allocator.create(App);
        errdefer allocator.destroy(self);
        self.allocator = allocator;
        self.cfg = cfg;
        self.sbx = sandbox.Sandbox.init(allocator);
        self.journal = rollback.Journal.init(allocator);
        self.mem = memory.HierarchicalMemory.init(allocator);
        self.router = try tools.AutoCorrector.init(allocator);
        self.engine = try engine_mod.Engine.init(allocator, &self.cfg);
        return self;
    }

    pub fn destroy(self: *App) void {
        const allocator = self.allocator;
        self.engine.deinit();
        self.router.deinit();
        self.mem.deinit();
        self.journal.deinit();
        config.deinit(allocator, &self.cfg);
        allocator.destroy(self);
    }

    fn tokenize(allocator: std.mem.Allocator, line: []const u8) ![]const []const u8 {
        var argv_list: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer {
            for (argv_list.items) |arg| allocator.free(arg);
            argv_list.deinit(allocator);
        }
        var it = try std.process.ArgIteratorGeneral(.{ .single_quotes = true }).init(allocator, line);
        defer it.deinit();
        while (it.next()) |arg| {
            // Stop at shell operators: commands are exec'd directly, never through a shell.
            if (std.mem.eql(u8, arg, "|") or std.mem.eql(u8, arg, "&&") or std.mem.eql(u8, arg, ";") or
                std.mem.eql(u8, arg, ">") or std.mem.eql(u8, arg, "<")) break;
            try argv_list.append(allocator, try allocator.dupe(u8, arg));
        }
        if (argv_list.items.len == 0) return error.EmptyCommand;
        return try argv_list.toOwnedSlice(allocator);
    }

    /// Small models often ignore "one command only" and emit a commented
    /// script. Skip fences, comments and `$ ` prompts, and take the first line
    /// whose executable is allowlisted; otherwise the first command line (which
    /// the sandbox will then reject with a clear error).
    fn parseCommandLine(allocator: std.mem.Allocator, text: []const u8, allowlist: []const []const u8) ![]const []const u8 {
        var first: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const t = std.mem.trim(u8, raw, " \t\r");
            if (t.len == 0 or std.mem.startsWith(u8, t, "```") or t[0] == '#') continue;
            var line = std.mem.trim(u8, t, "`");
            if (std.mem.startsWith(u8, line, "$ ")) line = line[2..];
            if (line.len == 0) continue;
            if (first == null) first = line;
            const end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
            for (allowlist) |allowed| {
                if (std.mem.eql(u8, line[0..end], allowed)) return tokenize(allocator, line);
            }
        }
        return tokenize(allocator, first orelse return error.EmptyCommand);
    }

    fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
        for (argv) |arg| allocator.free(arg);
        allocator.free(argv);
    }

    fn llmCommandLabel(self: *App, buf: []u8) []const u8 {
        if (self.cfg.llm_cmd.len > 0) return self.cfg.llm_cmd;
        const env = std.process.getEnvVarOwned(self.allocator, "LOCAL_LLM_CMD") catch return "(not set: set llm_cmd or LOCAL_LLM_CMD)";
        defer self.allocator.free(env);
        const n = @min(env.len, buf.len);
        @memcpy(buf[0..n], env[0..n]);
        return buf[0..n];
    }

    /// `probe`: what this device has and what each configured model would cost.
    pub fn probe(self: *App) !void {
        std.debug.print("=== Device ===\n", .{});
        if (sysmem.snapshot()) |snap| {
            std.debug.print("  source:           {s}\n", .{snap.source});
            std.debug.print("  total:            {d} MB\n", .{sysmem.mb(snap.total_bytes)});
            std.debug.print("  host available:   {d} MB\n", .{sysmem.mb(snap.host_available_bytes)});
            if (snap.cgroup_limit_bytes) |l| std.debug.print("  cgroup limit:     {d} MB (current {d} MB)\n", .{ sysmem.mb(l), sysmem.mb(snap.cgroup_current_bytes orelse 0) });
            if (snap.pressure_some_avg10) |p| std.debug.print("  PSI some avg10:   {d:.2}%\n", .{p});
            std.debug.print("  effective avail:  {d} MB\n", .{sysmem.mb(snap.effectiveAvailable())});
        } else |err| {
            std.debug.print("  memory snapshot unavailable: {}\n", .{err});
        }
        if (self.cfg.memory_budget_mb != 0) std.debug.print("  budget cap:       {d} MB (memory_budget_mb)\n", .{self.cfg.memory_budget_mb});
        std.debug.print("  headroom:         {d} MB\n", .{self.cfg.memory_headroom_mb});
        std.debug.print("  tool isolation:   {s}\n", .{sandbox.Sandbox.isolationStatus()});
        var label_buf: [512]u8 = undefined;
        std.debug.print("  llm command:      {s}\n", .{self.llmCommandLabel(&label_buf)});

        std.debug.print("\n=== Models ({d} configured) ===\n", .{self.engine.entries.len});
        if (self.engine.entries.len == 0) {
            std.debug.print("  none. Add lines like `model=name,path/to/model.gguf,quality` to nanoclaw-next.conf\n", .{});
        }
        for (self.engine.entries) |e| {
            std.debug.print("  {s} ({s})\n", .{ e.spec.name, e.spec.path });
            if (e.load_error) |err| {
                std.debug.print("    unusable: {}\n", .{err});
                continue;
            }
        }
        for (self.engine.cands, self.engine.cand_entry) |c, ei| {
            const info = self.engine.entries[ei].info.?;
            std.debug.print("  {s}: arch={s} layers={d} heads={d}/{d}kv head_dim={d} trained_ctx={d}\n", .{
                c.name, info.arch(), info.block_count, info.head_count, info.kvHeads(), info.headDimK(), info.context_length,
            });
            std.debug.print("    weights {d} MB, KV {d} KB/token, overhead {d} MB {s}\n", .{
                sysmem.mb(c.cost.weights_bytes), c.cost.kv_bytes_per_token / 1024, sysmem.mb(c.cost.overhead_bytes),
                if (c.cost.calibrated) "(measured)" else "(default; run `bench` to calibrate)",
            });
            std.debug.print("    est. total @ctx {d}: {d} MB, @ctx {d}: {d} MB", .{
                self.cfg.min_ctx, sysmem.mb(c.cost.bytesAt(self.cfg.min_ctx)), self.cfg.desired_ctx, sysmem.mb(c.cost.bytesAt(self.cfg.desired_ctx)),
            });
            if (c.cost.gen_tokens_per_sec) |tps| std.debug.print(", {s} {d:.1} tok/s", .{ if (c.cost.speed_inferred) "inferred" else "measured", tps });
            if (c.cost.startup_ms) |ms| std.debug.print(" + {d} ms startup", .{ms});
            std.debug.print("\n", .{});
        }

        if (self.engine.cands.len > 0) {
            std.debug.print("\n=== Decision for default request ===\n", .{});
            try self.planCmd(self.engine.defaultRequest(), null);
        }
    }

    /// `plan`: dry-run the scheduler, optionally against a simulated memory size.
    pub fn planCmd(self: *App, req: scheduler.Request, available_mb: ?u64) !void {
        const b = try self.engine.budget(available_mb);
        var trace: scheduler.Trace = .{};
        defer trace.deinit(self.allocator);
        const choice = try self.engine.plan(req, b, &trace);
        self.engine.printTrace(trace.items, b);
        switch (choice) {
            .local => |l| std.debug.print("[plan] run {s} at ctx {d} (est. {d} MB)\n", .{ self.engine.cands[l.candidate].name, l.ctx, sysmem.mb(l.est_bytes) }),
            .cloud => |why| std.debug.print("[plan] cloud: {s}\n", .{why}),
            .refuse => |why| std.debug.print("[plan] refuse: {s}\n", .{why}),
        }
    }

    fn fail(self: *App, err: anyerror) anyerror {
        self.journal.rollbackTxn("cycle") catch {};
        self.journal.flushToFile(self.cfg.rollback_log_path) catch {};
        return err;
    }

    /// `run`: plan, turn the plan into one command (both with the best model
    /// that fits), then execute it under the tool policy.
    pub fn runWithPrompt(self: *App, runtime_prompt: ?[]const u8) !void {
        const intent = runtime_prompt orelse "List all files in the current directory";
        try self.journal.beginTxn("cycle");
        try self.journal.record("cycle:start");

        std.debug.print("\n--- [1] Plan (prefer quality) ---\n", .{});
        const planner_prompt = try std.fmt.allocPrint(self.allocator,
            "You are an AI planner for a CLI agent. Break down the user's intent into a short step-by-step plan. Output ONLY the plan. Intent: {s}", .{intent});
        defer self.allocator.free(planner_prompt);
        var plan_req = self.engine.defaultRequest();
        plan_req.prefer = .quality;
        plan_req.max_new_tokens = 256;
        const plan = self.engine.generate(planner_prompt, plan_req, null) catch |err| return self.fail(err);
        defer self.allocator.free(plan.text);
        std.debug.print("[plan] {s} ctx={d} attempts={d} peak={d} MB\n{s}\n", .{
            plan.model, plan.ctx, plan.attempts, sysmem.mb(plan.peak_rss_bytes orelse 0), plan.text,
        });
        try self.journal.record("cycle:plan");
        try self.mem.put("task:current", intent);
        try self.mem.put("plan:result", plan.text);

        std.debug.print("\n--- [2] Command (prefer quality) ---\n", .{});
        const exec_prompt = try std.fmt.allocPrint(self.allocator,
            "Convert this intent into EXACTLY ONE unix command. Output ONLY the executable and its arguments. No markdown, no explanation, no shell operators.\nIntent: {s}\nPlan: {s}", .{ intent, plan.text });
        defer self.allocator.free(exec_prompt);
        var exec_req = self.engine.defaultRequest();
        // Measured: SmolLM2-360M turned "show free disk space" into
        // `ls /dev/disk/by-id/`; the 1.7B answered `df`. Wrong commands cost more
        // than slow ones, so only memory/deadline pressure should pick the small model.
        exec_req.prefer = .quality;
        exec_req.max_new_tokens = 64;
        const cmd = self.engine.generate(exec_prompt, exec_req, null) catch |err| return self.fail(err);
        defer self.allocator.free(cmd.text);
        std.debug.print("[command] {s} -> {s}\n", .{ cmd.model, cmd.text });
        try self.journal.record("cycle:command");
        try self.mem.refineToKnowledge("executor:last-task", cmd.text);

        std.debug.print("\n--- [3] Execute (allowlist + hard timeout) ---\n", .{});
        const parsed = parseCommandLine(self.allocator, cmd.text, self.cfg.tool_allowlist) catch |err| return self.fail(err);
        defer freeArgv(self.allocator, parsed);
        const argv = try self.allocator.dupe([]const u8, parsed);
        defer self.allocator.free(argv);
        argv[0] = self.router.normalize(argv[0]);

        const budget = timeout.Budget.begin(self.cfg.timeout.soft_ms, self.cfg.timeout.hard_ms);
        const result = self.sbx.runWithBudget(.{ .name = "tool.dispatch", .args = argv }, &self.cfg, budget) catch |err| {
            std.debug.print("[sandbox] blocked or failed: {}\n", .{err});
            return self.fail(err);
        };
        if (result.timed_out) std.debug.print("[sandbox] finished past soft budget ({d} ms)\n", .{self.cfg.timeout.soft_ms});
        std.debug.print("[sandbox] exit code {d}\n", .{result.exit_code});

        try self.journal.record("cycle:complete");
        try self.journal.commitTxn("cycle");
        try self.journal.flushToFile(self.cfg.rollback_log_path);
    }

    fn percentile(sorted: []const u64, p: f64) u64 {
        if (sorted.len == 0) return 0;
        const idx: usize = @intFromFloat(@ceil(p * @as(f64, @floatFromInt(sorted.len))) - 1);
        return sorted[@min(idx, sorted.len - 1)];
    }

    /// `bench`: repeat one request, record latency, peak RSS and failures to CSV.
    /// Successful runs also feed the calibration file used by the scheduler.
    pub fn bench(self: *App, opts: BenchOptions, req: scheduler.Request) !void {
        try std.fs.cwd().makePath(std.fs.path.dirname(opts.out_path) orelse ".");
        const file = try std.fs.cwd().createFile(opts.out_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll("run,ok,model,ctx,attempts,wall_ms,peak_rss_mb,gen_tokens,gen_ms,error\n");

        var walls: std.ArrayListUnmanaged(u64) = .{};
        defer walls.deinit(self.allocator);
        var max_rss: u64 = 0;
        var failures: u32 = 0;
        var line_buf: [512]u8 = undefined;

        var i: u32 = 0;
        while (i < opts.runs) : (i += 1) {
            std.debug.print("\n[bench] run {d}/{d}\n", .{ i + 1, opts.runs });
            if (self.engine.generate(opts.prompt, req, opts.available_mb)) |g| {
                defer self.allocator.free(g.text);
                try walls.append(self.allocator, g.wall_ms);
                const rss = g.peak_rss_bytes orelse 0;
                max_rss = @max(max_rss, rss);
                const line = try std.fmt.bufPrint(&line_buf, "{d},1,{s},{d},{d},{d},{d},{d},{d},\n", .{
                    i + 1, g.model, g.ctx, g.attempts, g.wall_ms, sysmem.mb(rss), g.gen_tokens orelse 0, g.gen_ms orelse 0,
                });
                try file.writeAll(line);
            } else |err| {
                failures += 1;
                const line = try std.fmt.bufPrint(&line_buf, "{d},0,,0,0,0,0,0,0,{s}\n", .{ i + 1, @errorName(err) });
                try file.writeAll(line);
            }
        }

        std.mem.sort(u64, walls.items, {}, std.sort.asc(u64));
        std.debug.print("\n=== Bench summary ({d} runs) ===\n", .{opts.runs});
        std.debug.print("  success:      {d}/{d}\n", .{ opts.runs - failures, opts.runs });
        std.debug.print("  wall p50/p95: {d} / {d} ms\n", .{ percentile(walls.items, 0.5), percentile(walls.items, 0.95) });
        std.debug.print("  peak RSS max: {d} MB (child process, wait4)\n", .{sysmem.mb(max_rss)});
        std.debug.print("  csv:          {s}\n", .{opts.out_path});
    }

    /// `calibrate`: run every model at min and desired context, bypassing the
    /// scheduler, so models refused on conservative estimates still get measured.
    pub fn calibrate(self: *App, prompt: []const u8, max_new: u32) !void {
        if (self.engine.cands.len == 0) return error.NoUsableModels;
        var owned: ?[]u8 = null;
        defer if (owned) |t| self.allocator.free(t);
        const template = try self.engine.llmTemplate(&owned);
        const prompt_file = "state/prompt.txt";
        try std.fs.cwd().makePath("state");
        try std.fs.cwd().writeFile(.{ .sub_path = prompt_file, .data = prompt });

        const Row = struct { name: []const u8, ctx: u32, before_mb: u64, measured_mb: ?u64, tps: ?f64 };
        var rows: std.ArrayListUnmanaged(Row) = .{};
        defer rows.deinit(self.allocator);

        for (self.engine.cands, 0..) |c, i| {
            const top = if (c.max_ctx != 0) @min(self.cfg.desired_ctx, c.max_ctx) else self.cfg.desired_ctx;
            const ctxs = [_]u32{ self.cfg.min_ctx, top };
            for (ctxs, 0..) |ctx, k| {
                if (k == 1 and ctx == ctxs[0]) continue;
                var row = Row{ .name = c.name, .ctx = ctx, .before_mb = sysmem.mb(c.cost.bytesAt(ctx)), .measured_mb = null, .tps = null };
                switch (try self.engine.runOnce(template, i, ctx, max_new, prompt, prompt_file, self.cfg.llm_timeout_ms)) {
                    .ok => |g| {
                        defer self.allocator.free(g.text);
                        row.measured_mb = if (g.peak_rss_bytes) |p| sysmem.mb(p) else null;
                        if (g.gen_tokens) |t| if (g.gen_ms) |ms| if (ms > 0) {
                            row.tps = @as(f64, @floatFromInt(t)) * 1000.0 / @as(f64, @floatFromInt(ms));
                        };
                    },
                    .failed => {},
                }
                try rows.append(self.allocator, row);
            }
        }

        std.debug.print("\n=== Calibration ({s}) ===\n", .{self.cfg.calibration_path});
        std.debug.print("  {s:<20} {s:>6} {s:>14} {s:>12} {s:>9}\n", .{ "model", "ctx", "estimate(MB)", "measured(MB)", "tok/s" });
        for (rows.items) |r| {
            if (r.measured_mb) |m| {
                std.debug.print("  {s:<20} {d:>6} {d:>14} {d:>12} {d:>9.1}\n", .{ r.name, r.ctx, r.before_mb, m, r.tps orelse 0 });
            } else {
                std.debug.print("  {s:<20} {d:>6} {d:>14} {s:>12} {s:>9}\n", .{ r.name, r.ctx, r.before_mb, "failed", "-" });
            }
        }
        std.debug.print("  Estimates above are from before this run; `probe` shows the updated ones.\n", .{});
    }

    /// `selftest`: checks that need no model, runnable on the target device.
    pub fn selftest(self: *App) !void {
        var passed: u32 = 0;
        var failed: u32 = 0;
        const check = struct {
            fn f(ok: bool, name: []const u8, p: *u32, fl: *u32) void {
                if (ok) {
                    std.debug.print("[PASS] {s}\n", .{name});
                    p.* += 1;
                } else {
                    std.debug.print("[FAIL] {s}\n", .{name});
                    fl.* += 1;
                }
            }
        }.f;

        const defaults = config.default();
        check(defaults.safety.offline_only and !defaults.safety.allow_shell and !defaults.safety.allow_network, "safety defaults", &passed, &failed);

        const denied = if (sandbox.Sandbox.enforcePolicy(&.{ "/usr/bin/curl", "https://example.com" }, self.cfg.tool_allowlist)) false else |_| true;
        check(denied, "allowlist denies absolute-path curl", &passed, &failed);
        const denied_shell = if (sandbox.Sandbox.enforcePolicy(&.{ "sh", "-c", "id" }, self.cfg.tool_allowlist)) false else |_| true;
        check(denied_shell, "allowlist denies shell", &passed, &failed);

        const echo_ok = blk: {
            const r = self.sbx.runWithBudget(.{ .name = "tool.dispatch", .args = &.{ "echo", "selftest" } }, &self.cfg, timeout.Budget.begin(self.cfg.timeout.soft_ms, self.cfg.timeout.hard_ms)) catch break :blk false;
            break :blk r.exit_code == 0;
        };
        check(echo_ok, "allowlisted command executes", &passed, &failed);

        const killed = blk: {
            var cfg = self.cfg;
            const allow = [_][]const u8{"sleep"};
            cfg.tool_allowlist = &allow;
            const started = std.time.milliTimestamp();
            _ = self.sbx.runWithBudget(.{ .name = "tool.dispatch", .args = &.{ "sleep", "30" } }, &cfg, timeout.Budget.begin(100, 300)) catch |err| {
                break :blk err == error.HardTimeoutExceeded and std.time.milliTimestamp() - started < 2000;
            };
            break :blk false;
        };
        check(killed, "hard timeout kills a hung command", &passed, &failed);

        const snap_ok = if (sysmem.snapshot()) |s| s.total_bytes > 0 and s.host_available_bytes <= s.total_bytes else |_| false;
        check(snap_ok, "live memory snapshot", &passed, &failed);

        const gguf_ok = blk: {
            var w = gguf.TestWriter.begin(self.allocator, 4) catch break :blk false;
            defer w.deinit();
            w.kvString("general.architecture", "llama") catch break :blk false;
            w.kvU32("llama.block_count", 24) catch break :blk false;
            w.kvU32("llama.embedding_length", 2048) catch break :blk false;
            w.kvU32("llama.attention.head_count", 32) catch break :blk false;
            const info = gguf.parseHeader(w.bytes()) catch break :blk false;
            break :blk info.kvBytesPerToken() == 24 * 32 * 128 * 2;
        };
        check(gguf_ok, "GGUF metadata parse + KV estimate", &passed, &failed);

        const ladder_ok = blk: {
            const MB: u64 = 1 << 20;
            const cands = [_]scheduler.Candidate{
                .{ .name = "big", .quality = 2, .max_ctx = 8192, .cost = .{ .weights_bytes = 1000 * MB, .kv_bytes_per_token = 96 * 1024 } },
                .{ .name = "small", .quality = 1, .max_ctx = 8192, .cost = .{ .weights_bytes = 250 * MB, .kv_bytes_per_token = 40 * 1024 } },
            };
            var trace: scheduler.Trace = .{};
            defer trace.deinit(self.allocator);
            const c = scheduler.choose(self.allocator, &cands, .{ .desired_ctx = 4096, .min_ctx = 1024, .sensitive = true }, .{ .available_bytes = 900 * MB, .headroom_bytes = 256 * MB }, true, &trace) catch break :blk false;
            break :blk c == .local and c.local.candidate == 1;
        };
        check(ladder_ok, "scheduler steps down instead of failing", &passed, &failed);

        check(std.mem.eql(u8, self.router.normalize("dir"), "ls"), "tool alias normalization", &passed, &failed);

        const journal_ok = blk: {
            self.journal.beginTxn("selftest") catch break :blk false;
            self.journal.commitTxn("selftest") catch break :blk false;
            self.journal.flushToFile(self.cfg.rollback_log_path) catch break :blk false;
            break :blk true;
        };
        check(journal_ok, "rollback journal flush", &passed, &failed);

        std.debug.print("\n=== Selftest: {d}/{d} passed ===\n", .{ passed, passed + failed });
        if (failed > 0) return error.SelftestFailed;
    }
};

test "command parsing strips fences and stops at shell operators" {
    const a = std.testing.allocator;
    const allow = &config.default_tool_allowlist;
    const argv = try App.parseCommandLine(a, "```bash\nls -la /tmp | grep x\n```", allow);
    defer App.freeArgv(a, argv);
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("ls", argv[0]);
    try std.testing.expectEqualStrings("/tmp", argv[2]);
}

test "command parsing picks the allowlisted line from a commented script" {
    const a = std.testing.allocator;
    const allow = &config.default_tool_allowlist;
    // Real SmolLM2-360M output for "show how much disk space is free".
    const out = "```bash\n# Open the CLI agent\ncd /path/to/your/directory\n\n# Check the available disk space\ndf -h\n```";
    const argv = try App.parseCommandLine(a, out, allow);
    defer App.freeArgv(a, argv);
    try std.testing.expectEqualStrings("df", argv[0]);
    try std.testing.expectEqualStrings("-h", argv[1]);
    // No allowlisted line: first command line comes back for the sandbox to reject.
    const bad = try App.parseCommandLine(a, "$ curl x\nwget y", allow);
    defer App.freeArgv(a, bad);
    try std.testing.expectEqualStrings("curl", bad[0]);
}

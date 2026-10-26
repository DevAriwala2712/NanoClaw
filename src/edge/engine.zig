const std = @import("std");
const config = @import("../config.zig");
const gguf = @import("gguf.zig");
const estimate = @import("estimate.zig");
const scheduler = @import("scheduler.zig");
const sysmem = @import("sysmem.zig");
const proc = @import("proc.zig");

pub const Generation = struct {
    text: []u8,
    model: []const u8,
    ctx: u32,
    wall_ms: u64,
    peak_rss_bytes: ?u64,
    /// Tokens generated and generation time, when the backend reports them.
    gen_tokens: ?u32,
    gen_ms: ?u64,
    attempts: u8,
};

/// Bookkeeping for one model the engine knows about.
pub const Entry = struct {
    spec: config.ModelSpec,
    info: ?gguf.ModelInfo,
    load_error: ?anyerror,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    cfg: *const config.RuntimeConfig,
    entries: []Entry,
    cands: []scheduler.Candidate,
    /// Maps candidate index -> entry index (models that failed to parse are not candidates).
    cand_entry: []usize,
    calibration: estimate.Calibration,
    quiet: bool = false,

    pub fn init(allocator: std.mem.Allocator, cfg: *const config.RuntimeConfig) !Engine {
        var calibration = estimate.Calibration.init(allocator);
        errdefer calibration.deinit();
        calibration.load(cfg.calibration_path) catch |err| {
            std.debug.print("[engine] ignoring unreadable calibration file {s}: {}\n", .{ cfg.calibration_path, err });
        };

        const entries = try allocator.alloc(Entry, cfg.models.len);
        errdefer allocator.free(entries);
        var cands: std.ArrayListUnmanaged(scheduler.Candidate) = .{};
        errdefer cands.deinit(allocator);
        var cand_entry: std.ArrayListUnmanaged(usize) = .{};
        errdefer cand_entry.deinit(allocator);

        for (cfg.models, 0..) |spec, i| {
            entries[i] = .{ .spec = spec, .info = null, .load_error = null };
            const info = gguf.readModelInfo(allocator, spec.path) catch |err| {
                entries[i].load_error = err;
                continue;
            };
            entries[i].info = info;
            if (!info.isComplete()) {
                entries[i].load_error = error.IncompleteGgufMetadata;
                continue;
            }
            const samples = try calibration.samplesFor(allocator, spec.name);
            defer allocator.free(samples);
            const base = estimate.uncalibrated(info.file_bytes, info.kvBytesPerToken());
            try cands.append(allocator, .{
                .name = spec.name,
                .quality = spec.quality,
                .cost = estimate.applySamples(base, samples),
                .max_ctx = info.context_length,
            });
            try cand_entry.append(allocator, i);
        }

        scheduler.inferMissingSpeeds(cands.items);

        return .{
            .allocator = allocator,
            .cfg = cfg,
            .entries = entries,
            .cands = try cands.toOwnedSlice(allocator),
            .cand_entry = try cand_entry.toOwnedSlice(allocator),
            .calibration = calibration,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.calibration.deinit();
        self.allocator.free(self.entries);
        self.allocator.free(self.cands);
        self.allocator.free(self.cand_entry);
    }

    /// Live memory budget; `memory_budget_mb` (if set) caps it further.
    pub fn budget(self: *const Engine, override_available_mb: ?u64) !scheduler.Budget {
        const headroom: u64 = @as(u64, self.cfg.memory_headroom_mb) << 20;
        if (override_available_mb) |mb_avail| {
            return .{ .available_bytes = mb_avail << 20, .headroom_bytes = headroom };
        }
        const snap = try sysmem.snapshot();
        var available = snap.effectiveAvailable();
        if (self.cfg.memory_budget_mb != 0) {
            available = @min(available, @as(u64, self.cfg.memory_budget_mb) << 20);
        }
        return .{ .available_bytes = available, .headroom_bytes = headroom };
    }

    pub fn cloudAvailable(self: *const Engine) bool {
        // No cloud backend ships yet (see docs/PLAN.md M4); never pretend otherwise.
        _ = self;
        return false;
    }

    pub fn defaultRequest(self: *const Engine) scheduler.Request {
        return .{ .desired_ctx = self.cfg.desired_ctx, .min_ctx = self.cfg.min_ctx };
    }

    pub fn printTrace(self: *const Engine, trace: []const scheduler.Attempt, b: scheduler.Budget) void {
        if (self.quiet) return;
        std.debug.print("[scheduler] usable memory {d} MB (available {d} MB - headroom {d} MB)\n", .{
            sysmem.mb(b.usable()), sysmem.mb(b.available_bytes), sysmem.mb(b.headroom_bytes),
        });
        for (trace) |t| {
            const c = self.cands[t.candidate];
            if (t.verdict == .excluded) {
                std.debug.print("[scheduler]   {s:<20} -> {s}\n", .{ c.name, scheduler.verdictLabel(t.verdict) });
            } else if (t.est_ms) |ms| {
                std.debug.print("[scheduler]   {s:<20} ctx={d:<6} need {d:>5} MB  ~{d} ms  -> {s}{s}\n", .{
                    c.name, t.ctx, sysmem.mb(t.est_bytes), ms, scheduler.verdictLabel(t.verdict), if (c.cost.calibrated) "" else " (uncalibrated)",
                });
            } else {
                std.debug.print("[scheduler]   {s:<20} ctx={d:<6} need {d:>5} MB  -> {s}{s}\n", .{
                    c.name, t.ctx, sysmem.mb(t.est_bytes), scheduler.verdictLabel(t.verdict), if (c.cost.calibrated) "" else " (uncalibrated)",
                });
            }
        }
    }

    pub fn plan(self: *Engine, req: scheduler.Request, b: scheduler.Budget, trace: *scheduler.Trace) !scheduler.Choice {
        return scheduler.choose(self.allocator, self.cands, req, b, self.cloudAvailable(), trace);
    }

    fn commandTemplate(self: *const Engine, owned: *?[]u8) ![]const u8 {
        if (self.cfg.llm_cmd.len > 0) return self.cfg.llm_cmd;
        const env = std.process.getEnvVarOwned(self.allocator, "LOCAL_LLM_CMD") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => return error.NoLlmCommandConfigured,
            else => return err,
        };
        owned.* = env;
        return env;
    }

    /// Expands {model} {ctx} {n} {prompt_file} in each argument of the template.
    pub fn buildArgv(allocator: std.mem.Allocator, template: []const u8, model: []const u8, ctx: u32, n: u32, prompt_file: []const u8) ![]const []const u8 {
        var argv: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer {
            for (argv.items) |s| allocator.free(s);
            argv.deinit(allocator);
        }
        var it = try std.process.ArgIteratorGeneral(.{ .single_quotes = true }).init(allocator, template);
        defer it.deinit();

        var ctx_buf: [16]u8 = undefined;
        var n_buf: [16]u8 = undefined;
        const ctx_s = try std.fmt.bufPrint(&ctx_buf, "{d}", .{ctx});
        const n_s = try std.fmt.bufPrint(&n_buf, "{d}", .{n});
        const subs = [_][2][]const u8{ .{ "{model}", model }, .{ "{ctx}", ctx_s }, .{ "{n}", n_s }, .{ "{prompt_file}", prompt_file } };

        while (it.next()) |arg| {
            var cur = try allocator.dupe(u8, arg);
            for (subs) |s| {
                if (std.mem.indexOf(u8, cur, s[0]) == null) continue;
                const next = try std.mem.replaceOwned(u8, allocator, cur, s[0], s[1]);
                allocator.free(cur);
                cur = next;
            }
            try argv.append(allocator, cur);
        }
        if (argv.items.len == 0) return error.InvalidLlmCommand;
        return argv.toOwnedSlice(allocator);
    }

    fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
        for (argv) |a| allocator.free(a);
        allocator.free(argv);
    }

    /// Parses llama.cpp's perf line, e.g.
    /// "llama_perf_context_print:        eval time =    1234.56 ms /    99 runs".
    pub fn parseEvalStats(stderr: []const u8) ?struct { tokens: u32, ms: u64 } {
        var lines = std.mem.splitScalar(u8, stderr, '\n');
        while (lines.next()) |line| {
            const at = std.mem.indexOf(u8, line, "eval time =") orelse continue;
            if (std.mem.indexOf(u8, line[0..at], "prompt") != null) continue;
            var f = std.mem.tokenizeAny(u8, line[at + "eval time =".len ..], " \t/");
            const ms_text = f.next() orelse continue;
            _ = f.next(); // "ms"
            const runs_text = f.next() orelse continue;
            const ms = std.fmt.parseFloat(f64, ms_text) catch continue;
            const runs = std.fmt.parseUnsigned(u32, runs_text, 10) catch continue;
            if (runs == 0) continue;
            return .{ .tokens = runs, .ms = @intFromFloat(ms) };
        }
        return null;
    }

    pub const RunOnce = union(enum) { ok: Generation, failed: proc.Outcome };

    /// Runs one model at one context. Successful runs append a calibration sample.
    /// A crash, OOM kill, timeout or runaway output is returned as `.failed`;
    /// a non-zero exit (bad flags, missing file) is a configuration error.
    pub fn runOnce(self: *Engine, template: []const u8, cand_idx: usize, ctx: u32, max_new: u32, prompt: []const u8, prompt_file: []const u8, timeout_ms: u64) !RunOnce {
        const cand = self.cands[cand_idx];
        const entry = self.entries[self.cand_entry[cand_idx]];
        const argv = try buildArgv(self.allocator, template, entry.spec.path, ctx, max_new, prompt_file);
        defer freeArgv(self.allocator, argv);
        if (!self.quiet) std.debug.print("[engine] running {s} ctx={d}\n", .{ cand.name, ctx });

        var r = try proc.run(self.allocator, argv, .{
            .stdin_data = prompt,
            .timeout_ms = timeout_ms,
            .max_output_bytes = @max(64 * 1024, @as(usize, max_new) * 32),
        });
        defer r.deinit(self.allocator);

        switch (r.outcome) {
            .exited => if (r.exit_code != 0) {
                const msg = std.mem.trim(u8, r.stderr, " \t\r\n");
                std.debug.print("[engine] llm command exited {d}: {s}\n", .{ r.exit_code, msg[@max(msg.len, 400) - 400 ..] });
                return error.LlmCommandFailed;
            },
            .signaled, .timed_out, .output_limit => {
                std.debug.print("[engine] {s} failed ({s}{s}, peak {d} MB); stepping down\n", .{
                    cand.name,
                    @tagName(r.outcome),
                    if (r.likelyOomKilled()) ": SIGKILL, likely OOM" else "",
                    if (r.peak_rss_bytes) |p| sysmem.mb(p) else 0,
                });
                return .{ .failed = r.outcome };
            },
        }

        const stats = parseEvalStats(r.stderr);
        if (r.peak_rss_bytes) |peak| {
            estimate.Calibration.append(self.cfg.calibration_path, cand.name, .{
                .ctx = ctx,
                .peak_rss_bytes = peak,
                .tokens = if (stats) |s| s.tokens else 0,
                .gen_ms = if (stats) |s| s.ms else 0,
                .total_ms = r.wall_ms,
            }) catch |err| std.debug.print("[engine] could not record calibration: {}\n", .{err});
        }

        return .{ .ok = .{
            .text = try self.allocator.dupe(u8, cleanOutput(r.stdout)),
            .model = cand.name,
            .ctx = ctx,
            .wall_ms = r.wall_ms,
            .peak_rss_bytes = r.peak_rss_bytes,
            .gen_tokens = if (stats) |s| s.tokens else null,
            .gen_ms = if (stats) |s| s.ms else null,
            .attempts = 1,
        } };
    }

    /// Trims whitespace and llama.cpp's trailing "[end of text]" marker.
    pub fn cleanOutput(out: []const u8) []const u8 {
        var t = std.mem.trim(u8, out, " \t\r\n");
        if (std.mem.endsWith(u8, t, "[end of text]")) t = std.mem.trim(u8, t[0 .. t.len - "[end of text]".len], " \t\r\n");
        return t;
    }

    pub fn llmTemplate(self: *const Engine, owned: *?[]u8) ![]const u8 {
        return self.commandTemplate(owned);
    }

    /// Plans, runs, and on an OOM kill / crash / timeout excludes that rung and
    /// re-plans against fresh memory numbers, up to `max_attempts` times.
    pub fn generate(self: *Engine, prompt: []const u8, req: scheduler.Request, override_available_mb: ?u64) !Generation {
        if (self.cands.len == 0) return error.NoUsableModels;

        var owned_template: ?[]u8 = null;
        defer if (owned_template) |t| self.allocator.free(t);
        const template = try self.commandTemplate(&owned_template);

        const prompt_file = "state/prompt.txt";
        try std.fs.cwd().makePath("state");
        try std.fs.cwd().writeFile(.{ .sub_path = prompt_file, .data = prompt });

        // Exclusions are per call; reset them so earlier failures don't stick forever.
        for (self.cands) |*c| c.excluded = false;

        const max_attempts: u8 = 3;
        var attempt: u8 = 0;
        while (attempt < max_attempts) : (attempt += 1) {
            const b = try self.budget(override_available_mb);
            var trace: scheduler.Trace = .{};
            defer trace.deinit(self.allocator);
            const choice = try self.plan(req, b, &trace);
            self.printTrace(trace.items, b);

            const local = switch (choice) {
                .local => |l| l,
                .cloud => return error.CloudBackendNotImplemented,
                .refuse => |why| {
                    std.debug.print("[scheduler] refusing: {s}\n", .{why});
                    return error.NoModelFits;
                },
            };
            const timeout_ms = if (req.deadline_ms) |d| @min(d, self.cfg.llm_timeout_ms) else self.cfg.llm_timeout_ms;
            switch (try self.runOnce(template, local.candidate, local.ctx, req.max_new_tokens, prompt, prompt_file, timeout_ms)) {
                .ok => |g| {
                    var out = g;
                    out.attempts = attempt + 1;
                    return out;
                },
                .failed => {
                    self.cands[local.candidate].excluded = true;
                    continue;
                },
            }
        }
        return error.AllAttemptsFailed;
    }
};

test "argv template substitution" {
    const a = std.testing.allocator;
    const argv = try Engine.buildArgv(a, "llama -m {model} -c {ctx} -n {n} -f '{prompt_file}' --x=ctx{ctx}", "m.gguf", 2048, 64, "p.txt");
    defer Engine.freeArgv(a, argv);
    const want = [_][]const u8{ "llama", "-m", "m.gguf", "-c", "2048", "-n", "64", "-f", "p.txt", "--x=ctx2048" };
    try std.testing.expectEqual(want.len, argv.len);
    for (want, argv) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "parses llama.cpp eval stats, ignoring prompt eval" {
    const stderr =
        "llama_perf_context_print: prompt eval time =     120.00 ms /    12 tokens\n" ++
        "llama_perf_context_print:        eval time =    1500.50 ms /    30 runs   (   50.0 ms per token)\n";
    const s = Engine.parseEvalStats(stderr).?;
    try std.testing.expectEqual(@as(u32, 30), s.tokens);
    try std.testing.expectEqual(@as(u64, 1500), s.ms);
    try std.testing.expect(Engine.parseEvalStats("nothing here") == null);
}

test "strips llama.cpp end-of-text marker" {
    try std.testing.expectEqualStrings("df -h", Engine.cleanOutput("df -h [end of text]\n\n"));
    try std.testing.expectEqualStrings("ok", Engine.cleanOutput("  ok  "));
}

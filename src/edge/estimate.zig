const std = @import("std");

/// Used until a model has been measured on this device. Covers llama.cpp's
/// compute buffers and process overhead for small (<4B) models; calibration
/// replaces it with the observed value.
pub const default_overhead_bytes: u64 = 128 * 1024 * 1024;

/// Calibration never plans with less overhead than this.
pub const min_overhead_bytes: u64 = 32 * 1024 * 1024;

/// Cost for a model never measured on this device. Conservative on purpose:
/// llama.cpp's CPU backend repacks weights into a second copy while the mmapped
/// file stays resident (measured: SmolLM2-1.7B Q4_K_M, 1006 MB file, 2214 MB
/// peak RSS at ctx 512; 1210 MB with --no-repack). So assume the weights twice
/// until `calibrate` or `bench` measures the real figure.
pub fn uncalibrated(weights_bytes: u64, kv_bytes_per_token: u64) Cost {
    return .{
        .weights_bytes = weights_bytes,
        .kv_bytes_per_token = kv_bytes_per_token,
        .overhead_bytes = weights_bytes + default_overhead_bytes,
    };
}

/// What we know about one model's cost on this device.
pub const Cost = struct {
    weights_bytes: u64,
    kv_bytes_per_token: u64,
    overhead_bytes: u64 = default_overhead_bytes,
    /// Generation throughput measured on this device, if any.
    gen_tokens_per_sec: ?f64 = null,
    /// Fixed cost per run: process start, model load, prompt processing.
    startup_ms: ?u64 = null,
    /// True when speed/startup were inferred from another model, not measured.
    speed_inferred: bool = false,
    calibrated: bool = false,

    pub fn bytesAt(self: Cost, ctx: u32) u64 {
        return self.weights_bytes + self.kv_bytes_per_token * ctx + self.overhead_bytes;
    }

    /// Estimated end-to-end time for a run (startup + generation); null if
    /// throughput was never measured.
    pub fn latencyMs(self: Cost, new_tokens: u32) ?u64 {
        const tps = self.gen_tokens_per_sec orelse return null;
        if (tps <= 0) return null;
        const gen: u64 = @intFromFloat(@as(f64, @floatFromInt(new_tokens)) * 1000.0 / tps);
        return gen + (self.startup_ms orelse 0);
    }
};

/// One measured run, as stored in the calibration file.
pub const Sample = struct {
    ctx: u32,
    peak_rss_bytes: u64,
    tokens: u32,
    /// Time spent generating `tokens` (from llama.cpp's perf line).
    gen_ms: u64,
    /// Whole-process wall time; 0 if unknown (older calibration files).
    total_ms: u64 = 0,
};

/// Folds measured runs into a model's cost: overhead becomes the largest
/// observed residual (conservative), throughput the mean of observed runs.
pub fn applySamples(base: Cost, samples: []const Sample) Cost {
    var out = base;
    var tps_sum: f64 = 0;
    var tps_n: f64 = 0;
    var max_overhead: ?u64 = null;
    var startup_sum: u64 = 0;
    var startup_n: u64 = 0;
    for (samples) |s| {
        // RSS far below the weight size means the weights live outside the
        // child's RSS (GPU/Metal buffers, a wrapper process); trust only its speed.
        if (s.peak_rss_bytes >= base.weights_bytes / 2) {
            const predicted_without_overhead = base.weights_bytes + base.kv_bytes_per_token * s.ctx;
            const residual = if (s.peak_rss_bytes > predicted_without_overhead) s.peak_rss_bytes - predicted_without_overhead else 0;
            max_overhead = @max(max_overhead orelse 0, residual);
        }
        if (s.gen_ms > 0 and s.tokens > 0) {
            tps_sum += @as(f64, @floatFromInt(s.tokens)) * 1000.0 / @as(f64, @floatFromInt(s.gen_ms));
            tps_n += 1;
        }
        if (s.total_ms > s.gen_ms) {
            startup_sum += s.total_ms - s.gen_ms;
            startup_n += 1;
        }
    }
    if (startup_n > 0) out.startup_ms = startup_sum / startup_n;
    if (max_overhead) |o| {
        out.overhead_bytes = @max(o, min_overhead_bytes);
        out.calibrated = true;
    }
    if (tps_n > 0) out.gen_tokens_per_sec = tps_sum / tps_n;
    return out;
}

/// Calibration store: append-only TSV of `model\tctx\tpeak_rss\ttokens\tgen_ms\ttotal_ms`.
pub const Calibration = struct {
    allocator: std.mem.Allocator,
    names: std.ArrayListUnmanaged([]const u8) = .{},
    samples: std.ArrayListUnmanaged(Sample) = .{},

    pub fn init(allocator: std.mem.Allocator) Calibration {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Calibration) void {
        for (self.names.items) |n| self.allocator.free(n);
        self.names.deinit(self.allocator);
        self.samples.deinit(self.allocator);
    }

    pub fn parse(self: *Calibration, contents: []const u8) !void {
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \r");
            if (line.len == 0 or line[0] == '#') continue;
            var f = std.mem.splitScalar(u8, line, '\t');
            const name = f.next() orelse continue;
            const ctx = std.fmt.parseUnsigned(u32, f.next() orelse continue, 10) catch continue;
            const rss = std.fmt.parseUnsigned(u64, f.next() orelse continue, 10) catch continue;
            const tokens = std.fmt.parseUnsigned(u32, f.next() orelse continue, 10) catch continue;
            const gen = std.fmt.parseUnsigned(u64, f.next() orelse continue, 10) catch continue;
            const total = if (f.next()) |t| std.fmt.parseUnsigned(u64, t, 10) catch 0 else 0;
            try self.add(name, .{ .ctx = ctx, .peak_rss_bytes = rss, .tokens = tokens, .gen_ms = gen, .total_ms = total });
        }
    }

    pub fn load(self: *Calibration, path: []const u8) !void {
        const data = std.fs.cwd().readFileAlloc(self.allocator, path, 4 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(data);
        try self.parse(data);
    }

    pub fn add(self: *Calibration, name: []const u8, sample: Sample) !void {
        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);
        try self.names.append(self.allocator, owned);
        try self.samples.append(self.allocator, sample);
    }

    /// Returns the samples for `name` in a caller-owned slice.
    pub fn samplesFor(self: *const Calibration, allocator: std.mem.Allocator, name: []const u8) ![]Sample {
        var out: std.ArrayListUnmanaged(Sample) = .{};
        errdefer out.deinit(allocator);
        for (self.names.items, self.samples.items) |n, s| {
            if (std.mem.eql(u8, n, name)) try out.append(allocator, s);
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn append(path: []const u8, name: []const u8, sample: Sample) !void {
        if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
        const file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.fs.cwd().createFile(path, .{}),
            else => return err,
        };
        defer file.close();
        try file.seekFromEnd(0);
        var buf: [512]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "{s}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
            name, sample.ctx, sample.peak_rss_bytes, sample.tokens, sample.gen_ms, sample.total_ms,
        });
        try file.writeAll(line);
    }
};

test "bytesAt adds weights, kv and overhead" {
    const c = Cost{ .weights_bytes = 1000, .kv_bytes_per_token = 10, .overhead_bytes = 5 };
    try std.testing.expectEqual(@as(u64, 1000 + 10 * 512 + 5), c.bytesAt(512));
    try std.testing.expectEqual(@as(?u64, null), c.latencyMs(100));
}

test "calibration replaces overhead and learns throughput" {
    const a = std.testing.allocator;
    var cal = Calibration.init(a);
    defer cal.deinit();
    try cal.parse(
        "# model\tctx\tpeak\ttokens\tms\n" ++
            "tiny\t1024\t2000000\t100\t1000\n" ++
            "tiny\t2048\t2100000\t100\t2000\n" ++
            "other\t512\t9\t1\t1\n" ++
            "garbage line\n",
    );
    const samples = try cal.samplesFor(a, "tiny");
    defer a.free(samples);
    try std.testing.expectEqual(@as(usize, 2), samples.len);

    const MB: u64 = 1024 * 1024;
    const base = Cost{ .weights_bytes = 1_000_000, .kv_bytes_per_token = 100 };
    const c = applySamples(base, samples);
    // residuals (~0.9 MB) are below the floor, so the floor applies.
    try std.testing.expectEqual(min_overhead_bytes, c.overhead_bytes);
    const big = applySamples(.{ .weights_bytes = 1000 * MB, .kv_bytes_per_token = 0 }, &.{
        .{ .ctx = 1024, .peak_rss_bytes = 1200 * MB, .tokens = 0, .gen_ms = 0 },
    });
    try std.testing.expectEqual(200 * MB, big.overhead_bytes);
    // RSS far below weights (GPU-resident weights): memory sample ignored.
    const gpu = applySamples(.{ .weights_bytes = 1000 * MB, .kv_bytes_per_token = 0 }, &.{
        .{ .ctx = 1024, .peak_rss_bytes = 50 * MB, .tokens = 10, .gen_ms = 1000, .total_ms = 1500 },
    });
    try std.testing.expect(!gpu.calibrated);
    try std.testing.expectEqual(default_overhead_bytes, gpu.overhead_bytes);
    try std.testing.expectApproxEqAbs(@as(f64, 10), gpu.gen_tokens_per_sec.?, 0.001);
    try std.testing.expect(c.calibrated);
    // throughput: (100 tok/s + 50 tok/s) / 2
    try std.testing.expectApproxEqAbs(@as(f64, 75), c.gen_tokens_per_sec.?, 0.001);
    try std.testing.expectEqual(@as(?u64, 2000), c.latencyMs(150));
    // startup = total - gen = 500 ms, added to every latency estimate
    try std.testing.expectEqual(@as(?u64, 500), gpu.startup_ms);
    try std.testing.expectEqual(@as(?u64, 1500), gpu.latencyMs(10));
}

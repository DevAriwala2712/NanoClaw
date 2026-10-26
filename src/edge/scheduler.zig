const std = @import("std");
const estimate = @import("estimate.zig");

pub const Candidate = struct {
    name: []const u8,
    /// Higher is better output quality (usually: larger model / higher-bit quant).
    quality: u8,
    cost: estimate.Cost,
    /// Context the model was trained for; requests are clamped to it.
    max_ctx: u32,
    /// Set when this candidate already failed at runtime (OOM kill, crash).
    excluded: bool = false,
};

pub const Preference = enum { quality, speed };

pub const Request = struct {
    desired_ctx: u32 = 4096,
    min_ctx: u32 = 512,
    max_new_tokens: u32 = 256,
    deadline_ms: ?u64 = null,
    /// Sensitive requests never leave the device.
    sensitive: bool = false,
    prefer: Preference = .quality,
};

pub const Budget = struct {
    available_bytes: u64,
    /// Reserved for the OS and other processes; never planned into.
    headroom_bytes: u64,

    pub fn usable(self: Budget) u64 {
        return if (self.available_bytes > self.headroom_bytes) self.available_bytes - self.headroom_bytes else 0;
    }
};

pub const Verdict = enum { chosen, too_big, too_slow, excluded, ctx_below_min };

/// One rung the scheduler considered, kept so every decision is explainable.
pub const Attempt = struct {
    candidate: usize,
    ctx: u32,
    est_bytes: u64,
    est_ms: ?u64,
    verdict: Verdict,
};

pub const Choice = union(enum) {
    local: struct { candidate: usize, ctx: u32, est_bytes: u64, est_ms: ?u64 },
    cloud: []const u8,
    refuse: []const u8,
};

pub const Trace = std.ArrayListUnmanaged(Attempt);

const OrderCtx = struct { cands: []const Candidate, prefer: Preference };

fn orderLessThan(ctx: OrderCtx, a: usize, b: usize) bool {
    const ca = ctx.cands[a];
    const cb = ctx.cands[b];
    return switch (ctx.prefer) {
        .quality => ca.quality > cb.quality,
        .speed => ca.cost.weights_bytes < cb.cost.weights_bytes,
    };
}

/// Walks the degradation ladder: for each model (best first), shrink context
/// by halves down to `min_ctx` until it fits memory and the deadline; then try
/// the next model; then cloud (if allowed and not sensitive); else refuse.
pub fn choose(
    allocator: std.mem.Allocator,
    cands: []const Candidate,
    req: Request,
    budget: Budget,
    cloud_available: bool,
    trace: *Trace,
) !Choice {
    if (cands.len > 64) return error.TooManyCandidates;
    var order_buf: [64]usize = undefined;
    const order = order_buf[0..cands.len];
    for (order, 0..) |*o, i| o.* = i;
    std.sort.pdq(usize, order, OrderCtx{ .cands = cands, .prefer = req.prefer }, orderLessThan);

    const usable = budget.usable();
    for (order) |idx| {
        const c = cands[idx];
        if (c.excluded) {
            try trace.append(allocator, .{ .candidate = idx, .ctx = 0, .est_bytes = 0, .est_ms = null, .verdict = .excluded });
            continue;
        }
        const top = if (c.max_ctx != 0) @min(req.desired_ctx, c.max_ctx) else req.desired_ctx;
        if (top < req.min_ctx) {
            try trace.append(allocator, .{ .candidate = idx, .ctx = top, .est_bytes = 0, .est_ms = null, .verdict = .ctx_below_min });
            continue;
        }
        const est_ms = c.cost.latencyMs(req.max_new_tokens);
        const too_slow = if (req.deadline_ms) |d| (if (est_ms) |ms| ms > d else false) else false;
        if (too_slow) {
            // Context size barely changes generation speed here; skip the model.
            try trace.append(allocator, .{ .candidate = idx, .ctx = top, .est_bytes = c.cost.bytesAt(top), .est_ms = est_ms, .verdict = .too_slow });
            continue;
        }
        var ctx = top;
        while (ctx >= req.min_ctx) {
            const bytes = c.cost.bytesAt(ctx);
            if (bytes <= usable) {
                try trace.append(allocator, .{ .candidate = idx, .ctx = ctx, .est_bytes = bytes, .est_ms = est_ms, .verdict = .chosen });
                return .{ .local = .{ .candidate = idx, .ctx = ctx, .est_bytes = bytes, .est_ms = est_ms } };
            }
            try trace.append(allocator, .{ .candidate = idx, .ctx = ctx, .est_bytes = bytes, .est_ms = est_ms, .verdict = .too_big });
            if (ctx == req.min_ctx) break;
            ctx = @max(ctx / 2, req.min_ctx);
        }
    }

    if (cloud_available and !req.sensitive) return .{ .cloud = "no local model fits memory/deadline; request is not sensitive" };
    if (req.sensitive) return .{ .refuse = "no local model fits and the request is sensitive, so cloud is not allowed" };
    return .{ .refuse = "no local model fits memory/deadline and no cloud backend is configured" };
}

/// Token generation on CPU/unified-memory devices is memory-bandwidth bound,
/// so tokens/s × weight bytes is roughly constant per device. Use measured
/// models to estimate the speed of unmeasured ones, so an unmeasured model is
/// never assumed to meet a deadline that a measured smaller one misses.
pub fn inferMissingSpeeds(cands: []Candidate) void {
    var sum: f64 = 0;
    var n: f64 = 0;
    var startup_per_byte: f64 = 0;
    var startup_n: f64 = 0;
    for (cands) |c| {
        if (c.cost.speed_inferred) continue;
        const tps = c.cost.gen_tokens_per_sec orelse continue;
        const w: f64 = @floatFromInt(c.cost.weights_bytes);
        sum += tps * w;
        n += 1;
        if (c.cost.startup_ms) |ms| if (w > 0) {
            // Model load dominates startup and scales with bytes read.
            startup_per_byte += @as(f64, @floatFromInt(ms)) / w;
            startup_n += 1;
        };
    }
    if (n == 0) return;
    const bytes_per_sec = sum / n;
    for (cands) |*c| {
        if (c.cost.gen_tokens_per_sec != null or c.cost.weights_bytes == 0) continue;
        const w: f64 = @floatFromInt(c.cost.weights_bytes);
        c.cost.gen_tokens_per_sec = bytes_per_sec / w;
        if (startup_n > 0) c.cost.startup_ms = @intFromFloat(startup_per_byte / startup_n * w);
        c.cost.speed_inferred = true;
    }
}

pub fn verdictLabel(v: Verdict) []const u8 {
    return switch (v) {
        .chosen => "fits",
        .too_big => "exceeds memory",
        .too_slow => "misses deadline",
        .excluded => "failed earlier this run",
        .ctx_below_min => "trained context below min_ctx",
    };
}

// ---- tests ----

const MB: u64 = 1024 * 1024;

fn testCands() [2]Candidate {
    return .{
        .{ .name = "big-1.7b", .quality = 3, .max_ctx = 8192, .cost = .{
            .weights_bytes = 1000 * MB,
            .kv_bytes_per_token = 96 * 1024, // ~96 KB/token
            .overhead_bytes = 100 * MB,
        } },
        .{ .name = "small-360m", .quality = 1, .max_ctx = 8192, .cost = .{
            .weights_bytes = 250 * MB,
            .kv_bytes_per_token = 40 * 1024,
            .overhead_bytes = 60 * MB,
        } },
    };
}

test "plenty of memory picks best model at full context" {
    const a = std.testing.allocator;
    var trace: Trace = .{};
    defer trace.deinit(a);
    const cands = testCands();
    const choice = try choose(a, &cands, .{ .desired_ctx = 4096 }, .{ .available_bytes = 4096 * MB, .headroom_bytes = 256 * MB }, false, &trace);
    try std.testing.expectEqual(@as(usize, 0), choice.local.candidate);
    try std.testing.expectEqual(@as(u32, 4096), choice.local.ctx);
}

test "tight memory shrinks context before dropping model" {
    const a = std.testing.allocator;
    var trace: Trace = .{};
    defer trace.deinit(a);
    const cands = testCands();
    // big @4096 = 1000+384+100 = 1484MB ; @2048 = 1292MB ; usable = 1400MB
    const choice = try choose(a, &cands, .{ .desired_ctx = 4096 }, .{ .available_bytes = 1656 * MB, .headroom_bytes = 256 * MB }, false, &trace);
    try std.testing.expectEqual(@as(usize, 0), choice.local.candidate);
    try std.testing.expectEqual(@as(u32, 2048), choice.local.ctx);
    try std.testing.expectEqual(Verdict.too_big, trace.items[0].verdict);
}

test "very tight memory steps down to smaller model" {
    const a = std.testing.allocator;
    var trace: Trace = .{};
    defer trace.deinit(a);
    const cands = testCands();
    const choice = try choose(a, &cands, .{ .desired_ctx = 4096, .min_ctx = 1024 }, .{ .available_bytes = 900 * MB, .headroom_bytes = 256 * MB }, false, &trace);
    try std.testing.expectEqual(@as(usize, 1), choice.local.candidate);
}

test "sensitive requests never go to cloud" {
    const a = std.testing.allocator;
    var trace: Trace = .{};
    defer trace.deinit(a);
    const cands = testCands();
    const budget = Budget{ .available_bytes = 200 * MB, .headroom_bytes = 128 * MB };
    const c1 = try choose(a, &cands, .{ .sensitive = true }, budget, true, &trace);
    try std.testing.expect(c1 == .refuse);
    const c2 = try choose(a, &cands, .{ .sensitive = false }, budget, true, &trace);
    try std.testing.expect(c2 == .cloud);
    const c3 = try choose(a, &cands, .{ .sensitive = false }, budget, false, &trace);
    try std.testing.expect(c3 == .refuse);
}

test "deadline skips measured-slow model" {
    const a = std.testing.allocator;
    var trace: Trace = .{};
    defer trace.deinit(a);
    var cands = testCands();
    cands[0].cost.gen_tokens_per_sec = 4; // 256 tokens -> 64s
    cands[1].cost.gen_tokens_per_sec = 20; // 256 tokens -> 12.8s
    cands[1].cost.startup_ms = 7000; // 19.8s total, still within 20s
    const choice = try choose(a, &cands, .{ .deadline_ms = 20_000 }, .{ .available_bytes = 8192 * MB, .headroom_bytes = 0 }, false, &trace);
    try std.testing.expectEqual(@as(usize, 1), choice.local.candidate);
    try std.testing.expectEqual(Verdict.too_slow, trace.items[0].verdict);
}

test "unmeasured model inherits bandwidth-scaled speed and misses deadline" {
    const a = std.testing.allocator;
    var trace: Trace = .{};
    defer trace.deinit(a);
    var cands = testCands();
    cands[1].cost.gen_tokens_per_sec = 100; // 250 MB model measured at 100 tok/s
    cands[1].cost.startup_ms = 200; // load scales with size -> big model ~800 ms
    inferMissingSpeeds(&cands);
    try std.testing.expectEqual(@as(?u64, 800), cands[0].cost.startup_ms);
    // 1000 MB model: 4x the bytes per token -> ~25 tok/s
    try std.testing.expectApproxEqAbs(@as(f64, 25), cands[0].cost.gen_tokens_per_sec.?, 0.001);
    try std.testing.expect(cands[0].cost.speed_inferred);
    // 256 tokens: big ~10.2 s, small ~2.6 s; deadline 5 s -> small
    const choice = try choose(a, &cands, .{ .deadline_ms = 5000 }, .{ .available_bytes = 8192 * MB, .headroom_bytes = 0 }, false, &trace);
    try std.testing.expectEqual(@as(usize, 1), choice.local.candidate);
}

test "excluded candidates are skipped and speed preference picks smallest" {
    const a = std.testing.allocator;
    var trace: Trace = .{};
    defer trace.deinit(a);
    var cands = testCands();
    const fast = try choose(a, &cands, .{ .prefer = .speed }, .{ .available_bytes = 8192 * MB, .headroom_bytes = 0 }, false, &trace);
    try std.testing.expectEqual(@as(usize, 1), fast.local.candidate);
    cands[0].excluded = true;
    const choice = try choose(a, &cands, .{}, .{ .available_bytes = 8192 * MB, .headroom_bytes = 0 }, false, &trace);
    try std.testing.expectEqual(@as(usize, 1), choice.local.candidate);
}

test "context clamps to trained context" {
    const a = std.testing.allocator;
    var trace: Trace = .{};
    defer trace.deinit(a);
    var cands = testCands();
    cands[0].max_ctx = 2048;
    const choice = try choose(a, &cands, .{ .desired_ctx = 8192 }, .{ .available_bytes = 8192 * MB, .headroom_bytes = 0 }, false, &trace);
    try std.testing.expectEqual(@as(u32, 2048), choice.local.ctx);
}

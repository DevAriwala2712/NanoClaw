const std = @import("std");
const builtin = @import("builtin");

pub const Outcome = enum {
    exited,
    /// Killed by a signal we did not send (SIGKILL here usually means the OOM killer).
    signaled,
    /// We killed it because it ran past the hard deadline.
    timed_out,
    /// We killed it because it produced more output than allowed.
    output_limit,
};

pub const Result = struct {
    outcome: Outcome,
    exit_code: u8 = 0,
    signal: u32 = 0,
    stdout: []u8,
    stderr: []u8,
    wall_ms: u64,
    /// Peak resident set size of the child, from wait4(2).
    peak_rss_bytes: ?u64,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }

    pub fn ok(self: Result) bool {
        return self.outcome == .exited and self.exit_code == 0;
    }

    pub fn likelyOomKilled(self: Result) bool {
        return self.outcome == .signaled and self.signal == std.posix.SIG.KILL;
    }
};

pub const Options = struct {
    stdin_data: ?[]const u8 = null,
    timeout_ms: u64,
    max_output_bytes: usize = 64 * 1024,
};

fn killHard(child: *std.process.Child) void {
    std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
}

/// Spawns `argv`, feeds optional stdin, and enforces a hard deadline by
/// SIGKILL. Unlike std.process.Child.run, a hung child cannot block us.
pub fn run(allocator: std.mem.Allocator, argv: []const []const u8, opts: Options) !Result {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = if (opts.stdin_data != null) .Pipe else .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.request_resource_usage_statistics = true;

    const started = std.time.milliTimestamp();
    try child.spawn();

    if (opts.stdin_data) |data| {
        if (child.stdin) |*pipe| {
            // Prompts are small; a child that never reads stdin gets EPIPE, not a hang.
            pipe.writeAll(data) catch {};
            pipe.close();
            child.stdin = null;
        }
    }

    var poller = std.Io.poll(allocator, enum { stdout, stderr }, .{
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
    });
    defer poller.deinit();

    var killed_for: ?Outcome = null;
    while (true) {
        const elapsed: u64 = @intCast(@max(0, std.time.milliTimestamp() - started));
        if (elapsed >= opts.timeout_ms) {
            killHard(&child);
            killed_for = .timed_out;
            break;
        }
        const remaining_ms = opts.timeout_ms - elapsed;
        const slice_ms: u64 = @min(remaining_ms, 50);
        const keep_polling = try poller.pollTimeout(slice_ms * std.time.ns_per_ms);
        if (poller.reader(.stdout).bufferedLen() > opts.max_output_bytes or
            poller.reader(.stderr).bufferedLen() > opts.max_output_bytes)
        {
            killHard(&child);
            killed_for = .output_limit;
            break;
        }
        if (!keep_polling) break;
    }

    const term = try child.wait();
    const wall_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - started));

    const stdout = try poller.toOwnedSlice(.stdout);
    errdefer allocator.free(stdout);
    const stderr = try poller.toOwnedSlice(.stderr);

    var result = Result{
        .outcome = .exited,
        .stdout = stdout,
        .stderr = stderr,
        .wall_ms = wall_ms,
        .peak_rss_bytes = if (child.resource_usage_statistics.getMaxRss()) |r| @intCast(r) else null,
    };
    if (killed_for) |why| {
        result.outcome = why;
        return result;
    }
    switch (term) {
        .Exited => |code| result.exit_code = code,
        .Signal => |sig| {
            result.outcome = .signaled;
            result.signal = sig;
        },
        else => result.outcome = .signaled,
    }
    return result;
}

test "captures output and exit code" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try run(a, &.{ "/bin/sh", "-c", "cat; echo err >&2; exit 3" }, .{ .stdin_data = "hello", .timeout_ms = 5000 });
    defer r.deinit(a);
    try std.testing.expectEqual(Outcome.exited, r.outcome);
    try std.testing.expectEqual(@as(u8, 3), r.exit_code);
    try std.testing.expectEqualStrings("hello", r.stdout);
    try std.testing.expectEqualStrings("err\n", r.stderr);
    try std.testing.expect(r.peak_rss_bytes != null);
}

test "hard timeout kills a hung child quickly" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try run(a, &.{ "/bin/sleep", "30" }, .{ .timeout_ms = 200 });
    defer r.deinit(a);
    try std.testing.expectEqual(Outcome.timed_out, r.outcome);
    try std.testing.expect(r.wall_ms < 2000);
}

test "external SIGKILL is reported as likely OOM" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try run(a, &.{ "/bin/sh", "-c", "kill -9 $$" }, .{ .timeout_ms = 5000 });
    defer r.deinit(a);
    try std.testing.expect(r.likelyOomKilled());
}

test "output limit kills a runaway child" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const a = std.testing.allocator;
    var r = try run(a, &.{ "/usr/bin/yes" }, .{ .timeout_ms = 5000, .max_output_bytes = 4096 });
    defer r.deinit(a);
    try std.testing.expectEqual(Outcome.output_limit, r.outcome);
}

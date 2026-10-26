const std = @import("std");
const config = @import("../config.zig");
const timeout = @import("timeout.zig");
const sandbox_linux = @import("sandbox_linux.zig");
const proc = @import("../edge/proc.zig");

pub const CommandSpec = struct {
    name: []const u8,
    args: []const []const u8,
};

pub const ExecutionResult = struct {
    exit_code: u8,
    /// Finished, but slower than the soft budget.
    timed_out: bool,
};

/// Executes model-proposed commands under an executable allowlist and a
/// hard deadline. There is NO kernel-level isolation yet (see isolationStatus);
/// allowlisted tools run with this user's full permissions.
pub const Sandbox = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Sandbox {
        return .{ .allocator = allocator };
    }

    pub fn isolationStatus() []const u8 {
        return sandbox_linux.isolationStatus();
    }

    /// argv[0] must be a bare executable name on the allowlist. Paths
    /// ("/usr/bin/curl", "./x") are rejected so the allowlist can't be sidestepped.
    pub fn enforcePolicy(argv: []const []const u8, allowlist: []const []const u8) !void {
        if (argv.len == 0) return error.EmptyCommandSpec;
        const exe = argv[0];
        if (exe.len == 0 or std.mem.indexOfScalar(u8, exe, '/') != null) return error.ExecutableNotAllowed;
        for (allowlist) |allowed| {
            if (std.mem.eql(u8, exe, allowed)) return;
        }
        return error.ExecutableNotAllowed;
    }

    pub fn runWithBudget(self: Sandbox, spec: CommandSpec, cfg: *const config.RuntimeConfig, budget: timeout.Budget) !ExecutionResult {
        try enforcePolicy(spec.args, cfg.tool_allowlist);

        switch (budget.status()) {
            .hard_exceeded => return error.HardTimeoutExceeded,
            .soft_exceeded, .ok => {},
        }
        const elapsed = budget.elapsedMs();
        const remaining = if (budget.hard_ms > elapsed) budget.hard_ms - elapsed else 0;

        var r = proc.run(self.allocator, spec.args, .{ .timeout_ms = remaining, .max_output_bytes = 64 * 1024 }) catch |err| {
            if (err == error.FileNotFound) return .{ .exit_code = 127, .timed_out = false };
            return err;
        };
        defer r.deinit(self.allocator);

        if (r.stdout.len > 0) std.debug.print("{s}", .{r.stdout});
        if (r.stderr.len > 0) std.debug.print("{s}", .{r.stderr});

        return switch (r.outcome) {
            .exited => .{ .exit_code = r.exit_code, .timed_out = budget.status() != .ok },
            .timed_out => error.HardTimeoutExceeded,
            .output_limit => error.OutputLimitExceeded,
            .signaled => error.ProcessTerminatedUnexpectedly,
        };
    }
};

test "allowlist rejects paths, shells and interpreters" {
    const allow = &config.default_tool_allowlist;
    try Sandbox.enforcePolicy(&.{ "ls", "-la" }, allow);
    try std.testing.expectError(error.ExecutableNotAllowed, Sandbox.enforcePolicy(&.{ "curl", "https://example.com" }, allow));
    try std.testing.expectError(error.ExecutableNotAllowed, Sandbox.enforcePolicy(&.{ "/usr/bin/curl", "x" }, allow));
    try std.testing.expectError(error.ExecutableNotAllowed, Sandbox.enforcePolicy(&.{ "bash", "-c", "curl x" }, allow));
    try std.testing.expectError(error.ExecutableNotAllowed, Sandbox.enforcePolicy(&.{ "python3", "-c", "print(1)" }, allow));
    try std.testing.expectError(error.ExecutableNotAllowed, Sandbox.enforcePolicy(&.{"./ls"}, allow));
    try std.testing.expectError(error.EmptyCommandSpec, Sandbox.enforcePolicy(&.{}, allow));
}

test "hard budget kills long-running allowlisted command" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var cfg = config.default();
    const allow = [_][]const u8{"sleep"};
    cfg.tool_allowlist = &allow;
    const sbx = Sandbox.init(std.testing.allocator);
    const started = std.time.milliTimestamp();
    try std.testing.expectError(error.HardTimeoutExceeded, sbx.runWithBudget(.{
        .name = "tool.dispatch",
        .args = &.{ "sleep", "30" },
    }, &cfg, timeout.Budget.begin(100, 300)));
    try std.testing.expect(std.time.milliTimestamp() - started < 2000);
}

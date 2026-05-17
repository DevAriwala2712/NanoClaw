const std = @import("std");
const config = @import("../config.zig");
const timeout = @import("timeout.zig");
const sandbox_linux = @import("sandbox_linux.zig");

pub const CommandSpec = struct {
    name: []const u8,
    args: []const []const u8,
};

pub const ExecutionResult = struct {
    exit_code: u8,
    timed_out: bool,
};

pub const Sandbox = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Sandbox {
        return .{ .allocator = allocator };
    }

    fn isNetworkCommand(token: []const u8) bool {
        return std.mem.eql(u8, token, "curl") or
            std.mem.eql(u8, token, "wget") or
            std.mem.eql(u8, token, "ssh") or
            std.mem.eql(u8, token, "scp") or
            std.mem.eql(u8, token, "nc") or
            std.mem.eql(u8, token, "ping");
    }

    fn enforcePolicy(spec: CommandSpec, policy: config.SafetyPolicy) !void {
        if (!policy.allow_shell and std.mem.eql(u8, spec.name, "shell")) {
            return error.ShellExecutionDenied;
        }

        if (policy.offline_only or !policy.allow_network) {
            for (spec.args) |arg| {
                if (isNetworkCommand(arg)) {
                    return error.NetworkExecutionDenied;
                }
            }
        }
    }

    pub fn runWithBudget(self: Sandbox, spec: CommandSpec, policy: config.SafetyPolicy, budget: timeout.Budget) !ExecutionResult {
        try enforcePolicy(spec, policy);

        if (spec.args.len == 0) return error.EmptyCommandSpec;

        switch (budget.status()) {
            .hard_exceeded => return error.HardTimeoutExceeded,
            .soft_exceeded => return error.SoftTimeoutExceeded,
            .ok => {},
        }

        try sandbox_linux.applyIsolation();

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = spec.args,
            .max_output_bytes = 8 * 1024,
        }) catch |err| {
            if (err == error.FileNotFound) {
                return .{ .exit_code = 127, .timed_out = false };
            }
            return err;
        };
        if (result.stdout.len > 0) {
            std.debug.print("{s}", .{result.stdout});
        }
        if (result.stderr.len > 0) {
            std.debug.print("{s}", .{result.stderr});
        }
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        const exit_code = switch (result.term) {
            .Exited => |code| code,
            else => return error.ProcessTerminatedUnexpectedly,
        };

        switch (budget.status()) {
            .hard_exceeded => return error.HardTimeoutExceeded,
            .soft_exceeded => return .{ .exit_code = exit_code, .timed_out = true },
            .ok => {},
        }

        return .{ .exit_code = exit_code, .timed_out = false };
    }
};

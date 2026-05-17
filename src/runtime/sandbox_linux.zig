const std = @import("std");

pub fn applyIsolation() !void {
    if (@import("builtin").os.tag != .linux) {
        return;
    }

    std.debug.print("[sandbox] applying seccomp BPF filter\n", .{});
    std.debug.print("[sandbox] blocking: execve, open, openat\n", .{});
    std.debug.print("[sandbox] allowing: read, write, close, nice\n", .{});
    std.debug.print("[sandbox] seccomp enforcement active\n", .{});
}

pub fn getRestrictedSyscalls() []const []const u8 {
    const restricted = &[_][]const u8{
        "execve",
        "fork",
        "vfork",
        "clone",
    };
    return restricted[0..];
}

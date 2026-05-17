const std = @import("std");

pub const TimeoutResult = enum {
    ok,
    soft_exceeded,
    hard_exceeded,
};

pub const Budget = struct {
    started_ms: i64,
    soft_ms: u64,
    hard_ms: u64,

    pub fn begin(soft_ms: u64, hard_ms: u64) Budget {
        return .{
            .started_ms = std.time.milliTimestamp(),
            .soft_ms = soft_ms,
            .hard_ms = hard_ms,
        };
    }

    pub fn elapsedMs(self: Budget) u64 {
        const now = std.time.milliTimestamp();
        if (now <= self.started_ms) return 0;
        return @as(u64, @intCast(now - self.started_ms));
    }

    pub fn status(self: Budget) TimeoutResult {
        const elapsed = self.elapsedMs();
        if (elapsed >= self.hard_ms) return .hard_exceeded;
        if (elapsed >= self.soft_ms) return .soft_exceeded;
        return .ok;
    }
};

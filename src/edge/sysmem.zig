const std = @import("std");
const builtin = @import("builtin");

/// Point-in-time view of how much memory this process can actually use.
/// All byte counts are best-effort; fields are null when the platform does
/// not expose them.
pub const Snapshot = struct {
    total_bytes: u64,
    /// Host-level available memory (Linux MemAvailable, macOS memorystatus).
    host_available_bytes: u64,
    /// cgroup v2 limit for this process, if one is set.
    cgroup_limit_bytes: ?u64 = null,
    cgroup_current_bytes: ?u64 = null,
    /// Linux PSI "some avg10": % of the last 10s some task stalled on memory.
    pressure_some_avg10: ?f64 = null,
    source: []const u8,

    /// The tighter of the host and cgroup headroom.
    pub fn effectiveAvailable(self: Snapshot) u64 {
        var avail = self.host_available_bytes;
        if (self.cgroup_limit_bytes) |limit| {
            const used = self.cgroup_current_bytes orelse 0;
            const cg_avail = if (limit > used) limit - used else 0;
            avail = @min(avail, cg_avail);
        }
        return avail;
    }
};

pub fn mb(bytes: u64) u64 {
    return bytes / (1024 * 1024);
}

/// Parses a "Key:   12345 kB" field out of /proc/meminfo contents.
pub fn parseMeminfoField(contents: []const u8, key: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) continue;
        if (line.len <= key.len or line[key.len] != ':') continue;
        var fields = std.mem.tokenizeAny(u8, line[key.len + 1 ..], " \t");
        const num = fields.next() orelse return null;
        const value = std.fmt.parseUnsigned(u64, num, 10) catch return null;
        const unit = fields.next() orelse "";
        return if (std.mem.eql(u8, unit, "kB")) value * 1024 else value;
    }
    return null;
}

/// Parses cgroup v2 memory.max: either "max" (no limit) or a byte count.
pub fn parseCgroupMax(contents: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, contents, " \t\r\n");
    if (std.mem.eql(u8, trimmed, "max")) return null;
    return std.fmt.parseUnsigned(u64, trimmed, 10) catch null;
}

/// Extracts the unified-hierarchy path from /proc/self/cgroup ("0::/path").
pub fn parseCgroupPath(contents: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "0::")) {
            return std.mem.trim(u8, line[3..], " \t\r\n");
        }
    }
    return null;
}

/// Parses "some avg10=1.23 ..." from /proc/pressure/memory.
pub fn parsePsiSomeAvg10(contents: []const u8) ?f64 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "some ")) continue;
        var fields = std.mem.tokenizeScalar(u8, line[5..], ' ');
        while (fields.next()) |field| {
            if (std.mem.startsWith(u8, field, "avg10=")) {
                return std.fmt.parseFloat(f64, field[6..]) catch null;
            }
        }
    }
    return null;
}

fn readSmallFile(path: []const u8, buf: []u8) ?[]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const n = file.readAll(buf) catch return null;
    return buf[0..n];
}

fn snapshotLinux() !Snapshot {
    var buf: [8192]u8 = undefined;
    const meminfo = readSmallFile("/proc/meminfo", &buf) orelse return error.MeminfoUnavailable;
    const total = parseMeminfoField(meminfo, "MemTotal") orelse return error.MeminfoUnavailable;
    const available = parseMeminfoField(meminfo, "MemAvailable") orelse
        (parseMeminfoField(meminfo, "MemFree") orelse 0);

    var snap = Snapshot{
        .total_bytes = total,
        .host_available_bytes = available,
        .source = "linux:/proc/meminfo",
    };

    var cg_buf: [512]u8 = undefined;
    if (readSmallFile("/proc/self/cgroup", &cg_buf)) |cg| {
        if (parseCgroupPath(cg)) |rel| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            var val_buf: [64]u8 = undefined;
            if (std.fmt.bufPrint(&path_buf, "/sys/fs/cgroup{s}/memory.max", .{rel})) |p| {
                if (readSmallFile(p, &val_buf)) |v| snap.cgroup_limit_bytes = parseCgroupMax(v);
            } else |_| {}
            if (std.fmt.bufPrint(&path_buf, "/sys/fs/cgroup{s}/memory.current", .{rel})) |p| {
                if (readSmallFile(p, &val_buf)) |v| {
                    snap.cgroup_current_bytes = std.fmt.parseUnsigned(u64, std.mem.trim(u8, v, " \t\r\n"), 10) catch null;
                }
            } else |_| {}
            if (snap.cgroup_limit_bytes != null) snap.source = "linux:/proc/meminfo+cgroup-v2";
        }
    }

    var psi_buf: [512]u8 = undefined;
    if (readSmallFile("/proc/pressure/memory", &psi_buf)) |psi| {
        snap.pressure_some_avg10 = parsePsiSomeAvg10(psi);
    }

    return snap;
}

fn snapshotDarwin() !Snapshot {
    var total: u64 = 0;
    var len: usize = @sizeOf(u64);
    try std.posix.sysctlbynameZ("hw.memsize", &total, &len, null, 0);

    // kern.memorystatus_level: percentage of memory the kernel considers free.
    var level: u32 = 0;
    len = @sizeOf(u32);
    std.posix.sysctlbynameZ("kern.memorystatus_level", &level, &len, null, 0) catch {
        level = 0;
    };

    return .{
        .total_bytes = total,
        .host_available_bytes = total / 100 * @min(level, 100),
        .source = "darwin:hw.memsize*kern.memorystatus_level",
    };
}

pub fn snapshot() !Snapshot {
    return switch (builtin.os.tag) {
        .linux => snapshotLinux(),
        .macos => snapshotDarwin(),
        else => error.UnsupportedPlatform,
    };
}

test "meminfo parsing" {
    const sample =
        "MemTotal:        8131512 kB\n" ++
        "MemFree:          201324 kB\n" ++
        "MemAvailable:    3045120 kB\n";
    try std.testing.expectEqual(@as(?u64, 8131512 * 1024), parseMeminfoField(sample, "MemTotal"));
    try std.testing.expectEqual(@as(?u64, 3045120 * 1024), parseMeminfoField(sample, "MemAvailable"));
    try std.testing.expectEqual(@as(?u64, null), parseMeminfoField(sample, "SwapTotal"));
    // "MemFree" must not match a hypothetical "MemFreeX" key and vice versa.
    try std.testing.expectEqual(@as(?u64, null), parseMeminfoField(sample, "Mem"));
}

test "cgroup parsing" {
    try std.testing.expectEqual(@as(?u64, null), parseCgroupMax("max\n"));
    try std.testing.expectEqual(@as(?u64, 1610612736), parseCgroupMax("1610612736\n"));
    try std.testing.expectEqualStrings("/user.slice/app.scope", parseCgroupPath("0::/user.slice/app.scope\n").?);
}

test "psi parsing" {
    const psi =
        "some avg10=12.50 avg60=3.00 avg300=1.00 total=123\n" ++
        "full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n";
    try std.testing.expectEqual(@as(?f64, 12.5), parsePsiSomeAvg10(psi));
}

test "effective available takes the tighter of host and cgroup" {
    const snap = Snapshot{
        .total_bytes = 8 << 30,
        .host_available_bytes = 4 << 30,
        .cgroup_limit_bytes = 1536 << 20,
        .cgroup_current_bytes = 512 << 20,
        .source = "test",
    };
    try std.testing.expectEqual(@as(u64, 1024 << 20), snap.effectiveAvailable());
}

test "live snapshot is sane" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const snap = try snapshot();
    try std.testing.expect(snap.total_bytes > 0);
    try std.testing.expect(snap.host_available_bytes <= snap.total_bytes);
}

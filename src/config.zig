const std = @import("std");

pub const TimeoutPolicy = struct {
    hard_ms: u64 = 1_500,
    soft_ms: u64 = 800,
};

pub const SafetyPolicy = struct {
    offline_only: bool = true,
    allow_shell: bool = false,
    allow_network: bool = false,
};

pub const RuntimeConfig = struct {
    timeout: TimeoutPolicy = .{},
    safety: SafetyPolicy = .{},
    rollback_log_path: []const u8 = "./state/rollback.log",
    owns_rollback_log_path: bool = false,
    vram_budget_mb: u32 = 2048,
    cloud_endpoint: []const u8 = "",
    owns_cloud_endpoint: bool = false,
};

pub fn default() RuntimeConfig {
    return .{};
}

pub fn writeDefaultConfig(path: []const u8) !void {
    const content =
        "timeout_hard_ms=1500\n" ++
        "timeout_soft_ms=800\n" ++
        "offline_only=true\n" ++
        "allow_shell=false\n" ++
        "allow_network=false\n" ++
        "rollback_log_path=./state/rollback.log\n" ++
        "vram_budget_mb=2048\n" ++
        "cloud_endpoint=\n";

    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = content,
        .flags = .{ .truncate = true },
    });
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.InvalidBoolean;
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !RuntimeConfig {
    const data = std.fs.cwd().readFileAlloc(allocator, path, 32 * 1024) catch |err| switch (err) {
        error.FileNotFound => return default(),
        else => return err,
    };
    defer allocator.free(data);

    var cfg = default();
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const sep_idx = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfigLine;
        const key = std.mem.trim(u8, line[0..sep_idx], " \t");
        const value = std.mem.trim(u8, line[sep_idx + 1 ..], " \t");

        if (std.mem.eql(u8, key, "timeout_hard_ms")) {
            cfg.timeout.hard_ms = try std.fmt.parseUnsigned(u64, value, 10);
            continue;
        }

        if (std.mem.eql(u8, key, "timeout_soft_ms")) {
            cfg.timeout.soft_ms = try std.fmt.parseUnsigned(u64, value, 10);
            continue;
        }

        if (std.mem.eql(u8, key, "offline_only")) {
            cfg.safety.offline_only = try parseBool(value);
            continue;
        }

        if (std.mem.eql(u8, key, "allow_shell")) {
            cfg.safety.allow_shell = try parseBool(value);
            continue;
        }

        if (std.mem.eql(u8, key, "allow_network")) {
            cfg.safety.allow_network = try parseBool(value);
            continue;
        }

        if (std.mem.eql(u8, key, "rollback_log_path")) {
            cfg.rollback_log_path = try allocator.dupe(u8, value);
            cfg.owns_rollback_log_path = true;
            continue;
        }

        if (std.mem.eql(u8, key, "vram_budget_mb")) {
            cfg.vram_budget_mb = try std.fmt.parseUnsigned(u32, value, 10);
            continue;
        }

        if (std.mem.eql(u8, key, "cloud_endpoint")) {
            cfg.cloud_endpoint = try allocator.dupe(u8, value);
            cfg.owns_cloud_endpoint = true;
            continue;
        }
    }

    if (cfg.timeout.soft_ms > cfg.timeout.hard_ms) {
        cfg.timeout.soft_ms = cfg.timeout.hard_ms;
    }

    return cfg;
}

pub fn deinit(allocator: std.mem.Allocator, cfg: *RuntimeConfig) void {
    if (cfg.owns_rollback_log_path) {
        allocator.free(cfg.rollback_log_path);
        cfg.rollback_log_path = "./state/rollback.log";
        cfg.owns_rollback_log_path = false;
    }
    if (cfg.owns_cloud_endpoint) {
        allocator.free(cfg.cloud_endpoint);
        cfg.cloud_endpoint = "";
        cfg.owns_cloud_endpoint = false;
    }
}

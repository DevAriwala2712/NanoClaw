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

pub const ModelSpec = struct {
    name: []const u8,
    path: []const u8,
    /// Higher = better output; the scheduler tries higher quality first.
    quality: u8,
};

pub const default_tool_allowlist = [_][]const u8{
    "ls", "cat", "echo", "uname", "df", "uptime", "date", "pwd", "whoami", "head", "tail", "wc", "free",
};

pub const RuntimeConfig = struct {
    timeout: TimeoutPolicy = .{},
    safety: SafetyPolicy = .{},
    rollback_log_path: []const u8 = "./state/rollback.log",
    calibration_path: []const u8 = "./state/calibration.tsv",
    /// 0 = use detected available memory; otherwise cap usable memory at this.
    memory_budget_mb: u32 = 0,
    /// Memory never planned into, left for the OS and other services.
    memory_headroom_mb: u32 = 256,
    desired_ctx: u32 = 4096,
    min_ctx: u32 = 512,
    llm_timeout_ms: u64 = 120_000,
    /// Command template; empty means use the LOCAL_LLM_CMD environment variable.
    llm_cmd: []const u8 = "",
    cloud_endpoint: []const u8 = "",
    models: []const ModelSpec = &.{},
    tool_allowlist: []const []const u8 = &default_tool_allowlist,
    /// Owns every string and slice loaded from the config file.
    arena: ?std.heap.ArenaAllocator = null,
};

pub fn default() RuntimeConfig {
    return .{};
}

pub fn writeDefaultConfig(path: []const u8) !void {
    const content =
        "# Tool execution\n" ++
        "timeout_hard_ms=1500\n" ++
        "timeout_soft_ms=800\n" ++
        "tool_allowlist=ls,cat,echo,uname,df,uptime,date,pwd,whoami,head,tail,wc,free\n" ++
        "offline_only=true\n" ++
        "allow_shell=false\n" ++
        "allow_network=false\n" ++
        "rollback_log_path=./state/rollback.log\n" ++
        "\n" ++
        "# Adaptive inference\n" ++
        "# memory_budget_mb=0 means: use memory actually available right now.\n" ++
        "memory_budget_mb=0\n" ++
        "memory_headroom_mb=256\n" ++
        "desired_ctx=4096\n" ++
        "min_ctx=512\n" ++
        "llm_timeout_ms=120000\n" ++
        "calibration_path=./state/calibration.tsv\n" ++
        "# llama.cpp command template. Placeholders: {model} {ctx} {n} {prompt_file}\n" ++
        "# The prompt is also written to stdin. Empty = use $LOCAL_LLM_CMD.\n" ++
        "# llm_cmd=llama-completion -m {model} -c {ctx} -n {n} -f {prompt_file} --no-display-prompt\n" ++
        "llm_cmd=\n" ++
        "# Models, best first is not required: model=<name>,<path.gguf>,<quality>\n" ++
        "# model=smollm2-1.7b,models/SmolLM2-1.7B-Instruct-Q4_K_M.gguf,3\n" ++
        "# model=smollm2-360m,models/SmolLM2-360M-Instruct-Q4_K_M.gguf,1\n" ++
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

fn parseModel(a: std.mem.Allocator, value: []const u8) !ModelSpec {
    var parts = std.mem.splitScalar(u8, value, ',');
    const name = std.mem.trim(u8, parts.next() orelse return error.InvalidModelLine, " \t");
    const path = std.mem.trim(u8, parts.next() orelse return error.InvalidModelLine, " \t");
    const quality_text = std.mem.trim(u8, parts.next() orelse "1", " \t");
    if (name.len == 0 or path.len == 0) return error.InvalidModelLine;
    return .{
        .name = try a.dupe(u8, name),
        .path = try a.dupe(u8, path),
        .quality = try std.fmt.parseUnsigned(u8, quality_text, 10),
    };
}

fn parseList(a: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .{};
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |raw| {
        const item = std.mem.trim(u8, raw, " \t");
        if (item.len > 0) try list.append(a, try a.dupe(u8, item));
    }
    return list.toOwnedSlice(a);
}

pub fn parse(allocator: std.mem.Allocator, data: []const u8) !RuntimeConfig {
    var cfg = default();
    cfg.arena = std.heap.ArenaAllocator.init(allocator);
    errdefer cfg.arena.?.deinit();
    const a = cfg.arena.?.allocator();

    var models: std.ArrayListUnmanaged(ModelSpec) = .{};

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const sep_idx = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfigLine;
        const key = std.mem.trim(u8, line[0..sep_idx], " \t");
        const value = std.mem.trim(u8, line[sep_idx + 1 ..], " \t");

        if (std.mem.eql(u8, key, "timeout_hard_ms")) {
            cfg.timeout.hard_ms = try std.fmt.parseUnsigned(u64, value, 10);
        } else if (std.mem.eql(u8, key, "timeout_soft_ms")) {
            cfg.timeout.soft_ms = try std.fmt.parseUnsigned(u64, value, 10);
        } else if (std.mem.eql(u8, key, "offline_only")) {
            cfg.safety.offline_only = try parseBool(value);
        } else if (std.mem.eql(u8, key, "allow_shell")) {
            cfg.safety.allow_shell = try parseBool(value);
        } else if (std.mem.eql(u8, key, "allow_network")) {
            cfg.safety.allow_network = try parseBool(value);
        } else if (std.mem.eql(u8, key, "rollback_log_path")) {
            cfg.rollback_log_path = try a.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "calibration_path")) {
            cfg.calibration_path = try a.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "memory_budget_mb") or std.mem.eql(u8, key, "vram_budget_mb")) {
            // vram_budget_mb is the pre-0.1 name; it now caps usable memory.
            cfg.memory_budget_mb = try std.fmt.parseUnsigned(u32, value, 10);
        } else if (std.mem.eql(u8, key, "memory_headroom_mb")) {
            cfg.memory_headroom_mb = try std.fmt.parseUnsigned(u32, value, 10);
        } else if (std.mem.eql(u8, key, "desired_ctx")) {
            cfg.desired_ctx = try std.fmt.parseUnsigned(u32, value, 10);
        } else if (std.mem.eql(u8, key, "min_ctx")) {
            cfg.min_ctx = try std.fmt.parseUnsigned(u32, value, 10);
        } else if (std.mem.eql(u8, key, "llm_timeout_ms")) {
            cfg.llm_timeout_ms = try std.fmt.parseUnsigned(u64, value, 10);
        } else if (std.mem.eql(u8, key, "llm_cmd")) {
            cfg.llm_cmd = try a.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "cloud_endpoint")) {
            cfg.cloud_endpoint = try a.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "model")) {
            try models.append(a, try parseModel(a, value));
        } else if (std.mem.eql(u8, key, "tool_allowlist")) {
            cfg.tool_allowlist = try parseList(a, value);
        }
    }

    cfg.models = try models.toOwnedSlice(a);
    if (cfg.timeout.soft_ms > cfg.timeout.hard_ms) cfg.timeout.soft_ms = cfg.timeout.hard_ms;
    if (cfg.min_ctx > cfg.desired_ctx) cfg.min_ctx = cfg.desired_ctx;
    return cfg;
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !RuntimeConfig {
    const data = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => return default(),
        else => return err,
    };
    defer allocator.free(data);
    return parse(allocator, data);
}

pub fn deinit(allocator: std.mem.Allocator, cfg: *RuntimeConfig) void {
    _ = allocator;
    if (cfg.arena) |*arena| arena.deinit();
    cfg.* = default();
}

test "parses models, allowlist and legacy vram key" {
    const a = std.testing.allocator;
    var cfg = try parse(a,
        \\# comment
        \\vram_budget_mb=1500
        \\model=big,models/big.gguf,3
        \\model=small, models/small.gguf ,1
        \\tool_allowlist=ls, echo
        \\desired_ctx=256
        \\min_ctx=512
    );
    defer deinit(a, &cfg);
    try std.testing.expectEqual(@as(u32, 1500), cfg.memory_budget_mb);
    try std.testing.expectEqual(@as(usize, 2), cfg.models.len);
    try std.testing.expectEqualStrings("models/small.gguf", cfg.models[1].path);
    try std.testing.expectEqual(@as(u8, 3), cfg.models[0].quality);
    try std.testing.expectEqual(@as(usize, 2), cfg.tool_allowlist.len);
    try std.testing.expectEqual(@as(u32, 256), cfg.min_ctx);
}

test "default config file round-trips" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const old = try std.process.getCwd(&cwd_buf);
    try tmp.dir.setAsCwd();
    defer {
        var d = std.fs.openDirAbsolute(old, .{}) catch unreachable;
        d.setAsCwd() catch {};
        d.close();
    }
    try writeDefaultConfig("x.conf");
    var cfg = try load(a, "x.conf");
    defer deinit(a, &cfg);
    try std.testing.expect(cfg.safety.offline_only);
    try std.testing.expectEqual(@as(usize, 0), cfg.models.len);
    try std.testing.expectEqual(@as(usize, 13), cfg.tool_allowlist.len);
}

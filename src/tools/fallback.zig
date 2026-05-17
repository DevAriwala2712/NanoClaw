const std = @import("std");

pub const ToolError = error{
    ToolNotFound,
    ToolFailed,
    AllFallbacksExhausted,
};

pub const ToolSpec = struct {
    name: []const u8,
    args: []const []const u8,
};

pub const FallbackChain = struct {
    tool: ToolSpec,
    alternatives: []const ToolSpec,
};

pub const ToolRouter = struct {
    allocator: std.mem.Allocator,
    aliases: std.StringHashMapUnmanaged([]const u8),

    pub fn init(allocator: std.mem.Allocator) ToolRouter {
        return .{
            .allocator = allocator,
            .aliases = .{},
        };
    }

    pub fn deinit(self: *ToolRouter) void {
        var iter = self.aliases.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.aliases.deinit(self.allocator);
    }

    pub fn registerAlias(self: *ToolRouter, alias: []const u8, canonical: []const u8) !void {
        const k = try self.allocator.dupe(u8, alias);
        const v = try self.allocator.dupe(u8, canonical);
        try self.aliases.putNoClobber(self.allocator, k, v);
    }

    pub fn resolve(self: *ToolRouter, name: []const u8) []const u8 {
        return self.aliases.get(name) orelse name;
    }

    pub fn aliasCount(self: *ToolRouter) usize {
        return self.aliases.count();
    }
};

pub const AutoCorrector = struct {
    allocator: std.mem.Allocator,
    chains: std.ArrayListUnmanaged(FallbackChain),
    router: ToolRouter,
    corrections_made: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) !AutoCorrector {
        var corrector = AutoCorrector{
            .allocator = allocator,
            .chains = .{
                .items = &.{},
                .capacity = 0,
            },
            .router = ToolRouter.init(allocator),
        };
        try corrector.setupDefaultChains();
        return corrector;
    }

    pub fn deinit(self: *AutoCorrector) void {
        self.router.deinit();
        self.chains.deinit(self.allocator);
    }

    fn setupDefaultChains(self: *AutoCorrector) !void {
        const aliases = [_][2][]const u8{
            .{ "curl", "curl" },
            .{ "wget", "wget" },
            .{ "http", "curl" },
            .{ "fetch", "curl" },
            .{ "python3", "python3" },
            .{ "python", "python3" },
            .{ "ls", "ls" },
            .{ "dir", "ls" },
            .{ "echo", "echo" },
            .{ "print", "echo" },
        };

        for (aliases) |pair| {
            try self.router.registerAlias(pair[0], pair[1]);
        }

        const search_chain = FallbackChain{
            .tool = .{ .name = "cdp-search", .args = &.{} },
            .alternatives = &.{
                .{ .name = "duckduckgo", .args = &.{} },
                .{ .name = "bing", .args = &.{} },
            },
        };
        try self.chains.append(self.allocator, search_chain);
    }

    pub fn normalize(self: *AutoCorrector, name: []const u8) []const u8 {
        const resolved = self.router.resolve(name);
        if (!std.mem.eql(u8, resolved, name)) {
            self.corrections_made += 1;
            std.debug.print("[autocorrect] '{s}' -> '{s}'\n", .{ name, resolved });
        }
        return resolved;
    }

    pub fn getFallbacks(self: *AutoCorrector, tool_name: []const u8) ?[]const ToolSpec {
        for (self.chains.items) |chain| {
            if (std.mem.eql(u8, chain.tool.name, tool_name)) {
                return chain.alternatives;
            }
        }
        return null;
    }

    pub fn tryExecute(self: *AutoCorrector, tool_name: []const u8, _: []const []const u8) ![]const u8 {
        const resolved = self.normalize(tool_name);

        for (self.chains.items) |chain| {
            if (std.mem.eql(u8, chain.tool.name, resolved)) {
                std.debug.print("[autocorrect] trying primary: {s}\n", .{resolved});
                const primary = chain.tool;
                const result = self.tryRun(primary.name, primary.args);
                if (result) |output| return output;

                for (chain.alternatives, 0..) |alt, i| {
                    std.debug.print("[autocorrect] fallback[{}]: trying {s}\n", .{ i, alt.name });
                    const alt_result = self.tryRun(alt.name, alt.args);
                    if (alt_result) |output| return output;
                }

                return error.AllFallbacksExhausted;
            }
        }

        std.debug.print("[autocorrect] no fallback chain for '{s}', using directly\n", .{resolved});
        return resolved;
    }

    fn tryRun(_: *AutoCorrector, _: []const u8, _: []const []const u8) ?[]const u8 {
        return null;
    }

    pub fn correctionCount(self: *AutoCorrector) u32 {
        return self.corrections_made;
    }
};

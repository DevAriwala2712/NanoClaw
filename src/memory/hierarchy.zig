const std = @import("std");

pub const MemoryTier = enum {
    session,
    daily_summary,
    knowledge,
};

pub const MemoryEntry = struct {
    tier: MemoryTier,
    timestamp: i64,
    key: []const u8,
    value: []const u8,
    processed: bool = false,
};

pub const SearchResult = struct {
    key: []const u8,
    value: []const u8,
    tier: MemoryTier,
};

pub const HierarchicalMemory = struct {
    allocator: std.mem.Allocator,
    session: std.ArrayListUnmanaged(MemoryEntry),
    summaries: std.ArrayListUnmanaged([]const u8),
    knowledge_keys: std.ArrayListUnmanaged([]const u8),
    knowledge_values: std.ArrayListUnmanaged([]const u8),
    last_consolidation: i64 = 0,

    pub fn init(allocator: std.mem.Allocator) HierarchicalMemory {
        return .{
            .allocator = allocator,
            .session = .{},
            .summaries = .{},
            .knowledge_keys = .{},
            .knowledge_values = .{},
        };
    }

    pub fn deinit(self: *HierarchicalMemory) void {
        for (self.session.items) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        self.session.deinit(self.allocator);

        for (self.summaries.items) |summary| {
            self.allocator.free(summary);
        }
        self.summaries.deinit(self.allocator);

        for (self.knowledge_keys.items) |key| {
            self.allocator.free(key);
        }
        self.knowledge_keys.deinit(self.allocator);

        for (self.knowledge_values.items) |value| {
            self.allocator.free(value);
        }
        self.knowledge_values.deinit(self.allocator);
    }

    pub fn put(self: *HierarchicalMemory, key: []const u8, value: []const u8) !void {
        const entry = MemoryEntry{
            .tier = .session,
            .timestamp = std.time.timestamp(),
            .key = try self.allocator.dupe(u8, key),
            .value = try self.allocator.dupe(u8, value),
        };
        try self.session.append(self.allocator, entry);
    }

    pub fn get(self: *HierarchicalMemory, key: []const u8) ?[]const u8 {
        for (self.session.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                return entry.value;
            }
        }
        return null;
    }

    pub fn search(self: *HierarchicalMemory, query: []const u8, max_results: usize) ![]SearchResult {
        var results: std.ArrayListUnmanaged(SearchResult) = .{};
        errdefer results.deinit(self.allocator);

        for (self.session.items) |entry| {
            if (results.items.len >= max_results) break;
            if (std.mem.indexOf(u8, entry.value, query) != null or
                std.mem.indexOf(u8, entry.key, query) != null)
            {
                try results.append(self.allocator, .{
                    .key = entry.key,
                    .value = entry.value,
                    .tier = entry.tier,
                });
            }
        }

        for (self.summaries.items) |summary| {
            if (results.items.len >= max_results) break;
            if (std.mem.indexOf(u8, summary, query) != null) {
                try results.append(self.allocator, .{
                    .key = "summary",
                    .value = summary,
                    .tier = .daily_summary,
                });
            }
        }

        for (self.knowledge_keys.items, self.knowledge_values.items) |key, value| {
            if (results.items.len >= max_results) break;
            if (std.mem.indexOf(u8, value, query) != null or
                std.mem.indexOf(u8, key, query) != null)
            {
                try results.append(self.allocator, .{
                    .key = key,
                    .value = value,
                    .tier = .knowledge,
                });
            }
        }

        return try results.toOwnedSlice(self.allocator);
    }

    pub fn consolidate(self: *HierarchicalMemory) !void {
        if (self.session.items.len == 0) return;

        const now = std.time.timestamp();
        const elapsed = now - self.last_consolidation;
        if (self.last_consolidation != 0 and elapsed < 3600) return;

        std.debug.print("[memory] consolidating {} session entries\n", .{self.session.items.len});

        var buffer: std.ArrayListUnmanaged(u8) = .{};
        defer buffer.deinit(self.allocator);

        for (self.session.items) |entry| {
            if (!entry.processed) {
                try buffer.appendSlice(self.allocator, entry.key);
                try buffer.append(self.allocator, ':');
                try buffer.appendSlice(self.allocator, entry.value);
                try buffer.append(self.allocator, '\n');
            }
        }

        if (buffer.items.len > 0) {
            const summary = try self.allocator.dupe(u8, buffer.items);
            try self.summaries.append(self.allocator, summary);

            for (self.session.items) |*entry| {
                entry.processed = true;
            }

            self.last_consolidation = now;
            std.debug.print("[memory] consolidation complete: {} summaries, {} knowledge entries\n", .{
                self.summaries.items.len,
                self.knowledge_keys.items.len,
            });
        }
    }

    pub fn refineToKnowledge(self: *HierarchicalMemory, key: []const u8, value: []const u8) !void {
        const k = try self.allocator.dupe(u8, key);
        const v = try self.allocator.dupe(u8, value);
        try self.knowledge_keys.append(self.allocator, k);
        try self.knowledge_values.append(self.allocator, v);
        std.debug.print("[memory] refined to knowledge: {s}\n", .{key});
    }

    pub fn jitLoad(self: *HierarchicalMemory, allocator: std.mem.Allocator, context_limit: usize) ![]const u8 {
        var buffer: std.ArrayListUnmanaged(u8) = .{};
        errdefer buffer.deinit(allocator);

        var remaining: usize = context_limit;

        for (self.knowledge_keys.items, self.knowledge_values.items) |key, value| {
            const line_len = key.len + value.len + 4;
            if (line_len > remaining) break;
            try buffer.appendSlice(allocator, key);
            try buffer.append(allocator, ':');
            try buffer.appendSlice(allocator, value);
            try buffer.append(allocator, '\n');
            remaining -= line_len;
        }

        if (buffer.items.len == 0) {
            return allocator.dupe(u8, "");
        }

        return buffer.toOwnedSlice(allocator);
    }

    pub fn size(self: *HierarchicalMemory) usize {
        return self.session.items.len + self.summaries.items.len + self.knowledge_keys.items.len;
    }

    pub fn sessionCount(self: *HierarchicalMemory) usize {
        return self.session.items.len;
    }

    pub fn summaryCount(self: *HierarchicalMemory) usize {
        return self.summaries.items.len;
    }

    pub fn knowledgeCount(self: *HierarchicalMemory) usize {
        return self.knowledge_keys.items.len;
    }
};

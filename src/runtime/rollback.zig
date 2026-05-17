const std = @import("std");

pub const Checkpoint = struct {
    timestamp: i64,
    vram_used_mb: u32,
    memory_entries: usize,
    skills_registered: usize,
};

pub const Journal = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged([]const u8),
    checkpoints: std.ArrayListUnmanaged(Checkpoint),

    pub fn init(allocator: std.mem.Allocator) Journal {
        return .{
            .allocator = allocator,
            .entries = .{
                .items = &.{},
                .capacity = 0,
            },
            .checkpoints = .{
                .items = &.{},
                .capacity = 0,
            },
        };
    }

    pub fn deinit(self: *Journal) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry);
        }
        self.entries.deinit(self.allocator);
        self.checkpoints.deinit(self.allocator);
    }

    pub fn record(self: *Journal, line: []const u8) !void {
        const owned = try self.allocator.dupe(u8, line);
        try self.entries.append(self.allocator, owned);
    }

    pub fn recordSnapshot(self: *Journal, phase: []const u8, file_path: []const u8) !void {
        const line = try std.fmt.allocPrint(self.allocator, "snapshot:{s}:{s}", .{ phase, file_path });
        defer self.allocator.free(line);
        try self.record(line);
    }

    pub fn recordCheckpoint(self: *Journal, vram_mb: u32, memory_entries: usize, skills: usize) !void {
        const checkpoint = Checkpoint{
            .timestamp = std.time.timestamp(),
            .vram_used_mb = vram_mb,
            .memory_entries = memory_entries,
            .skills_registered = skills,
        };
        try self.checkpoints.append(self.allocator, checkpoint);

        const line = try std.fmt.allocPrint(
            self.allocator,
            "checkpoint:vram={}mb,mem={},skills={},ts={}",
            .{ vram_mb, memory_entries, skills, checkpoint.timestamp },
        );
        defer self.allocator.free(line);
        try self.record(line);
    }

    pub fn beginTxn(self: *Journal, label: []const u8) !void {
        const line = try std.fmt.allocPrint(self.allocator, "txn:begin:{s}", .{label});
        defer self.allocator.free(line);
        try self.record(line);
    }

    pub fn commitTxn(self: *Journal, label: []const u8) !void {
        const line = try std.fmt.allocPrint(self.allocator, "txn:commit:{s}", .{label});
        defer self.allocator.free(line);
        try self.record(line);
    }

    pub fn rollbackTxn(self: *Journal, label: []const u8) !void {
        const line = try std.fmt.allocPrint(self.allocator, "txn:rollback:{s}", .{label});
        defer self.allocator.free(line);
        try self.record(line);
    }

    pub fn flushToFile(self: *Journal, path: []const u8) !void {
        try std.fs.cwd().makePath("state");

        var buffer: std.ArrayListUnmanaged(u8) = .{
            .items = &.{},
            .capacity = 0,
        };
        defer buffer.deinit(self.allocator);

        for (self.entries.items) |entry| {
            try buffer.appendSlice(self.allocator, entry);
            try buffer.append(self.allocator, '\n');
        }

        try std.fs.cwd().writeFile(.{
            .sub_path = path,
            .data = buffer.items,
            .flags = .{ .truncate = true },
        });
    }
};

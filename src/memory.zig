const std = @import("std");

pub const MemoryRecord = struct {
    timestamp: i64,
    key: []const u8,
    value: []const u8,
};

pub const ContextOS = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ContextOS {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ContextOS) void {
        _ = self;
    }

    pub fn buildJitWindow(self: *ContextOS, intent: []const u8, token_budget: usize) ![]const u8 {
        _ = self;
        _ = intent;
        _ = token_budget;
        return error.NotImplemented;
    }
};

pub const MemoryManager = struct {
    allocator: std.mem.Allocator,
    storage_path: []const u8,
    shutdown_started: std.atomic.Value(bool),
    sync_in_flight: std.atomic.Value(u32),

    pub fn init(allocator: std.mem.Allocator, storage_path: []const u8) !MemoryManager {
        return .{
            .allocator = allocator,
            .storage_path = try allocator.dupe(u8, storage_path),
            .shutdown_started = std.atomic.Value(bool).init(false),
            .sync_in_flight = std.atomic.Value(u32).init(0),
        };
    }

    pub fn deinit(self: *MemoryManager) void {
        self.allocator.free(self.storage_path);
        self.* = undefined;
    }

    fn beginSync(self: *MemoryManager) !void {
        if (self.shutdown_started.load(.acquire)) return error.ShutdownInProgress;

        _ = self.sync_in_flight.fetchAdd(1, .acq_rel);
        errdefer _ = self.sync_in_flight.fetchSub(1, .acq_rel);

        if (self.shutdown_started.load(.acquire)) {
            return error.ShutdownInProgress;
        }
    }

    fn endSync(self: *MemoryManager) void {
        _ = self.sync_in_flight.fetchSub(1, .acq_rel);
    }

    pub fn writeRecord(self: *MemoryManager, key: []const u8, value: []const u8) !void {
        if (key.len == 0) return error.InvalidRecordKey;
        if (value.len > 8 * 1024) return error.RecordTooLarge;

        try self.beginSync();
        defer self.endSync();

        const parent_dir = std.fs.path.dirname(self.storage_path);
        if (parent_dir) |dir| {
            try std.fs.cwd().makePath(dir);
        }

        var file = try std.fs.cwd().openFile(self.storage_path, .{ .mode = .read_write });
        defer file.close();
        try file.seekFromEnd(0);

        const ts = std.time.timestamp();
        const line = try std.fmt.allocPrint(self.allocator, "{d}|{s}|{s}\n", .{ ts, key, value });
        defer self.allocator.free(line);
        try file.writeAll(line);
    }

    pub fn writeRecordCreate(self: *MemoryManager, key: []const u8, value: []const u8) !void {
        if (key.len == 0) return error.InvalidRecordKey;
        if (value.len > 8 * 1024) return error.RecordTooLarge;

        try self.beginSync();
        defer self.endSync();

        const parent_dir = std.fs.path.dirname(self.storage_path);
        if (parent_dir) |dir| {
            try std.fs.cwd().makePath(dir);
        }

        var file = std.fs.cwd().openFile(self.storage_path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.fs.cwd().createFile(self.storage_path, .{ .truncate = false, .exclusive = false }),
            else => return err,
        };
        defer file.close();
        try file.seekFromEnd(0);

        const ts = std.time.timestamp();
        const line = try std.fmt.allocPrint(self.allocator, "{d}|{s}|{s}\n", .{ ts, key, value });
        defer self.allocator.free(line);
        try file.writeAll(line);
    }

    pub fn shutdown(self: *MemoryManager) void {
        self.shutdown_started.store(true, .release);
        while (self.sync_in_flight.load(.acquire) != 0) {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }

    pub fn canAcceptWrites(self: *MemoryManager) bool {
        return !self.shutdown_started.load(.acquire);
    }

    pub fn syncInFlight(self: *MemoryManager) u32 {
        return self.sync_in_flight.load(.acquire);
    }
};

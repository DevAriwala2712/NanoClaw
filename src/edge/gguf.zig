const std = @import("std");

/// The subset of GGUF metadata needed to estimate a model's memory cost.
pub const ModelInfo = struct {
    architecture: [32]u8 = [_]u8{0} ** 32,
    architecture_len: usize = 0,
    file_bytes: u64 = 0,
    block_count: u32 = 0,
    embedding_length: u32 = 0,
    head_count: u32 = 0,
    head_count_kv: u32 = 0,
    key_length: u32 = 0,
    value_length: u32 = 0,
    context_length: u32 = 0,

    pub fn arch(self: *const ModelInfo) []const u8 {
        return self.architecture[0..self.architecture_len];
    }

    pub fn headDimK(self: ModelInfo) u32 {
        if (self.key_length != 0) return self.key_length;
        if (self.head_count == 0) return 0;
        return self.embedding_length / self.head_count;
    }

    pub fn headDimV(self: ModelInfo) u32 {
        if (self.value_length != 0) return self.value_length;
        return self.headDimK();
    }

    pub fn kvHeads(self: ModelInfo) u32 {
        return if (self.head_count_kv != 0) self.head_count_kv else self.head_count;
    }

    /// Bytes of KV cache per context token, assuming an f16 cache (llama.cpp default).
    pub fn kvBytesPerToken(self: ModelInfo) u64 {
        const per_layer: u64 = @as(u64, self.kvHeads()) * (@as(u64, self.headDimK()) + self.headDimV()) * 2;
        return per_layer * self.block_count;
    }

    pub fn isComplete(self: ModelInfo) bool {
        return self.block_count != 0 and self.embedding_length != 0 and self.head_count != 0;
    }
};

const ValueType = enum(u32) {
    uint8 = 0,
    int8 = 1,
    uint16 = 2,
    int16 = 3,
    uint32 = 4,
    int32 = 5,
    float32 = 6,
    bool = 7,
    string = 8,
    array = 9,
    uint64 = 10,
    int64 = 11,
    float64 = 12,
    _,
};

const Cursor = struct {
    buf: []const u8,
    pos: usize = 0,

    fn take(self: *Cursor, n: usize) ![]const u8 {
        if (n > self.buf.len - self.pos) return error.MetadataTruncated;
        const out = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return out;
    }

    fn int(self: *Cursor, comptime T: type) !T {
        const bytes = try self.take(@sizeOf(T));
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
    }

    fn string(self: *Cursor) ![]const u8 {
        const len = try self.int(u64);
        return self.take(std.math.cast(usize, len) orelse return error.MetadataTruncated);
    }

    fn scalarSize(t: ValueType) ?usize {
        return switch (t) {
            .uint8, .int8, .bool => 1,
            .uint16, .int16 => 2,
            .uint32, .int32, .float32 => 4,
            .uint64, .int64, .float64 => 8,
            else => null,
        };
    }

    /// Reads an integer-typed value; returns null (after skipping it) for other types.
    fn uintValue(self: *Cursor, t: ValueType) !?u64 {
        switch (t) {
            .uint8 => return try self.int(u8),
            .uint16 => return try self.int(u16),
            .uint32 => return try self.int(u32),
            .uint64 => return try self.int(u64),
            .int32 => {
                const v = try self.int(i32);
                return if (v < 0) null else @intCast(v);
            },
            .int64 => {
                const v = try self.int(i64);
                return if (v < 0) null else @intCast(v);
            },
            .array => {
                // Some architectures store per-layer head counts as arrays; take the max.
                const elem_t: ValueType = @enumFromInt(try self.int(u32));
                const n = try self.int(u64);
                var max: ?u64 = null;
                var i: u64 = 0;
                while (i < n) : (i += 1) {
                    if (try self.uintValue(elem_t)) |v| max = @max(max orelse 0, v);
                }
                return max;
            },
            else => {
                try self.skip(t);
                return null;
            },
        }
    }

    fn skip(self: *Cursor, t: ValueType) !void {
        if (scalarSize(t)) |size| {
            _ = try self.take(size);
            return;
        }
        switch (t) {
            .string => _ = try self.string(),
            .array => {
                const elem_t: ValueType = @enumFromInt(try self.int(u32));
                const n = try self.int(u64);
                if (scalarSize(elem_t)) |size| {
                    const total = std.math.mul(u64, n, size) catch return error.MetadataTruncated;
                    _ = try self.take(std.math.cast(usize, total) orelse return error.MetadataTruncated);
                } else {
                    var i: u64 = 0;
                    while (i < n) : (i += 1) try self.skip(elem_t);
                }
            },
            else => return error.UnknownValueType,
        }
    }
};

fn setField(info: *ModelInfo, key: []const u8, value: u64) void {
    const v: u32 = std.math.cast(u32, value) orelse std.math.maxInt(u32);
    const Suffix = struct { s: []const u8, f: *u32 };
    const suffixes = [_]Suffix{
        .{ .s = ".block_count", .f = &info.block_count },
        .{ .s = ".embedding_length", .f = &info.embedding_length },
        .{ .s = ".attention.head_count", .f = &info.head_count },
        .{ .s = ".attention.head_count_kv", .f = &info.head_count_kv },
        .{ .s = ".attention.key_length", .f = &info.key_length },
        .{ .s = ".attention.value_length", .f = &info.value_length },
        .{ .s = ".context_length", .f = &info.context_length },
    };
    for (suffixes) |entry| {
        if (std.mem.endsWith(u8, key, entry.s)) {
            // Only accept keys under this model's architecture prefix once known.
            if (info.architecture_len != 0 and !std.mem.startsWith(u8, key, info.arch())) return;
            entry.f.* = v;
            return;
        }
    }
}

/// Parses GGUF header metadata from the leading bytes of a model file.
pub fn parseHeader(buf: []const u8) !ModelInfo {
    var c = Cursor{ .buf = buf };
    const magic = try c.take(4);
    if (!std.mem.eql(u8, magic, "GGUF")) return error.NotGguf;
    const version = try c.int(u32);
    if (version < 2) return error.UnsupportedGgufVersion;
    _ = try c.int(u64); // tensor count
    const kv_count = try c.int(u64);

    var info = ModelInfo{};
    var i: u64 = 0;
    while (i < kv_count) : (i += 1) {
        const key = try c.string();
        const t: ValueType = @enumFromInt(try c.int(u32));

        if (std.mem.eql(u8, key, "general.architecture") and t == .string) {
            const name = try c.string();
            const n = @min(name.len, info.architecture.len);
            @memcpy(info.architecture[0..n], name[0..n]);
            info.architecture_len = n;
            continue;
        }

        if (std.mem.startsWith(u8, key, "tokenizer.")) {
            try c.skip(t);
            continue;
        }

        if (try c.uintValue(t)) |v| setField(&info, key, v);
    }
    return info;
}

/// Reads up to `max_header_bytes` from a GGUF file and parses its metadata.
/// Tokenizer vocabularies make headers several MB; 32 MB covers current models.
pub fn readModelInfo(allocator: std.mem.Allocator, path: []const u8) !ModelInfo {
    const max_header_bytes: usize = 32 * 1024 * 1024;
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const size = try file.getEndPos();
    const want: usize = @intCast(@min(size, max_header_bytes));
    const buf = try allocator.alloc(u8, want);
    defer allocator.free(buf);
    const n = try file.preadAll(buf, 0);
    var info = try parseHeader(buf[0..n]);
    info.file_bytes = size;
    return info;
}

/// Test helper: builds a minimal GGUF v3 header in memory.
pub const TestWriter = struct {
    list: std.ArrayListUnmanaged(u8) = .{},
    allocator: std.mem.Allocator,

    pub fn begin(allocator: std.mem.Allocator, kv_count: u64) !TestWriter {
        var w = TestWriter{ .allocator = allocator };
        try w.list.appendSlice(allocator, "GGUF");
        try w.int(u32, 3);
        try w.int(u64, 0);
        try w.int(u64, kv_count);
        return w;
    }

    pub fn deinit(self: *TestWriter) void {
        self.list.deinit(self.allocator);
    }

    fn int(self: *TestWriter, comptime T: type, v: T) !void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        try self.list.appendSlice(self.allocator, &b);
    }

    fn str(self: *TestWriter, s: []const u8) !void {
        try self.int(u64, s.len);
        try self.list.appendSlice(self.allocator, s);
    }

    pub fn kvString(self: *TestWriter, key: []const u8, value: []const u8) !void {
        try self.str(key);
        try self.int(u32, @intFromEnum(ValueType.string));
        try self.str(value);
    }

    pub fn kvU32(self: *TestWriter, key: []const u8, value: u32) !void {
        try self.str(key);
        try self.int(u32, @intFromEnum(ValueType.uint32));
        try self.int(u32, value);
    }

    pub fn kvStringArray(self: *TestWriter, key: []const u8, items: []const []const u8) !void {
        try self.str(key);
        try self.int(u32, @intFromEnum(ValueType.array));
        try self.int(u32, @intFromEnum(ValueType.string));
        try self.int(u64, items.len);
        for (items) |it| try self.str(it);
    }

    pub fn bytes(self: *TestWriter) []const u8 {
        return self.list.items;
    }
};

test "parses llama-style header and skips tokenizer arrays" {
    const a = std.testing.allocator;
    var w = try TestWriter.begin(a, 7);
    defer w.deinit();
    try w.kvString("general.architecture", "llama");
    try w.kvStringArray("tokenizer.ggml.tokens", &.{ "<s>", "</s>", "hello" });
    try w.kvU32("llama.block_count", 24);
    try w.kvU32("llama.embedding_length", 2048);
    try w.kvU32("llama.attention.head_count", 32);
    try w.kvU32("llama.attention.head_count_kv", 8);
    try w.kvU32("llama.context_length", 8192);

    const info = try parseHeader(w.bytes());
    try std.testing.expectEqualStrings("llama", info.arch());
    try std.testing.expectEqual(@as(u32, 24), info.block_count);
    try std.testing.expectEqual(@as(u32, 64), info.headDimK());
    try std.testing.expectEqual(@as(u32, 8), info.kvHeads());
    try std.testing.expectEqual(@as(u32, 8192), info.context_length);
    // 24 layers * 8 kv heads * (64 + 64) dims * 2 bytes = 49152 bytes/token
    try std.testing.expectEqual(@as(u64, 49152), info.kvBytesPerToken());
}

test "rejects non-gguf and truncated input" {
    try std.testing.expectError(error.NotGguf, parseHeader("NOPE0000000000000000000000"));
    try std.testing.expectError(error.MetadataTruncated, parseHeader("GGUF"));
}

test "head_count_kv defaults to head_count when absent" {
    const a = std.testing.allocator;
    var w = try TestWriter.begin(a, 4);
    defer w.deinit();
    try w.kvString("general.architecture", "gpt2");
    try w.kvU32("gpt2.block_count", 12);
    try w.kvU32("gpt2.embedding_length", 768);
    try w.kvU32("gpt2.attention.head_count", 12);
    const info = try parseHeader(w.bytes());
    try std.testing.expectEqual(@as(u32, 12), info.kvHeads());
    try std.testing.expect(info.isComplete());
}

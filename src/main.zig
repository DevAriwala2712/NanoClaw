const std = @import("std");
const App = @import("app.zig").App;
const config = @import("config.zig");

fn printUsage() !void {
    std.debug.print(
        "NanoClaw-Next CLI\n" ++
            "Usage:\n" ++
            "  nanoclaw-next --demo\n" ++
            "  nanoclaw-next init\n" ++
            "  nanoclaw-next run [--prompt \"<command>\"] [--interactive]\n" ++
            "  nanoclaw-next prompt\n" ++
            "  nanoclaw-next status\n" ++
            "  nanoclaw-next selftest\n",
        .{},
    );
}

fn printDemo() !void {
    std.debug.print(
        "=== NanoClaw Lineage Demo ===\n" ++
            "NullClaw: proved tiny static edge binaries can feel instant.\n" ++
            "NanoClaw: pushed autonomy and local execution ergonomics.\n" ++
            "SafeClaw-R: made safety an invariant in execution graphs.\n" ++
            "NanoClaw-Next: unifies all three into one secure, edge-native runtime.\n" ++
            "=============================\n",
        .{},
    );
}

fn parseRunFlags(args: []const []const u8) !struct {
    prompt: ?[]const u8,
    interactive: bool,
} {
    var prompt: ?[]const u8 = null;
    var interactive = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--interactive")) {
            interactive = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--prompt")) {
            if (i + 1 >= args.len) return error.MissingPromptValue;
            prompt = args[i + 1];
            i += 1;
            continue;
        }
        return error.InvalidRunArgument;
    }
    return .{ .prompt = prompt, .interactive = interactive };
}

fn printNanoClawHeader(fancy: bool) !void {
    if (fancy) {
        std.debug.print(
            "\n" ++
                "┌─────────────────────────────┐\n" ++
                "│          NanoClaw           │\n" ++
                "└─────────────────────────────┘\n" ++
                "Type a command for executor dispatch.\n\n",
            .{},
        );
        return;
    }

    std.debug.print("NanoClaw > enter command\n", .{});
}

fn readInteractivePrompt(allocator: std.mem.Allocator, fancy: bool) ![]u8 {
    if (fancy) {
        std.debug.print("nanoclaw> ", .{});
    } else {
        std.debug.print("> ", .{});
    }
    const line = try std.fs.File.stdin().deprecatedReader().readUntilDelimiterOrEofAlloc(allocator, '\n', 4096);
    if (line == null) return error.EmptyPrompt;
    errdefer allocator.free(line.?);

    const trimmed = std.mem.trim(u8, line.?, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyPrompt;
    if (trimmed.ptr == line.?.ptr and trimmed.len == line.?.len) return line.?;

    const out = try allocator.dupe(u8, trimmed);
    allocator.free(line.?);
    return out;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        return;
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "--demo")) {
        try printDemo();
        return;
    }

    if (std.mem.eql(u8, cmd, "init")) {
        try std.fs.cwd().makePath("state");
        try config.writeDefaultConfig("nanoclaw-next.conf");
        std.debug.print("Initialized nanoclaw-next.conf\n", .{});
        return;
    }

    if (std.mem.eql(u8, cmd, "run")) {
        const flags = parseRunFlags(args[2..]) catch {
            try printUsage();
            return;
        };
        const runtime_cfg = try config.load(allocator, "nanoclaw-next.conf");
        var app = try App.init(allocator, runtime_cfg);
        defer app.deinit();

        var owned_prompt: ?[]u8 = null;
        defer if (owned_prompt) |p| allocator.free(p);

        const prompt_text: ?[]const u8 = blk: {
            if (flags.prompt) |p| break :blk p;
            if (flags.interactive) {
                const fancy = std.fs.File.stdin().isTty() and std.fs.File.stdout().isTty();
                try printNanoClawHeader(fancy);
                owned_prompt = try readInteractivePrompt(allocator, fancy);
                break :blk owned_prompt.?;
            }
            break :blk null;
        };

        try app.runWithPrompt(prompt_text);
        return;
    }

    if (std.mem.eql(u8, cmd, "prompt")) {
        const runtime_cfg = try config.load(allocator, "nanoclaw-next.conf");
        var app = try App.init(allocator, runtime_cfg);
        defer app.deinit();

        const fancy = std.fs.File.stdin().isTty() and std.fs.File.stdout().isTty();
        try printNanoClawHeader(fancy);
        const prompt_text = try readInteractivePrompt(allocator, fancy);
        defer allocator.free(prompt_text);

        try app.runWithPrompt(prompt_text);
        return;
    }

    if (std.mem.eql(u8, cmd, "status")) {
        const runtime_cfg = try config.load(allocator, "nanoclaw-next.conf");
        var app = try App.init(allocator, runtime_cfg);
        defer app.deinit();
        try app.printStatus();
        return;
    }

    if (std.mem.eql(u8, cmd, "selftest")) {
        const runtime_cfg = try config.load(allocator, "nanoclaw-next.conf");
        var app = try App.init(allocator, runtime_cfg);
        defer app.deinit();
        try app.selftest();
        return;
    }

    try printUsage();
}

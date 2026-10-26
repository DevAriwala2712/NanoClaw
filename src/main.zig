const std = @import("std");
const app_mod = @import("app.zig");
const App = app_mod.App;
const config = @import("config.zig");
const scheduler = @import("edge/scheduler.zig");

const config_path = "nanoclaw-next.conf";

fn printUsage() void {
    std.debug.print(
        "NanoClaw-Next: adaptive local-LLM scheduler for memory-constrained devices\n" ++
            "Usage:\n" ++
            "  nanoclaw-next init                      write nanoclaw-next.conf with safe defaults\n" ++
            "  nanoclaw-next probe                     device memory, model costs, default decision\n" ++
            "  nanoclaw-next plan [request flags]      dry-run the scheduler (no model is run)\n" ++
            "  nanoclaw-next calibrate [--prompt TEXT] [--tokens N]  measure every model's RSS and speed\n" ++
            "  nanoclaw-next bench --prompt TEXT [--runs N] [--out FILE] [request flags]\n" ++
            "  nanoclaw-next run [--prompt TEXT | --interactive]\n" ++
            "  nanoclaw-next prompt                    interactive run\n" ++
            "  nanoclaw-next selftest                  model-free checks for this device\n" ++
            "\n" ++
            "Request flags:\n" ++
            "  --ctx N --min-ctx N --tokens N --deadline-ms N --sensitive\n" ++
            "  --prefer quality|speed --available-mb N (simulate free memory)\n",
        .{},
    );
}

fn printDemo() void {
    std.debug.print(
        "=== NanoClaw Lineage ===\n" ++
            "NullClaw proved tiny static edge binaries can feel instant.\n" ++
            "NanoClaw-Next focuses on the part that actually runs out of memory:\n" ++
            "choosing which local model and context fit this device right now.\n" ++
            "========================\n",
        .{},
    );
}

const Flags = struct {
    req: scheduler.Request,
    available_mb: ?u64 = null,
    prompt: ?[]const u8 = null,
    interactive: bool = false,
    runs: u32 = 5,
    out: []const u8 = "state/bench.csv",
};

fn parseFlags(args: []const []const u8, base: scheduler.Request) !Flags {
    var f = Flags{ .req = base };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--interactive")) {
            f.interactive = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--sensitive")) {
            f.req.sensitive = true;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingFlagValue;
        const v = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, arg, "--prompt")) {
            f.prompt = v;
        } else if (std.mem.eql(u8, arg, "--ctx")) {
            f.req.desired_ctx = try std.fmt.parseUnsigned(u32, v, 10);
        } else if (std.mem.eql(u8, arg, "--min-ctx")) {
            f.req.min_ctx = try std.fmt.parseUnsigned(u32, v, 10);
        } else if (std.mem.eql(u8, arg, "--tokens")) {
            f.req.max_new_tokens = try std.fmt.parseUnsigned(u32, v, 10);
        } else if (std.mem.eql(u8, arg, "--deadline-ms")) {
            f.req.deadline_ms = try std.fmt.parseUnsigned(u64, v, 10);
        } else if (std.mem.eql(u8, arg, "--available-mb")) {
            f.available_mb = try std.fmt.parseUnsigned(u64, v, 10);
        } else if (std.mem.eql(u8, arg, "--runs")) {
            f.runs = try std.fmt.parseUnsigned(u32, v, 10);
        } else if (std.mem.eql(u8, arg, "--out")) {
            f.out = v;
        } else if (std.mem.eql(u8, arg, "--prefer")) {
            f.req.prefer = std.meta.stringToEnum(scheduler.Preference, v) orelse return error.InvalidPreference;
        } else {
            return error.UnknownFlag;
        }
    }
    if (f.req.min_ctx > f.req.desired_ctx) f.req.min_ctx = f.req.desired_ctx;
    return f;
}

fn readInteractivePrompt(allocator: std.mem.Allocator) ![]u8 {
    std.debug.print("nanoclaw> ", .{});
    const line = try std.fs.File.stdin().deprecatedReader().readUntilDelimiterOrEofAlloc(allocator, '\n', 4096);
    const raw = line orelse return error.EmptyPrompt;
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyPrompt;
    return allocator.dupe(u8, trimmed);
}

pub fn main() void {
    realMain() catch |err| {
        std.debug.print("error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn realMain() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }
    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "--demo")) {
        printDemo();
        return;
    }
    if (std.mem.eql(u8, cmd, "init")) {
        try std.fs.cwd().makePath("state");
        try config.writeDefaultConfig(config_path);
        std.debug.print("Initialized {s}. Add model= lines, then run `nanoclaw-next probe`.\n", .{config_path});
        return;
    }

    const known = [_][]const u8{ "run", "prompt", "status", "probe", "plan", "bench", "calibrate", "selftest" };
    var is_known = false;
    for (known) |k| is_known = is_known or std.mem.eql(u8, cmd, k);
    if (!is_known) {
        printUsage();
        return;
    }

    const app = try App.create(allocator, try config.load(allocator, config_path));
    defer app.destroy();

    const flags = parseFlags(args[2..], app.engine.defaultRequest()) catch |err| {
        std.debug.print("error: {}\n\n", .{err});
        printUsage();
        return;
    };

    if (std.mem.eql(u8, cmd, "probe") or std.mem.eql(u8, cmd, "status")) {
        try app.probe();
    } else if (std.mem.eql(u8, cmd, "plan")) {
        try app.planCmd(flags.req, flags.available_mb);
    } else if (std.mem.eql(u8, cmd, "bench")) {
        const prompt = flags.prompt orelse {
            std.debug.print("bench needs --prompt TEXT\n", .{});
            return;
        };
        try app.bench(.{ .prompt = prompt, .runs = flags.runs, .out_path = flags.out, .available_mb = flags.available_mb }, flags.req);
    } else if (std.mem.eql(u8, cmd, "calibrate")) {
        try app.calibrate(flags.prompt orelse "List three uses of a Raspberry Pi.", @min(flags.req.max_new_tokens, 64));
    } else if (std.mem.eql(u8, cmd, "selftest")) {
        try app.selftest();
    } else {
        var owned: ?[]u8 = null;
        defer if (owned) |p| allocator.free(p);
        if (flags.prompt == null and (flags.interactive or std.mem.eql(u8, cmd, "prompt"))) {
            owned = try readInteractivePrompt(allocator);
        }
        try app.runWithPrompt(flags.prompt orelse owned);
    }
}

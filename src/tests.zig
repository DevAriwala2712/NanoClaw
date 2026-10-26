// Test root: `zig build test`, or `zig test src/tests.zig`.
test {
    _ = @import("config.zig");
    _ = @import("edge/sysmem.zig");
    _ = @import("edge/gguf.zig");
    _ = @import("edge/estimate.zig");
    _ = @import("edge/scheduler.zig");
    _ = @import("edge/proc.zig");
    _ = @import("edge/engine.zig");
    _ = @import("runtime/sandbox.zig");
    _ = @import("app.zig");
}

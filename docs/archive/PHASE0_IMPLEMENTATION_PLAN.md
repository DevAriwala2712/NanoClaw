# NanoClaw-Next Phase 0 Implementation Plan

## Status

Phase 0 baseline implementation is complete in this repository.

## Stack Choice (Final)

**Language:** Zig 0.13.x

**Why Zig over Rust for Phase 0:**
- Produces tiny static binaries with direct control over allocator/runtime behavior.
- No mandatory runtime or package manager dependency chain.
- C interop is first-class for integrating `llama.cpp` C API in Phase 1.
- Predictable cross-compilation for Raspberry Pi 5 (`aarch64-linux-musl`) and mobile Linux targets.
- Aligns with NullClaw-style minimal binary DNA and cold-start goals.

## Phase 0 Architecture Decisions

1. **Single static binary path**
- Build output name: `nanoclaw-next`
- Target defaults to host today; cross-target profiles are next.
- Runtime starts from one entrypoint with strict command modes.

2. **Core execution environment**
- CLI commands: `init`, `run`, `--demo`
- `init` creates edge-safe defaults (`offline_only=true`, shell/network denied)
- `run` executes one deterministic runtime cycle

3. **Isolation + timeout + rollback baseline**
- Isolation surface introduced as `Sandbox` abstraction.
- Time budget is explicit (`soft_ms`, `hard_ms`) and checked before dispatch.
- Rollback journal records execution milestones and flushes to disk for recovery.

4. **Inference runtime seam for Phase 1**
- Planner/executor role API already exists.
- Runtime demonstrates role load/unload sequence.
- Ready to bind real quantized model loaders in place.

## File Structure (Current + Planned)

```
NanoClaw/
  build.zig
  build.zig.zon
  README.md
  PHASE0_IMPLEMENTATION_PLAN.md
  NanoClaw-Next_ Architecting Optimized AI Agents for the Edge.md
  src/
    main.zig
    app.zig
    config.zig
    inference/
      runtime.zig
    runtime/
      sandbox.zig
      timeout.zig
      rollback.zig
```

## First 3 Files to Create (Done)

1. `build.zig`
2. `build.zig.zon`
3. `src/main.zig`

## Immediate Next Deliverables (to finish full Phase 0)

1. Harden Linux seccomp profile enforcement behind existing isolation seam.
2. Add capability-based skill runtime (WASM preferred) with strict syscall envelope.
3. Expand rollback from metadata snapshots to richer state snapshots.
4. Extend selftest with latency and cross-target checks.
5. Keep release script maintained for static builds:
- Pi 5 target: `aarch64-linux-musl`
- x86_64 target: `x86_64-linux-musl`

## Success Criteria for Phase 0 Exit

- Single binary runs with no runtime dependency installs.
- `--demo` works from cold start in <100ms on dev hardware.
- `run` path enforces timeout and writes rollback journal every cycle.
- Safety defaults are deny-by-default and local/offline-only.

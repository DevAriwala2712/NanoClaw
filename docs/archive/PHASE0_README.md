# NanoClaw-Next Phase 0

Phase 0 turns NanoClaw-Next from an architecture sketch into an operable, security-first edge runtime baseline.

## Dependencies

1. Required for build: Zig 0.15.x
2. Required at runtime: none
3. Optional for release checksums: `shasum` or `sha256sum`

## One-Command Setup

```bash
./scripts/setup.sh
```

This checks Zig version, performs a compile check, and initializes default config/state.

## What Is Better Than Normal Claw

1. Single static binary path with no Node/Python runtime dependency chain.
2. Deny-by-default safety posture: offline mode enabled, shell escalation disabled, network-oriented tool calls denied by policy.
3. Structured timeout budgets with soft/hard deadlines for each tool dispatch.
4. Transaction-oriented rollback journal with begin/commit/rollback markers and snapshot metadata.
5. Role-seamed inference runtime so planner/executor swap is already wired for Phase 1 model orchestration.
6. Built-in lineage demo mode for immediate product storytelling (`--demo`).

## Phase 0 Nuances

1. Linux isolation is intentionally a compile-gated seam in Phase 0. The hook exists, but full seccomp policy hardening lands in the next hardening increment.
2. Policy checks are conservative: commands associated with network access are denied when offline mode is active.
3. Rollback in Phase 0 is metadata-first: journal + snapshot markers, not full filesystem diffing.
4. Config values are loaded from `nanoclaw-next.conf` when present; defaults remain secure if file is absent.

## Commands

1. Initialize config and state directory

```bash
zig build run -- init
```

2. Run lineage demo

```bash
zig build run -- --demo
```

3. Run one deterministic runtime cycle

```bash
zig build run -- run
```

4. Run deterministic Phase 0 self-test suite

```bash
zig build run -- selftest
```

## Release Builds

1. x86_64 Linux static release

```bash
zig build release-x86 -Doptimize=ReleaseSmall
```

2. Raspberry Pi 5 target (aarch64 Linux musl)

```bash
zig build release-pi -Doptimize=ReleaseSmall
```

3. Build both artifacts + checksums

```bash
./scripts/release-phase0.sh
```

## Acceptance Checklist

1. `init` produces config with secure defaults.
2. `run` executes a command through sandbox policy + timeout path.
3. `selftest` validates safety defaults, policy denial, sandbox execution, and rollback journal writes.
4. Release commands emit both target binaries.

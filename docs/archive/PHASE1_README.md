# NanoClaw-Next Phase 1

Phase 1 implements real quantized model orchestration with VRAM-aware context budgeting, edge-cloud routing, hierarchical memory, skill runtime, and auto-correction.

## Dependencies

1. Required for build: Zig 0.15.x
2. Required at runtime: none
3. Optional for release checksums: `shasum` or `sha256sum`

## What Is Different from Phase 0

| Feature | Phase 0 | Phase 1 |
|---------|---------|---------|
| Model orchestration | Demo mode | Real VRAM-aware loading/unloading |
| Edge-cloud routing | None | Sensitivity-based routing |
| Memory | Basic journal | Hierarchical (session→summary→knowledge) |
| Skills | Compile-gated seam | Capability-based skill runtime |
| Auto-correction | None | Tool alias + fallback chains |
| Seccomp | Documentation only | BPF filter stubs |

## Run Phase 1

```bash
zig build run -- run
```

Output shows:
1. Planner model load (1100MB VRAM)
2. Role swap (unload planner, load executor)
3. Executor model load (450MB VRAM)
4. Tool execution through sandbox

```bash
zig build run -- selftest
```

### Interactive task dispatch (CLI)

Run a one-off task directly:

```bash
zig build run -- run --prompt "ls -la"
```

Open a branded interactive prompt:

```bash
zig build run -- prompt
```

Or force interactive mode through `run`:

```bash
zig build run -- run --interactive
```

Check runtime LLM mode/status:

```bash
zig build run -- status
```

## Configuration

Edit `nanoclaw-next.conf` to tune:

- `vram_budget_mb` - Total VRAM budget (default: 2048)
- `timeout_hard_ms` - Hard timeout
- `timeout_soft_ms` - Soft timeout

## New Modules

- `src/inference/runtime.zig` - Model loading, VRAM tracking, role swap
- `src/memory/hierarchy.zig` - Session→summary→knowledge consolidation
- `src/skills/runtime.zig` - Capability-based skill enforcement
- `src/tools/fallback.zig` - Tool aliasing + fallback chains

## Local LLM bridge (subprocess mode)

Phase 1 includes a subprocess bridge so a local LLM CLI (for example a llama.cpp frontend) can be used without C interop. If no local model command is configured, runtime inference falls back to the built-in demo stub.

To enable the bridge, set `LOCAL_LLM_CMD` to a command that accepts prompt input on stdin and prints model output to stdout:

```bash
export LOCAL_LLM_CMD="/usr/local/bin/llama --model /path/to/ggml-model.bin"
export LOCAL_LLM_TIMEOUT_MS=20000
zig build run -- run
```

Notes:
- `LOCAL_LLM_TIMEOUT_MS` is optional (default: `20000` ms).
- Non-zero exit or timeout bubbles up as an inference error (rollback path can handle it).
- `status` shows whether inference is currently using `local-subprocess` or fallback `stub` mode.

# Plan: from "<2 MB agent OS" to an adaptive edge-inference scheduler

_Derived from [RESEARCH_SYNTHESIS.md](RESEARCH_SYNTHESIS.md). Date: 2026-10-26._

## Positioning

> **Given the memory actually free on this device right now, the latency budget, and how sensitive the request is, run the best model × context that fits. When things go wrong, step down a rung instead of crashing, and explain why.**

What we are **not** building: another agent harness competing on binary size (NullClaw, PicoClaw and ZeroClaw already own that), or an inference engine (llama.cpp already is one). We drive llama.cpp; the contribution is the decision layer and the evidence.

## Architecture

```
          request (prompt, ctx need, max tokens, deadline, sensitive?)
                               │
 ┌─────────────┐   ┌───────────▼────────────┐   ┌──────────────────┐
 │ sysmem      │──▶│ scheduler (pure)        │◀──│ catalog          │
 │ MemAvailable│   │ ladder: shrink ctx →    │   │ GGUF metadata →  │
 │ cgroup v2   │   │ smaller model → cloud?  │   │ weights + KV/tok │
 │ PSI / sysctl│   │ → refuse (with reason)  │   │ + calibration    │
 └─────────────┘   └───────────┬────────────┘   └────────▲─────────┘
                               │ choice + trace          │ measured peak RSS,
                   ┌───────────▼────────────┐            │ tokens/s
                   │ backend: llama.cpp CLI  │────────────┘
                   │ hard timeout, wait4 RSS │
                   │ OOM-kill → retry 1 rung │
                   └─────────────────────────┘
```

## Milestones

### M1: Honest, measurable foundation _(this branch)_
| Item | Acceptance |
|---|---|
| `edge/sysmem`: Linux `/proc/meminfo`, cgroup v2 `memory.max`/`memory.current`, `/proc/pressure/memory`; macOS `hw.memsize` × `kern.memorystatus_level` | Parsers unit-tested with fixtures; `probe` prints a live snapshot |
| `edge/gguf`: read architecture, layers, heads, KV heads, head dims, trained context from the GGUF header | Unit test on a synthetic GGUF; skips large tokenizer arrays |
| `edge/estimate`: weights + KV(ctx) + overhead; overhead and tokens/s learned from `state/calibration.tsv` | Unit-tested formula; calibration round-trip test |
| `edge/scheduler`: pure ladder with an explainable trace | Unit tests: fits, shrinks context, steps down a model, cloud only if not sensitive, refuses with a reason, honours the deadline |
| `edge/proc`: spawn with stdin, poll, **hard-kill on timeout**, capture peak RSS via `wait4` | Tested on macOS with real child processes |
| Backend: `LOCAL_LLM_CMD` template with `{model}` `{ctx}` `{n}` `{prompt_file}`; OOM or crash → exclude that rung and retry | Tested with a fake LLM script that simulates an OOM kill |
| Sandbox: executable **allowlist** + hard timeout; remove the fake "seccomp active" output | Policy tests: `/usr/bin/curl`, `bash -c`, `python3 -c` all denied |
| Cloud: removed until real; never chosen for sensitive requests | Scheduler test |
| CLI: `probe`, `plan` (dry run, `--available-mb` to simulate), `bench` (CSV + p50/p95 + peak RSS) | Manual run on macOS |
| README: claims replaced with measured numbers and method | Binary size measured per target |

**M1 status (2026-10-26):** done and run against real SmolLM2 1.7B/360M (llama.cpp 0.7.0, CPU) on an Apple Silicon Mac. What the real runs taught us, now fixed:
- Uncalibrated memory was under-estimated by up to 44% because of CPU weight repacking. The default now assumes 2× weights, and `calibrate` measures the real figure.
- Latency ignored model load and prompt time, so a run was killed at its deadline. Startup time is now measured and added.
- The 360M model writes wrong shell commands. `run` now prefers quality for both steps; the small model is only for memory/deadline pressure.
- llama.cpp's `--fit` handles single-model memory fitting. Position NanoClaw-Next above it.

### M2: Evidence on real hardware _(needs a Pi 5 4 GB and a Linux box)_
1. Run `scripts/compare-linux.sh`: a cgroup-capped (`MemoryMax=1.5G`) comparison of fixed llama.cpp at default context vs the NanoClaw-Next scheduler on the same prompts. Report the success rate, p50/p95 latency and peak RSS.
2. Calibrate estimate error: predicted vs measured peak RSS across Q4_K_M, Q5_K_M and Q8_0 at 512–8k context. Target error under 10%.
3. Pressure experiment: a background memory hog ramps up mid-run; show pre-emptive step-down when PSI `some avg10` rises.
4. Publish the results table in the README.

### M3: Real isolation for tool execution
- Landlock (filesystem: read-only home, writable `state/`), seccomp-bpf (deny `connect`, `ptrace`, `mount`), `PR_SET_NO_NEW_PRIVS`, and dropping to a dedicated user.
- Tests run on Linux CI (GitHub Actions `ubuntu-latest` + `aarch64` runner).
- Only after this lands may the README mention sandboxing.

### M4: Persistent engine and smarter policies
- Link `libllama` or drive a long-lived `llama-server`, so weights stay mapped between requests and swap cost is paid only on a model change.
- KV cache quantization (`q8_0`) as an extra rung on the ladder.
- Learned latency model (prompt-processing and generation tokens/s per model), thermal-throttle awareness on the Pi.
- Optional cloud backend (OpenAI-compatible HTTP), off by default.

### M5: Agent layer (only after M2 shows a win)
Revisit hierarchical memory, skills and tool fallback, which exist today as experimental scaffolding.

## What unlocks the most potential

1. **The scheduler + calibration loop (M1)** turns the project from claims into a tool that behaves differently from Ollama under memory pressure. Everything else depends on it.
2. **The capped benchmark (M2)** is the single artifact that makes the project credible to reviewers, employers and users.
3. **A persistent engine (M4)** removes the per-request model-load cost, which otherwise eats the latency budget on a Pi.

## Risks

| Risk | Mitigation |
|---|---|
| Ollama adds adaptive fallback | Stay focused on explainable, deadline-aware choices and a reproducible benchmark; both are useful even then |
| Estimates are wrong on GPU/Metal backends | Calibration from measured RSS; M2 error target |
| Per-request process spawn is slow | M4 persistent engine; benchmarks report load time separately |
| Name collision with NanoClaw | Decide on a rename (EdgeMorph / NanoEdge Runtime) after checking availability |
| Zig 0.15.2 `zig build` fails on macOS 27 (linker can't read the new SDK) | Documented workaround: `zig build-exe … -target aarch64-macos.15.0`; CI on Linux |

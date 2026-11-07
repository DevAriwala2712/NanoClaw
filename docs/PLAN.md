# Research plan: memory-efficient inference with useful model behavior

_Derived from [RESEARCH_SYNTHESIS.md](RESEARCH_SYNTHESIS.md). Date: 2026-10-26._

**Scope updated 2026-11-06:** NanoClaw-Next is the research repository. [TUMe](https://github.com/DevAriwala2712/TUMe) owns the maintenance-product direction: monitoring, diagnosis, permitted recovery, APIs and integrations. See [PROJECT_SPLIT.md](PROJECT_SPLIT.md). The existing M1/M2 evidence is retained; future work must measure task usefulness alongside resource savings.

## Positioning

> **Given the memory actually free on this device right now, the latency budget, and how sensitive the request is, run the best model × context that fits. When things go wrong, step down a rung instead of crashing, and explain why.**

What we are **not** building: another agent harness competing on binary size (NullClaw, PicoClaw and ZeroClaw already own that), or an inference engine (llama.cpp already is one). We drive llama.cpp; the contribution is the decision layer and the evidence.

**Quality requirement:** preserving a configured model ranking is not a quality evaluation. Compare policies on task correctness, completeness, uncertainty/refusal behavior and the whole workload's memory/latency. A smaller model that returns an incorrect answer is not a successful optimization. The [evaluation protocol](QUALITY_EVALUATION.md) defines the research approach; its quality criteria must be set before experiments.

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
**M2 status (2026-11-06): in progress.** First Linux evidence collected in a 4 GiB Ubuntu ARM64 VM on Apple Silicon. Under a real 1.5 GiB cgroup cap, fixed 1.7B @ 4096 failed 5/5 with OOM kills; the scheduler selected 360M @ 4096 and completed 5/5 (end-to-end p50/p95 810/911 ms). A separate fault-injection run recovered from a real OOM on attempt two. Linux tests passed 32/32, selftest 10/10. [Cap comparison and raw evidence](benchmarks/2026-11-05-linux-vm/REPORT.md).

The VM calibration grid is now measured for both 1.7B and 360M at Q4_K_M, Q5_K_M and Q8_0: calibration at 512/4096, then three repetitions at held-out 1024/2048/8192 contexts, 54/54 completed with no OOM kills and maximum absolute RSS error 0.0583% (target <10%). The VM was temporarily enlarged to 8 GiB, with a 6 GiB cap per command, for this accuracy experiment. [Grid report, method and data](benchmarks/2026-11-06-quantization-grid/REPORT.md).

Still outstanding: physical Pi validation, the PSI-pressure policy/experiment, and broader prompt/quality coverage. PSI is currently read but is not a scheduler input; pre-emptive switching during inference needs implementation before item 3 can pass. VM results do not close the hardware milestone.

1. Run `scripts/compare-linux.sh`: a cgroup-capped (`MemoryMax=1.5G`) comparison of fixed llama.cpp at default context vs the NanoClaw-Next scheduler on the same prompts. Report the success rate, p50/p95 latency and peak RSS.
2. Calibrate estimate error: predicted vs measured peak RSS across Q4_K_M, Q5_K_M and Q8_0 at 512–8k context. Target error under 10%.
3. Pressure experiment: a background memory hog ramps up mid-run; show pre-emptive step-down when PSI `some avg10` rises.
4. Publish the results table in the README.

### M3: Quality-preserving evaluation _(planned)_
- Build labeled tasks for extraction, reasoning, system diagnosis, permitted-procedure selection and uncertainty/refusal. Use held-out cases and predefined rubrics.
- Compare fixed-large, fixed-small, tuned-server and adaptive policies at the same RAM limits, prompts, output budgets and operating conditions.
- Publish correct-task completion, invalid recommendations, refusals, total retry-inclusive latency, peak RSS and cgroup charge. Set task-specific quality floors before comparing policies.
- Keep optimization claims limited to measured workloads. The existing small-model mistakes are failures to account for, not exceptions to hide.
- Production isolation and maintenance runbooks belong to TUMe. This repository's existing tool path remains experimental and does not provide kernel isolation.

### M4: Persistent engine and memory-policy research _(planned)_
- Link `libllama` or drive a long-lived `llama-server`, so weights stay mapped between requests and swap cost is paid only on a model change.
- KV cache quantization (`q8_0`) as an extra rung on the ladder.
- Learned latency model (prompt-processing and generation tokens/s per model), thermal-throttle awareness on the Pi.
- Optional cloud backend (OpenAI-compatible HTTP), off by default.

Evaluate each candidate's quality and total-footprint effects under M3, including context loss, prompt truncation, output limits, GPU memory versus RSS, deadline misses and retries. Deadline-aware estimates are not a proven whole-request service guarantee.

### M5: Transfer validated results into TUMe _(planned)_
Document a source commit, supported backend/configuration, experiment evidence and integration contract for each policy adopted by TUMe. Prefer selective reviewed transfers; do not automatically merge experiments into the product. Maintenance features, portals, messaging and fleet management stay in TUMe's roadmap.

## What unlocks the most potential

1. **The scheduler + calibration loop (M1)** provides a measurable base for CPU/container memory decisions; superiority over tuned serving tools remains unproven.
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

### M3 preparation update (2026-11-06)

Implemented request-level retry evidence and shared deadlines, plus an offline
60-case suite and strict response scorer. See [evaluation guide](../evaluation/README.md).
These are implementation artifacts, not measured quality results. Scoring remains
provisional until run ingestion binds treatment identities and tokenizer counts
to a verified experiment manifest; Linux cgroup collection and inference runs
remain separately authorized experiment work.

### M3 run ingestion (2026-11-07)

`evaluate_quality.py ingest` binds one policy/cap run to a frozen bundle. It checks
bundle checksums, the frozen scorer, each arm's model and context, per-case
token counts, rendered-prompt hashes, backend arguments and eligibility status.
A run can pass the quality gate only when it is bound, complete, held out and
fully measured, including cgroup charge and OOM counts. The manifest now declares
`fixed_context` for the fixed arms.

`scripts/run_quality_arm.py` is the execution driver. It runs one arm per cap,
with each request in its own systemd scope (MemoryMax, no swap,
OOMPolicy=continue). It captures `memory.peak` and OOM kills, checks model and
calibration hashes, gates ineligible inputs before launch, and writes `run.json`
for `ingest`. It is tested against a fake backend only. No inference has been
run.

`scripts/prepare_quality_manifest.py` fills manifests from the pinned tokenizer and
implements the tuned-context selection rule. Drafts for the four development sweep
contexts are in `state/quality/prepared/` (ignored by Git). They are unfrozen
until hardware, authorization and repetitions are set.

**Blocker found while preparing:** held-out prompts reach 5660 tokens, so only
7/10 cases per family fit at context 4096. The 9/10 gate is unreachable for
every arm until the context set, the gate or the long cases change. See the
[evaluation guide](../evaluation/README.md#preparing-manifests).

Next, as authorized experiment work: fill and freeze a development manifest
(pinned llama.cpp build, model hashes, tokenizer counts per case). Sweep
development contexts to freeze `tuned_context_by_cap`, then run the held-out arms
on the Ubuntu VM.

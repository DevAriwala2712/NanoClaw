# M2: first Linux VM evidence (2026-11-05)

M2 is **in progress**. A real cgroup memory cap works on Linux, the scheduler avoids an oversized model, and a separate fault-injection check recovers from a real backend OOM kill. These are Ubuntu VM measurements on an Apple Silicon Mac, not Raspberry Pi results.

## Environment and method

- Multipass 1.16.4, Ubuntu 24.04.5 LTS, Linux 6.8.0-147-generic, aarch64; 4 virtual CPUs, 4 GiB configured RAM, 24 GiB virtual disk. No host home-directory mount.
- NanoClaw source: `7d5643b`; cross-built with Zig 0.15.2 for `aarch64-linux-musl`, `ReleaseSmall`, stripped. Linux unit tests: 32/32; Linux selftest: 10/10. macOS unit tests also passed 32/32.
- Official llama.cpp release `b11669`, commit `620d2225c`, version `0.7.0-dev`, CPU only. Release archive SHA-256 verified against the GitHub asset digest. Existing SmolLM2-Instruct Q4_K_M models copied from the Mac; model SHA-256 values are in [metadata.json](metadata.json).
- Prompt: “Explain what swap memory is in two sentences.” Both strategies use context 4096, maximum 128 generated tokens, seed 1, temperature 0, chat template, one turn, four generation/batch threads, `-ngl 0`, and `--fit off`. The baseline fixes the 1.7B model; NanoClaw may select the 360M model. The calibration calls used the same prompt and 64 tokens.
- Five runs per strategy, alternating baseline/adaptive. Each run gets a fresh systemd user scope with `MemoryMax=1536M`, `MemorySwapMax=0`, and `OOMPolicy=continue`. The VM Linux page cache is cleared before **each** measured run (`sync; echo 3 > /proc/sys/vm/drop_caches`, inside the VM only).
- End-to-end latency uses a monotonic clock around `systemd-run`, including scope setup, scheduler startup, model load and inference. GNU `time` records command peak RSS; `memory.peak` separately records the whole scope's peak memory charge. Before/after `memory.events` verifies real OOM kills.
- Primary measurements: [comparison.csv](comparison.csv), [summary.json](summary.json), [cgroup-events.json](cgroup-events.json). These runs do **not** override the scheduler's memory snapshot.

## Capped comparison

| Strategy | Success | Successful end-to-end p50 / p95 | Max command RSS | Max cgroup charge | OOM kills |
|---|---:|---:|---:|---:|---:|
| Fixed llama.cpp, 1.7B @ 4096 | 0/5 | N/A | 1533.5 MiB | 1536.0 MiB | 5 |
| NanoClaw, 360M @ 4096 | 5/5 | 810 / 911 ms | 555.5 MiB | 599.3 MiB | 0 |

All baseline attempts exited 137. Their **failed-attempt** end-to-end p50/p95 was 1997/2958 ms; that is not a successful inference latency or a speedup comparison. All adaptive runs generated 83 tokens and completed in one attempt. Success here means backend completion and generated tokens, not an assessment of answer quality. A smaller model has a quality tradeoff.

The existing `scripts/compare-linux.sh` was also run unchanged, using a baseline wrapper to match inference flags: fixed model 0/5, adaptive 5/5, adaptive child-only p50/p95 639/790 ms and peak RSS 555 MiB. See [original-script.log](original-script.log). That script does not clear caches between runs, does not collect baseline RSS, and reports the selected child's time rather than end-to-end scheduler latency; use the controlled table above for the primary result.

## Held-out memory estimate

Calibration used contexts 512 and 4096. Context 2048 was measured directly through llama.cpp, without feeding its result into the calibration store beforehand. Predictions are derived from the saved calibration snapshot and GGUF weight/KV costs.

| Q4_K_M model | Held-out context | Predicted RSS | Measured RSS | Signed error |
|---|---:|---:|---:|---:|
| 1.7B | 2048 | 2430.0 MiB | 2428.6 MiB | +0.056% |
| 360M | 2048 | 476.4 MiB | 475.5 MiB | +0.188% |

Raw byte values: [heldout.json](heldout.json). These are single held-out measurements on two Q4 models; they do not establish the full Q4/Q5/Q8, 512–8192-context error target.

## Recovery from a real OOM kill

A separate check deliberately supplied `--available-mb 4096` while retaining the real **1536 MiB** kernel cap. This is fault injection of an overoptimistic memory snapshot, not part of the main comparison. With `OOMPolicy=continue`, the oversized 1.7B child was SIGKILLed, `memory.events` incremented `oom_kill` by one, and NanoClaw excluded that model and completed on the 360M at context 4096, **attempt 2**. Evidence: [recovery.log](recovery.log), [recovery.csv](recovery.csv), and the `recovery` entry in [cgroup-events.json](cgroup-events.json).

The reported 767 ms in `recovery.csv` covers only the successful child's execution. It omits the failed attempt and is **not** the total recovery latency.

## What the experiment exposed

- **Systemd OOM policy matters:** with the default `OOMPolicy=stop`, systemd stopped the scope after the backend OOM, preventing the measurement wrapper from finishing. Use `OOMPolicy=continue` when testing whether a surviving supervisor can retry. NanoClaw cannot recover if its supervisor is killed too.
- **Page-cache accounting matters:** a preliminary warm-cache run showed process RSS above the cgroup cap because model pages had been charged outside the new scope during calibration. The primary comparison clears the VM page cache before each run. RSS and cgroup charge remain different metrics and are both recorded.
- **Conservative estimates can reject runnable contexts:** a deliberately optimistic calibration trial completed the 1.7B model at context 512 under this cap, with roughly 1532 MiB peak RSS, despite its unconstrained calibrated estimate being 2141 MiB. Linux can reclaim mapped file pages under pressure. The comparison above is specifically a fixed **4096** context baseline; it is not a claim that the 1.7B model can never run in 1.5 GiB or that this is the optimal policy.
- **PSI is observation only today:** the snapshot reads PSI, but the scheduler does not consume it and does not monitor a running child to pre-emptively switch models. The M2 pressure experiment therefore requires policy work before it can demonstrate the behavior described in the plan.

## Reproduction

The VM is named `nanoclaw-m2`. Its project is `/home/ubuntu/NanoClaw`, the executable is `bin/nanoclaw-next`, and llama.cpp is `/home/ubuntu/llama-b11669/llama-completion`. [config.txt](config.txt) captures its inference settings. No source/runtime behavior was changed for this experiment.

The exact controlled comparison driver is preserved as [run-linux-vm.py](run-linux-vm.py). It expects this prepared VM layout, Python 3.11+, GNU `time`, a working systemd user manager, and passwordless sudo **inside the VM** for page-cache clearing. It writes results under `state/m2-vm/` and appends successful runs to the VM calibration file; archive prior output before rerunning. After calibration at contexts 512 and 4096:

```bash
multipass start nanoclaw-m2
multipass exec nanoclaw-m2 -- python3 /home/ubuntu/NanoClaw/state/m2-vm/run-linux-vm.py
```

To repeat the original repository script with matching flags:

```bash
cd /home/ubuntu/NanoClaw
PATH="$PWD/bin:$PATH" \
  LLAMA_BIN="$PWD/state/m2-vm/baseline-wrapper.sh" \
  bash scripts/compare-linux.sh 1536M \
  models/SmolLM2-1.7B-Instruct-Q4_K_M.gguf \
  "Explain what swap memory is in two sentences." 5
```

That wrapper execs llama-completion with `-cnv -st --temp 0 -s 1 -ngl 0 --simple-io -t 4 -tb 4 --fit off`, followed by the script's arguments. Full raw logs, commands, preliminary runs and recovery configuration are also preserved locally in `state/m2-2026-11-05/evidence.tar.gz` (ignored by Git).

## Remaining M2 acceptance (as of 2026-11-05)

Follow-up: the Q4/Q5/Q8 grid was completed on the Ubuntu VM on 2026-11-06; see the [grid report](../2026-11-06-quantization-grid/REPORT.md). Physical Pi validation and the pressure-policy work remain outstanding.

1. Repeat on a physical Raspberry Pi 5 4 GB; VM timings do not predict Pi performance.
2. Extend held-out estimation to Q5_K_M/Q8_0 and contexts 512–8192, with repeated runs.
3. Implement and test a PSI-aware pressure policy, then run a ramping memory-hog experiment. Live memory changes are currently considered only when planning/retrying, and PSI is not a policy input.
4. Broaden prompts and repetitions, including answer-quality evaluation. Five runs on one prompt are preliminary evidence.

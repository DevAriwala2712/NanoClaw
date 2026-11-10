# M3 quality pilot

## Environment and preflight

The experiment runs on an Apple M3 Pro host with 18 GiB RAM using the existing Multipass 1.16.4 QEMU VM with Ubuntu 24.04 ARM64, four vCPUs, 4 GiB assigned RAM and Linux 6.8.0-147. The CPU-only backend is llama.cpp b11669 (620d2225c), with four generation and four batch threads. NanoClaw was cross-built from `d69a60f8d5109c6ca31c6e637a6928f0b0111e92` using Zig 0.15.2 and `zig build-exe src/main.zig -target aarch64-linux-musl -OReleaseSmall -fstrip`.

The [preflight log](preflight.txt) records model and binary hashes, a real 1536 MiB cgroup with swap disabled, and 32/32 Linux Zig tests, 10/10 self-checks and 22/22 Python quality tests. Both SmolLM2 Q4_K_M models matched the pinned tokenizer at 116 and 5650 tokens when checked with `llama-completion --verbose-prompt`. The tokenizer check did not use the study's cold-cache protocol. [Frozen calibration](calibration.tsv) reuses the Q4 samples from the [prior calibration grid](../2026-11-06-quantization-grid/REPORT.md), with model IDs mapped to the M3 manifest IDs.

The pilot uses one greedy repetition per case (`--temp 0 -s 1`), a 128-token output budget, a shared 120-second request deadline, no prompt truncation and fresh processes with the VM page cache cleared before each measured request. The development sweep uses 512/1024/2048/4096/8192 contexts at 1536/2048/3072 MiB. It tunes a fixed large-model context before the four-policy comparison on the 30 held-out cases. The per-family quality floor is 9/10 with zero forbidden decisions. See the [evaluation protocol](../../../evaluation/README.md) and [execution script](run-m3.sh).

## Live cgroup smoke test

The first attempt reached systemd but exited before inference because the runner resolved a relative scope-script path from the request's working directory. Commit `7846281` makes the scope and measurement paths absolute. The rerun used the unchanged Zig binary and the updated Python driver. The archive retains both attempts, exact commands, counters, raw responses and the frozen smoke bundle.

| Policy | Case (prompt tokens) | Model and context | Request wall time | Peak child RSS | Peak cgroup charge | Outcome |
|---|---|---|---:|---:|---:|---|
| Fixed small | uncertainty-01 (116) | 360M @ 8192 | 0.912 s | 720.1 MiB | 729.0 MiB | Invalid output |
| Fixed small | diagnosis-04 (5650) | 360M @ 8192 | 39.583 s | 744.8 MiB | 754.3 MiB | Invalid output |
| Adaptive | uncertainty-01 (116) | 360M @ 8192 | 0.855 s | 720.2 MiB | 762.1 MiB | Invalid output |
| Adaptive | diagnosis-04 (5650) | 360M @ 8192 | 37.787 s | 744.8 MiB | 786.5 MiB | Invalid output |

All four processes completed under the 1536 MiB cap with zero OOM kills and zero deadline misses. Both arms ingested successfully and remain provisional because the smoke covers two development cases. [Raw smoke evidence](smoke-evidence.tar.gz).

## Development checkpoint at 1.5 and 2 GiB

Each cap has five development arms with 30 cases per arm. At each cap, 51 inputs were ineligible for their assigned context. No development answer scored correct. Request latency includes all attempts on the 99 launched requests per cap, including failures. Both caps recorded zero deadline misses.

| Cap | Backend completions | Invalid outputs | Unnecessary refusals | Correct refusals | OOM kills | Request p50 / p95 (s) | Max child RSS / cgroup (MiB) |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1536 MiB | 45 | 42 | 3 | 0 | 54 | 2.120 / 9.812 | 1533.88 / 1536.00 |
| 2048 MiB | 69 | 65 | 4 | 0 | 30 | 3.920 / 52.530 | 2044.45 / 2048.00 |

At 4096 context, the eligible requests went from 24 OOM kills at 1536 MiB to 24 completions at 2048 MiB, with zero correct answers in both arms. Failed-request p50/p95 at the lower cap were 1.894/2.069 s. Completed-request p50/p95 at the higher cap were 13.871/58.157 s.

### Raw checkpoint

The checkpoint contains 14/15 bound development arms. The 3072 MiB arm at 8192 context has 22/30 records. Held-out results are pending. The archive includes all recorded request rows at capture, completed request logs, frozen bundles, hashes and the earlier interruption. [Raw checkpoint archive](development-checkpoint-evidence.tar.gz).

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

The checkpoint contains 14/15 bound development arms. The 3072 MiB arm at 8192 context has 22/30 records. The held-out run was pending at capture. The archive includes all recorded request rows at capture, completed request logs, frozen bundles, hashes and the earlier interruption. [Raw checkpoint archive](development-checkpoint-evidence.tar.gz).

## Development sweep

Fifteen full development arms were scored and bound to the frozen manifests.
The prespecified rule selected 4096 at 1536 MiB, 8192 at 2048 MiB, 512 at 3072 MiB.
At 1536 MiB, 2048 MiB, the selection rule picked a context with zero backend completions. When no candidate scores a correct supported task, an arm that produces no answer can win the invalid-output tiebreak. The held-out comparison retains the frozen rule and reports this limitation.
The denominator includes all 30 cases per arm. Ineligible cases did not launch.
A VM power-off interrupted the first 3072 MiB / 1024-context arm. Its 21 records and shutdown evidence are archived separately. The arm was rerun from the beginning with the original bundle and its rerun is the only attempt included in the table.

| Cap | Context | Correct supported | Correct refusals | Invalid | Ineligible | Backend failures | OOM kills |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1536 MiB | 512 | 0/25 | 0/5 | 8 | 21 | 0 | 0 |
| 1536 MiB | 1024 | 0/25 | 0/5 | 17 | 12 | 0 | 0 |
| 1536 MiB | 2048 | 0/25 | 0/5 | 17 | 12 | 0 | 0 |
| 1536 MiB | 4096 | 0/25 | 0/5 | 0 | 6 | 24 | 24 |
| 1536 MiB | 8192 | 0/25 | 0/5 | 0 | 0 | 30 | 30 |
| 2048 MiB | 512 | 0/25 | 0/5 | 8 | 21 | 0 | 0 |
| 2048 MiB | 1024 | 0/25 | 0/5 | 17 | 12 | 0 | 0 |
| 2048 MiB | 2048 | 0/25 | 0/5 | 17 | 12 | 0 | 0 |
| 2048 MiB | 4096 | 0/25 | 0/5 | 23 | 6 | 0 | 0 |
| 2048 MiB | 8192 | 0/25 | 0/5 | 0 | 0 | 30 | 30 |
| 3072 MiB | 512 | 0/25 | 0/5 | 8 | 21 | 0 | 0 |
| 3072 MiB | 1024 | 0/25 | 0/5 | 17 | 12 | 0 | 0 |
| 3072 MiB | 2048 | 0/25 | 0/5 | 17 | 12 | 0 | 0 |
| 3072 MiB | 4096 | 0/25 | 0/5 | 23 | 6 | 0 | 0 |
| 3072 MiB | 8192 | 0/25 | 0/5 | 29 | 0 | 0 | 0 |

[Development metrics](development.csv) · [Tuned context selection](tuned.json) · [Raw development evidence](development-evidence.tar.gz).

## Held-out quality and resource results

Each row covers the same 30 cases. E, D and U are extraction, diagnosis and uncertainty, each out of 10.
Latency includes all attempts and spans scheduled requests, including failed ones.
Cases gated before launch contribute to the quality denominator and have no runtime measurements.

| Cap | Policy | E / D / U | Invalid | OOM kills | Deadline misses | Request p50 / p95 (ms) | Max RSS / cgroup (MiB) | Quality floor |
|---:|---|---:|---:|---:|---:|---:|---:|---|
| 1536 MiB | adaptive_input_gate | 0 / 0 / 0 | 28 | 0 | 0 | 11351 / 43142 | 744.9 / 787.7 | Fail |
| 1536 MiB | fixed_large | 0 / 0 / 0 | 0 | 30 | 0 | 1878 / 2276 | 1533.9 / 1536.0 | Fail |
| 1536 MiB | fixed_small | 0 / 0 / 0 | 28 | 0 | 0 | 11242 / 39703 | 745.1 / 753.8 | Fail |
| 1536 MiB | tuned_large | 0 / 0 / 0 | 0 | 21 | 0 | 1788 / 1937 | 1534.1 / 1536.0 | Fail |
| 2048 MiB | adaptive_input_gate | 0 / 0 / 0 | 28 | 0 | 0 | 14599 / 44230 | 745.1 / 787.7 | Fail |
| 2048 MiB | fixed_large | 0 / 0 / 0 | 0 | 30 | 0 | 1782 / 2263 | 2045.0 / 2048.0 | Fail |
| 2048 MiB | fixed_small | 0 / 0 / 0 | 28 | 0 | 0 | 13243 / 71407 | 745.1 / 753.6 | Fail |
| 2048 MiB | tuned_large | 0 / 0 / 0 | 0 | 30 | 0 | 1785 / 2315 | 2045.1 / 2048.0 | Fail |
| 3072 MiB | adaptive_input_gate | 0 / 0 / 0 | 30 | 0 | 0 | 14951 / 45945 | 2492.8 / 2540.5 | Fail |
| 3072 MiB | fixed_large | 0 / 0 / 0 | 30 | 0 | 0 | 28055 / 85206 | 3066.9 / 3072.0 | Fail |
| 3072 MiB | fixed_small | 0 / 0 / 0 | 28 | 0 | 0 | 14390 / 44649 | 744.9 / 753.8 | Fail |
| 3072 MiB | tuned_large | 0 / 0 / 0 | 6 | 0 | 0 | 2913 / 3184 | 2158.1 / 2171.2 | Fail |

[Held-out metrics](heldout.csv) include correct refusals, forbidden decisions, ineligibility, backend failures, model/context selections, and latency split by completion status. [Raw held-out evidence](heldout-evidence.tar.gz).

## KV cache feasibility probe

The same 1.7B Q4_K_M model ran at 8192 context under a 3072 MiB cap. Both arms enabled Flash Attention and used the same two development cases, threads and cold-cache procedure.

| K/V cache | Case | Backend status | Scored outcome | Wall (ms) | RSS / cgroup (MiB) | OOM kills | Deadline missed |
|---|---|---|---|---:|---:|---:|---|
| f16 | uncertainty-01 | completed | invalid | 3860 | 3066.7 / 3072.0 | 0 | No |
| f16 | diagnosis-04 | completed | invalid | 79570 | 3066.5 / 3072.0 | 0 | No |
| q8_0 | uncertainty-01 | completed | invalid | 3350 | 2874.5 / 2889.2 | 0 | No |
| q8_0 | diagnosis-04 | deadline_exhausted | deadline_exhausted | 120156 | 2930.1 / 2944.4 | 0 | Yes |

[Probe commands](run-kv.sh) · [Raw KV probe evidence](kv-evidence.tar.gz).

# M3 quality pilot

## Environment and preflight

The experiment runs on an Apple M3 Pro host with 18 GiB RAM using the existing Multipass 1.16.4 QEMU VM with Ubuntu 24.04 ARM64, four vCPUs, 4 GiB assigned RAM and Linux 6.8.0-147. The CPU-only backend is llama.cpp b11669 (620d2225c), with four generation and four batch threads. NanoClaw was cross-built from `d69a60f8d5109c6ca31c6e637a6928f0b0111e92` using Zig 0.15.2 and `zig build-exe src/main.zig -target aarch64-linux-musl -OReleaseSmall -fstrip`.

The [preflight log](preflight.txt) records model and binary hashes, a real 1536 MiB cgroup with swap disabled, and 32/32 Linux Zig tests, 10/10 self-checks and 22/22 Python quality tests. Both SmolLM2 Q4_K_M models matched the pinned tokenizer at 116 and 5650 tokens when checked with `llama-completion --verbose-prompt`. The tokenizer check did not use the study's cold-cache protocol. [Frozen calibration](calibration.tsv) reuses the Q4 samples from the [prior calibration grid](../2026-11-06-quantization-grid/REPORT.md), with model IDs mapped to the M3 manifest IDs.

The pilot uses one greedy repetition per case (`--temp 0 -s 1`), a 128-token output budget, a shared 120-second request deadline, no prompt truncation and fresh processes with the VM page cache cleared before each measured request. The development sweep uses 512/1024/2048/4096/8192 contexts at 1536/2048/3072 MiB. It tunes a fixed large-model context before the four-policy comparison on the 30 held-out cases. The per-family quality floor is 9/10 with zero forbidden decisions. See the [evaluation protocol](../../../evaluation/README.md) and [execution script](run-m3.sh).

The preflight establishes measurement prerequisites. The smoke and study results will be recorded in separate commits as they are collected.

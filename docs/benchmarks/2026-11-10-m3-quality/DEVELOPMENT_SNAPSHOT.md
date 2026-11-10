# M3 development snapshot

Captured during the development sweep on November 10, 2026. This snapshot includes nine fully scored configurations out of 15 and all 270 case records from those configurations, including cases gated before launch. It covers all five 1536 MiB configurations and four 2048 MiB configurations. The 2048 MiB / 8192-context arm, 3072 MiB arms, and held-out study are outside this snapshot.

See the [pilot report](REPORT.md) for hardware, model, backend and cache settings. The [metrics CSV](development-snapshot.csv) separates correctness and refusals from backend completion, and reports invalid outputs, OOM kills, retry-inclusive request latency, peak process RSS and peak cgroup charge. All nine summaries were reproduced from the frozen bundles and per-case records retained locally.

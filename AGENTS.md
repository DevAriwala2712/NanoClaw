# Working on NanoClaw-Next research

This repository studies memory-efficient local inference with preserved task usefulness. TUMe is the separate maintenance product: https://github.com/DevAriwala2712/TUMe. Read `docs/PROJECT_SPLIT.md`, `docs/PLAN.md` and `docs/QUALITY_EVALUATION.md` before changing scope or evaluating policies.

- Keep product telemetry, maintenance workflows, portal/API and integration features in TUMe unless they are explicitly needed as research fixtures.
- A completed inference or lower RSS is not proof of task quality. Report correctness, invalid outputs, refusals and total retry-inclusive latency alongside memory/failure measurements.
- Distinguish process RSS, cgroup charge, controller size and total running footprint. Identify hardware/model/backend/settings and cold versus warm operation.
- Compare against tuned baselines and current documented competitor behavior. Do not claim other servers universally use static knobs or fail hard.
- Existing tool execution is experimental: executable allowlist plus timeout, without kernel isolation. Avoid describing it as a safe autonomous maintenance agent.
- New inference benchmarks, stress experiments, VMs and model downloads require explicit user authorization. Documentation-only changes use static document/repository checks.
- Preserve raw evidence and provenance. Transfer validated changes to TUMe selectively; do not automatically merge experimental branches into a maintenance deployment.

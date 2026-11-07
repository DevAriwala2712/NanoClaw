# Changelog

Follows [Keep a Changelog](https://keepachangelog.com/). Entries are taken from merged pull requests.

## [Unreleased]

### Added
- `evaluate_quality.py ingest`: manifest-bound scoring of one policy/cap run. It verifies the frozen bundle, arm treatment, token counts, prompt hashes and backend arguments. The manifest gains `fixed_context`.
- `scripts/run_quality_arm.py`: runs one policy arm at one cap. Each request runs in a systemd memory scope, and the driver records cgroup peak and OOM kills and writes `run.json` for `ingest`.
- `scripts/prepare_quality_manifest.py`: fills manifests (hashes, tokenizer identity, rendered prompts, pinned token counts) and picks the tuned context per cap from development summaries.
- Logo mark, generated figures (`scripts/make_figures.py`), computed README badges (`scripts/update_badges.py`) and a drift test.
- `CONTRIBUTING.md`, `.editorconfig`, issue and pull request templates.

### Changed
- README rebuilt around measured evidence. Loose root files moved: `ZIG_VERSION_REQUIREMENT.md` to `docs/`, `Resources/` to `docs/archive/`.

## 2026-11-06

### Added
- Q4_K_M / Q5_K_M / Q8_0 memory-estimate grid at held-out contexts: 54/54 runs completed, max RSS error 0.0583% (#3).

## 2026-11-05

### Added
- Linux VM memory-cap benchmarks and a real OOM-recovery check (#2).

### Fixed
- Benchmark CSV line endings normalised (#2).

## 2026-10-26

### Changed
- Rebuilt as an adaptive local-LLM scheduler for constrained devices (#1).

# Changelog

Follows [Keep a Changelog](https://keepachangelog.com/). Entries are taken from merged pull requests.

## [Unreleased]

### Added
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

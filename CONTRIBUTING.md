# Contributing

NanoClaw-Next is evidence-first: a claim goes in the README only if a file in this repo backs it.

## Set up

- Zig **0.15.2** (see [docs/ZIG_VERSION_REQUIREMENT.md](docs/ZIG_VERSION_REQUIREMENT.md); on macOS 27 use the fallback target documented there).
- Python 3.11+ with `matplotlib` for figures (`pip install matplotlib`). Nothing else is needed for the scripts.
- llama.cpp and GGUF models only if you run real benchmarks. `scripts/dev/` has fake models and a fake LLM for model-free runs.

## Check your change

```bash
zig build test                                     # unit tests
python3 -m unittest tests.test_readme_badges       # README badges still match the evidence
```

## When you change results or docs

- New measurements go under `docs/benchmarks/<date>-<name>/` with the raw data, the driver script and a `REPORT.md` that states the method and limits.
- Regenerate figures and badges, then commit them with the data:

```bash
python3 scripts/make_figures.py
python3 scripts/update_badges.py
```

- Never edit the numbers between `<!-- badges:start -->` and `<!-- badges:end -->` by hand.
- Keep negative and preliminary results visible, and say whether a result came from a VM or from real target hardware.
- Use `git mv` for moves, and fix relative links.

## Commits and pull requests

Write the commit message to say what changed and where any numbers came from. Fill in the pull request template with the tests you ran.

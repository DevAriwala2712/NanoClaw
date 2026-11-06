# Model/context quality implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Make request accounting trustworthy and provide the offline pilot evaluation artifacts.
**Architecture:** Keep legacy child CSV fields and add request totals plus a versioned JSONL sidecar. Use standard-library Python for fixture validation, scoring and manifest preparation; no inference launcher in this change.
**Tech Stack:** Zig 0.15.2, Python 3 standard library.
**Spec:** ../specs/2026-11-06-model-context-quality-design.md

## Global Constraints
- No inference experiments, model downloads or VM operations.
- Sixty cases, three families, ten development and ten held-out cases per family.
- Full rendered input plus 128 output tokens must fit context.
- Missing measurements are null, never zero; RSS and cgroup charge are separate.
- Preserve raw answers and reject malformed structured output.

## Review Focus
- Terminal errors must retain attempt durations and memory.
- Large stdin or closed output streams must not evade child timeout.
- Missing/duplicate evaluation rows must not inflate quality scores.
- Forbidden action selections must not disappear into generic invalid output counts.
- Different model tokenizers and template overhead must not share one token count.

### Task 1: Request accounting and deadline
**Files:** src/edge/engine.zig, src/edge/proc.zig, src/app.zig, src/main.zig, tests/test_request_accounting.py, tests/fixtures/accounting_backend.py.
**Interfaces:** Engine.last_request exposes totals and fixed-size attempt records after both success and failure; bench emits FILE.requests.jsonl schema_version=2 alongside compatible CSV columns. --freeze-calibration disables appending samples.
- [ ] Write integration tests with real fake-backend processes for retry success, exhausted deadline, nonzero exit, all failures, larger failed RSS, no-fit refusal, frozen calibration, blocked stdin and closed pipes.
- [ ] Run tests against baseline and observe failures.
- [ ] Implement monotonic request/child timers, remaining-deadline retries, per-attempt metadata and raw output sidecar.
- [ ] Run Zig suite and Python integration tests; commit.

### Task 2: Offline evaluation
**Files:** evaluation/cases.jsonl, evaluation/case.schema.json, evaluation/manifest.template.json, scripts/evaluate_quality.py, tests/test_quality_evaluation.py.
**Interfaces:** load_cases(path), score_response(case, raw), summarize(cases, records), eligible(prompt_tokens, context, output_tokens=128), validate_manifest(manifest, cases, ready=False); CLI validate, score, freeze.
- [ ] Write tests for strict parsing, evidence IDs, forbidden actions, correct/unnecessary refusals, backend failures, missing/duplicate records, split leakage, token eligibility and unresolved manifest rejection.
- [ ] Observe failures, then implement validator/scorer and 60 independently labeled scenario fixtures.
- [ ] Implement immutable provenance bundle preparation and manifest validation, including tokenizer-specific prompt counts and raw artifact checksums.
- [ ] Run the complete offline suite and validate the shipped fixtures; commit.

### Task 3: Documentation and final review
**Files:** evaluation/README.md, README.md, docs/PLAN.md, scripts/update_badges.py-generated README badges.
- [ ] Document schema migration, scoring, proposed matrix and separate experiment authorization.
- [ ] Run all tests, build native and Linux targets, update badges and verify whitespace.
- [ ] Request fresh whole-branch review, fix important findings with regression tests, and commit.

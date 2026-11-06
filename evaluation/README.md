# Offline model/context pilot

This directory implements the preparation and scoring portion of the approved
study. No inference results have been collected. Cases are hand-authored synthetic
fixtures: 20 extraction, 20 diagnosis and 20 uncertainty/injected-log cases, with
10 development and 10 held-out cases per family. Scenario groups are split before
wording or length variation. They are public fixtures, not a hidden benchmark.

Validate without inference:

```sh
python3 scripts/evaluate_quality.py validate
```

Responses must be a single JSON object with `decision`, `fields` and `evidence`.
Scoring rejects fences, duplicate keys, extra text, missing fields and non-finite
numbers. Fields match exactly (including types); evidence IDs are an unordered
set. Forbidden decisions are counted independently of malformed output.

A records JSONL file describes ONE policy and ONE cap. Each row has `case_id`,
`repetition` (one-based), `status`, `response` (raw string for completion),
`total_wall_ms`, `max_attempt_rss_bytes`, `cgroup_peak_bytes`, `oom_kills` and
`deadline_missed`. Unknown measurements use null. Status is completed,
backend_failed, backend_error, scheduler_refusal, deadline_exhausted or
context_ineligible. Preserve backend logs, actual arguments and runtime sidecars
alongside records. The scorer does not launch or execute model output.

```sh
python3 scripts/evaluate_quality.py score --records records.jsonl --split heldout --repetitions 3 --out summary.json
```

Missing rows count as missing outcomes, duplicate rows are rejected. Repetitions
are not independent cases: a case counts correct only if all repetitions are
correct. The pilot quality gate requires 9/10 correct in EACH held-out family and
zero forbidden decisions. Development or partial suites cannot pass this gate.
Report supported-task correctness and correct refusals separately. Small counts
are exploratory and do not establish population safety rates. Latency summaries
separate completed backend requests from failed ones; correctness is separate.

## Freeze before experiments

Copy manifest.template.json and fill hardware, exact source/backend build, model
hashes, calibration hashes, sampling, threads, cache procedure, ordering,
repetitions, authorization and tokenizer-specific rendered prompts/counts.
Counts include the chat template and special tokens. The complete original case
prompt must occur in the rendered input. The eligibility rule is rendered tokens
plus 128 reserved output tokens <= chosen context. Counts are supplied from the
pinned backend tokenizer; this offline tool cannot independently verify them.

Choose one tuned large-model context per cap using development data: maximize
correct supported tasks, then minimize invalid/forbidden outputs, median total
latency and context, in that order. Freeze before evaluating held-out cases.
The existing scheduler arm gates its selected configuration for input eligibility
without truncation or another retry. A prompt-aware router is a future arm.

```sh
python3 scripts/evaluate_quality.py freeze --manifest prepared.json --out state/quality/frozen-study
```

Freeze refuses unresolved fields and existing destinations. It snapshots cases,
manifest and scorer with SHA-256 checksums. These are tamper-evident snapshots,
not filesystem-enforced immutability. Keep model files and raw runtime artifacts
separately; manifest hashes identify them. This command does not run inference.

Proposed experiment: existing CPU models, caps 1536/2048/3072 MiB, contexts
512/1024/2048/4096, 128 output tokens. A development-only sweep measures eligible
model/context pairs before choosing the tuned baseline. Exact repetitions,
resource availability and cache procedure remain to be set before authorization.
New experiments, model downloads and VM operations require explicit approval.
The Linux cgroup execution driver and actual measurements are deferred to that
separately authorized experiment; the shipped command is an offline scorer.

## Runtime accounting

`bench` appends schema-version-2 CSV fields `total_wall_ms`,
`max_attempt_rss_bytes`, `deadline_missed`, `schema_version`. Original `wall_ms`
and `peak_rss_mb` remain successful-child metrics. Missing CSV numbers are empty.
`FILE.requests.jsonl` stores complete attempts, bounded raw stdout/stderr, prompt,
response, signals, exit codes and request totals. Protect these files as prompt
and response data. `--freeze-calibration` suppresses calibration writes.

The deadline spans all retries. Child input and EOF handling remain subject to
that deadline. The controller records overruns; this is not a real-time guarantee
or kernel isolation. RSS is not whole-workload cgroup charge; use a Linux wrapper
for charge/OOM counters and preserve cold-process versus page-cache conditions.

### Current scoring boundary

`observed_quality_floor_met` describes response labels only. `quality_floor_passed`
remains false and `provisional` remains true: the offline scorer does not yet bind
records to a verified executed manifest, selected model/context or tokenizer
counts. Do not combine treatments or cite this output as a validated policy
comparison. Manifest-bound run ingestion and Linux cgroup capture are required
before the experiment's research acceptance gate can pass. Unknown OOM/deadline
measurements yield null aggregate counts. Diagnosis answer positions are balanced
within each split.

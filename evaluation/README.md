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
512/1024/2048/4096/8192, 128 output tokens. A development-only sweep measures eligible
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

### Scoring boundary

`score` is label-only: `quality_floor_passed` is always false and `provisional`
always true. Use `ingest` for results that can be cited.

## Manifest-bound ingestion

`ingest` scores one policy at one cap against a frozen bundle. Run the scorer
copy inside the bundle; ingestion refuses if the running scorer differs.

```sh
python3 state/quality/frozen-study/evaluate_quality.py ingest \
  --bundle state/quality/frozen-study --run run.json --records records.jsonl --out summary.json
```

`run.json` is written by the execution driver after the run:
`schema_version` (1), `policy`, `cap_mib`, `split`, `repetitions`,
`bundle_checksums_sha256` (SHA-256 of the bundle's `checksums.json`) and
`records_sha256`. Each record adds `model_id`, `context`, `prompt_tokens`,
`rendered_prompt_sha256` and `backend_arguments` to the fields above.

Ingestion rejects the whole run when any of these fail:

- bundle files match `checksums.json`, and the manifest is experiment-ready;
- the sidecar names this bundle, the records hash, the manifest split and
  repetitions, a manifest policy and cap;
- the arm's treatment holds. `models[0]` is the large model and `models[1]` the
  small one. `fixed_large`/`fixed_small` use their model at `fixed_context`;
  `tuned_large` uses the large model at `tuned_context_by_cap[cap]`;
  `adaptive_input_gate` may use either model and any study context, and is the
  only arm that may report `scheduler_refusal` (with null model and context);
- the prompt token count, rendered-prompt hash and backend arguments equal the
  manifest's entry for that case and model;
- `context_ineligible` appears exactly when rendered tokens + output tokens
  exceed the context.

A bound summary reports `selections` (model@context counts). It stays
`provisional` when rows are missing or any record lacks wall time, RSS, cgroup
charge, OOM count or deadline flag. `quality_floor_passed` requires a bound,
complete, fully measured held-out run that meets the observed floor.

Token counts are still supplied by the pinned tokenizer and bound, not
recomputed. A `context_ineligible` request is gated before launch, so its missing
measurements do not make the run provisional. Diagnosis answer positions are
balanced within each split.

## Preparing manifests

`scripts/prepare_quality_manifest.py prepare` fills a manifest from the
template, without inference:

- model, calibration and case hashes;
- GGUF tokenizer identity and chat-template hash;
- the source commit, read from `.git`;
- `backend_arguments` for the target machine's `llama-completion`;
- rendered prompts, with token counts from the pinned `llama-tokenize`, which
  loads only the vocabulary.

Rendering follows llama.cpp's built-in ChatML (jinja is off by default, and
there is no system prompt). The tool refuses a model whose GGUF template is not
ChatML. Hardware, authorization and repetitions are flags; while any is unset,
`freeze` refuses.

```sh
python3 scripts/prepare_quality_manifest.py prepare --split development --tuned-context 1024 \
  --model smollm2-1.7b-q4=models/SmolLM2-1.7B-Instruct-Q4_K_M.gguf \
  --model smollm2-360m-q4=models/SmolLM2-360M-Instruct-Q4_K_M.gguf \
  --calibration state/calibration.tsv --tokenizer "$(command -v llama-tokenize)" \
  --llama-completion /home/ubuntu/llama-b11669/llama-completion \
  --hardware "..." --authorization "..." --repetitions 3 \
  --out state/quality/prepared/development-tuned-1024.json
```

The development sweep uses one manifest per candidate context: `--tuned-context`
applies that context at every cap. Run `tuned_large` at each cap from each
frozen sweep bundle, then pick per cap:

```sh
python3 scripts/prepare_quality_manifest.py choose-tuned summaries/*.json --out tuned.json
```

`choose-tuned` takes bound, non-provisional development summaries. Its
selection file becomes `--tuned-selection` for the held-out manifest, and its
SHA-256 becomes `development_results_sha256`. The rendered-prompt assumption
should be checked once on the target, for example by comparing
`llama-completion --verbose-prompt` token counts for one case per model.

**Context coverage (2026-11-07).** With the pinned b11669 tokenizer, prompts range
from 116 to 5660 tokens, and counts are identical for both models. Including the
128 reserved output tokens, the number of cases that fit is:

| Context | Development (per family) | Held-out (per family) |
|---:|---:|---:|
| 512 | 3/10 | 2/10 |
| 1024 | 6/10 | 4/10 |
| 2048 | 6/10 | 4/10 |
| 4096 | 8/10 | 7/10 |
| 8192 | 10/10 | 10/10 |

With 512–4096 only, no arm could reach the 9/10 held-out gate, so 8192
(SmolLM2's trained context) is now a study context. Fixed arms default to
`fixed_context` 8192, the only context every case fits. Fixed arms therefore
fail on memory, not on input length. The tuned arm still picks its context per
cap from development data, and the adaptive arm starts at 8192 and halves.

## Running an arm

`scripts/run_quality_arm.py` runs one policy at one cap and writes
`records.jsonl` and `run.json` for `ingest`. **It launches real inference**, so
use it only for an authorized experiment.

```sh
python3 scripts/run_quality_arm.py --bundle state/quality/frozen-study \
  --policy adaptive_input_gate --cap-mib 1536 \
  --model smollm2-1.7b-q4=models/SmolLM2-1.7B-Instruct-Q4_K_M.gguf \
  --model smollm2-360m-q4=models/SmolLM2-360M-Instruct-Q4_K_M.gguf \
  --calibration state/calibration.tsv --nanoclaw bin/nanoclaw-next \
  --out state/quality/runs/adaptive-1536 --drop-caches
```

Before any launch, the driver checks that model and calibration files match the
manifest hashes. Each request then runs `nanoclaw-next bench --runs 1
--freeze-calibration` in a fresh directory. The directory holds a generated
config (the manifest's `backend_arguments` as `llm_cmd`, plus only the arm's
models) and keeps the raw argv, stdout/stderr and request sidecar.

- **Fixed and tuned arms** configure one model at the frozen context and pass
  `--available-mb` large enough to disable adaptation. The kernel cap is the
  only memory limit, and an OOM kill ends as `backend_failed`.
- **The adaptive arm** configures both models with `--ctx 8192`. `--min-ctx` is
  the smallest study context that fits every model's rendered prompt plus the
  output tokens. That is the input gate; there is no truncation.
- **Inputs that cannot fit** are recorded as `context_ineligible` and never launched.

`--launcher systemd` (the default) needs Linux with a systemd user manager. It
wraps each request in a scope with `MemoryMax=<cap>M`, `MemorySwapMax=0` and
`OOMPolicy=continue`, and records `memory.peak` and the `oom_kill` delta.
`--drop-caches` runs `sudo -n` page-cache clearing before each request; it is
meant for the VM only. `--launcher none` runs uncapped and leaves cgroup fields
null, so its results stay provisional. Use it only for development smoke tests,
with `--limit N`.

Run each policy/cap pair into its own output directory, in the manifest's
declared ordering. Then ingest each one with the bundle's frozen scorer.

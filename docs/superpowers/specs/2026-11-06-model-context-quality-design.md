# Model versus context under a memory budget

Status: proposed design for review; no new inference experiments authorized or run.

## Intent

Determine when keeping a stronger model with less context completes more tasks
correctly than switching to a smaller model with more context. Establish this for
a declared workload, not as a guarantee about arbitrary prompts. This implements
the direction in docs/QUALITY_EVALUATION.md and brings part of M3 forward.

## Approaches

1. Build a bounded, labeled model/context comparison first (recommended direction
   accepted for starting work). It provides interpretable evidence and exposes
   measurement errors before adding policy complexity.
2. Add KV-cache quantization first. Potentially preserves a stronger model, but
   introduces backend support and quality variables before scoring exists.
3. Add live PSI-triggered switching first. Addresses changing availability, but
   cancellation, restart cost and lost progress complicate causal comparisons.

Proceed with approach 1. The detailed design below remains proposed. Persistent
serving, KV-cache compression and pressure-triggered switching are later studies.
Maintenance features and operational tool execution remain outside this study.

## First implementation: complete request accounting

Preserve existing child metrics for compatibility and label them explicitly.
Add a monotonic total request duration including planning, prompt preparation,
failed attempts and retries. Record each attempted model/context, outcome, exit
status or signal, child duration and peak RSS, including terminal failures.
Keep scheduler refusal distinct from backend failure and model-generated refusal.

Use one absolute request deadline. Before planning and spawning each retry,
compute the remaining budget; do not reset the deadline. Exhausted deadlines end
the request. Keep the configured per-child timeout as an additional upper bound.
Expose deadline overrun rather than claiming a strict real-time guarantee.

Record maximum child RSS across attempts as a distinct statistic; it is neither
sum-of-RSS nor whole-workload memory. Linux experiment wrappers record cgroup
memory.peak, OOM counters and cap/swap settings across the complete workload.
Controller size, controller runtime memory, child RSS and cgroup charge remain
separate. Missing measurements are null, never zero.

Use fake backends for implementation tests: delayed failure then success, deadline
exhaustion, terminal failure and a failed attempt with higher RSS than the final
attempt. Verify actual orchestration, not only arithmetic helpers. No models or
VMs are needed for these checks.

## Evaluation artifacts

Author an initial suite of 60 cases: 20 structured extraction, 20 evidence-based
diagnosis/selection from supplied options, and 20 insufficient-evidence or
instruction-in-log cases. These are research fixtures; nothing executes commands.

Split each family into 10 development and 10 held-out cases. Split underlying
scenario templates before producing wording or length variants, so variants of
one scenario cannot leak across the split. Freeze versioned cases and labels
before policy comparison. Sixty cases are a pilot, not broad validation.

Each case stores an ID, family, scenario group, split, exact prompt, expected
structured fields, acceptable alternatives, evidence spans, permitted decisions
and refusal expectation. Diagnosis uses supplied identifiers and evidence IDs
for deterministic scoring. Free-text explanations are preserved but exploratory.

Vary evidence length and placement across cases, including separated required
events and irrelevant distractors. Record exact rendered prompt tokens for each
model's tokenizer and chat template. Context requirements include template and
special-token overhead plus reserved output tokens. Do not estimate these from
characters or silently truncate the input. A configuration that cannot fit the
complete input is ineligible and recorded as such. This first study reduces
unused context capacity; lossy summarization/truncation is a separate experiment.

Preserve raw responses, rendering, backend logs, scores and provenance in a
versioned run directory. Scoring must work offline against saved responses.
Malformed structured output is invalid even if a substring looks correct.
Distinguish incorrect answers, invalid outputs, correct refusals, unnecessary
refusals, backend failures and context-ineligible configurations.

## Comparison contract

Begin with the existing SmolLM2 1.7B and 360M Q4_K_M assets, subject to later run
authorization. Do not download models. Pin hashes, llama.cpp build, CPU settings,
threads, sampling, template, output budget and calibration snapshot.

Compare fixed large at full context, fixed small at full context, a large-model
context configuration tuned on development cases, and the existing adaptive
scheduler. Full context is 4096; candidate contexts are 512, 1024, 2048 and 4096.
Use 128 output tokens for these deliberately short structured tasks. The tuned
baseline must respect the same complete-input rule and be frozen before held-out
evaluation. Document current backend fitting behavior and all explicit settings.

On development cases, sweep all eligible model/context pairs at each authorized
cap. Choose one large-model context per cap by most correct supported tasks,
then fewest invalid/forbidden outputs, then lowest median total latency, then
lowest context. Ineligible cases remain in the denominator. Freeze this baseline
before held-out evaluation; it does not select a different context per request.

For the existing adaptive policy, the harness inspects its planned selection and
checks eligibility with that selected model's tokenizer. An ineligible selection
is recorded without launching inference or trying a different context. Label this
arm "existing scheduler with input eligibility gate". The gate prevents silent
input loss without pretending the existing scheduler is prompt-aware. A later
prompt-aware policy is a separately named arm, developed only on development
cases, with candidate-specific required context.

Proposed cap grid: 1.5, 2 and 3 GiB in the existing Linux environment, with swap
disabled. Final feasible caps, run count and cache procedure must be frozen in
the execution manifest before any evaluation, after environment inspection and
explicit authorization. Do not create or resize a VM as part of implementation.
Start with cold process runs; page-cache state is a separate declared dimension.
Warm persistent serving requires its own comparison.

Freeze calibration during evaluation. Do not feed held-out measurements back
into policy tuning. Use paired cases and balanced policy ordering. Report every
case and configuration, including failures; repetitions measure runtime variation
and do not count as independent task cases.

## Decision rule and acceptance

First establish the observed correctness/memory/latency tradeoff. Do not train a
new router before the baseline matrix exists. On development data only, propose
a simple rule using prompt length and task family, then freeze it for held-out
evaluation. Model self-confidence is not a correctness label.

Proposed pilot quality floor: at least 9/10 held-out cases correct in each family
and zero selections outside the fixture's permitted actions. Publish exact counts
and uncertainty; this small sample cannot establish a population safety rate.
Report supported-task correctness and appropriate refusal separately, preventing
an always-refuse policy from passing. A policy failing the floor is rejected for
this workload regardless of memory savings. If no policy passes, report that
result rather than relaxing thresholds after observing outcomes.

Primary outcome: correct supported tasks completed per submitted supported task
under each cap. Secondary outcomes: correct refusals, invalid outputs, forbidden
selections, OOMs, other failures, context ineligibility, request p50/p95, deadline
misses, maximum child RSS and whole-workload cgroup peak. Report failure durations
as well as successful-request latency. Keep hardware/model/backend and cold/warm
conditions attached to every result.

## Delivery sequence and boundaries

1. Implement and test request accounting and remaining-deadline behavior.
2. Author the versioned task schema, fixtures, offline scorer and run manifest.
3. Validate scorer behavior with saved synthetic responses; verify fixture splits
   and provenance without inference.
4. Present the exact experiment matrix and resource requirements for authorization.
5. Run the authorized comparison, preserve evidence and report positive or
   negative results. Only then propose a quality-aware scheduler change.

Builder choices: file organization, structured output encoding, test helpers and
internal result types. Preserve public CLI compatibility where practical and
version any changed report schema. No success claim is made by this document.

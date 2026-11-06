# Evaluate memory efficiency without losing task usefulness

Status: protocol for future research; no new evaluations were run to create it.

## Question

Given the same device, workload and total memory limit, which policy completes useful tasks correctly? A lower RSS figure or fewer failed processes is insufficient if answers become wrong, incomplete or unsuitable for execution.

## Baselines

Compare a fixed larger model, a fixed smaller model, tuned single-model serving, and the adaptive scheduler on identical tasks. Declare backend build, model hashes/quantization, rendered prompt, context, output limit, sampling, thread count, cache state, process lifetime and resource cap. Report cold and warm operation separately. Include a tuned baseline rather than only an oversized configuration with adaptation disabled.

Policies worth investigating include keeping a stronger model while adjusting context, KV-cache representation, batching/concurrency, idle-model residency and persistent inference. These are research candidates, not claims that they currently ship.

## Task families and scoring

| Task family | Evidence of a correct result |
|---|---|
| Structured extraction from diagnostic text | Required fields match a labeled fixture; unsupported fields remain unknown |
| Explain a system failure | Explanation cites the relevant supplied events and distinguishes evidence from hypotheses |
| Recommend a diagnostic step | Recommendation addresses the fixture's fault and respects permitted capabilities |
| Suggest a maintenance procedure | Procedure identifier and arguments match an approved fixture; unsupported actions are refused |
| General instruction following and reasoning | A predefined task-specific rubric checks correctness, completeness and constraints |
| Insufficient context / malicious log content | Model reports uncertainty or refuses unsupported action; embedded instructions do not become commands |

Freeze task cases, labels/rubrics, baseline configurations, quality-floor criteria and repetition counts before comparing policies. Keep policy-tuning and final evaluation cases separate. Publish misses, refusals, truncations and invalid outputs as well as successes. Do not claim the suite validates real cyberattack detection.

## Required report

Report task correctness and successful task completions, invalid/unsafe recommendations, correct refusals, OOM/failure rate, total end-to-end latency, peak process RSS, whole-workload cgroup charge and model/context choices. Latency includes failed attempts and retries. Show quality versus memory across policies, not a single aggregate winner without its workload.

A proposed memory optimization advances only when its quality impact is measured and acceptable for the stated task. A model that fits but fails the quality floor is not an acceptable substitution. Refusing an unsupported task can be preferable to producing a confident incorrect action.

## Existing evidence and gaps

The November 2026 VM experiments measured RSS accuracy and completion on one short prompt. The 54-run Q4/Q5/Q8 grid is not 54 distinct tasks and does not establish general answer quality. Earlier command-generation observations already showed incorrect output from the 360M model. See the [current plan](PLAN.md) and [benchmark reports](benchmarks/2026-11-06-quantization-grid/REPORT.md).

# M2: quantization/context calibration grid (2026-11-06)

The calibrated estimator met the **under-10% RSS-error target on this Ubuntu VM grid**: 54/54 held-out runs completed, zero OOM kills, maximum absolute error **0.0583%**. This closes the VM portion of the quantization/context measurement step. Physical Pi validation and the PSI-pressure policy/experiment remain outstanding.

## Method

- Apple M3 Pro host with 18 GiB RAM; Multipass 1.16.4, QEMU driver, Ubuntu 24.04 ARM64. The existing VM was temporarily enlarged to **8 GiB** with four vCPUs. Each inference/calibration command ran in a real **6 GiB** cgroup, swap disabled, `OOMPolicy=continue`. This grid measures unconstrained RSS accuracy; it does not repeat the earlier 1.5 GiB-cap comparison.
- Same unchanged NanoClaw runtime as `7d5643b`, compiled with Zig 0.15.2 for `aarch64-linux-musl`, ReleaseSmall. Official CPU-only llama.cpp `b11669`, commit `620d2225c`, as in the [first VM experiment](../2026-11-05-linux-vm/REPORT.md).
- SmolLM2-Instruct **1.7B and 360M**, each at **Q4_K_M, Q5_K_M, Q8_0**. All six GGUFs were SHA-256 verified. [models.json](models.json) includes exact sizes, hashes, source repositories and pinned revisions from the publishers' model metadata: [1.7B](https://huggingface.co/bartowski/SmolLM2-1.7B-Instruct-GGUF), [360M](https://huggingface.co/bartowski/SmolLM2-360M-Instruct-GGUF).
- Prompt: “Explain what swap memory is in two sentences.” Maximum 64 tokens, greedy temperature 0, requested seed 1, chat template, single turn, `-ngl 0`, `-t 4 -tb 4 --fit off`. Every held-out run generated 63 tokens. The VM page cache was cleared before each calibration command and each held-out inference; downloads finished before measurements began.
- Each model got a **separate calibration store**, created by NanoClaw's actual `calibrate` command at contexts **512 and 4096**. The two samples were then frozen. Contexts **1024, 2048 and 8192** were held out, with **three independent process runs per model/context**, sequentially. Total: **12 calibration samples + 54 held-out runs**.
- Predicted bytes use the production rule: GGUF file size + GGUF-derived f16 KV bytes/token × context + calibrated overhead. The external calculation was cross-checked against NanoClaw's actual `plan` output for all 18 model/context choices, and KV coefficients were checked against `probe`. The dry-run `plan` call supplied `--available-mb 8192` solely to print each prediction; backend measurements used the real 6 GiB cap.
- GNU `time` obtains child peak RSS in KiB; multiplying by 1024 gives the measured bytes. Signed error is `(predicted − measured) / measured × 100`. The table uses the maximum **absolute** error over nine held-out runs per model. Predictions were not updated with held-out observations.

## Results

All memory figures below are MiB. Calibration endpoints are training observations, not independent validation. The 8192-context range covers three held-out repetitions.

| Model size | Quantization | Calibration RSS, ctx 512 / 4096 | Held-out RSS, ctx 8192 | Worst held-out error |
|---|---|---:|---:|---:|
| 1.7B | Q4_K_M | 2140.8 / 2813.1 | 3581.0–3581.2 | 0.0157% |
| 1.7B | Q5_K_M | 2464.7 / 3137.0 | 3905.1–3905.2 | 0.0105% |
| 1.7B | Q8_0 | 3599.4 / 4271.8 | 5039.7–5040.0 | 0.0107% |
| 360M | Q4_K_M | 415.5 / 555.5 | 715.5–715.7 | 0.0583% |
| 360M | Q5_K_M | 438.7 / 578.5 | 738.7–738.7 | 0.0540% |
| 360M | Q8_0 | 787.7 / 927.9 | 1087.9–1088.0 | 0.0327% |

Raw [measurements.csv](measurements.csv) contains every held-out observation, including context 1024/2048, exact byte values, generated tokens and elapsed time. [summary.json](summary.json) contains per-model maxima and means. [calibrations.tsv](calibrations.tsv) preserves the 12 training observations; [production-plans.log](production-plans.log) preserves the actual CLI prediction traces. [cgroup-events.json](cgroup-events.json) records cap/swap settings, peak charges and before/after OOM counters for every held-out run. Peak RSS and cgroup charge are distinct measurements.

## Limits of this result

The very small errors are observed for this fixed short prompt, this backend build and CPU configuration, and a per-model calibration on the **same device**. They show that the KV-context term extrapolates accurately here, not that all prompts, architectures, GPUs, engines or devices will have this error. The 10% target is met for this measured grid, not established universally. Only three repetitions per held-out context were used.

The 1.7B Q8 model at context 8192 uses about **5 GiB RSS**. It was measurable because the VM was enlarged; it is not a claim that this configuration fits a 4 GB Pi. The production estimator's conservative behavior under memory pressure is a different question: Linux can reclaim mapped weights, so unconstrained RSS can exceed the minimum charged footprint under a tight cap. See the previous experiment's caveats.

No scheduler, estimator, backend or pressure-policy behavior changed. PSI is still observed but is not a scheduling input. The ramping memory-hog experiment and pre-emptive switching behavior remain unimplemented, and these data do not close M2's physical-hardware requirement or measure answer quality.

## Reproduction and preserved artifacts

[run-grid.py](run-grid.py) is the exact measurement driver; [download-models.py](download-models.py) retrieves and verifies the pinned files in [models.json](models.json). Both expect the prepared VM layout from the first report: project `/home/ubuntu/NanoClaw`, executable `bin/nanoclaw-next`, llama.cpp `/home/ubuntu/llama-b11669/llama-completion`, Python 3.11+, curl, GNU `time`, working systemd user scopes and passwordless sudo **inside the VM** for page-cache clearing.

The scripts, GGUFs and original raw logs are retained in VM `nanoclaw-m2`. Full raw output, command arguments, calibration traces and the token-counter instrumentation preflight are also saved locally in `state/m2-grid-2026-11-06/evidence.tar.gz` (ignored by Git). The main benchmark uses the corrected counter parser, which accepts llama.cpp performance lines reporting generation as `runs` or `tokens`; all 54 observations passed the token-count check.

To run the preserved driver again:

```bash
multipass stop nanoclaw-m2
multipass set local.nanoclaw-m2.memory=8G
multipass start nanoclaw-m2
multipass exec nanoclaw-m2 -- python3 /home/ubuntu/run-grid.py
```

The driver resumes complete samples in `state/m2-grid-2026-11-06/`. To collect a completely new grid, first archive/rename that directory inside the VM. It refuses to silently reuse a partial calibration. To prepare the models on another equivalently configured VM, copy `models.json` to the project's `state/grid-manifest.json` and run `download-models.py`; that script verifies file size and SHA-256 before installing each download into `models/`.

After collecting the evidence, the VM was stopped and its configured RAM restored to **4 GiB**. Retained models consume guest disk space, not running host RAM.

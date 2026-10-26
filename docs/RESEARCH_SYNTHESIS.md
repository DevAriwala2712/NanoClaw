# Research Synthesis: Local LLM Inference on Memory-Constrained Edge Devices

_Date: 2026-10-26 · Method: desk research + code audit · Status: hypotheses, not validated with users_

## Research overview

**Question.** Where do people running LLMs on small devices (Raspberry Pi 5, Jetson, old laptops, mini-PCs) get stuck, and which of those problems is NanoClaw-Next positioned to solve better than existing tools?

**Sources.**

| Type | Sources | Notes |
|---|---|---|
| Code audit | This repository (all of `src/`) | Built and cross-compiled with Zig 0.15.2 |
| Benchmarks / guides | Pi 5 llama.cpp and Ollama write-ups, Stratosphere IPS Pi 5 study, tinyweights.dev, noze.it | Mostly practitioner blogs; numbers conflict |
| Issue trackers | Ollama issue #3460 and troubleshooting docs | Crash-on-allocation reports |
| Landscape | OpenClaw "lightweight variant" round-ups (NullClaw, PicoClaw, ZeroClaw, NanoClaw) | Project claims, unverified |
| Research | arXiv 2405.17670 (LLMs controlling mobile robots at the edge) | Motivation for offline operation |

**Confidence caveat.** There are no interviews, surveys or telemetry here. Every finding below is supported by secondary sources. Treat it as a set of hypotheses to validate with 5–8 real edge users before committing to a large roadmap.

## Key findings (ordered by frequency × impact)

### 1. Memory, not compute or binary size, is the binding constraint on small devices
- **Evidence:** One guide calls the 8 GB Pi 5 the practical minimum for 2–3B models. On 4 GB, models under 1.5B fit comfortably, while 3B models at normal context sizes push into swap. The OS, the runtime and the KV cache all compete for what's left after the weights load.
- **Frequency:** Nearly every Pi or Jetson guide reviewed.
- **Impact:** High. Exceeding memory means swap-thrash (latency collapses) or an OOM kill (the request is lost).
- **Confidence:** High.

### 2. Existing tools fail hard instead of degrading
- **Evidence:** Ollama issue #3460: on an allocation failure the server throws and terminates. Workarounds are all manual: lower `num_ctx`, lower `num_gpu`, quantize the KV cache, cap loaded models, or "switch to a less resource-intensive model".
- **Frequency:** Recurring theme in troubleshooting guides.
- **Impact:** High for unattended devices (kiosks, robots, home hubs), where nobody is present to retune.
- **Confidence:** Medium. Ollama does some automatic offload backoff for GPU layers, but nothing found picks a smaller model or context on its own.

### 3. Today's knobs are static; the device's memory is not
- **Evidence:** `OLLAMA_MAX_LOADED_MODELS`, `keep_alive`, llama-swap configs and `num_ctx` are all set ahead of time. Free memory on a shared edge box changes minute to minute (camera pipelines, browsers, other services). Ollama's eviction is reactive and based on estimates.
- **Impact:** Medium–high. Users either over-provision (a small model wastes capacity) or under-provision (crashes).
- **Confidence:** Medium.

**Update (2026-10-26, verified locally on llama.cpp 0.7.0 via Homebrew):** llama.cpp now ships `--fit` (on by default). It adjusts GPU layer offload and context size (floor `--fit-ctx`, default 4096) so *one given model* fits device memory, with a default 1 GiB margin. That covers part of this gap inside a single model. Going by its `--help`, it doesn't choose between models, plan around a latency deadline, go below 4096 context unless told to, or retry after an OOM kill. NanoClaw-Next's contribution has to be framed as the layer above `--fit`: model choice, deadlines, sensitivity and recovery, not "llama.cpp can't fit memory".

### 4. The KV cache is the hidden memory cost people under-estimate
- **Evidence:** Guides list context length and KV cache quantization as the first OOM fixes. KV memory grows linearly with context: `2 × layers × ctx × kv_heads × head_dim × bytes`. For a ~1B model at 8k context that is hundreds of MB on top of the weights.
- **Impact:** High. It's the cheapest lever, since shrinking context costs far less quality than shrinking the model.
- **Confidence:** High (follows directly from the architecture).

### 5. Latency budgets matter as much as memory for interactive and robotic uses
- **Evidence:** Pi 5 throughput is about 5–15 tok/s for 1–1.5B models and 2–5 tok/s for 3B. Thermal throttling without active cooling costs another 20–30%. Voice assistants and robot control have hard response windows.
- **Impact:** Medium–high. A slow answer can be as useless as no answer.
- **Confidence:** Medium. Numbers vary widely by setup.

### 6. Privacy and offline operation are the reason to run at the edge at all
- **Evidence:** Regulated sectors (healthcare, defense, legal) can't send data to cloud APIs. Robots and field devices can't count on connectivity. Hybrid local-plus-cloud setups are becoming the norm.
- **Impact:** Strategic. Defines who the buyer is and why "fall back to cloud" must be opt-in and blocked for sensitive data.
- **Confidence:** Medium.

### 7. The "tiny agent harness" niche is saturated and measures the wrong thing
- **Evidence:** NullClaw (Zig, ~678 KB), PicoClaw (Go, <10 MB RAM), ZeroClaw (Rust, ~3.4 MB). All get their small footprint by calling cloud models. The harness is under 0.1% of memory next to a local model.
- **Impact:** High for positioning. Competing on binary size doesn't differentiate.
- **Confidence:** High.

### 8. NanoClaw-Next's current code doesn't yet address any of the above
- **Evidence (audit):** "VRAM" was hardcoded constants; model files were never opened; cloud routing returned a made-up string; the sandbox printed "seccomp enforcement active" without applying any isolation; timeouts were checked only before and after a blocking call; the skill and fallback paths were no-ops.
- **Impact:** High. Any reviewer who reads the code will discount the whole project.
- **Confidence:** High (verified by reading every file).

## Measured findings (added 2026-10-26, real models on an Apple Silicon Mac)

| # | Finding | Evidence | Confidence |
|---|---|---|---|
| M-1 | GGUF metadata predicts KV-cache growth exactly | Measured slopes of 192 KB/token (1.7B) and 40 KB/token (360M) match the formula | High |
| M-2 | Static overhead guesses are dangerous; per-device calibration is needed | Default guess under by 44% for the 1.7B; CPU repacking keeps a second weight copy (2214 → 1210 MB with `--no-repack`); after one calibration run, a held-out context is predicted within 2 MB | High (one device) |
| M-3 | Latency is dominated by fixed startup for short answers | 1.7B: ~800 ms startup vs ~1.3 s generation for ~100 tokens; ignoring it caused a deadline kill | High |
| M-4 | The smallest model is not a safe "executor" | 360M wrote `ls /dev/disk/by-id/` for "show free disk space"; 1.7B wrote `df` | Medium (a handful of prompts) |
| M-5 | llama.cpp now fits a single model to memory itself (`--fit`) | `llama-completion --help`, llama.cpp 0.7.0 | High |

Implication: the defensible contribution is **measured, explainable choice between models under memory, latency and sensitivity constraints, with recovery**, not "fitting a model into memory", which llama.cpp increasingly does itself.

## User segments (hypothesised)

| Segment | Device | Job to be done | What breaks today |
|---|---|---|---|
| **Hobbyist/maker** | Pi 5 4–8 GB | Offline voice assistant or home automation | Picks a model by trial and error; it OOMs when other services run |
| **Robotics / field engineer** | Jetson Orin, Pi CM5 | Natural-language command → action within a time limit | Needs a guaranteed response time; can't babysit crashes |
| **Privacy-bound team** | Mini-PC or old laptop on-prem | Local summarisation or classification of sensitive text | Cloud is forbidden; hardware is mixed; needs predictable behaviour |
| **Edge-AI student/researcher** | Whatever is at hand | Benchmark and compare runtimes reproducibly | No common harness for "same workload, same box, measured memory" |

## Opportunity areas

| # | Opportunity | Unlocks | Impact | Feasibility |
|---|---|---|---|---|
| O1 | **Measure before deciding:** read real available memory (MemAvailable, cgroup limit, pressure stall info) | Everything else; turns hardcoded constants into facts | High | High |
| O2 | **Know each model's true cost:** parse GGUF metadata to compute weights + KV cache per context length | Accurate fit checks without loading the model | High | High |
| O3 | **Adaptive selection ladder:** for a request with a context need and a deadline, choose model × context; shrink context first, then model, then cloud (only if not sensitive), then refuse with a reason | The core differentiator: degrade instead of crash | High | High |
| O4 | **Learn from runs:** record measured peak RSS and tokens/s per model and feed them back into the estimates | Estimates converge to reality per device | Medium–high | High |
| O5 | **Graceful runtime failure:** detect OOM kill or timeout and retry one rung down | Unattended reliability | High | Medium |
| O6 | **Reproducible benchmark:** a `bench` command plus a cgroup-capped comparison against llama-server | Evidence; credibility | High | Medium |
| O7 | **Real isolation for tool execution** (Landlock + seccomp) | Safe agentic use | Medium (agent use only) | Medium; needs Linux testing |
| O8 | Agent features (memory hierarchy, skills, fallback chains) | Agent UX | Low until O1–O6 exist | — |

## Recommendations

1. **Reposition** from "<2 MB agent OS" to an **adaptive edge-inference scheduler on top of llama.cpp**. Findings 1, 2, 3, 7.
2. **Build O1–O5 now** as pure, unit-tested Zig modules. That's the smallest slice that's both true and differentiated.
3. **Make every claim measurable.** Replace marketing claims with numbers from `bench`, with the method documented. Findings 7, 8.
4. **Stop claiming isolation** until Landlock or seccomp is real and tested on Linux. Use an executable allowlist and hard-kill timeouts in the meantime. Finding 8.
5. **Pause agent features** (O8) until the scheduler wins a benchmark.
6. **Consider a rename.** "NanoClaw" collides with an established project. Candidates: _EdgeMorph_, _NanoEdge Runtime_; availability not checked.

## Open questions

- Do real users prefer a **smaller model at full context** or a **bigger model at reduced context** when memory is tight? Interview robotics and assistant builders; A/B on task success.
- How accurate are GGUF-based estimates against measured peak RSS across quant types and backends (CPU vs Metal/CUDA)? Needs Pi 5 and Jetson measurements.
- Is pressure-stall info (PSI) a better trigger than MemAvailable for pre-emptive step-down? Needs a cgroup stress experiment.
- Would users accept cloud fallback with a per-request "sensitive" flag, or does it have to be off globally?

## Sources

- [Stratosphere IPS – LLM performance on Raspberry Pi 5](https://stratospherelinuxips.readthedocs.io/en/develop/immune/research_rpi_llm_performance.html)
- [tinyweights.dev – Run LLMs on Raspberry Pi 5](https://tinyweights.dev/posts/run-llms-raspberry-pi-5/)
- [Ollama vs llama.cpp on Raspberry Pi 5](https://medium.com/@omkar121212/ollama-vs-llama-cpp-on-raspberry-pi-5-8e7fbeb310de)
- [SitePoint – LLMs on Raspberry Pi at the edge](https://www.sitepoint.com/llms-raspberry-pi-edge/)
- [Ollama issue #3460](https://github.com/ollama/ollama/issues/3460)
- [localaimaster – Ollama out-of-memory errors](https://localaimaster.com/blog/ollama-out-of-memory-errors)
- [noze.it – Edge AI on Raspberry Pi with Ollama and llama.cpp](https://www.noze.it/insights/raspberry-pi-edge-ai-ollama/)
- [zylos.ai – Edge AI on-device LLMs (2026)](https://zylos.ai/research/2026-01-10-edge-ai-on-device-llms)
- [arXiv 2405.17670 – LLMs controlling mobile robots at the edge](https://arxiv.org/html/2405.17670v3)
- [lucaberton.com – Private offline edge assistants](https://lucaberton.com/blog/edge-ai-llm-private-assistants-offline/)
- [hongkiat – OpenClaw alternatives](https://www.hongkiat.com/blog/?p=74251)
- [It's FOSS – OpenClaw alternatives for Pi-class devices](https://itsfoss.com/openclaw-alternatives/)
- [ClawDocs – Lightweight variants](https://clawdocs.org/guides/lightweight-variants)

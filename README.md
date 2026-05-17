# NanoClaw-Next: The <2MB, zero-dependency, dynamically swapping AI operating system for the extreme edge.

Runs flawlessly on a Raspberry Pi 5 with under 2GB VRAM.

## Why NanoClaw-Next?

### 1. True Zero-Dependency Static Binary (<2 MB)
Unlike standard OpenClaw, which requires heavy Node.js or Python runtimes and 16GB of RAM just to operate smoothly, NanoClaw-Next is compiled entirely in Zig as a single static binary. It requires absolutely no external dependencies, no Python environments, and no Docker containers. You simply drop the sub-2MB executable onto a Raspberry Pi 5 or an old mobile SoC, and it runs instantly bare-metal.

### 2. VRAM-Aware Dynamic Model Swapping (Role-Based Orchestration)
Standard edge agents often crash because they try to load a single, massive model into limited memory, leading to out-of-memory errors and extreme latency. NanoClaw-Next solves this with an aggressive model-swapping engine:
* **The Planner:** It temporarily loads a highly compressed 1.7B parameter planner model (consuming just ~1100 MB of VRAM) strictly to break down the user's task into steps.
* **The Executor:** Once the plan is made, the planner is instantly unloaded to free up memory, and a hyper-efficient 360M parameter micro-execution model (consuming just ~450 MB of VRAM) takes over to use tools and execute the loop. This keeps peak VRAM usage well under 2GB, allowing continuous, crash-free execution on resource-constrained devices.

### 3. Edge-Cloud Collaborative Routing
NanoClaw-Next features a built-in routing engine that intelligently evaluates a task's computational load and sensitivity. Simple tool executions and tasks involving Personally Identifiable Information (PII) are processed entirely locally on the 360M executor to guarantee absolute privacy. However, if the agent faces complex reasoning tasks beyond the local model's cognitive capacity, it seamlessly routes the request to powerful cloud endpoints.

### 4. Military-Grade Architectural Security
Giving an AI agent shell access is historically dangerous due to prompt injection risks. NanoClaw-Next is secure by default. It utilizes a bare-metal seccomp-bpf and namespace-based isolation sandbox to strictly isolate the agent's execution loop at the OS level. This ensures that even if a malicious skill is loaded or the LLM hallucinates a dangerous command, the operating system intercepts and neutralizes the action before it can execute.

### 5. Superior to Existing Edge Alternatives
While projects like PicoClaw have proven that $10 edge AI is possible, they rely on a Go-based runtime (<10MB footprint) and rigidly map to a single small model. NanoClaw-Next is the "Pro" evolution: its Zig foundation allows for a much smaller footprint (<2MB), and its dynamic multi-model orchestration ensures it isn't trapped by the cognitive limits of a single micro-model.

### 6. Flawless Developer Experience
The developer loop is stupidly simple. No massive npm install trees or dependency hell. You run `./nanoclaw init` to generate your config, and run the binary.

---

## What You Need

Build dependency:
1. Zig 0.15.2

## Setup & Install

macOS:
```bash
brew install zig
```

Linux:
1. Download Zig 0.15.2 from the official download page.
2. Add the Zig binary to your PATH.

**First-Time Setup:**
From project root, run:
```bash
./scripts/setup.sh
```
This checks your Zig version, compile-checks the project, and creates default runtime state via `init`.

## How to Run

1. **Initialize Config:** (if you skipped the setup script)
```bash
zig build run -- init
```

2. **Run One Runtime Cycle:**
```bash
zig build run -- run
```

3. **Check Status (LLM mode, VRAM budget):**
```bash
zig build run -- status
```

4. **Run Built-in Verification (Self-test):**
```bash
zig build run -- selftest
```

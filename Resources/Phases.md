To provide an unambiguous blueprint for AI coding assistants (like Cursor or Copilot), here is the comprehensive, in-depth breakdown of all five phases of the **NanoClaw-Next** architecture. 

This guide explicitly defines the architectural invariants—what the AI must build (**To Implement**) and the strict anti-patterns it must avoid (**What NOT to Implement**).

### Phase 0: Foundation (Core Execution Environment)
The goal is to establish a bare-metal, ultra-lightweight environment that completely bypasses the dependency and bloat issues of traditional Python/Node.js deployments.

*   **To Implement:**
    *   **Zero-Dependency Compilation:** Build the core engine entirely in **Zig**. It must compile into a single static binary targeting `<2 MB` (e.g., using `-target aarch64-linux-musl` and `.ReleaseSmall` optimization). 
    *   **Inference Runtime:** Statically link the `llama.cpp` C API directly into the binary to handle local inference without external API bridging overhead.
    *   **Architectural Sandbox:** Implement a bare-metal `seccomp-bpf` and namespace-based isolation layer. Privilege must be dropped immediately. Ensure strict timeout parameters and explicit rollback paths are wired into the main execution loop.
    *   **Developer Experience:** Create a CLI router that allows a user to run `nanoclaw-next init` to generate a single configuration file, and include a `--demo` flag that prints the Claw lineage marketing hook.
*   **What NOT to Implement:**
    *   **NO Docker:** Do not use Docker or containerization engines; this must run bare-metal on resource-constrained devices like the Raspberry Pi 5.
    *   **NO Interpreters:** Do not include Node.js, Python runtimes, or external dependency manifests like `package.json` or `requirements.txt`.

### Phase 1: Inference Engine & VRAM Orchestration
The goal is to prevent memory crashes (like the `AsyncLLM output_handler failed`) by dynamically managing how models occupy limited VRAM (4–8 GB).

*   **To Implement:**
    *   **VRAM-Aware Context Budgeting:** Build a model-swapping orchestrator that continuously monitors available memory.
    *   **Dynamic Model Swapping:** Implement logic to load a large, aggressively quantized (4-bit or 8-bit) "planner" model *only* for high-level task decomposition. **Crucially, the code must unload this planner model immediately from VRAM once the plan is generated**.
    *   **Micro-Execution Model:** Load a much smaller (e.g., 3.8B parameter) model for the continuous loop of actual tool execution.
    *   **Edge-Cloud Routing:** Implement a router that keeps PII and sensitive data processing purely local, while offloading computationally heavy reasoning or audio tasks to a cloud endpoint when required.
*   **What NOT to Implement:**
    *   **NO Single Monolithic Models:** Do not attempt to map a single, large model to handle planning, evaluation, and tool execution simultaneously.

### Phase 2: Resilient Hierarchical Memory
The goal is to solve "lost in the middle" context degradation and catastrophic database lock/crash errors on long-running edge agents.

*   **To Implement:**
    *   **Lifecycle-Guarded Database:** Implement a SQLite (or similar embedded DB) wrapper using atomic operations. It must include strict lifecycle guards that block new syncs if a shutdown sequence has started and force the system to wait for in-flight syncs to complete before sleeping.
    *   **Just-In-Time (JIT) Context OS:** Build a context manager that uses compression and caching to load *only* the specific knowledge required for the immediate step into the prompt.
    *   **Idle-Time Consolidation:** Create a background thread that runs when the agent is idle to consolidate raw session logs into daily summaries, and then refines them into long-term, machine-readable knowledge.
*   **What NOT to Implement:**
    *   **NO Raw Log Dumping:** Do not append raw, uncompressed chat histories or raw tool execution outputs infinitely into the LLM context window.
    *   **NO Unsafe Async DB Writes:** Do not allow unguarded asynchronous database writes that can cause race conditions or `database is not open` errors mid-task.

### Phase 3: Structural Security & Skill Governance
The goal is to implement military-grade safety at the system architecture level to intercept prompt injections or malicious third-party skills.

*   **To Implement:**
    *   **SafeClaw-R Graph Invariants:** Enforce a strict execution graph where **every functional agent node is physically preceded by a safety enforcement node**. The code must intercept risks (e.g., mass deletion, PII leakage) *before* the command is passed to the OS layer.
    *   **Cryptographically Bounded Skills:** Implement "Safe Skill Factories" applying the principle of least privilege. Skills must be sandboxed so they only access the exact data required for their specific function.
    *   **Specification Engineering:** Build a parser to ingest corporate policies and ethical boundaries as machine-readable knowledge corpora that the safety nodes evaluate actions against.
*   **What NOT to Implement:**
    *   **NO Prompt-Based Safety:** Do not rely on system prompts like "Do not do bad things" to ensure safety. Security must be structural and enforced at the execution/OS level.
    *   **NO Open Shell Access:** Do not grant skills unrestricted shell or filesystem access.

### Phase 4: Intelligent Tool Dispatch & Auto-Correction
The goal is to ensure the agent's workflow never hangs or crashes due to LLM syntax hallucinations or numerical drift caused by quantized models.

*   **To Implement:**
    *   **Context-Aware Auto-Correction Router:** Build a middleware layer that sits between the LLM output and the tool execution. It must perform alias normalization (mapping misspelled or hallucinated tool names back to canonical functions) to silently fix errors without returning an error to the user.
    *   **Multi-Layer Fallback Chains:** Implement automated retry and fallback logic. If a primary tool fails (e.g., a CDP browser search), the code must automatically step down to a fallback tool (e.g., DuckDuckGo HTTP POST, then Bing) to complete the task.
*   **What NOT to Implement:**
    *   **NO Fragile Execution:** Do not fail loudly and halt the agent loop when the LLM outputs a minor syntax error, missing comma, or slightly misspelled tool name.
    *   **NO Public Dashboards:** Do not expose the agent's dashboard or operational setup directly to the public internet during this phase.
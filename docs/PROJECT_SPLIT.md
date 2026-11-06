# Research and product split

Decision date: 2026-11-06. The owner requested two separately focused repositories, retaining the existing research project and deriving a maintenance product from its foundation.

| Repository | Purpose | Primary success measure |
|---|---|---|
| [NanoClaw-Next / NanoClaw](https://github.com/DevAriwala2712/NanoClaw) | Research local-LLM memory estimates, scheduling, context/cache policies and recovery without sacrificing useful capability | Correct tasks completed under declared resource budgets, alongside memory, latency and failure measurements |
| [TUMe](https://github.com/DevAriwala2712/TUMe) | Develop a lightweight Linux edge-device maintenance supervisor: observe, diagnose, recommend, then perform explicitly permitted recovery | Device problems identified and resolved correctly, with low total overhead and an auditable action history |

## Scope of this setup

TUMe is derived from NanoClaw's public `main` at commit `fe65c25e37dab1e1c572aabde08a56467008b952`, including Git history and committed experiment evidence. The owner delegated the choice between TUMe and TUMMe; TUMe is the selected name. No acronym expansion is asserted.

This split establishes repository identity, documentation, ownership of future work and a product roadmap. It does not implement a maintenance daemon, portal, API, cyberattack detector or new inference behavior. Local models, VM state, credentials and ignored experiment directories are not part of the source copy.

## Where work belongs

| Area | Research repository | TUMe |
|---|---|---|
| GGUF memory models, calibration and scheduling experiments | Owns experiments and underlying methods | Adopts validated versions after product integration review |
| Quality under memory pressure | Owns evaluation protocol, datasets and policy comparisons | Uses task-specific checks for diagnosis and permitted actions |
| Persistent inference, KV/context choices and pressure policies | Studies resource/quality tradeoffs | Integrates a supported operational configuration |
| Telemetry, findings, service diagnosis and maintenance procedures | Only experiment fixtures if needed | Owns product implementation |
| Privilege separation, action permissions, runbooks and auditing | Research commands remain experimental | Owns production safety and recovery design |
| Portal, HTTP API, messaging, fleet and security-event integrations | Outside the research project's primary scope | Owns product features as they are implemented |

## Transfer policy

The repositories start with shared history, not a separately published library or a live dependency. No automatic synchronization is configured. Transfer a relevant change through a reviewed commit/cherry-pick or a later versioned interface; record the source commit, affected contract, evaluation evidence and product validation. Do not blindly merge a research branch into a maintenance deployment.

Research evidence keeps its hardware, prompt, model, configuration and date. Copied evidence is not a benchmark of the future TUMe product. Historical agent scaffolding in the source does not establish implemented maintenance functionality.

The unchanged CLI retains some pre-split wording: for example, `probe` reports isolation as "planned, M3." That message refers to the old research roadmap. The current research M3 concerns quality evaluation, and operational isolation belongs to TUMe; the legacy text does not indicate implemented kernel isolation.

## Guardrails

- The research goal is memory efficiency **with measured task usefulness**, not success defined as merely producing text.
- TUMe's monitoring and emergency policies must operate without an available LLM. Model inference is an optional consumer of the device budget.
- Diagnostic evidence is untrusted input. Generated explanations do not grant execution privileges.
- An autonomous recovery action requires a defined procedure, permissions, verification and an audit record; unrestricted generated shell commands are not the product design.
- New experiments, stress tests and model downloads are separately authorized work. This documentation/repository setup does not start them.

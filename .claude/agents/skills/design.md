---
name: design
description: Skill to start the full service design pipeline. Usage: /design <requirements-file> [output=<folder>] [context=<file>]. Parses arguments and invokes design-orchestrator. Use when the user wants to design a new service from a requirements file.
---

Parse the arguments from the skill invocation:
- First positional argument: path to the requirements file (required). If missing, ask: "Please provide the path to your requirements file." Wait for the answer before continuing.
- `output=<path>`: output folder (optional). If not provided, the orchestrator will auto-derive it as an `output/` subfolder next to the requirements file.
- `context=<path>`: optional path to an existing context file to lock the tech stack. Do not ask for this — only use it if the user explicitly provided it.
- Upfront flags: detect if the user said any of these in their invocation:
  - "design only" / "stop at design" → pass as `design_only: true`
  - "no build" → pass as `no_build: true`
  - "no review" → pass as `no_review: true`

Read the full instructions from `.claude/agents/orchestrators/design-orchestrator.md` and execute them yourself in this conversation using the following parameters:
- requirements_file: <requirements_file>
- output_folder: <output_folder_if_provided>
- context: <context_file_if_provided>
- design_only / no_build / no_review: <flags_if_detected>

Do NOT spawn a subagent. Run the orchestrator logic directly so the full pipeline (discovery Q&A → plan mode alternatives → approval → quality gate → fast review → scaffolding → unit tests → full review → production build) happens in one unbroken conversation thread.

**Context budget note**: because the full pipeline runs in a single conversation thread, the accumulated context from all phase outputs (design files, review reports, test results, build output) can approach the context window limit for complex services (10+ components). For complex services, recommend the user use one of these flags to reduce context consumption:
- `design only` — stops after quality gate; no scaffolding or build
- `no build` — stops after full review and implementation plan
- `no review` — skips Phase 5 full review; runs Phase 4b tests then build only

After the user approves an alternative, announce each phase as it starts and run through all phases automatically without asking "proceed?" between them. The only hard pause is the alternative selection in Phase 1.

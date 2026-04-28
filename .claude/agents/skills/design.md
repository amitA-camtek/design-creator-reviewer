---
name: design
description: Skill to start the full service design pipeline. Usage: /design <requirements-file> [output=<folder>] [context=<file>]. Parses arguments and invokes design-orchestrator. Use when the user wants to design a new service from a requirements file.
---

Parse the arguments from the skill invocation:
- First positional argument: path to the requirements file (required). If missing, ask: "Please provide the path to your requirements file." Wait for the answer before continuing.
- `output=<path>`: output folder (required). If not provided, ask: "Where should the output files be written? Please provide a folder path." Wait for the answer before continuing.
- `context=<path>`: existing service-context.md to lock the tech stack (optional). Do not ask for this — only use it if the user explicitly provided it.

Read the full instructions from `.claude/agents/orchestrators/design-orchestrator.md` and execute them yourself in this conversation using the following parameters:
- requirements_file: <requirements_file>
- output_folder: <output_folder>
- context: <context_file_if_provided>

Do NOT spawn a subagent. Run the orchestrator logic directly so the full interactive session (discovery Q&A → plan mode alternatives → approval → pipeline → review → build) happens in one unbroken conversation thread.

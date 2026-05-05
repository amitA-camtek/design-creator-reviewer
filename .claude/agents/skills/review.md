---
name: review
description: Skill to run a service review on a design or codebase. The orchestrator auto-selects the right reviewers based on what the folder contains — no need to choose between fast and full. Usage: /review <folder> [requirements=<file>] [agents=<list>] [force_run_all=true]. Invokes review-orchestrator.
---

Parse the arguments from the skill invocation:
- First positional argument: path to the folder to review (required). If missing, ask: "Please provide the path to the folder you want to review."
- `requirements=<path>`: requirements file for completeness checking (optional)
- `agents=<comma-separated-list>`: explicit agent subset, bypasses auto-skip (optional)
- `force_run_all=true`: run every candidate agent regardless of inputs (optional)

Build the prompt for review-orchestrator:
```
folder: <folder_path>
output_folder: <folder_path>
requirements: <requirements_file_if_provided>
agents: <agents_list_if_provided>
force_run_all: <true_if_flag_provided>
```

Read the full instructions from `.claude/agents/orchestrators/review-orchestrator.md` and execute them yourself in this conversation with the provided parameters. Do NOT spawn a subagent.

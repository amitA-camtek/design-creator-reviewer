---
name: review
description: Skill to run a focused 3-dimension review (requirements, security, storage) on a design or codebase. Usage: /review <folder> [requirements=<file>]. Invokes review-orchestrator. Use when the user wants a fast review without the full 8-dimension analysis.
---

Parse the arguments from the skill invocation:
- First positional argument: path to the folder to review (required). If missing, ask: "Please provide the path to the folder you want to review."
- `requirements=<path>`: requirements file for completeness checking (optional)

Build the prompt for review-orchestrator:
```
folder: <folder_path>
requirements: <requirements_file_if_provided>
output_folder: <folder_path>
```

Read the full instructions from `.claude/agents/orchestrators/review-orchestrator.md` and execute them yourself in this conversation with the provided parameters. Do NOT spawn a subagent.

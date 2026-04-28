---
name: fullreview
description: Skill to run a comprehensive 8-dimension review (all specialist agents in parallel) on a design or codebase. Usage: /fullreview <folder> [requirements=<file>]. Invokes full-validator. Use when the user wants complete coverage across all dimensions.
---

Parse the arguments from the skill invocation:
- First positional argument: path to the folder to review (required). If missing, ask: "Please provide the path to the folder you want to review."
- `requirements=<path>`: requirements file for completeness checking (optional)

Build the prompt for full-validator:
```
folder: <folder_path>
requirements: <requirements_file_if_provided>
output_folder: <folder_path>
```

Read the full instructions from `.claude/agents/orchestrators/full-validator.md` and execute them yourself in this conversation with the provided parameters. Do NOT spawn a subagent.

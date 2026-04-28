---
name: build
description: Skill to build a production project from a completed design package. Usage: /build <output-folder>. Creates fully-implemented source files then builds and runs the project (up to 10 fix cycles). Use after design-orchestrator has completed the full design pipeline.
---

Parse the arguments from the skill invocation:
- First positional argument: path to the design output folder (required). If missing, ask: "Please provide the path to the design output folder."

**Step 1 — Create project files**

Invoke the `production-file-creator` agent with:
```
output_folder: <output_folder>
```

Wait for it to complete. If it reports an error, relay it to the user and stop.

Extract `production_root` from its result.

Tell the user: "Project files created in `{production_root}`. Building now..."

**Step 2 — Build and run**

Invoke the `production-build-runner` agent with:
```
production_root: <production_root>
output_folder: <output_folder>
```

Relay its outcome to the user verbatim.

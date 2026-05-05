---
name: build
description: Skill to build a production project from a completed design package. Usage: /build <output-folder>. Creates fully-implemented source files, runs unit tests, builds the project (up to 10 fix cycles), and runs it. Includes a build-to-design feedback loop (up to 3 outer cycles) if the build fails. Use after design-orchestrator has completed the full design pipeline. (Tools: All tools)
---

Parse the arguments from the skill invocation:
- First positional argument: path to the design output folder (required). If missing, ask: "Please provide the path to the design output folder."

Invoke the `build-orchestrator` agent with:
```
output_folder: {output_folder}
```

Wait for it to complete and relay its final report to the user.

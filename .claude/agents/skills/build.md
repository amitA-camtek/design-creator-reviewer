---
name: build
description: Skill to build a production project from a completed design package. Usage: /build <output-folder>. Creates fully-implemented source files, runs unit tests, builds the project (up to 10 fix cycles), and runs it. Includes a build-to-design feedback loop (up to 3 outer cycles) if the build fails. Use after design-orchestrator has completed the full design pipeline.
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

Tell the user: "Project files created in `{production_root}`. Creating and running unit tests..."

**Step 2 — Unit tests**

Invoke the `test-file-creator` agent with:
```
output_folder: <output_folder>
```

Wait for it to complete.

Invoke the `test-runner` agent with:
```
output_folder: <output_folder>
production_root: <production_root>
```

Wait for it to complete. Read the gate status from the result (ADVANCE / HOLDING).

Tell the user the test summary: pass rate, gate status.

Tell the user: "Building now (up to 10 fix cycles)..."

**Step 3 — Build and run (with feedback loop)**

**Outer loop (max 3 cycles):**

Invoke the `production-build-runner` agent with:
```
production_root: <production_root>
output_folder: <output_folder>
```

Wait for it to complete.

If the build **succeeded**: relay the run report to the user and stop.

If the build **failed**:
1. Read the build errors from `{output_folder}/Production/build-errors.md`
2. For each compiler error, map it back to the originating design section:
   - Check `{output_folder}/pipeline/code-scaffolding.md` for the component name
   - Check `{output_folder}/architecture-design.md` or `{output_folder}/schema-design.md` for the definition
3. Patch the relevant design file with a corrected definition
4. Re-invoke `production-file-creator` to regenerate affected source files
5. Retry the build (next outer cycle)

If 3 outer cycles exhausted: report the remaining errors to the user verbatim and stop.

# Commands Reference

All commands run inside a Claude Code conversation in this workspace.
There are three ways to trigger work: **slash commands**, **natural language**, and **direct agent invocation**.

---

## Slash Commands

Type these exactly in the chat prompt.

### `/design` — Full design pipeline

```
/design <requirements-file> [output=<folder>] [context=<file>]
```

Runs the complete interactive design pipeline: architecture → schema → API → sequences → scaffolding → test plan → review → fix patches.

| Argument | Required | Description |
|---|---|---|
| `<requirements-file>` | Yes | Path to `engineering_requirements.md` |
| `output=<folder>` | No | Where to write output files. Defaults to a folder next to the requirements file. |
| `context=<file>` | No | Path to an existing `service-context.md` to lock the technology stack. Omit to let the agent choose freely. |

**Examples:**
```
/design C:\projects\myservice\req.md
/design C:\projects\myservice\req.md output=C:\projects\myservice\design
/design C:\projects\myservice\req.md output=C:\projects\myservice\design context=C:\projects\myservice\service-context.md
```

**Produces:** `architecture-design.md`, `schema-design.md`, `api-design.md`, `sequence-diagrams.md`, `code-scaffolding.md`, `test-plan.md`, `review-report.md`, `fix-patches.md`, `design-package-summary.md`

---

### `/review` — Service review with smart auto-skip

```
/review <folder> [requirements=<file>] [agents=<list>] [force_run_all=true]
```

Invokes `review-orchestrator`. Up to 9 specialist reviewers are candidates; the orchestrator's smart auto-skip pass runs only those whose inputs are actually present in the folder (e.g. `api-contract-reviewer` is skipped if there is no API; `concurrency-reviewer` is skipped on design-only folders). `security-reviewer` is never skipped.

| Argument | Required | Description |
|---|---|---|
| `<folder>` | Yes | Path to the design output folder or codebase to review |
| `requirements=<file>` | No | Requirements file for completeness checking |
| `agents=<comma-list>` | No | Explicit reviewer subset (e.g. `agents=security,storage`); bypasses auto-skip |
| `force_run_all=true` | No | Disable auto-skip; run every candidate reviewer regardless of inputs |

**Examples:**
```
/review C:\projects\myservice\design
/review C:\projects\myservice\design requirements=C:\projects\myservice\req.md
/review C:\projects\myservice\design agents=security,storage
/review C:\projects\myservice\design force_run_all=true
```

**Produces:** `review/review-report.md` and `review/fix-patches.md`. The report's "Skipped reviewers" section explains why each skipped reviewer was dropped.

---

### `/build` — Build a production project

```
/build <output-folder>
```

Takes a completed design package and produces a fully-implemented, compilable, running service. Creates source files from the design, then builds and auto-fixes compile errors (up to 10 cycles).

| Argument | Required | Description |
|---|---|---|
| `<output-folder>` | Yes | Path to the folder containing the completed design package |

**Example:**
```
/build C:\projects\myservice\design
```

**Produces:** `Production/<ServiceName>/` — a complete, runnable project

---

### `/powerpoint-generator` — Generate a stakeholder presentation

```
/powerpoint-generator <output-folder>
```

Reads the completed design package and produces an 11-slide `.pptx` presentation. Requires Python 3 (installs `python-pptx` automatically if missing).

| Argument | Required | Description |
|---|---|---|
| `<output-folder>` | Yes | Path to the folder containing the completed design package |

**Example:**
```
/powerpoint-generator C:\projects\myservice\design
```

**Produces:** `assets/<service-name>-design.pptx`

---

## Natural Language Triggers

These phrases trigger the same pipelines automatically — no slash command needed.

| Say something like... | What runs |
|---|---|
| "design a new service from this requirements file" | `/design` pipeline |
| "create a design for `<path>`" | `/design` pipeline |
| "review this folder" | `/review` |
| "do a full review of `<path>`" | `/review` (smart auto-skip handles depth) |
| "run a comprehensive review" | `/review` (smart auto-skip handles depth) |
| "build production code from the design" | `/build` |
| "create a PowerPoint for this design" | `/powerpoint-generator` |
| "generate slides for `<path>`" | `/powerpoint-generator` |

---

## Standalone Designers (Direct Agent Invocation)

These are interactive design agents that work in isolation — useful when you want to redesign just one layer without re-running the full pipeline.

Each agent asks discovery questions **one at a time**, presents 3 alternatives in plan mode, lets you iterate freely, and only writes files after you say **"approved"**.

### `@architecture-designer`

```
@architecture-designer requirements_file='<path>' output_folder='<path>'
```

Produces 3 architecture alternatives (differing in coupling/deployment/concurrency model), lets you choose and refine, then writes `architecture-alternatives.md` + `architecture-design.md`.

**Example:**
```
@architecture-designer requirements_file='C:\projects\myservice\req.md' output_folder='C:\projects\myservice\design'
```

---

### `@schema-designer`

```
@schema-designer requirements_file='<path>' output_folder='<path>'
```

Produces 3 schema alternatives (differing in indexing strategy and constraint strictness), lets you choose and refine, then writes `schema-alternatives.md` + `schema-design.md`.

**Example:**
```
@schema-designer requirements_file='C:\projects\myservice\req.md' output_folder='C:\projects\myservice\design'
```

---

### `@api-designer`

```
@api-designer requirements_file='<path>' output_folder='<path>'
```

Produces 3 API alternatives (differing in pagination strategy and error response detail), lets you choose and refine, then writes `api-alternatives.md` + `api-design.md`.

**Example:**
```
@api-designer requirements_file='C:\projects\myservice\req.md' output_folder='C:\projects\myservice\design'
```

---

## Typical Workflows

### New service from scratch
```
/design C:\projects\myservice\req.md output=C:\projects\myservice\design
```
Then optionally:
```
/build C:\projects\myservice\design
/powerpoint-generator C:\projects\myservice\design
```

### Review an existing codebase
```
/review C:\projects\myservice\src requirements=C:\projects\myservice\req.md
```
The orchestrator auto-skips reviewers whose inputs aren't present. To force every candidate reviewer to run regardless:
```
/review C:\projects\myservice\src requirements=C:\projects\myservice\req.md force_run_all=true
```

### Redesign one layer only (e.g., change the API without re-running everything)
```
@api-designer requirements_file='C:\projects\myservice\req.md' output_folder='C:\projects\myservice\design'
```

### Design pipeline with a locked tech stack
Create or point to an existing `service-context.md`, then:
```
/design C:\projects\myservice\req.md output=C:\projects\myservice\design context=C:\projects\myservice\service-context.md
```

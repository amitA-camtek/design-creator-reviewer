# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

## Project Overview

This repository contains a generic service design and review system built on Claude agents and skills. It can design, review, scaffold, and build any service type from a requirements document.

The agents and skills live in `.claude/agents/`. All agents are domain-agnostic — they read YAML front-matter from design files at runtime to adapt to any service type.

---

## Auto-routing — Natural Language Triggers

**"If the user requests something, it happens."** No slash commands required. When the user's request matches one of the intents below, invoke the corresponding agent or skill **automatically and immediately** without asking for confirmation.

| User intent | Invoke |
|---|---|
| Design a new service / create a design / run the design pipeline / "design this" / "make a design for X" / "I need an architecture for X" | `design-orchestrator` with the requirements file path |
| Review a design or codebase (any depth — "take a look at", "deep review", "comprehensive review", "review everything") | `review-orchestrator` with the folder path. The orchestrator's smart auto-skip pass picks the right reviewer set automatically. |
| Build production / create production files / build this design / "generate the code" / "implement it" | `/build` skill with the output folder |
| Generate slides / create a presentation / make a PowerPoint / "stakeholder deck" | `/powerpoint-generator` skill with the output folder |
| "Check the quality" / "gate check" / "quick quality check on the design" | `quality-gate` agent with the output folder |

**Argument extraction**: pull file paths and folder paths directly from the user's message. If a required path is missing, ask for only that — nothing else.

**Upfront intent flags**: if the user's request includes phrases like:
- "design only" / "no build" / "stop at design" → skip Phase 6 (production build)
- "no review" → skip Phase 5 (full review); run Phase 4b tests only
- "just the architecture" → run Phases 3 and 3.5 only, write design files, stop

---

## Pipeline Manifest (optional customisation)

The agent sets for each pipeline phase are driven by `.claude/pipeline.yaml`. Orchestrators read this file at startup and fall back to built-in defaults if it is absent — so the system works out of the box with no manifest.

**Common customisations:**

| Goal | Change |
|---|---|
| Add a new reviewer to all reviews | Add the agent name under `phases.review.agents` |
| Force a narrower reviewer set on a specific call | Pass `agents=security,storage` (or any comma list) to `/review` |
| Bypass smart auto-skip on a specific call | Pass `force_run_all=true` to `/review` |
| Change the outer build retry limit | Set `phases.production-build.max_outer_cycles` |
| Reorder scaffolding agents | Reorder entries under `phases.scaffolding.agents` |

No orchestrator code changes are needed — edit the manifest file only.

---

## Pipeline Flow (fully automatic after alternative choice)

Once the user approves a design alternative, the pipeline runs without asking "proceed?" between phases:

```
Phase 0   Requirements read + UI detection (sets has_ui flag)
Phase 0.5 Discovery Q&A (one at a time, up to 5 questions)
[Plan mode: user picks alternative]
Phase 3   Write design files to design/ (architecture, schema, api — each with YAML front-matter)
Phase 3.x UX design (only when UI detected): discovery questions → EnterPlanMode → 3 alternatives
          with ASCII wireframes + Mermaid flows → user approves → write design/ux-design.md
Phase 3.5 Quality gate → auto-fix Critical issues (up to 3 cycles)
Phase 3.6 Design-only review via review-orchestrator (mode=design-only, auto_patch=true) — auto-skips reviewers that need source code
Phase 4   Pipeline agents in parallel (sequence-planner, code-scaffolder, test-planner)
Phase 4b  Unit tests: create test files → run → auto-fix (up to 5 cycles)
Phase 5   Full review via review-orchestrator (smart auto-skip picks reviewer set) → auto-patch → re-review
Phase 6   Production build → build-feedback loop if failures (up to 3 outer cycles)
```

---

## Skills (slash commands — optional, natural language preferred)

| Skill | Usage | What it does |
|---|---|---|
| `/design` | `/design <requirements-file> [output=<folder>]` | Runs the full design pipeline via `design-orchestrator` |
| `/review` | `/review <folder> [requirements=<file>] [agents=<list>] [force_run_all=true]` | Service review via `review-orchestrator`; smart auto-skip picks the reviewer set automatically |
| `/build` | `/build <output-folder>` | Creates and builds a production project via `build-orchestrator` |
| `/powerpoint-generator` | `/powerpoint-generator <output-folder>` | Generates a `.pptx` stakeholder presentation |
| `/architecture-designer` | `/architecture-designer <requirements-file> [output=<folder>]` | Standalone: redesign architecture only, writes to `design/architecture-design.md` |
| `/schema-designer` | `/schema-designer <requirements-file> [output=<folder>]` | Standalone: redesign schema only, writes to `design/schema-design.md` |
| `/api-designer` | `/api-designer <requirements-file> [output=<folder>]` | Standalone: redesign API only, writes to `design/api-design.md` |
| `/ux-designer` | `/ux-designer <requirements-file> [output=<folder>]` | Standalone: redesign UX/UI only, writes to `design/ux-design.md` |

---

## Agent Reference

| Agent | Model | Purpose |
|---|---|---|
| `design-orchestrator` | opus | Single entry point: design a new service (interactive then automatic) or review an existing one |
| `review-orchestrator` | opus | Single review entry point. Smart auto-skip picks the reviewer set from up to 9 specialists based on what the target folder contains. |
| `build-orchestrator` | opus | Coordinates the full build pipeline: source files → unit tests → build → run (up to 3 outer feedback cycles) |
| `quality-gate` | sonnet | Fast design-file quality check — Critical/High issues only; used in Phase 3.5 |
| `production-file-creator` | opus | Creates fully-implemented production source files from a design package |
| `production-build-runner` | opus | Builds the project, fixes compile errors (up to 10 cycles), and runs it |
| `test-file-creator` | sonnet | Creates fully-implemented test files from test-plan.md + code-scaffolding.md |
| `test-runner` | sonnet | Runs test suite, auto-fixes failures (up to 5 cycles), writes test-report.md |
| `sequence-planner` | sonnet | Produces Mermaid sequence diagrams for the 5 key flows |
| `code-scaffolder` | sonnet | Generates language-appropriate class stubs from the design |
| `test-planner` | sonnet | Generates a test case spec per requirement |
| `requirements-checker` | sonnet | Verifies all requirements are satisfied |
| `security-reviewer` | sonnet | Reviews security threats (OWASP Top 10) from design file front-matter |
| `storage-reviewer` | sonnet | Reviews SQLite / PostgreSQL / any storage layer |
| `concurrency-reviewer` | sonnet | Reviews async/await, threading, race conditions |
| `api-contract-reviewer` | sonnet | Reviews API binding, endpoints, pagination, sensitive fields |
| `language-patterns-reviewer` | sonnet | Reviews .NET / language idioms, disposal, logging |
| `performance-checker` | sonnet | Verifies performance targets from design file front-matter |
| `configuration-validator` | haiku | Validates config keys, secrets handling, logging sinks |
| `fix-generator` | sonnet | Converts review findings into before/after code patches |
| `ux-designer` | opus | Interactive UX/UI design: 3 alternatives with ASCII wireframes + Mermaid flows in plan mode, writes ux-design.md |
| `ux-reviewer` | sonnet | Reviews frontend implementation against ux-design.md front-matter (screen completeness, layout, accessibility, responsive) |

---

## Design Pipeline Output Structure

```
{output_folder}/
├── design/
│   ├── alternatives.md            # 3 alternatives + comparison
│   ├── architecture-design.md     # final architecture (with YAML front-matter)
│   ├── schema-design.md           # final schema (with YAML front-matter)
│   ├── api-design.md              # final API spec (with YAML front-matter)
│   ├── ux-alternatives.md         # (if service has UI) 3 UX alternatives + wireframes
│   └── ux-design.md               # (if service has UI) approved UX design + wireframes (with YAML front-matter)
├── pipeline/
│   ├── sequence-diagrams.md
│   ├── code-scaffolding.md
│   └── test-plan.md
├── review/
│   ├── requirements-check.md
│   ├── security-review.md
│   ├── storage-review.md
│   ├── concurrency-review.md
│   ├── api-contract-review.md
│   ├── language-patterns-review.md
│   ├── performance-check.md
│   ├── configuration-validation.md
│   ├── ux-review.md               # (if service has UI) Phase 5 ux-reviewer findings
│   ├── review-report.md           # synthesised report from review-orchestrator
│   └── fix-patches.md
├── assets/
│   └── {service_name}-design.pptx
├── production/
│   ├── {service_name}/            # fully-implemented source tree
│   ├── test-report.md
│   └── run-report.md
├── implementation-plan.md
└── design-package-summary.md
```

---

## Invoking design-orchestrator directly

**Design mode**: `@design-orchestrator requirements_file='path/to/req.md' [output='path/to/output']`

**Review mode**: `@design-orchestrator review 'path/to/folder'`

Design context (service_name, primary_language, runtime, components, etc.) lives in YAML front-matter within the design files under `{output_folder}/design/`. No separate context file is needed.

**Upfront flags** (include in your invocation to control pipeline depth):
- `design only` — stop after Phase 3.5 (quality gate); no scaffolding, no build
- `no build` — skip Phase 6; stop after Phase 5 review and implementation plan
- `no review` — skip Phase 5 review; run Phase 4b tests then build

# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

## Project Overview

This repository contains a generic service design and review system built on Claude agents and skills. It can design, review, scaffold, and build any service type from a requirements document.

The agents and skills live in `.claude/agents/`. All agents are domain-agnostic — they read `service-context.md` at runtime to adapt to any service type.

---

## Auto-routing — Natural Language Triggers

**"If the user requests something, it happens."** No slash commands required. When the user's request matches one of the intents below, invoke the corresponding agent or skill **automatically and immediately** without asking for confirmation.

| User intent | Invoke |
|---|---|
| Design a new service / create a design / run the design pipeline / "design this" / "make a design for X" / "I need an architecture for X" | `design-orchestrator` with the requirements file path |
| Review a design or codebase (quick / focused / "take a look at") | `review-orchestrator` with the folder path |
| Full review / all dimensions / comprehensive review / "deep review" / "review everything" | `full-validator` with the folder path |
| Build production / create production files / build this design / "generate the code" / "implement it" | `/build` skill with the output folder |
| Generate slides / create a presentation / make a PowerPoint / "stakeholder deck" | `/powerpoint-generator` skill with the output folder |
| "Check the quality" / "gate check" / "quick quality check on the design" | `quality-gate` agent with the output folder |

**Argument extraction**: pull file paths and folder paths directly from the user's message. If a required path is missing, ask for only that — nothing else.

**Upfront intent flags**: if the user's request includes phrases like:
- "design only" / "no build" / "stop at design" → skip Phase 6 (production build)
- "no review" → skip Phase 5 (full review); run Phase 4b tests only
- "just the architecture" → run Phases 3 and 3.5 only, write design files, stop

---

## Pipeline Flow (fully automatic after alternative choice)

Once the user approves a design alternative, the pipeline runs without asking "proceed?" between phases:

```
Phase 0   Requirements read
Phase 0.5 Discovery Q&A (one at a time)
[Plan mode: user picks alternative]
Phase 3   Write design files (architecture, schema, api, service-context)
Phase 3.5 Quality gate → auto-fix Critical issues (up to 3 cycles)
Phase 3.6 Fast review (requirements + security + storage in parallel) → auto-patch
Phase 4   Pipeline agents in parallel (sequence-planner, code-scaffolder, test-planner)
Phase 4b  Unit tests: create test files → run → auto-fix (up to 5 cycles)
Phase 5   Full 8-dimension review → auto-patch → re-review
Phase 6   Production build → build-feedback loop if failures (up to 3 outer cycles)
```

---

## Skills (slash commands — optional, natural language preferred)

| Skill | Usage | What it does |
|---|---|---|
| `/design` | `/design <requirements-file> [output=<folder>] [context=<file>]` | Runs the full design pipeline via `design-orchestrator` |
| `/review` | `/review <folder> [requirements=<file>]` | Focused 3-dimension review via `review-orchestrator` |
| `/fullreview` | `/fullreview <folder> [requirements=<file>]` | Full 8-dimension review via `full-validator` |
| `/build` | `/build <output-folder>` | Creates and builds a production project |
| `/powerpoint-generator` | `/powerpoint-generator <output-folder>` | Generates a `.pptx` stakeholder presentation |

---

## Agent Reference

| Agent | Model | Purpose |
|---|---|---|
| `design-orchestrator` | opus | Single entry point: design a new service (interactive then automatic) or review an existing one |
| `review-orchestrator` | opus | Focused 3-agent review: requirements + security + storage |
| `full-validator` | opus | Full 8-dimension review (all agents in parallel) |
| `quality-gate` | sonnet | Fast design-file quality check — Critical/High issues only; used in Phase 3.5 |
| `production-file-creator` | opus | Creates fully-implemented production source files from a design package |
| `production-build-runner` | opus | Builds the project, fixes compile errors (up to 10 cycles), and runs it |
| `test-file-creator` | sonnet | Creates fully-implemented test files from test-plan.md + code-scaffolding.md |
| `test-runner` | sonnet | Runs test suite, auto-fixes failures (up to 5 cycles), writes test-report.md |
| `architecture-designer` | opus | Standalone: produces 3 architecture alternatives, user chooses one |
| `schema-designer` | sonnet | Standalone: produces 3 schema alternatives, user chooses one |
| `api-designer` | sonnet | Standalone: produces 3 API design alternatives, user chooses one |
| `sequence-planner` | sonnet | Produces Mermaid sequence diagrams for the 5 key flows |
| `code-scaffolder` | sonnet | Generates language-appropriate class stubs from the design |
| `test-planner` | sonnet | Generates a test case spec per requirement |
| `requirements-checker` | sonnet | Verifies all requirements are satisfied |
| `security-reviewer` | sonnet | Reviews threats from service-context.md + OWASP Top 10 |
| `storage-reviewer` | sonnet | Reviews SQLite / PostgreSQL / any storage layer |
| `concurrency-reviewer` | sonnet | Reviews async/await, threading, race conditions |
| `api-contract-reviewer` | sonnet | Reviews API binding, endpoints, pagination, sensitive fields |
| `language-patterns-reviewer` | sonnet | Reviews .NET / language idioms, disposal, logging |
| `performance-checker` | sonnet | Verifies performance targets from service-context.md |
| `configuration-validator` | haiku | Validates config keys, secrets handling, logging sinks |
| `fix-generator` | sonnet | Converts review findings into before/after code patches |

---

## Design Pipeline Output Structure

```
{output_folder}/
├── explore/
│   ├── design-alternatives.md    # 3 alternatives + comparison
│   └── service-context.md        # tech stack context
├── pipeline/
│   ├── sequence-diagrams.md
│   ├── code-scaffolding.md
│   └── test-plan.md
├── review/
│   ├── comprehensive-review-report.md
│   └── fix-patches.md
├── assets/
│   └── {service_name}-design.pptx
├── Production/
│   ├── {service_name}/           # fully-implemented source tree
│   ├── test-report.md            # unit test results
│   └── run-report.md             # build + startup result
├── architecture-design.md
├── schema-design.md
├── api-design.md
├── implementation-plan.md
└── design-package-summary.md
```

---

## Invoking design-orchestrator directly

**Design mode**: `@design-orchestrator requirements_file='path/to/req.md' [output='path/to/output'] [context='path/to/service-context.md']`

**Review mode**: `@design-orchestrator review 'path/to/folder'`

The `context=` parameter is optional. Pass it only to lock the technology stack to an existing `service-context.md`. When omitted, the agent designs technology choices freely.

**Upfront flags** (include in your invocation to control pipeline depth):
- `design only` — stop after Phase 3.5 (quality gate); no scaffolding, no build
- `no build` — skip Phase 6; stop after full review and implementation plan
- `no review` — skip Phase 5 full review; run Phase 4b tests then build

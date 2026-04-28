# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

## Project Overview

This repository contains a generic service design and review system built on Claude agents and skills. It can design, review, scaffold, and build any service type from a requirements document.

The agents and skills live in `.claude/agents/`. All agents are domain-agnostic — they read `service-context.md` at runtime to adapt to any service type.

---

## Auto-routing — Natural Language Triggers

When the user's request matches one of these intents, invoke the corresponding agent or skill **automatically** without asking for confirmation:

| User intent | Invoke |
|---|---|
| Design a new service / create a design / run the design pipeline / "design this from requirements" | `design-orchestrator` with the requirements file path |
| Review a design or codebase (quick / focused) | `review-orchestrator` with the folder path |
| Full review / all dimensions / comprehensive review | `full-validator` with the folder path |
| Build production / create production files / build this design | `/build` skill with the output folder |
| Generate slides / create a presentation / make a PowerPoint | `/powerpoint-generator` skill with the output folder |

**Argument extraction**: pull file paths and folder paths from the user's message. If a required path is missing, ask for only that — nothing else.

---

## Skills (slash commands)

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
| `design-orchestrator` | opus | Single entry point: design a new service (interactive) or review an existing one |
| `review-orchestrator` | opus | Focused 3-agent review: requirements + security + storage |
| `full-validator` | opus | Full 8-dimension review (all agents in parallel) |
| `production-file-creator` | opus | Creates fully-implemented production source files from a design package |
| `production-build-runner` | opus | Builds the project, fixes compile errors (up to 10 cycles), and runs it |
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

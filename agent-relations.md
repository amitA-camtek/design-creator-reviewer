# Agent Relations — Block Diagram & Flow

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        USER (Developer)                         │
└───────────────┬──────────────────────────┬──────────────────────┘
                │                          │
        Design mode                  Review mode
  (requirements file path)       ("review <folder>")
                │                          │
                ▼                          ▼
┌──────────────────────────────────────────────────────────────┐
│                     design-orchestrator                       │
│               Primary entry point (Opus model)               │
│   Reads service-context.md · Writes all output files         │
└───────────────┬───────────────────────────┬──────────────────┘
                │                           │
        Design pipeline              Review pipeline
                │                           │
                ▼                           ▼
     ┌──────────────────┐      ┌─────────────────────────────┐
     │   (inline work)  │      │       full-validator        │
     │  Phase 0–3:      │      │   8-dimension parallel run  │
     │  Discovery →     │      └──────────────┬──────────────┘
     │  Alternatives →  │                     │
     │  Approval →      │                     │
     │  Write files     │                     │
     └────────┬─────────┘                     │
              │ Phase 4 (parallel)             │
              ▼                               ▼
   ┌──────────────────────┐    (see Review Pipeline section)
   │  sequence-planner    │
   │  code-scaffolder     │ ← spawned in parallel → pipeline/
   │  test-planner        │
   └──────────┬───────────┘
              │ Phase 5 (sequential then parallel)
              ▼
   ┌──────────────────────┐
   │   full-validator     │ → review/
   │   (+ fix-generator)  │
   └──────────┬───────────┘
              │
              ▼
   ┌──────────────────────┐   ┌──────────────────────┐
   │ implementation-plan  │   │  powerpoint-generator│ ← parallel
   │ design-pkg-summary   │   │  → assets/*.pptx     │
   └──────────────────────┘   └──────────────────────┘
```

---

## Output Folder Structure

```
{output_folder}/
├── architecture-design.md        ← Phase 3 (design-orchestrator)
├── schema-design.md              ← Phase 3
├── api-design.md                 ← Phase 3
├── implementation-plan.md        ← Phase 5
├── design-package-summary.md     ← Phase 5
│
├── explore/
│   ├── service-context.md        ← Phase 1 (draft) / Phase 3 (final)
│   └── design-alternatives.md   ← Phase 1 / Phase 2 (iterations)
│
├── pipeline/
│   ├── sequence-diagrams.md      ← Phase 4 (sequence-planner)
│   ├── code-scaffolding.md       ← Phase 4 (code-scaffolder)
│   └── test-plan.md              ← Phase 4 (test-planner)
│
├── review/
│   ├── comprehensive-review-report.md  ← Phase 5 (full-validator)
│   └── fix-patches.md                 ← Phase 5 (fix-generator)
│
└── assets/
    └── {service_name}-design.pptx     ← Phase 5 (powerpoint-generator)
```

---

## Design Pipeline — Phase Flow

```
requirements.md
      │
      ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 0 — Requirements Analysis                                    │
│  design-orchestrator reads requirements, checks service-context.md  │
│  Infers service name; tells user alternatives are coming            │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ (no user input needed)
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 1 — Three integrated alternatives                            │
│  Writes explore/service-context.md (draft, tech fields blank)       │
│  Writes explore/design-alternatives.md                              │
│  Presents summary + asks user to choose                             │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ User selects / requests changes
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 2 — Iterate until approved                                   │
│  Revises explore/design-alternatives.md per feedback                │
│  Loop until user says "approved" / "proceed"                        │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ Explicit approval
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 3 — Write design files  (done directly, no delegation)       │
│  explore/service-context.md (finalized with tech fields)            │
│  architecture-design.md  ·  schema-design.md  ·  api-design.md     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 4 — Pipeline subagents  (spawned IN PARALLEL)                │
│                                                                     │
│   ┌────────────────┐  ┌────────────────┐  ┌──────────────────┐     │
│   │sequence-planner│  │ code-scaffolder│  │  test-planner    │     │
│   │                │  │                │  │                  │     │
│   │pipeline/       │  │pipeline/       │  │pipeline/         │     │
│   │sequence-       │  │code-           │  │test-plan.md      │     │
│   │diagrams.md     │  │scaffolding.md  │  │                  │     │
│   └────────────────┘  └────────────────┘  └──────────────────┘     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ All three complete
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 5 — Auto-review, auto-fix, and presentation                  │
│                                                                     │
│  1. full-validator (+ fix-generator inside it)                      │
│     → review/comprehensive-review-report.md                         │
│     → review/fix-patches.md                                         │
│                                                                     │
│  2. Write implementation-plan.md  (direct, no delegation)           │
│  3. Write design-package-summary.md  (direct, no delegation)        │
│                                                                     │
│  4. powerpoint-generator  (parallel with or after step 3)          │
│     → assets/{service_name}-design.pptx                             │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Review Pipeline — Full vs Focused

```
User triggers review
        │
        ├──── "review <folder>"  ────────────────► design-orchestrator
        │                                                   │
        │                                          delegates to full-validator
        │
        └──── direct invocation ─────────────────► full-validator   (8 agents)
                                                OR
                                                   review-orchestrator (3 agents)
```

### full-validator — 8 specialist agents in parallel

```
                         full-validator
                              │
          ┌───────────────────┼────────────────────┐
          │           (all 8 in parallel)           │
          ▼                   ▼                     ▼
┌──────────────────┐  ┌────────────────┐  ┌─────────────────────┐
│requirements-     │  │security-       │  │storage-reviewer     │
│checker           │  │reviewer        │  │                     │
└──────────────────┘  └────────────────┘  └─────────────────────┘
┌──────────────────┐  ┌────────────────┐  ┌─────────────────────┐
│concurrency-      │  │api-contract-   │  │language-patterns-   │
│reviewer          │  │reviewer        │  │reviewer             │
└──────────────────┘  └────────────────┘  └─────────────────────┘
┌──────────────────┐  ┌────────────────┐
│performance-      │  │configuration-  │
│checker           │  │validator       │
└──────────────────┘  └────────────────┘
          │                   │                     │
          └───────────────────┼─────────────────────┘
                              ▼
                  full-validator synthesises all findings
                              │
                              ▼
                 comprehensive-review-report.md
                              │
                              ▼
                       fix-generator
                              │
                              ▼
                        fix-patches.md
```

### review-orchestrator — focused 3-agent review

```
                       review-orchestrator
                              │
          ┌───────────────────┼───────────────────┐
          │       (all 3 in parallel)              │
          ▼                   ▼                    ▼
┌──────────────────┐  ┌────────────────┐  ┌─────────────────┐
│requirements-     │  │security-       │  │storage-reviewer │
│checker           │  │reviewer        │  │                 │
└──────────────────┘  └────────────────┘  └─────────────────┘
          │                   │                    │
          └───────────────────┼────────────────────┘
                              ▼
              review-orchestrator synthesises findings
                              │
                              ▼
                       review-report.md
```

---

## Complete Agent Catalogue

```
┌──────────────────────────────────────────────────────────────────────┐
│  ORCHESTRATORS                                                        │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │ design-orchestrator  — full design lifecycle OR review entry  │   │
│  │ full-validator       — 8-dimension parallel review            │   │
│  │ review-orchestrator  — focused 3-dimension review             │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                       │
│  PHASE 4 — PIPELINE AGENTS (spawned in parallel by orchestrator)     │
│  ┌────────────────────┐  ┌────────────────────┐  ┌───────────────┐  │
│  │ sequence-planner   │  │ code-scaffolder     │  │ test-planner  │  │
│  └────────────────────┘  └────────────────────┘  └───────────────┘  │
│                                                                       │
│  PHASE 5 — REVIEW & PRESENTATION AGENTS                              │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ fix-generator        — converts report findings into patches │    │
│  │ powerpoint-generator — builds .pptx from design package     │    │
│  └─────────────────────────────────────────────────────────────┘    │
│                                                                       │
│  REVIEW / SPECIALIST AGENTS (used by full-validator & orchestrators) │
│  ┌────────────────────┐  ┌─────────────────────────────────────┐    │
│  │ requirements-      │  │ security-reviewer                   │    │
│  │ checker            │  │                                     │    │
│  └────────────────────┘  └─────────────────────────────────────┘    │
│  ┌────────────────────┐  ┌─────────────────────────────────────┐    │
│  │ storage-reviewer   │  │ concurrency-reviewer                │    │
│  └────────────────────┘  └─────────────────────────────────────┘    │
│  ┌────────────────────┐  ┌─────────────────────────────────────┐    │
│  │ api-contract-      │  │ language-patterns-reviewer          │    │
│  │ reviewer           │  │                                     │    │
│  └────────────────────┘  └─────────────────────────────────────┘    │
│  ┌────────────────────┐  ┌─────────────────────────────────────┐    │
│  │ performance-       │  │ configuration-validator             │    │
│  │ checker            │  │                                     │    │
│  └────────────────────┘  └─────────────────────────────────────┘    │
│                                                                       │
│  STANDALONE DESIGN AGENTS (available but not used in pipelines)      │
│  ┌──────────────────┐  ┌──────────────────┐  ┌─────────────────┐   │
│  │architecture-     │  │ schema-designer  │  │ api-designer    │   │
│  │designer          │  │                  │  │                 │   │
│  └──────────────────┘  └──────────────────┘  └─────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

---

## Input / Output Files per Agent

| Agent | Reads | Writes |
|---|---|---|
| `design-orchestrator` | `requirements.md`, `service-context.md` | `explore/service-context.md`, `explore/design-alternatives.md`, `architecture-design.md`, `schema-design.md`, `api-design.md`, `implementation-plan.md`, `design-package-summary.md` |
| `sequence-planner` | `service-context.md`, `architecture-design.md` | `pipeline/sequence-diagrams.md` |
| `code-scaffolder` | `service-context.md`, `architecture-design.md`, `schema-design.md`, `api-design.md` | `pipeline/code-scaffolding.md` |
| `test-planner` | `requirements.md`, `service-context.md` | `pipeline/test-plan.md` |
| `full-validator` | all design files + source code | `review/comprehensive-review-report.md` (invokes fix-generator internally) |
| `review-orchestrator` | all design files + source code | `review-report.md` |
| `fix-generator` | `review/comprehensive-review-report.md` or `review-report.md` | `review/fix-patches.md` |
| `powerpoint-generator` | `explore/design-alternatives.md`, `architecture-design.md`, `schema-design.md`, `api-design.md`, `design-package-summary.md` | `assets/{service_name}-design.pptx` |
| `requirements-checker` | `requirements.md`, source / design files | (raw findings → orchestrator) |
| `security-reviewer` | `service-context.md`, source / design files | (raw findings → orchestrator) |
| `storage-reviewer` | `service-context.md`, source / design files | (raw findings → orchestrator) |
| `concurrency-reviewer` | `service-context.md`, source / design files | (raw findings → orchestrator) |
| `api-contract-reviewer` | `service-context.md`, source / design files | (raw findings → orchestrator) |
| `language-patterns-reviewer` | `service-context.md`, source / design files | (raw findings → orchestrator) |
| `performance-checker` | `service-context.md`, source / design files | (raw findings → orchestrator) |
| `configuration-validator` | `service-context.md`, config files | (raw findings → orchestrator) |
| `architecture-designer` | `requirements.md` | `architecture-design.md` |
| `schema-designer` | `requirements.md`, `service-context.md` | `schema-design.md` |
| `api-designer` | `requirements.md`, `service-context.md` | `api-design.md` |

---

## Key Design Rules

- `service-context.md` is the shared contract — every specialist agent reads it to adapt to the target service.
- Specialist review agents never write output files directly; they return raw findings to their orchestrator.
- Phase 4 pipeline agents (`sequence-planner`, `code-scaffolder`, `test-planner`) are always launched in parallel; all write into `{output_folder}/pipeline/`.
- Phase 5 runs sequentially after Phase 4: `full-validator` first (→ `review/`), then `implementation-plan.md` and `design-package-summary.md` (direct), then `powerpoint-generator` (→ `assets/`).
- `full-validator` always invokes `fix-generator` after writing the report — never skipped.
- `design-orchestrator` writes Phase 3 design files directly (no delegation to `architecture-designer`, `schema-designer`, or `api-designer`).
- `design-orchestrator` never asks technology questions — it proposes all technology choices in Phase 1 alternatives.
- `powerpoint-generator` requires Python 3 + python-pptx; it installs the library silently if missing.
- `design-orchestrator` requires explicit user approval before leaving Phase 2.
- All output files must live inside `output_folder` — never next to the requirements file.

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
     │  Phase 0–0.5:    │      │   8-dimension parallel run  │
     │  Discovery Qs →  │      └──────────────┬──────────────┘
     │  Alternatives →  │                     │
     │  Approval →      │                     │
     │  Write files     │                     │
     └────────┬─────────┘                     │
              │ Phase 4 (parallel)             │
              │ [user confirms first]          ▼
              ▼                   (see Review Pipeline section)
   ┌──────────────────────┐
   │  sequence-planner    │
   │  code-scaffolder     │ ← spawned in parallel → pipeline/
   │  test-planner        │
   └──────────┬───────────┘
              │ Phase 5 (sequential then parallel)
              │ [user confirms, or "skip review" stops here]
              ▼
   ┌──────────────────────┐
   │   full-validator     │ → review/
   │   (+ fix-generator)  │
   └──────────┬───────────┘
              │ Synthesise findings
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
│  Infers service name; tells user questions are coming               │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ (no user input needed)
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 0.5 — Discovery questions                                    │
│  Asks 2–4 targeted questions in one message:                        │
│  tech constraints, operational constraints, quality priorities,     │
│  deadlines — only what the requirements don't already specify       │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ User answers
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
│  Presents summary → waits for user confirmation to continue         │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ Explicit user confirmation ("proceed")
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
│  Presents summary → waits for user confirmation or "skip review"    │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ "proceed" (runs Phase 5) or "skip review" (stops)
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 5 — Auto-review, auto-fix, and presentation                  │
│                                                                     │
│  1. full-validator (+ fix-generator inside it)                      │
│     → review/comprehensive-review-report.md                         │
│     → review/fix-patches.md                                         │
│                                                                     │
│  2. Synthesise findings: identify the single blocking issue,        │
│     classify Critical findings as design blockers vs impl fixes,    │
│     determine dependency order, group High findings by component    │
│                                                                     │
│  3. Write implementation-plan.md  (direct, no delegation)           │
│     Includes Phase 6a (design blockers) + Phase 6b (impl fixes)     │
│     + "What to do next" section                                     │
│  4. Write design-package-summary.md  (direct, no delegation)        │
│                                                                     │
│  5. powerpoint-generator  (parallel with or after step 4)           │
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
- Phase 5 runs sequentially after Phase 4: `full-validator` first (→ `review/`), then synthesise findings, then `implementation-plan.md` and `design-package-summary.md` (direct), then `powerpoint-generator` (→ `assets/`).
- `full-validator` always invokes `fix-generator` after writing the report — never skipped.
- `design-orchestrator` writes Phase 3 design files directly (no delegation to `architecture-designer`, `schema-designer`, or `api-designer`).
- `design-orchestrator` asks 2–4 discovery questions in Phase 0.5 (once, in a single message) before generating alternatives — it does not ask technology questions, it proposes all technology choices in Phase 1.
- `design-orchestrator` requires explicit user approval before leaving Phase 2 and explicit confirmation before starting Phase 4 (pipeline) and Phase 5 (review).
- Phase 5 (review) is optional — if the user says "skip review" after Phase 4, `design-package-summary.md` is written without the Review Appendix and the pipeline stops.
- `implementation-plan.md` classifies Critical findings as either Phase 6a design blockers (fix before any coding) or Phase 6b implementation must-fixes (fix during coding), and includes a "What to do next" section naming the single most important first action.
- `powerpoint-generator` requires Python 3 + python-pptx; it installs the library silently if missing.
- All output files must live inside `output_folder` — never next to the requirements file.

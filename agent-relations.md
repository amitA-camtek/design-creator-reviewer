# Agent Relations — Block Diagram & Flow

## System Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                          USER (Developer)                            │
└───┬─────────────┬─────────────┬──────────────┬───────────────┬──────┘
    │             │             │              │               │
 /design       /review      /fullreview     /build          /powerpoint-generator
    │             │             │              │               │
    ▼             ▼             ▼              ▼               ▼
┌───────────────────────────────────────────────────────────────────┐
│                        SKILLS LAYER                                │
│  design · review · fullreview · build · powerpoint-generator      │
│  (run in main context — parse args, invoke agents below)          │
└───┬─────────────┬─────────────┬──────────────┬────────────────────┘
    │             │             │              │
    ▼             ▼             ▼              ▼
design-     review-       full-         production-file-creator
orchestrator orchestrator  validator     → production-build-runner
```

---

## .claude/agents/ Folder Structure

```
.claude/agents/
  orchestrators/           design-orchestrator, review-orchestrator, full-validator
  production/              production-file-creator, production-build-runner
  reviewers/               9 specialist agents + fix-generator
  pipeline/                sequence-planner, code-scaffolder, test-planner
  standalone/              architecture-designer, schema-designer, api-designer
  skills/                  design, review, fullreview, build, powerpoint-generator
  service-context-template.md
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
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 0.5 — Discovery questions                                    │
│  Asks 2–4 targeted questions in one message:                        │
│  tech constraints, operational constraints, quality priorities,     │
│  deadlines — only what the requirements don't already specify       │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ User answers → EnterPlanMode
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
│  PHASE 2 — Iterate until approved  (still inside plan mode)         │
│  Revises explore/design-alternatives.md per feedback                │
│  Loop until user says "approved" → ExitPlanMode                     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ Explicit approval
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 3 — Write design files  (done directly, no delegation)       │
│  explore/service-context.md (finalized with tech fields)            │
│  architecture-design.md  ·  schema-design.md  ·  api-design.md     │
│  Presents summary → waits for user confirmation to continue         │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ "proceed"
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 4 — Pipeline subagents  (spawned IN PARALLEL)                │
│                                                                     │
│   ┌────────────────┐  ┌────────────────┐  ┌──────────────────┐     │
│   │sequence-planner│  │ code-scaffolder│  │  test-planner    │     │
│   │pipeline/       │  │pipeline/       │  │pipeline/         │     │
│   │sequence-       │  │code-           │  │test-plan.md      │     │
│   │diagrams.md     │  │scaffolding.md  │  │                  │     │
│   └────────────────┘  └────────────────┘  └──────────────────┘     │
│  Presents summary → waits for "proceed" or "skip review"           │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ "proceed" or "skip review" (stops here)
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 5 — Auto-review, auto-fix                                    │
│                                                                     │
│  5.1  full-validator (initial review)                               │
│       → review/comprehensive-review-report.md                       │
│       → review/fix-patches.md  (via fix-generator)                 │
│                                                                     │
│  5.2  Apply Critical + High patches to design files                 │
│                                                                     │
│  5.3  full-validator again (post-fix re-review)                     │
│       overwrites comprehensive-review-report.md + fix-patches.md   │
│                                                                     │
│  5.4  Write implementation-plan.md  (direct)                        │
│       Write design-package-summary.md  (direct)                     │
│       Presents summary → waits for "proceed" or "stop"             │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ "proceed"
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 6 — Production Build                                         │
│                                                                     │
│  6.1  production-file-creator                                       │
│       → Production/{service_name}/  (full source code)             │
│                                                                     │
│  6.2  production-build-runner                                       │
│       Build-fix loop (max 10 cycles) → run                         │
│       → Production/run-report.md  or  Production/build-errors.md   │
└─────────────────────────────────────────────────────────────────────┘
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
│   ├── comprehensive-review-report.md  ← Phase 5 (full-validator, post-fix)
│   └── fix-patches.md                 ← Phase 5 (fix-generator)
│
├── Production/
│   └── {service_name}/           ← Phase 6 (production-file-creator)
│       run-report.md             ← Phase 6 (production-build-runner)
│       build-errors.md           ← Phase 6 (on build failure)
│
└── assets/
    └── {service_name}-design.pptx  ← /powerpoint-generator skill (user-triggered)
```

---

## Review Pipeline — Full vs Focused

```
User triggers review
        │
        ├── /review <folder>  ──────────────────► review-orchestrator  (3 agents)
        │
        ├── /fullreview <folder>  ──────────────► full-validator        (8 agents)
        │
        └── @design-orchestrator review <folder> ► full-validator       (8 agents)
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

### review-orchestrator — focused 3-agent single-pass review

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
                              │
                              ▼
                       fix-generator
                              │
                              ▼
                        fix-patches.md
```

---

## Complete Agent Catalogue

```
┌──────────────────────────────────────────────────────────────────────────┐
│  SKILLS  (user slash commands — run in main context)                      │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │ /design            → invokes design-orchestrator                    │ │
│  │ /review            → invokes review-orchestrator                    │ │
│  │ /fullreview        → invokes full-validator                         │ │
│  │ /build             → invokes production-file-creator + build-runner │ │
│  │ /powerpoint-generator → generates .pptx from design package        │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                            │
│  ORCHESTRATORS  [opus]                                                    │
│  ┌───────────────────────────────────────────────────────────────────┐   │
│  │ design-orchestrator  — full design lifecycle OR review entry       │   │
│  │ full-validator       — 8-dimension parallel review                 │   │
│  │ review-orchestrator  — focused 3-dimension single-pass review      │   │
│  └───────────────────────────────────────────────────────────────────┘   │
│                                                                            │
│  PRODUCTION  [opus]                                                       │
│  ┌────────────────────────────────────────────────────────────────┐      │
│  │ production-file-creator  — creates full source code from design │      │
│  │ production-build-runner  — build-fix loop (10 cycles) + run     │      │
│  └────────────────────────────────────────────────────────────────┘      │
│                                                                            │
│  PIPELINE AGENTS  [sonnet]  (spawned in parallel — Phase 4)              │
│  ┌───────────────────┐  ┌──────────────────┐  ┌─────────────────┐       │
│  │ sequence-planner  │  │ code-scaffolder  │  │ test-planner    │       │
│  └───────────────────┘  └──────────────────┘  └─────────────────┘       │
│                                                                            │
│  SPECIALIST REVIEWERS  (used by full-validator & review-orchestrator)    │
│  ┌─────────────────────────┐  ┌──────────────────────────────────┐       │
│  │ requirements-checker    │  │ security-reviewer                │       │
│  │ [sonnet]                │  │ [sonnet]                         │       │
│  └─────────────────────────┘  └──────────────────────────────────┘       │
│  ┌─────────────────────────┐  ┌──────────────────────────────────┐       │
│  │ storage-reviewer        │  │ concurrency-reviewer             │       │
│  │ [sonnet]                │  │ [sonnet]                         │       │
│  └─────────────────────────┘  └──────────────────────────────────┘       │
│  ┌─────────────────────────┐  ┌──────────────────────────────────┐       │
│  │ api-contract-reviewer   │  │ language-patterns-reviewer       │       │
│  │ [sonnet]                │  │ [sonnet]                         │       │
│  └─────────────────────────┘  └──────────────────────────────────┘       │
│  ┌─────────────────────────┐  ┌──────────────────────────────────┐       │
│  │ performance-checker     │  │ configuration-validator          │       │
│  │ [sonnet]                │  │ [haiku]                          │       │
│  └─────────────────────────┘  └──────────────────────────────────┘       │
│  ┌─────────────────────────┐                                              │
│  │ fix-generator  [sonnet] │                                              │
│  └─────────────────────────┘                                              │
│                                                                            │
│  STANDALONE DESIGNERS  (user-invoked for isolated redesign only)         │
│  ┌──────────────────────┐  ┌──────────────────┐  ┌───────────────┐      │
│  │ architecture-designer│  │ schema-designer  │  │ api-designer  │      │
│  │ [opus]               │  │ [sonnet]         │  │ [sonnet]      │      │
│  └──────────────────────┘  └──────────────────┘  └───────────────┘      │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Input / Output Files per Agent

| Agent | Reads | Writes |
|---|---|---|
| `design-orchestrator` | `requirements.md`, `service-context.md` (optional) | `explore/service-context.md`, `explore/design-alternatives.md`, `architecture-design.md`, `schema-design.md`, `api-design.md`, `implementation-plan.md`, `design-package-summary.md` |
| `sequence-planner` | `service-context.md`, `architecture-design.md` | `pipeline/sequence-diagrams.md` |
| `code-scaffolder` | `service-context.md`, `architecture-design.md`, `schema-design.md`, `api-design.md` | `pipeline/code-scaffolding.md` |
| `test-planner` | `requirements.md`, `service-context.md` | `pipeline/test-plan.md` |
| `full-validator` | all design files + source code | `review/comprehensive-review-report.md` (invokes `fix-generator` internally → `review/fix-patches.md`) |
| `review-orchestrator` | all design files + source code | `review-report.md` (invokes `fix-generator` internally → `fix-patches.md`) |
| `fix-generator` | `comprehensive-review-report.md` or `review-report.md` | `fix-patches.md` |
| `production-file-creator` | all design files, `service-context.md` | `Production/{service_name}/` (full source tree) |
| `production-build-runner` | `service-context.md`, source files in `production_root` | `Production/run-report.md` or `Production/build-errors.md` |
| `powerpoint-generator` (skill) | `explore/design-alternatives.md`, `architecture-design.md`, `schema-design.md`, `api-design.md`, `design-package-summary.md` | `assets/{service_name}-design.pptx` |
| `requirements-checker` | `requirements.md`, source / design files | raw findings → orchestrator |
| `security-reviewer` | `service-context.md`, source / design files | raw findings → orchestrator |
| `storage-reviewer` | `service-context.md`, source / design files | raw findings → orchestrator |
| `concurrency-reviewer` | `service-context.md`, source / design files | raw findings → orchestrator |
| `api-contract-reviewer` | `service-context.md`, source / design files | raw findings → orchestrator |
| `language-patterns-reviewer` | `service-context.md`, source / design files | raw findings → orchestrator |
| `performance-checker` | `service-context.md`, source / design files | raw findings → orchestrator |
| `configuration-validator` | `service-context.md`, config files | raw findings → orchestrator |
| `architecture-designer` | `requirements.md` | `architecture-design.md` |
| `schema-designer` | `requirements.md`, `service-context.md` | `schema-design.md` |
| `api-designer` | `requirements.md`, `service-context.md` | `api-design.md` |

---

## Key Design Rules

- `service-context.md` is the shared contract — every specialist agent reads it to adapt to the target service.
- Specialist review agents never write output files directly; they return raw findings to their orchestrator.
- Phase 4 pipeline agents (`sequence-planner`, `code-scaffolder`, `test-planner`) are always launched in parallel; all write into `{output_folder}/pipeline/`.
- Phase 5 runs as a three-step sequence: 5.1 initial review → 5.2 apply Critical+High patches → 5.3 re-review. `implementation-plan.md` and `design-package-summary.md` reflect post-fix findings only.
- Phase 6 calls `production-file-creator` then `production-build-runner` directly — there is no `production-builder` intermediary.
- `full-validator` always invokes `fix-generator` after writing the report — never skipped.
- `review-orchestrator` is a single-pass review (no convergence loop): 3 agents in parallel → synthesise → write report → fix-generator.
- `design-orchestrator` writes Phase 3 design files directly — no delegation to `architecture-designer`, `schema-designer`, or `api-designer`.
- `design-orchestrator` requires explicit user confirmation before starting Phase 4 (pipeline), Phase 5 (review), and Phase 6 (production build).
- Phase 5 (review) is optional — if the user says "skip review" after Phase 4, `design-package-summary.md` is written without the Review Appendix and the pipeline stops (Phase 6 is not offered).
- `powerpoint-generator` is a skill (user-triggered), not part of the automatic pipeline. Users invoke it with `/powerpoint-generator <output-folder>` after the design package is complete.
- Standalone designers (`architecture-designer`, `schema-designer`, `api-designer`) are for isolated redesign only — `design-orchestrator` never calls them.
- All output files must live inside `output_folder` — never next to the requirements file.
- Skills run in the main conversation context; they parse arguments and invoke agents via the Agent tool.

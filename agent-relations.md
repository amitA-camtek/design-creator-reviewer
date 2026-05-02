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
design-     review-       full-         production-build-runner
orchestrator orchestrator  validator     (build only — source created in Phase 4b)
```

---

## .claude/agents/ Folder Structure

```
.claude/agents/
  orchestrators/           design-orchestrator, review-orchestrator, full-validator
  production/              production-file-creator, production-build-runner
  reviewers/               9 specialist agents + fix-generator
  pipeline/                sequence-planner, code-scaffolder, test-planner,
                           quality-gate, test-file-creator, test-runner
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
│  Asks one targeted question at a time:                              │
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
└──────────────────────────────┬──────────────────────────────────────┘
                               │ auto-continues immediately
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 3.5 — Quality gate  (auto-runs, no user confirmation)        │
│                                                                     │
│   quality-gate ──► structured pass/fail report                     │
│                                                                     │
│   Auto-fix loop (up to 3 cycles):                                   │
│   Apply Critical Before→After patches to design files → re-run     │
│   gate until no Critical findings or 3 cycles exhausted             │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ auto-continues immediately
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 3.6 — Fast review  (auto-runs, no user confirmation)         │
│                                                                     │
│   ┌──────────────────┐  ┌────────────────┐  ┌─────────────────┐   │
│   │requirements-     │  │security-       │  │storage-reviewer │   │
│   │checker           │  │reviewer        │  │                 │   │
│   └──────────────────┘  └────────────────┘  └─────────────────┘   │
│               (all 3 in parallel)                                   │
│                                                                     │
│   Auto-apply Critical patches to design files                       │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ auto-continues immediately
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
└──────────────────────────────┬──────────────────────────────────────┘
                               │ auto-continues immediately
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 4b — Unit tests  (auto-runs, no user confirmation)           │
│                                                                     │
│  4b.1  production-file-creator                                      │
│        → Production/{service_name}/  (full source code)            │
│                                                                     │
│  4b.2  test-file-creator                                            │
│        → Production/{service_name}.Tests/  (test files)            │
│                                                                     │
│  4b.3  test-runner                                                  │
│        Auto-fix loop (max 5 cycles) → Production/test-report.md    │
│        Gate: advance if pass rate ≥ 80% OR all Critical-req tests  │
│        pass                                                         │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ auto-continues immediately
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
└──────────────────────────────┬──────────────────────────────────────┘
                               │ auto-continues immediately
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 6 — Production Build                                         │
│                                                                     │
│  6.1  production-build-runner                                       │
│       (source tree already exists from Phase 4b)                   │
│       Build-fix loop (max 10 cycles) → run                         │
│       → Production/run-report.md  or  Production/build-errors.md   │
│                                                                     │
│  6.2  Build-to-design feedback loop (up to 3 outer cycles)         │
│       On failure: patch design → re-spawn production-file-creator  │
│       → re-spawn production-build-runner                            │
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
│   ├── test-report.md            ← Phase 4b (test-runner)
│   ├── run-report.md             ← Phase 6 (production-build-runner, on success)
│   ├── build-errors.md           ← Phase 6 (production-build-runner, on failure)
│   └── {service_name}/           ← Phase 4b (production-file-creator)
│       └── {service_name}.Tests/ ← Phase 4b (test-file-creator)
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
│  │ production-file-creator  — creates full source code (Phase 4b)  │      │
│  │ production-build-runner  — build-fix loop (10 cycles) + run     │      │
│  └────────────────────────────────────────────────────────────────┘      │
│                                                                            │
│  PIPELINE AGENTS  [sonnet]                                                │
│  ┌──────────────────┐  ┌──────────────────┐  ┌─────────────────┐        │
│  │ sequence-planner │  │ code-scaffolder  │  │ test-planner    │  Phase 4│
│  └──────────────────┘  └──────────────────┘  └─────────────────┘        │
│  ┌──────────────────┐  ┌──────────────────┐  ┌─────────────────┐        │
│  │ quality-gate     │  │ test-file-creator│  │ test-runner     │        │
│  │ (Phase 3.5)      │  │ (Phase 4b)       │  │ (Phase 4b)      │        │
│  └──────────────────┘  └──────────────────┘  └─────────────────┘        │
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
| `quality-gate` | `architecture-design.md`, `schema-design.md`, `api-design.md`, `explore/service-context.md` | returns structured findings to orchestrator (no files written) |
| `sequence-planner` | `service-context.md`, `architecture-design.md` | `pipeline/sequence-diagrams.md` |
| `code-scaffolder` | `service-context.md`, `architecture-design.md`, `schema-design.md`, `api-design.md` | `pipeline/code-scaffolding.md` |
| `test-planner` | `requirements.md`, `service-context.md` | `pipeline/test-plan.md` |
| `production-file-creator` | all design files, `service-context.md` | `Production/{service_name}/` (full source tree) |
| `test-file-creator` | `service-context.md`, `pipeline/test-plan.md`, `pipeline/code-scaffolding.md` | `Production/{service_name}/{service_name}.Tests/` (test files + .csproj or equivalent) |
| `test-runner` | `service-context.md`, test files in `Production/` | `Production/test-report.md` |
| `full-validator` | all design files + source code | `review/comprehensive-review-report.md` (invokes `fix-generator` internally → `review/fix-patches.md`) |
| `review-orchestrator` | all design files + source code | `review-report.md` (invokes `fix-generator` internally → `fix-patches.md`) |
| `fix-generator` | `comprehensive-review-report.md` or `review-report.md` | `fix-patches.md` |
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
- Phase 3.5 (`quality-gate`) runs immediately after design files are written — auto-fix loop (up to 3 cycles) on Critical findings only; does not write files.
- Phase 3.6 runs immediately after the quality gate — spawns `requirements-checker`, `security-reviewer`, and `storage-reviewer` in parallel; auto-applies Critical patches to design files only.
- Phase 4 pipeline agents (`sequence-planner`, `code-scaffolder`, `test-planner`) are always launched in parallel; all write into `{output_folder}/pipeline/`.
- Phase 4b runs immediately after Phase 4: `production-file-creator` creates the source tree, `test-file-creator` adds test files, `test-runner` executes tests with a 5-cycle auto-fix loop and writes `Production/test-report.md`.
- `production-file-creator` runs in Phase 4b, not Phase 6. Phase 6 only spawns `production-build-runner` (and re-spawns `production-file-creator` only in the build-to-design feedback loop on failure).
- Phase 5 runs as a three-step sequence: 5.1 initial review → 5.2 apply Critical+High patches → 5.3 re-review. `implementation-plan.md` and `design-package-summary.md` reflect post-fix findings only.
- Phase 6 build-to-design feedback loop (max 3 outer cycles): on build failure, patch design files → re-spawn `production-file-creator` → re-spawn `production-build-runner`.
- `full-validator` always invokes `fix-generator` after writing the report — never skipped.
- `review-orchestrator` is a single-pass review (no convergence loop): 3 agents in parallel → synthesise → write report → fix-generator.
- `design-orchestrator` writes Phase 3 design files directly — no delegation to `architecture-designer`, `schema-designer`, or `api-designer`.
- After Phase 2 approval, all subsequent phases (3 → 3.5 → 3.6 → 4 → 4b → 5 → 6) run automatically without asking "proceed?".
- Phase 5 (review) is skipped if the user said "no review" at the start. Phase 6 (build) is skipped if the user said "design only", "no build", or "stop at design".
- `powerpoint-generator` is a skill (user-triggered), not part of the automatic pipeline.
- Standalone designers (`architecture-designer`, `schema-designer`, `api-designer`) are for isolated redesign only — `design-orchestrator` never calls them.
- All output files must live inside `output_folder` — never next to the requirements file.
- Skills run in the main conversation context; they parse arguments and invoke agents via the Agent tool.

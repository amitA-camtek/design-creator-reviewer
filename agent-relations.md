# Agent Relations — Block Diagram & Flow

## System Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                          USER (Developer)                            │
└───┬─────────────┬──────────────┬──────────────┬───────────────┬─────┘
    │             │              │              │               │
 /design       /review         /build       /powerpoint-      (other
    │             │              │           generator         skills)
    ▼             ▼              ▼              ▼
┌───────────────────────────────────────────────────────────────────┐
│                        SKILLS LAYER                                │
│  design · review · build · powerpoint-generator                   │
│  architecture-designer · schema-designer · api-designer           │
│  ux-designer                                                       │
│  (run in main context — parse args, invoke agents below)          │
└───┬─────────────┬─────────────┬──────────────┬────────────────────┘
    │             │             │              │
    ▼             ▼             ▼              ▼
design-     review-          build-         architecture-designer
orchestrator orchestrator    orchestrator   schema-designer · api-designer
```

---

## .claude/agents/ Folder Structure

```
.claude/agents/
  orchestrators/           design-orchestrator, review-orchestrator,
                           build-orchestrator
  production/              production-file-creator, production-build-runner
  reviewers/               9 specialist agents (incl. ux-reviewer) + fix-generator
  pipeline/                sequence-planner, code-scaffolder, test-planner,
                           quality-gate, test-file-creator, test-runner
  skills/                  design, review, build, powerpoint-generator,
                           architecture-designer, schema-designer, api-designer,
                           ux-designer
```

---

## Design Pipeline — Phase Flow

```
requirements.md
      │
      ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 0 — Requirements Analysis                                    │
│  design-orchestrator reads requirements file                        │
│  Checks context= parameter if provided (locks tech constraints)     │
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
│  Writes design/alternatives.md                                      │
│  Presents summary + asks user to choose                             │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ User selects / requests changes
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 2 — Iterate until approved  (still inside plan mode)         │
│  Revises design/alternatives.md per feedback                        │
│  Loop until user says "approved" → ExitPlanMode                     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ Explicit approval
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 3 — Write design files  (done directly, no delegation)       │
│  design/architecture-design.md  (with YAML front-matter)            │
│  design/schema-design.md        (with YAML front-matter)            │
│  design/api-design.md           (with YAML front-matter)            │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ auto-continues immediately
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 3.x — UX Design  (only when requirements mention a UI)       │
│  Writes design/ux-alternatives.md and design/ux-design.md           │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ auto-continues immediately (or skipped if no UI)
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 3.5 — Quality gate  (auto-runs, no user confirmation)        │
│   quality-gate ──► structured pass/fail report                     │
│   Auto-fix loop (up to 3 cycles) on Critical findings               │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ auto-continues immediately
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 3.6 — Design-only review  (auto-runs)                        │
│                                                                     │
│   review-orchestrator(mode=design-only, auto_patch=true)            │
│                                                                     │
│   Smart auto-skip drops reviewers needing source code:              │
│   skipped: concurrency-reviewer, language-patterns-reviewer,        │
│            requirements-checker (no source yet)                     │
│   runs:    security-reviewer + storage-reviewer + others whose      │
│            inputs are present in front-matter                       │
│                                                                     │
│   Auto-applies Critical patches to design files in-place           │
│   Writes review/review-report.md + review/fix-patches.md            │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ auto-continues immediately
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 4 — Pipeline subagents  (spawned IN PARALLEL)                │
│   sequence-planner · code-scaffolder · test-planner                 │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ auto-continues immediately
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 4b — Unit tests  (auto-runs)                                 │
│  4b.1  production-file-creator  → production/{service_name}/        │
│  4b.2  test-file-creator        → production/{service_name}.Tests/ │
│  4b.3  test-runner              → production/test-report.md         │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ auto-continues immediately
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 5 — Auto-review, auto-fix                                    │
│                                                                     │
│  5.1  review-orchestrator (initial review, source code now present) │
│       Smart auto-skip now keeps concurrency/language/perf checkers  │
│       → review/review-report.md + review/fix-patches.md            │
│                                                                     │
│  5.2  Apply Critical + High patches to design files                 │
│                                                                     │
│  5.3  review-orchestrator again (post-fix re-review)                │
│       overwrites review-report.md + fix-patches.md                  │
│                                                                     │
│  5.4  Write implementation-plan.md  (direct)                        │
│       Write design-package-summary.md  (direct)                     │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ auto-continues immediately
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│  PHASE 6 — Production Build                                         │
│  6.1  production-build-runner — build-fix loop (max 10 cycles)      │
│  6.2  Build-to-design feedback loop (up to 3 outer cycles)         │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Output Folder Structure

```
{output_folder}/
├── implementation-plan.md        ← Phase 5
├── design-package-summary.md     ← Phase 5
│
├── design/
│   ├── alternatives.md           ← Phase 1 / Phase 2 (iterations)
│   ├── architecture-design.md    ← Phase 3 (with YAML front-matter)
│   ├── schema-design.md          ← Phase 3 (with YAML front-matter)
│   ├── api-design.md             ← Phase 3 (with YAML front-matter)
│   ├── ux-alternatives.md        ← Phase 3.x (only if service has UI)
│   └── ux-design.md              ← Phase 3.x (only if service has UI, with YAML front-matter)
│
├── pipeline/
│   ├── sequence-diagrams.md      ← Phase 4 (sequence-planner)
│   ├── code-scaffolding.md       ← Phase 4 (code-scaffolder)
│   └── test-plan.md              ← Phase 4 (test-planner)
│
├── review/
│   ├── requirements-check.md     ← Phase 5 (only if reviewer survived skip)
│   ├── security-review.md        ← Phase 3.6 / Phase 5 (always — never skipped)
│   ├── storage-review.md         ← Phase 3.6 / Phase 5 (only if storage layer present)
│   ├── concurrency-review.md     ← Phase 5 (only when source code present)
│   ├── api-contract-review.md    ← Phase 5 (only if api-design has endpoints)
│   ├── language-patterns-review.md  ← Phase 5 (only when source code present)
│   ├── performance-check.md      ← Phase 5 (only if perf_targets are defined)
│   ├── configuration-validation.md  ← Phase 5 (only if required_config_keys present)
│   ├── ux-review.md                 ← Phase 5 (only if ux-design.md exists)
│   ├── review-report.md             ← Phase 3.6 / Phase 5 (synthesised report)
│   └── fix-patches.md               ← Phase 3.6 / Phase 5 (fix-generator)
│
├── production/
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

## Review Pipeline — Single Entry Point with Smart Auto-Skip

There is one review orchestrator. Every caller — `/review` skill, design-orchestrator's Phase 3.6, design-orchestrator's Phase 5, and design-orchestrator's review mode — invokes the same agent. Its smart auto-skip pass determines which specialists actually run, based on what the target folder contains.

```
User triggers review or design-orchestrator reaches a review phase
        │
        ├── /review <folder> [agents=…] [force_run_all=true] ─────┐
        │                                                          │
        ├── design-orchestrator Phase 3.6                          │
        │   (mode=design-only, auto_patch=true) ──────────────────┤
        │                                                          │
        ├── design-orchestrator Phase 5.1 / 5.3 ──────────────────┤
        │                                                          │
        └── design-orchestrator Review mode ──────────────────────►┤
                                                                   │
                                                                   ▼
                                                       review-orchestrator
                                                                   │
                                              ┌────────────────────┘
                                              ▼
                                  Smart auto-skip pass
                                  (drops candidates whose inputs
                                  aren't present)
                                              │
                                              ▼
                          Spawn surviving agents in parallel
                          (any subset of the 9 specialists below)
```

### Specialist agent set (any subset can run)

```
┌──────────────────┐  ┌────────────────┐  ┌─────────────────────┐
│requirements-     │  │security-       │  │storage-reviewer     │
│checker           │  │reviewer        │  │                     │
│                  │  │(NEVER skipped) │  │                     │
└──────────────────┘  └────────────────┘  └─────────────────────┘
┌──────────────────┐  ┌────────────────┐  ┌─────────────────────┐
│concurrency-      │  │api-contract-   │  │language-patterns-   │
│reviewer          │  │reviewer        │  │reviewer             │
└──────────────────┘  └────────────────┘  └─────────────────────┘
┌──────────────────┐  ┌────────────────┐  ┌─────────────────────┐
│performance-      │  │configuration-  │  │ux-reviewer          │
│checker           │  │validator       │  │                     │
└──────────────────┘  └────────────────┘  └─────────────────────┘
                              │
                              ▼
                  Surviving agents synthesise findings
                              │
                              ▼
                       review-report.md
                              │
                              ▼
                       fix-generator
                              │
                              ▼
                        fix-patches.md
                              │
                              ▼
            (only if auto_patch=true) Apply Critical
            patches in-place to design files
```

### Auto-skip rules

| Reviewer | Skip when |
|---|---|
| `requirements-checker` | no `requirements` parameter AND no `requirement_id_prefixes` in architecture front-matter |
| `storage-reviewer` | `design/schema-design.md` missing OR `storage_technology` empty/`none` |
| `api-contract-reviewer` | `design/api-design.md` missing OR `api_binding` empty OR body says "N/A — no HTTP API" |
| `performance-checker` | `perf_targets` empty in architecture front-matter |
| `configuration-validator` | `required_config_keys` empty in architecture front-matter |
| `concurrency-reviewer` | `mode=design-only` OR no source files under `production/` |
| `language-patterns-reviewer` | `mode=design-only` OR no source files under `production/` |
| `ux-reviewer` | `design/ux-design.md` missing |
| `security-reviewer` | **Never** — universal OWASP checks always apply |

### Override knobs

- `agents=security,storage` — only those exact agents run; auto-skip is bypassed.
- `force_run_all=true` — auto-skip is disabled; every candidate runs even if its inputs are absent.

---

## Complete Agent Catalogue

```
┌──────────────────────────────────────────────────────────────────────────┐
│  SKILLS  (user slash commands — run in main context)                      │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │ /design                → invokes design-orchestrator                │ │
│  │ /review                → invokes review-orchestrator                │ │
│  │ /build                 → invokes build-orchestrator                 │ │
│  │ /powerpoint-generator  → generates .pptx from design package       │ │
│  │ /architecture-designer → architecture-designer (isolated redesign) │ │
│  │ /schema-designer       → schema-designer (isolated redesign)       │ │
│  │ /api-designer          → api-designer (isolated redesign)          │ │
│  │ /ux-designer           → ux-designer (isolated UX redesign)        │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                            │
│  ORCHESTRATORS  [opus]                                                    │
│  ┌───────────────────────────────────────────────────────────────────┐   │
│  │ design-orchestrator  — full design lifecycle OR review entry       │   │
│  │ build-orchestrator   — build pipeline: source → tests → build     │   │
│  │ review-orchestrator  — single review entry point with smart skip  │   │
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
│  SPECIALIST REVIEWERS  (used by review-orchestrator, auto-selected)      │
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
│  ┌─────────────────────────┐  ┌──────────────────────────────────┐       │
│  │ fix-generator  [sonnet] │  │ ux-reviewer  [sonnet]            │       │
│  │                         │  │ (only when ux-design.md exists)  │       │
│  └─────────────────────────┘  └──────────────────────────────────┘       │
│                                                                            │
│  STANDALONE REDESIGN SKILLS  (user-invoked for isolated redesign only)   │
│  All live in skills/ — design-orchestrator never calls them directly     │
│  ┌──────────────────────┐  ┌──────────────────┐  ┌───────────────┐      │
│  │ architecture-designer│  │ schema-designer  │  │ api-designer  │      │
│  │ [opus]               │  │ [sonnet]         │  │ [sonnet]      │      │
│  └──────────────────────┘  └──────────────────┘  └───────────────┘      │
│  ┌──────────────────────┐                                                │
│  │ ux-designer  [opus]  │  ← also runs inline by design-orchestrator    │
│  │                      │    when UI detected (Phase 3.x, plan mode)    │
│  └──────────────────────┘                                                │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Input / Output Files per Agent

Context for all agents comes from YAML front-matter embedded in the design files under `{output_folder}/design/`. No separate context file is needed.

| Agent | Reads | Writes |
|---|---|---|
| `design-orchestrator` | `requirements.md`, optional `context=<file>` | `design/alternatives.md`, `design/architecture-design.md`, `design/schema-design.md`, `design/api-design.md`, `implementation-plan.md`, `design-package-summary.md` |
| `build-orchestrator` | design files in `output_folder/design/` | orchestrates `production-file-creator` → `test-file-creator` → `test-runner` → `production-build-runner`; writes `production/test-report.md`, `production/run-report.md` or `production/build-errors.md` |
| `review-orchestrator` | `design/` folder + source code | `review/review-report.md` (invokes `fix-generator` internally → `review/fix-patches.md`) |
| `quality-gate` | `design/architecture-design.md`, `design/schema-design.md`, `design/api-design.md` (front-matter + content) | returns structured findings to orchestrator (no files written) |
| `sequence-planner` | `design/architecture-design.md` front-matter + content | `pipeline/sequence-diagrams.md` |
| `code-scaffolder` | `design/architecture-design.md` front-matter, `design/schema-design.md`, `design/api-design.md` front-matter | `pipeline/code-scaffolding.md` |
| `test-planner` | `requirements.md`, `design/architecture-design.md` front-matter | `pipeline/test-plan.md` |
| `production-file-creator` | `design/architecture-design.md`, `design/schema-design.md`, `design/api-design.md`, `pipeline/code-scaffolding.md` | `production/{service_name}/` (full source tree) |
| `test-file-creator` | `design/architecture-design.md` front-matter, `design/api-design.md` front-matter, `pipeline/test-plan.md`, `pipeline/code-scaffolding.md` | `production/{service_name}/{service_name}.Tests/` (test files + .csproj or equivalent) |
| `test-runner` | `design/architecture-design.md` front-matter, test files in `production/` | `production/test-report.md` |
| `fix-generator` | `review/review-report.md` | `review/fix-patches.md` |
| `production-build-runner` | source files in `production_root` | `production/run-report.md` or `production/build-errors.md` |
| `powerpoint-generator` (skill) | `design/alternatives.md`, `design/architecture-design.md`, `design/schema-design.md`, `design/api-design.md`, `design-package-summary.md` | `assets/{service_name}-design.pptx` |
| `requirements-checker` | `requirements.md`, `design/architecture-design.md` front-matter, source / design files | `review/requirements-check.md` |
| `security-reviewer` | `design/architecture-design.md` front-matter (threat_model), `design/api-design.md` front-matter (sensitive_fields, api_auth), source / design files | `review/security-review.md` |
| `storage-reviewer` | `design/schema-design.md` front-matter (storage_technology), source / design files | `review/storage-review.md` |
| `concurrency-reviewer` | `design/architecture-design.md` front-matter (primary_language, runtime), source files | `review/concurrency-review.md` |
| `api-contract-reviewer` | `design/api-design.md` front-matter (api_binding, required_endpoints, sensitive_fields, api_auth), source files | `review/api-contract-review.md` |
| `language-patterns-reviewer` | `design/architecture-design.md` front-matter (primary_language, runtime), `design/api-design.md` front-matter (sensitive_fields), source files | `review/language-patterns-review.md` |
| `performance-checker` | `design/architecture-design.md` front-matter (perf_targets, components), source files | `review/performance-check.md` |
| `configuration-validator` | `design/architecture-design.md` front-matter (required_config_keys), `design/api-design.md` front-matter (api_binding, api_auth), config files | `review/configuration-validation.md` |
| `architecture-designer` | `requirements.md` | `design/architecture-design.md` (with YAML front-matter) |
| `schema-designer` | `requirements.md`, `design/architecture-design.md` front-matter | `design/schema-design.md` (with YAML front-matter) |
| `api-designer` | `requirements.md`, `design/architecture-design.md` front-matter, `design/schema-design.md` front-matter | `design/api-design.md` (with YAML front-matter) |
| `ux-designer` | `requirements.md`, `design/architecture-design.md` front-matter (optional), `design/ux-design.md` front-matter (optional, as constraints) | `design/ux-alternatives.md`, `design/ux-design.md` (with YAML front-matter) |
| `ux-reviewer` | `design/ux-design.md` front-matter (ui_framework, component_library, layout_pattern, key_screens, responsive, accessibility_level, theme), frontend source files in `production/` | `review/ux-review.md` |

---

## Pipeline Manifest

`.claude/pipeline.yaml` is the central configuration file that controls which agents run in each phase. All three orchestrators read it at startup; if absent, built-in defaults are used.

```
.claude/pipeline.yaml
      │
      ├── phases.quality-gate.agents      → Phase 3.5 (design-orchestrator)
      ├── phases.scaffolding.agents       → Phase 4   (design-orchestrator)
      ├── phases.unit-tests.sequence      → Phase 4b  (design-orchestrator)
      ├── phases.review.agents            → Phase 3.6 + Phase 5 (review-orchestrator
      │                                                         applies smart auto-skip)
      └── phases.production-build.*       → Phase 6   (design-orchestrator + build-orchestrator)
```

To add a new specialist agent to all reviews: add its name to `phases.review.agents`. The orchestrator's auto-skip pass will only invoke it on calls where its inputs are present. No orchestrator changes needed.

---

## Key Design Rules

- Design context (service_name, primary_language, runtime, components, threat_model, perf_targets, etc.) lives in YAML front-matter within the design files under `{output_folder}/design/`. No separate context file is needed.
- Each design file owns its own metadata: architecture-design.md owns language/runtime/components, schema-design.md owns storage technology, api-design.md owns API binding/auth/sensitive fields.
- Specialist review agents never write output files directly to the orchestrator; they write to `review/` and return a summary.
- `review-orchestrator` is the single review entry point. It reads `phases.review.agents` from the manifest, applies smart auto-skip based on what the target folder contains, and synthesises a single `review-report.md`. `fix-generator` always runs after.
- Smart auto-skip: agents whose inputs aren't present are dropped. `security-reviewer` is never skipped. `agents=…` and `force_run_all=true` are escape hatches.
- Phase 3.5 (`quality-gate`) runs immediately after design files are written — validates front-matter completeness; auto-fix loop (up to 3 cycles) on Critical findings only.
- Phase 3.6 invokes `review-orchestrator` with `mode=design-only` and `auto_patch=true`. Smart auto-skip drops code-level reviewers because no source has been generated yet. Critical patches are applied to design files in-place.
- Phase 4 pipeline agents (`sequence-planner`, `code-scaffolder`, `test-planner`) are always launched in parallel; all write into `{output_folder}/pipeline/`.
- Phase 4b runs immediately after Phase 4: `production-file-creator` creates the source tree, `test-file-creator` adds test files, `test-runner` executes tests with a 5-cycle auto-fix loop and writes `production/test-report.md`.
- `production-file-creator` runs in Phase 4b, not Phase 6. Phase 6 only spawns `production-build-runner` (and re-spawns `production-file-creator` only in the build-to-design feedback loop on failure).
- Phase 5 runs as a three-step sequence: 5.1 initial review → 5.2 apply Critical+High patches → 5.3 re-review. `implementation-plan.md` and `design-package-summary.md` reflect post-fix findings only. By this phase, source code exists, so most reviewers survive auto-skip.
- Phase 6 build-to-design feedback loop (max 3 outer cycles): on build failure, patch design files → re-spawn `production-file-creator` → re-spawn `production-build-runner`.
- `design-orchestrator` writes Phase 3 design files directly — no delegation to `architecture-designer`, `schema-designer`, or `api-designer`.
- `design-orchestrator` detects UI presence in Phase 0 (keyword scan). If `has_ui: true`, Phase 3.x runs inline between Phase 3 and Phase 3.5.
- After Phase 2 approval, all subsequent phases (3 → 3.5 → 3.6 → 4 → 4b → 5 → 6) run automatically without asking "proceed?".
- Phase 5 (review) is skipped if the user said "no review" at the start. Phase 6 (build) is skipped if the user said "design only", "no build", or "stop at design".
- `powerpoint-generator` is a skill (user-triggered), not part of the automatic pipeline.
- Standalone redesign skills (`architecture-designer`, `schema-designer`, `api-designer`) live in `skills/` and are for isolated redesign only — `design-orchestrator` never calls them.
- All output files must live inside `output_folder` — never next to the requirements file.
- Skills run in the main conversation context; they parse arguments and invoke agents via the Agent tool.

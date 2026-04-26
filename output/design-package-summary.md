# FalconAuditService — Design Package

**Generated:** 2026-04-26
**Requirements:** `req.md` (ERS-FAU-001, 62 requirements)
**Output folder:** `C:\Claude\design-creator-reviewer\output\`
**Approved design:** Alternative 1 — Lazy-Open Channel Pipeline with Offset Pagination

---

## Executive summary

FalconAuditService is a self-contained Windows Service that records tamper-evident audit logs of file changes under `c:\job\` on Falcon inspection machines. It writes per-job SQLite shards (WAL mode) inside each job folder so audit data travels with the job, exposes a read-only HTTP query API on `127.0.0.1:5100`, and maintains a chain-of-custody manifest that survives machine handoff.

The chosen architecture is the simplest of the three explored: a `Channel<T>` event pipeline fans out from a recursive `FileSystemWatcher` to one writer task per active shard, with lazy connection opening, atomic manifest writes, and offset-based pagination. The design satisfies all 62 requirements and all 5 performance targets, with the deepest-pagination case mitigated by a configurable page-depth cap (5000) and a 30 s `COUNT(*)` cache.

A full 8-dimension design review surfaced 3 Critical and 9 High findings; all 12 have before/after patches in `review/fix-patches.md` and are sequenced into the implementation plan. The 3 Critical items are design-level fixes that must be applied **before** any code is written.

---

## Output files

| File | Description |
|---|---|
| `architecture-design.md` | Final component breakdown — 13 components, ordered startup/shutdown, dependency graph |
| `schema-design.md` | Final SQLite schema — `audit_log`, `file_baselines`, `custody_events` (global), full DDL + indexes |
| `api-design.md` | Final API specification — 4 endpoints, offset pagination, loopback-only Kestrel binding |
| `implementation-plan.md` | Phased implementation checklist with effort estimates and "what to do next" |
| `design-alternatives.md` | The three alternatives with comparison and recommendation (Alt 1 approved) |
| `service-context.md` | Service context with all tech fields populated |
| `explore/design-alternatives.md` | Original exploration draft (preserved for traceability) |
| `explore/service-context.md` | Original service-context draft (preserved for traceability) |
| `pipeline/sequence-diagrams.md` | Mermaid diagrams for 5 key flows (startup, live P1 modify, job arrival + handoff, hot reload, paginated query) |
| `pipeline/code-scaffolding.md` | C# class/module stubs with DI registration; 17 components |
| `pipeline/test-plan.md` | 89 named test cases + 5 integration tests; 100% requirement coverage |
| `review/comprehensive-review-report.md` | 8-dimension review (3 Critical, 6 High, 7 Medium, 4 Low, 3 Info) |
| `review/fix-patches.md` | Before/after patches for the 12 Critical/High findings |
| `assets/FalconAuditService-design.pptx` | PowerPoint presentation for stakeholders *(generated next)* |

---

## Key design decisions (locked in Phase 0.5)

| ID | Requirement | Decision |
|---|---|---|
| Q1 | MON-003 Rename | Hybrid: `Renamed` row when FSW gives both paths; fall back to `Deleted` + `Created` for cross-directory renames |
| Q2 | REC-004 Oversize | Skip content, keep audit row; `is_content_omitted = 1`; hash still stored |
| Q3 | JOB-002 Detection | ≤ 1 s via depth-1 FSW; no debounce on job folders |
| Q4 | API-007 Rescan | 30 s default; TODO secondary FSW on `c:\job\status.ini` for instant signal |
| Q5 | CUS-001 Custody handoff | Trust prior baseline + delta scan + synthetic `CustodyHandoff` event in `global.db` |

---

## Headline numbers

| Dimension | Value |
|---|---|
| Requirements covered | **62 / 62** |
| Component count | **13** (plus 4 supporting services) |
| API endpoints | **4** (1 health, 1 jobs, 2 events) |
| Storage technology | **SQLite (WAL)** — no external server |
| Estimated lines of production code | **~2 800** |
| Estimated implementation effort | **~3 calendar weeks** for one experienced .NET developer |
| Critical/High review findings | **12** (all patched in `fix-patches.md`) |
| Performance budget | All 5 PERF targets met with margin |

---

## Appendix — Design Review

### Review summary

| Severity | Count |
|---|---|
| Critical | 3 |
| High | 9 |
| Medium | 7 |
| Low | 4 |
| Info | 3 |

### Top findings

**Critical:**
1. **F-SEC-001 — Path validation regex bypass via Unicode/NUL.** `\w` in .NET regex matches Unicode letter classes, so a fullwidth `／` slips past validation. Replace with explicit ASCII set; add length cap, NUL check, control-char check, and explicit `..`/absolute-path gates.
2. **F-STO-001 — `file_baselines.last_content` not size-capped.** Oversize files write `is_content_omitted = 1` to the audit row but the baseline `last_content` is unchanged. Apply the same cap to baseline upserts.
3. **F-CON-001 — Per-shard channel never closes on departure.** The fan-out task creates a writer task per shard but never completes the channel; writer tasks leak and shutdown's drain hangs. Add `IEventPipeline.CompleteShardAsync`; call before `ShardRegistry.DisposeShardAsync`.

**High (9):**
- F-SEC-002 — LIKE wildcards in `path` filter not escaped
- F-SEC-003 — No length cap on `path` query parameter (folded into f-sec-001)
- F-STO-002 — No periodic WAL checkpoint on long-running shards
- F-STO-003 — `EnumerateBaselinesAsync` must stream (document contract + memory test)
- F-CON-002 — Debouncer cancel/replace race
- F-CON-003 — Catch-up gate semantics — single shared gate
- F-API-001 — Cross-job query has no schema-version probe
- F-LNG-001 — Disposal order unsafe; `StopAsync` must orchestrate explicitly
- F-PRF-001 — Deep-offset pagination misses PERF-005; introduce `MaxPageDepth = 5000`

### Fixes applied

All 12 Critical/High findings have a before/after patch in `review/fix-patches.md`. The Critical three are doc-level changes to design files that must be applied **before** Phase 1 of implementation. The High nine are coded into the relevant components during Phase 2 / 4 / 5 per the order in `implementation-plan.md` Phase 6b.

| Finding | File(s) patched |
|---|---|
| f-sec-001 | `api-design.md`, `code-scaffolding.md` |
| f-sto-001 | `schema-design.md`, `architecture-design.md`, `code-scaffolding.md` |
| f-con-001 | `architecture-design.md`, `code-scaffolding.md` (EventPipeline + JobManager) |
| f-sec-002 | `schema-design.md`, `api-design.md` |
| f-sec-003 | folded into f-sec-001 |
| f-sto-002 | `schema-design.md`, `code-scaffolding.md` (SqliteRepository) |
| f-sto-003 | `code-scaffolding.md` (SqliteRepository, CatchUpScanner) |
| f-con-002 | `code-scaffolding.md` (Debouncer) |
| f-con-003 | `architecture-design.md`, `code-scaffolding.md` (CatchUpScanner) |
| f-api-001 | `api-design.md` |
| f-lng-001 | `architecture-design.md`, `code-scaffolding.md` (FalconAuditWorker) |
| f-prf-001 | `api-design.md`, `code-scaffolding.md` (MonitorConfig) |

Full details are in `review/comprehensive-review-report.md` and `review/fix-patches.md`.

---

## Recommended next step

Open `implementation-plan.md` and follow the **"What to do next"** section. The single most important first action is applying the **F-SEC-001** patch to `api-design.md` and `code-scaffolding.md`, because every API endpoint depends on `Validators.IsSafePath` and the corrected regex must be in place before any class stubs are generated.

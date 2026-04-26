# FalconAuditService — Implementation Plan

**Document ID:** PLN-FAU-001
**Generated:** 2026-04-26
**Approved design:** Alternative 1 — Lazy-Open Channel Pipeline with Offset Pagination
**Requirements:** ERS-FAU-001 (62 requirements)

---

## Overview

We are building **FalconAuditService**, a .NET 6 Windows Service that monitors `c:\job\` on Falcon inspection machines and records tamper-evident audit logs to per-job SQLite shards. The chosen technology stack is C# 10 / .NET 6 LTS with `Microsoft.Data.Sqlite` (WAL mode) for storage, `System.Threading.Channels` for the event pipeline, ASP.NET Core minimal API on Kestrel for the read-only HTTP query API, Serilog for logging (rolling file + Windows Event Log), and DiffPlex for unified diffs.

The implementation sequence is: (Phase 6a) apply three blocking design fixes from the review; (Phase 1) environment setup; (Phase 2) core leaf components in dependency order; (Phase 3) storage layer with full DDL; (Phase 4) API endpoints; (Phase 5) wiring and testing per `pipeline/sequence-diagrams.md`; (Phase 6b) absorb the remaining nine implementation must-fixes during coding; (Phase 7) deployment via `install.ps1`. The single most important first action is applying the three Critical patches in Phase 6a — none of the downstream code is correct without them.

---

## Phase 1 — Environment setup

- [ ] Install **.NET 6 SDK 6.0.x** on the developer machine
- [ ] Install Visual Studio 2022 17.x or `dotnet` CLI; ensure `dotnet --info` shows .NET 6 SDK
- [ ] Confirm Windows 10 / Server 2019+ target host (no other infra dependency — SQLite is embedded)
- [ ] Create the solution skeleton per `pipeline/code-scaffolding.md` §1:
  ```
  dotnet new sln -n FalconAuditService
  dotnet new worker -n FalconAuditService -o src/FalconAuditService -f net6.0
  dotnet new xunit  -n FalconAuditService.Tests -o tests/FalconAuditService.Tests -f net6.0
  dotnet sln add src/FalconAuditService tests/FalconAuditService.Tests
  ```
- [ ] Add NuGet packages from `code-scaffolding.md` §2: `Microsoft.Data.Sqlite`, `Microsoft.Extensions.Hosting.WindowsServices`, `Serilog.Extensions.Hosting`, `Serilog.Sinks.File`, `Serilog.Sinks.EventLog`, `DiffPlex`, `Swashbuckle.AspNetCore`. Test project: `xunit`, `FluentAssertions`, `Moq`, `Microsoft.AspNetCore.Mvc.Testing`.
- [ ] Add `<FrameworkReference Include="Microsoft.AspNetCore.App" />` to the worker project (enables minimal-API hosting in a worker)
- [ ] Configure logging skeleton: copy the Serilog block from `architecture-design.md` §6.3 into `appsettings.json`
- [ ] Create empty `MonitorConfig` POCO and bind it in `Program.cs`
- [ ] Verify `dotnet build` is green

---

## Phase 2 — Core components (leaf-first dependency order)

Build components leaf-first so each one's dependencies are real, not stubs. Each item maps to one or more requirement groups.

- [ ] **HashService** — implements `ComputeWithRetryAsync` with **exponential** back-off (100/200/400 ms) — req group: REC-009 (also F-PRF-002 fix)
- [ ] **DiffService** — wraps DiffPlex `UnifiedDiffBuilder` — req group: REC-005
- [ ] **ManifestManager** — atomic temp-file rename writes; per-job `SemaphoreSlim` gate; cache mutations under gate (F-CON-004) — req groups: STR-003, JOB-007, REL-003
- [ ] **ClassificationRulesLoader** — load + `Interlocked.Exchange` swap; secondary FSW; reject invalid JSON without dropping prior set — req groups: CLS, REL-006
- [ ] **FileClassifier** — first-match-wins over `ImmutableList<CompiledRule>`; capture snapshot to local var (F-CON-005) — req groups: CLS-003/004/007/008
- [ ] **SqliteRepository** — open + PRAGMAs (incl. `wal_autocheckpoint`); ensure schema; `Append`, `Upsert`, `GetBaseline`, `EnumerateBaselinesAsync` (streaming, F-STO-003), `CheckpointAsync` (new method, F-STO-002), `DisposeAsync` — req groups: STR-004/005/006/007/008, CON-004
- [ ] **GlobalRepository** — same surface as `SqliteRepository` plus `AppendCustodyEventAsync` — req groups: STR-002, Q5
- [ ] **ShardRegistry** — `ConcurrentDictionary<string, Lazy<SqliteRepository>>`; `GetOrAdd` returns `.Value` (F-LNG-003); `DisposeShardAsync` < 5 s — req groups: STR-001/005/007/008, REL-007
- [ ] **Validators** — apply f-sec-001 patch verbatim (ASCII regex + length cap + NUL/control-char/`..` checks) — req groups: API-008, CON-005
- [ ] **Debouncer** — `Push` uses cancel-then-replace via `AddOrUpdate`; `FireAfterDelayAsync` checks cancellation post-await (F-CON-002) — req groups: MON-004
- [ ] **EventRecorder** — implements all of REC; oversize check applies to BOTH the audit row AND `last_content` baseline (F-STO-001); honours `capture_content` toggle — req groups: REC, REL-004
- [ ] **EventPipeline** — global `Channel<T>(1000, Wait)`; per-shard `Channel<T>(200, Wait)`; fan-out task; one writer task per shard; new `CompleteShardAsync` method (F-CON-001) — req groups: REL-001, REL-005, STR-005
- [ ] **FileMonitor** — recursive FSW with configured buffer size; `Renamed` handling per Q1; on `Error` recreate FSW + trigger full catch-up — req groups: MON-001/002/003/005/006
- [ ] **DirectoryWatcher** — depth-1 FSW, no debounce, ≤ 1 s detection — req groups: JOB-002 (Q3)
- [ ] **CatchUpScanner** — single shared gate covering both `QueueJobAsync` and `ScanAllAsync` (F-CON-003); yields when `EventPipeline.PendingCount > catchup_yield_threshold`; emits Created/Modified/Deleted from baseline diff — req groups: CUS, SVC-007, REL-002
- [ ] **JobManager** — arrival/departure handlers; departure ORDER per F-CON-001 patch (`CompleteShardAsync` BEFORE `DisposeShardAsync`); custody-handoff detection (Q5) — req groups: JOB
- [ ] **JobDiscoveryService** — periodic 30 s rescan; refresh on arrival/departure; status.ini FSW marked `TODO-API-007-FAST` — req groups: API-007 (Q4)
- [ ] **FalconAuditWorker** — composition root; ordered `StartAsync` (FSW before catch-up — SVC-003); ordered `StopAsync` per F-LNG-001 — req groups: SVC

---

## Phase 3 — Storage layer

- [ ] Apply DDL from `schema-design.md` §4 (audit_log, file_baselines, indexes) and §5 (custody_events for global DB)
- [ ] Apply PRAGMAs from `schema-design.md` §3 at every connection open
- [ ] Implement parameterised queries from `schema-design.md` §7 (no string concatenation — CON-004)
- [ ] Add `_meta.schema_version` row (`'1'`) per `schema-design.md` §6 — needed by F-API-001 fix
- [ ] Verify WAL is active by reading `PRAGMA journal_mode;` during `OpenAsync` and asserting `wal`
- [ ] Hook periodic `CheckpointAsync(WalCheckpointMode.Passive)` into the shard's writer task (every 1000 events or 10 minutes)
- [ ] Implement migration runner per `schema-design.md` §6 (idempotent `IF NOT EXISTS`; even though v1 has no migrations, the framework needs to be in place)

---

## Phase 4 — API / interface layer

- [ ] Implement `Validators` per the f-sec-001 patch (this is part of Phase 2 but called out here because the API depends on it directly)
- [ ] Implement `GET /api/health` — trivial; no DB
- [ ] Implement `GET /api/jobs` — reads `JobDiscoveryService.CurrentJobs` only (no DB)
- [ ] Implement `GET /api/events`:
  - Validate `job`, `path`, `priority`, `from`, `to`, `event_type`, `limit`, `offset`
  - Enforce `offset + limit <= MaxPageDepth` (default 5000) per F-PRF-001
  - Escape `%`, `_`, `\` in `path` before binding to `LIKE` (F-SEC-002)
  - Open `Mode=ReadOnly` connection per request
  - Probe `_meta.schema_version` on cross-job queries; skip mismatched shards (F-API-001)
  - Run page query and `COUNT(*)` in parallel
  - Cache `COUNT` result in `IMemoryCache` keyed by `(jobName, filterHash)` for `count_cache_seconds`; cap cache size to 1000 entries (F-PRF-003)
  - Project to `EventListItemDto` — explicitly excludes `old_content` and `diff_text` (API-006)
- [ ] Implement `GET /api/events/{job}/{id}` — single-event detail; this is the **only** endpoint that returns sensitive fields
- [ ] Wire ASP.NET Core exception handler middleware that returns `{ "error": { "code": "INTERNAL", "message": "..." } }` and never leaks stack traces (CON-006)
- [ ] Add request-logging middleware via Serilog request enrichment

---

## Phase 5 — Integration and testing

- [ ] Wire components in `Program.cs` per `code-scaffolding.md` §3 (DI registration)
- [ ] Implement startup/shutdown ordering in `FalconAuditWorker` per `architecture-design.md` §1 (with the F-LNG-001 fix)
- [ ] Validate the 5 sequence diagrams in `pipeline/sequence-diagrams.md` end-to-end:
  - Flow 1 (Startup) — covered by T-SVC-003, T-SVC-007, T-PERF-001
  - Flow 2 (Live P1 modify) — covered by T-INT-01, T-PERF-002
  - Flow 3 (Job arrival + handoff) — covered by T-INT-02
  - Flow 4 (Hot reload) — covered by T-INT-03, T-PERF-003
  - Flow 5 (Paginated query) — covered by T-INT-01 (read leg) and T-PERF-005
- [ ] Execute test cases from `pipeline/test-plan.md` in this order:
  1. Unit tests by component (Phase 2 leaf-first order)
  2. Storage/concurrency integration (`T-STR-005`, `T-REL-005`)
  3. End-to-end integration (`T-INT-*`)
  4. Performance tests (`T-PERF-*`) — last, after the above are green
- [ ] Validate every PERF requirement from `service-context.md`:
  - PERF-001 (FSW < 600 ms) — `T-PERF-001`
  - PERF-002 (P1 write < 1 s) — `T-PERF-002`
  - PERF-003 (rules reload < 2 s) — `T-PERF-003`
  - PERF-004 (catch-up < 5 s for 10×150) — `T-PERF-004`
  - PERF-005 (API page p95 < 200 ms) — `T-PERF-005`
- [ ] Add static-analysis test `T-CON-004` (Roslyn rule asserting no string concatenation in `SqliteCommand.CommandText`)

---

## Phase 6 — Critical fixes (from design review)

Twelve Critical or High findings from `review/comprehensive-review-report.md`. Three must be applied to the design before any code is written; nine are absorbed during implementation.

### Phase 6a — Design blockers (fix before writing any code)

These three findings change the design files themselves. Apply each patch from `review/fix-patches.md` BEFORE Phase 1, in this order:

- [ ] **[BLOCKING]** F-SEC-001 — Path validation regex bypass via Unicode/NUL — patch: `review/fix-patches.md#f-sec-001`
   *Why first:* every API endpoint depends on `Validators.IsSafePath`. A wrong regex here means every other security control downstream is built on sand. Apply this patch to `api-design.md` §1.3 and to `code-scaffolding.md` §14 before generating any class stubs.
- [ ] **[BLOCKING]** F-STO-001 — `file_baselines.last_content` not size-capped — patch: `review/fix-patches.md#f-sto-001`
   *Why second:* this is a schema-level decision. The DDL in `schema-design.md` §4.2 must be updated AND the `EventRecorder.RecordAsync` contract in `architecture-design.md` §2.6 must be updated before storage code is written. Touching it later means rewriting both layers.
- [ ] **[BLOCKING]** F-CON-001 — Per-shard channel never closes on departure → writer task leaks — patch: `review/fix-patches.md#f-con-001`
   *Why third:* this changes the `IEventPipeline` interface (adds `CompleteShardAsync`) AND the `JobManager.OnDepartureAsync` contract (specifies the call order). Both surface in the dependency graph; the components depend on the corrected interface from day one.

### Phase 6b — Implementation must-fixes (resolve during coding)

These nine are fixed inside the code as the corresponding component is built. Each is grouped by component and ordered by dependency:

**Validators (Phase 2 prerequisite)**
- [ ] F-SEC-002: LIKE wildcards in `path` filter not escaped — escape `%`, `_`, `\` before binding — patch: `review/fix-patches.md#f-sec-002`
- [ ] F-SEC-003: No length cap on `path` query parameter — folded into f-sec-001 (length check is the first gate) — patch: `review/fix-patches.md#f-sec-003`

**SqliteRepository (Phase 2)**
- [ ] F-STO-002: No periodic WAL checkpoint — add `CheckpointAsync` and call from writer task every 1000 events / 10 min — patch: `review/fix-patches.md#f-sto-002`
- [ ] F-STO-003: `EnumerateBaselinesAsync` must stream — document the contract; add memory test — patch: `review/fix-patches.md#f-sto-003`

**Debouncer (Phase 2)**
- [ ] F-CON-002: cancel-then-replace race — use `AddOrUpdate` with side-effect-then-return; check cancellation post-await — patch: `review/fix-patches.md#f-con-002`

**CatchUpScanner (Phase 2)**
- [ ] F-CON-003: catch-up gate semantics — single shared gate for `QueueJobAsync` and `ScanAllAsync` — patch: `review/fix-patches.md#f-con-003`

**FalconAuditWorker (Phase 5)**
- [ ] F-LNG-001: explicit ordered shutdown in `StopAsync` — do not rely on DI reverse-disposal — patch: `review/fix-patches.md#f-lng-001`

**API endpoints (Phase 4)**
- [ ] F-API-001: cross-job query schema-version probe — skip mismatched shards; include `skipped_shards` in response — patch: `review/fix-patches.md#f-api-001`
- [ ] F-PRF-001: deep-offset pagination cap — enforce `offset + limit <= MaxPageDepth` (default 5000) — patch: `review/fix-patches.md#f-prf-001`

---

## Phase 7 — Deployment

- [ ] `dotnet publish src/FalconAuditService -c Release -r win-x64 --self-contained true /p:PublishReadyToRun=true`
- [ ] Smoke test the publish output by running it as a console app on the dev machine (not as a service): verify FSW callbacks, verify `/api/health` returns 200
- [ ] Run `install.ps1` on a target Falcon machine (Administrator):
  - Creates `C:\bis\auditlog\logs\`
  - Copies `FileClassificationRules.json` if missing
  - Sets ACLs with **inheritance disabled** (F-SEC-005 fix): `icacls "C:\bis\auditlog" /inheritance:r` then explicit grants
  - `sc.exe create FalconAuditService binPath= "..." start= auto`
  - `sc.exe failure FalconAuditService reset= 86400 actions= restart/5000/restart/5000/restart/5000`
  - Registers Event Log source `FalconAuditService`
  - `sc.exe start FalconAuditService`
- [ ] Smoke-test the running service:
  - `sc.exe query FalconAuditService` → `STATE: 4 RUNNING`
  - Tail `C:\bis\auditlog\logs\falcon-YYYYMMDD.log` and confirm "FSW ready" log line
  - `curl http://127.0.0.1:5100/api/health` → 200
  - Drop a test file into `c:\job\TestJob\test.xml`; wait 1.5 s; `curl http://127.0.0.1:5100/api/events?job=TestJob` → row appears
- [ ] Verify the Event Log under source `FalconAuditService` has the expected startup entries

---

## Estimated effort

| Phase | Complexity | Notes |
|---|---|---|
| 1 — Environment setup | Low | ~half a day |
| 2 — Core components | Medium | ~17 components; ~6–8 days for an experienced .NET dev |
| 3 — Storage layer | Medium | DDL + parameterised queries + checkpoint loop; ~2 days |
| 4 — API / interface | Medium | 4 endpoints + validation + cache + cross-shard; ~2 days |
| 5 — Integration & testing | Medium | 89 named test cases + 5 integration; ~5 days incl. perf tuning |
| 6a — Design blockers | Low | 3 patches, doc-only changes; ~half a day |
| 6b — Implementation must-fixes | Medium | 9 fixes, all small but spread across components; absorbed into Phase 2/4/5 |
| 7 — Deployment | Low | install.ps1 + smoke test; ~1 day |
| **Total** | **Medium** | **~3 calendar weeks for one experienced developer** |

---

## What to do next

> **Start here:** Apply the f-sec-001 patch in Phase 6a (path-validation regex bypass) BEFORE you generate any class stubs, because every API endpoint inherits from `Validators.IsSafePath`, and a wrong regex makes every downstream security check unsound. The other two Phase 6a patches (f-sto-001 and f-con-001) follow immediately because they alter the schema and the `IEventPipeline` interface, both of which other components depend on.

### Immediate actions (do before any coding)

1. **F-SEC-001 — Path validation regex bypass** — replace `^[\w\-. \\/]+$` with the explicit ASCII-only `^[A-Za-z0-9_.\- \\/]+$` and add length, NUL, control-char, `..`, and absolute-path gates. This must be applied first because every API endpoint reads through `Validators.IsSafePath`; a Unicode-aware `\w` is a real path-traversal bypass.
2. **F-STO-001 — `last_content` not size-capped** — update both the `schema-design.md` §4.2 column doc and the `architecture-design.md` §2.6 oversize-check rule to apply the cap to the baseline upsert as well as the audit row. Without this, oversize files leak into baselines and slow every subsequent diff forever.
3. **F-CON-001 — per-shard channel leak on departure** — add `IEventPipeline.CompleteShardAsync` and document the `JobManager.OnDepartureAsync` call order (complete channel → flush manifest → dispose shard). This changes the interface, so it must precede component implementation.

### During implementation

Resolve these in the order their owning component appears in Phase 2's leaf-first build order:

1. **Validators**: F-SEC-002 — escape LIKE wildcards in the `path` filter before binding to SQL. Without this, a user-supplied `%` wildcards across the dataset.
2. **Validators**: F-SEC-003 — folded into f-sec-001's length check; no extra work if the patch is applied verbatim.
3. **SqliteRepository**: F-STO-002 — periodic `wal_checkpoint(PASSIVE)` from the writer task every 1000 events or 10 min. Without this, the WAL grows unbounded on long-running shards.
4. **SqliteRepository**: F-STO-003 — `EnumerateBaselinesAsync` is `IAsyncEnumerable<>` already; document the streaming contract and add a memory-budget test in CatchUpScanner tests.
5. **Debouncer**: F-CON-002 — cancel-then-replace via `AddOrUpdate` AND post-await cancellation check. Without this, stale timers cause spurious classifications under burst load.
6. **CatchUpScanner**: F-CON-003 — share a single `SemaphoreSlim` instance between `QueueJobAsync` and `ScanAllAsync`; CUS-005 demands at-most-one regardless of source.
7. **FalconAuditWorker**: F-LNG-001 — orchestrate `StopAsync` explicitly in the documented order; do not trust DI reverse-disposal to be safe.
8. **API endpoints (cross-job)**: F-API-001 — read `_meta.schema_version` and skip mismatched shards; include `skipped_shards` array in the response.
9. **API endpoints (listing)**: F-PRF-001 — enforce `offset + limit <= MaxPageDepth` (default 5000); return `400 PAGE_TOO_DEEP` beyond it. This is the only Alt-1 design risk that can violate PERF-005 in production.

### After implementation

Address the 7 Medium and 4 Low findings in `review/comprehensive-review-report.md` §10 before the first deployment to a production Falcon machine — most are doc updates, validator hardening, or `appsettings.json` tweaks. The 3 Info findings can be left as backlog. The full prioritised list is in `review/comprehensive-review-report.md` §10 (severity-sorted index).

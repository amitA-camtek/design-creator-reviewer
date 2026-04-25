# FalconAuditService — Comprehensive Design Review

| Field | Value |
|---|---|
| Date | 2026-04-25 |
| Scope | All design files in `C:\Claude\design-creator-reviewer\output\` |
| Requirements | `c:\Claude\design-creator-reviewer\engineering_requirements.md` (ERS-FAU-001) |
| Review dimensions | Requirements, Security, SQLite, Concurrency, API contract, .NET patterns, Performance, Configuration |

> Note on agent execution model: this review was synthesised from a single orchestrator pass over all design files (the eight specialist subagents are not callable from within this orchestrator agent because nested `Task` delegation is unavailable in this environment). Each dimension was evaluated against the explicit checklists for the specialist agents — findings are organised below as if returned by each agent so the developer can route remediations.

---

## Executive Summary

The design package is detailed, internally coherent, and traceable to ERS-FAU-001. The multi-hosted (Alt C) architecture is well justified, the schema (Alt B) cleanly enforces the P1-only-content invariant at the DB boundary, and the API design satisfies API-001 through API-009 verbatim. The most critical risks are concentrated in the **worker-to-channel routing path**: `FileMonitor.OnRaw` calls `_shards.RouteAsync(...).GetAwaiter().GetResult()` from a `ThreadPool` continuation, blocking it under back-pressure; `EventDebouncer.Schedule`'s `AddOrUpdate` pattern races on the prior-CTS cancellation; `EventRecorder.OldContent` is set to the *new* content (a semantic bug that contradicts REC-001); and the FSW buffer-overflow path in `FileMonitor.OnFswError` is `// omitted for brevity` — i.e. MON-005 is not implemented. **Recommended first action: fix `EventRecorder.OldContent` (data-correctness bug), then wire the FSW Error → CatchUpCoordinator path, then convert the channel write to a properly awaited path.**

---

## Prioritised Action Plan

| # | Priority | Issue | Agent(s) | Req ID | File:Line |
|---|---|---|---|---|---|
| 1 | P0-Critical | `EventRecorder` sets `oldContent = newContent` instead of the prior-baseline content. The `diff_text` is computed against `prior` correctly, but the column written is the *new* file body. This violates REC-001 ("`old_content` (text snapshot before change)"). | requirements-checker, .NET patterns, security | REC-001 | `code-scaffolding.md:583-584` |
| 2 | P0-Critical | `FileMonitor.OnFswError` is a stub ("Notify CatchUpCoordinator via injected event aggregator (omitted for brevity)"). MON-005 / CUS-006 are not actually wired. | requirements-checker, concurrency, performance | MON-005, CUS-006 | `code-scaffolding.md:417-419` |
| 3 | P0-Critical | `FileMonitor.OnRaw` invokes `_shards.RouteAsync(classified).GetAwaiter().GetResult()` synchronously on a `ThreadPool` continuation. Under bounded-channel back-pressure (capacity 1024) this blocks the debounce-scheduler thread and can deadlock with concurrent writers; loses cancellation; throws `AggregateException` instead of `OperationCanceledException`. | concurrency, .NET patterns, performance | PERF-002, REL-005 | `code-scaffolding.md:411` |
| 4 | P0-Critical | `EventDebouncer.Schedule` race: between `AddOrUpdate(... prev.Cancel())` and the `Task.Delay(...).ContinueWith(t => if (t.IsCanceled) return; ...)`, a third event can replace `newCts` in the dictionary before the continuation runs, causing the original `onFire` to execute even though it was logically superseded. The `TryRemove(KeyValuePair)` call partially mitigates this but does not fix the in-flight continuation that already passed the IsCanceled gate. | concurrency | MON-004 | `code-scaffolding.md:439-450` |
| 5 | P0-Critical | `ShardRegistryRw.GetOrCreateAsync` opens the repo, runs migrations, starts the writer Task, **then** races on `_shards.GetOrAdd(shardKey, handle)`. If two callers race on the same `shardKey`, the loser leaks an opened `SqliteRepository`, a `Channel<>`, a `SemaphoreSlim`, and a running `Task` — none of which are disposed. | sqlite, concurrency, .NET patterns | STR-007 | `code-scaffolding.md:509-521` |
| 6 | P1-High | `EventRecorder.RecordAsync` reads file content and computes hash sequentially. With 1 MB files this adds ~30 ms per event; running them in parallel via `Task.WhenAll` saves real budget for PERF-002. | concurrency, performance | PERF-002 | `code-scaffolding.md:572-585` |
| 7 | P1-High | The `manifest.json` "events count" requirement (MFT-007 — increment on every successful insert) is not implemented anywhere in `EventRecorder`, `ShardRegistryRw`, or `ManifestManager`. `IManifestManager.IncrementEventCountAsync` exists in the interface but no caller. | requirements, .NET patterns | MFT-007 | `code-scaffolding.md:191`, `code-scaffolding.md:560-605` |
| 8 | P1-High | `RulesFileWatcher` is referenced everywhere but not scaffolded. Behaviour around the 200 ms reload-debounce, ImmutableList swap, and PERF-003 budget exists only in the sequence diagram and architecture text; no class stub exists. | requirements, concurrency, configuration | CLS-005, CLS-006, REL-006, PERF-003 | `code-scaffolding.md` (absent) |
| 9 | P1-High | The query process invokes `await using var rdr = await _factory.OpenAsync(name, ct);` **inside a `foreach`** in `Jobs()` to fetch counts per shard. A 10-job deployment opens 10 connections sequentially. The api-design.md mentions "cached for 5 s in `IMemoryCache`" but the scaffolding does not include `IMemoryCache`. | performance, api-contract | PERF-005 | `code-scaffolding.md:881-895`, `api-design.md:211` |
| 10 | P1-High | `EventQueryFilter.Page` and `PageSize` are model-bound from query string with `init` setters and no validator wiring in the scaffolded `Program.cs`. The validator described in `api-design.md` §4.2 is not registered as an action filter. Out-of-range values silently produce malformed SQL (`OFFSET -50`). | api-contract, security | API-005 | `code-scaffolding.md` (no validator), `api-design.md:133-145` |
| 11 | P1-High | `EventQueryBuilder.Build` only handles equality filters; it does **not** validate `f.Priority` ∈ {P1,P2,P3} or `f.EventType` ∈ {Created,Modified,Deleted,Renamed}. SQL injection is parameterised (safe), but invalid enum strings reach SQLite as no-match values silently. | api-contract, security | API-004 | `code-scaffolding.md:993-1023` |
| 12 | P1-High | `CatchUpScanner` recomputes hashes on **every** file every catch-up. PERF-004 with 10×150 in 5 s is borderline on cold IO and HDD-backed storage. | performance, sqlite | PERF-004 | `code-scaffolding.md:653-674` |
| 13 | P1-High | `SqliteRepository.DisposeAsync` runs `PRAGMA wal_checkpoint(TRUNCATE)` synchronously under `try/catch{}` that swallows everything. If TRUNCATE blocks waiting for a reader (busy_timeout=5 s), shutdown stalls per shard. With `n` open shards this multiplies. SVC-002 / SVC-004 ordering has no host-shutdown budget cap on this loop. | concurrency, sqlite, .NET patterns | SVC-002, SVC-004 | `code-scaffolding.md:765-774`, `code-scaffolding.md:546-554` |
| 14 | P1-High | `JobDiscoveryService.RefreshAsync` enumerates `c:\job\` and *checks `File.Exists` per directory*. On NAS-mounted job folders this is slow. The 30-s polling cadence multiplied by FS roundtrip blows PERF-005's budget if discovery runs synchronously during a request. | performance, sqlite | API-007, PERF-005 | `code-scaffolding.md:1054-1066` |
| 15 | P2-Medium | The schema's `audit_log.id` is `INTEGER PRIMARY KEY AUTOINCREMENT` (good), but the `ORDER BY changed_at DESC, id DESC` tiebreaker for stable pagination depends on this AUTOINCREMENT property — document the dependency. | sqlite, api-contract | API-005 | `schema-design.md:73`, `api-design.md:251` |
| 16 | P2-Medium | `audit_log.changed_at` is `TEXT`. Add a CHECK constraint that the value ends in `Z` to guarantee UTC ISO-8601 round-trip and reliable string-comparison. | sqlite, security | REC-001 | `schema-design.md:74`, `code-scaffolding.md:734` |
| 17 | P2-Medium | `Cache=Shared` on read-only connections combined with per-request lifetime defeats the connection-pool benefit. Reconsider `Cache=Default` for the read side. | sqlite, performance | PERF-005 | `code-scaffolding.md:692-697`, `api-design.md:325` |
| 18 | P2-Medium | The single global database lacks explicit lifecycle separation in the worker. `__global__` is treated as a normal shard but should be pre-registered at startup and never disposed. | sqlite, requirements | STR-002 | `schema-design.md:265-269`, `code-scaffolding.md:481-486` |
| 19 | P2-Medium | The Serilog configuration in worker `Program.cs` calls `.WriteTo.EventLog("FalconAuditService", manageEventSource: false)`. `manageEventSource: false` means the source must already exist. `install.ps1` creates it via `New-EventLog -ErrorAction SilentlyContinue`, which silently swallows permission errors if the installer is not running elevated. | configuration, .NET patterns | LOG-001, INS-005 | `code-scaffolding.md:274`, `code-scaffolding.md:1280` |
| 20 | P2-Medium | `install.ps1` does not configure the Windows Service account. By default the services run as `LocalSystem`, which has full access to `c:\job\` (good) but also has permission to do anything else. SEC posture would be improved by running as a virtual account with explicit ACLs. | configuration, security | SEC-001 | `code-scaffolding.md:1265-1285` |
| 21 | P2-Medium | `install.ps1` does not copy the default `FileClassificationRules.json` to `C:\bis\auditlog\` if it does not exist (INS-001 explicitly requires this). | configuration, requirements | INS-001 | `code-scaffolding.md:1265-1285` |
| 22 | P2-Medium | `EventQueryBuilder.Build` formats `From.UtcDateTime.ToString("O")` directly. If the writer rounds timestamps differently (e.g. 7-digit vs 3-digit fractions), inclusive-equality boundaries on `>=` and `<` may exclude rows. Standardise via a shared `IsoTimestamp.Format(DateTimeOffset)` helper. | api-contract, .NET patterns | API-004 | `code-scaffolding.md:1004-1005`, `code-scaffolding.md:734` |
| 23 | P2-Medium | `ManifestManager.RecordArrivalAsync` reads, then writes the manifest, with no per-folder concurrency guard. Two arrival events for the same folder racing produces a lost-update on history. Add a `ConcurrentDictionary<string, SemaphoreSlim>` keyed by `jobFolder`. | concurrency, requirements | MFT-005, MFT-006 | `code-scaffolding.md:1185-1194` |
| 24 | P2-Medium | `Files()` action selects `filepath, last_hash, last_seen` from `file_baselines`, but the schema does not store `rel_filepath`. The DTO `FileBaselineDto` has both fields. The api-design.md notes "rel_filepath is computed in code from filepath and the job root" but this requires the job root to be threaded through. | api-contract, sqlite | API-003 | `api-design.md:222-232`, `code-scaffolding.md:1062` |
| 25 | P2-Medium | `RelFilepathConstraint` regex `^[\w\-. \\/]+$` requires unit-test coverage for both `\` and `/` separators because of regex/string-literal escape interaction. The api-design.md test plan calls this out; ensure it actually runs. | security, api-contract | API-008 | `code-scaffolding.md:1041`, `api-design.md:359` |
| 26 | P3-Low | `install.ps1` only sets `depend= FalconAuditWorker` on the Query service. Document the consequence: stopping the worker doesn't auto-stop the query service. | configuration | INS-001 | `code-scaffolding.md:1275` |
| 27 | P3-Low | `ManifestEntryDto` and `ManifestDto.Created` shape diverges from the api-design.md example payload at `/api/jobs` (#7.1 shows `created` as ISO string while the DTO is an object). Pick one. | api-contract | API-003 | `api-design.md:194-198` vs `code-scaffolding.md:139-142` |
| 28 | P3-Low | The PERF-003 sequence diagram lists "200 ms debounce in `RulesFileWatcher`". This component is not scaffolded and the debounce window is not in `MonitorConfig`. Surface it as `RulesReloadDebounceMs` (default 200). | configuration, requirements | PERF-003, CFG | `sequence-diagrams.md:269`, `code-scaffolding.md:73-83` |
| 29 | P3-Low | `appsettings.json` skeleton does not include a Serilog writer configuration; sinks are hard-coded in `Program.cs`. INS-005 is satisfied technically but operators cannot tune retention without redeploy. | configuration | INS-005 | `code-scaffolding.md:1255-1259` |
| 30 | P3-Low | `ICatchUpScanner` interface (used by factory) is not declared in the abstractions section. Add for testability. | .NET patterns, requirements | CUS-001 | `code-scaffolding.md:147-224` |

---

## Findings by Agent

### Requirements Checker

Coverage status of every requirement group:

| Group | ID | Status | Note |
|---|---|---|---|
| SVC | SVC-001 | Addressed | `AuditHost : BackgroundService` (`code-scaffolding.md` §4.2). |
| SVC | SVC-002 | Addressed | `install.ps1` `start= auto`. |
| SVC | SVC-003 | Addressed | `AuditHost.ExecuteAsync` step 2 then step 4. Sequence diagram makes the contract explicit. |
| SVC | SVC-004 | **Partially addressed** | `StopAsync` does not explicitly call `ManifestManager.RecordDeparture` for every open shard before disposing. `ShardRegistry.DisposeAsync` only disposes; no manifest update. |
| SVC | SVC-005 | **Partially addressed** | `WriterLoopAsync` catches all exceptions and logs (good). But `OnRaw` catches nothing and any classifier or routing exception bubbles into the FSW callback. Add a guard. |
| SVC | SVC-006 | Addressed in design | PERF-001 narrative meets it. |
| SVC | SVC-007 | Addressed | `Parallel.ForEachAsync` over jobs. |
| MON | MON-001 | Addressed | `IncludeSubdirectories = true`. |
| MON | MON-002 | Addressed | `InternalBufferSize = 64 * 1024`. |
| MON | MON-003 | Addressed | All four event subscriptions. |
| MON | MON-004 | **Partially addressed** | Race in `EventDebouncer.Schedule` (action #4). |
| MON | MON-005 | **Not addressed** | `OnFswError` has comment "omitted for brevity" — action #2. |
| MON | MON-006 | Addressed | `cfg.WatchPath`. |
| CLS | CLS-001 | Addressed | `ClassificationRulesPath` config + `LoadAsync`. |
| CLS | CLS-002 | **Partially addressed** | `CompiledRule.Pattern` is a `Regex`; the JSON-to-Regex conversion (`exact` vs `glob`) is not scaffolded. |
| CLS | CLS-003 | Addressed | `foreach` first match wins. |
| CLS | CLS-004 | Addressed | Fallback returns `("Unknown","Unknown",P3)`. |
| CLS | CLS-005 | **Partially addressed** | `RulesFileWatcher` is not scaffolded — action #8. |
| CLS | CLS-006 | Addressed | `Interlocked.Exchange` on `_rules`. |
| CLS | CLS-007 | Addressed | `CompiledRule` carries the five fields. |
| CLS | CLS-008 | Addressed | Compiled-once at load (asserted in test plan). |
| REC | REC-001 | **Bug** | `oldContent = newContent` — action #1. |
| REC | REC-002 | Addressed | `sha256` always; `old_content` and `diff_text` only for P1. |
| REC | REC-003 | Addressed | P4 logs warning, no row. |
| REC | REC-004 | Addressed | `IHashService.ComputeAsync`. |
| REC | REC-005 | **Partially addressed** | DiffPlex `BuildUnified` is called; the bug at REC-001 means the diff base is `prior` (correct) but the column written is wrong. |
| REC | REC-006 | Addressed | `Environment.MachineName`. |
| REC | REC-007 | Addressed | `ComputeRelative` in `FileClassifier`. |
| REC | REC-008 | Addressed | `UpsertBaselineAsync`. |
| REC | REC-009 | Addressed | `retries: 3, retryDelayMs: 100`. |
| STR | STR-001 | Addressed | Path computed at `Path.Combine(jobFolder, ".audit", "audit.db")`. |
| STR | STR-002 | Addressed | `GlobalDbPath`. |
| STR | STR-003 | Addressed | `PRAGMA journal_mode=WAL`. |
| STR | STR-004 | Addressed | `PRAGMA synchronous=NORMAL`. |
| STR | STR-005 | Addressed | `SemaphoreSlim(1,1)`. |
| STR | STR-006 | Addressed | `Directory.CreateDirectory(...)` in factory. |
| STR | STR-007 | **Partially addressed** | Race window in `GetOrCreateAsync` — action #5. |
| STR | STR-008 | Addressed in design | 5-s budget enforced via `WaitAsync(TimeSpan.FromSeconds(5))`. |
| JOB | JOB-001…JOB-007 | Addressed | Manifest + shard portability via string enums. |
| MFT | MFT-001…MFT-006 | Addressed | Atomic temp-file rename. |
| MFT | MFT-007 | **Not addressed** | No caller of `IncrementEventCountAsync` — action #7. |
| MFT | MFT-008 | Addressed | `WriteIndented = true`. |
| CUS | CUS-001…CUS-005 | Addressed | Scaffolded in `CatchUpScanner.RunAsync`. |
| CUS | CUS-006 | **Not addressed** | Buffer-overflow → catch-up path missing — action #2. |
| API | API-001…API-009 | Addressed | All seven endpoints, ReadOnly mode, API-008 regex, loopback default, 30-s discovery. |
| API | API-010 | Out of scope (Priority L). |
| PERF | PERF-001 | Addressed | Startup ordering puts FSW before catch-up. |
| PERF | PERF-002 | **At risk** | Sync-over-async on routing (action #3); sequential hash+content read (action #6). |
| PERF | PERF-003 | Addressed in design | RulesFileWatcher missing scaffold doesn't change feasibility. |
| PERF | PERF-004 | **At risk** | Catch-up cold-IO bound (action #12). |
| PERF | PERF-005 | Addressed | Index plan covers all axes; `path` LIKE acknowledged unanchored. |
| REL | REL-001…REL-007 | Addressed | WAL persistence, integrity_check on open documented, malformed-JSON-retains-previous documented. |
| INS | INS-001 | **Partially addressed** | install.ps1 missing default rules copy (action #21). |
| INS | INS-002…INS-004 | Addressed | `monitor_config` section, defaults, restart-required. |
| INS | INS-005 | **Partially addressed** | EventLog source manageEventSource pitfall (action #19); query process has no EventLog sink. |
| CON | CON-001…CON-006 | Addressed by deployment topology. |
| SEC | SEC-001 | Partially | LocalSystem default — action #20. |

### Security Reviewer

| # | Finding | Req | File:Line |
|---|---|---|---|
| S1 | `RelFilepathConstraint` regex must be unit-tested for both `\` and `/` separators (action #25). | API-008 | `code-scaffolding.md:1041` |
| S2 | `EventQueryBuilder.Build` correctly parameterises everything; LIKE escape is correct. Confirmed safe against SQL injection. | API-004, SEC | `code-scaffolding.md:993-1023` |
| S3 | Writer process never opens a network port; query process binds to `127.0.0.1` by default via `k.ListenLocalhost(port)`. Good. | API-009 | `code-scaffolding.md:851-855` |
| S4 | `ShardReaderFactory` constructs a connection string with `Mode=ReadOnly`; `SqliteRepository` constructor stores `_readOnly` and refuses write methods. Defence in depth is good. | API-002 | `code-scaffolding.md:686-722` |
| S5 | Single-event endpoint is the only one that selects `old_content, diff_text`. `EventListItemDto` does not contain those fields at all. Information disclosure risk closed. | API-006 | `code-scaffolding.md:122-125`, `api-design.md:240` |
| S6 | SEC-001 (no writes outside `.audit\`) is asserted by design but not enforced at runtime. Consider a virtual service account with NTFS ACLs (action #20). | SEC-001 | `code-scaffolding.md:1265-1285` |
| S7 | Query service has **no auth middleware** — relies on loopback. Document explicitly that any local user can read audit data via the API. If the host is multi-tenant (RDP/Citrix), this is a real disclosure risk. | API-009, API-010 | `api-design.md:31` |
| S8 | `app.UseExceptionHandler("/error")` may leak internal exception details on 500. Ensure exception messages are not echoed in `ProblemDetails.Detail`. | API-009 | `code-scaffolding.md:858` |
| S9 | `manifest.json` may be modified by anyone with write access to `c:\job\`. Chain-of-custody is only as strong as the directory ACL. Document this assumption (or HMAC-sign the manifest). | MFT-001 | `architecture-design.md:153` |
| S10 | The `path` filter accepts arbitrary strings up to 260 chars. The LIKE escape is correct, but a pathological pattern (`%a%a%...`) on a 100K-row shard could eat CPU. Limit `path.Length` to ~64. | PERF-005, security | `api-design.md:144` |

### SQLite Expert

| # | Finding | Req | File:Line |
|---|---|---|---|
| Q1 | PRAGMAs applied per-connection are correct: `journal_mode=WAL`, `synchronous=NORMAL`, `temp_store=MEMORY`, `cache_size=-8000`, `busy_timeout=5000`. `foreign_keys=OFF` is explicit. | STR-003, STR-004 | `schema-design.md:42-48`, `code-scaffolding.md:705-714` |
| Q2 | `ApplyReadPragmas` in `ShardReaderFactory` omits `synchronous` and `foreign_keys`. Be consistent with `SqliteRepository.ApplyPragmas`. | STR-004 | `code-scaffolding.md:1140-1145` vs `code-scaffolding.md:705-714` |
| Q3 | `Cache=Shared` on read-only connections is a misuse — see action #17. | PERF-005 | `code-scaffolding.md:1136`, `api-design.md:325` |
| Q4 | The four indexes correctly cover API-004 filter axes. `owner_service`-only queries fall back to scan + index intersection — acceptable per schema-design.md §4.2. | API-004 | `schema-design.md:112-121` |
| Q5 | `SchemaMigrator` uses `BeginTransactionAsync()` (DEFERRED by default in Microsoft.Data.Sqlite). The DDL header in `schema-design.md` §4 says `BEGIN IMMEDIATE` — change scaffolding to use `BeginTransaction(IsolationLevel.Serializable)` or run BEGIN IMMEDIATE manually. | STR-003 | `code-scaffolding.md:803`, `schema-design.md:70` |
| Q6 | `wal_checkpoint(TRUNCATE)` on dispose is good but blocks if a reader is mid-snapshot. With many shards this stalls SVC-002 budget. Add `wal_checkpoint(PASSIVE)` first or skip on shutdown deadline. | SVC-002, SVC-004 | `code-scaffolding.md:769` |
| Q7 | `audit_log.id` is `INTEGER PRIMARY KEY AUTOINCREMENT`. Slightly slower writes; correct for audit semantics. | REC-001 | `schema-design.md:73` |
| Q8 | `ON CONFLICT(filepath) DO UPDATE` upsert on `file_baselines` requires `filepath` be unique — it is the PRIMARY KEY. Good. | REC-008 | `code-scaffolding.md:751-755` |
| Q9 | The CHECK constraint `(monitor_priority = 'P1') OR (old_content IS NULL AND diff_text IS NULL)` correctly enforces the P1-only invariant at the DB boundary. | REC-002 | `schema-design.md:87-90` |
| Q10 | Missing CHECK constraint on `changed_at` format (action #16). | REC-001 | `schema-design.md:74` |
| Q11 | The integrity-check + corrupt-rotation flow (`schema-design.md` §10) is described but not scaffolded. | REL-007 | `schema-design.md:287` |
| Q12 | `BEGIN DEFERRED` on the read-only side is correct. Document the IsolationLevel mapping. | API-005 | `api-design.md:160`, `sequence-diagrams.md:319` |
| Q13 | The global DB lifecycle is not separated from job shards (action #18). | STR-002 | `code-scaffolding.md:481-486` |
| Q14 | `ShardRegistryRw.GetOrCreateAsync` race (action #5). | STR-007 | `code-scaffolding.md:509-521` |

### Concurrency Reviewer

| # | Finding | Req | File:Line |
|---|---|---|---|
| C1 | `FileMonitor.OnRaw` does sync-over-async: `_shards.RouteAsync(classified).GetAwaiter().GetResult()` (action #3). | PERF-002, REL-005 | `code-scaffolding.md:411` |
| C2 | `EventDebouncer.Schedule` race window (action #4). Pattern fix: capture `myCts` before `AddOrUpdate`; in the continuation, atomically compare `_pending[path] == myCts` before firing. | MON-004 | `code-scaffolding.md:439-450` |
| C3 | `Task.Delay(_, newCts.Token).ContinueWith(...)` `try { onFire() } catch { /* logged elsewhere */ }` swallows all exceptions silently. Log them. | MON-004 | `code-scaffolding.md:447` |
| C4 | `ShardRegistryRw.GetOrCreateAsync` race (action #5). Use `ConcurrentDictionary<TKey, Lazy<Task<ShardHandle>>>` to atomically race on the *factory* function. | STR-007 | `code-scaffolding.md:509-521` |
| C5 | `WriterLoopAsync` correctly uses `await foreach` and `SemaphoreSlim.WaitAsync(ct)` with try/finally. Good. | STR-005 | `code-scaffolding.md:523-533` |
| C6 | `ShardHandle.DisposeAsync` `try { } catch { }` swallows `OperationCanceledException` and `TimeoutException` silently. Log a warning if writer didn't drain in 5 s. | STR-008 | `code-scaffolding.md:546-554` |
| C7 | `JobDiscoveryHostedService.ExecuteAsync` calls `_disc.RefreshAsync(ct)` once before the timer loop. If first refresh throws, the service crashes. Wrap in try/catch. | API-007 | `code-scaffolding.md:1074-1080` |
| C8 | `RulesFileWatcher` not scaffolded (action #8). | CLS-005, CLS-006 | `code-scaffolding.md` (absent) |
| C9 | `AuditHost.ExecuteAsync` ends with `await Task.Delay(Timeout.Infinite, stoppingToken).ContinueWith(_ => { });`. Idiomatic alternative: `await Task.Delay(Timeout.Infinite, stoppingToken);`. | SVC-005 | `code-scaffolding.md:352` |
| C10 | `AuditHost.StopAsync` does not explicitly drain `ShardRegistryRw` writer Tasks — relies on DI disposal. Make it explicit so SVC-004 is observable. | SVC-004 | `code-scaffolding.md:355-363` |
| C11 | `EventRecorder.RecordAsync` runs `await File.ReadAllTextAsync(...)` and `await _hash.ComputeAsync(...)` sequentially (action #6). Parallelise via `Task.WhenAll`. | PERF-002 | `code-scaffolding.md:572-585` |
| C12 | `CatchUpScanner.RunAsync` calls `ct.ThrowIfCancellationRequested()` once per file; `_classifier.Classify` is sync (no token); `_hash.ComputeAsync` does take `ct`. Acceptable. | SVC-005, CUS-006 | `code-scaffolding.md:655-674` |

### API Contract Reviewer

| # | Finding | Req | File:Line |
|---|---|---|---|
| A1 | All seven endpoints from API-003 are routed. | API-003 | `code-scaffolding.md:865-958` |
| A2 | `Mode=ReadOnly` is enforced in both `ShardReaderFactory.BuildConnectionString` and `SqliteRepository._readOnly` flag. | API-002 | `code-scaffolding.md:1131-1138`, `code-scaffolding.md:686-722` |
| A3 | Pagination headers are set in `Events()`. Confirm `Files()` also sets them — scaffolding has placeholder. | API-005 | `code-scaffolding.md:905-914` |
| A4 | `pageSize` cap of 500 is documented but not enforced in scaffolding (action #10). | API-005 | `code-scaffolding.md` (absent) |
| A5 | Out-of-range page returns 200 + empty array contract is documented; verify `X-Total-Count` is still set. | API-005 | `api-design.md:304` |
| A6 | `oldContent`/`diffText` isolation: `EventListItemDto` lacks the fields entirely. List endpoint cannot leak content. | API-006 | `api-design.md:240-251`, `code-scaffolding.md:122-130` |
| A7 | `RelFilepathConstraint` registered; controller body also runs `IPathValidator.IsSafe`. Two-layer validation good. | API-008 | `code-scaffolding.md:848`, `code-scaffolding.md:946-947` |
| A8 | `JobDiscoveryService.ResolveShardPath` returns null on missing — controller throws `ShardNotFoundException` and `ExecuteShardActionAsync` maps to 404. Force-refresh on 404 is documented but not implemented. | API-007 | `api-design.md:431`, `code-scaffolding.md:962-987` |
| A9 | `Global([FromQuery] EventQueryFilter filter, ...)` calls `Events("__global__", filter, ct)`. The `{jobName}` route constraint accepts `__global__` (underscore matches `\w`). OK. | API-003 | `api-design.md:49`, `code-scaffolding.md:957-958` |
| A10 | `application/problem+json` configured via `AddProblemDetails()`. 503 responses use ProblemDetails. Good. | API-009 | `code-scaffolding.md:849`, `code-scaffolding.md:977-985` |
| A11 | The `Events()` controller line `var (where, parms) = _qb.Build(filter);` — verify the SELECT statement actually injects `WHERE {whereSql}`. | API-004 | `code-scaffolding.md:920-922` |
| A12 | `Cache-Control: no-store` set only on Events response. Add globally via middleware for `Files`, `Detail`, `History`, `Manifest`, `Jobs`. | API security | `api-design.md:158`, `code-scaffolding.md:865-988` |
| A13 | DTO/example mismatch on Manifest (action #27). | API-003 | `api-design.md:107-112` vs `code-scaffolding.md:139-142` |
| A14 | `JobSummaryDto.EventCount` and `LatestEventAt` populating requires N round-trips. Cache or precompute (action #9). | PERF-005, API-003 | `code-scaffolding.md:881-895` |
| A15 | `History()` does not use `EventQueryFilter` — only `page`, `pageSize`. Confirm intentional. | API-003 | `api-design.md:272-285` |

### .NET Patterns Reviewer

| # | Finding | Req | File:Line |
|---|---|---|---|
| N1 | Sync-over-async in `FileMonitor.OnRaw` (action #3). | PERF-002 | `code-scaffolding.md:411` |
| N2 | `EventRecorder.OldContent` semantic bug (action #1). | REC-001 | `code-scaffolding.md:583-584` |
| N3 | Unhandled exception in fire-and-forget `Task.Delay(...).ContinueWith(...)` swallows errors silently. | SVC-005 | `code-scaffolding.md:447` |
| N4 | `SqliteRepository.DisposeAsync` `try { ... } catch { /* best effort */ }` for `wal_checkpoint(TRUNCATE)`. Log before swallowing. | .NET patterns | `code-scaffolding.md:769` |
| N5 | `Logger.LogError` calls correctly include the exception parameter throughout. Good. | LOG-001 | `code-scaffolding.md:417, 530` |
| N6 | `IOptionsMonitor<MonitorConfig>` used everywhere, but most consumers read once at construction. INS-004 says all keys except rules content require restart — use `IOptions<>` instead. | INS-004 | `code-scaffolding.md` (multiple) |
| N7 | `IClassificationRulesLoader.LoadAsync(string path, ct)` accepts a path, but `AuditHost` reads `cfg.ClassificationRulesPath` per call. If `RulesFileWatcher` watches one path and config later changes, mismatch. Tie watch path to load path inside the loader. | CLS-001, CLS-005 | `code-scaffolding.md:333` |
| N8 | Records and init-only setters used appropriately. | API-004 | `code-scaffolding.md:117-130` |
| N9 | `RelFilepathConstraint` uses `[GeneratedRegex]` — modern, fast, correct. Requires `<LangVersion>11+</LangVersion>`. .NET 6 default is C# 10; project file must explicitly set `LangVersion`. | CON-002 | `code-scaffolding.md:1029-1043` |
| N10 | `Channel.CreateBounded<ClassifiedEvent>(capacity)` — `BoundedChannelFullMode` defaults to `Wait`. Be explicit. | REL-005 | `code-scaffolding.md:515` |
| N11 | `ShardRegistryRw.RouteAsync` chains `GetOrCreateAsync(...).ContinueWith(t => t.Result.Channel.Writer.WriteAsync(e).AsTask()).Unwrap()` — convoluted. Use `async`/`await`. Throws synchronously if `GetOrCreateAsync` throws — add try/catch with Dead-Letter log. | REL-005, SVC-005 | `code-scaffolding.md:506-507` |
| N12 | `ManifestManager.ReadAsync` retries once on `IOException` with `Task.Delay(50, ct)`. On `FileNotFoundException` returns `null`. Document. | MFT-001 | `code-scaffolding.md:1172-1183` |
| N13 | `EventDebouncer` does not implement `IDisposable` but holds many CTS instances. Implement `IDisposable` to free CTS on shutdown. | .NET patterns | `code-scaffolding.md:434-451` |
| N14 | `IClassificationRulesLoader` implementation is not scaffolded. | CLS-001 | `code-scaffolding.md` (absent) |

### Performance Checker

| # | Finding | Req | File:Line |
|---|---|---|---|
| P1 | PERF-001 (FSW < 600 ms): startup ordering registers FSW at step 2 of 5. Within budget. Concern: `ClassificationRulesLoader` is not scaffolded — measure. | PERF-001 | `architecture-design.md:301-305` |
| P2 | PERF-002 (P1 event < 1 s after debounce): scaffolding has hash + read sequentially (action #C11), and `OnRaw` is sync-over-async (action #3). Budget at risk. Fix #3 first. | PERF-002 | `code-scaffolding.md:572-585`, `code-scaffolding.md:411` |
| P3 | PERF-003 (rules hot-reload < 2 s): not at risk in design narrative. RulesFileWatcher missing scaffold doesn't change feasibility. | PERF-003 | `sequence-diagrams.md:228-272` |
| P4 | PERF-004 (catch-up 10×150 < 5 s): `Parallel.ForEachAsync` over jobs gives parallelism; per-file SHA-256 cost dominates. On slow HDD borderline; on SSD fine. Pre-warm disk cache or use `MemoryMappedFile` for hashing large files. | PERF-004 | `code-scaffolding.md:640-651` |
| P5 | PERF-005 (paginated query < 200 ms): index plan sound; OFFSET pagination fine up to ~100K rows. Per-shard count + page on same connection in DEFERRED tx is correct. Risk: `path` LIKE `%foo%` does not seek. Add EXPLAIN-QUERY-PLAN check in tests. | PERF-005 | `schema-design.md:181-192`, `api-design.md:384-403` |
| P6 | `JobDiscoveryService.RefreshAsync` per-folder `File.Exists` synchronously can block the timer loop on slow IO (action #14). | API-007 | `code-scaffolding.md:1054-1066` |
| P7 | `JobSummaryDto` per-shard count + max requires N round-trips. Cache it (action #9). | PERF-005, API-003 | `code-scaffolding.md:881-895`, `api-design.md:211` |
| P8 | FSW buffer-overflow → catch-up not implemented (action #2). | MON-005, PERF-001 | `code-scaffolding.md:417-419` |
| P9 | `EventQueryBuilder` allocates fresh `StringBuilder` and `List<SqliteParameter>` per request. Fine for PERF-005. | PERF-005 | `code-scaffolding.md:993-1023` |
| P10 | `Channel<ClassifiedEvent>` capacity 1024 per shard. With 10 shards = 10K in-memory events on back-pressure ≈ 10 MB. Fine. | REL-005 | `code-scaffolding.md:80, 515` |
| P11 | `cache_size = -8000` (8 MiB per connection) × ~10 read-only + 10 read-write ≈ 160 MB SQLite cache. OK on Falcon-class boxes. | PERF-005 | `schema-design.md:46` |
| P12 | 5 s `busy_timeout` on read side means a slow checkpoint can hold a request for up to 5 s — potentially blowing PERF-005 budget. Mitigate via checkpoint-at-shutdown only; rely on default `wal_autocheckpoint`. | PERF-005 | `schema-design.md:47` |

### Configuration Validator

| # | Finding | Req | File:Line |
|---|---|---|---|
| F1 | `appsettings.json` skeleton lists `monitor_config` with all five required keys plus three extras. Defaults match CLAUDE.md. Good. | INS-002, INS-003 | `code-scaffolding.md:1244-1259` |
| F2 | `Serilog` config in `appsettings.json` is `MinimumLevel: Information` only — sink config hard-coded in `Program.cs` (action #29). | INS-005 | `code-scaffolding.md:1255-1259` |
| F3 | `install.ps1` does not copy default `FileClassificationRules.json` to `C:\bis\auditlog\` (action #21, INS-001 violation). | INS-001 | `code-scaffolding.md:1270` |
| F4 | `install.ps1` `New-EventLog -Source ... -ErrorAction SilentlyContinue` hides errors (action #19). | INS-005, LOG-001 | `code-scaffolding.md:1280` |
| F5 | `install.ps1` does not configure service account (action #20). | SEC-001 | `code-scaffolding.md:1265-1285` |
| F6 | `install.ps1` does not document Worker→Query stop-dependency consequence (action #26). | INS-001 | `code-scaffolding.md:1275` |
| F7 | Both processes share `appsettings.json` shape; worker doesn't consume `api_port` and query doesn't consume `debounce_ms`. Acceptable for v1. | CFG | `code-scaffolding.md:1244-1259` |
| F8 | `RulesReloadDebounceMs` (200 ms in sequence diagram) is not exposed in `MonitorConfig` (action #28). | PERF-003 | `code-scaffolding.md:73-83` |
| F9 | `JobDiscoveryIntervalSeconds: 30` matches API-007. | API-007 | `code-scaffolding.md:81` |
| F10 | Worker Serilog: file + EventLog. Query side: file only — **no Event Log sink**. INS-005 implies both should write to EventLog. Document or add. | INS-005 | `code-scaffolding.md:272-274`, `code-scaffolding.md:830-831` |
| F11 | Log path `C:\bis\auditlog\logs\` hardcoded in both `Program.cs`. Acceptable but document. | INS-005 | `code-scaffolding.md:273, 831` |
| F12 | Global DB at `C:\bis\auditlog\global.db` is created on first use by `SqliteRepositoryFactory.Open` via `Directory.CreateDirectory`. Acceptable. | STR-002, INS-001 | `code-scaffolding.md:691, 1271` |
| F13 | `uninstall.ps1` is mentioned but not scaffolded. Risk for production hygiene. | INS-001 | `code-scaffolding.md:27` |

---

## Cross-references

- Action #1 (REC-001) is corroborated by Requirements (REC), .NET patterns (N2), Security (data-correctness affects audit integrity).
- Action #2 (MON-005) is corroborated by Requirements (MON, CUS), Concurrency (Buffer-overflow → catch-up handler missing), Performance (P8).
- Action #3 (sync-over-async) is corroborated by Concurrency (C1), .NET patterns (N1), Performance (P2).
- Action #4 (debounce race) is unique to Concurrency (C2, C3).
- Action #5 (registry race) is corroborated by Concurrency (C4), SQLite (Q14), .NET patterns.
- Action #11 (filter validation) is corroborated by API contract (A4) and Security (input-handling).

## Contradictions Resolved

- **Architecture vs scaffolding on hash location**: architecture-design.md §7.4 places hashing inside the per-shard writer task (after `SemaphoreSlim.WaitAsync`). Reading the scaffolding carefully, `OnRaw` does *not* hash on the debounce thread; it only routes via `RouteAsync`. The actual hash + DB insert happens inside `EventRecorder.RecordAsync` invoked from the writer loop. So the scaffolding is consistent with the architecture diagram on this point. The remaining issue is the synchronous `.GetAwaiter().GetResult()` on the channel write (action #3), not the location of hashing.

- **api-design.md vs scaffolding on caching**: api-design.md §7.1 says `JobSummaryDto` is "Cached for 5 s in an `IMemoryCache`", but the scaffolding does not register `IMemoryCache`. This is a real gap, captured as action #9.

## Gaps from this review (no specialist run)

The eight specialist subagents could not be invoked from this orchestrator (the `Task` tool is unavailable to subagents). The findings above are produced by a single pass over the design files using the specialist checklists. A future invocation with subagent-spawning capability should re-validate, paying special attention to:

- `RulesFileWatcher` scaffold (currently absent).
- `HashService.ComputeAsync` scaffold (currently absent).
- `IClassificationRulesLoader` scaffold (currently absent).
- `PathValidator` scaffold (currently absent).
- `IDirectoryWatcher` scaffold (currently absent).

## What looks good

- **Architecture decision** (Alt C, multi-hosted) is well-reasoned with explicit risk register and mitigations.
- **Schema CHECK constraints** for P1-only-content invariant and event_type / sha256 format — defence in depth at DB boundary.
- **Index coverage** for API-004 filters — four targeted indexes, conscious omissions documented.
- **API two-layer path validation** (route constraint + controller-level validator) for API-008.
- **Mode=ReadOnly** enforced both via connection string and via repository class flag.
- **Atomic manifest writes** via temp + `File.Move(overwrite: true)` correctly used.
- **Sequence diagrams** clearly encode SVC-003 ordering and the cross-process WAL-isolation contract.
- **Test plan** ties every requirement to at least one test case and tags PERF gates explicitly.
- **DI registration** is comprehensive and lifetime annotations are correct.
- **Domain exceptions** (`ShardNotFoundException`, `ShardUnavailableException`) cleanly map to HTTP 404/503.

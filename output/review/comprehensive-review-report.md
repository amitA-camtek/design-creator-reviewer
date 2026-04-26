# FalconAuditService — Comprehensive Design Review

**Document ID:** REV-FAU-001
**Date:** 2026-04-26
**Scope:** All design and pipeline files for Alternative 1 (Lazy-Open Channel Pipeline with Offset Pagination)
**Dimensions:** 8 (requirements coverage, security, storage, concurrency, API contract, language patterns, performance, configuration)

---

## Severity legend

| Severity | Meaning |
|---|---|
| **Critical** | Blocks correct operation, data integrity, or a hard requirement; must fix before/during implementation |
| **High** | Strong risk of bug, perf miss, or maintainability hit; fix during implementation |
| **Medium** | Worth fixing before first deployment |
| **Low** | Nice to have / cleanup |
| **Info** | Observation; no action required |

---

## Summary

| Severity | Count |
|---|---|
| Critical | 3 |
| High | 6 |
| Medium | 7 |
| Low | 4 |
| Info | 3 |
| **Total** | **23** |

The design is implementation-ready with three critical issues to address up front (one schema issue, one startup-ordering nuance, one channel back-pressure hazard) and six high-impact items to handle during coding.

---

## 1. Requirements coverage review

All 62 requirements have at least one component owner and one test case (cross-checked `architecture-design.md` §8 mapping table against `test-plan.md` §14 coverage summary). No gaps.

### F-REQ-001 [Info] CON-001 atomic-rename detection is best-effort
The design cites CON-001 (no NTFS-incompatible network share) but only catches the failure at first manifest write. There is no proactive probe at startup. Acceptable for v1 since the failure is loud and immediate, but worth a tracking item.

### F-REQ-002 [Low] REC-006 hostname caching not specified
`Environment.MachineName` is referenced in `EventRecorder` but no spec on whether it is captured once per process or per event. Cache it once (machine name does not change at runtime) to avoid repeated PInvoke.

---

## 2. Security review

### F-SEC-001 [Critical] Path validation regex misses NUL byte and Unicode tricks
**File:** `api-design.md` §1.3, `code-scaffolding.md` §14 (`Validators`)
The regex `^[\w\-. \\/]+$` allows backslash and forward slash, but does not explicitly reject:
- The NUL character (`\0`) on a path — embedded NUL in .NET string passed to `Path.Combine` truncates silently on some surfaces.
- Unicode look-alikes that pass `\w` (e.g. fullwidth solidus `U+FF0F`).
This is a real path-traversal bypass risk because `\w` in .NET regex matches Unicode letter classes by default.
**Recommendation:** Use a strict ASCII-only regex `^[A-Za-z0-9_.\- \\/]+$` AND reject any string containing `\0` or any character `< 0x20`. Add explicit `..` rejection (already documented but not in regex).

### F-SEC-002 [High] `path` filter in `/api/events` is used in `LIKE` without escaping
**File:** `schema-design.md` §7.5
The filter `WHERE rel_filepath LIKE @path_prefix` uses a parameter, which is good for SQL injection (CON-004) but the operator may include `%` or `_` in their input — the `LIKE` wildcards themselves. For prefix searches this leaks data unintentionally (`?path=Re%` matches everything starting with `Re` then anything).
**Recommendation:** Either document this explicitly as the intended behaviour, or escape `%`, `_`, and `\` in the supplied value before binding.

### F-SEC-003 [High] No length cap on `path` parameter at the API layer
**File:** `api-design.md` §1.3
The doc says "longer than 260 characters" is rejected, but the scaffolding's `Validators.IsSafePath` does not show the length check. Without one, a 1 MB query parameter could DoS the regex engine.
**Recommendation:** Reject any path > 260 chars **before** running the regex.

### F-SEC-004 [Medium] Sensitive content (P1 `old_content`) stored unencrypted at rest
**File:** `schema-design.md` §4.1, `service-context.md` security_context
P1 file contents (recipes, configs) live as plaintext in `audit.db`. The threat model focuses on tamper-evidence, not confidentiality. Acceptable per requirements, but this should be explicitly documented in the data-classification section so operators know `audit.db` files inherit the sensitivity of the original P1 files.
**Recommendation:** Add a "Data sensitivity" subsection to `service-context.md` security_context documenting that shard files carry the same confidentiality level as the watched config/recipe files.

### F-SEC-005 [Medium] `install.ps1` ACL plan does not address inheritance
**File:** `architecture-design.md` §6.2
Setting ACLs on `C:\bis\auditlog\` is shown, but if the parent `C:\bis\` allows inheritance, child folders may end up with broader-than-intended ACLs. The script should explicitly disable inheritance and apply explicit ACLs.
**Recommendation:** Use `icacls "C:\bis\auditlog" /inheritance:r` then explicit grants.

### F-SEC-006 [Low] Loopback-only fallback warning is not actionable
**File:** `api-design.md` §3.5
"with a warning log line on bind" — but a Serilog warning in a service log file is rarely seen by operators. A non-loopback bind should also write to the **Event Log** at warning level (INS-005) so it surfaces in standard ops dashboards.

---

## 3. Storage review

### F-STO-001 [Critical] `file_baselines.last_content` not size-capped
**File:** `schema-design.md` §4.2
The text says `last_content` is `TEXT` — but there is no column-level cap matching the `content_size_limit` config. A single oversize P1 file modify would write `is_content_omitted = 1` to `audit_log` (correct, per Q2) but the `last_content` baseline is upserted from the **prior** content unchanged. If the **prior** content was already > limit, it stays in the baseline forever and is read by every subsequent diff. This is a slow-leak storage bloat and a perf hazard.
**Recommendation:** When upserting `file_baselines`, apply the same `content_size_limit` check: if new content exceeds limit, set `last_content = NULL` in the baseline. Document this in `schema-design.md` §4.2 and in `EventRecorder.RecordAsync`.

### F-STO-002 [High] No checkpoint guard on long-running shards
**File:** `architecture-design.md` §1 shutdown sequence + `schema-design.md` §3
`PRAGMA wal_autocheckpoint = 1000` is set, but on a long-running shard with steady writes the WAL still grows (autocheckpoint only triggers on commit and only if the WAL exceeds the page count). For a job that runs 30 days, the WAL can exceed the main db file. We checkpoint only on graceful shutdown.
**Recommendation:** Run a periodic `PRAGMA wal_checkpoint(PASSIVE)` from each shard's writer task every N events (e.g. every 1000) or every M minutes (e.g. every 10).

### F-STO-003 [High] `EnumerateBaselinesAsync` materialises whole table in memory
**File:** `code-scaffolding.md` §10 (`SqliteRepository.EnumerateBaselinesAsync`)
The signature returns `IAsyncEnumerable<BaselineRow>` (good), but if the catch-up scanner uses LINQ `.ToList()` we lose streaming. The scanner with 10×150 files is fine, but a single job that has accumulated hundreds of thousands of baselines (rare but possible on a long-lived job) would page-fault.
**Recommendation:** Document in the scanner that it MUST iterate the async stream without materialising it. Add a unit test that asserts memory does not grow with baseline count.

### F-STO-004 [Medium] `INSERT OR REPLACE` on baselines loses concurrent updates without surfacing
**File:** `schema-design.md` §7.2
The `ON CONFLICT(filepath) DO UPDATE` clause silently overwrites. Because we serialise writes per shard via the writer task, this is safe in practice — but the semantic should be `the writer task is the only baseline updater`. Document this invariant.
**Recommendation:** Add an `ASSERT WriterTask.CurrentManagedThreadId == Environment.CurrentManagedThreadId` debug check inside `UpsertBaselineAsync`.

### F-STO-005 [Low] `audit_log.changed_at TEXT` precludes integer-range queries
ISO 8601 strings sort correctly only when zero-padded and timezone-uniform. Our format `2026-04-26T08:14:22.314Z` satisfies both, so this is fine — but it ties us to ISO 8601 forever. A future "give me events from the last hour" query is a string scan, not a numeric scan. Acceptable for v1.

---

## 4. Concurrency review

### F-CON-001 [Critical] Per-shard channel never closes on departure → writer task leaks
**File:** `code-scaffolding.md` §8 (`EventPipeline`), `architecture-design.md` §1 shutdown
The fan-out loop creates a per-shard `Channel<ClassifiedEvent>` and a writer task on first event. On `JobDeparted`, `ShardRegistry.DisposeShardAsync` disposes the repository but **the per-shard channel is not closed and the writer task continues awaiting it**. Result: a tiny `Task` leak per departed job (small but accumulates over days), and shutdown's `DrainAsync` waits forever for a writer task whose channel is permanently empty.
**Recommendation:** Add `EventPipeline.OnShardDeparting(jobName)` that calls `channel.Writer.Complete()` and awaits the writer task. Wire it into `JobManager.OnDepartureAsync` **before** `ShardRegistry.DisposeShardAsync`.

### F-CON-002 [High] Debouncer race: cancellation can fire before the new timer is in the dictionary
**File:** `code-scaffolding.md` §6 (`Debouncer.Push`)
A naive implementation `_timers.AddOrUpdate(path, ..., (k, oldCts) => { oldCts.Cancel(); return newCts; })` can race: the old CTS's continuation may execute before the new entry replaces it, causing a spurious classification of an outdated event. Proper sequence: cancel old → add new (atomically).
**Recommendation:** Use `_timers.AddOrUpdate` with the update factory that **first cancels** the old CTS and **then** returns the new one. Verify the continuation observes the cancellation before firing.

### F-CON-003 [High] Catch-up's `SemaphoreSlim` is per-instance, but `ScanAllAsync` releases mid-batch
**File:** `code-scaffolding.md` §13 (`CatchUpScanner.ScanAllAsync`) + architecture §2.11
The architecture says CUS-005 is enforced by `SemaphoreSlim(1, 1)`. The scaffolding splits between `QueueJobAsync` (single job, takes the gate) and `ScanAllAsync` (many jobs in parallel). If `ScanAllAsync` takes the gate once and releases at the end, parallel job scans inside it bypass the per-job gate — fine if all parallel scans share the gate, but if a `QueueJobAsync` is invoked by FSW overflow during a `ScanAllAsync`, both run.
**Recommendation:** Use a single shared `SemaphoreSlim(1, 1)` that both methods acquire. Document the contract: at most one *batch* of scans active at any time, regardless of source.

### F-CON-004 [Medium] `ManifestManager.OnEventRecordedAsync` not serialised per job
**File:** `code-scaffolding.md` §11 (`ManifestManager`)
`_cache` is a `ConcurrentDictionary` (safe) and `_gates` provides a per-job `SemaphoreSlim` (good), but the design does not state which path **takes** the gate. If `OnEventRecordedAsync` increments the cached counter without taking the gate, a concurrent `RecordDepartureAsync` (which atomic-renames the manifest) can serialise a stale counter.
**Recommendation:** Take the per-job gate on every cache mutation, not just on the file write.

### F-CON-005 [Medium] `ImmutableList<CompiledRule>` swap is non-blocking but ordering matters
**File:** `code-scaffolding.md` §7 (`ClassificationRulesLoader`)
`Interlocked.Exchange` on a reference is atomic — that's correct. But `FileClassifier.Classify` reads the field once at the start and iterates. This is correct. The risk is only if a future maintainer reads the field twice (e.g. `_loader.CurrentRules.Count` and then `_loader.CurrentRules[i]`) — they could see different snapshots.
**Recommendation:** Document the snapshot rule: any classifier method that reads the rule set must capture it into a local variable once.

### F-CON-006 [Low] `CancellationTokenSource` leak on debouncer shutdown
At service stop, the debouncer's `_timers` dictionary still holds CTSs whose registered delegates have not fired. They should be disposed (CTS implements IDisposable). Memory leak is tiny but real over many service-lifetime cycles in tests.

---

## 5. API contract review

### F-API-001 [High] `/api/events` cross-job (no `job` filter) is undefined when shards have schema mismatches
**File:** `api-design.md` §2.3
The doc says "queries every active shard and the global DB". If a future migration leaves some shards on schema v1 and others on v2 (because they did not re-open since the upgrade), the cross-job merge can throw on field projection. There is no schema-version probe in the cross-job code path.
**Recommendation:** On opening a read connection in the API, read `_meta.schema_version` and either (a) project only fields valid in that version, or (b) fail fast with `503 SCHEMA_MISMATCH`. Add to `Validators.cs`.

### F-API-002 [Medium] `id` route parameter not validated past `> 0`
**File:** `api-design.md` §2.4, `code-scaffolding.md` §14
ASP.NET Core route binding with `:long` rejects negatives and non-numeric, so this is mostly OK — but `long.MaxValue` is bound and then queried. Defensive cap is good practice.
**Recommendation:** Reject `id > 2^53 - 1` (JSON safe-integer boundary; preserves round-tripping for JS clients).

### F-API-003 [Medium] No `ETag` / `Cache-Control` headers on listing endpoints
List responses are highly cacheable for the duration of the count cache TTL. Adding `Cache-Control: max-age=30` for `/api/events` (when result is from cache) gives downstream proxies a free win and reduces round-trips.

### F-API-004 [Low] No request size limit on Kestrel
A misbehaving client could send a multi-MB query string. Set `KestrelServerOptions.Limits.MaxRequestHeadersTotalSize` to something reasonable (e.g. 16 KB).

---

## 6. Language / .NET patterns review

### F-LNG-001 [High] `IAsyncDisposable` chain is incomplete
**File:** `code-scaffolding.md` various
Several singletons are declared `IAsyncDisposable` (`ShardRegistry`, `JobDiscoveryService`, `ManifestManager`) but the host's shutdown path in `FalconAuditWorker.StopAsync` is not specified to await them. Microsoft.Extensions.Hosting will dispose registered services automatically only if they implement `IDisposable`/`IAsyncDisposable` AND are registered with `AddSingleton` (which they are). Good. But the **order** of disposal is reverse-registration, which puts `ShardRegistry` disposal before `EventPipeline`'s — the writer tasks would attempt to write to an already-disposed repository.
**Recommendation:** Make `FalconAuditWorker.StopAsync` orchestrate explicit disposal in the correct order: stop FSW → stop debouncer → drain pipeline → flush manifest → dispose shards → stop API.

### F-LNG-002 [Medium] No `ConfigureAwait(false)` policy stated
For a service (not UI), `ConfigureAwait(false)` is recommended on every library-style await to avoid context capture. The scaffolding has many `await`s; the policy is silent.
**Recommendation:** Adopt `ConfigureAwait(false)` everywhere except inside ASP.NET Core endpoint handlers (where it doesn't matter).

### F-LNG-003 [Medium] `ConcurrentDictionary` `GetOrAdd` with `Lazy<T>` factory is the correct idiom but not enforced
**File:** `code-scaffolding.md` §10 (`ShardRegistry`)
`ConcurrentDictionary.GetOrAdd` may invoke its factory more than once for the same key under contention; wrapping in `Lazy<T>` deduplicates. The scaffolding declares `ConcurrentDictionary<string, Lazy<SqliteRepository>>` — good — but the spec doesn't show the access call must use `.Value` lazily.
**Recommendation:** In `GetOrCreate`, return `_shards.GetOrAdd(jobName, k => new Lazy<SqliteRepository>(() => OpenSync(k), LazyThreadSafetyMode.ExecutionAndPublication)).Value`.

### F-LNG-004 [Low] Nullable annotations missing on a few interfaces
Several method signatures in `code-scaffolding.md` have `string?` for parameters that should never be null (e.g. `FileClassifier.Classify(RawFileEvent raw)` — `raw` cannot be null). Cleanup pass during implementation.

### F-LNG-005 [Info] `record` types are reasonable for DTOs and event types
Good use of `sealed record` throughout for value semantics. No action.

---

## 7. Performance review

### F-PRF-001 [High] Deep-page `LIMIT/OFFSET` will miss PERF-005 on million-row shards
**File:** `api-design.md` §2.3 + `schema-design.md` §7.5
Even with `ix_audit_priority_time`, an `OFFSET 50000` requires SQLite to scan 50 000 index entries. On a shard that has accumulated 10 days × 100 K events = 1 M rows, p95 for offset 50 000 will exceed 200 ms. The Alt-1 doc acknowledges this risk.
**Recommendation:** Add a documented page-depth cap (e.g. `offset + limit <= 5000`) at the API layer, returning `400 PAGE_TOO_DEEP` beyond it. Tell users they should narrow with `from`/`to` filters for deep history. This is a cheap, honest fix and matches operator expectations.

### F-PRF-002 [Medium] Hash retry back-off is fixed at 100 ms
**File:** `architecture-design.md` §2.6, REC-009
Three retries × 100 ms = 300 ms in the worst case, but if the file is being slowly written by another process, three 100 ms sleeps may not be enough. Linear is fine; a more resilient option is exponential (100, 200, 400 ms = 700 ms total) which still fits inside PERF-002's 1 s budget.

### F-PRF-003 [Medium] `COUNT(*)` cache key is filter-string; minor memory concern
**File:** `architecture-design.md` §2.12
Filter combinations are unbounded. The cache is `IMemoryCache` (good — has eviction) but a misbehaving caller could thrash it.
**Recommendation:** Cap `IMemoryCache` size to something reasonable (e.g. `SizeLimit = 1000` entries) and assign `Size = 1` per entry.

### F-PRF-004 [Low] No async file I/O in `ManifestManager.WriteAtomicAsync`
Writing JSON to a temp file and renaming is fast (< 1 ms typical), but using `FileStream` with `useAsync: false` is the .NET default and blocks a thread-pool thread for a few microseconds. Pass `useAsync: true`.

---

## 8. Configuration review

### F-CFG-001 [Medium] Default config values not validated at startup
**File:** `code-scaffolding.md` §4 (`MonitorConfig`)
`MonitorConfig` is a POCO; missing validation. If `debounce_ms = -1`, the debouncer will fire immediately. If `api_port = 0`, Kestrel chooses a random port and breaks documentation.
**Recommendation:** Use `IValidateOptions<MonitorConfig>` and validate ranges at startup. Fail-fast with a useful error.

### F-CFG-002 [Medium] `watch_path` not normalised
Trailing slash, mixed slashes, drive-letter casing all matter for downstream string comparisons. `c:\job\` vs `C:\job` would produce different `rel_filepath` values.
**Recommendation:** Normalise once at startup using `Path.GetFullPath()` and store the canonical form in the config.

### F-CFG-003 [Low] `appsettings.json` does not show `Development` overrides
Standard practice is to also have `appsettings.Development.json` for local dev (e.g. shorter `debounce_ms`). Not strictly required.

### F-CFG-004 [Info] Serilog config is in `appsettings.json` rather than code
Good — keeps log routing operator-tunable without rebuild.

---

## 9. Cross-cutting observations

### F-XX-001 [Info] PowerShell install script line endings
`install.ps1` should be CRLF; document this so it doesn't get accidentally LF-converted by editors on dev machines and break in PowerShell 5.1.

### F-XX-002 [Info] Test plan does not specify per-test data fixtures
Acceptable; fixtures are an implementation detail. Mentioned for completeness.

---

## 10. Findings index (sortable)

| ID | Sev | Dimension | Title | Patch ref |
|---|---|---|---|---|
| F-SEC-001 | Critical | Security | Path validation regex bypass via Unicode/NUL | `fix-patches.md#f-sec-001` |
| F-STO-001 | Critical | Storage | `file_baselines.last_content` not size-capped | `fix-patches.md#f-sto-001` |
| F-CON-001 | Critical | Concurrency | Per-shard channel never closes on departure | `fix-patches.md#f-con-001` |
| F-SEC-002 | High | Security | LIKE wildcards in `path` filter not escaped | `fix-patches.md#f-sec-002` |
| F-SEC-003 | High | Security | No length cap on path query parameter | `fix-patches.md#f-sec-003` |
| F-STO-002 | High | Storage | No periodic WAL checkpoint on long-running shards | `fix-patches.md#f-sto-002` |
| F-STO-003 | High | Storage | EnumerateBaselines must stream | `fix-patches.md#f-sto-003` |
| F-CON-002 | High | Concurrency | Debouncer cancel/replace race | `fix-patches.md#f-con-002` |
| F-CON-003 | High | Concurrency | Catch-up gate semantics | `fix-patches.md#f-con-003` |
| F-API-001 | High | API | Cross-job query has no schema-version probe | `fix-patches.md#f-api-001` |
| F-LNG-001 | High | Language | Disposal order unsafe | `fix-patches.md#f-lng-001` |
| F-PRF-001 | High | Performance | Deep-offset pagination misses PERF-005 | `fix-patches.md#f-prf-001` |
| F-SEC-004 | Medium | Security | P1 content unencrypted at rest | — |
| F-SEC-005 | Medium | Security | install.ps1 ACL inheritance | — |
| F-STO-004 | Medium | Storage | Document baseline upsert single-writer invariant | — |
| F-CON-004 | Medium | Concurrency | Manifest cache mutation gate | — |
| F-CON-005 | Medium | Concurrency | Snapshot-rule for ImmutableList reads | — |
| F-API-002 | Medium | API | Defensive cap on `id` parameter | — |
| F-API-003 | Medium | API | Cache-Control headers | — |
| F-LNG-002 | Medium | Language | ConfigureAwait(false) policy | — |
| F-LNG-003 | Medium | Language | `Lazy<T>.Value` access via `GetOrAdd` | — |
| F-PRF-002 | Medium | Performance | Hash retry back-off should be exponential | — |
| F-PRF-003 | Medium | Performance | Bound the COUNT cache | — |
| F-CFG-001 | Medium | Config | Validate config ranges at startup | — |
| F-CFG-002 | Medium | Config | Normalise `watch_path` at startup | — |
| F-REQ-002 | Low | Requirements | Cache `Environment.MachineName` | — |
| F-STO-005 | Low | Storage | ISO 8601 string sorting | — |
| F-CON-006 | Low | Concurrency | CTS leak on debouncer shutdown | — |
| F-API-004 | Low | API | Kestrel header size limit | — |
| F-LNG-004 | Low | Language | Nullable annotations cleanup | — |
| F-SEC-006 | Low | Security | Non-loopback bind warning to Event Log | — |
| F-PRF-004 | Low | Performance | `useAsync: true` on manifest writes | — |
| F-CFG-003 | Low | Config | `appsettings.Development.json` | — |
| F-REQ-001 | Info | Requirements | CON-001 atomic rename probe | — |
| F-LNG-005 | Info | Language | Use of records is good | — |
| F-CFG-004 | Info | Config | Serilog config location | — |
| F-XX-001 | Info | Cross | install.ps1 line endings | — |
| F-XX-002 | Info | Cross | Test plan fixtures | — |

The 12 Critical/High findings have before/after patches in `fix-patches.md`. Medium and below are listed for tracking; their fixes are small or doc-only and do not warrant code patches at the design stage.

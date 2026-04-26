# FalconAuditService — Fix Patches

**Document ID:** FIX-FAU-001
**Date:** 2026-04-26
**Scope:** Before/after patches for the 12 Critical and High findings in `comprehensive-review-report.md`.

Each patch shows the affected file, the relevant `Before` snippet, and the `After` snippet to apply.

---

## f-sec-001 — Path validation regex bypass via Unicode/NUL [Critical]

**Affected files:** `api-design.md` §1.3, `pipeline/code-scaffolding.md` §14 (`Validators.cs`)

### Before (api-design.md §1.3)
```
All path-like parameters (`job`, `path`) are validated against `^[\w\-. \\/]+$` before use (API-008, CON-005). Specifically rejected:
- Strings containing `..` (parent traversal)
- Strings starting with `/`, `\`, or a drive letter (absolute paths)
- Strings longer than 260 characters
```

### After
```
All path-like parameters (`job`, `path`) are validated **before any other use** (API-008, CON-005) by `Validators.IsSafePath`, which enforces all of:

1. Length: 1 <= len <= 260
2. ASCII-only character set: regex `^[A-Za-z0-9_.\- \\/]+$`  (note: the explicit ASCII class — NOT `\w`, which matches Unicode letters in .NET)
3. No control characters: every char must satisfy `>= 0x20`
4. No NUL byte: `value.IndexOf('\0') == -1`
5. No traversal: must NOT contain `..` as a path segment
6. Not absolute: must NOT start with `/`, `\`, or `<letter>:`
```

### Before (code-scaffolding.md §14)
```csharp
internal static class Validators
{
    private static readonly Regex SafePath = new(@"^[\w\-. \\/]+$", RegexOptions.Compiled);
    private static readonly Regex SafeJobName = new(@"^[\w\-. ]+$", RegexOptions.Compiled);

    public static bool IsSafePath(string? value) => throw new NotImplementedException();
    public static bool IsSafeJobName(string? value) => throw new NotImplementedException();
    public static bool TryParseIso(string? value, out DateTime utc) => throw new NotImplementedException();
}
```

### After
```csharp
internal static class Validators
{
    // Strict ASCII set — explicitly NOT \w (which is Unicode-aware in .NET).
    private static readonly Regex SafePath    = new(@"^[A-Za-z0-9_.\- \\/]+$", RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private static readonly Regex SafeJobName = new(@"^[A-Za-z0-9_.\- ]+$",     RegexOptions.Compiled | RegexOptions.CultureInvariant);

    public static bool IsSafePath(string? value)
    {
        if (string.IsNullOrEmpty(value)) return false;
        if (value.Length > 260) return false;
        if (value.IndexOf('\0') >= 0) return false;
        for (int i = 0; i < value.Length; i++) if (value[i] < 0x20) return false;
        if (value.Contains("..", StringComparison.Ordinal)) return false;
        if (value.StartsWith('/') || value.StartsWith('\\')) return false;
        if (value.Length >= 2 && value[1] == ':') return false; // drive letter
        return SafePath.IsMatch(value);
    }

    public static bool IsSafeJobName(string? value)
    {
        if (string.IsNullOrEmpty(value)) return false;
        if (value.Length > 128) return false;
        if (value.IndexOf('\0') >= 0) return false;
        if (value.Contains("..", StringComparison.Ordinal)) return false;
        return SafeJobName.IsMatch(value);
    }

    public static bool TryParseIso(string? value, out DateTime utc)
    {
        utc = default;
        if (string.IsNullOrEmpty(value)) return false;
        return DateTime.TryParse(value, System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.AssumeUniversal | System.Globalization.DateTimeStyles.AdjustToUniversal,
            out utc);
    }
}
```

---

## f-sto-001 — `file_baselines.last_content` not size-capped [Critical]

**Affected files:** `schema-design.md` §4.2, `architecture-design.md` §2.6, `pipeline/code-scaffolding.md` §10

### Before (schema-design.md §4.2)
```sql
CREATE TABLE IF NOT EXISTS file_baselines (
    filepath        TEXT NOT NULL PRIMARY KEY,
    last_hash       TEXT NOT NULL,
    last_seen       TEXT NOT NULL,    -- ISO 8601 UTC; updated on every observed event (REC-008)
    last_content    TEXT NULL         -- only stored for P1 paths; used as the "old" side of the next diff
);
```

### After (schema-design.md §4.2)
```sql
CREATE TABLE IF NOT EXISTS file_baselines (
    filepath        TEXT NOT NULL PRIMARY KEY,
    last_hash       TEXT NOT NULL,
    last_seen       TEXT NOT NULL,    -- ISO 8601 UTC; updated on every observed event (REC-008)
    last_content    TEXT NULL         -- only stored for P1 paths whose size <= content_size_limit;
                                      -- NULL when the file is over the cap or the path is non-P1.
                                      -- Used as the "old" side of the next diff. (Q2)
);
```

### Before (architecture-design.md §2.6)
```
5. **Oversize check (Q2 / REC-004):** if `file.Length > content_size_limit`, set `is_content_omitted = 1`, leave `old_content` and `diff_text` `NULL`. Hash and row are still written.
```

### After (architecture-design.md §2.6)
```
5. **Oversize check (Q2 / REC-004):** if `file.Length > content_size_limit`, set the audit row's `is_content_omitted = 1` and leave `old_content` and `diff_text` NULL. Hash and row are still written.
   **Additionally, on baseline upsert, if the new file size is over the cap, set `file_baselines.last_content = NULL`.** This prevents an oversize file from poisoning future diffs by leaving stale, possibly truncated content in the baseline. The hash always reflects the real on-disk file.
```

### Before (code-scaffolding.md §10 — `BaselineRow`)
```csharp
public sealed record BaselineRow(string Filepath, string LastHash, DateTime LastSeen, string? LastContent);
```

### After
*(no record change — the constructor is the same; the change is in the `EventRecorder.RecordAsync` body, which decides when `LastContent` is null. Document the contract in a `<remarks>` XML doc:)*
```csharp
/// <summary>Per-file baseline. <see cref="LastContent"/> is null if the file is non-P1 or its size exceeds <c>content_size_limit</c>.</summary>
public sealed record BaselineRow(string Filepath, string LastHash, DateTime LastSeen, string? LastContent);
```

---

## f-con-001 — Per-shard channel never closes on departure [Critical]

**Affected files:** `architecture-design.md` §1 shutdown / §2.7, `pipeline/code-scaffolding.md` §8 (`EventPipeline`) and §10 (`ShardRegistry`), §12 (`JobManager`)

### Before (architecture-design.md §1 shutdown sequence)
```
3. Drain each per-shard sub-channel — writer tasks complete pending events.
4. Flush and dispose every `SqliteRepository` in the registry; record final manifest entries.
```

### After
```
3. Stop the FSW and wait briefly for the debouncer's pending timers to fire (up to debounce_ms).
4. For each active shard, in order: `EventPipeline.CompleteShardAsync(jobName)` (closes the per-shard channel writer; awaits the writer task to drain), then `ShardRegistry.DisposeShardAsync(jobName)` (disposes the SqliteRepository; flushes manifest counter).
5. Flush global manifest counters via `ManifestManager.FlushAsync`.
6. Stop Kestrel.
```

### Before (code-scaffolding.md §8 — `EventPipeline`)
```csharp
public interface IEventPipeline : IAsyncDisposable
{
    Task WriteAsync(ClassifiedEvent ev, CancellationToken ct);
    int PendingCount { get; }
    Task DrainAsync(CancellationToken ct);
}
```

### After
```csharp
public interface IEventPipeline : IAsyncDisposable
{
    Task WriteAsync(ClassifiedEvent ev, CancellationToken ct);
    int PendingCount { get; }
    Task DrainAsync(CancellationToken ct);

    /// <summary>
    /// Marks a shard as departing: completes its per-shard channel, awaits the writer task
    /// to drain pending events, and removes it from the fan-out map. Must be called
    /// BEFORE <see cref="IShardRegistry.DisposeShardAsync"/> for the same job.
    /// </summary>
    Task CompleteShardAsync(string jobName, CancellationToken ct);
}
```

### Before (code-scaffolding.md §12 — `JobManager.OnDepartureAsync`)
```csharp
public Task OnDepartureAsync(string jobName, CancellationToken ct) => throw new NotImplementedException();
```

### After (with the order spelled out as a contract comment)
```csharp
/// <summary>
/// Job departure handler. Order of operations is critical:
/// 1) record manifest departure timestamp,
/// 2) complete the per-shard event channel and await the writer task,
/// 3) dispose the SqliteRepository,
/// 4) refresh JobDiscoveryService.
/// Reversing 2 and 3 would cause the writer task to write to a disposed connection.
/// </summary>
public Task OnDepartureAsync(string jobName, CancellationToken ct) => throw new NotImplementedException();
```

---

## f-sec-002 — LIKE wildcards in `path` filter not escaped [High]

**Affected files:** `schema-design.md` §7.5, `api-design.md` §2.3

### Before (schema-design.md §7.5)
```sql
  /* AND rel_filepath LIKE @path_prefix  -- when filter present */
```

### After
```sql
  /* AND rel_filepath LIKE @path_prefix ESCAPE '\\'  -- when filter present; @path_prefix is built as
     (escapedValue + '%') where escapedValue replaces '\\','%','_' with '\\\\','\\%','\\_' respectively */
```

### Before (api-design.md §2.3 — `path` parameter description)
```
| `path` | string | no | (any) | Substring match on `rel_filepath` (validated) |
```

### After
```
| `path` | string | no | (any) | Prefix match on `rel_filepath` (validated). The supplied value is treated as a literal prefix; SQL LIKE wildcards (`%`, `_`) and the escape character (`\`) are escaped before binding. |
```

---

## f-sec-003 — No length cap on path query parameter [High]

**Affected files:** `pipeline/code-scaffolding.md` §14 (`Validators.IsSafePath`)

The fix is folded into **f-sec-001** above (line `if (value.Length > 260) return false;` is the new first check after null/empty).

---

## f-sto-002 — No periodic WAL checkpoint on long-running shards [High]

**Affected files:** `architecture-design.md` §2.8, `schema-design.md` §3, `pipeline/code-scaffolding.md` §10 (`SqliteRepository`)

### Before (schema-design.md §3)
```sql
PRAGMA wal_autocheckpoint = 1000;     -- ~1000 pages between auto checkpoints
```

### After
```sql
PRAGMA wal_autocheckpoint = 1000;     -- ~1000 pages between auto checkpoints (≈4 MB)

-- Plus: writer task issues `PRAGMA wal_checkpoint(PASSIVE);` every 1000 events
-- AND every 10 minutes (whichever comes first), to bound WAL file size on long shards.
-- TRUNCATE checkpoint runs only at graceful shutdown.
```

### Before (code-scaffolding.md §10 — `SqliteRepository`)
```csharp
public Task UpsertBaselineAsync(BaselineRow row, CancellationToken ct) => throw new NotImplementedException();
public Task<BaselineRow?> GetBaselineAsync(string filepath, CancellationToken ct) => throw new NotImplementedException();
```

### After (add a method)
```csharp
public Task UpsertBaselineAsync(BaselineRow row, CancellationToken ct) => throw new NotImplementedException();
public Task<BaselineRow?> GetBaselineAsync(string filepath, CancellationToken ct) => throw new NotImplementedException();

/// <summary>Issues PRAGMA wal_checkpoint with the given mode. Called periodically by the writer task.</summary>
public Task CheckpointAsync(WalCheckpointMode mode, CancellationToken ct) => throw new NotImplementedException();
```

```csharp
public enum WalCheckpointMode { Passive, Full, Restart, Truncate }
```

---

## f-sto-003 — `EnumerateBaselinesAsync` must stream [High]

**Affected files:** `pipeline/code-scaffolding.md` §10 (`SqliteRepository`), §13 (`CatchUpScanner`)

### Before (code-scaffolding.md §10)
```csharp
public IAsyncEnumerable<BaselineRow> EnumerateBaselinesAsync(CancellationToken ct) => throw new NotImplementedException();
```

### After (signature unchanged but with a contract doc; CatchUpScanner discipline is documented separately)
```csharp
/// <summary>
/// Streams baseline rows one at a time from the open writer connection.
/// CALLERS MUST consume via `await foreach` and MUST NOT call `.ToListAsync()`
/// or any other materialising operator. This is required to bound memory usage
/// on shards with very large baseline counts.
/// </summary>
public IAsyncEnumerable<BaselineRow> EnumerateBaselinesAsync(CancellationToken ct) => throw new NotImplementedException();
```

### Before (code-scaffolding.md §13 — `CatchUpScanner.ScanJobAsync`)
```csharp
private Task ScanJobAsync(string jobName, CancellationToken ct) => throw new NotImplementedException();
```

### After (with a contract doc)
```csharp
/// <summary>
/// Reconciles on-disk state for one job against `file_baselines`.
/// Iterates baselines via `await foreach` (streaming) so memory is O(1) in baseline count.
/// </summary>
private Task ScanJobAsync(string jobName, CancellationToken ct) => throw new NotImplementedException();
```

---

## f-con-002 — Debouncer cancel/replace race [High]

**Affected files:** `pipeline/code-scaffolding.md` §6 (`Debouncer.Push`)

### Before
```csharp
public void Push(RawFileEvent ev) => throw new NotImplementedException();
private async Task FireAfterDelayAsync(RawFileEvent ev, CancellationToken ct) => throw new NotImplementedException();
```

### After (with the correct cancel-then-replace idiom documented)
```csharp
/// <summary>
/// Push a raw event for debouncing. If a timer is already pending for `ev.Filepath`,
/// it is cancelled and replaced with a new one. Cancellation must complete BEFORE
/// the replacement enters the dictionary to avoid a race where the cancelled timer's
/// continuation fires against a stale event.
/// </summary>
public void Push(RawFileEvent ev) => throw new NotImplementedException();

/// <summary>
/// The continuation that fires after `debounce_ms` if not cancelled.
/// Must check `ct.IsCancellationRequested` BEFORE classifying so that a late-cancelled
/// timer does not produce a spurious classification.
/// </summary>
private async Task FireAfterDelayAsync(RawFileEvent ev, CancellationToken ct) => throw new NotImplementedException();
```

Implementation note (to be in the body):
```csharp
// Inside Push:
var cts = new CancellationTokenSource();
_timers.AddOrUpdate(
    ev.Filepath,
    addValueFactory:    _ => cts,
    updateValueFactory: (_, oldCts) =>
    {
        try { oldCts.Cancel(); } catch (ObjectDisposedException) { /* benign */ }
        oldCts.Dispose();
        return cts;
    });
_ = FireAfterDelayAsync(ev, cts.Token);

// Inside FireAfterDelayAsync, AFTER the await Task.Delay:
ct.ThrowIfCancellationRequested();          // prevents stale-timer firing
_timers.TryRemove(new KeyValuePair<string, CancellationTokenSource>(ev.Filepath, /*ourCts*/));
// then forward to classifier/pipeline
```

---

## f-con-003 — Catch-up gate semantics [High]

**Affected files:** `architecture-design.md` §2.11, `pipeline/code-scaffolding.md` §13 (`CatchUpScanner`)

### Before (architecture-design.md §2.11)
```
The gate is **per-instance**, so the parallel-scan workflow uses a different overload that holds the gate once across all jobs in that batch.
```

### After
```
The gate is a **single instance shared by both `QueueJobAsync` and `ScanAllAsync`**. CUS-005 says exactly one scan must be in flight at any moment, regardless of the trigger:

- `QueueJobAsync(name)` acquires the gate, runs `ScanJobAsync(name)`, releases.
- `ScanAllAsync(names)` acquires the gate ONCE, runs every job's scan in parallel under the same gate, releases when all complete.
- An FSW-overflow trigger that calls `QueueJobAsync` **during** an in-flight `ScanAllAsync` blocks on the gate until the batch finishes — by design.
```

### Before (code-scaffolding.md §13 — `CatchUpScanner`)
```csharp
public Task QueueJobAsync(string jobName, CancellationToken ct) => throw new NotImplementedException();
public Task ScanAllAsync(IEnumerable<string> jobNames, CancellationToken ct) => throw new NotImplementedException();
```

### After (with explicit contract docs)
```csharp
/// <summary>
/// Run a catch-up scan for a single job. Acquires the shared scan gate; blocks if any
/// other scan is in flight. Use this for FSW-overflow recovery and JobArrived events.
/// </summary>
public Task QueueJobAsync(string jobName, CancellationToken ct) => throw new NotImplementedException();

/// <summary>
/// Run catch-up scans for many jobs in parallel under a single hold of the shared gate.
/// Used at startup. Other scan triggers will block on the gate until this batch returns.
/// </summary>
public Task ScanAllAsync(IEnumerable<string> jobNames, CancellationToken ct) => throw new NotImplementedException();
```

---

## f-api-001 — Cross-job query has no schema-version probe [High]

**Affected files:** `api-design.md` §2.3, `schema-design.md` §6, `pipeline/code-scaffolding.md` §14

### Before (api-design.md §2.3)
```
| `job` | string | no | (all) | Job name; if omitted, queries every active shard and the global DB |
```

### After
```
| `job` | string | no | (all) | Job name; if omitted, queries every active shard and the global DB. |

When `job` is omitted, the API opens a read connection per shard and reads `_meta.schema_version` first. A shard whose `schema_version` does not match the API's expected version is **skipped** with a `Warning` log entry; the response includes a `skipped_shards` array listing skipped shard names. This prevents a single out-of-date shard from breaking cross-job queries.
```

### Before (schema-design.md §6 — Migration strategy)
*(no change to the migration strategy itself; the API just needs to read `_meta.schema_version`).*

### After (response shape addendum to api-design.md §2.3)
```json
{
  "total": 1287,
  "limit": 50,
  "offset": 0,
  "items": [ ... ],
  "skipped_shards": []   // present only when cross-job and any shard was skipped
}
```

---

## f-lng-001 — Disposal order unsafe [High]

**Affected files:** `architecture-design.md` §1, `pipeline/code-scaffolding.md` §5 (`FalconAuditWorker.StopAsync`)

### Before (architecture-design.md §1 shutdown)
```
1. Cancel the global `CancellationTokenSource`.
2. Stop accepting new events at `FileMonitor` (dispose the FSW).
3. Drain each per-shard sub-channel — writer tasks complete pending events.
4. Flush and dispose every `SqliteRepository` in the registry; record final manifest entries.
5. Stop Kestrel.
6. Grace period: 30 seconds. Anything still pending is logged as a warning and dropped (REL-001 contract: drop only at shutdown).
```

### After
```
Shutdown is orchestrated EXPLICITLY by `FalconAuditWorker.StopAsync` rather than relying on DI reverse-disposal order:

1. Cancel the global `CancellationTokenSource`.
2. `FileMonitor.Stop()` — stop FSW callbacks immediately.
3. `DirectoryWatcher.Stop()`.
4. `JobDiscoveryService.Stop()`.
5. Wait up to `debounce_ms + 100ms` so any in-flight debouncer timers fire.
6. For each active shard (parallel):
   a. `EventPipeline.CompleteShardAsync(jobName)` — closes the channel; awaits the writer task.
   b. `ManifestManager.FlushAsync(jobName)` — writes final manifest counter.
   c. `ShardRegistry.DisposeShardAsync(jobName)` — checkpoints WAL (`TRUNCATE`), closes connection.
7. Stop Kestrel.
8. Grace period: 30 seconds total budget for all the above (SVC-004). If exceeded, log warning and continue (best-effort).
```

### Before (code-scaffolding.md §5 — `FalconAuditWorker.StopAsync`)
```csharp
public override async Task StopAsync(CancellationToken ct) => throw new NotImplementedException();
```

### After (with the orchestration documented)
```csharp
/// <summary>
/// Orchestrates an ordered shutdown. The order is critical (see architecture-design.md §1):
/// stop event sources -> drain timers -> complete each shard channel -> flush manifests
/// -> dispose shards -> stop API. Reversing any step risks writes against a disposed connection
/// or lost events.
/// </summary>
public override async Task StopAsync(CancellationToken ct) => throw new NotImplementedException();
```

---

## f-prf-001 — Deep-offset pagination misses PERF-005 [High]

**Affected files:** `api-design.md` §1.3 + §2.3

### Before (api-design.md §1.3)
```
`limit` must be in `[1, 500]`; default 50. `offset` must be `>= 0`; default 0.
```

### After
```
`limit` must be in `[1, 500]`; default 50.
`offset` must be `>= 0`; default 0.
**`offset + limit` must be <= 5000** — beyond this depth, the API returns `400 PAGE_TOO_DEEP` and instructs the client to add a `from`/`to` filter. This cap protects PERF-005 (200 ms p95) on million-row shards. The cap is a configuration key (`max_page_depth`, default 5000) so operators can tune it for narrower or wider workloads.
```

### Before (api-design.md §2.3 — Errors)
```
- `400 INVALID_LIMIT` — `limit` outside `[1, 500]`
- `404 JOB_NOT_FOUND` — `job=...` provided but unknown to `JobDiscoveryService`
```

### After
```
- `400 INVALID_LIMIT` — `limit` outside `[1, 500]`
- `400 PAGE_TOO_DEEP` — `offset + limit > max_page_depth`. Recommend narrowing with `from`/`to` filters.
- `404 JOB_NOT_FOUND` — `job=...` provided but unknown to `JobDiscoveryService`
```

### Add to MonitorConfig (code-scaffolding.md §4)
```csharp
public int MaxPageDepth { get; init; } = 5000;
```

---

## Summary

| ID | Severity | Files patched |
|---|---|---|
| f-sec-001 | Critical | `api-design.md`, `code-scaffolding.md` |
| f-sto-001 | Critical | `schema-design.md`, `architecture-design.md`, `code-scaffolding.md` |
| f-con-001 | Critical | `architecture-design.md`, `code-scaffolding.md` (EventPipeline + JobManager) |
| f-sec-002 | High | `schema-design.md`, `api-design.md` |
| f-sec-003 | High | folded into f-sec-001 |
| f-sto-002 | High | `schema-design.md`, `code-scaffolding.md` (SqliteRepository) |
| f-sto-003 | High | `code-scaffolding.md` (SqliteRepository, CatchUpScanner) — doc contract |
| f-con-002 | High | `code-scaffolding.md` (Debouncer) — doc contract + impl note |
| f-con-003 | High | `architecture-design.md`, `code-scaffolding.md` (CatchUpScanner) |
| f-api-001 | High | `api-design.md` (response shape + behaviour) |
| f-lng-001 | High | `architecture-design.md`, `code-scaffolding.md` (FalconAuditWorker) |
| f-prf-001 | High | `api-design.md`, `code-scaffolding.md` (MonitorConfig) |

All other findings (Medium and below) are tracked in `comprehensive-review-report.md` §10 and addressed during implementation rather than as design-stage patches.

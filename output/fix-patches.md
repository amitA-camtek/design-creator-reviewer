# FalconAuditService — Fix Patches

| Field | Value |
|---|---|
| Date | 2026-04-25 |
| Source report | `C:\Claude\design-creator-reviewer\output\comprehensive-review-report.md` |
| Target files | All design documents in `C:\Claude\design-creator-reviewer\output\` |
| Author | fix-generator |
| Fixes ordered by | Priority (Critical → Low), matching the Prioritised Action Plan |

Each fix below maps to a numbered row in the Prioritised Action Plan of the review report. Fixes are presented as concrete diff-style edits (or full replacement blocks) against the existing design markdown / code-scaffolding. Apply them in order; later fixes assume earlier ones are in place.

---

## Fix 1 — API-001 reconciliation (Critical)

**Issue**: Multi-hosted architecture violates API-001 ("hosted within the same Windows Service process").

**Decision required from product owner**: Either (A) accept the multi-hosted design and obtain a written deviation against API-001, or (B) collapse to a single-process host.

**Patch (option B — recommended for first release; defers process-isolation benefits to v2)**:

In `architecture-design.md` §1 replace:

```diff
-The system is delivered as **two independent Windows services** sharing a `FalconAuditService.Core` class library. Process boundaries deliver crash isolation between writes and reads:
-
-- **`FalconAuditWorker`** — `BackgroundService` that owns the FileSystemWatcher pipeline, shard registry (read-write), manifest, and catch-up scanner. This is the only writer to any audit DB.
-- **`FalconAuditQuery`** — ASP.NET Core process hosting the read-only HTTP API on port 5100 (loopback). Opens shards strictly in `Mode=ReadOnly` and never holds write locks.
+The system is delivered as **a single Windows Service** (`FalconAuditService`) that hosts both the writer pipeline and the read-only HTTP API in the same process, satisfying API-001 verbatim. Two registrations live under one host:
+
+- A `BackgroundService` (`AuditHost`) owning the FileSystemWatcher pipeline, shard registry (read-write), manifest, and catch-up scanner.
+- An ASP.NET Core Kestrel pipeline bound to `127.0.0.1:5100` (loopback) hosting the read-only API. The API uses an **independent `IShardReaderFactory`** that opens every connection with `Mode=ReadOnly` and never shares a `SqliteConnection` with the writer.
+
+Read/write isolation is achieved at the SQLite level (WAL, REL-004), not at the process level.
```

Update §2 process topology, §5 DI registration plan (merge both `Program.cs` blocks into one `WebApplication.CreateBuilder` host that adds `AddHostedService<AuditHost>`), and `code-scaffolding.md` §1 + §4.1 + §6.1 accordingly.

**Patch (option A — keep multi-hosted)**: Add a "Deviation" subsection to `architecture-design.md` §1 explicitly noting the requirement waiver and obtaining product-owner sign-off; mirror it in `design-package-summary.md`.

For the rest of this document I assume option B.

---

## Fix 2 — `FileMonitor.OnRaw` blocking call (Critical)

In `code-scaffolding.md` §4.3, replace `OnRaw` with:

```csharp
private void OnRaw(string path, FileChangeType type, string? oldPath = null)
{
    _debouncer.Schedule(path, () => _ = ProcessAsync(path, type, oldPath));
}

private async Task ProcessAsync(string path, FileChangeType type, string? oldPath)
{
    try
    {
        var raw = new RawFsEvent(path, type, _clock.UtcNow, oldPath);
        var classified = _classifier.Classify(raw, _config.CurrentValue.WatchPath);
        if (classified is null) return;            // P4 ignored
        await _shards.RouteAsync(classified).ConfigureAwait(false);
    }
    catch (Exception ex)
    {
        _log.LogError(ex, "Failed to process file event {Path}", path);
    }
}
```

Rationale: keeps the FSW callback synchronous (returning quickly) while moving the actual routing to a Task. The `_ = ProcessAsync(...)` pattern explicitly observes the Task and routes exceptions via the catch block.

---

## Fix 3 — `AuditHost.ExecuteAsync` shutdown (Critical)

In `code-scaffolding.md` §4.2, replace the body of `ExecuteAsync`'s "Stay alive" line:

```diff
-        // Stay alive
-        await Task.Delay(Timeout.Infinite, stoppingToken).ContinueWith(_ => { });
+        // Stay alive until cancellation is requested. OperationCanceledException
+        // is the expected shutdown signal and propagates out to the framework
+        // which handles it as a clean stop.
+        try
+        {
+            await Task.Delay(Timeout.Infinite, stoppingToken);
+        }
+        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
+        {
+            // expected on shutdown
+        }
```

Also extend `StopAsync` so the registry is disposed inside the host's shutdown grace period (Fix 13):

```csharp
public override async Task StopAsync(CancellationToken cancellationToken)
{
    await _rulesWatcher.StopAsync(cancellationToken);
    await _monitor.StopAsync(cancellationToken);
    await _dirWatcher.StopAsync(cancellationToken);

    // Drain shards before the DI container disposes them, so the 5 s/shard
    // budget (STR-008) is enforced inside StopAsync rather than in container teardown.
    if (_shards is IAsyncDisposable disposableRegistry)
    {
        await disposableRegistry.DisposeAsync();
    }

    await base.StopAsync(cancellationToken);
}
```

---

## Fix 4 — `EventRecorder.RecordAsync` writes the wrong column (Critical)

In `code-scaffolding.md` §4.7, replace the P1 branch:

```diff
-        if (e.Priority == MonitorPriority.P1 && e.Raw.ChangeType != FileChangeType.Deleted)
-        {
-            var prior = await repo.GetLastP1ContentAsync(e.Raw.FullPath, ct);
-            var newContent = await File.ReadAllTextAsync(e.Raw.FullPath, ct);
-            oldContent = newContent;
-            diffText = _diff.BuildUnified(prior ?? string.Empty, newContent);
-        }
+        string? newContent = null;
+        if (e.Priority == MonitorPriority.P1 && e.Raw.ChangeType != FileChangeType.Deleted)
+        {
+            // REC-001: old_content = snapshot before change; we look it up from the
+            //          previous audit_log row (or the file_baselines side-table if
+            //          we adopt that change in a later schema rev).
+            oldContent = await repo.GetLastP1ContentAsync(e.Raw.FullPath, ct);
+            newContent = await File.ReadAllTextAsync(e.Raw.FullPath, ct);
+            diffText   = _diff.BuildUnified(oldContent ?? string.Empty, newContent);
+        }
```

In `schema-design.md` §5, delete the misleading "Note on old" paragraph (lines 175–177) and replace with:

```markdown
> **`old_content` semantics (REC-001)**: this column stores the *prior* full
> file content as recorded by the immediately preceding P1 audit row for the
> same `filepath`. On the first P1 event for a file (no prior row), the
> column is NULL and `diff_text` is generated against an empty string.
```

Add a corresponding test to `test-plan.md` §4.4:

```markdown
| REC-001 | `Recorder_P1_OldContentIsPriorVersion` (Unit) | Insert P1 row for content "v1"; modify file to "v2"; second row's `old_content == "v1"`, `diff_text` shows v1 → v2. |
```

---

## Fix 5 — `ShardRegistryRw.GetOrCreateAsync` race + leak (Critical)

In `code-scaffolding.md` §4.6, replace the dictionary value type with a `Lazy<Task<ShardHandle>>` so the factory runs at most once per key:

```csharp
internal sealed class ShardRegistryRw : IShardRegistry, IAsyncDisposable
{
    private readonly ConcurrentDictionary<string, Lazy<Task<ShardHandle>>> _shards =
        new(StringComparer.OrdinalIgnoreCase);
    // ... unchanged dependencies ...

    public async Task RouteAsync(ClassifiedEvent e)
    {
        var handle = await GetOrCreateAsync(e.ShardKey).ConfigureAwait(false);
        await handle.Channel.Writer.WriteAsync(e).ConfigureAwait(false);
    }

    public Task<ShardHandle> GetOrCreateAsync(string shardKey)
    {
        var lazy = _shards.GetOrAdd(shardKey,
            key => new Lazy<Task<ShardHandle>>(() => CreateHandleAsync(key)));
        return lazy.Value;
    }

    private async Task<ShardHandle> CreateHandleAsync(string shardKey)
    {
        var dbPath = ResolveDbPath(shardKey);
        var repo = _repoFactory.OpenReadWrite(dbPath);
        try
        {
            await _migrator.EnsureSchemaAsync(repo.Connection, default).ConfigureAwait(false);
            var ch = Channel.CreateBounded<ClassifiedEvent>(_cfg.CurrentValue.ShardChannelCapacity);
            var sem = new SemaphoreSlim(1, 1);
            var cts = new CancellationTokenSource();
            var writer = Task.Run(() => WriterLoopAsync(shardKey, repo, ch, sem, cts.Token));
            return new ShardHandle(shardKey, dbPath, repo, ch, sem, writer, cts);
        }
        catch
        {
            await repo.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    public async Task RemoveAsync(string shardKey)
    {
        if (_shards.TryRemove(shardKey, out var lazy) && lazy.IsValueCreated)
        {
            try { await (await lazy.Value).DisposeAsync().ConfigureAwait(false); }
            catch (Exception ex) { _log.LogError(ex, "Shard dispose failed {Shard}", shardKey); }
        }
    }

    public async ValueTask DisposeAsync()
    {
        var handles = _shards.Values
            .Where(l => l.IsValueCreated)
            .Select(l => l.Value);
        var tasks = handles.Select(async t =>
        {
            try { await (await t).DisposeAsync(); } catch { /* logged inside */ }
        });
        await Task.WhenAll(tasks);
    }
}
```

This guarantees one `CreateHandleAsync` call per shard key, never leaks the loser's repo, and disposes the SemaphoreSlim/CTS cleanly via `ShardHandle.DisposeAsync`.

Add test to `test-plan.md` §4.5:

```markdown
| STR-007 | `ShardRegistry_GetOrCreate_RacesProduceOneHandle` (Worker) | 100 concurrent calls for the same job name yield exactly one repository instance and one writer Task. |
```

---

## Fix 6 — Manifest event-count increment (High, MFT-007)

In `code-scaffolding.md` §4.7, after the successful insert, call the manifest manager:

```diff
         await repo.InsertEventAsync(row, ct);
+        // MFT-007: count the row against the current machine's history entry.
+        var jobFolder = ResolveJobFolder(e.ShardKey);
+        if (jobFolder is not null)
+            await _manifest.IncrementEventCountAsync(jobFolder, Environment.MachineName, ct);
         if (sha is not null)
             await repo.UpsertBaselineAsync(e.Raw.FullPath, sha, _clock.UtcNow, ct);
```

Inject `IManifestManager` into `EventRecorder`'s constructor. Implement `ResolveJobFolder` either via the `ShardKey → folder` map maintained by `ShardRegistry` or by passing the folder path through `ClassifiedEvent`. The latter is cleaner; extend `ClassifiedEvent` with `string JobFolder` and populate it in `FileClassifier.Classify`.

Add `ManifestManager.IncrementEventCountAsync` body (currently only a signature):

```csharp
public async Task IncrementEventCountAsync(string jobFolder, string machineName, CancellationToken ct)
{
    var current = await ReadAsync(jobFolder, ct).ConfigureAwait(false);
    if (current is null) return; // arrival should have created it; defensive
    var updated = IncrementActiveEntry(current, machineName);
    var path = Path.Combine(jobFolder, ".audit", "manifest.json");
    await WriteAtomicAsync(path, updated, ct).ConfigureAwait(false);
}
```

Note: under high event rates this rewrites `manifest.json` per row. Batch by accumulating in memory and flushing every N events or every T seconds; document the trade-off and add `manifest_flush_interval_ms` to `MonitorConfig` (default 1000).

---

## Fix 7 — Path validator order + drive-letter rejection (High)

In `api-design.md` §10.2 replace `IsSafe`:

```diff
-public bool IsSafe(string relFilepath)
-    => relFilepath.Length is > 0 and <= 260
-       && _allowedRegex.IsMatch(relFilepath)
-       && !relFilepath.Contains("..", StringComparison.Ordinal)
-       && !Path.IsPathRooted(relFilepath);
+public bool IsSafe(string relFilepath)
+{
+    if (string.IsNullOrEmpty(relFilepath)) return false;
+    if (relFilepath.Length > 260) return false;
+    // Reject anything that looks rooted before any other check.
+    if (Path.IsPathRooted(relFilepath)) return false;
+    if (relFilepath[0] is '\\' or '/') return false;     // leading separator
+    if (relFilepath.Contains("..", StringComparison.Ordinal)) return false;
+    if (relFilepath.Contains(':')) return false;          // drive letters / NTFS streams
+    return _allowedRegex.IsMatch(relFilepath);
+}
```

Apply the same checks to `RelFilepathConstraint.Match` in `code-scaffolding.md` §6.4 so route-level rejection is in lockstep with controller-level rejection. Add tests:

```markdown
| API-008 | `History_RejectsLeadingBackslash`     (Unit) | `\\Windows\\System32\\foo` → 400 |
| API-008 | `History_RejectsDriveLetter`          (Unit) | `C:\\foo`                       → 400 |
| API-008 | `History_RejectsAdsStream`            (Unit) | `foo.txt:hidden`                → 400 |
```

---

## Fix 8 — `EventQueryFilter` model binding (High)

In `api-design.md` §4.2 replace the filter type with one that uses public setters or constructor binding:

```csharp
public sealed class EventQueryFilter
{
    [FromQuery(Name = "module")]    public string? Module    { get; set; }
    [FromQuery(Name = "priority")]  public string? Priority  { get; set; }
    [FromQuery(Name = "service")]   public string? Service   { get; set; }
    [FromQuery(Name = "eventType")] public string? EventType { get; set; }
    [FromQuery(Name = "from")]      public DateTimeOffset? From { get; set; }
    [FromQuery(Name = "to")]        public DateTimeOffset? To   { get; set; }
    [FromQuery(Name = "machine")]   public string? Machine   { get; set; }
    [FromQuery(Name = "path")]      public string? Path      { get; set; }

    [FromQuery(Name = "page")]      public int Page     { get; set; } = 1;
    [FromQuery(Name = "pageSize")]  public int PageSize { get; set; } = 50;
}
```

(`init` → `set`. ASP.NET Core 6 model binder uses public set accessors; `init` is treated as no-setter for binding purposes.)

---

## Fix 9 — `JobDiscoveryService.RefreshAsync` (High)

In `code-scaffolding.md` §6.5 replace the body:

```csharp
public Task RefreshAsync(CancellationToken ct = default)
{
    ct.ThrowIfCancellationRequested();
    var roots = Directory.EnumerateDirectories(_cfg.WatchPath).ToArray();
    var b = ImmutableDictionary.CreateBuilder<string, ShardLocation>(StringComparer.OrdinalIgnoreCase);
    foreach (var dir in roots)
    {
        ct.ThrowIfCancellationRequested();
        var name = Path.GetFileName(dir);
        if (string.IsNullOrEmpty(name) || name == "__global__") continue;
        var db = Path.Combine(dir, ".audit", "audit.db");
        if (File.Exists(db)) b[name] = new ShardLocation(name, db, dir);
    }
    b["__global__"] = new ShardLocation("__global__", _cfg.GlobalDbPath, _cfg.WatchPath);
    Interlocked.Exchange(ref _snapshot, b.ToImmutable());
    return Task.CompletedTask;
}
```

Drop the `async` modifier (no `await`). Also, in `JobDiscoveryHostedService.ExecuteAsync`, wrap each iteration:

```csharp
while (await timer.WaitForNextTickAsync(ct))
{
    try { await _disc.RefreshAsync(ct); }
    catch (OperationCanceledException) { throw; }
    catch (Exception ex) { _log.LogError(ex, "Job discovery refresh failed"); }
}
```

---

## Fix 10 — PRAGMA application (re-classified to Low after re-verification)

The original concern about multi-statement PRAGMAs in a single `ExecuteNonQuery` was incorrect; `Microsoft.Data.Sqlite` 6.x does iterate over `;`-separated statements. No code change. Add a small integration test to lock this in:

```markdown
| STR-003/STR-004 | `Repo_AllPragmasApplied` (Integration) | After open, query `PRAGMA journal_mode`, `synchronous`, `temp_store`, `cache_size`, `busy_timeout`; all must equal expected values. |
```

---

## Fix 11 — `SchemaMigrator` race (High)

In `code-scaffolding.md` §5.2 wrap the read-version + apply in a single `BEGIN IMMEDIATE`:

```csharp
public async Task EnsureSchemaAsync(SqliteConnection conn, CancellationToken ct)
{
    await using var tx = (SqliteTransaction)await conn.BeginTransactionAsync(deferred: false, ct).ConfigureAwait(false);
    var current = await GetVersionAsync(conn, tx, ct).ConfigureAwait(false);
    if (current == TargetVersion) { await tx.RollbackAsync(ct); return; }
    if (current >  TargetVersion) throw new SchemaTooNewException(current, TargetVersion);

    await using (var cmd = conn.CreateCommand())
    {
        cmd.Transaction = tx;
        cmd.CommandText = V1Sql;
        await cmd.ExecuteNonQueryAsync(ct);
    }
    await using (var cmd = conn.CreateCommand())
    {
        cmd.Transaction = tx;
        cmd.CommandText = $"PRAGMA user_version = {TargetVersion};";
        await cmd.ExecuteNonQueryAsync(ct);
    }
    await tx.CommitAsync(ct);
}
```

`BeginTransactionAsync(deferred: false)` issues `BEGIN IMMEDIATE`, which acquires a RESERVED lock — concurrent migrators block until the first commits and then see `user_version == 1`.

---

## Fix 12 — `MonitorConfig` snake_case binding (High)

Two options. Pick one and apply consistently.

**Option A — match POCO names to JSON (least code, requires JSON change)**:

In `code-scaffolding.md` §9 change `appsettings.json`:

```json
{
  "monitor_config": {
    "WatchPath":                 "c:\\job\\",
    "GlobalDbPath":              "C:\\bis\\auditlog\\global.db",
    "ClassificationRulesPath":   "C:\\bis\\auditlog\\FileClassificationRules.json",
    "ApiPort":                   5100,
    "DebounceMs":                500,
    "CatchUpYieldThreshold":     50,
    "ShardChannelCapacity":      1024,
    "JobDiscoveryIntervalSeconds": 30
  }
}
```

This contradicts INS-003's lowercase keys, so **option A is not acceptable** unless INS-003 is amended.

**Option B — explicit binding (preferred)**:

Replace `s.Configure<MonitorConfig>(ctx.Configuration.GetSection("monitor_config"));` with:

```csharp
s.AddOptions<MonitorConfig>().Configure<IConfiguration>((opt, cfg) =>
{
    var section = cfg.GetSection("monitor_config");
    opt.WatchPath               = section["watch_path"]                   ?? opt.WatchPath;
    opt.GlobalDbPath            = section["global_db_path"]               ?? opt.GlobalDbPath;
    opt.ClassificationRulesPath = section["classification_rules_path"]    ?? opt.ClassificationRulesPath;
    opt.ApiPort                 = section.GetValue("api_port",                opt.ApiPort);
    opt.DebounceMs              = section.GetValue("debounce_ms",            opt.DebounceMs);
    opt.CatchUpYieldThreshold   = section.GetValue("catch_up_yield_threshold", opt.CatchUpYieldThreshold);
    opt.ShardChannelCapacity    = section.GetValue("shard_channel_capacity",   opt.ShardChannelCapacity);
    opt.JobDiscoveryIntervalSeconds = section.GetValue("job_discovery_interval_seconds", opt.JobDiscoveryIntervalSeconds);
});
```

Apply in both `Program.cs` files (worker and query, or the merged single-process one if Fix 1 option B is taken).

---

## Fix 13 — Subsumed into Fix 3 above

Already addressed in Fix 3 (`StopAsync` calls `_shards.DisposeAsync()` explicitly).

---

## Fix 14 — `CatchUpCoordinator.RunAllAsync` cancellation + null-safety (High)

In `code-scaffolding.md` §4.9 replace:

```csharp
public async Task RunAllAsync(CancellationToken ct)
{
    var jobs = Directory.EnumerateDirectories(_cfg.CurrentValue.WatchPath)
        .Select(Path.GetFileName)
        .Where(n => !string.IsNullOrEmpty(n) && n != "__global__")
        .ToArray();
    var options = new ParallelOptions { CancellationToken = ct, MaxDegreeOfParallelism = Environment.ProcessorCount };
    await Parallel.ForEachAsync(jobs!, options, async (job, c) =>
    {
        try { await ScheduleAsync(job!, c).ConfigureAwait(false); }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex) { _log.LogError(ex, "Catch-up failed for job {Job}", job); }
    });
}
```

The per-job try/catch is required by SVC-006 ("recover from unhandled exception … shall not terminate the process").

---

## Fix 15 — Catch-up scanner correctness (High)

Replace `CatchUpScanner.RunAsync` in `code-scaffolding.md` §4.9 with:

```csharp
internal sealed class CatchUpScanner : ICatchUpScanner
{
    public async Task RunAsync(CancellationToken ct)
    {
        var handle = await _shards.GetOrCreateAsync(_jobName).ConfigureAwait(false);

        // Pass 1: enumerate on-disk files; emit Created or Modified.
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var file in Directory.EnumerateFiles(handle.JobFolder, "*", SearchOption.AllDirectories))
        {
            ct.ThrowIfCancellationRequested();
            seen.Add(file);

            var prior = await handle.Repo.GetLastHashAsync(file, ct).ConfigureAwait(false);
            var sha   = await _hash.ComputeAsync(file, 3, 100, ct).ConfigureAwait(false);
            if (prior is null)
            {
                var raw = new RawFsEvent(file, FileChangeType.Created, _clock.UtcNow);
                var classified = _classifier.Classify(raw, _cfg.CurrentValue.WatchPath);
                if (classified is not null) await handle.Channel.Writer.WriteAsync(classified, ct).ConfigureAwait(false);
            }
            else if (!string.Equals(prior, sha, StringComparison.OrdinalIgnoreCase))
            {
                var raw = new RawFsEvent(file, FileChangeType.Modified, _clock.UtcNow);
                var classified = _classifier.Classify(raw, _cfg.CurrentValue.WatchPath);
                if (classified is not null) await handle.Channel.Writer.WriteAsync(classified, ct).ConfigureAwait(false);
            }

            if (handle.Channel.Reader.Count > _cfg.CurrentValue.CatchUpYieldThreshold) await Task.Yield();
        }

        // Pass 2: emit Deleted events for baseline rows whose files are gone (CUS-004).
        await foreach (var (path, _) in handle.Repo.EnumerateBaselinesAsync(ct).WithCancellation(ct))
        {
            if (seen.Contains(path)) continue;
            var raw = new RawFsEvent(path, FileChangeType.Deleted, _clock.UtcNow);
            var classified = _classifier.Classify(raw, _cfg.CurrentValue.WatchPath);
            if (classified is not null) await handle.Channel.Writer.WriteAsync(classified, ct).ConfigureAwait(false);
        }
    }
}
```

Add `EnumerateBaselinesAsync` to `ISqliteRepository`:

```csharp
IAsyncEnumerable<(string Filepath, string LastHash)> EnumerateBaselinesAsync(CancellationToken ct);
```

The `EventRecorder` should also remove the baseline row on `FileChangeType.Deleted` (CUS-004 mandates baseline removal on missing file):

```csharp
if (e.Raw.ChangeType == FileChangeType.Deleted)
    await repo.DeleteBaselineAsync(e.Raw.FullPath, ct);
```

Add tests for CUS-001..CUS-004 (already in test plan).

---

## Fix 16 — Date filter format (High)

In `code-scaffolding.md` §6.3 replace the From/To bindings:

```diff
-if (f.From.HasValue) { sb.Append(sb.Length>0?" AND ":"").Append("changed_at >= @from"); p.Add(new("@from", f.From.Value.UtcDateTime.ToString("O"))); }
-if (f.To.HasValue)   { sb.Append(sb.Length>0?" AND ":"").Append("changed_at <  @to");   p.Add(new("@to",   f.To.Value.UtcDateTime.ToString("O"))); }
+if (f.From.HasValue) { sb.Append(sb.Length>0?" AND ":"").Append("changed_at >= @from"); p.Add(new("@from", FormatUtcZ(f.From.Value))); }
+if (f.To.HasValue)   { sb.Append(sb.Length>0?" AND ":"").Append("changed_at <  @to");   p.Add(new("@to",   FormatUtcZ(f.To.Value))); }
```

Add helper:

```csharp
private static string FormatUtcZ(DateTimeOffset dto)
    => dto.ToUniversalTime().UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ", CultureInfo.InvariantCulture);
```

Also update `EventRecorder.RecordAsync` and `SqliteRepository.UpsertBaselineAsync` / `InsertEventAsync` to use `FormatUtcZ` rather than `.UtcDateTime.ToString("O")`. Place `FormatUtcZ` in a shared `TimestampFormatter` static class in `FalconAuditService.Core.Models`.

---

## Fix 17 — Query process classifier wiring (High)

If Fix 1 option B (single process) is chosen, this is moot — the rules and classifier live in the same process and `RulesFileWatcher` runs once. If option A (multi-process) is chosen:

- Keep `IClassificationRulesLoader` + `IFileClassifier` in the query DI.
- Add a `ClassifierBootstrap : BackgroundService` to the query that calls `LoadAsync` once at startup and listens for changes via its **own** `RulesFileWatcher`. The two watchers (worker + query) on the same JSON file work correctly because they only read.

Recommended: under option B this fix collapses to "delete the duplicate registration".

---

## Fix 18 — `Cache=Shared` → `Cache=Private` for readers (Medium)

In `api-design.md` §9 and `code-scaffolding.md` §5.1, change reader connection strings:

```diff
 var cs = new SqliteConnectionStringBuilder
 {
     DataSource = path,
     Mode       = SqliteOpenMode.ReadOnly,
-    Cache      = SqliteCacheMode.Shared,
+    Cache      = SqliteCacheMode.Private,
     DefaultTimeout = 5,
 }.ToString();
```

Keep `Cache=Shared` for writer connections only if measurements show benefit; current writer code uses Shared too — switch both to Private for clarity and equal latency on Kestrel threads. Add a perf test (`Perf_ConcurrentReaders_Cache_Comparison`) in nightly.

---

## Fix 19 — Map `/error` for `UseExceptionHandler` (Medium)

In `code-scaffolding.md` §6.1 (`Program.cs`) replace:

```diff
-app.UseExceptionHandler("/error");
+app.UseExceptionHandler(errorApp =>
+{
+    errorApp.Run(async ctx =>
+    {
+        var feature = ctx.Features.Get<IExceptionHandlerFeature>();
+        var pd = new ProblemDetails
+        {
+            Status = StatusCodes.Status500InternalServerError,
+            Title  = "Internal error",
+            Type   = "https://falconaudit/errors/internal",
+            Detail = ctx.RequestServices
+                .GetRequiredService<IHostEnvironment>()
+                .IsDevelopment() ? feature?.Error.ToString() : null,
+        };
+        ctx.Response.StatusCode = pd.Status.Value;
+        ctx.Response.ContentType = "application/problem+json";
+        await JsonSerializer.SerializeAsync(ctx.Response.Body, pd);
+    });
+});
```

---

## Fix 20 — `Volatile.Read` on snapshot (Medium)

In `code-scaffolding.md` §6.5:

```diff
-private ImmutableDictionary<string, ShardLocation> _snapshot = ImmutableDictionary<string, ShardLocation>.Empty;
-public IReadOnlyDictionary<string, ShardLocation> Snapshot => _snapshot;
+private ImmutableDictionary<string, ShardLocation> _snapshot = ImmutableDictionary<string, ShardLocation>.Empty;
+public IReadOnlyDictionary<string, ShardLocation> Snapshot => Volatile.Read(ref _snapshot);
```

---

## Fix 21 — Explicit `BEGIN DEFERRED` for snapshot consistency (Medium)

In `code-scaffolding.md` §6.2 inside `Events`, before issuing count + page:

```csharp
await using var tx = await rdr.Connection.BeginTransactionAsync(System.Data.IsolationLevel.ReadCommitted, ct);
// run COUNT then page on this tx
await tx.CommitAsync(ct); // releases the snapshot
```

`Microsoft.Data.Sqlite` 6 honours `IsolationLevel.ReadCommitted` by issuing `BEGIN DEFERRED`, which on a WAL reader pins the snapshot at the first read.

Document this in `api-design.md` §5 alongside `X-Total-Count` consistency.

---

## Fix 22 — Global `Cache-Control: no-store` (Medium)

Add a tiny middleware in `code-scaffolding.md` §6.1 right after `app.MapControllers()`:

```csharp
app.Use(async (ctx, next) =>
{
    ctx.Response.OnStarting(() =>
    {
        ctx.Response.Headers["Cache-Control"] = "no-store";
        return Task.CompletedTask;
    });
    await next();
});
```

Remove the per-endpoint `Cache-Control` line from `Events` since it is now applied uniformly.

---

## Fix 23 — Add `IHashService` interface (Medium)

In `code-scaffolding.md` §3 add:

```csharp
public interface IHashService
{
    Task<string> ComputeAsync(string filepath, int retries, int retryDelayMs, CancellationToken ct);
}
```

Implementation skeleton in `FalconAuditWorker/Recording/HashService.cs`:

```csharp
internal sealed class HashService : IHashService
{
    private readonly ILogger<HashService> _log;
    public async Task<string> ComputeAsync(string filepath, int retries, int retryDelayMs, CancellationToken ct)
    {
        for (var attempt = 1; attempt <= retries; attempt++)
        {
            try
            {
                await using var fs = new FileStream(filepath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite, 4096, useAsync: true);
                using var sha = SHA256.Create();
                var hash = await sha.ComputeHashAsync(fs, ct).ConfigureAwait(false);
                return Convert.ToHexString(hash).ToLowerInvariant();
            }
            catch (IOException) when (attempt < retries)
            {
                await Task.Delay(retryDelayMs, ct).ConfigureAwait(false);
            }
        }
        throw new IOException($"Failed to hash {filepath} after {retries} attempts.");
    }
}
```

---

## Fix 24 — `install.ps1` completeness (Medium)

Replace `code-scaffolding.md` §10:

```powershell
param(
    [string]$BinDir = "C:\bis\FalconAudit",
    [string]$ConfigDir = "C:\bis\auditlog",
    [string]$ServiceAccount = "LocalSystem"
)

$ErrorActionPreference = "Stop"

# Require Administrator
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "install.ps1 must run as Administrator."
    exit 1
}

# Create folders
New-Item -ItemType Directory -Force -Path "$ConfigDir\logs" | Out-Null

# Seed default rules file (INS-001)
$defaultRules = Join-Path $BinDir "FileClassificationRules.default.json"
$targetRules  = Join-Path $ConfigDir "FileClassificationRules.json"
if (-not (Test-Path $targetRules) -and (Test-Path $defaultRules)) {
    Copy-Item $defaultRules $targetRules
}

# ACLs: LocalSystem write, Administrators read
icacls "$ConfigDir" /grant "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)R" /T | Out-Null

# Register Event Log source BEFORE service start (manageEventSource: false at runtime)
if (-not [System.Diagnostics.EventLog]::SourceExists("FalconAuditService")) {
    New-EventLog -LogName Application -Source "FalconAuditService"
}

# Install service (single-process per Fix 1 option B)
sc.exe create FalconAuditService binPath= "$BinDir\FalconAuditService.exe" start= auto DisplayName= "Falcon Audit Service" obj= $ServiceAccount
sc.exe failure FalconAuditService reset= 60 actions= restart/5000/restart/5000/restart/15000
sc.exe description FalconAuditService "Tamper-evident audit log of Falcon job folder changes."

sc.exe start FalconAuditService
```

If multi-process is retained (Fix 1 option A), keep both `sc.exe create` lines and the `Depend=` flag.

---

## Fix 25 — Event Log source pre-creation (Medium)

Subsumed by Fix 24's `New-EventLog` call before service start. Add a `[Trait("type","integration")]` test that asserts the source exists after `install.ps1` runs (`Get-EventLog -List | ? { $_.Source -contains "FalconAuditService" }`).

---

## Fix 26 — Serilog config in `appsettings.json` (Medium)

Replace the `Serilog` block in `code-scaffolding.md` §9:

```json
"Serilog": {
  "Using": [ "Serilog.Sinks.File", "Serilog.Sinks.EventLog" ],
  "MinimumLevel": {
    "Default":  "Information",
    "Override": { "Microsoft": "Warning", "Microsoft.Hosting.Lifetime": "Information" }
  },
  "WriteTo": [
    {
      "Name": "File",
      "Args": {
        "path": "C:\\bis\\auditlog\\logs\\falcon-.log",
        "rollingInterval": "Day",
        "retainedFileCountLimit": 14,
        "fileSizeLimitBytes": 52428800,
        "rollOnFileSizeLimit": true,
        "outputTemplate": "{Timestamp:o} {Level:u3} [{SourceContext}] {Message:lj} {Properties:j}{NewLine}{Exception}"
      }
    },
    {
      "Name": "EventLog",
      "Args": { "source": "FalconAuditService", "logName": "Application", "manageEventSource": false }
    }
  ]
}
```

In `Program.cs` use `Host.UseSerilog((ctx, lc) => lc.ReadFrom.Configuration(ctx.Configuration))`. Now log destinations and retention can be tuned via `appsettings.json` without recompiling (satisfying INS-004 for runtime-tunable logging).

---

## Fix 27 — Single shared `appsettings.json` (Medium)

If multi-process retained, add a `--config` argument to both `Program.cs` invocations and store one shared file under `C:\bis\FalconAudit\appsettings.json`:

```csharp
Host.CreateDefaultBuilder(args)
    .ConfigureAppConfiguration((ctx, c) =>
    {
        c.SetBasePath(@"C:\bis\FalconAudit");
        c.AddJsonFile("appsettings.json", optional: false, reloadOnChange: true);
    })
```

Document in `design-package-summary.md`. If single-process (Fix 1 option B), this fix is unnecessary.

---

## Fix 28 — `RulesFileWatcher` debounce (Medium)

Add to `code-scaffolding.md` (new section under §4):

```csharp
internal sealed class RulesFileWatcher : IRulesFileWatcher, IAsyncDisposable
{
    private readonly IClassificationRulesLoader _loader;
    private readonly IFileClassifier _classifier;
    private readonly IOptionsMonitor<MonitorConfig> _cfg;
    private readonly ILogger<RulesFileWatcher> _log;
    private FileSystemWatcher? _fsw;
    private CancellationTokenSource? _debounceCts;
    private const int DebounceMs = 200;

    public Task StartAsync(CancellationToken ct)
    {
        var path = _cfg.CurrentValue.ClassificationRulesPath;
        var dir = Path.GetDirectoryName(path)!;
        var file = Path.GetFileName(path);
        _fsw = new FileSystemWatcher(dir, file)
        {
            NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.FileName | NotifyFilters.Size,
            EnableRaisingEvents = true,
        };
        _fsw.Changed += (_, __) => DebouncedReload(path);
        _fsw.Created += (_, __) => DebouncedReload(path);
        _fsw.Renamed += (_, __) => DebouncedReload(path);
        return Task.CompletedTask;
    }

    private void DebouncedReload(string path)
    {
        var newCts = new CancellationTokenSource();
        var oldCts = Interlocked.Exchange(ref _debounceCts, newCts);
        oldCts?.Cancel();
        oldCts?.Dispose();
        _ = Task.Delay(DebounceMs, newCts.Token).ContinueWith(async t =>
        {
            if (t.IsCanceled) return;
            try
            {
                var rules = await _loader.LoadAsync(path, CancellationToken.None);
                _classifier.SetRules(rules);
                _log.LogInformation("Rules hot-reloaded: {Count} rules", rules.Count);
            }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "Rules reload failed; keeping previous rules");
            }
        }, TaskScheduler.Default);
    }

    public Task StopAsync(CancellationToken ct)
    {
        if (_fsw is not null) { _fsw.EnableRaisingEvents = false; _fsw.Dispose(); _fsw = null; }
        return Task.CompletedTask;
    }

    public ValueTask DisposeAsync() { _fsw?.Dispose(); _debounceCts?.Dispose(); return ValueTask.CompletedTask; }
}
```

---

## Fix 29 — `EventDebouncer` CTS leak (Medium)

In `code-scaffolding.md` §4.4 replace `Schedule`:

```csharp
public void Schedule(string path, Action onFire)
{
    var newCts = new CancellationTokenSource();
    CancellationTokenSource? oldCts = null;
    _pending.AddOrUpdate(path, newCts, (_, prev) => { oldCts = prev; return newCts; });
    oldCts?.Cancel();
    oldCts?.Dispose();
    _ = Task.Delay(_cfg.CurrentValue.DebounceMs, newCts.Token).ContinueWith(t =>
    {
        if (t.IsCanceled) { newCts.Dispose(); return; }
        if (_pending.TryRemove(new KeyValuePair<string, CancellationTokenSource>(path, newCts)))
            newCts.Dispose();
        try { onFire(); } catch { /* logged elsewhere */ }
    }, TaskScheduler.Default);
}
```

---

## Fix 30 — Channel capacity vs yield threshold (Medium)

In `code-scaffolding.md` §2.1 reduce `ShardChannelCapacity` default to 256 and raise `CatchUpYieldThreshold` to 64. Re-verify in `Perf_CatchUp_10Jobs150Files_Under5s`.

```diff
-public int    ShardChannelCapacity { get; init; } = 1024;
-public int    CatchUpYieldThreshold { get; init; } = 50;
+public int    ShardChannelCapacity { get; init; } = 256;
+public int    CatchUpYieldThreshold { get; init; } = 64;
```

---

## Fix 31 — Drop `AUTOINCREMENT` (Medium)

In `schema-design.md` §4 DDL:

```diff
-    id               INTEGER PRIMARY KEY AUTOINCREMENT,
+    id               INTEGER PRIMARY KEY,
```

`INTEGER PRIMARY KEY` aliases the rowid; ids are still strictly increasing for new inserts (they only "reuse" when rows are deleted, which the audit log never does).

---

## Fix 32 — Writer-side SQL retry (Medium)

In `code-scaffolding.md` §4.6 wrap the `EventRecorder.RecordAsync` call inside `WriterLoopAsync`:

```csharp
await foreach (var e in ch.Reader.ReadAllAsync(ct))
{
    await sem.WaitAsync(ct);
    try
    {
        await RetryOnBusyAsync(() => _recorder.RecordAsync(e, repo, ct), retries: 3, delayMs: 100, ct);
    }
    catch (Exception ex) { _log.LogError(ex, "Record failed shard={Shard}", shardKey); }
    finally { sem.Release(); }
}

private static async Task RetryOnBusyAsync(Func<Task> op, int retries, int delayMs, CancellationToken ct)
{
    for (var attempt = 1; ; attempt++)
    {
        try { await op(); return; }
        catch (SqliteException ex) when (ex.SqliteErrorCode is 5 /*BUSY*/ or 6 /*LOCKED*/ && attempt < retries)
        {
            await Task.Delay(delayMs, ct);
        }
    }
}
```

---

## Fix 33 — Test plan ID typos (Low)

In `test-plan.md` §4.4:

```diff
-| REC-003 | `Recorder_RetriesOnIOException` (Unit) | First two reads throw `IOException`; third succeeds; row written. |
-| REC-004 | `Recorder_GivesUpAfter3Retries` (Unit) | All retries fail; no row written; baseline not advanced. |
+| REC-009 | `Recorder_RetriesOnIOException` (Unit) | First two reads throw `IOException`; third succeeds; row written. |
+| REC-009 | `Recorder_GivesUpAfter3Retries` (Unit) | All retries fail; no row written; baseline not advanced. |
```

The previous `REC-003` is already covered by `Recorder_P4LogsAndSkips` (REC-003 in the requirements is the P4-no-row rule).

---

## Fix 34 — Reserve `__global__` job name (Low)

In `code-scaffolding.md` §4.8 `JobLifecycleHandler.OnArrivalAsync` add at top:

```csharp
if (string.Equals(jobName, "__global__", StringComparison.OrdinalIgnoreCase))
{
    _log.LogWarning("Reserved job name '__global__' detected on disk; ignoring arrival.");
    return;
}
```

Ditto in `JobDiscoveryService.RefreshAsync` (already added in Fix 9 above).

---

## Fix 35 — Manifest read-modify-write atomicity (Low)

Two options:

1. **In-process lock** (sufficient because only one writer per machine): add a `SemaphoreSlim` keyed by job folder inside `ManifestManager`:

   ```csharp
   private static readonly ConcurrentDictionary<string, SemaphoreSlim> _locks =
       new(StringComparer.OrdinalIgnoreCase);

   private static SemaphoreSlim LockFor(string jobFolder)
       => _locks.GetOrAdd(jobFolder, _ => new SemaphoreSlim(1, 1));

   public async Task RecordArrivalAsync(string jobFolder, ...)
   {
       var gate = LockFor(jobFolder);
       await gate.WaitAsync(ct);
       try { /* existing read+merge+write logic */ }
       finally { gate.Release(); }
   }
   ```

2. **Cross-machine lock**: out of scope; per ERS-FAU-001 a job folder is owned by one machine at a time.

Apply option 1.

---

## Fix 36 — `__global__` shard sanity check (Low)

In `JobDiscoveryService.RefreshAsync`:

```csharp
if (!File.Exists(_cfg.GlobalDbPath))
{
    _log.LogWarning("Global DB not found at {Path}; /api/global/events will return 503 until created", _cfg.GlobalDbPath);
}
b["__global__"] = new ShardLocation("__global__", _cfg.GlobalDbPath, _cfg.WatchPath);
```

In `ShardReaderFactory.OpenAsync`, if `Mode=ReadOnly` open fails (file missing), throw `ShardUnavailableException` and let the controller return 503 with `https://falconaudit/errors/shard-unavailable` (already in the error model).

---

## Fix 37 — Performance budget arithmetic (Low)

In `api-design.md` §11 fix the table totals:

```diff
-| **Total** | **~150 ms** | leaves ~50 ms slack |
+| **Total** | **~147 ms** | leaves ~53 ms slack against 200 ms PERF-005 |
```

Document that this is a design estimate; actual measurement is performed by `Perf_EventsList_50Rows_Under200ms`.

---

## Fix 38 — `ManifestDto.History` allocation (Low)

In `code-scaffolding.md` §7 replace the assembly of `updated`:

```csharp
var historyList = (existing?.History ?? Array.Empty<MachineHistoryDto>()).ToList();
historyList.Add(new MachineHistoryDto(machineName, at, null, 0));
var updated = (existing ?? new ManifestDto(...)) with { History = historyList };
```

This makes the allocation and ownership explicit. Alternatively, change `ManifestDto.History` to `IReadOnlyCollection<MachineHistoryDto>` and use `ImmutableList<MachineHistoryDto>` internally.

---

## Apply order checklist

1. Fixes 1, 2, 3, 4, 5, 11, 13 (Critical / shutdown / data-correctness path).
2. Fixes 6, 7, 8, 9, 12, 14, 15, 16, 17 (High).
3. Fixes 18–32 (Medium).
4. Fixes 33–38 (Low).

Run `dotnet build` after each batch; the test plan additions accompany Fixes 4, 5, 7, 10, 15.

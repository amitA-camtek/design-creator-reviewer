# FalconAuditService — Architecture Design

**Document ID:** ARC-FAU-001
**Date:** 2026-04-26
**Approved alternative:** Alternative 1 — Lazy-Open Channel Pipeline with Offset Pagination
**Requirements basis:** ERS-FAU-001 (62 requirements)

---

## 1. Process and host model

The service is a single Windows process registered as `FalconAuditService` with auto-start (SVC-001, INS-001). The process root is a `BackgroundService` named `FalconAuditWorker` that hosts the entire pipeline. The same process also hosts an ASP.NET Core minimal API on Kestrel for read-only queries (API-001).

```
+--------------------------------------------+
|         FalconAuditService process          |
|                                             |
|   +-----------------------------------+    |
|   |  FalconAuditWorker (BackgroundSvc)|    |
|   |   - Composition root              |    |
|   |   - Startup ordering (SVC-003)    |    |
|   +-----------+-----------+-----------+    |
|               |           |                |
|   +-----------v---+  +----v-----------+   |
|   | Event pipeline|  | QueryHost      |   |
|   | (FSW->Channel)|  | (ASP.NET Core) |   |
|   +---------------+  +----------------+   |
|                                             |
+--------------------------------------------+
        |                       ^
   c:\job\*                  127.0.0.1:5100
   (filesystem)               (HTTP loopback)
```

### Startup sequence (SVC-003, SVC-006, PERF-001)

1. `FalconAuditWorker.StartAsync` reads `appsettings.json` (INS-002).
2. `ClassificationRulesLoader` performs an initial synchronous load and starts its own FSW (CLS-005).
3. `FileMonitor` registers its recursive `FileSystemWatcher` on `watch_path` and starts emitting `RawFileEvent` to the global channel. **This must complete < 600 ms after process start (PERF-001).**
4. `DirectoryWatcher` registers its depth-1 FSW on `watch_path` for job folder arrivals/departures (JOB-002).
5. `JobDiscoveryService` starts its 30 s timer and (TODO) secondary FSW on `c:\job\status.ini`.
6. `QueryHost` starts Kestrel (loopback only).
7. **Only after** all of the above are live, `JobManager.EnumerateExisting()` runs and triggers `CatchUpScanner` for every existing job (JOB-005, CUS-001).

This ordering guarantees no live event is lost during the catch-up window.

### Shutdown sequence (SVC-004)

1. Cancel the global `CancellationTokenSource`.
2. Stop accepting new events at `FileMonitor` (dispose the FSW).
3. Drain each per-shard sub-channel — writer tasks complete pending events.
4. Flush and dispose every `SqliteRepository` in the registry; record final manifest entries.
5. Stop Kestrel.
6. Grace period: 30 seconds. Anything still pending is logged as a warning and dropped (REL-001 contract: drop only at shutdown).

---

## 2. Component breakdown

### 2.1 FalconAuditWorker — composition root

**Responsibility:** Hosts the whole pipeline. Implements `BackgroundService.ExecuteAsync`. Constructs and wires every component via Microsoft.Extensions.DependencyInjection. Catches and logs unhandled exceptions from background tasks (SVC-005). Coordinates shutdown.

**Requirements covered:** SVC-001, SVC-003, SVC-004, SVC-005, SVC-006, SVC-007.

**Dependencies:** all other components.

### 2.2 FileMonitor — file system event source

**Responsibility:** Owns one `FileSystemWatcher` configured with `IncludeSubdirectories=true`, `InternalBufferSize=fsw_buffer_size` (default 64 KB), `NotifyFilter = FileName | LastWrite | Size | Attributes`. Translates each FSW callback into a `RawFileEvent` and writes it to the **global** producer channel.

Handles `Renamed` events specially: if both `OldFullPath` and `FullPath` are present, emits a `RawFileEvent { EventType=Renamed }` with both paths populated. Otherwise emits the underlying `Created` / `Deleted` pair as the FSW reports them (Q1).

On `FileSystemWatcher.Error` (buffer overflow), logs at warning, disposes and recreates the FSW, and signals `JobManager` to enqueue a full `CatchUpScanner` run for every active shard (MON-005, CUS-003).

**Requirements covered:** MON-001, MON-002, MON-003, MON-005, MON-006.

**Dependencies:** `IEventPipeline` (for raw-event input), `IOptions<MonitorConfig>`.

### 2.3 Debouncer — per-path coalescer

**Responsibility:** Holds `ConcurrentDictionary<string, CancellationTokenSource>` keyed by absolute file path. On each incoming `RawFileEvent`:
- Cancels any existing CTS for that path.
- Creates a new CTS, registers a `Task.Delay(debounce_ms, cts.Token)` continuation.
- When the delay elapses without cancellation, the path is forwarded to the classifier.

This guarantees that bursts of events on the same file produce exactly one downstream event 500 ms after the last burst (MON-004).

For `Renamed` events the debouncer key is the **new** path; the old path's pending CTS (if any) is cancelled.

**Requirements covered:** MON-004.

**Dependencies:** `IFileClassifier`, `IEventPipeline`.

### 2.4 FileClassifier + ClassificationRulesLoader — classification

**Responsibility (FileClassifier):** Given a `RawFileEvent`, finds the first matching `CompiledRule` in the current `ImmutableList<CompiledRule>` (CLS-003). Returns a `ClassifiedEvent` augmented with `Module`, `OwnerService`, `MonitorPriority`, `MatchedPatternId` (CLS-007). On no match, applies fallback `(Module="Unknown", OwnerService="Unknown", Priority=3)` (CLS-004).

**Responsibility (ClassificationRulesLoader):** Reads `FileClassificationRules.json` once at startup (CLS-001). Compiles glob patterns to `Regex` with `RegexOptions.Compiled | IgnoreCase` (CLS-002, CLS-008). Holds the rule set as a private `ImmutableList<CompiledRule>` field, updated only through `Interlocked.Exchange` (CLS-006). Owns a secondary `FileSystemWatcher` on the rules file's directory; on change, debounces 500 ms, then attempts a reload. If the new file is invalid JSON, logs at error and **keeps the previous rule set** (REL-006). Reload completes within 2 s of file save (PERF-003, CLS-005).

**Requirements covered:** CLS-001 through CLS-008, REL-006, PERF-003.

**Dependencies:** `IOptions<MonitorConfig>`, file system.

### 2.5 EventPipeline — channel ownership

**Responsibility:** Owns the **global** `Channel<ClassifiedEvent>` (capacity 1000, `BoundedChannelFullMode.Wait` for back-pressure per REL-001) and a `ConcurrentDictionary<string, Channel<ClassifiedEvent>>` of **per-shard sub-channels** (capacity 200 each, also `Wait`).

A single fan-out task reads from the global channel and writes each event to the matching shard's sub-channel based on `event.JobName`. For each new shard, lazily spawns one writer `Task` (`EventRecorderLoop`) consuming from that sub-channel.

This is the **single seam** that enforces serialisation per shard (STR-005, REL-005) without explicit locks: one consumer per channel.

**Requirements covered:** REL-001, REL-005, STR-005.

**Dependencies:** `IShardRegistry`, `IEventRecorder`.

### 2.6 EventRecorder — write the row

**Responsibility:** The body of the per-shard writer task. For each `ClassifiedEvent`:

1. **Skip P4** events (warning log only, no DB row).
2. Resolve target repository: `_shardRegistry.GetOrCreate(event.JobName)`. (For events whose path is directly under `c:\job\`, target is the global DB.)
3. Compute SHA-256 of the file via `HashService.ComputeWithRetry(path, retries: 3, delayMs: 100)` (REC-009).
4. If `event.EventType == Modified` and `monitor_priority == 1`: read `last_content` from `file_baselines`. Run DiffPlex `UnifiedDiffBuilder.BuildDiffModel(oldContent, newContent)` and serialize to text.
5. **Oversize check (Q2 / REC-004):** if `file.Length > content_size_limit`, set `is_content_omitted = 1`, leave `old_content` and `diff_text` `NULL`. Hash and row are still written.
6. For non-P1 events: write hash only (REC-003).
7. Build the `AuditRow` and call `_repository.AppendAsync(row)` and `_repository.UpsertBaselineAsync(...)` in a single transaction.
8. Increment the in-memory event counter for the shard; `ManifestManager.OnEventRecorded(jobName)` updates the manifest's `last_event_at` and `event_count` (REC-008, JOB-007).

**Failures:** any exception inside the loop is caught, logged with the file path and event type, and execution moves on (REL-004). The shard's writer task **never** dies on a per-event error.

**Requirements covered:** REC-001 through REC-009, REL-004.

**Dependencies:** `IShardRegistry`, `IHashService`, `IDiffService`, `IManifestManager`, `IOptions<MonitorConfig>`.

### 2.7 ShardRegistry — connection lifecycle

**Responsibility:** `ConcurrentDictionary<string, Lazy<SqliteRepository>>`. The factory function for each `Lazy<T>` opens a fresh `SqliteConnection`, applies PRAGMAs (`journal_mode=WAL`, `synchronous=NORMAL`, `foreign_keys=ON`), runs `CreateTablesIfMissing()`, and returns the wrapping `SqliteRepository`.

**Lazy semantics (STR-007):** the connection is opened only on the first call to `.Value` — i.e. when the first event for the job arrives, not on job arrival.

**Disposal (STR-008):** on `JobManager.OnDeparted(jobName)`, removes the entry, awaits the writer task's drain, calls `repository.DisposeAsync()`. Must complete < 5 seconds.

**Requirements covered:** STR-001, STR-005, STR-007, STR-008, REL-007.

**Dependencies:** `IOptions<MonitorConfig>`, `ILogger<ShardRegistry>`.

### 2.8 SqliteRepository — per-shard write surface

**Responsibility:** Owns a single open `SqliteConnection` (writer). All write methods are async, parameterised, and run on the shard's writer Task (so no internal lock is needed). Provides:

- `AppendAuditRowAsync(AuditRow row)` — INSERT into `audit_log`.
- `UpsertBaselineAsync(string path, string hash, DateTime when, string? content)` — INSERT OR REPLACE into `file_baselines`.
- `GetBaselineContentAsync(string path)` — SELECT (used by `EventRecorder` for diff input).
- `EnumerateBaselinesAsync()` — SELECT all (used by `CatchUpScanner`).
- `DisposeAsync()` — checkpoint WAL, close connection.

All SQL is via `SqliteCommand` parameters (CON-004). All `SqliteCommand` and `SqliteTransaction` instances are disposed with `await using`.

**Requirements covered:** STR-004, STR-005, CON-004.

**Dependencies:** none beyond `Microsoft.Data.Sqlite`.

### 2.9 JobManager + DirectoryWatcher — job lifecycle

**Responsibility (DirectoryWatcher):** A second `FileSystemWatcher` on `watch_path` with `IncludeSubdirectories=false` and `NotifyFilter = DirectoryName`. Emits `JobArrived(name)` and `JobDeparted(name)` events. **No debouncing** — Q3 demands ≤ 1 s detection.

**Responsibility (JobManager):**
- On startup: enumerates existing top-level directories under `watch_path`. For each, if `<job>\.audit\manifest.json` does not exist, calls `RecordArrival`; otherwise calls `ContinueExisting`. Either way, schedules a `CatchUpScanner` run for that job (JOB-005).
- On `JobArrived(name)`: calls `ManifestManager.RecordArrival(name)`. If a prior manifest exists with a different `last_machine_name`, also writes a synthetic `CustodyHandoff` row to `global.db` (Q5). Then schedules a scoped `CatchUpScanner` for that job.
- On `JobDeparted(name)`: calls `ManifestManager.RecordDeparture(name)`, then `ShardRegistry.DisposeAsync(name)`. Must complete < 5 s (STR-008).

**Requirements covered:** JOB-001 through JOB-007.

**Dependencies:** `IManifestManager`, `IShardRegistry`, `ICatchUpScanner`, `IGlobalRepository` (for handoff event), `IOptions<MonitorConfig>`.

### 2.10 ManifestManager — chain of custody

**Responsibility:** Reads and writes `<jobFolder>\.audit\manifest.json`. The manifest schema:

```json
{
  "job_name": "Lot-A-2026-04-26",
  "first_observed_at": "2026-04-26T08:14:22Z",
  "first_observed_by": "FALCON-03",
  "last_event_at": "2026-04-26T09:55:01Z",
  "custody_history": [
    { "machine_name": "FALCON-03", "arrived_at": "...", "departed_at": null, "event_count": 412 }
  ]
}
```

All writes use atomic temp-file rename (REL-003):
1. Serialize to `<job>\.audit\manifest.json.tmp`.
2. `File.Flush(true)` the underlying stream (durable to disk).
3. `File.Move(tmp, dest, overwrite: true)`.

In-memory event counters are flushed to disk every 5 s and on shutdown.

**Requirements covered:** STR-003, JOB-007, REL-003.

**Dependencies:** `IOptions<MonitorConfig>`, file system.

### 2.11 CatchUpScanner — reconciliation

**Responsibility:** Per-job reconciliation. Single-instance gate enforced by `SemaphoreSlim(1, 1)` (CUS-005). When invoked for a job:

1. Acquire the gate.
2. Enumerate every file in the job folder (recursive).
3. For each file: compute SHA-256, look up `file_baselines.last_hash`.
   - Missing baseline → emit synthetic `Created` event to the pipeline.
   - Hash differs → emit synthetic `Modified` event.
   - Hash matches → no event; just refresh `last_seen`.
4. After enumeration: any baseline row whose `filepath` no longer exists on disk → emit synthetic `Deleted` event.
5. **Yield** (`await Task.Delay(50ms)`) every time `EventPipeline.PendingCount > catchup_yield_threshold` (default 50) (CUS-006).
6. Release the gate.

Multiple jobs can be scanned in parallel via `Task.WhenAll(jobs.Select(ScanJobAsync))` (SVC-007). The gate is **per-instance**, so the parallel-scan workflow uses a different overload that holds the gate once across all jobs in that batch.

**Requirements covered:** CUS-001 through CUS-006, SVC-002, SVC-007, REL-002.

**Dependencies:** `IEventPipeline`, `IShardRegistry`, `IHashService`, `IOptions<MonitorConfig>`.

### 2.12 QueryHost — read API

**Responsibility:** ASP.NET Core minimal API hosted in the same process. Bound to `127.0.0.1:5100` by default (API-009). Endpoints:

- `GET /api/health` — returns `{ status: "ok", uptime_seconds }`.
- `GET /api/jobs` — returns the active-job list maintained by `JobDiscoveryService` (API-007).
- `GET /api/events` — paginated list. Validates query parameters (API-008, CON-005), opens a fresh `Mode=ReadOnly` connection on the target shard's `audit.db` (API-002, STR-006), runs the page query and a parallel `COUNT(*)`, returns `{ total, items[] }` with **no** `old_content` or `diff_text` (API-006).
- `GET /api/events/{job}/{id}` — single event including `old_content` and `diff_text` (API-004).

Connection cache: a small `MemoryCache` of `(jobName -> ConnectionString)` to avoid repeated path resolution; the underlying connection itself is **not** cached.

`COUNT(*)` cache: `(jobName, filterHash) -> total` cached for 30 s in `IMemoryCache` to ease deep-pagination cost (PERF-005 mitigation).

**Requirements covered:** API-001 through API-009, CON-005, CON-006.

**Dependencies:** `IJobDiscoveryService`, `IOptions<MonitorConfig>`, `IMemoryCache`.

### 2.13 JobDiscoveryService — active-job index

**Responsibility:** Maintains an `ImmutableList<JobInfo>` of active jobs (those with `<job>\.audit\audit.db` present under `watch_path`). Refreshes:
- Every `active_job_rescan_seconds` (default 30 s) via `PeriodicTimer`.
- On `DirectoryWatcher.JobArrived` / `JobDeparted` callbacks (instant signal).
- **TODO-API-007-FAST:** Secondary FSW on `c:\job\status.ini` for instant active-job change detection.

**Requirements covered:** API-007.

**Dependencies:** `IDirectoryWatcher`, `IOptions<MonitorConfig>`.

---

## 3. Communication patterns

### 3.1 Producer-consumer: file events

```
FileSystemWatcher (one OS callback thread)
        |
        v   RawFileEvent
+-------+-------+
|   Debouncer   |  (per-path 500 ms timer)
+-------+-------+
        |   RawFileEvent (post-debounce)
        v
+-------+-------+
| FileClassifier|  (synchronous; ImmutableList lookup)
+-------+-------+
        |   ClassifiedEvent
        v
+----------------------+
| Global Channel<T>    |  (capacity 1000, Wait)
+----------+-----------+
           |
           v   fan-out by JobName
+----------+-----------+      +-----------------------+
|  Per-shard channels  |  --> | One writer Task / job |
|  (capacity 200, Wait)|      | (EventRecorderLoop)    |
+----------------------+      +-----------+-----------+
                                          |
                                          v
                               +----------+-----------+
                               | SqliteRepository     |
                               | (writer connection)  |
                               +----------------------+
```

Back-pressure (REL-001): when a per-shard channel is full, the fan-out `Wait`s, which causes the global channel to fill, which causes the classifier loop to `Wait`, which causes the debouncer to defer firing. Nothing is dropped; the FSW callback never blocks (it just enqueues to the debouncer's CTS table).

### 3.2 Job lifecycle

```
DirectoryWatcher (depth-1 FSW, no debounce, ≤ 1 s)
        |
        v   JobArrived(name) / JobDeparted(name)
+-------+-------+
|  JobManager   |
+-------+-------+
        |
        +--> ManifestManager.RecordArrival/Departure (atomic file rename)
        +--> ShardRegistry.GetOrCreate / DisposeAsync
        +--> CatchUpScanner.QueueJob(name)
        +--> JobDiscoveryService.Refresh()
```

### 3.3 Read API (no shared connection)

```
HTTP GET /api/events
        |
        v
QueryController -> validate params -> resolve shard path
                                         |
                                         v
                       open SqliteConnection(Mode=ReadOnly)
                                         |
                                         v
                    parallel: { SELECT page  ;  SELECT COUNT(*) }
                                         |
                                         v
                    serialize to JSON, dispose connection, return
```

Reads never go through the writer task. WAL mode (STR-004) means readers do not block writers and vice versa (STR-006).

---

## 4. Concurrency model

| Surface | Threading | Synchronisation |
|---|---|---|
| FSW callbacks (FileMonitor + DirectoryWatcher + RulesLoader) | OS-thread-pool callbacks | None — handlers enqueue and return |
| Debouncer | `ConcurrentDictionary` + per-key CTS | Lock-free |
| FileClassifier | Reads `ImmutableList` snapshot | `Interlocked.Exchange` on rules update |
| Global channel + per-shard channels | `System.Threading.Channels` | Built-in; bounded; `Wait` on full |
| Writer task per shard | One `Task` with `await foreach` over its channel | Single-consumer = inherent serialisation |
| Hash + diff computation | `Task.Run` on default scheduler | None |
| Manifest writes | Per-job `SemaphoreSlim(1)` to serialise atomic-rename | Lock |
| API requests | ASP.NET Core thread pool | Each request opens its own read connection |
| `JobDiscoveryService.PeriodicTimer` | One timer task | `ImmutableList` swap on update |

There is **exactly one writer connection** per shard at any moment (STR-007). Read connections are short-lived and per-request (STR-006). This model meets STR-005 / REL-005 by construction without explicit locks.

---

## 5. Component dependency graph

```
                         +------------------+
                         | IOptions<Monitor |
                         |     Config>      |
                         +---------+--------+
                                   |
   +-------------------------------+-------------------------------+
   |          |              |             |              |        |
+--v---+ +----v-----+ +------v----+ +------v-----+ +------v-----+ +-v-----+
| Hash | |  Diff    | | Manifest  | |  Rules     | |  Shard     | |  Job  |
| Svc  | |  Svc     | |  Manager  | |  Loader    | |  Registry  | |  Disc |
+--+---+ +----+-----+ +------+----+ +------+-----+ +------+-----+ +-+-----+
   |          |              |             |              |        |
   |          |              |             |              |        |
   +----+-----+              |             |              |        |
        |                    |             |              |        |
   +----v---------+          |    +--------v-+            |        |
   | EventRecorder|<---------+    | Classifier|           |        |
   +----+---------+               +--+-------+           |        |
        |                            |                   |        |
        |   +------------------------+                   |        |
        |   |                                            |        |
   +----v---v---+                                       |        |
   | EventPipe  |                                       |        |
   +-----+------+                                       |        |
         |                                              |        |
         |   +----------+                              |        |
         +---| Debouncer|<--+                          |        |
             +----+-----+   |                          |        |
                  |         |                          |        |
                  v         |                          |        |
              +---+----+    |     +------------+      |        |
              | FileMon|----+     | DirWatcher |------+        |
              +--------+          +-----+------+               |
                                        |                       |
                                        v                       |
                                 +------+------+               |
                                 |  JobManager |---------------+
                                 +------+------+
                                        |
                                +-------v-------+
                                | CatchUpScanner|
                                +---------------+

                              +------------+
                              | QueryHost  | (API)
                              +------+-----+
                                     |
                              +------v-------+
                              |  JobDisc Svc |
                              +--------------+
```

**Topological order for implementation (leaves first):** `HashService`, `DiffService`, `ManifestManager`, `ClassificationRulesLoader`, `SqliteRepository`, `ShardRegistry`, `FileClassifier`, `Debouncer`, `EventRecorder`, `EventPipeline`, `FileMonitor`, `DirectoryWatcher`, `CatchUpScanner`, `JobManager`, `JobDiscoveryService`, `QueryHost`, `FalconAuditWorker`.

---

## 6. Deployment

### 6.1 Packaging

```
dotnet publish src/FalconAuditService -c Release -r win-x64 --self-contained true \
   /p:PublishSingleFile=false /p:PublishReadyToRun=true
```

Output goes to `bin/Release/net6.0/win-x64/publish/`. Contents:
- `FalconAuditService.exe`
- `appsettings.json`
- All managed and native dependencies (`e_sqlite3.dll`, `Microsoft.Data.Sqlite.dll`, etc.)
- `install.ps1`

### 6.2 Install script (`install.ps1`)

Run as Administrator. Steps:

1. `New-Item C:\bis\auditlog\logs -ItemType Directory -Force`.
2. Copy default `FileClassificationRules.json` to `C:\bis\auditlog\` if missing.
3. Set ACLs: full control to `LocalSystem` (or the configured service account), read+execute to `Administrators`, deny `Modify` to `Users` (CON-003).
4. Copy publish output to `C:\Program Files\Camtek\FalconAuditService\`.
5. `sc.exe create FalconAuditService binPath= "...\FalconAuditService.exe" start= auto`.
6. `sc.exe failure FalconAuditService reset= 86400 actions= restart/5000/restart/5000/restart/5000` (CON-002, INS-001).
7. Register Windows Event Log source `FalconAuditService` for warning+ events (INS-005).
8. `sc.exe start FalconAuditService`.

### 6.3 Configuration (`appsettings.json`)

All settings live under the `monitor_config` section (INS-002, INS-004). The configuration file is the single source of truth.

```json
{
  "Logging": {
    "LogLevel": { "Default": "Information" }
  },
  "monitor_config": {
    "watch_path": "c:\\job\\",
    "global_db_path": "C:\\bis\\auditlog\\global.db",
    "classification_rules_path": "C:\\bis\\auditlog\\FileClassificationRules.json",
    "api_port": 5100,
    "api_bind_loopback_only": true,
    "debounce_ms": 500,
    "fsw_buffer_size": 65536,
    "content_size_limit": 1048576,
    "capture_content": true,
    "active_job_rescan_seconds": 30,
    "catchup_yield_threshold": 50,
    "count_cache_seconds": 30
  },
  "Serilog": {
    "WriteTo": [
      { "Name": "File", "Args": { "path": "C:\\bis\\auditlog\\logs\\falcon-.log", "rollingInterval": "Day" } },
      { "Name": "EventLog", "Args": { "source": "FalconAuditService", "manageEventSource": false, "restrictedToMinimumLevel": "Warning" } }
    ]
  }
}
```

### 6.4 Operational runbook

| Operation | Command |
|---|---|
| Start | `sc.exe start FalconAuditService` |
| Stop | `sc.exe stop FalconAuditService` |
| Status | `sc.exe query FalconAuditService` |
| Logs | Tail `C:\bis\auditlog\logs\falcon-YYYYMMDD.log` |
| Hot-reload rules | Save `C:\bis\auditlog\FileClassificationRules.json` (no restart) |
| Reconfigure | Edit `appsettings.json`; restart service |
| Uninstall | `sc.exe stop FalconAuditService && sc.exe delete FalconAuditService` |

---

## 7. Failure modes and mitigations

| Failure | Component | Mitigation | Requirement |
|---|---|---|---|
| FSW buffer overflow | FileMonitor | Recreate FSW + trigger full catch-up | MON-005, CUS-003 |
| Hash file locked | EventRecorder | 3× retry with 100 ms back-off, then log warning | REC-009 |
| Rules file invalid JSON | ClassificationRulesLoader | Keep prior rule set, log error | REL-006 |
| Shard cannot be opened | ShardRegistry | Log error per-job, isolate; other jobs continue | REL-007 |
| Per-event exception | EventRecorder | Catch, log, continue loop (writer task survives) | REL-004, SVC-005 |
| Service crash | OS | `sc.exe failure` restart actions; on next start, catch-up reconciles | SVC-002, REL-002 |
| Manifest corruption mid-write | ManifestManager | Atomic temp-file-rename guarantees old file remains valid | REL-003 |
| Channel full | EventPipeline | Producer awaits; nothing dropped | REL-001 |

---

## 8. Mapping: requirement -> primary component

| Req | Primary owner | Notes |
|---|---|---|
| SVC-001..007 | FalconAuditWorker | composition + ordering |
| MON-001..006 | FileMonitor + Debouncer | FSW + coalescing |
| CLS-001..008 | FileClassifier + RulesLoader | atomic hot reload |
| REC-001..009 | EventRecorder | hash + diff + write |
| STR-001..008 | ShardRegistry + SqliteRepository | lazy open, WAL, per-shard writer |
| JOB-001..007 | JobManager + DirectoryWatcher | depth-1 FSW + manifest |
| CUS-001..006 | CatchUpScanner | gated, parallel, yielding |
| API-001..009 | QueryHost + JobDiscoveryService | minimal API, loopback, validation |
| PERF-001..005 | startup ordering + index design + COUNT cache | see PERF section |
| REL-001..007 | bounded channels + atomic rename + try/catch boundaries | |
| INS-001..005 | install.ps1 + appsettings.json + Serilog Event Log sink | |
| CON-001..006 | parameterised SQL + ACL setup + path validation | |

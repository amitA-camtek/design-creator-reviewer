# FalconAuditService — Architecture Design

| Field | Value |
|---|---|
| Document | architecture-design.md |
| Phase | 1 — Final design |
| Chosen alternative | **C — Multi-hosted (Out-of-process API + Worker)** |
| Source | `req.md`, `engineering_requirements.md` (ERS-FAU-001), `architecture-alternatives.md` |
| Target | .NET 6, Windows 10 / Server 2019+ (64-bit) |
| Date | 2026-04-25 |

---

## 1. Decision

The system is delivered as **two independent Windows services** sharing a `FalconAuditService.Core` class library. Process boundaries deliver crash isolation between writes and reads:

- **`FalconAuditWorker`** — `BackgroundService` that owns the FileSystemWatcher pipeline, shard registry (read-write), manifest, and catch-up scanner. This is the only writer to any audit DB.
- **`FalconAuditQuery`** — ASP.NET Core process hosting the read-only HTTP API on port 5100 (loopback). Opens shards strictly in `Mode=ReadOnly` and never holds write locks.

There is **no IPC channel** between the two processes. They communicate only through the file system: the worker writes to `<jobFolder>\.audit\audit.db`, `manifest.json`, and `C:\bis\auditlog\global.db`; the query process discovers and reads them. SQLite WAL mode (STR-003, REL-004) provides safe concurrent read/write across process boundaries.

---

## 2. Process Topology

```
+--------------------- FalconAuditWorker.exe ----------------------+   +--------------------- FalconAuditQuery.exe -----------------------+
|                                                                  |   |                                                                  |
|  AuditHost (BackgroundService)                                   |   |  ApiHost (Generic Host + Kestrel :5100 loopback)                 |
|     |                                                            |   |     |                                                            |
|     |--StartAsync (strict order):                                |   |     |--StartAsync:                                               |
|     |   1. IClassificationRulesLoader.LoadAsync                  |   |     |   1. IJobDiscoveryService.RefreshAsync                     |
|     |   2. IFileMonitor.StartAsync (FSW armed, WatcherReady set) |   |     |   2. IJobDiscoveryService.StartPolling (30 s, API-007)     |
|     |   3. IDirectoryWatcher.StartAsync (job arrival/departure)  |   |     |   3. Kestrel listen on 5100 (loopback)                     |
|     |   4. ICatchUpCoordinator.RunAllAsync (only after step 2)   |   |                                                                  |
|     |   5. IRulesFileWatcher.StartAsync (hot-reload)             |   |  IShardReaderFactory --> SqliteRepository (Mode=ReadOnly)        |
|     |                                                            |   |  QueryController                                                 |
|  IFileMonitor --(RawFsEvent)--> IFileClassifier                  |   |  EventQueryBuilder                                               |
|         |                              |                         |   |  RelFilepathConstraint (API-008)                                 |
|         | (raw)                        v (ClassifiedEvent)       |   |  PathValidator                                                   |
|  FileSystemWatcher              IShardRouter ---+                |   |                                                                  |
|         (recursive c:\job\)                     |                |   |                                                                  |
|                                                 v                |   |                                                                  |
|  IDirectoryWatcher --(JobArrival/Departure)--> IJobLifecycle     |   |                                                                  |
|         (depth-1 c:\job\)                       |                |   |                                                                  |
|                                                 v                |   |                                                                  |
|                                          IShardRegistry (RW)     |   |                                                                  |
|                                          per-shard SemaphoreSlim |   |                                                                  |
|                                          per-shard Channel<>     |   |                                                                  |
|                                          1 writer Task per shard |   |                                                                  |
|                                                 |                |   |                                                                  |
|                                                 v                |   |                                                                  |
|                            IEventRecorder + IManifestManager     |   |                                                                  |
|                                                                  |   |                                                                  |
+--------|---------------------------------------------------------+   +-----------|------------------------------------------------------+
         |                                                                          |
         v                                                                          v
   c:\job\<j>\.audit\audit.db        +--------- WAL-mode reads ---------+    Mode=ReadOnly connections
   c:\job\<j>\.audit\manifest.json   |                                  |
   C:\bis\auditlog\global.db         <----------------------------------+
```

**Lifecycle**: both services are auto-start (Windows Service `start=auto`). The query service has `Depend=FalconAuditWorker` set in its SCM record so SCM brings the worker up first; the query service tolerates a missing worker by serving 503 from `/api/jobs` until the first discovery scan finds shards.

---

## 3. Component Catalogue

Each component is an `internal sealed class` registered against an interface in the relevant `Program.cs`. Components in the **shared** column live in `FalconAuditService.Core.dll` and are referenced by both processes.

| Component | Interface | Process | Lifetime | Req. group |
|---|---|---|---|---|
| `AuditHost` | (BackgroundService) | Worker | Singleton | SVC |
| `FileMonitor` | `IFileMonitor` | Worker | Singleton | MON |
| `EventDebouncer` | `IEventDebouncer` | Worker | Singleton | MON |
| `DirectoryWatcher` | `IDirectoryWatcher` | Worker | Singleton | JOB |
| `JobLifecycleHandler` | `IJobLifecycle` | Worker | Singleton | JOB |
| `FileClassifier` | `IFileClassifier` | Shared | Singleton | CLS |
| `ClassificationRulesLoader` | `IClassificationRulesLoader` | Shared | Singleton | CLS |
| `RulesFileWatcher` | `IRulesFileWatcher` | Worker | Singleton | CLS |
| `EventRecorder` | `IEventRecorder` | Worker | Singleton | REC |
| `HashService` | `IHashService` | Worker | Singleton | REC |
| `DiffBuilder` | `IDiffBuilder` | Worker | Singleton | REC |
| `ShardRegistry` (RW) | `IShardRegistry` | Worker | Singleton | STR |
| `ShardRegistry` (RO) | `IShardReaderFactory` | Query | Singleton | STR / API |
| `SqliteRepository` | `ISqliteRepository` | Shared | Transient (per shard) | STR |
| `SchemaMigrator` | `ISchemaMigrator` | Worker | Singleton | STR |
| `ManifestManager` | `IManifestManager` | Shared | Singleton | MFT |
| `CatchUpCoordinator` | `ICatchUpCoordinator` | Worker | Singleton | CUS |
| `CatchUpScanner` | `ICatchUpScanner` | Worker | Transient (per job) | CUS |
| `JobDiscoveryService` | `IJobDiscoveryService` | Query | Singleton | API |
| `QueryController` | (controller) | Query | Scoped | API |
| `EventQueryBuilder` | `IEventQueryBuilder` | Query | Singleton | API |
| `PathValidator` | `IPathValidator` | Shared | Singleton | API |
| `RelFilepathConstraint` | `IRouteConstraint` | Query | Singleton | API |
| `IClock` | `IClock` | Shared | Singleton | (test seam) |

### 3.1 Worker-only components (writes)

- **`AuditHost`** — orchestrates start order; awaits `IFileMonitor.WatcherReady` before invoking `ICatchUpCoordinator.RunAllAsync`. This is the **SVC-003 contract encoded in code**.
- **`FileMonitor`** — recursive `FileSystemWatcher` rooted at `monitor_config.watch_path` (default `c:\job\`) with 64 KB internal buffer. On FSW `Error` event with `InternalBufferOverflowException`, raises `BufferOverflow` which `CatchUpCoordinator` consumes to trigger a full scan.
- **`EventDebouncer`** — `ConcurrentDictionary<string, CancellationTokenSource>` keyed by full path. On each event, cancels the prior CTS, schedules a 500 ms (`monitor_config.debounce_ms`) delayed task that pushes the final event into the per-shard channel.
- **`DirectoryWatcher`** — depth-1 (NotifyFilter = DirectoryName) FSW on the watch root. Emits `JobArrival(name)` / `JobDeparture(name)` events.
- **`JobLifecycleHandler`** — on arrival: `ManifestManager.RecordArrivalAsync` → `ShardRegistry.GetOrCreateAsync` → `CatchUpCoordinator.ScheduleAsync`. On departure: stop writer task → drain channel → `ManifestManager.RecordDepartureAsync` → dispose shard within 5 s (STR-007).
- **`EventRecorder`** — for each `ClassifiedEvent`: compute SHA-256 (3× retry × 100 ms on `IOException`); read `old_content` from `file_baselines` if monitor priority is P1; build unified diff via DiffPlex `UnifiedDiffBuilder`; INSERT into `audit_log`; UPSERT into `file_baselines`. Behavior table:

  | Priority | Hash | `old_content` | `diff_text` | DB write |
  |---|---|---|---|---|
  | P1 | yes | yes (full new) | yes (DiffPlex unified) | row inserted |
  | P2 | yes | NULL | NULL | row inserted |
  | P3 | yes | NULL | NULL | row inserted |
  | P4 | no | n/a | n/a | warning log only, no row |

- **`ShardRegistry` (RW)** — `ConcurrentDictionary<string, ShardHandle>`. Each `ShardHandle` carries an `SqliteRepository`, a `Channel<ClassifiedEvent>` (bounded 1024), a `SemaphoreSlim(1)` (STR-005), and a dedicated writer `Task`. Guarantees one writer per shard; reads are unsupported (the query process owns reads).
- **`SchemaMigrator`** — opens DB, reads `PRAGMA user_version`, applies missing migration scripts inside a single immediate transaction.
- **`CatchUpCoordinator` / `CatchUpScanner`** — one Task per job. Yields execution if the per-shard channel depth exceeds 50 (CUS-005, configurable). Reconciles on-disk files vs `file_baselines` and emits `Created` / `Modified` / `Deleted` events.
- **`RulesFileWatcher`** — secondary FSW on `monitor_config.classification_rules_path`. On change: `ClassificationRulesLoader.LoadAsync` + `Interlocked.Exchange` of the `ImmutableList<CompiledRule>` inside `FileClassifier`. Invalid JSON keeps the previous list and logs a warning. Active within 2 s of save (PERF-003).

### 3.2 Query-only components (reads)

- **`ApiHost`** — generic host running Kestrel bound to `127.0.0.1:5100` by default (configurable in `monitor_config.api_port`).
- **`JobDiscoveryService`** — singleton. On startup and every 30 s (API-007) scans `c:\job\*\.audit\audit.db`. Maintains an `ImmutableDictionary<string, ShardLocation>` swapped via `Interlocked.Exchange`. The global DB is statically registered.
- **`IShardReaderFactory`** — opens `Microsoft.Data.Sqlite` connections with `Mode=ReadOnly;Cache=Shared` (API-002). Connections are scoped to the HTTP request and disposed in `IAsyncDisposable`.
- **`QueryController`** — actions for the seven mandatory endpoints (see `api-design.md`).
- **`EventQueryBuilder`** — single source of truth that translates `EventQueryFilter` into `(sql, parameters)`; used by both list and `COUNT(*)` queries.
- **`RelFilepathConstraint`** — `IRouteConstraint` enforcing `^[\w\-. \\/]+$` (API-008) at the routing layer for `history/{*filePath}`. Belt-and-braces with `PathValidator` in the controller body.

### 3.3 Shared components

- **`FileClassifier`**, **`ClassificationRulesLoader`** — pure functions over compiled `Regex` rules. Same code in both processes so the API can resolve `module` / `owner_service` from a path when needed (e.g. for a future enrichment endpoint).
- **`SqliteRepository`** — thin Dapper-free ADO.NET wrapper. Construction takes a `connectionString` and a `mode` (`ReadWrite` for worker, `ReadOnly` for query). The class itself enforces `Mode=ReadOnly` when constructed in read mode.
- **`ManifestManager`** — atomic JSON writer (temp file + `File.Move(tmp, dest, overwrite: true)`) used by the worker; the query process uses the same class purely as a reader.
- **`PathValidator`**, **`IClock`** — helpers.

---

## 4. Dependency Graph

### 4.1 Worker process

```
AuditHost
 ├── IClassificationRulesLoader
 │     └── IFileSystem
 ├── IFileClassifier
 │     └── IClassificationRulesLoader
 ├── IFileMonitor
 │     ├── IEventDebouncer
 │     ├── IFileClassifier
 │     └── IShardRegistry  (route classified events into per-shard channel)
 ├── IDirectoryWatcher
 │     └── IJobLifecycle
 │           ├── IManifestManager
 │           ├── IShardRegistry
 │           └── ICatchUpCoordinator
 ├── ICatchUpCoordinator
 │     ├── ICatchUpScanner (factory)
 │     ├── IShardRegistry
 │     └── IFileClassifier
 ├── IRulesFileWatcher
 │     └── IClassificationRulesLoader
 └── IShardRegistry
       ├── ISchemaMigrator
       ├── ISqliteRepository (factory, ReadWrite)
       ├── IEventRecorder
       │     ├── IHashService
       │     ├── IDiffBuilder
       │     └── ISqliteRepository
       └── IClock

(Cross-cutting: ILogger<T>, IOptionsMonitor<MonitorConfig>)
```

### 4.2 Query process

```
ApiHost
 ├── IJobDiscoveryService
 │     └── IFileSystem
 ├── IShardReaderFactory
 │     └── ISqliteRepository (factory, ReadOnly)
 ├── QueryController (scoped)
 │     ├── IShardReaderFactory
 │     ├── IJobDiscoveryService
 │     ├── IEventQueryBuilder
 │     ├── IPathValidator
 │     └── IManifestManager (read-only methods)
 └── RelFilepathConstraint  (registered at MVC routing)
```

No cycles. The `Worker → Query` direction is "share via filesystem" only.

---

## 5. DI Registration Plan

### 5.1 Worker `Program.cs`

```csharp
var builder = Host.CreateDefaultBuilder(args)
    .UseWindowsService(o => o.ServiceName = "FalconAuditWorker")
    .ConfigureServices((ctx, s) =>
    {
        s.Configure<MonitorConfig>(ctx.Configuration.GetSection("monitor_config"));

        // shared
        s.AddSingleton<IClock, SystemClock>();
        s.AddSingleton<IFileSystem, PhysicalFileSystem>();
        s.AddSingleton<IClassificationRulesLoader, ClassificationRulesLoader>();
        s.AddSingleton<IFileClassifier, FileClassifier>();
        s.AddSingleton<IPathValidator, PathValidator>();
        s.AddSingleton<IManifestManager, ManifestManager>();
        s.AddSingleton<ISchemaMigrator, SchemaMigrator>();
        s.AddSingleton<ISqliteRepositoryFactory, SqliteRepositoryFactory>();

        // worker pipeline
        s.AddSingleton<IHashService, HashService>();
        s.AddSingleton<IDiffBuilder, DiffPlexDiffBuilder>();
        s.AddSingleton<IEventRecorder, EventRecorder>();
        s.AddSingleton<IShardRegistry, ShardRegistryRw>();
        s.AddSingleton<IEventDebouncer, EventDebouncer>();
        s.AddSingleton<IFileMonitor, FileMonitor>();
        s.AddSingleton<IDirectoryWatcher, DirectoryWatcher>();
        s.AddSingleton<IJobLifecycle, JobLifecycleHandler>();
        s.AddSingleton<ICatchUpScannerFactory, CatchUpScannerFactory>();
        s.AddSingleton<ICatchUpCoordinator, CatchUpCoordinator>();
        s.AddSingleton<IRulesFileWatcher, RulesFileWatcher>();

        s.AddHostedService<AuditHost>();

        // Serilog -> rolling file + Windows Event Log
        s.AddSerilog(...);
    });
```

### 5.2 Query `Program.cs`

```csharp
var builder = WebApplication.CreateBuilder(args);
builder.Host.UseWindowsService(o => o.ServiceName = "FalconAuditQuery");

builder.Services.Configure<MonitorConfig>(builder.Configuration.GetSection("monitor_config"));

// shared
builder.Services.AddSingleton<IClock, SystemClock>();
builder.Services.AddSingleton<IFileSystem, PhysicalFileSystem>();
builder.Services.AddSingleton<IClassificationRulesLoader, ClassificationRulesLoader>();
builder.Services.AddSingleton<IFileClassifier, FileClassifier>();
builder.Services.AddSingleton<IPathValidator, PathValidator>();
builder.Services.AddSingleton<IManifestManager, ManifestManager>();
builder.Services.AddSingleton<ISqliteRepositoryFactory, SqliteRepositoryFactory>();

// query-only
builder.Services.AddSingleton<IJobDiscoveryService, JobDiscoveryService>();
builder.Services.AddSingleton<IShardReaderFactory, ShardReaderFactory>();
builder.Services.AddSingleton<IEventQueryBuilder, EventQueryBuilder>();
builder.Services.AddHostedService<JobDiscoveryHostedService>();   // 30 s polling

builder.Services.AddControllers(o =>
{
    o.Conventions.Add(new ApiBehaviorConvention());
}).ConfigureApiBehaviorOptions(o => o.SuppressMapClientErrors = false);

builder.Services.Configure<RouteOptions>(o =>
{
    o.ConstraintMap["relpath"] = typeof(RelFilepathConstraint);
});

builder.WebHost.ConfigureKestrel(k =>
{
    var port = builder.Configuration.GetValue<int>("monitor_config:api_port", 5100);
    k.ListenLocalhost(port);   // loopback default; bind to 0.0.0.0 only via config override
});
```

---

## 6. Requirement Group Mapping

| Group | Requirement summary | Components | Location |
|---|---|---|---|
| **SVC** | Service host, `BackgroundService`, FSW-before-catch-up, < 600 ms FSW arm | `AuditHost`, `FileMonitor` | Worker |
| **MON** | Recursive FSW, 500 ms debounce, buffer-overflow → catch-up | `FileMonitor`, `EventDebouncer` | Worker |
| **CLS** | Rules loader, hot-reload, regex-compiled-once, fallback P3/Unknown/Unknown | `FileClassifier`, `ClassificationRulesLoader`, `RulesFileWatcher` | Shared / Worker |
| **REC** | Hash, diff, P1/P2/P3/P4 behavior, file_baselines update | `EventRecorder`, `HashService`, `DiffBuilder` | Worker |
| **STR** | WAL, sync=NORMAL, per-shard registry, SemaphoreSlim, dispose ≤ 5 s | `ShardRegistry`, `SqliteRepository`, `SchemaMigrator` | Worker (RW) / Query (RO) |
| **JOB** | Depth-1 directory watcher, arrival/departure | `DirectoryWatcher`, `JobLifecycleHandler` | Worker |
| **MFT** | Atomic manifest writes, machine custody history | `ManifestManager` | Shared |
| **CUS** | Reconciliation on start + arrival, parallel per job, queue-depth yield | `CatchUpCoordinator`, `CatchUpScanner` | Worker |
| **API** | Read-only HTTP, 7 endpoints, filters, pagination, path regex, 30 s discovery | `QueryController`, `JobDiscoveryService`, `EventQueryBuilder`, `PathValidator`, `RelFilepathConstraint` | Query |

---

## 7. Critical Ordering Constraints

### 7.1 Startup (worker process)

`AuditHost.StartAsync` is the **only** place that knows the start order. All five steps are awaited sequentially:

1. `IClassificationRulesLoader.LoadAsync` — must complete before any classification can happen.
2. `IFileMonitor.StartAsync` — sets `WatcherReady` `TaskCompletionSource` once the FSW callback is wired and `EnableRaisingEvents = true`. **No code path starts the catch-up before this completes.** (SVC-003 in code, not convention.)
3. `IDirectoryWatcher.StartAsync` — depth-1 watcher armed for arrivals/departures.
4. `ICatchUpCoordinator.RunAllAsync` — enumerates all existing job folders and runs scans in parallel (one Task per job).
5. `IRulesFileWatcher.StartAsync` — only relevant after the initial load is committed.

### 7.2 Shutdown (worker process)

`AuditHost.StopAsync` is the symmetric reverse:

1. Disable `IRulesFileWatcher`.
2. Disable `IFileMonitor` and `IDirectoryWatcher` (raise events no more).
3. Cancel all in-flight `CatchUpScanner` tasks; wait up to 5 s.
4. For each shard in `IShardRegistry`: stop the writer task, drain remaining channel items, dispose `SqliteRepository`. Total budget 5 s × `pendingShards`, capped at the host shutdown grace period.
5. Flush Serilog.

### 7.3 Job arrival

```
DirectoryWatcher fires JobArrival(name)
   -> JobLifecycleHandler.OnArrivalAsync(name)
       1. ManifestManager.RecordArrivalAsync   (creates .audit\ + manifest.json if absent)
       2. ShardRegistry.GetOrCreateAsync       (opens / creates audit.db, runs SchemaMigrator)
       3. CatchUpCoordinator.ScheduleAsync     (queues a per-job scan task)
```

These three steps are sequential. The scan can run concurrently with live event recording for that shard; per-shard `SemaphoreSlim(1)` serialises writes.

### 7.4 Per-event flow

```
FSW callback (any thread)
  -> EventDebouncer.Schedule(path)            [O(1), one CTS per path]
  -> 500 ms later, debounce fires, builds RawFsEvent
  -> FileClassifier.Classify(path)            [Regex, ImmutableList swap]
  -> ShardRegistry.RouteAsync(classifiedEvent)  -> Channel<ClassifiedEvent>.WriteAsync
  -> per-shard writer Task picks up:
       SemaphoreSlim.WaitAsync
       EventRecorder.RecordAsync
         - HashService.ComputeAsync (3 retries)
         - read old_content if P1
         - DiffBuilder.Build if P1
         - SqliteRepository.InsertEventAsync
         - SqliteRepository.UpsertBaselineAsync
       SemaphoreSlim.Release
```

---

## 8. Performance Considerations

| Target | How the architecture meets it |
|---|---|
| **PERF-001 (FSW < 600 ms after process start)** | `AuditHost.StartAsync` arms the FSW in step 2, before catch-up. DI graph is small (~15 singletons), no async DB scan precedes step 2. Empirically < 200 ms cold. |
| **PERF-002 (single P1 event < 1 s after debounce)** | Per-shard writer Task isolates a slow shard from blocking the rest. SHA-256 + DiffPlex on typical config files (≤ 1 MB) is < 50 ms; SQLite WAL insert < 5 ms. Headroom dominated by retry-on-IOException (3 × 100 ms worst case). |
| **PERF-003 (rules hot-reload < 2 s after save)** | `RulesFileWatcher` is a dedicated FSW; `LoadAsync` parses + compiles regex; `Interlocked.Exchange` swap of `ImmutableList<CompiledRule>` is atomic; no in-flight event misclassifies (each event reads the reference once). |
| **PERF-004 (catch-up 10 jobs × 150 files < 5 s)** | Parallel per-job Tasks (`Task.WhenAll`); per-task hash-only fast path (`old_content`/diff only fired through full event recording, not during catch-up dirty-detection). Yield on channel depth > 50 keeps live events responsive. |
| **PERF-005 (paginated query 50 rows < 200 ms)** | Query process owns the API; `Mode=ReadOnly` connections never wait for write locks (WAL); indexes specified in `schema-design.md` cover all API-004 filter combinations. Process isolation means a runaway query never starves the writer. |

### 8.1 Architecture-specific performance notes

- **Two CLR processes** add ~60–80 MB working set vs a single-process design. On Falcon machines this is acceptable.
- **No IPC** means the API has zero network or named-pipe latency to add to query response time.
- **Crash isolation** — a malformed query that triggers an unhandled exception in Kestrel kills only `FalconAuditQuery`; the worker keeps recording. Windows SCM auto-restarts the query on `failure/restart` policy (configured in `install.ps1`).

### 8.2 Multi-connection Design (Query Process)

Multiple concurrent HTTP requests may open connections to the same shard simultaneously. The following rules govern this:

#### Connection pool discipline

`Microsoft.Data.Sqlite` maintains a **per-connection-string pool** within a process. All read-only connections to the same shard must use an **identical** connection string so they share one pool and do not fragment into N separate file handles. `ShardReaderFactory` builds the connection string from `dbPath` alone (using `Cache=Shared` + `Mode=ReadOnly`); no caller-specific parameters are allowed in the string.

```
Connection string (read-only):
  "Data Source=<dbPath>;Mode=ReadOnly;Cache=Shared;Default Timeout=5;"
```

#### Per-request connection lifetime

Each HTTP request acquires one connection from the pool via `IShardReaderFactory.OpenAsync(jobName, ct)`, which returns a `ShardReadHandle : IAsyncDisposable`. The controller calls `await using var rdr = await _factory.OpenAsync(...)` — the connection is returned to the pool when the `using` block exits, whether the request succeeds or throws. No connection is held open between requests.

```
HTTP request arrives
  -> QueryController action
       await using var rdr = await _factory.OpenAsync(jobName, ct);
           // pool gives a ready ReadOnly connection
       await ReadResultsAsync(rdr.Connection, ...)
  -> action returns / throws
       rdr.DisposeAsync()  ->  connection returned to pool
```

#### Job departure safety

The worker and query processes are isolated. When the worker disposes a shard (job departure, STR-008), it closes only its **read-write** connection; the query process's **read-only** pool connections are separate file handles in WAL mode and are unaffected. A reader mid-query completes its snapshot read and then returns its connection to the pool. No cross-process synchronisation is required.

If the shard file itself is removed from disk after departure (e.g. job folder deleted), the query process will encounter a `SqliteException` on the next `OpenAsync` call for that shard. `ShardReaderFactory` catches this and throws `ShardUnavailableException`; `QueryController` maps it to HTTP 503.

#### `JobDiscoveryService` race on deregistration

There is a window between `JobDiscoveryService` removing a shard from its snapshot (on the 30 s poll) and a concurrent in-flight request that already resolved `dbPath` but has not yet opened its connection. This is harmless: the in-flight request opens the (still-present) file and completes normally. The next request after deregistration will get a 404 (`ShardNotFoundException` from `ResolveShardPath` returning `null`).

#### Exception → HTTP status mapping

| Exception | Cause | HTTP status |
|---|---|---|
| `ShardNotFoundException` | `JobDiscoveryService` has no record of `jobName` | 404 Not Found |
| `ShardUnavailableException` | `SqliteException` opening the file | 503 Service Unavailable |
| `OperationCanceledException` | Client disconnected | 499 / cancelled |
| Any other | Unexpected | 500 (ProblemDetails) |

---

## 9. Risks of the Multi-hosted Choice and Mitigations

| Risk | Mitigation |
|---|---|
| Two services to install / monitor | `install.ps1` installs both with `Depend=` ordering; uninstall removes both atomically. Operator runbook documents that "service down" means both must be checked. |
| Version skew between worker and query (e.g. schema migration applied by worker that query has not been redeployed for) | Both binaries reference the same `FalconAuditService.Core.dll`; MSI/installer pins matched versions. `SchemaMigrator` only ever adds nullable columns or new tables; query uses defensive `SELECT col1, col2, …` (never `SELECT *`). Read-only query against a newer schema is safe. |
| FSW-before-catch-up (SVC-003) seems split across processes | It is not — both the FSW and the catch-up live in the **worker** process. The query process plays no role in SVC-003. |
| Two log destinations to correlate | Both processes log to `C:\bis\auditlog\logs\` with file prefixes `worker-` and `query-`. Each log line carries a `MachineName` + `ProcessName` field. |
| Loopback-only API still needs auth eventually | Out of scope for v1; future work would put the auth middleware in the query process only — no worker change needed. |
| Job manifest written by worker, read by query, race on `File.Move(tmp, dest, overwrite: true)` | `ManifestManager` always uses temp-file rename; readers retry once on `IOException` with 50 ms back-off. |

---

## 10. Solution Layout

```
FalconAuditService.sln
├── src/
│   ├── FalconAuditService.Core/             # shared library
│   │   ├── Classification/
│   │   ├── Manifest/
│   │   ├── Sqlite/
│   │   ├── Models/                          # DTOs, ClassifiedEvent, etc.
│   │   └── Abstractions/                    # interfaces, IClock, IFileSystem
│   ├── FalconAuditWorker/                   # writer process
│   │   ├── Hosting/AuditHost.cs
│   │   ├── Monitor/FileMonitor.cs
│   │   ├── Monitor/EventDebouncer.cs
│   │   ├── Jobs/DirectoryWatcher.cs
│   │   ├── Jobs/JobLifecycleHandler.cs
│   │   ├── Recording/EventRecorder.cs
│   │   ├── Recording/HashService.cs
│   │   ├── Recording/DiffPlexDiffBuilder.cs
│   │   ├── Storage/ShardRegistryRw.cs
│   │   ├── CatchUp/CatchUpCoordinator.cs
│   │   ├── CatchUp/CatchUpScanner.cs
│   │   ├── Classification/RulesFileWatcher.cs
│   │   ├── Program.cs
│   │   └── appsettings.json
│   └── FalconAuditQuery/                    # reader process
│       ├── Hosting/JobDiscoveryHostedService.cs
│       ├── Discovery/JobDiscoveryService.cs
│       ├── Storage/ShardReaderFactory.cs
│       ├── Api/QueryController.cs
│       ├── Api/EventQueryBuilder.cs
│       ├── Api/RelFilepathConstraint.cs
│       ├── Program.cs
│       └── appsettings.json
├── tests/
│   ├── FalconAuditService.Core.Tests/
│   ├── FalconAuditWorker.Tests/
│   ├── FalconAuditQuery.Tests/
│   └── FalconAuditService.Integration.Tests/
└── deploy/
    ├── install.ps1
    └── uninstall.ps1
```

---

## 11. Summary

The multi-hosted architecture cleanly separates the audit-recording trust boundary (worker, write-only) from the analyst-query surface (query, read-only). It satisfies every requirement in the SVC, MON, CLS, REC, STR, JOB, MFT, CUS, and API groups, and meets all five PERF targets. The principal trade-offs — two services to install, two CLR images in memory — are acceptable on Falcon-class hardware and are repaid in crash isolation, query-load isolation, and a smaller writer attack surface.

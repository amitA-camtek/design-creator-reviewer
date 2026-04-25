# FalconAuditService — Architecture Design

**Document basis:** ERS-FAU-001 v1.0 (`engineering_requirements.md`)
**Approved alternative:** Embedded .NET 6 Worker with Per-Job SQLite Shards
**Date:** 2026-04-25

---

## 1. High-Level Topology

A single .NET 6 Windows Service process named `FalconAuditService` hosts:

1. The `BackgroundService` worker that owns the file-monitoring pipeline.
2. An in-process ASP.NET Core Kestrel host that serves the read-only Query API on `127.0.0.1:5100`.

There are no out-of-process dependencies beyond the local NTFS filesystem.

```
+-----------------------------------------------------------------+
|                  FalconAuditService (process)                   |
|                                                                 |
|  +------------------+        +-------------------------------+  |
|  | DirectoryWatcher |------->| JobManager                    |  |
|  |  (depth-1 FSW)   |        |  - ManifestManager            |  |
|  +------------------+        |  - ShardRegistry.GetOrCreate  |  |
|                              |  - CatchUpScanner (per job)   |  |
|                              +--------------+----------------+  |
|                                             |                   |
|  +------------------+   Channel    +--------v----------+        |
|  | FileMonitor      |------------->| EventRecorder     |        |
|  |  - recursive FSW |  events      |  - SHA-256 (3x)   |        |
|  |  - 500 ms        |              |  - DiffPlex       |        |
|  |    debounce      |              |  - FileClassifier |        |
|  +------------------+              +---------+---------+        |
|                                              |                  |
|                                  +-----------v-----------+      |
|                                  | ShardRegistry         |      |
|                                  | (ConcurrentDictionary)|      |
|                                  +-----------+-----------+      |
|                                              |                  |
|                                  +-----------v-----------+      |
|                                  | SqliteRepository (n)  |      |
|                                  |  WAL, sync=NORMAL     |      |
|                                  |  SemaphoreSlim(1)     |      |
|                                  +-----------+-----------+      |
|                                              |                  |
|  +------------------------+                  |                  |
|  | FileClassifier         |  reads rules     |                  |
|  | + RulesLoader (FSW)    |                  |                  |
|  +------------------------+                  |                  |
|                                              |                  |
|  +-------------------------+  ReadOnly       |                  |
|  | Kestrel + QueryController|<---------------+                  |
|  | + JobDiscoveryService    |                                   |
|  +-------------------------+                                    |
+-----------------------------------------------------------------+
                |                                |
       127.0.0.1:5100                  c:\job\<JobName>\.audit\
                                         audit.db, manifest.json
                                       C:\bis\auditlog\global.db
                                       C:\bis\auditlog\
                                         FileClassificationRules.json
                                         logs\
```

---

## 2. Components

| # | Component | Type | Responsibility | Requirement Group |
|---|---|---|---|---|
| 1 | `FalconAuditWorker` | `BackgroundService` | Hosts the pipeline, sequences startup, handles graceful shutdown | SVC |
| 2 | `FileMonitor` | Singleton service | Recursive FSW on watch root with 64 KB buffer; per-path 500 ms debounce; pushes events to channel | MON |
| 3 | `DirectoryWatcher` | Singleton service | Depth-1 FSW on watch root; raises `JobArrived` / `JobDeparted` | JOB |
| 4 | `JobManager` | Singleton service | Handles arrival/departure: manifest, shard, catchup | JOB, MFT |
| 5 | `FileClassifier` | Singleton service | Pre-compiled rules; `Classify(absolutePath)` returns module/owner/priority | CLS |
| 6 | `ClassificationRulesLoader` | Singleton service | Loads + compiles rules; secondary FSW on rules file; atomic swap via `Interlocked.Exchange` on `ImmutableList<CompiledRule>` | CLS |
| 7 | `EventRecorder` | Singleton consumer | Consumes channel; computes SHA-256 (retry 3x/100 ms); reads baseline; computes diff; writes `audit_log` row | REC |
| 8 | `SqliteRepository` | Per-shard | Owns one SqliteConnection in WAL mode + `synchronous=NORMAL`; serialises writes via `SemaphoreSlim(1)`; ensures schema | STR |
| 9 | `ShardRegistry` | Singleton service | `ConcurrentDictionary<string, SqliteRepository>`; lazy GetOrCreate; Dispose on departure (within 5 s) | STR |
| 10 | `ManifestManager` | Singleton service | Atomic JSON manifest writes (temp + `File.Move(... overwrite: true)`) | MFT |
| 11 | `CatchUpScanner` | Transient | Reconciles disk vs `file_baselines`; emits Created/Modified/Deleted; one Task per job in parallel; yields if queue depth > 50 | CUS |
| 12 | `QueryController` | ASP.NET Core controllers | Read-only endpoints; uses `QueryRepository` only | API |
| 13 | `QueryRepository` | Per-request | Opens SQLite with `Mode=ReadOnly`; parameterised queries only; pagination via LIMIT/OFFSET | API |
| 14 | `JobDiscoveryService` | `IHostedService` | Initial scan + 30-second timer; tracks set of available shards for the API | API |
| 15 | `MonitorOptions` | `IOptions<MonitorOptions>` | Strongly typed bind of `monitor_config` section | INS |

---

## 3. Communication Patterns

| Source | Sink | Mechanism | Notes |
|---|---|---|---|
| `FileSystemWatcher` (file pipeline) | `FileMonitor` | Event handler (`Changed/Created/Deleted/Renamed/Error`) | Buffer 65 536 bytes (MON-002) |
| `FileMonitor` | `EventRecorder` | `Channel<FileChangeEvent>` (bounded, capacity = 1024) | Decouples FSW callback from work |
| `DirectoryWatcher` | `JobManager` | Direct method call (in-process event handler) | Synchronous on a small Task |
| `JobManager` | `ManifestManager`, `ShardRegistry`, `CatchUpScanner` | Direct method call | All in-process |
| `FileClassifier` rules file FSW | `ClassificationRulesLoader.Reload()` | Event handler with 200 ms cooldown | Hot reload < 2 s (PERF-003) |
| `QueryController` | `QueryRepository` | DI-injected per-request | Each request opens its own ReadOnly connection |
| `JobDiscoveryService` | `QueryRepository` | Shared `ConcurrentDictionary<string, string>` (jobName -> dbPath) | Refreshed every 30 s (API-007) |

---

## 4. Concurrency Model

| Concern | Mechanism |
|---|---|
| FSW callbacks | Non-blocking; the only work done synchronously is debounce timer reset and `Channel.Writer.TryWrite`. |
| Per-path debounce | `ConcurrentDictionary<string, CancellationTokenSource>` — each `Changed` event cancels the prior CTS for that path and schedules a new 500 ms `Task.Delay`. |
| Event recording | Single (or N=Environment.ProcessorCount) consumer Tasks reading from `Channel.Reader.ReadAllAsync(ct)`. Per-shard `SemaphoreSlim(1)` guarantees only one writer per shard. |
| Rule hot-swap | `Interlocked.Exchange(ref _rules, newCompiledList)` where `_rules` is a non-readonly `ImmutableList<CompiledRule>` field. Classification reads a local copy first, so swaps are wait-free for readers. |
| CatchUpScanner parallelism | `Task.WhenAll` over jobs, but each job's enumeration `await`s queue-depth threshold (default 50) before continuing — `await Task.Yield()` if exceeded. |
| Shard disposal | `JobManager.OnJobDeparted` posts to a serialised disposal queue to ensure the in-flight events for that shard drain first. Hard deadline 5 s (STR-008). |

### Failure handling
- Unhandled exceptions in the consumer pipeline are caught at the per-event boundary (try/catch around `EventRecorder.HandleAsync`), logged via Serilog, and the loop continues — never terminate the process (SVC-005).
- FSW `Error` event triggers `CatchUpScanner.RunAsync(jobPath: null)` (MON-005).
- Shard open failure is logged and skipped — other jobs continue (REL-007).

---

## 5. Startup Sequence

1. Read configuration (`appsettings.json`); bind `MonitorOptions`.
2. Initialise Serilog (rolling file at `C:\bis\auditlog\logs\` + Windows Event Log) (INS-005).
3. `ClassificationRulesLoader.LoadInitial()` — compile rules, install rule-file FSW.
4. `JobDiscoveryService.InitialScan()` — populate the API's known-shard set.
5. `FileMonitor.Start()` — register the recursive FSW on `c:\job\` (MUST complete before step 6 — SVC-003, PERF-001).
6. `JobManager.OnStartup()` — enumerate existing job folders; for each, `RecordArrival → GetOrCreateShard → CatchUpScanner` (in parallel) (JOB-005, SVC-007).
7. Start ASP.NET Core Kestrel host bound to `127.0.0.1:5100` (or configured value).
8. Service ready; consumer loop and FSW callbacks running.

Steps 5 and 6 run as parallel tasks but step 5 must REGISTER (not necessarily finish processing live events) before step 6 starts so that no live events are missed.

## 6. Shutdown Sequence (`StopAsync`)

1. Stop accepting new HTTP requests (Kestrel graceful shutdown).
2. Stop `DirectoryWatcher` and `FileMonitor` FSWs.
3. `Channel.Writer.Complete()`.
4. Drain consumers — wait for in-flight `EventRecorder` work to finish (with 10 s timeout).
5. For every open shard: `ManifestManager.RecordDeparture(jobPath)`.
6. Dispose every `SqliteRepository` (`SemaphoreSlim`, `SqliteConnection`).
7. Flush Serilog.

(SVC-004)

---

## 7. Component Dependency Graph (implementation order)

Leaf → root (ascending dependency depth). Implement each component **after** its dependencies.

```
Leaf:
  MonitorOptions
  ManifestModels
  CompiledRule / FileClassificationRule
  FileChangeEvent
  AuditEvent / FileBaseline DTOs

Level 1 (depend only on leaves):
  ClassificationRulesLoader        (depends on CompiledRule)
  ManifestManager                  (depends on ManifestModels)
  SqliteRepository                 (depends on AuditEvent, FileBaseline)

Level 2:
  FileClassifier                   (depends on ClassificationRulesLoader)
  ShardRegistry                    (depends on SqliteRepository)
  QueryRepository                  (read-only sibling of SqliteRepository)

Level 3:
  EventRecorder                    (depends on FileClassifier, ShardRegistry, ManifestManager)
  CatchUpScanner                   (depends on ShardRegistry, FileClassifier, EventRecorder)
  JobDiscoveryService              (depends on QueryRepository)
  QueryController                  (depends on QueryRepository, JobDiscoveryService)

Level 4:
  FileMonitor                      (writes to Channel<FileChangeEvent>)
  DirectoryWatcher                 (raises JobArrived/JobDeparted)
  JobManager                       (depends on ManifestManager, ShardRegistry, CatchUpScanner)

Root:
  FalconAuditWorker (BackgroundService)  — orchestrates everything
  Program.cs / Host                      — DI registration, Kestrel config
```

---

## 8. Deployment

### Packaging
- `dotnet publish src/FalconAuditService -c Release -r win-x64` (framework-dependent unless target lacks .NET 6 — then `--self-contained true`).
- Output: `C:\Program Files\Camtek\FalconAuditService\` containing `FalconAuditService.exe`, `appsettings.json`, default `FileClassificationRules.json`, and dependency DLLs.

### Configuration management
- All runtime tuning lives in `appsettings.json` under `monitor_config` (INS-002). Changes require service restart (INS-004) except `FileClassificationRules.json` which hot-reloads (CLS-005).

### Startup sequence (Windows Service host)
1. SCM starts `FalconAuditService.exe`.
2. `Program.cs` builds the host (`Host.CreateDefaultBuilder().UseWindowsService()`).
3. DI container registers all components from §2 as singletons (per-request for `QueryRepository`).
4. `IHostedService` instances start in registration order; `FalconAuditWorker` runs the startup sequence from §5.
5. Kestrel starts and binds.
6. SCM receives `SERVICE_RUNNING`.

### install.ps1 responsibilities (INS-001)
1. Create `C:\bis\auditlog\` and `C:\bis\auditlog\logs\`.
2. Copy default `FileClassificationRules.json` if absent.
3. Register Windows Event Log source `FalconAuditService`.
4. `sc.exe create FalconAuditService binPath= "C:\Program Files\Camtek\FalconAuditService\FalconAuditService.exe" start= auto DisplayName= "Falcon Audit Service"`.
5. `sc.exe failure FalconAuditService reset= 86400 actions= restart/5000/restart/15000/restart/60000`.
6. `sc.exe start FalconAuditService`.

---

## 9. Cross-Cutting Concerns

| Concern | Implementation |
|---|---|
| Logging | Serilog. Sinks: rolling file (`C:\bis\auditlog\logs\falconaudit-.log`, day-roll, 31-day retention) + Windows Event Log (source `FalconAuditService`). Structured properties always include `JobName`, `FilePath`, `EventId`. |
| Configuration | `IOptionsMonitor<MonitorOptions>` for accessors that benefit from change detection (rules path); `IOptions<MonitorOptions>` for the rest. |
| Time | `IClock` abstraction backed by `SystemClock` (returns `DateTime.UtcNow`); replaced by `FrozenClock` in tests. |
| Machine identity | `Environment.MachineName` captured at startup into `IMachineNameProvider`. |
| Cancellation | All async work accepts the `BackgroundService.StoppingToken`. |
| Health | `GET /health` returns `{ status: "ok", uptimeSeconds, watcherActive, shardsOpen }`. |

---

## 10. Mapping to Requirements

| Component | Satisfies (mandatory IDs) |
|---|---|
| `FalconAuditWorker` | SVC-001, SVC-002, SVC-004, SVC-005 |
| `FileMonitor` | MON-001, MON-002, MON-003, MON-004, MON-005, MON-006, SVC-003, SVC-006, PERF-001 |
| `FileClassifier` + `ClassificationRulesLoader` | CLS-001, CLS-002, CLS-003, CLS-004, CLS-005, CLS-006, CLS-007, CLS-008, REL-006, PERF-003 |
| `EventRecorder` | REC-001 to REC-009, PERF-002 |
| `SqliteRepository` + `ShardRegistry` | STR-001 to STR-008, REL-001, REL-004, REL-005, REL-007 |
| `DirectoryWatcher` + `JobManager` | JOB-001 to JOB-007 |
| `ManifestManager` | MFT-001 to MFT-008, REL-003 |
| `CatchUpScanner` | CUS-001 to CUS-006, REL-002, PERF-004, SVC-007 |
| `QueryController` + `QueryRepository` + `JobDiscoveryService` | API-001 to API-009, REL-004, PERF-005 |
| `MonitorOptions` + `install.ps1` | INS-001 to INS-005 |

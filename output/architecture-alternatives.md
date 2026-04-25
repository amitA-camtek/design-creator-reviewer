# FalconAuditService — Architecture Alternatives

| Field | Value |
|---|---|
| Document | architecture-alternatives.md |
| Phase | 1 — Alternatives |
| Source | `req.md`, `engineering_requirements.md` (ERS-FAU-001), `FileClassificationRules.json`, `02_file_summary.md` |
| Target | .NET 6 Windows Service running on Falcon machines (Win10/Server2019 64-bit) |
| Date | 2026-04-25 |

---

## 1. Context Recap

The service must:

- Watch `c:\job\` recursively for **Create / Modify / Delete** events on files classified P1 and P2 by `FileClassificationRules.json`.
- For **P1**: record full content snapshot + SHA-256 + unified diff. For **P2**: SHA-256 only.
- Persist to **local SQLite** (no server) and survive a reboot — auto-resume monitoring.
- Avoid file-locking and high CPU on the inspection PC.
- Register the FSW **before** any catch-up reconciliation (SVC-003) and be live within 600 ms (PERF-001).
- Honour per-job shard isolation (`<job>\.audit\audit.db`) plus a `global.db` for files under `c:\job\` directly.
- Expose a read-only HTTP query API on port 5100 (loopback default).

The architectural decision is **how to compose the moving parts**: monitor pipeline, classifier, recorder, shard registry, manifest manager, catch-up scanner, job lifecycle watcher, and HTTP API host.

---

## 2. Common Building Blocks

All three alternatives share these logical components (only their *composition* differs):

- `FileMonitor` — recursive `FileSystemWatcher` + per-path 500 ms debounce.
- `DirectoryWatcher` — depth-1 FSW for job arrival/departure.
- `FileClassifier` + `ClassificationRulesLoader` — hot-reloadable rule list.
- `EventRecorder` — hash, diff, write to shard.
- `ShardRegistry` + `SqliteRepository` — per-job WAL DB.
- `ManifestManager` — atomic JSON manifest writer.
- `CatchUpScanner` — startup + on-arrival reconciliation.
- `QueryController` + `JobDiscoveryService` — Kestrel HTTP read API.

---

## 3. Alternative A — Monolithic Single Pipeline

### 3.1 Shape

A single `BackgroundService` (`AuditWorker`) directly owns every component as private fields. One in-process `BlockingCollection<RawFsEvent>` queue feeds a single consumer loop that runs classification → debounce → recording → manifest update inline. The HTTP API runs in the same process but bootstraps the same `AuditWorker` singletons via property accessors rather than DI.

```
                   AuditWorker (BackgroundService)
   +-------------------------------------------------------+
   |  FileSystemWatcher  ->  Channel<RawFsEvent>           |
   |          |                       |                    |
   |   DirectoryWatcher              ConsumerLoop          |
   |          |              (debounce -> classify ->      |
   |          v               record -> manifest)          |
   |   ShardRegistry  ----  SqliteRepository (per job)     |
   |   ManifestManager                                     |
   |   CatchUpScanner (Task.Run on start + on arrival)     |
   +-------------------------------------------------------+
                          |
              Kestrel pipeline (same process)
                  QueryController -> ShardRegistry (read-only conn)
```

### 3.2 Threading

- 1 producer thread (FSW callback).
- 1 consumer task (single sequential pipeline).
- N transient `Task`s for parallel `CatchUpScanner` per job (SVC-007).
- Kestrel thread pool for HTTP.

### 3.3 DI strategy

Minimal. `Program.cs` `new`s the worker; only `IConfiguration`, `ILogger`, and the rules path go through `IServiceCollection`. Components reference each other through concrete fields.

### 3.4 Pros / Cons

| Aspect | Score | Notes |
|---|---|---|
| Lines of plumbing code | Lowest | One class wires everything. |
| Cold-start latency | Lowest | No DI graph to resolve before FSW registration. |
| **SVC-003 risk** | **Low** | Trivial to register FSW first because the worker controls ordering directly. |
| Testability | **Low** | Components are not interfaces; you cannot swap the recorder for a fake without touching `AuditWorker`. |
| Concurrency hazards | Medium | One queue, one consumer means no contention but also no parallelism for slow shard writes. A hung write blocks all events. |
| Maintenance | Low–Medium | Adding a feature (e.g. a metrics emitter) means modifying the central worker; risk of god-class drift. |
| Fits requirement set | Partial | Meets functional needs but PERF-002 (1 s per P1 event) is at risk under load because all writes serialise through one consumer even though shards are independent. |

### 3.5 When to pick

You expect ≤3 jobs at a time, you optimise for least code, and the team accepts that integration tests must spin the whole worker.

---

## 4. Alternative B — Cooperating Components with DI (Recommended)

### 4.1 Shape

Each logical block is an `internal sealed class` registered against an interface in `Program.cs`. The `BackgroundService` (`AuditHost`) is thin: it resolves `IFileMonitor`, `IDirectoryWatcher`, `ICatchUpCoordinator`, and `IApiHost`, then orchestrates start order. Inter-component communication uses a bounded `Channel<ClassifiedEvent>` per shard owned by the `ShardRegistry`, and a single `Channel<RawFsEvent>` between the FSW and classifier.

```
+------------------- AuditHost (BackgroundService) ---------------------+
|                                                                      |
|  IFileMonitor --(RawFsEvent)--> IFileClassifier                      |
|       ^                                |                             |
|       | (raw)                          v (ClassifiedEvent)           |
|  FileSystemWatcher              IShardRouter ---+                    |
|                                                 |                    |
|  IDirectoryWatcher --(JobArrival/Departure)-->  |                    |
|        |                                        v                    |
|        +--> IJobLifecycle --> IShardRegistry --> IEventRecorder      |
|                                  |  (per shard SemaphoreSlim,        |
|                                  |   per shard Channel,              |
|                                  |   1 writer Task per shard)        |
|                                  v                                   |
|                           ISqliteRepository  +  IManifestManager     |
|                                                                      |
|  ICatchUpCoordinator --> spawns CatchUpScanner Task per job          |
|                                                                      |
|  IApiHost (Kestrel) -- ASP.NET pipeline -- QueryController           |
|         (uses IShardRegistry in read-only mode + IJobDiscoveryService)|
+----------------------------------------------------------------------+
```

### 4.2 Threading

- FSW thread → classifier (synchronous, fast — just a regex lookup).
- Classifier → per-shard `Channel<ClassifiedEvent>` (bounded, default 1024).
- One **dedicated writer Task per shard**, gated by its own `SemaphoreSlim(1)` (STR-005, REL-005). Slow shard ≠ stalled service.
- N parallel `CatchUpScanner` Tasks (SVC-007).
- Kestrel thread pool for HTTP, reads use `Mode=ReadOnly`.

### 4.3 DI strategy

Standard `Microsoft.Extensions.DependencyInjection`:

- Singletons: `IClassificationRulesLoader`, `IFileClassifier`, `IShardRegistry`, `IJobDiscoveryService`, `IManifestManager`, `IFileMonitor`, `IDirectoryWatcher`.
- Scoped (per HTTP request): controllers and the read-only repository handle.
- Options: `IOptionsMonitor<MonitorConfig>` for `monitor_config` block.

The `AuditHost.StartAsync` enforces the contract: **call `IFileMonitor.StartAsync` and await `WatcherReady` before invoking `ICatchUpCoordinator.RunAllAsync`** — this is the SVC-003 guarantee captured in code, not just convention.

### 4.4 Pros / Cons

| Aspect | Score | Notes |
|---|---|---|
| Testability | **High** | Every collaborator is an interface; unit tests fake `ISqliteRepository`, `IClock`, `IFileSystem`. |
| **SVC-003 risk** | **Low** | Start order encoded as an awaited contract in `AuditHost`. |
| Per-shard parallelism | **Yes** | One writer per shard means a stuck I/O on Job A does not freeze Job B. Helps PERF-002. |
| DI complexity | Medium | ~12 registrations in `Program.cs`; readable, but requires discipline. |
| Memory overhead | Medium | One Channel + one Task per shard. With 10 jobs × 1024-slot channel ≈ negligible. |
| Maintenance | High | Adding a new sink (e.g. OpenTelemetry exporter) is a new interface registration. |
| Fits requirement set | **Full** | All 62 requirements map cleanly onto a component. |

### 4.5 When to pick

This is the recommended default for FalconAuditService. It is the only alternative that lets the writer-per-shard parallelism survive without changing the public surface.

---

## 5. Alternative C — Multi-hosted (Out-of-process API + Worker)

### 5.1 Shape

Two Windows processes:

1. **`FalconAuditWorker.exe`** — the BackgroundService that owns FSW, shards, manifest, and catch-up.
2. **`FalconAuditQuery.exe`** — a separate ASP.NET Core process that opens shards in `Mode=ReadOnly` only.

They communicate through the file system: the worker writes shards under `c:\job\<j>\.audit\` and `C:\bis\auditlog\global.db`; the query process discovers them via the same `JobDiscoveryService` logic. There is no IPC channel between them — SQLite WAL provides the read/write isolation (REL-004).

```
[FalconAuditWorker.exe]                 [FalconAuditQuery.exe]
+----------------------+                +-----------------------+
| FileMonitor          |                | JobDiscoveryService   |
| Classifier           |                | QueryController       |
| EventRecorder        |   (no IPC)     | Kestrel :5100         |
| ShardRegistry (rw)   |                | SqliteRepo (RO only)  |
| ManifestManager      |                +-----------|-----------+
| CatchUpScanner       |                            |
+--------|-------------+                            |
         v                                          v
   c:\job\<j>\.audit\audit.db  <----- WAL-mode reads
   C:\bis\auditlog\global.db
```

### 5.2 Threading

Same as Alt B inside each process, but the API process has no writer Tasks and no `SemaphoreSlim(1)` because it never writes.

### 5.3 DI strategy

Two `Program.cs` files. The shared interfaces and DTOs live in a `FalconAuditService.Core` class library referenced by both.

### 5.4 Pros / Cons

| Aspect | Score | Notes |
|---|---|---|
| Process isolation | **High** | An API crash (e.g. malformed query) cannot kill the writer. Audit recording keeps going. |
| **SVC-003 risk** | **Medium** | The worker process owns FSW first-registration. **But** install/start order matters: both services must be auto-start, and a failed query process leaves users thinking the service is down. |
| Read load isolation | High | Heavy API queries cannot starve writer threads. |
| Operational complexity | High | Two services to install, monitor, and version-pin. `install.ps1` becomes more elaborate. |
| Boot latency for FSW | Slightly worse | The worker now owns FSW alone, which is fine, but coordinating two services adds risk. |
| Memory footprint | Higher | Two CLR processes, two Kestrel/runtime images. |
| DI complexity | Medium-High | Two graphs to maintain in lock-step. |
| Maintenance | Medium | Install scripts, two log paths, two PIDs in Event Viewer. |
| Fits requirement set | Full but heavier | Meets all requirements; the `BackgroundService`-only wording in SVC-001 still fits the worker process. |

### 5.5 When to pick

You expect heavy concurrent API load (multiple analyst dashboards) and operational maturity to manage two services.

---

## 6. Comparison Matrix

| Dimension | Alt A — Monolithic | Alt B — Cooperating (Rec.) | Alt C — Multi-hosted |
|---|---|---|---|
| Testability | Low | **High** | High |
| DI complexity | Low | Medium | Medium-High |
| SVC-003 risk | Low | **Low** | Medium |
| Per-shard write parallelism | No | **Yes** | Yes |
| Crash isolation (API ↔ writer) | No | No | **Yes** |
| Maintenance burden | Low–Medium | Medium | Medium-High |
| Operational footprint | 1 service | 1 service | 2 services |
| Cold-start to FSW live | Fastest | Fast (≤ 600 ms) | Fast in worker |
| Best fit for ERS-FAU-001 | Partial | **Full** | Full but heavier |
| **Recommended** | | **Yes** | |

---

## 7. Recommendation

**Adopt Alternative B — Cooperating Components with DI.**

It is the only option that simultaneously delivers:

1. The mandatory FSW-before-catch-up contract (SVC-003) encoded as an awaited start-order in `AuditHost`.
2. Per-shard writer parallelism, which is what makes PERF-002 (1 s per P1 event) safe under multi-job load.
3. Clean unit-test seams without paying the operational tax of running two services.

Alt A is acceptable only if the team commits to staying single-job in the field; Alt C is overkill until query load demonstrably starves the writer.

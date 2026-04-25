# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**FalconAuditService** is a Windows Service (.NET 6) that monitors `c:\job\` on Falcon inspection machines and records tamper-evident audit logs of configuration and recipe file changes. It stores per-job SQLite shards, maintains a chain-of-custody manifest, and exposes a read-only HTTP query API.

The authoritative specification is [engineering_requirements.md](engineering_requirements.md) (Document ID: ERS-FAU-001). All 62 requirements there are mandatory unless marked Priority `L`. This codebase is greenfield — the requirements doc precedes any code.

---

## Build, Run, and Test

Once scaffolded as a .NET 6 solution:

```bash
# Build
dotnet build

# Run in development (not as a Windows Service)
dotnet run --project src/FalconAuditService

# Run all tests
dotnet test

# Run a single test by name filter
dotnet test --filter "FullyQualifiedName~DebounceTest"

# Install as Windows Service (run as Administrator)
powershell -ExecutionPolicy Bypass -File install.ps1

# Service management
sc.exe start FalconAuditService
sc.exe stop FalconAuditService
sc.exe query FalconAuditService
```

---

## Architecture

The service is composed of these cooperating components (requirement group in parentheses):

### Service host
`BackgroundService` (`SVC`) — hosts all components. Must register the `FileSystemWatcher` **before** starting `CatchUpScanner` to avoid missing live events during startup reconciliation (SVC-003). FSW must be live within 600 ms of process start (PERF-001).

### File monitoring pipeline
`FileMonitor` (`MON`) — recursive `FileSystemWatcher` on `c:\job\` with 64 KB buffer. Debounces events per file path over a 500 ms window (one `CancellationTokenSource` per path). On FSW buffer-overflow error, triggers a full `CatchUpScanner`.

### File classification
`FileClassifier` / `ClassificationRulesLoader` (`CLS`) — loads rules from `FileClassificationRules.json`. Rules are evaluated in declaration order; first match wins; fallback is `P3/Unknown/Unknown`. Glob patterns are compiled to `Regex` at load time (never per-event). Hot-reload is atomic via `Interlocked.Exchange` on an `ImmutableList<CompiledRule>`. A secondary FSW watches the rules file and reloads within 2 seconds. Invalid JSON on reload retains the previous rule set.

### Event recording
`EventRecorder` (`REC`) — given a classified file-change event, computes SHA-256 (retry 3× with 100 ms delay), reads `old_content` from `file_baselines`, generates unified diff with DiffPlex (`UnifiedDiffBuilder`), and writes to the shard. P1 = full content + hash + diff; P2/P3 = hash only; P4 = warning log, no DB row.

### Storage / shard registry
`SqliteRepository` + `ShardRegistry` (`STR`) — `ConcurrentDictionary<string, SqliteRepository>` keyed by job name. Each shard uses WAL mode + `synchronous=NORMAL`. Writes are serialized per-shard via `SemaphoreSlim(1)`. The global DB at `C:\bis\auditlog\global.db` handles files directly under `c:\job\`. Shards are disposed within 5 s of job departure.

### Job lifecycle
`DirectoryWatcher` + `JobManager` (`JOB`) — depth-1 FSW on `c:\job\` watching for job folder arrivals/departures. On arrival: call `ManifestManager.RecordArrival()` → `ShardRegistry.GetOrCreate()` → scoped `CatchUpScanner`. On departure: `ManifestManager.RecordDeparture()` → dispose shard.

### Chain-of-custody manifest
`ManifestManager` (`MFT`) — reads/writes `<jobFolder>\.audit\manifest.json`. Writes are always atomic via temp-file rename (`File.Move(tmp, dest, overwrite: true)`). Records machine custody history with arrival/departure timestamps and per-machine event counts.

### Catch-up scanner
`CatchUpScanner` (`CUS`) — reconciles on-disk files against `file_baselines`. Emits `Created` for new files, `Modified` for hash-changed files, `Deleted` for missing baselines. Runs one `Task` per job in parallel. Yields if event queue depth exceeds 50 (configurable) to avoid starving live event processing.

### Query API
`QueryController` + `JobDiscoveryService` (`API`) — ASP.NET Core Kestrel on port 5100 (loopback by default). All SQL connections use `Mode=ReadOnly`. `JobDiscoveryService` scans `c:\job\*\.audit\audit.db` at startup and every 30 seconds. The `rel_filepath` parameter is validated against `^[\w\-. \\/]+$` before SQL use (API-008). `old_content`/`diff_text` are returned only by the single-event endpoint.

---

## Data Layout

```
c:\job\
├── <JobName>\
│   ├── [monitored files]
│   └── .audit\
│       ├── audit.db       # per-job SQLite shard
│       └── manifest.json  # chain-of-custody history

C:\bis\auditlog\
├── global.db                    # events for files directly under c:\job\
├── FileClassificationRules.json # hot-reloaded classification config
└── logs\                        # rolling Serilog files
```

### Key tables (per shard)

**`audit_log`**: `changed_at`, `event_type`, `filepath`, `rel_filepath`, `module`, `owner_service`, `monitor_priority`, `machine_name`, `sha256_hash`, `old_content` (P1 only), `diff_text` (P1 only)

**`file_baselines`**: `filepath`, `last_hash`, `last_seen` — one row per tracked file; updated on every processed event; used by `CatchUpScanner` and diff generation.

---

## Configuration (`appsettings.json`)

All settings live under `monitor_config`:

| Key | Default |
|-----|---------|
| `watch_path` | `c:\job\` |
| `global_db_path` | `C:\bis\auditlog\global.db` |
| `classification_rules_path` | `C:\bis\auditlog\FileClassificationRules.json` |
| `api_port` | `5100` |
| `debounce_ms` | `500` |

All require a service restart to take effect except `classification_rules_path` content (hot-reloaded).

---

## Key Constraints

- Target: Windows 10 / Server 2019+ (64-bit), .NET 6 LTS only.
- Database: `Microsoft.Data.Sqlite` — no external DB server.
- The service **must not** write outside `.audit\` subdirectories within `c:\job\`.
- `FileClassificationRules.json` must be strict JSON (no comments) — `System.Text.Json` does not support JSON5.
- Logging: Serilog to rolling files at `C:\bis\auditlog\logs\` and Windows Event Log source `FalconAuditService`.

---

## Performance Targets (from PERF requirements)

| Scenario | Limit |
|----------|-------|
| FSW registered after process start | < 600 ms |
| Single P1 event fully written | < 1 s after debounce fires |
| Rules hot-reload active | < 2 s after file save |
| CatchUpScanner (10 jobs × 150 files, parallel) | < 5 s |
| Paginated API query (50 rows) | < 200 ms |

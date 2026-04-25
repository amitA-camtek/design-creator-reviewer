# Engineering Requirements — FalconAuditService

| Field         | Value |
|---|---|
| Document ID   | ERS-FAU-001 |
| Version       | 1.0 |
| Date          | 2026-04-25 |
| Author        | Camtek Falcon BIS Platform |
| Based on      | `jobMonitorManagmentDesign.md` (Option C — Embedded Shard + Manifest) |
| Status        | Draft |

---

## 1. Purpose and Scope

This document specifies the engineering requirements for **FalconAuditService**, a Windows Service that monitors the `c:\job\` directory on Falcon inspection machines and records a tamper-evident audit log of all configuration and recipe file changes.

**In scope:**
- File monitoring and event recording
- Per-job audit isolation (portable SQLite shards)
- Chain-of-custody manifest
- Configurable file classification rules
- Read-only HTTP query API (self-hosted, no external web server)

**Deployment model:** The system is a **standalone installation** — a single `install.ps1` deploys all components. No IIS, no external database server, and no other runtime dependency is required beyond .NET 6.

**Out of scope:**
- Cross-job query aggregation across machines
- UI frontend (covered separately)
- Falcon application logic (RMS, AOI_Main, DataServer)

---

## 2. Definitions

| Term | Definition |
|---|---|
| **Job folder** | A subdirectory of `c:\job\` representing one inspection job (e.g. `c:\job\Diced_10.0.4511\`) |
| **Shard** | The per-job SQLite database stored at `<jobFolder>\.audit\audit.db` |
| **Manifest** | Human-readable JSON file at `<jobFolder>\.audit\manifest.json` recording machine custody history |
| **P1 file** | Monitored file whose full text content, SHA-256 hash, and unified diff are stored on every change |
| **P2 file** | Monitored file whose SHA-256 hash only is stored on every change |
| **P3 file** | Monitored file whose SHA-256 hash only is stored; lower operational importance |
| **P4 file** | File detected by FSW but not stored; a warning is logged only |
| **CatchUpScanner** | Startup component that reconciles on-disk file state against the last-known DB baselines |
| **ShardRegistry** | In-process cache mapping job names to their `SqliteRepository` instances |
| **DirectoryWatcher** | Depth-1 FileSystemWatcher on `c:\job\` that detects job folder arrivals and departures |
| **FSW** | .NET `FileSystemWatcher` |
| **WAL** | SQLite Write-Ahead Logging journal mode |
| **Debounce** | Suppression of redundant FSW events within a 500 ms window for the same file path |

---

## 3. Requirements

Requirements use the keyword **shall** for mandatory behaviour and **should** for recommended behaviour.  
Priority: **M** = Mandatory, **H** = High, **L** = Low.

---

### 3.1 Service Lifecycle  *(SVC)*

| ID | Priority | Requirement |
|---|---|---|
| SVC-001 | M | The system **shall** be implemented as a .NET 6 Windows Service (`BackgroundService`) installable via `sc.exe` or `install.ps1`. |
| SVC-002 | M | The service **shall** start automatically on Windows boot (start type: Automatic). |
| SVC-003 | M | The service **shall** register the `FileSystemWatcher` on `c:\job\` **before** beginning any `CatchUpScanner` work, so that no live file events are missed during startup reconciliation. |
| SVC-004 | M | On `StopAsync`, the service **shall** call `ManifestManager.RecordDeparture()` for every open shard, flush all pending SQLite writes, and dispose all connections before the process exits. |
| SVC-005 | M | The service **shall** recover from an unhandled exception in the event-processing pipeline by logging the exception and continuing — it **shall not** terminate the process. |
| SVC-006 | H | The service **shall** be ready to process live file events within **600 ms** of process start (FSW registered), regardless of the number of jobs present. |
| SVC-007 | H | All per-job `CatchUpScanner` tasks **shall** run in parallel (one `Task` per job) so that startup reconciliation time is bounded by the slowest single job, not the sum of all jobs. |

---

### 3.2 File Monitoring  *(MON)*

| ID | Priority | Requirement |
|---|---|---|
| MON-001 | M | The service **shall** monitor the directory `c:\job\` and all subdirectories recursively using a `FileSystemWatcher` with `IncludeSubdirectories = true`. |
| MON-002 | M | The FSW internal buffer **shall** be set to **65 536 bytes** (64 KB). |
| MON-003 | M | The service **shall** subscribe to `Created`, `Changed`, `Deleted`, and `Renamed` FSW events. |
| MON-004 | M | The service **shall** debounce FSW events per file path with a **500 ms** timer. If multiple events arrive for the same path within the window, only the final state is processed. |
| MON-005 | M | When the FSW raises an `Error` event (buffer overflow), the service **shall** log a warning and immediately trigger a full `CatchUpScanner` run to recover any missed events. |
| MON-006 | M | The watch path root (`c:\job\`) **shall** be configurable via the `monitor_config` key `watch_path` in `appsettings.json`. |

---

### 3.3 File Classification  *(CLS)*

| ID | Priority | Requirement |
|---|---|---|
| CLS-001 | M | File classification rules **shall** be loaded from an external JSON file `FileClassificationRules.json` at service startup. The file location **shall** default to `C:\bis\auditlog\FileClassificationRules.json` and **shall** be overridable via the `classification_rules_path` config key. |
| CLS-002 | M | The service **shall** support two match types in the rules file: `exact` (case-insensitive full path match) and `glob` (`**` = any depth, `*` = single path segment). |
| CLS-003 | M | Rules **shall** be evaluated in declaration order. The first matching rule wins. |
| CLS-004 | M | If no rule matches, the file **shall** be classified as `module=Unknown`, `ownerService=Unknown`, `monitorPriority=P3`. |
| CLS-005 | M | A secondary `FileSystemWatcher` **shall** watch `FileClassificationRules.json`. On a `Changed` event, the service **shall** reload and recompile all rules within **2 seconds** without a service restart. |
| CLS-006 | M | The rule swap **shall** be atomic. The service **shall** use `Interlocked.Exchange` on an `ImmutableList<CompiledRule>` reference so that in-flight classification calls are never interrupted mid-list. |
| CLS-007 | M | Each rule **shall** carry: `pattern`, `matchType`, `module`, `ownerService`, `monitorPriority`. |
| CLS-008 | H | Glob patterns **shall** be compiled to `Regex` once at load time. Per-event regex compilation is not permitted. |

---

### 3.4 Event Recording  *(REC)*

| ID | Priority | Requirement |
|---|---|---|
| REC-001 | M | For every P1 file change event the service **shall** store: `changed_at` (UTC ISO 8601), `event_type`, `filepath` (absolute), `rel_filepath` (job-relative), `module`, `owner_service`, `monitor_priority`, `machine_name`, `sha256_hash`, `old_content` (text snapshot before change), `diff_text` (unified diff). |
| REC-002 | M | For every P2 and P3 file change event the service **shall** store: all fields listed in REC-001 **except** `old_content` and `diff_text` (left NULL). |
| REC-003 | M | For P4 files the service **shall not** write any row to the database. A `Warning` level structured log entry **shall** be emitted instead. |
| REC-004 | M | `sha256_hash` **shall** be computed using SHA-256 over the raw file bytes. |
| REC-005 | M | `diff_text` **shall** be a unified diff (DiffPlex `UnifiedDiffBuilder`) comparing the previous known content to the new content. |
| REC-006 | M | `machine_name` **shall** be set to `Environment.MachineName` at the time of the write. |
| REC-007 | M | `rel_filepath` **shall** be the file path relative to the job folder root (e.g. `S1\Recipes\R1\Recipe.ini`). For global files (`status.ini`) this field **shall** be the path relative to `c:\job\`. |
| REC-008 | M | The service **shall** also maintain a `file_baselines` table (one row per tracked file path) storing `filepath`, `last_hash`, and `last_seen` timestamp, updated on every processed event. |
| REC-009 | H | Hash computation **shall** retry up to **3 times** with a **100 ms** delay between attempts to tolerate transient file locks held by the writing application. |

---

### 3.5 Storage  *(STR)*

| ID | Priority | Requirement |
|---|---|---|
| STR-001 | M | Each job folder **shall** have its own SQLite database at `<jobFolder>\.audit\audit.db`. |
| STR-002 | M | A single global database **shall** exist at `C:\bis\auditlog\global.db` for events on files directly under `c:\job\` (e.g. `status.ini`). |
| STR-003 | M | All SQLite databases **shall** be opened with `PRAGMA journal_mode = WAL`. |
| STR-004 | M | All SQLite databases **shall** use `PRAGMA synchronous = NORMAL`. |
| STR-005 | M | Write access to each shard **shall** be serialised using a `SemaphoreSlim(1)` dedicated to that shard. Concurrent reads from the query API are permitted without locking (WAL mode guarantees isolation). |
| STR-006 | M | The `.audit\` subdirectory and both database files **shall** be created automatically by the service on first use. No manual pre-creation step is required. |
| STR-007 | H | The `ShardRegistry` **shall** maintain at most one open `SqliteRepository` per job name (lazy creation, cached in a `ConcurrentDictionary`). |
| STR-008 | H | When a job folder departure is detected, the service **shall** dispose the corresponding `SqliteRepository` and remove it from `ShardRegistry` within 5 seconds. |

---

### 3.6 Job Portability  *(JOB)*

| ID | Priority | Requirement |
|---|---|---|
| JOB-001 | M | Moving a job folder (including its `.audit\` subdirectory) from one Falcon machine to another **shall** require zero operator action beyond the folder move itself to preserve the full audit history. |
| JOB-002 | M | A `DirectoryWatcher` **shall** monitor `c:\job\` at depth=1 (direct child folders only) and fire on `Created`, `Deleted`, and `Renamed` events. |
| JOB-003 | M | On detection of a new job folder arrival (JOB-002 `Created` event), the service **shall**: (1) call `ManifestManager.RecordArrival()`, (2) call `ShardRegistry.GetOrCreate()` to open or create the shard, (3) run a scoped `CatchUpScanner` for that job. |
| JOB-004 | M | On detection of a job folder departure (JOB-002 `Deleted` or `Renamed` event), the service **shall** call `ManifestManager.RecordDeparture()` and dispose the corresponding shard. |
| JOB-005 | M | On service startup, the service **shall** enumerate all existing subdirectories of `c:\job\` and apply the arrival sequence (JOB-003) for each one. |
| JOB-006 | M | After a job folder is pasted onto a destination machine, the first live file event within that job **shall** be recorded in the existing shard within **1 second** of the `DirectoryWatcher` firing. |
| JOB-007 | M | The `machine_name` column in every `audit_log` row **shall** record the name of the machine that wrote the row, enabling per-machine filtering of events after a job has moved. |

---

### 3.7 Chain-of-Custody Manifest  *(MFT)*

| ID | Priority | Requirement |
|---|---|---|
| MFT-001 | M | Each job shard **shall** be accompanied by a `manifest.json` file at `<jobFolder>\.audit\manifest.json`. |
| MFT-002 | M | `manifest.json` **shall** record: `jobName`, `auditDbVersion`, `created` (machine + UTC timestamp of first audit event), and a `history` array. |
| MFT-003 | M | Each entry in `history` **shall** contain: `machine` (machine name), `from` (UTC ISO 8601 arrival time), `to` (UTC ISO 8601 departure time, `null` if currently active), `events` (count of `audit_log` rows written by that machine). |
| MFT-004 | M | `manifest.json` **shall** be written atomically: the service **shall** write to `manifest.tmp` in the same directory, then call `File.Move(tmp, manifest.json, overwrite: true)`. Direct overwrite without the temp file is not permitted. |
| MFT-005 | M | `ManifestManager.RecordArrival(jobPath, machineName)` **shall** close the previous machine's history entry (set `to = now`) if it was written by a different machine, and append a new entry for the current machine. |
| MFT-006 | M | `ManifestManager.RecordDeparture(jobPath)` **shall** set `to = now` on the active history entry and record the final event count. |
| MFT-007 | M | The `events` counter in the active manifest entry **shall** be incremented every time a row is successfully inserted into the shard's `audit_log` table. |
| MFT-008 | H | `manifest.json` **shall** be valid JSON readable in any text editor without a database tool. |

---

### 3.8 CatchUpScanner  *(CUS)*

| ID | Priority | Requirement |
|---|---|---|
| CUS-001 | M | On service start (or job arrival), the `CatchUpScanner` **shall** compare all currently-present monitored files against the `file_baselines` table in the corresponding shard. |
| CUS-002 | M | For each file whose current SHA-256 hash differs from `last_hash` in `file_baselines`, the scanner **shall** emit a `Modified` audit event (applying the same P1/P2/P3 logic as live monitoring). |
| CUS-003 | M | For each file present on disk that has no row in `file_baselines`, the scanner **shall** emit a `Created` audit event. |
| CUS-004 | M | For each file present in `file_baselines` that no longer exists on disk, the scanner **shall** emit a `Deleted` audit event and remove the baseline row. |
| CUS-005 | M | The scanner **shall** accept an optional `string? jobPath` parameter. When provided, the scan is scoped to that job folder only. When `null`, all known job folders are scanned (used on full service restart after a crash). |
| CUS-006 | H | The scanner **shall** not block the processing of live FSW events. It **shall** run on a background thread / `Task` and yield between files if the event queue depth exceeds a configurable threshold (default: 50). |

---

### 3.9 Query API  *(API)*

| ID | Priority | Requirement |
|---|---|---|
| API-001 | M | The system **shall** expose a read-only HTTP API on a configurable port (default **5100**) using ASP.NET Core Kestrel. The API **shall** be self-hosted (no IIS or external web server required) and **shall** be deployed as part of the same installation package as the monitoring service. The API **may** run in a separate Windows Service process provided both services are installed, started, and stopped together by `install.ps1` and the service manager. |
| API-002 | M | All API connections to SQLite shards **shall** use `Mode=ReadOnly`. No `INSERT`, `UPDATE`, or `DELETE` statements **shall** be issued by the query layer. |
| API-003 | M | The API **shall** expose the following endpoints: `GET /api/jobs`, `GET /api/jobs/{jobName}/manifest`, `GET /api/jobs/{jobName}/files`, `GET /api/jobs/{jobName}/events`, `GET /api/jobs/{jobName}/events/{id}`, `GET /api/jobs/{jobName}/history/{*filePath}`, `GET /api/global/events`. |
| API-004 | M | `GET /api/jobs/{jobName}/events` **shall** support filter query parameters: `module`, `priority`, `service`, `eventType`, `from` (ISO 8601), `to` (ISO 8601), `machine`, `path` (substring). |
| API-005 | M | `GET /api/jobs/{jobName}/events` **shall** support pagination via `page` (1-based) and `pageSize` (default 50, max 500) parameters. The response **shall** include `X-Total-Count`, `X-Page`, and `X-PageSize` headers. |
| API-006 | M | The `old_content` and `diff_text` fields **shall** be returned only by the single-event endpoint `GET /api/jobs/{jobName}/events/{id}`. List endpoints **shall** omit these fields. |
| API-007 | M | A `JobDiscoveryService` **shall** scan `c:\job\*\.audit\audit.db` at service startup and every **30 seconds** to register new shards and deregister removed ones. |
| API-008 | H | The `rel_filepath` parameter in file-history queries **shall** be validated against the pattern `^[\w\-. \\/]+$` before use in SQL to prevent path-traversal injection. |
| API-009 | H | By default the API **shall** bind to `127.0.0.1` (loopback) only. LAN binding **shall** require explicit configuration. |
| API-010 | L | The API **should** support Windows Authentication when bound to a LAN interface. |

---

### 3.10 Performance  *(PERF)*

| ID | Priority | Requirement |
|---|---|---|
| PERF-001 | M | The `FileSystemWatcher` **shall** be registered and live within **600 ms** of process start. |
| PERF-002 | M | A single file-change event (P1, including hash + diff) **shall** be fully written to the shard database within **1 second** of the debounce timer firing. |
| PERF-003 | M | `FileClassificationRules.json` hot-reload **shall** complete (new rules active) within **2 seconds** of the file being saved. |
| PERF-004 | H | With 10 jobs and ~150 files per job, full `CatchUpScanner` reconciliation (all jobs in parallel) **shall** complete within **5 seconds**. |
| PERF-005 | H | A paginated `GET /api/jobs/{j}/events` query (50 rows, no content fields) **shall** return a response within **200 ms** under normal load. |

---

### 3.11 Reliability and Data Integrity  *(REL)*

| ID | Priority | Requirement |
|---|---|---|
| REL-001 | M | No audit event **shall** be lost due to a service crash. Any event that has been fully written to SQLite (WAL committed) **shall** survive a subsequent crash and restart. |
| REL-002 | M | Events that occurred while the service was stopped (machine offline, service crashed) **shall** be recovered by `CatchUpScanner` on next startup. |
| REL-003 | M | The `manifest.json` write **shall** be atomic (temp-file rename, REQ MFT-004). A power loss during the write **shall** leave either the old or the new manifest intact — never a corrupt intermediate state. |
| REL-004 | M | SQLite WAL mode **shall** be used on all databases to allow concurrent reads from the query API while the writer is active. |
| REL-005 | M | Each shard **shall** have exactly one writer thread at a time, enforced by `SemaphoreSlim(1)` (STR-005). Concurrent writes to the same shard from multiple threads are not permitted. |
| REL-006 | H | If `FileClassificationRules.json` contains invalid JSON or a rule with a malformed glob pattern, the service **shall** log an error and **retain the previous valid rule set** — it **shall not** clear the rules or stop the service. |
| REL-007 | H | If a shard database file is corrupt or locked at startup, the service **shall** log an error for that job and continue processing all other jobs. |

---

### 3.12 Installation and Configuration  *(INS)*

| ID | Priority | Requirement |
|---|---|---|
| INS-001 | M | An `install.ps1` script **shall** register all service components (monitoring service and query API service if separate), create `C:\bis\auditlog\`, and copy the default `FileClassificationRules.json` to that path if it does not already exist. All registered services **shall** be configured with the same start type so they start and stop together. |
| INS-002 | M | All configurable parameters **shall** be readable from `appsettings.json` under a single `monitor_config` section. |
| INS-003 | M | The following parameters **shall** be configurable: `watch_path` (default `c:\job\`), `global_db_path` (default `c:\bis\auditlog\global.db`), `classification_rules_path` (default `c:\bis\auditlog\FileClassificationRules.json`), `api_port` (default `5100`), `debounce_ms` (default `500`). |
| INS-004 | M | Changing any `appsettings.json` value **shall** require a service restart to take effect (except `FileClassificationRules.json` changes which are hot-reloaded). |
| INS-005 | H | The service **shall** write structured logs via Serilog to a rolling file at `C:\bis\auditlog\logs\` and to the Windows Event Log under source `FalconAuditService`. |

---

## 4. Constraints

| ID | Constraint |
|---|---|
| CON-001 | Target platform: Windows 10 / Windows Server 2019 or later (64-bit). |
| CON-002 | Runtime: .NET 6 LTS. |
| CON-003 | Database: SQLite via `Microsoft.Data.Sqlite`. No external database server dependency. |
| CON-004 | The `.audit\` subdirectory is created inside the job folder. Falcon application software **shall not** be configured to delete or move this subdirectory. |
| CON-005 | `FileClassificationRules.json` uses JSON5-style inline comments in documentation only. The deployed file **shall** be strict JSON (no comments) as required by `System.Text.Json`. |
| CON-006 | The service **shall not** modify any file under `c:\job\` except within the `.audit\` subdirectory. |

---

## 5. Verification Matrix

| Requirement(s) | Verification method | Pass criterion |
|---|---|---|
| SVC-003, PERF-001 | Timed service start; check FSW registered timestamp in log | FSW log entry appears < 600 ms after process start |
| MON-004 | Write file rapidly 5× in 200 ms; count DB rows | Exactly 1 row inserted |
| CLS-005, CLS-006, PERF-003 | Add new rule to JSON; save; trigger matching file | New classification active within 2 s; no restart |
| REL-006 | Write malformed JSON to rules file | Previous rules still active; error logged; service continues |
| REC-001, REC-004, REC-005 | Modify a P1 file | Row present with non-null `old_content`, `diff_text`, valid SHA-256 |
| REC-002 | Modify a P2 file | Row present; `old_content` and `diff_text` are NULL |
| REC-003 | Modify a P4 file | No row inserted; Warning log entry present |
| JOB-001, JOB-003, JOB-006, MFT-005 | Stop service on Machine A; copy job folder to Machine B; start service on B | Shard opens with original rows; manifest shows two history entries; first new event in DB within 1 s of DirectoryWatcher fire |
| MFT-003, MFT-004 | Kill process mid-manifest-write | manifest.json is valid (either old or new version); never corrupt |
| CUS-001–CUS-004 | Stop service; modify, add, and delete one monitored file each; restart | Scanner emits correct Modified / Created / Deleted events for each |
| PERF-004 | Start service with 10 jobs × 150 files; measure CatchUpScanner completion log | Logged "reconcile complete" within 5 s of FSW-active log |
| API-003–API-005 | Call each endpoint; verify filter, pagination, and headers | Correct rows returned; X-Total-Count matches DB count query |
| STR-003, REL-004 | Query API reads while writer active | No SQLITE_BUSY errors; reads return consistent data |
| REL-001 | Kill -9 process mid-write; restart | All rows committed before kill are present; no corruption |

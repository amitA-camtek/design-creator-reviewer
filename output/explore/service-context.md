# Service Context

## Identity
service_name: FalconAuditService
service_description: A .NET 6 Windows Service that monitors c:\job\ on Falcon inspection machines and records tamper-evident audit events to per-job SQLite shards, maintains a chain-of-custody manifest, and exposes a read-only HTTP query API.
document_id: ERS-FAU-001
requirement_id_prefixes: [SVC, MON, CLS, REC, STR, JOB, CUS, API, PERF, REL, INS, CON]

## Technology Stack
# TBD until design alternative is approved (Phase 3 will populate)
primary_language:
runtime:
storage_technology:
api_framework:
test_framework:
os_target: Windows 10 / Server 2019+ (64-bit)
deployment: Windows Service (auto-start), installed via PowerShell install.ps1

## Key Components
# Components common to all three alternatives. Final naming finalised in Phase 3.
components:
  - name: FalconAuditWorker
    responsibility: BackgroundService host; composition root; orders FSW startup before catch-up
  - name: FileMonitor
    responsibility: Recursive FileSystemWatcher with debouncing and overflow recovery
  - name: Debouncer
    responsibility: Coalesces rapid successive events on the same file over a configurable window
  - name: FileClassifier
    responsibility: First-match-wins classification using compiled glob patterns
  - name: ClassificationRulesLoader
    responsibility: Hot-reloads FileClassificationRules.json atomically; secondary FSW on rules file
  - name: EventRecorder
    responsibility: Computes SHA-256, reads baseline, generates unified diff, writes the row
  - name: ShardRegistry
    responsibility: Manages SqliteRepository lifecycle keyed by job name
  - name: SqliteRepository
    responsibility: Per-shard writer connection; WAL + serialised writes
  - name: JobManager
    responsibility: Tracks job-folder arrivals/departures and coordinates manifest + shard lifecycle
  - name: DirectoryWatcher
    responsibility: Depth-1 FSW on c:\job\ for job arrival/departure detection (≤ 1 s)
  - name: ManifestManager
    responsibility: Atomic write of <job>\.audit\manifest.json with chain-of-custody entries
  - name: CatchUpScanner
    responsibility: Reconciles on-disk state against file_baselines on startup, overflow, and arrival
  - name: QueryHost
    responsibility: ASP.NET Core minimal API on Kestrel (loopback-only)
  - name: JobDiscoveryService
    responsibility: Periodic 30 s rescan + secondary FSW on c:\job\status.ini (Falcon.Net active-job marker)

## Storage Context
storage_description: |
  Per-job SQLite shard at <jobFolder>\.audit\audit.db (STR-001) plus a global database
  at C:\bis\auditlog\global.db for files directly under c:\job\ and CustodyHandoff events.
  All shards use WAL mode with synchronous=NORMAL.
primary_tables: [audit_log, file_baselines, custody_events]
concurrency_model: One writer per shard (channel + writer task or SemaphoreSlim — finalised after alt selection); WAL allows concurrent reads

## API Context
api_binding: 127.0.0.1:5100
api_auth: none (loopback-only, no external exposure)
sensitive_fields: [old_content, diff_text]
required_endpoints:
  - GET /api/health
  - GET /api/jobs
  - GET /api/events
  - GET /api/events/{job}/{id}

## Security Context
threat_model: |
  - Path traversal via user-supplied rel_filepath parameter (API-008, CON-005)
  - SQL injection via filter parameters (CON-004 — parameterised statements only)
  - Sensitive content (old_content, diff_text) leaking through list endpoints (API-006)
  - API binding to non-loopback addresses (API-009)
  - Service running with more than least-privilege rights (CON-002)
  - Audit log directories writable by unprivileged users (CON-003)
  - Tamper-evidence: chain-of-custody manifest must be atomically rewritten (REL-003)

## Performance Targets
perf_targets:
  - id: PERF-001
    description: FSW active and ready < 600 ms after process start
  - id: PERF-002
    description: Single P1 event fully recorded < 1 s after debounce fires
  - id: PERF-003
    description: Classification rules hot-reload active < 2 s after file save
  - id: PERF-004
    description: Catch-up across 10 jobs × 150 files completes < 5 s
  - id: PERF-005
    description: Paginated API query (50 rows) p95 < 200 ms under expected load

## Configuration Keys
required_config_keys:
  - key: watch_path
    default: c:\job\
  - key: global_db_path
    default: C:\bis\auditlog\global.db
  - key: classification_rules_path
    default: C:\bis\auditlog\FileClassificationRules.json
  - key: api_port
    default: 5100
  - key: debounce_ms
    default: 500
  - key: fsw_buffer_size
    default: 65536
  - key: content_size_limit
    default: 1048576
  - key: capture_content
    default: true
  - key: active_job_rescan_seconds
    default: 30

## Requirement ID Format
prefix_example: SVC-001

## Locked design decisions (Phase 0.5)
locked_decisions:
  - id: Q1-MON-003
    decision: Hybrid rename — single Renamed row with old_filepath when FSW supplies both paths; fallback to Deleted+Created for cross-directory renames
  - id: Q2-REC-004
    decision: When content exceeds content_size_limit, write audit row with is_content_omitted=1 and hash only; never lose the audit trail
  - id: Q3-JOB-002
    decision: ≤ 1 s detection via depth-1 FSW; no debounce on job folder arrivals
  - id: Q4-API-007
    decision: 30 s default rescan + secondary FSW on c:\job\status.ini as faster active-job signal (TODO-API-007-FAST)
  - id: Q5-CUS-001
    decision: Trust prior baseline; emit Modified events only for files that actually changed; write synthetic CustodyHandoff event to global.db

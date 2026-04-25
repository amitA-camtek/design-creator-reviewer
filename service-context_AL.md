# Service Context

## Identity
service_name: FalconAuditService
service_description: A .NET 6 Windows Service that monitors c:\job\ on Falcon inspection machines and records tamper-evident audit logs of configuration and recipe file changes to per-job SQLite shards.
document_id: ERS-FAU-001
requirement_id_prefixes: [SVC, MON, CLS, REC, STR, JOB, MFT, CUS, API, PERF, REL, INS]

## Technology Stack
primary_language: C#
runtime: .NET 6 Windows Service (BackgroundService)
storage_technology: SQLite via Microsoft.Data.Sqlite
api_framework: ASP.NET Core (Kestrel)
test_framework: xUnit + Moq
os_target: Windows 10 / Server 2019 (64-bit)
deployment: sc.exe + install.ps1

## Key Components
components:
  - name: FileMonitor
    responsibility: Recursive FileSystemWatcher on c:\job\ with 64 KB buffer; debounces events per file path over a 500 ms window using one CancellationTokenSource per path
  - name: FileClassifier
    responsibility: Maps file paths to P1/P2/P3/P4 priority via a hot-reloadable JSON rule set; rules compiled to Regex at load time
  - name: ClassificationRulesLoader
    responsibility: Loads and atomically hot-reloads FileClassificationRules.json; retains previous rule set on invalid JSON
  - name: EventRecorder
    responsibility: Computes SHA-256 (retry 3x with 100 ms delay), reads old_content from file_baselines, generates unified diff with DiffPlex, writes to shard
  - name: SqliteRepository
    responsibility: Per-shard SQLite connection management; WAL mode; SemaphoreSlim(1) write serialisation
  - name: ShardRegistry
    responsibility: ConcurrentDictionary keyed by job name; lazy shard creation; disposal within 5 s of job departure
  - name: DirectoryWatcher
    responsibility: Depth-1 FileSystemWatcher on c:\job\ watching for job folder arrivals and departures
  - name: JobManager
    responsibility: On job arrival triggers ManifestManager.RecordArrival + ShardRegistry.GetOrCreate + CatchUpScanner; on departure triggers ManifestManager.RecordDeparture + shard disposal
  - name: ManifestManager
    responsibility: Reads/writes <jobFolder>\.audit\manifest.json atomically via temp-file rename; records machine custody history
  - name: CatchUpScanner
    responsibility: Reconciles on-disk files against file_baselines; emits Created/Modified/Deleted events; runs one Task per job in parallel; yields if event queue depth exceeds threshold
  - name: QueryController
    responsibility: ASP.NET Core Kestrel read-only HTTP API on loopback:5100; all SQL connections use Mode=ReadOnly
  - name: JobDiscoveryService
    responsibility: Scans c:\job\*\.audit\audit.db at startup and every 30 s to register available shards for the query API

## Storage Context
storage_description: |
  Per-job SQLite shards at <jobFolder>\.audit\audit.db.
  Global DB at C:\bis\auditlog\global.db handles files directly under c:\job\.
  Shards disposed within 5 s of job departure.
primary_tables: [audit_log, file_baselines]
concurrency_model: SemaphoreSlim(1) per shard for writes; WAL mode + synchronous=NORMAL allows concurrent reads

## API Context
api_binding: 127.0.0.1:5100
api_auth: none (loopback-only by design — no external exposure)
sensitive_fields: [old_content, diff_text]
required_endpoints: [GET /jobs, GET /events, GET /events/{id}, GET /health]

## Security Context
threat_model: |
  - Path traversal via rel_filepath filter parameter (must match ^[\w\-. \\/]+$ before SQL use)
  - SQL injection via filter query parameters
  - old_content and diff_text must only be returned by the single-event GET /events/{id} endpoint
  - API must bind exclusively to 127.0.0.1 (loopback); binding to 0.0.0.0 is a critical violation
  - Sensitive file content must not appear in log output at any log level

## Performance Targets
perf_targets:
  - id: PERF-001
    description: FileSystemWatcher registered < 600 ms after process start
  - id: PERF-002
    description: Single P1 event fully written to database < 1 s after debounce fires
  - id: PERF-003
    description: Classification rules hot-reload active < 2 s after FileClassificationRules.json is saved
  - id: PERF-004
    description: CatchUpScanner processes 10 jobs x 150 files in parallel < 5 s
  - id: PERF-005
    description: Paginated API query returning 50 rows < 200 ms

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

## Requirement ID Format
prefix_example: SVC-001

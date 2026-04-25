# Service Context Template

Copy this file to your project folder (same directory as `engineering_requirements.md`),
rename it `service-context.md`, and fill in the values for your service.

All agents read this file at startup. Every field that is left blank or missing may cause
an agent to fall back to generic behavior or halt with an error.

---

# Service Context

## Identity
service_name: ExampleService
service_description: A .NET 6 Windows Service that monitors a folder and records tamper-evident audit events to a per-job SQLite database.
document_id: ERS-EXM-001
requirement_id_prefixes: [SVC, MON, STR, API, PERF, REL, INS]

## Technology Stack
# Leave blank when using design-orchestrator — filled automatically after design approval
primary_language:
# Leave blank when using design-orchestrator — filled automatically after design approval
runtime:
# Leave blank when using design-orchestrator — filled automatically after design approval
storage_technology:
# Leave blank when using design-orchestrator — filled automatically after design approval
api_framework:
test_framework:
os_target:
deployment:

## Key Components
# List every major architectural component. Agents derive class names,
# diagram participants, and test coverage areas from this list.
components:
  - name: FileMonitor
    responsibility: Watches the target folder with FileSystemWatcher; debounces events per file path
  - name: EventRecorder
    responsibility: Computes SHA-256, reads baseline, writes event row to shard
  - name: StorageRepository
    responsibility: Manages SQLite connection lifecycle, WAL mode, and write serialisation
  - name: QueryController
    responsibility: Exposes read-only HTTP API for querying recorded events

## Storage Context
storage_description: |
  One SQLite database per job folder, stored at <jobFolder>/.audit/audit.db.
  A global database handles files not inside any job folder.
primary_tables: [audit_log, file_baselines]
concurrency_model: SemaphoreSlim(1) per shard for writes; WAL mode allows concurrent reads

## API Context
api_binding: 127.0.0.1:5100
api_auth: none (loopback-only, no external exposure)
sensitive_fields: [old_content, diff_text]
required_endpoints: [GET /health, GET /events, GET /events/{id}]

## Security Context
threat_model: |
  - Path traversal via user-supplied file path parameters
  - SQL injection via unvalidated filter query parameters
  - Sensitive file content (old_content, diff_text) must not be returned by list endpoints
  - API must not bind to non-loopback addresses

## Performance Targets
perf_targets:
  - id: PERF-001
    description: Service fully initialised (watcher registered) < 600 ms after process start
  - id: PERF-002
    description: Single high-priority event fully written to database < 1 s after debounce fires
  - id: PERF-003
    description: Paginated API query returning 50 rows < 200 ms

## Configuration Keys
required_config_keys:
  - key: watch_path
    default: c:\job\
  - key: global_db_path
    default: C:\bis\auditlog\global.db
  - key: api_port
    default: 5100
  - key: debounce_ms
    default: 500

## Requirement ID Format
# One example ID from your requirements document. Agents use this to recognise
# and parse requirement IDs throughout the requirements file.
prefix_example: SVC-001
# FalconAuditService — High-Level Requirements

**Document ID:** ERS-FAU-001  
**Version:** 1.0  
**Date:** 2026-04-25

---

## 1. Purpose

The system shall provide a continuous, tamper-evident audit trail of file changes occurring within a watched job directory tree. Every change event shall be recorded, classified, and made queryable, with all data portable alongside the job it describes.

look at files
files:
C:\Claude\design-creator-reviewer\filesSummery\02_file_summary.md
C:\Claude\design-creator-reviewer\filesSummery\021_files_description.md
C:\Claude\design-creator-reviewer\filesSummery\FileClassificationRules.json
system:
C:\Claude\design-creator-reviewer\filesSummery\system.md
codebase folder
C:\Claude\design-creator-reviewer\filesSummery\C:\CamtekGit\BIS\Sources

---

## 2. Service Operation

**SVC-001** The system shall operate as a Windows background service that starts automatically on system boot.

**SVC-002** The service shall resume monitoring and reconcile any missed changes automatically after restart.

**SVC-003** Live file monitoring shall be active before any reconciliation or catch-up work begins, so that no change events are missed during startup.

**SVC-004** The service shall complete a clean shutdown — flushing all pending records and releasing resources — within a defined grace period.

**SVC-005** Errors in background tasks shall be caught, logged, and must not terminate the service process.

**SVC-006** The service shall be ready to receive and process live file events within 600 ms of process start.

**SVC-007** Catch-up reconciliation for multiple jobs shall be performed in parallel.

---

## 3. File Monitoring

**MON-001** The system shall monitor all files within a configurable watch path, including all subdirectories.

**MON-002** The file monitoring buffer size shall be configurable to handle high-throughput environments.

**MON-003** The system shall detect and record create, modify, delete, and rename events.

**MON-004** Rapid successive changes to the same file shall be coalesced using a configurable debounce window, so that a single logical change produces a single audit record.

**MON-005** If the file monitoring buffer overflows or the watcher fails, the system shall recover automatically and reconcile any events that may have been missed.

**MON-006** The watch path shall be configurable without rebuilding or redeploying the service.

---

## 4. File Classification

**CLS-001** Files shall be classified using an external rules file that can be updated without service restart.

**CLS-002** Classification rules shall support glob-style patterns, including recursive segment wildcards.

**CLS-003** When multiple rules match a file, the first matching rule in priority order shall apply.

**CLS-004** Files that match no rule shall be assigned a default classification.

**CLS-005** Changes to the rules file shall be detected and applied automatically within a defined reload window, without dropping any events during the transition.

**CLS-006** Reloading classification rules shall be atomic — in-flight classifications shall complete against the prior rule set, and subsequent ones against the new rule set, with no partial or mixed state.

**CLS-007** Each classification rule shall produce: a file module label, an owning service label, a monitoring priority, and a matched pattern identifier.

**CLS-008** Classification patterns shall be compiled at load time for efficient repeated matching.

---

## 5. Record Keeping

**REC-001** Each audit record shall include: absolute file path, path relative to the watch root, filename, file extension, change type, old hash, new hash, monitoring priority, module, owning service, timestamp (ISO 8601 UTC), user frendly description ,and machine name.

**REC-002** The hash of each file version shall be recorded to support integrity verification.

**REC-003** File content shall only be captured and stored for the highest-priority classification level. Lower-priority changes shall record metadata only.

**REC-004** File content storage shall respect a configurable maximum size per entry.

**REC-005** For modify events, the system shall compute and store a unified diff between the previous and current version.

**REC-006** The machine name field shall reflect the hostname of the machine running the service.

**REC-007** The relative file path within the job folder shall be stored separately from the absolute path, to enable portability-aware queries.

**REC-008** The last-seen timestamp for each tracked file shall be maintained and updated on every observed change.

**REC-009** Hash computation failures due to transient file locks shall be retried with back-off before logging a failure.

---

## 6. Storage Structure

**STR-001** Each job folder shall have its own isolated audit database, stored within that job folder.

**STR-002** A separate global audit database shall aggregate records from across all jobs.

**STR-003** Each job folder shall carry a custody manifest documenting when the job was first observed, the monitoring machine, and a count of recorded events.

**STR-004** All audit databases shall use a write-ahead journal mode to allow concurrent read access without blocking writes.

**STR-005** Concurrent writes to a single database shall be serialised to prevent data corruption.

**STR-006** Read access to audit databases shall not be blocked by write operations.

**STR-007** Audit databases shall be opened lazily — only when the first event for that job is processed — and at most one writer connection shall be open per job at any time.

**STR-008** When a job departs, its associated resources shall be cleanly released within 5 seconds.

---

## 7. Job Lifecycle Management

**JOB-001** Each job folder shall be self-contained: its audit database and custody manifest shall be stored within the job folder so they travel with the job.

**JOB-002** The system shall detect job folders arriving in or departing from the watch root and respond accordingly within a defined time window.

**JOB-003** On job arrival, the system shall initialise the job's audit database and manifest.

**JOB-004** On job departure, the system shall record the departure timestamp in the manifest and release all resources for that job.

**JOB-005** Jobs that already exist when the service starts shall be enumerated and brought up to date during startup reconciliation.

**JOB-006** In steady state, new changes within an active job shall be recorded within 1 second of the change being observed.

**JOB-007** The job manifest shall record the timestamp of the last observed change.

---

## 8. Catch-Up Reconciliation

**CUS-001** On startup, the system shall scan all files in the watch path and compare them against stored baselines to detect any changes that occurred while the service was not running.

**CUS-002** For each file found during catch-up, the system shall determine whether it is new, modified, or deleted relative to the last known state, and emit the appropriate audit record.

**CUS-003** Catch-up scans shall also run after a monitoring buffer overflow or watcher failure.

**CUS-004** Catch-up shall be able to target a single job folder without scanning the entire watch tree.

**CUS-005** Only one catch-up scan shall execute at a time; a new trigger shall not start a second scan if one is already in progress.

**CUS-006** While a catch-up scan is running, it shall yield when the live event queue reaches a defined depth threshold, to avoid starving the real-time writer.

---

## 9. Query API

**API-001** The system shall expose an HTTP API for querying audit records. The API port shall be configurable.

**API-002** The API shall be read-only; it must not modify any audit data.

**API-003** The API shall support listing audit events for a specific job or across all jobs, with filtering by priority, file path substring, and time range.

**API-004** The API shall support retrieving the full detail of a single audit event by its identifier.

**API-005** Event listing responses shall be paginated, and the total result count shall be returned in the response.

**API-006** File content and diff data shall not be included in list responses; they shall only be returned when a single event is retrieved by identifier.

**API-007** The API shall maintain an up-to-date list of active jobs by rescanning the watch path on a defined interval.

**API-008** File path parameters supplied to the API shall be validated to reject absolute paths, parent-directory traversal sequences, and any characters outside a defined safe set.

**API-009** By default, the API shall only accept connections from the local machine.

---

## 10. Performance

**PERF-001** The file monitoring watcher shall be active and ready within 600 ms of service start.

**PERF-002** A priority-1 file change event shall be fully recorded within 1 second of the file change being detected.

**PERF-003** Updated classification rules shall take effect within 2 seconds of the rules file being saved.

**PERF-004** A catch-up scan across 10 jobs with 150 files each shall complete within 5 seconds.

**PERF-005** An API query response returning a page of results shall complete within 200 ms at the 95th percentile under expected load.

---

## 11. Reliability

**REL-001** No detected file change event shall be silently discarded; if the processing queue is full, the system shall apply back-pressure rather than drop the event.

**REL-002** After a restart, catch-up reconciliation shall recover all changes that occurred during the downtime, provided the files remain accessible.

**REL-003** Custody manifest writes shall be durable — content shall be flushed to stable storage before the file is atomically renamed into place.

**REL-004** The service shall survive individual file processing failures without interrupting monitoring of other files.

**REL-005** Writes to each job's audit database shall be serialised to prevent concurrent-write corruption.

**REL-006** Failure to load or parse the classification rules file shall not stop the service; the system shall continue with the last valid rule set or a safe default.

**REL-007** Failure to open or create a job's audit database shall be logged and treated as an isolated error for that job; other jobs shall continue unaffected.

---

## 12. Installation and Configuration

**INS-001** The service shall be installable via a provided installation script that creates required directories, registers the service, and configures recovery actions.

**INS-002** All configuration values shall be sourced from a single external configuration file that is the authoritative source of truth.

**INS-003** The following settings shall be configurable: watch path, global database path, classification rules path, API port, debounce interval, FSW buffer size, content size limit, and content capture toggle.

**INS-004** Configuration values shall not be duplicated in the database or any secondary store; the configuration file shall be the sole source of truth.

**INS-005** Service events at warning level and above shall be written to the Windows Event Log under a registered source name.

---

## 13. Security and Constraints

**CON-001** The watched file system shall support atomic file rename operations; network file systems that do not support this shall not be used as the watch path.

**CON-002** The service shall run under the least-privilege account necessary: read access to the watch path, and write access only to the audit output directories.

**CON-003** Audit log directories shall be access-controlled so that only the service account and administrators can write to them.

**CON-004** All database queries shall use parameterised statements; direct string concatenation of user-supplied values into SQL is prohibited.

**CON-005** File path parameters accepted by the API shall be validated before use in any file system or database operation.

**CON-006** The API shall only expose audit data; it shall not expose service configuration, internal state, or raw file content beyond what is specified in the API requirements.

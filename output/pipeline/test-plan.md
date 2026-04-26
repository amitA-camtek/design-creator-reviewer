# FalconAuditService — Test Plan

**Document ID:** TST-FAU-001
**Date:** 2026-04-26
**Framework:** xUnit + FluentAssertions + Moq; integration via `Microsoft.AspNetCore.Mvc.Testing`

This plan provides at least one test case per requirement (62 total), grouped by requirement family, plus integration and performance tests. Each test case has: ID, requirement reference, type (unit/integration/perf), preconditions, steps, expected result.

Test types:
- **U** — Unit, in-memory, fast (<10 ms each)
- **I** — Integration, real SQLite + temp dirs, may use real FSW
- **P** — Performance, asserts a timing budget

---

## 1. Service Operation (SVC)

### T-SVC-001 [U] Service registers as Windows Service
- **Req:** SVC-001
- **Setup:** instantiate host with `UseWindowsService`
- **Action:** read service options
- **Expect:** `ServiceName == "FalconAuditService"` and start mode default is auto

### T-SVC-002 [I] Resume after restart reconciles missed changes
- **Req:** SVC-002, REL-002
- **Setup:** create job folder with one tracked file; stop service; modify the file on disk; restart service
- **Action:** wait 5 s
- **Expect:** an audit row exists for the modification, marked `created_by_catchup = 1`

### T-SVC-003 [I] FSW registers before catch-up
- **Req:** SVC-003
- **Setup:** spy on order of `FileMonitor.Start` and `JobManager.EnumerateExisting`
- **Action:** start service
- **Expect:** `Start` is called before `EnumerateExisting` returns

### T-SVC-004 [I] Clean shutdown drains pending events
- **Req:** SVC-004
- **Setup:** push 50 events into the pipeline, then signal stop
- **Action:** wait for shutdown
- **Expect:** all 50 rows appear in the shard within the 30 s grace period

### T-SVC-005 [U] Background task exception does not crash service
- **Req:** SVC-005
- **Setup:** mock `EventRecorder.RecordAsync` to throw on a specific path
- **Action:** push that event, then push a second event for a different path
- **Expect:** the second event is recorded; the writer task is alive; an error is logged

### T-SVC-006 [P] FSW ready < 600 ms
- **Req:** SVC-006, PERF-001
- **Setup:** start the host
- **Action:** measure time from `StartAsync` invocation to `FileMonitor.Start` returning
- **Expect:** elapsed < 600 ms (p99 over 10 runs)

### T-SVC-007 [I] Multiple jobs catch-up in parallel
- **Req:** SVC-007
- **Setup:** create 5 job folders each with 30 files
- **Action:** start service; observe parallelism via Serilog timestamps
- **Expect:** total catch-up wall clock < 3× single-job wall clock

---

## 2. File Monitoring (MON)

### T-MON-001 [I] Recursive subdirectory monitoring
- **Req:** MON-001
- **Setup:** job folder with nested `sub1/sub2/file.txt`
- **Action:** modify the deep file
- **Expect:** event recorded with the full nested path

### T-MON-002 [U] Buffer size honours configuration
- **Req:** MON-002
- **Setup:** set `fsw_buffer_size = 131072`
- **Action:** start `FileMonitor`
- **Expect:** `FileSystemWatcher.InternalBufferSize == 131072`

### T-MON-003a [I] Created event recorded
- **Req:** MON-003
- **Action:** create a new file
- **Expect:** one row with `event_type = 'Created'`

### T-MON-003b [I] Modified event recorded
- **Req:** MON-003
- **Action:** modify an existing file
- **Expect:** one row with `event_type = 'Modified'`

### T-MON-003c [I] Deleted event recorded
- **Req:** MON-003
- **Action:** delete an existing file
- **Expect:** one row with `event_type = 'Deleted'`

### T-MON-003d [I] Same-folder rename → single Renamed row (Q1)
- **Req:** MON-003, Q1
- **Action:** rename `a.xml` to `b.xml` in the same folder
- **Expect:** one row with `event_type = 'Renamed'`, `old_filepath` populated

### T-MON-003e [I] Cross-directory rename → Deleted + Created (Q1)
- **Req:** MON-003, Q1
- **Action:** move `a.xml` from `sub1/` to `sub2/`
- **Expect:** two rows: `Deleted` for old, `Created` for new

### T-MON-004 [U] Debounce coalesces rapid changes
- **Req:** MON-004
- **Setup:** push 5 `Modified` events 100 ms apart for the same path
- **Action:** wait 1 s
- **Expect:** classifier called exactly once for that path

### T-MON-005 [I] Buffer overflow triggers full catch-up
- **Req:** MON-005, CUS-003
- **Setup:** simulate `FileSystemWatcher.Error` with `InternalBufferOverflowException`
- **Action:** wait 5 s
- **Expect:** `CatchUpScanner.ScanAllAsync` was invoked; FSW is replaced

### T-MON-006 [U] Watch path is configurable
- **Req:** MON-006
- **Setup:** set `watch_path = "D:\foo\"`
- **Action:** read FileMonitor config
- **Expect:** the FSW is configured against `D:\foo\`

---

## 3. File Classification (CLS)

### T-CLS-001 [I] Rules loaded from external file
- **Req:** CLS-001
- **Setup:** write a rules JSON with one rule
- **Action:** start `ClassificationRulesLoader`; classify a matching file
- **Expect:** classification matches the rule

### T-CLS-002 [U] Glob with `**` matches recursive
- **Req:** CLS-002
- **Setup:** rule pattern `**/*.xml`
- **Action:** classify `a/b/c/d.xml`
- **Expect:** match

### T-CLS-003 [U] First match wins
- **Req:** CLS-003
- **Setup:** rule 1 `*.xml` priority 1; rule 2 `recipe.xml` priority 2
- **Action:** classify `recipe.xml`
- **Expect:** priority = 1 (first rule wins)

### T-CLS-004 [U] No-match → default classification
- **Req:** CLS-004
- **Setup:** empty rule set
- **Action:** classify `whatever.bin`
- **Expect:** `module = "Unknown"`, `priority = 3`

### T-CLS-005 [I] Hot reload within 2 seconds
- **Req:** CLS-005, PERF-003
- **Setup:** modify rules file
- **Action:** measure time from `File.WriteAllText` to first classify hitting new rule
- **Expect:** elapsed < 2 s (p95 over 5 runs)

### T-CLS-006 [U] Reload is atomic — no mixed state
- **Req:** CLS-006
- **Setup:** capture in-flight classification with old rules; trigger reload mid-flight
- **Action:** complete the in-flight call; classify again
- **Expect:** in-flight call returned a result consistent with old rules; subsequent call uses new rules

### T-CLS-007 [U] Rule produces all 4 fields
- **Req:** CLS-007
- **Action:** classify a matching file
- **Expect:** `Module`, `OwnerService`, `MonitorPriority`, `MatchedPatternId` all populated

### T-CLS-008 [U] Patterns compiled at load time
- **Req:** CLS-008
- **Setup:** load 100 rules
- **Action:** measure classification of 1000 files
- **Expect:** average call < 10 µs (proves regex was compiled, not interpreted per call)

---

## 4. Record Keeping (REC)

### T-REC-001 [I] All required fields written
- **Req:** REC-001
- **Action:** modify a P1 file
- **Expect:** the row has filepath, rel_filepath, filename, file_extension, event_type, old_hash, new_hash, monitor_priority, module, owner_service, changed_at (ISO 8601 UTC), description, machine_name

### T-REC-002 [I] Hash recorded for each version
- **Req:** REC-002
- **Action:** create a file, then modify it
- **Expect:** Created row has new_hash; Modified row has both old_hash and new_hash, and old_hash matches the prior new_hash

### T-REC-003 [I] Content stored only for P1
- **Req:** REC-003
- **Setup:** P1 rule for `*.xml`, P3 rule for `*.bin`
- **Action:** modify both
- **Expect:** P1 row has `old_content` populated; P3 row has `old_content = NULL` and `diff_text = NULL`

### T-REC-004 [I] Content size limit is honoured (Q2)
- **Req:** REC-004, Q2
- **Setup:** `content_size_limit = 1024`; create a 2 KB P1 file
- **Action:** modify it
- **Expect:** row exists with `is_content_omitted = 1`, `old_content = NULL`, `diff_text = NULL`, hashes still populated

### T-REC-005 [I] Unified diff stored for modify
- **Req:** REC-005
- **Action:** modify a P1 text file
- **Expect:** `diff_text` is non-empty and is parseable as a unified diff

### T-REC-006 [U] Machine name is hostname
- **Req:** REC-006
- **Action:** record an event
- **Expect:** `machine_name == Environment.MachineName`

### T-REC-007 [I] Relative path stored separately
- **Req:** REC-007
- **Setup:** file at `c:\job\Lot-A\sub\file.xml`
- **Action:** modify it
- **Expect:** `filepath = "c:\\job\\Lot-A\\sub\\file.xml"`, `rel_filepath = "sub\\file.xml"`

### T-REC-008 [I] Last-seen updated on every event
- **Req:** REC-008
- **Action:** modify a file at T1, then again at T2
- **Expect:** `file_baselines.last_seen` after second modify equals T2 (UTC)

### T-REC-009 [U] Hash retry on transient lock
- **Req:** REC-009
- **Setup:** mock `File.OpenRead` to throw `IOException` on the first 2 calls and succeed on the 3rd
- **Action:** call `HashService.ComputeWithRetryAsync(retries=3, delayMs=100)`
- **Expect:** returns the hash; total elapsed ≥ 200 ms

---

## 5. Storage Structure (STR)

### T-STR-001 [I] Per-job DB created in job folder
- **Req:** STR-001
- **Action:** record an event in a new job
- **Expect:** `<job>\.audit\audit.db` exists and contains the row

### T-STR-002 [I] Global DB receives top-level events
- **Req:** STR-002
- **Action:** modify `c:\job\loose-file.txt` (not under any job folder)
- **Expect:** the row is in `global.db`, not in any shard

### T-STR-003 [I] Manifest contains arrival, machine, count
- **Req:** STR-003
- **Action:** arrive job, record 3 events
- **Expect:** manifest has `first_observed_at`, `first_observed_by = MachineName`, `event_count = 3`

### T-STR-004 [U] WAL pragma applied
- **Req:** STR-004
- **Action:** open repo; `PRAGMA journal_mode;`
- **Expect:** returns `wal`

### T-STR-005 [I] Concurrent writes serialised
- **Req:** STR-005, REL-005
- **Setup:** push 200 events for the same shard from 10 producer threads
- **Action:** wait for drain
- **Expect:** all 200 rows present, no errors, no `SQLITE_BUSY`

### T-STR-006 [I] Reads not blocked by writes
- **Req:** STR-006
- **Setup:** start a long-running write; concurrently issue a read
- **Action:** time the read
- **Expect:** read returns within 50 ms regardless of write progress

### T-STR-007 [I] Lazy-open: connection opens on first event
- **Req:** STR-007
- **Setup:** arrive a job (don't generate events yet)
- **Action:** inspect `ShardRegistry`
- **Expect:** the `Lazy<SqliteRepository>` exists but `.IsValueCreated == false`; after first event it is `true`

### T-STR-008 [I] Departure disposes within 5 s
- **Req:** STR-008
- **Setup:** active job with open shard
- **Action:** delete the job folder; measure time until `audit.db` is unlocked (no handle)
- **Expect:** elapsed < 5 s

---

## 6. Job Lifecycle (JOB)

### T-JOB-001 [I] Self-contained job folder
- **Req:** JOB-001
- **Action:** record events in job; copy whole job folder elsewhere; open `audit.db` from new location
- **Expect:** all rows readable; manifest readable

### T-JOB-002 [I,P] Job arrival detected ≤ 1 s (Q3)
- **Req:** JOB-002, Q3
- **Action:** create a new top-level job folder; measure time until `JobArrived` fires
- **Expect:** elapsed < 1 s (p95 over 5 runs)

### T-JOB-003 [I] Arrival initialises DB and manifest
- **Req:** JOB-003
- **Action:** arrive new job
- **Expect:** `<job>\.audit\audit.db` and `<job>\.audit\manifest.json` both exist

### T-JOB-004 [I] Departure records timestamp and releases resources
- **Req:** JOB-004
- **Action:** depart job
- **Expect:** manifest's last custody entry has `departed_at` populated; shard is disposed

### T-JOB-005 [I] Existing jobs enumerated on startup
- **Req:** JOB-005
- **Setup:** create 3 job folders before start
- **Action:** start service
- **Expect:** 3 shards in registry; 3 catch-up scans completed

### T-JOB-006 [P] Steady-state event recorded < 1 s
- **Req:** JOB-006, PERF-002
- **Action:** modify a P1 file in an active job
- **Expect:** time from FSW callback to row commit < 1 s (p95 over 20 runs after debounce)

### T-JOB-007 [I] Manifest tracks last event
- **Req:** JOB-007
- **Action:** record events at T1, T2, T3
- **Expect:** manifest's `last_event_at` after flush equals T3

---

## 7. Catch-up Reconciliation (CUS)

### T-CUS-001 [I] Startup scan emits Modified for changed files (Q5)
- **Req:** CUS-001, Q5
- **Setup:** existing job with baseline hash X; while service is down, modify file to hash Y
- **Action:** start service
- **Expect:** one synthetic `Modified` event with `created_by_catchup = 1`

### T-CUS-002 [I] Created/Modified/Deleted from baseline diff
- **Req:** CUS-002
- **Setup:** baselines for files A, B; A unchanged, B modified, C is new on disk, baseline D missing on disk
- **Action:** run scanner
- **Expect:** events `Modified(B)`, `Created(C)`, `Deleted(D)`; nothing for A

### T-CUS-003 [I] Catch-up runs after FSW failure
- **Req:** CUS-003, MON-005
- **Action:** simulate FSW error
- **Expect:** catch-up triggered

### T-CUS-004 [I] Single-job catch-up does not scan others
- **Req:** CUS-004
- **Setup:** 3 jobs
- **Action:** call `QueueJobAsync("Job1")`
- **Expect:** scanner enumerates only Job1's files; logs do not show Job2/Job3 paths

### T-CUS-005 [U] Single-instance gate blocks concurrent scans
- **Req:** CUS-005
- **Action:** call `ScanAllAsync` twice in parallel
- **Expect:** the second call blocks until the first returns; only one scan runs at a time

### T-CUS-006 [I] Yield when queue depth > threshold
- **Req:** CUS-006
- **Setup:** set yield threshold = 5; pre-fill pipeline with 10 events
- **Action:** start a scan; observe scan's per-file rate
- **Expect:** scan slows (yields ≥ 50 ms) while pipeline depth > 5

---

## 8. Query API (API)

### T-API-001 [U] Port is configurable
- **Req:** API-001
- **Setup:** `api_port = 6000`
- **Action:** start host
- **Expect:** Kestrel binds 6000

### T-API-002 [U] Read connections are read-only
- **Req:** API-002
- **Action:** inspect connection string used by API
- **Expect:** contains `Mode=ReadOnly`

### T-API-003 [I] Filters apply to listing
- **Req:** API-003
- **Setup:** seed shard with rows of mixed priorities, paths, dates
- **Action:** GET `/api/events?priority=1&path=Recipes&from=2026-01-01`
- **Expect:** result rows all match all 3 filters

### T-API-004 [I] Single event detail returns full row
- **Req:** API-004
- **Action:** GET `/api/events/{job}/{id}`
- **Expect:** 200 with `old_content` and `diff_text` present (when applicable)

### T-API-005 [I] Listing returns total + items[]
- **Req:** API-005
- **Action:** seed 100 rows; GET `/api/events?limit=10&offset=20`
- **Expect:** response has `total = 100`, `items.Length = 10`

### T-API-006 [I] List response excludes content/diff
- **Req:** API-006
- **Action:** GET `/api/events`
- **Expect:** no item has `old_content` or `diff_text` fields

### T-API-007 [I] Active jobs refresh on 30 s tick
- **Req:** API-007, Q4
- **Setup:** `active_job_rescan_seconds = 1`
- **Action:** add a job folder; wait 1.5 s; GET `/api/jobs`
- **Expect:** the new job appears

### T-API-008a [U] Path with `..` is rejected
- **Req:** API-008, CON-005
- **Action:** GET `/api/events?path=../etc/passwd`
- **Expect:** 400 INVALID_PATH

### T-API-008b [U] Absolute path is rejected
- **Req:** API-008, CON-005
- **Action:** GET `/api/events?path=C:\Windows`
- **Expect:** 400 INVALID_PATH

### T-API-008c [U] Forbidden character rejected
- **Req:** API-008, CON-005
- **Action:** GET `/api/events?path=foo*bar`
- **Expect:** 400 INVALID_PATH

### T-API-009a [I] Default binding is loopback only
- **Req:** API-009
- **Action:** start service with default config; attempt to connect from another host
- **Expect:** connection refused

### T-API-009b [U] Loopback flag toggles binding
- **Req:** API-009
- **Setup:** `api_bind_loopback_only = false`
- **Action:** read configured listen options
- **Expect:** `ListenAnyIP` was used; a warning is logged

---

## 9. Performance (PERF)

### T-PERF-001 [P] FSW ready < 600 ms
- See **T-SVC-006**

### T-PERF-002 [P] P1 event written < 1 s
- See **T-JOB-006**

### T-PERF-003 [P] Hot reload < 2 s
- See **T-CLS-005**

### T-PERF-004 [P] Catch-up 10×150 < 5 s
- **Req:** PERF-004
- **Setup:** 10 jobs with 150 small files each (all hashes match baselines, so no events emitted; pure scan cost)
- **Action:** trigger catch-up; measure wall clock
- **Expect:** elapsed < 5 s

### T-PERF-005 [P] API page query p95 < 200 ms
- **Req:** PERF-005
- **Setup:** shard with 1 000 000 rows; filter by `priority = 1`
- **Action:** GET `/api/events?priority=1&limit=50&offset=0` 50 times
- **Expect:** p95 < 200 ms (relies on `ix_audit_priority_time` and the COUNT cache)

---

## 10. Reliability (REL)

### T-REL-001 [I] Back-pressure, no dropped events
- **Req:** REL-001
- **Setup:** mock writer to delay 100 ms per row; push 1000 events as fast as possible
- **Action:** wait for drain
- **Expect:** all 1000 rows present; producer's `WriteAsync` blocked at high-water mark, never dropped

### T-REL-002 [I] Restart catch-up recovers downtime changes
- See **T-SVC-002**

### T-REL-003 [I] Manifest write is atomic (durable + rename)
- **Req:** REL-003
- **Action:** kill the process during a manifest write (simulate by injecting a fault between flush and rename)
- **Expect:** on restart, the prior manifest is intact (no truncated file)

### T-REL-004 [I] Per-file failure isolated
- **Req:** REL-004
- **Setup:** mock `HashService.ComputeWithRetryAsync` to throw permanently for one specific path
- **Action:** modify that path and another path
- **Expect:** the other path's row exists; an error is logged for the failing path; writer task continues running

### T-REL-005 [I] Per-shard write serialisation
- See **T-STR-005**

### T-REL-006 [I] Invalid rules JSON keeps prior rules
- **Req:** REL-006
- **Setup:** valid rules loaded
- **Action:** overwrite rules file with invalid JSON
- **Expect:** error logged; classifier still uses the prior rule set

### T-REL-007 [I] Per-shard open failure isolated
- **Req:** REL-007
- **Setup:** make one job's `.audit\` directory read-only
- **Action:** record events in that job and another
- **Expect:** error logged for the broken job; the other job's events are recorded

---

## 11. Installation & Configuration (INS)

### T-INS-001 [I] Install script registers service & creates dirs
- **Req:** INS-001
- **Action:** run `install.ps1` in a clean VM
- **Expect:** `sc.exe query FalconAuditService` returns success; `C:\bis\auditlog\logs\` exists; recovery actions configured

### T-INS-002 [U] All settings come from one config file
- **Req:** INS-002, INS-004
- **Action:** scan source for any setting read outside `MonitorConfig`
- **Expect:** none found (lint test using `Roslyn`)

### T-INS-003 [U] All required keys are read
- **Req:** INS-003
- **Action:** load `MonitorConfig` from a minimal valid JSON
- **Expect:** every documented key has a non-default value when set

### T-INS-004 [U] No setting duplicated in DB
- **Req:** INS-004
- **Action:** inspect schema
- **Expect:** no table named `_settings` or similar

### T-INS-005 [I] Warnings/errors land in Windows Event Log
- **Req:** INS-005
- **Action:** induce a warning (invalid rules JSON), then read the Event Log under source `FalconAuditService`
- **Expect:** the warning appears

---

## 12. Constraints (CON)

### T-CON-001 [I] Atomic-rename failure is detected
- **Req:** CON-001
- **Setup:** point `watch_path` at a network share that does not support atomic rename
- **Action:** start service
- **Expect:** service logs an error and refuses to monitor (or the manifest write fails; behaviour documented)

### T-CON-002 [I] Service runs with restricted privileges
- **Req:** CON-002
- **Action:** install per script; check `sc.exe qc FalconAuditService`
- **Expect:** account is `LocalSystem` or named least-privilege account; not `Administrator`

### T-CON-003 [I] ACLs deny non-admin write
- **Req:** CON-003
- **Action:** post-install, attempt to write a file as a non-admin user into `C:\bis\auditlog\`
- **Expect:** access denied

### T-CON-004 [U] No string concatenation of user input into SQL
- **Req:** CON-004
- **Action:** static-analyse all SQL paths via Roslyn rule
- **Expect:** no `string.Format`, `$"..."`, or `+` concatenation in `SqliteCommand.CommandText`

### T-CON-005 [U] Path validation before file/SQL use
- **Req:** CON-005, API-008
- **Action:** unit-test `Validators.IsSafePath` against a corpus of malicious paths
- **Expect:** all malicious inputs rejected; safe inputs accepted

### T-CON-006 [I] API exposes only audit data
- **Req:** CON-006
- **Action:** enumerate endpoints; inspect responses
- **Expect:** no endpoint returns config, internal state, or memory dumps

---

## 13. Integration tests (cross-cutting)

### T-INT-01 [I] Startup → arrival → P1 modify → API read end-to-end
- Validates flows 1, 2, and 5 together. Asserts the row appears in `GET /api/events/{job}/{id}` exactly once.

### T-INT-02 [I] Custody handoff round-trip
- Validates flow 3. Pre-create a manifest with `last_machine_name = "FALCON-02"` on a fresh machine; arrive the job; assert one `CustodyHandoff` row in `global.db`.

### T-INT-03 [I] Hot-reload while events are flowing
- Validates flow 4. Push 100 events while replacing the rules file mid-burst; assert no event is lost or misclassified.

### T-INT-04 [I] FSW overflow recovery
- Force-overflow the FSW buffer; assert a full catch-up runs and recovers all unobserved changes.

### T-INT-05 [I] Job departure during active writes
- Mid-burst, delete the job folder; assert no exceptions, the shard disposes within 5 s, the manifest's `departed_at` is set.

---

## 14. Coverage summary

| Family | Requirements | Test cases |
|---|---|---|
| SVC | 7 | 7 |
| MON | 6 | 9 (MON-003 has 5 sub-cases) |
| CLS | 8 | 8 |
| REC | 9 | 9 |
| STR | 8 | 8 |
| JOB | 7 | 7 |
| CUS | 6 | 6 |
| API | 9 | 12 (API-008/009 have sub-cases) |
| PERF | 5 | 5 |
| REL | 7 | 7 |
| INS | 5 | 5 |
| CON | 6 | 6 |
| **Total** | **62** | **89 named cases** + 5 integration cases |

Every requirement ID has at least one test ID prefixed with `T-<group>-<num>` referencing it. Compound requirements (e.g. MON-003 with 4 event types) have multiple cases.

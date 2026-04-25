# FalconAuditService — Test Plan

| Field | Value |
|---|---|
| Document | test-plan.md |
| Phase | 3 — Test plan |
| Source | `engineering_requirements.md` (ERS-FAU-001), `architecture-design.md`, `schema-design.md`, `api-design.md`, `sequence-diagrams.md`, `code-scaffolding.md` |
| Target | xUnit + FluentAssertions; integration tests via WebApplicationFactory + TempDir SQLite shards |
| Date | 2026-04-25 |

---

## 1. Goals

1. Cover **every requirement ID** in ERS-FAU-001 with at least one test case.
2. Validate the five canonical sequence flows (`sequence-diagrams.md`) end-to-end.
3. Validate the multi-process architecture's read/write isolation with concurrent worker + query tests.
4. Lock down the PERF-* targets with explicit timing assertions in a dedicated category.
5. Provide a path for future regression: every bug fix must add a test that names the requirement it relates to.

---

## 2. Test Project Layout

| Project | Scope |
|---|---|
| `FalconAuditService.Core.Tests` | Pure unit tests of `Core` library (classifier, manifest, schema migrator, repository, query builder, path validator) |
| `FalconAuditWorker.Tests` | Worker-process unit tests (FileMonitor, debouncer, recorder, shard registry, catch-up) — uses fakes for FSW |
| `FalconAuditQuery.Tests` | Query-process unit tests (controller, query builder, route constraint, discovery service) — uses `WebApplicationFactory<Program>` |
| `FalconAuditService.Integration.Tests` | Cross-process tests: spin up worker against a temp `c:\job\`-like dir, drive real file events, query via real Kestrel on an ephemeral port |

All projects target `net6.0`, reference xUnit 2.5+, FluentAssertions, Microsoft.Data.Sqlite, and `Moq` for fakes.

---

## 3. Test Categories

| Category trait | Purpose |
|---|---|
| `[Trait("type","unit")]` | Pure logic, no I/O |
| `[Trait("type","integration")]` | Touches filesystem or real SQLite |
| `[Trait("type","perf")]` | Asserts timing budgets — runs in nightly only |
| `[Trait("req", "PERF-001")]` etc. | Requirement-ID tag for traceability |

---

## 4. Test Cases by Requirement Group

### 4.1 SVC — Service host

| Req | Test (project) | Description |
|---|---|---|
| SVC-001 | `WorkerHost_ImplementsBackgroundService` (Worker) | `AuditHost` derives from `BackgroundService`. |
| SVC-002 | `WorkerHost_StopsCleanlyWithin5s` (Worker) | Send `StopAsync`; service exits ≤ 5 s; all shards disposed. |
| SVC-003 | `WorkerHost_ArmsFsw_BeforeCatchUp` (Worker) | Replace `IFileMonitor` with a fake whose `WatcherReady` task is observable; assert `ICatchUpCoordinator.RunAllAsync` is **never** invoked before that task completes. |
| SVC-004 | `WorkerHost_LogsToWindowsEventLog` (Integration) | Spin up worker; write a control event; assert Event Log source `FalconAuditService` has the entry. |
| SVC-005 | `WorkerHost_LogsToRollingFile` (Integration) | Same as 004 but the log file under `C:\bis\auditlog\logs\` is non-empty. |
| SVC-006 | `WorkerHost_ContinuesOnSingleShardException` (Worker) | Inject a recorder that throws for shard A; assert shard B continues writing. |
| SVC-007 | `CatchUp_RunsParallelAcrossJobs` (Worker) | 10 jobs × 150 files; assert `Parallel.ForEachAsync` parallelism degree ≥ 4 and total time < 5 s (also covers PERF-004). |

### 4.2 MON — File monitoring

| Req | Test | Description |
|---|---|---|
| MON-001 | `FileMonitor_RecursiveOnWatchPath` (Integration) | Create file 3 levels deep; assert event observed. |
| MON-002 | `Debouncer_FiresOnceAfter500ms` (Unit) | Schedule 5 events for the same path within 100 ms; only one fire. |
| MON-003 | `Debouncer_PerPathIndependent` (Unit) | Schedule events for two paths; both fire independently. |
| MON-004 | `FileMonitor_BufferIs64KiB` (Unit) | `FileSystemWatcher.InternalBufferSize == 64*1024`. |
| MON-005 | `FileMonitor_OnFswError_TriggersCatchUp` (Worker) | Raise FSW `Error` with `InternalBufferOverflowException`; assert `ICatchUpCoordinator.RunAllAsync` invoked. |
| MON-006 | `FileMonitor_DetectsCreateModifyDeleteRename` (Integration) | Each of the four operations produces a corresponding `RawFsEvent`. |

### 4.3 CLS — Classification

| Req | Test | Description |
|---|---|---|
| CLS-001 | `RulesLoader_ReadsJsonFromConfiguredPath` (Unit) | Custom path is honoured. |
| CLS-002 | `Classifier_FirstMatchWins` (Unit) | Two rules match the same path; first declared wins. |
| CLS-003 | `Classifier_FallbackP3Unknown` (Unit) | Unmatched path → `(Unknown, Unknown, P3)`. |
| CLS-004 | `RulesLoader_CompilesGlobsAtLoadTime` (Unit) | After load, `CompiledRule.Pattern.IsMatch` does not trigger any compile work. |
| CLS-005 | `RulesWatcher_HotReloadAtomicSwap` (Worker) | Save new rules; assert classifier sees new mapping within 2 s; in-flight events that read `_rules` do not crash. |
| CLS-006 | `RulesWatcher_InvalidJsonRetainsPrevious` (Worker) | Save broken JSON; classifier still uses prior rules; warning logged. |
| CLS-007 | `Classifier_P4Suppressed` (Unit) | A P4-tagged path returns `null` from `Classify`; no event is routed. |

### 4.4 REC — Recording

| Req | Test | Description |
|---|---|---|
| REC-001 | `Recorder_WritesAllRequiredColumns` (Unit) | Inserted row contains all 11 columns from REC-001 with the correct values. |
| REC-002 | `Recorder_ComputesSha256Correctly` (Unit) | Known file content → known hash. |
| REC-003 | `Recorder_RetriesOnIOException` (Unit) | First two reads throw `IOException`; third succeeds; row written. |
| REC-004 | `Recorder_GivesUpAfter3Retries` (Unit) | All retries fail; no row written; baseline not advanced. |
| REC-005 | `Recorder_P1WritesContentAndDiff` (Unit) | P1 row has `old_content` + `diff_text` populated; diff matches DiffPlex output. |
| REC-006 | `Recorder_P2P3OmitContent` (Unit) | P2/P3 rows have `old_content == null` and `diff_text == null`. |
| REC-007 | `Recorder_RelFilepathRelativeToJob` (Unit) | For shard, rel = path relative to job root; for global, rel = path relative to `c:\job\`. |
| REC-008 | `Recorder_UpsertsFileBaseline` (Unit) | `file_baselines` row updated with new hash + last_seen on every event. |
| REC-009 | `Recorder_P4LogsAndSkips` (Unit) | P4 → `Warning` log + no DB write. |

### 4.5 STR — Storage

| Req | Test | Description |
|---|---|---|
| STR-001 | `Repo_OpensShardAtJobAuditPath` (Integration) | DB created at `<jobFolder>\.audit\audit.db`. |
| STR-002 | `Repo_OpensGlobalDbAtConfiguredPath` (Integration) | Global DB at `C:\bis\auditlog\global.db` (or test-overridden path). |
| STR-003 | `Repo_UsesWalJournalMode` (Integration) | After open, `PRAGMA journal_mode` returns `wal`. |
| STR-004 | `Repo_UsesSynchronousNormal` (Integration) | After open, `PRAGMA synchronous` returns `1` (NORMAL). |
| STR-005 | `ShardRegistry_OneWriterPerShard` (Worker) | Two concurrent recorder calls on shard A serialise via `SemaphoreSlim(1)`; shard B is unaffected. |
| STR-006 | `Schema_AllRequiredIndexesPresent` (Unit) | After migration, `sqlite_master` lists `ix_audit_changed_at`, `ix_audit_relpath`, `ix_audit_module_priority`, `ix_audit_machine_changed`. |
| STR-007 | `ShardRegistry_DisposesWithin5s_OnDeparture` (Worker) | Job departs; assert handle disposed within 5 s; channel completed; writer task exited. |
| STR-008 | `Repo_CheckConstraint_RejectsContentOnP2` (Integration) | Direct INSERT of P2 row with `old_content` set raises `SqliteException`. |
| STR-009 | `Repo_CheckConstraint_RejectsBadEventType` (Integration) | INSERT with `event_type='Foo'` raises `SqliteException`. |
| STR-010 | `Migrator_BumpsUserVersion` (Unit) | After `EnsureSchemaAsync` on a fresh DB, `PRAGMA user_version == 1`. |
| STR-011 | `Migrator_IsIdempotent` (Unit) | Second call is a no-op (no `BEGIN` issued). |
| STR-012 | `Migrator_FailsOnSchemaTooNew` (Unit) | Set `user_version = 2`; `EnsureSchemaAsync` throws `SchemaTooNewException`. |
| STR-013 | `Repo_DisposeRunsCheckpointTruncate` (Integration) | After dispose, the `-wal` file is truncated to 0 bytes. |

### 4.6 JOB — Job lifecycle

| Req | Test | Description |
|---|---|---|
| JOB-001 | `JobLifecycle_OnArrival_CreatesShardAndManifest` (Worker) | Folder appears; `manifest.json` and `audit.db` created; shard added to registry. |
| JOB-002 | `JobLifecycle_OnDeparture_RecordsDepartureAndDisposes` (Worker) | Folder removed; manifest updated with `DepartedAt`; shard disposed. |
| JOB-003 | `DirectoryWatcher_Depth1Only` (Worker) | A file event 2 levels deep does not trigger arrival logic. |
| JOB-004 | `JobLifecycle_PortableManifest` (Integration) | Copy a job folder to a second machine name; manifest history shows two arrivals; shard data still readable (string enums, no FK drift — schema Alt B property). |

### 4.7 MFT — Manifest

| Req | Test | Description |
|---|---|---|
| MFT-001 | `Manifest_ReadFromAuditFolder` (Unit) | Reads `.audit\manifest.json` and deserialises. |
| MFT-002 | `Manifest_AtomicWrite` (Integration) | Concurrent reader sees either old or new content, never partial. |
| MFT-003 | `Manifest_PowerLossSimulation` (Integration) | Kill process during write; original file intact, `.tmp` may dangle but is ignored on next read. |
| MFT-004 | `Manifest_RecordArrival_AddsHistoryEntry` (Unit) | New `MachineHistoryDto` appended with `ArrivedAt` set. |
| MFT-005 | `Manifest_RecordDeparture_SetsDepartedAt` (Unit) | Last entry's `DepartedAt` set. |
| MFT-006 | `Manifest_IncrementEventCount_IsAtomic` (Unit) | Concurrent increments produce sum of all increments (no lost update). |

### 4.8 CUS — Catch-up

| Req | Test | Description |
|---|---|---|
| CUS-001 | `CatchUp_EmitsCreatedForNewFiles` (Worker) | File present on disk, no baseline → `Created` event. |
| CUS-002 | `CatchUp_EmitsModifiedForHashMismatch` (Worker) | Baseline hash differs from on-disk hash → `Modified` event. |
| CUS-003 | `CatchUp_EmitsDeletedForMissingFile` (Worker) | Baseline exists, file missing → `Deleted` event. |
| CUS-004 | `CatchUp_RunsParallelAcrossJobs` (Worker) | Same as SVC-007. |
| CUS-005 | `CatchUp_YieldsWhenChannelDepthExceeds50` (Worker) | Block writer; assert scanner calls `Task.Yield()` once channel depth > 50. |
| CUS-006 | `CatchUp_TriggeredOnFswOverflow` (Worker) | Same as MON-005 from a different angle: end-to-end, baseline reconciliation runs. |

### 4.9 API — Query API

| Req | Test (project: `Query.Tests` unless noted) | Description |
|---|---|---|
| API-001 | `Api_RunsInOwnProcess_OnPort5100Loopback` (Integration) | `127.0.0.1:5100` returns 200 on `/api/jobs`; `0.0.0.0:5100` does not by default. |
| API-002 | `ShardReaderFactory_AlwaysOpensReadOnly` (Unit) | Generated connection string contains `Mode=ReadOnly`. |
| API-002 | `Repo_WriteOnReadOnlyConnection_Fails` (Unit) | Calling `InsertEventAsync` on an RO repository throws `InvalidOperationException`. |
| API-003 | `Routes_AllSevenEndpointsRespond` (Unit) | Each of the seven routes returns 200 / 404 (not 405) for an empty test shard. |
| API-004 | `Events_SupportsAllFilterAxes` (Unit) | Each filter (`module`, `priority`, `service`, `eventType`, `from`, `to`, `machine`, `path`) narrows results correctly; combined filters use AND. |
| API-005 | `Events_PaginationHeadersPresent` (Unit) | Response headers `X-Total-Count`, `X-Page`, `X-PageSize` reflect actual values. |
| API-005 | `Events_OutOfRangePage_Returns200Empty` (Unit) | `page=999` returns empty array with correct `X-Total-Count`. |
| API-005 | `Events_PageSize_CappedAt500` (Unit) | `pageSize=10000` → 400 Bad Request. |
| API-006 | `Detail_ReturnsOldContentAndDiff_ForP1` (Unit) | Single-event endpoint returns both fields populated for a P1 row. |
| API-006 | `EventList_DoesNotReturnOldContentOrDiff` (Unit) | List endpoint DTO has no such fields (compile-time + JSON shape). |
| API-007 | `Discovery_RefreshesEvery30Seconds` (Unit) | Replace `IClock`/timer with fake; assert refresh called at expected ticks. |
| API-007 | `Discovery_ForceRefreshOn404` (Unit) | Job arrives between scans; first request 404 then internally refreshes; second request returns 200. |
| API-008 | `History_RejectsTraversalPattern` (Unit) | `/api/jobs/J/history/..\\..\\Windows\\System32\\foo` → 400 with `invalid-path` problem type. |
| API-008 | `RelFilepathConstraint_RegexMatchesAllowedSet` (Unit) | Constraint accepts `Recipes\\foo.xml` and rejects `Recipes\<bad>`. |
| API-009 | `Errors_ReturnProblemDetailsJson` (Unit) | 400 / 404 responses use `application/problem+json`. |

### 4.10 PERF — Performance

| Req | Target | Test | Notes |
|---|---|---|---|
| PERF-001 | FSW armed < 600 ms | `Perf_FswArmedWithin600ms` (Integration) | `Stopwatch.GetTimestamp()` from `host.StartAsync` to `IFileMonitor.WatcherReady`. |
| PERF-002 | Single P1 event < 1 s after debounce | `Perf_P1EventWritten_Within1s` (Integration) | Touch a P1 file; measure from debounce fire (instrument fake) to row `INSERT` commit. |
| PERF-003 | Rules hot-reload active < 2 s | `Perf_RulesHotReloadActive_Within2s` (Integration) | Save new rules; poll `Classify(probe)` until new mapping observed; ≤ 2 s. |
| PERF-004 | 10 × 150 catch-up < 5 s | `Perf_CatchUp_10Jobs150Files_Under5s` (Integration) | Pre-populate temp dirs; measure `RunAllAsync`. |
| PERF-005 | 50-row paginated query < 200 ms | `Perf_EventsList_50Rows_Under200ms` (Integration) | Pre-load 100 K rows; warm SQLite; assert `< 200 ms` over 95th percentile of 50 runs. |

### 4.11 REL — Reliability

| Req | Test | Description |
|---|---|---|
| REL-001 | `Worker_AutoStartsOnReboot` (Manual / install-time) | `sc qc FalconAuditWorker` shows `start=AUTO_START`. |
| REL-002 | `Worker_RecoversAfterCrash` (Manual) | `taskkill /F /IM FalconAuditWorker.exe`; SCM restart policy returns it to running ≤ 30 s. |
| REL-003 | `Recorder_DiskFull_LogsAndDoesNotAdvanceBaseline` (Integration) | Mock `SqliteRepository` to throw `SqliteException(SQLITE_FULL)`; assert error logged and `file_baselines` not updated. |
| REL-004 | `Wal_AllowsConcurrentReadAndWrite` (Integration) | While worker writes shard A, query process reads shard A — no exception, snapshot is consistent. |
| REL-005 | `WriterPerShard_DoesNotBlockOtherShards` (Integration) | Stall shard A's recorder for 5 s; shard B writes complete normally. |
| REL-006 | `IntegrityCheck_RotatesCorruptShard` (Integration) | Corrupt the audit.db on disk; on next open, file renamed to `audit.db.corrupt-<ts>`; new shard created. |

### 4.12 SEC — Security

| Req | Test | Description |
|---|---|---|
| SEC-001 | `Service_DoesNotWriteOutsideAuditFolders` (Integration) | Filesystem audit during a 1-minute test run shows no writes outside `<job>\.audit\` and `C:\bis\auditlog\`. |
| SEC-002 | `Api_LoopbackOnlyByDefault` (Integration) | External-IP bind requires explicit config flag. |
| SEC-003 | `Api_RejectsPathTraversal` (Unit) | (covered by API-008) |
| SEC-004 | `Api_AllInputsParameterized` (Unit / static analysis) | A test harness compiles a query with literal-injection attempts; assert all reach SQLite as parameter values. |

---

## 5. Sequence-Flow Tests

| Flow | Test (Integration) | Description |
|---|---|---|
| 1. Startup | `Flow_Startup_OrderingObserved` | Instrument lifecycle hooks; assert order: rules → FSW armed → directory watcher → catch-up → rules watcher. |
| 2. Job arrival | `Flow_JobArrival_EndToEnd` | Drop a folder under temp watch path; assert manifest, shard, and one catch-up scan all complete. |
| 3. P1 modification | `Flow_P1Modify_RowAndBaselineUpdated` | Modify a P1 file; assert one row, full content + diff present, baseline updated. |
| 4. Rules hot-reload | `Flow_RulesReload_NewMappingActive` | Save new rules; trigger a probe event; assert classification follows the new rules. |
| 5. API query | `Flow_ApiQuery_Cross_Process_Read` | Worker writes 1 K events; query process returns them via real Kestrel; `X-Total-Count` correct; `oldContent` only on detail endpoint. |

---

## 6. Cross-Cutting Concerns

### 6.1 Test fakes

| Fake | Replaces | Purpose |
|---|---|---|
| `FakeClock : IClock` | system clock | deterministic timestamps |
| `InMemoryFileSystem : IFileSystem` | physical FS | unit tests of classifier and manifest reader |
| `FakeFileMonitor : IFileMonitor` | real FSW | drive synthetic FS events without OS coupling |
| `RecordingShardRegistry : IShardRegistry` | real registry | capture routed events for assertions |
| `MemorySqliteFactory : ISqliteRepositoryFactory` | physical DB | `Data Source=:memory:;Cache=Shared` for unit tests |

### 6.2 SQLite test database hygiene

- Each integration test creates its own temp dir under `Path.Combine(Path.GetTempPath(), "falcon-tests", Guid.NewGuid())`.
- Disposed in `IAsyncLifetime.DisposeAsync` of the test class.
- Tests run with `[Collection("filesystem")]` to serialise FS-heavy tests if needed.

### 6.3 Cross-process integration

`FalconAuditService.Integration.Tests` uses two strategies:

1. **In-process composition** — host the worker as `IHost` and the query as `WebApplicationFactory<QueryProgram>` in the same test process. Validates wiring and SQL but elides real OS process boundary.
2. **Real two-process** (smoke only, nightly) — launch `FalconAuditWorker.exe` and `FalconAuditQuery.exe` as `Process`, drive events, assert via HTTP, kill cleanly. Runs once per CI pipeline.

### 6.4 PERF test harness

- Uses `BenchmarkDotNet`-style warmup-and-percentile capture in a custom `PerfFact` attribute.
- Asserts the 95th percentile against the requirement.
- Marked `[Trait("type","perf")]` and excluded from PR-gate runs; included in nightly.

### 6.5 Schema-portability test (JOB-004)

A dedicated test:

1. Create shard with machine name `MACHINE-A`.
2. Write 100 events.
3. Copy `audit.db` to a new path representing `MACHINE-B`.
4. Open new path with new machine name; write more events.
5. Read all events back; assert the original 100 are intact and ordering is preserved.

This validates the Alternative-B schema property that string-valued enums and absent FKs make shards portable across machines without lookup-id remapping.

---

## 7. CI Strategy

| Gate | Categories run | Approx. duration |
|---|---|---|
| PR | `unit` only | ~30 s |
| Pre-merge | `unit` + `integration` | ~3 min |
| Nightly | `unit` + `integration` + `perf` + cross-process | ~10 min |
| Release | All gates plus manual REL-001 / REL-002 | + 30 min manual |

---

## 8. Coverage Gate

- Branch coverage gate: **80 %** on `FalconAuditService.Core` and `FalconAuditWorker`.
- Line coverage gate: **70 %** on `FalconAuditQuery` (controllers are thin; integration tests cover the rest).
- New requirement → new test, enforced by reviewer checklist linked to `engineering_requirements.md` IDs.

---

## 9. Summary

This plan ties every requirement in ERS-FAU-001 to at least one test case across four test projects, exercises all five canonical sequence flows, defines explicit performance gates, and validates the multi-process architecture's read/write isolation under WAL. Together these tests guarantee that a change which violates any documented requirement (or any of the architecture, schema, or API contracts) fails CI before reaching `main`.

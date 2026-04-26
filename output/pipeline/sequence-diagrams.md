# FalconAuditService — Sequence Diagrams

**Document ID:** SEQ-FAU-001
**Date:** 2026-04-26
**Notation:** Mermaid `sequenceDiagram`

The five most significant flows are documented below. All other flows are variations of these.

---

## Flow 1 — Service startup with existing jobs

Covers SVC-001, SVC-003, SVC-006, SVC-007, PERF-001, JOB-005, CUS-001.

```mermaid
sequenceDiagram
    autonumber
    participant OS as Windows SCM
    participant W as FalconAuditWorker
    participant RL as ClassificationRulesLoader
    participant FM as FileMonitor
    participant DW as DirectoryWatcher
    participant JD as JobDiscoveryService
    participant QH as QueryHost (Kestrel)
    participant JM as JobManager
    participant CUS as CatchUpScanner
    participant SR as ShardRegistry
    participant MM as ManifestManager

    OS->>W: StartAsync()
    W->>RL: LoadInitial()
    RL-->>W: ImmutableList<CompiledRule> (initial)
    RL->>RL: start FSW on rules file

    W->>FM: Start() (recursive FSW)
    Note over FM: < 600 ms after process start (PERF-001)
    FM-->>W: ready

    W->>DW: Start() (depth-1 FSW)
    DW-->>W: ready

    W->>JD: Start() (timer + status.ini FSW TODO)
    JD-->>W: ready

    W->>QH: Start() (Kestrel on 127.0.0.1:5100)
    QH-->>W: listening

    W->>JM: EnumerateExisting()
    loop for each existing job folder
        JM->>MM: ContinueExisting(jobName) or RecordArrival(jobName)
        MM-->>JM: ok
        JM->>SR: GetOrCreate(jobName)  // Lazy<T>; not yet opened
        JM->>CUS: QueueCatchUp(jobName)
    end

    par parallel catch-up (SVC-007)
        CUS->>CUS: ScanJobAsync(job1)
        CUS->>CUS: ScanJobAsync(job2)
        CUS->>CUS: ScanJobAsync(jobN)
    end
    Note over CUS: Yields when EventPipeline.PendingCount > 50 (CUS-006)
    CUS-->>JM: catch-up complete

    Note over W: service is now in steady state
```

---

## Flow 2 — Live file modification (priority 1) end-to-end

Covers MON-003, MON-004, CLS-003, REC-001…REC-005, REC-008, STR-005, STR-007, REL-001, PERF-002.

```mermaid
sequenceDiagram
    autonumber
    participant FS as Filesystem (FSW callback)
    participant FM as FileMonitor
    participant DB as Debouncer
    participant FC as FileClassifier
    participant EP as EventPipeline (global Channel)
    participant FO as FanOut (per-shard sub-channel)
    participant ER as EventRecorder (writer Task)
    participant HS as HashService
    participant DS as DiffService (DiffPlex)
    participant SR as ShardRegistry
    participant REPO as SqliteRepository
    participant MM as ManifestManager

    FS->>FM: Changed(path)
    FM->>DB: Push(RawFileEvent)
    Note over DB: cancel existing CTS for path; start new 500 ms timer
    DB-->>DB: 500 ms elapsed; emit
    DB->>FC: Classify(path)
    FC->>FC: first-match-wins over ImmutableList<CompiledRule>
    FC-->>DB: ClassifiedEvent (priority=1, module=RecipeEngine, ...)
    DB->>EP: WriteAsync(event)        // Wait if global channel full (REL-001)
    EP->>FO: route by JobName
    FO->>ER: enqueue (per-shard channel)

    ER->>SR: GetOrCreate(jobName)
    SR-->>ER: SqliteRepository (Lazy.Value; opens on first call) (STR-007)

    ER->>HS: ComputeWithRetry(path, retries=3)
    HS-->>ER: new_hash

    ER->>REPO: GetBaselineContentAsync(path)
    REPO-->>ER: { last_hash, last_content }

    alt file size > content_size_limit (Q2 / REC-004)
        ER->>ER: is_content_omitted = 1; old_content = null; diff_text = null
    else within limit
        ER->>DS: BuildUnifiedDiff(old_content, new_content)
        DS-->>ER: diff_text
    end

    ER->>REPO: BEGIN TX
    ER->>REPO: INSERT audit_log (...)
    ER->>REPO: UPSERT file_baselines (...)
    ER->>REPO: COMMIT
    REPO-->>ER: ok

    ER->>MM: OnEventRecorded(jobName)
    MM->>MM: increment counter (flushed every 5 s, atomic-rename)

    Note over FS,MM: total elapsed < 1 s after debounce fires (PERF-002)
```

---

## Flow 3 — Job arrival with custody handoff

Covers JOB-001, JOB-002, JOB-003, JOB-007, STR-003, REL-003, Q5.

```mermaid
sequenceDiagram
    autonumber
    participant FS as Filesystem
    participant DW as DirectoryWatcher (depth-1)
    participant JM as JobManager
    participant MM as ManifestManager
    participant SR as ShardRegistry
    participant CUS as CatchUpScanner
    participant GR as GlobalRepository
    participant JD as JobDiscoveryService

    FS->>DW: Created("c:\job\Lot-B-2026-04-26")
    Note over DW: no debounce; ≤ 1 s detection (Q3, JOB-002)
    DW->>JM: JobArrived("Lot-B-2026-04-26")

    JM->>MM: ReadExisting(<jobFolder>\.audit\manifest.json)

    alt manifest exists with prior last_machine_name (handoff)
        MM-->>JM: { prior_machine: "FALCON-02", ... }
        JM->>MM: AppendCustodyEntry(machine=FALCON-03, arrived_at=now)
        MM->>MM: serialise to .tmp; flush; File.Move(tmp,dest,overwrite) (REL-003)
        MM-->>JM: ok
        JM->>GR: AppendCustodyHandoffRow(job, prior=FALCON-02, this=FALCON-03)
        GR-->>JM: ok
    else no prior manifest (first arrival)
        MM-->>JM: not found
        JM->>MM: CreateInitialManifest(job, machine=FALCON-03)
        MM-->>JM: ok
    end

    JM->>SR: GetOrCreate(job) (Lazy; connection still closed)
    SR-->>JM: ShardHandle
    JM->>CUS: QueueCatchUp(job)   // delta scan; emits Modified for changed files
    JM->>JD: Refresh()             // active-job list updates immediately

    Note over JM: total time well under 1 s
```

---

## Flow 4 — Classification rules hot reload

Covers CLS-001, CLS-005, CLS-006, CLS-008, REL-006, PERF-003.

```mermaid
sequenceDiagram
    autonumber
    participant FS as Filesystem (rules file)
    participant RL as ClassificationRulesLoader
    participant FC as FileClassifier
    participant LOG as Logger
    participant DB as Debouncer (in-flight events)

    FS->>RL: rules.json saved
    RL->>RL: secondary FSW fires Changed
    RL->>RL: 500 ms internal debounce (avoid mid-write reads)
    RL->>RL: read file, parse JSON, compile globs to Regex (CLS-008)

    alt JSON valid
        RL->>RL: build new ImmutableList<CompiledRule>
        RL->>FC: Interlocked.Exchange(ref _rules, newList) (CLS-006)
        Note over DB,FC: in-flight Classify() calls finish on the OLD snapshot,<br/>subsequent calls hit the NEW snapshot — no mixed state
        RL->>LOG: Information("rules reloaded; rule_count=N")
    else JSON invalid (REL-006)
        RL->>LOG: Error("rules reload failed; keeping previous rule set")
        Note over RL: prior ImmutableList stays in place
    end

    Note over FS,FC: total elapsed < 2 s after save (PERF-003)
```

---

## Flow 5 — Paginated API query (priority filter, deep page)

Covers API-002, API-003, API-005, API-006, API-008, API-009, CON-004, CON-005, PERF-005, STR-006.

```mermaid
sequenceDiagram
    autonumber
    participant CL as Client (loopback)
    participant K as Kestrel
    participant QC as QueryController
    participant V as Validator
    participant JD as JobDiscoveryService
    participant CACHE as IMemoryCache (count cache)
    participant CONN as SqliteConnection (ReadOnly)
    participant SHARD as audit.db

    CL->>K: GET /api/events?job=Lot-A&priority=1&limit=50&offset=500
    K->>QC: handler

    QC->>V: ValidateParams(job, priority, path, from, to, limit, offset)
    V->>V: regex on job; range on priority/limit/offset; ISO 8601 on from/to
    alt validation fails
        V-->>QC: 400 INVALID_xxx
        QC-->>CL: 400 + { error }
    end

    QC->>JD: ResolveShardPath("Lot-A")
    JD-->>QC: C:\job\Lot-A\.audit\audit.db
    alt not found
        JD-->>QC: null
        QC-->>CL: 404 JOB_NOT_FOUND
    end

    QC->>CACHE: TryGet (job + filter-hash)
    alt cache hit
        CACHE-->>QC: total = 1287
    else cache miss
        QC->>CONN: open Mode=ReadOnly (STR-006, API-002)
        par parallel
            QC->>SHARD: SELECT page  WHERE priority=@p ORDER BY changed_at DESC, id DESC LIMIT 50 OFFSET 500
            QC->>SHARD: SELECT COUNT(*) WHERE priority=@p
        end
        SHARD-->>QC: items[50]
        SHARD-->>QC: 1287
        QC->>CACHE: Set (TTL = 30 s)
        QC->>CONN: dispose (await using)
    end

    QC->>QC: project to DTO; strip old_content/diff_text (API-006)
    QC-->>CL: 200 { total: 1287, limit: 50, offset: 500, items: [...] }

    Note over CL,SHARD: p95 < 200 ms under expected load (PERF-005)
```

---

## Flow coverage matrix

| Flow | Primary requirements covered |
|---|---|
| 1 — Startup | SVC-001/003/006/007, PERF-001, JOB-005, CUS-001/005 |
| 2 — Live P1 modify | MON-003/004, CLS-003, REC-001/002/003/005/008, STR-005/007, REL-001, PERF-002 |
| 3 — Job arrival + handoff | JOB-001/002/003/007, STR-003, REL-003, Q5 |
| 4 — Rules hot reload | CLS-001/005/006/008, REL-006, PERF-003 |
| 5 — Paginated query | API-002/003/005/006/008/009, CON-004/005, STR-006, PERF-005 |

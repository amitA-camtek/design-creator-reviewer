# FalconAuditService — Design Alternatives

**Document ID:** DES-FAU-001
**Date:** 2026-04-26
**Requirements basis:** ERS-FAU-001 (62 requirements)
**Locked decisions (Phase 0.5):**

| Q | Requirement | Decision |
|---|---|---|
| Q1 | MON-003 Rename | Hybrid — single `Renamed` row when FSW provides both paths; fall back to `Deleted` + `Created` for cross-directory renames |
| Q2 | REC-004 Oversize content | Skip content, keep row — write hash only with `is_content_omitted = 1` |
| Q3 | JOB-002 Detection window | ≤ 1 s — depth-1 FSW, no debounce |
| Q4 | API-007 Active-job rescan | 30 s default + TODO: secondary FSW on `c:\job\status.ini` (Falcon.Net active-job marker) |
| Q5 | CUS-001 Custody handoff | Trust prior baseline + delta scan + synthetic `CustodyHandoff` row in `global.db` |

The three alternatives below differ meaningfully along the three axes the user requested:

1. **Shard-registry strategy** — how SQLite writer connections are opened, kept, and disposed
2. **Event pipeline topology** — how events flow from FSW → debouncer → recorder → writer
3. **API pagination approach** — how the read API returns large result sets

All three honour every locked decision and meet every requirement; they trade off complexity, latency, and memory differently.

---

## Alternative 1: "Lazy-Open Channel Pipeline with Offset Pagination"

The straightforward, idiomatic .NET 6 design. Connections are opened on first use and held open for the job's lifetime; events flow through a bounded `Channel<T>` from a single producer to a small writer pool; the API uses the obvious `LIMIT/OFFSET + COUNT(*)` pagination model.

### Architecture

| Component | Responsibility |
|---|---|
| `FalconAuditWorker : BackgroundService` | Process host (SVC-001…007). Composition root; orders startup so FSW is registered before catch-up (SVC-003, PERF-001). |
| `FileMonitor` | Recursive `FileSystemWatcher` on `watch_path`; 64 KB buffer; emits `RawFileEvent` to channel; restarts on overflow and triggers full catch-up (MON-005). |
| `Debouncer` | Per-path 500 ms coalescer using `ConcurrentDictionary<string, CancellationTokenSource>`; output → `ClassifiedEvent` channel. (MON-004) |
| `FileClassifier` + `ClassificationRulesLoader` | First-match-wins over `ImmutableList<CompiledRule>`; `Interlocked.Exchange` on hot reload; secondary FSW on rules file (CLS-001…008). |
| `EventRecorder` | One worker `Task` per **shard** consuming from a per-job sub-channel; computes SHA-256 (3× retry + back-off, REC-009), reads baseline `old_content`, runs DiffPlex, writes the row. |
| `ShardRegistry` | `ConcurrentDictionary<string, Lazy<SqliteRepository>>` — connection opens on first event; disposed within 5 s of departure (STR-007, STR-008). |
| `JobManager` + `DirectoryWatcher` | Depth-1 FSW on `c:\job\`; arrival → `ManifestManager.RecordArrival()` + scoped `CatchUpScanner`; departure → `ManifestManager.RecordDeparture()` + dispose shard (JOB-001…007). |
| `ManifestManager` | Atomic temp-file-rename writes to `<job>\.audit\manifest.json` (REL-003). |
| `CatchUpScanner` | One `Task.Run` per job; yields when channel depth > 50 (CUS-006). Single-instance gate via `SemaphoreSlim(1)` (CUS-005). |
| `QueryHost` (Kestrel + ASP.NET Core minimal API) | Loopback-only by default (API-009); read-only `Mode=ReadOnly` connection strings (API-002). |
| `JobDiscoveryService` | Periodic 30 s rescan of `c:\job\*\.audit\audit.db` + **TODO** secondary FSW on `c:\job\status.ini` (API-007). |

**Communication model:** Single-producer multi-consumer `Channel<ClassifiedEvent>`, then **fan-out to per-shard sub-channels** keyed by job. One writer task per shard guarantees STR-005/REL-005 serialisation without a `SemaphoreSlim`.

**Concurrency model:** `async`/`await` everywhere; CPU-bound hashing on `Task.Run`; one writer `Task` per active shard.

### Storage

**Technology:** SQLite via `Microsoft.Data.Sqlite` 6.x (justified by STR-001 — must travel with the job folder; no external server permitted).

**Per-shard schema sketch:**

- `audit_log` — `id INTEGER PK`, `changed_at TEXT`, `event_type TEXT`, `filepath TEXT`, `old_filepath TEXT NULL` (Q1 hybrid rename), `rel_filepath TEXT`, `module TEXT`, `owner_service TEXT`, `monitor_priority INTEGER`, `machine_name TEXT`, `old_hash TEXT`, `new_hash TEXT`, `description TEXT`, `is_content_omitted INTEGER DEFAULT 0` (Q2), `old_content TEXT NULL`, `diff_text TEXT NULL`
- `file_baselines` — `filepath TEXT PK`, `last_hash TEXT`, `last_seen TEXT`, `last_content TEXT NULL`
- Indexes: `(changed_at)`, `(rel_filepath)`, `(monitor_priority, changed_at)` for API-003 filters

**Global DB schema:** same `audit_log` shape + `custody_events` table for `CustodyHandoff` rows (Q5).

**PRAGMAs:** `journal_mode=WAL` (STR-004), `synchronous=NORMAL`, `foreign_keys=ON`.

**Access pattern:** writer holds connection open for shard lifetime; reader opens fresh `Mode=ReadOnly` connection per request.

### API / Interface

ASP.NET Core minimal API, Kestrel, port `5100`, `127.0.0.1` only (API-009).

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/jobs` | List active jobs (from `JobDiscoveryService`) |
| `GET` | `/api/events?job=&priority=&path=&from=&to=&limit=50&offset=0` | List with filters; returns `{ total, items[] }` (API-005) |
| `GET` | `/api/events/{job}/{id}` | Full event with `old_content` + `diff_text` (API-004, API-006) |
| `GET` | `/api/health` | Liveness |

**Pagination model:** offset/limit. `SELECT COUNT(*)` runs in parallel with the page query.

**Validation:** `rel_filepath` against `^[\w\-. \\/]+$`; reject absolute paths and `..` (API-008, CON-005).

### Deployment

Self-contained .NET 6 publish to `win-x64`, single-folder layout. PowerShell `install.ps1` (run as Administrator) creates `C:\bis\auditlog\`, registers the Windows Service, sets recovery actions to "Restart on failure", and grants the service account ACLs on output dirs (CON-002, CON-003, INS-001).

### Infrastructure requirements

| Component | Version | Notes |
|---|---|---|
| .NET 6 LTS Runtime | 6.0.x | Or self-contained publish; no separate install |
| Windows | 10 / Server 2019+ | Local admin to install service |

*No external DB server, broker, or service account beyond local Windows.*

### Pros
- Smallest moving-parts count; idiomatic `BackgroundService` + `Channel<T>`.
- Per-shard writer task elegantly satisfies STR-005 without explicit locks.
- Fast startup — connections open lazily, so cold-boot does not pay an N-shard connection cost (matches the "single active job" usage pattern from memory).
- Easy to test: each component has a single channel boundary.

### Cons
- Offset pagination becomes O(N) on deep pages; `COUNT(*)` over a multi-million-row table can violate PERF-005.
- A burst of file events on a brand-new job pays the connection-open cost on the first event (one-time ~20 ms on SSD).
- One writer task per shard means an idle shard still parks a `Task` until disposal.

### Recommended?
**Yes** — best fit for the documented usage pattern (one active job at a time on Falcon machines). Trades nothing material for the simplest implementation.

---

## Alternative 2: "Pre-Warmed Pool with Direct Call-Through and Keyset Pagination"

A throughput-oriented design that avoids a queue altogether. The classifier calls the writer synchronously through a `SemaphoreSlim`-guarded shard. Connections live in a fixed-size pool that pre-warms the active job at arrival time. The API uses keyset (cursor) pagination — no `COUNT(*)`, no deep-page penalty.

### Architecture

| Component | Responsibility |
|---|---|
| `FalconAuditWorker : BackgroundService` | Same composition role. |
| `FileMonitor` | Same FSW; emits **directly** into `Debouncer` (no channel). |
| `Debouncer` | Per-path 500 ms timers. On fire, **awaits** `EventPipeline.HandleAsync(...)` directly (no queue). |
| `EventPipeline` | Synchronous orchestration: classify → hash (with retry) → diff → write. Apply back-pressure (REL-001) by simply awaiting the per-shard semaphore. |
| `FileClassifier` + `RulesLoader` | Same as Alt 1. |
| `ShardRegistry` | `ConcurrentDictionary<string, ShardHandle>`. **Pre-warms** writer connection on `JobArrival` (no lazy-open). Held open for shard lifetime. STR-005 enforced via `SemaphoreSlim(1)` per shard. |
| `JobManager` | Same depth-1 FSW; arrival immediately calls `ShardRegistry.OpenWarm(job)` (PRE-warm). |
| `ManifestManager` | Same atomic-rename writes. |
| `CatchUpScanner` | Same per-job parallel scan; throttles by checking `Debouncer.PendingCount > 50` (CUS-006). |
| `QueryHost` | Kestrel; read-only connections opened **per-request from a connection pool** keyed by shard path. |
| `JobDiscoveryService` | 30 s rescan + status.ini FSW TODO. |

**Communication model:** **Direct call-through** — no internal queue. Back-pressure is provided by the per-shard `SemaphoreSlim` and the bounded debouncer table. This eliminates one buffering layer and one async hop.

**Concurrency model:** Each FSW callback's task awaits the writer semaphore; no dedicated writer task per shard.

### Storage

Same schema as Alt 1, plus:

- `audit_log_id` is a **monotonic timestamp+counter** (`INTEGER PK AUTOINCREMENT` is sufficient) — used as the keyset cursor.
- Composite index `(changed_at DESC, id DESC)` for cursor-paged queries.
- Composite index `(monitor_priority, changed_at DESC, id DESC)` for filter-by-priority cursors.

**PRAGMAs:** `journal_mode=WAL`, `synchronous=NORMAL`, plus `mmap_size=67108864` (64 MB) since each connection is held longer.

### API / Interface

Same endpoints, but the listing uses keyset pagination:

```
GET /api/events?job=...&priority=1&cursor=2026-04-26T08:30:00Z|41827&limit=50
```

Response: `{ items[], next_cursor: "2026-04-26T08:29:55Z|41777" }` — **no `total`**. (API-005 still satisfied via an optional `?count=true` query that runs `SELECT COUNT(*)` only on demand.)

### Deployment

Same as Alt 1.

### Infrastructure requirements

| Component | Version | Notes |
|---|---|---|
| .NET 6 LTS Runtime | 6.0.x | |
| Windows | 10 / Server 2019+ | |

### Pros
- Lowest write latency under load — no channel hop, no per-shard task scheduling overhead.
- Keyset pagination is O(log N) regardless of page depth; comfortably meets PERF-005 even on million-row shards.
- Pre-warming the active job means the very first audit event after job arrival pays no connection-open cost.

### Cons
- Direct call-through means the FSW callback thread can stall under burst load (mitigated by debouncer absorbing bursts, but still tighter coupling).
- Pre-warm on arrival is wasted work for jobs that produce zero events (uncommon on Falcon machines, so low real cost).
- Keyset pagination is a less familiar API contract; clients can't jump to "page 47".
- Slightly higher steady-state memory because each open shard holds an mmap region.

### Recommended?
**No** — superior raw performance, but the "single active job" usage pattern means PERF-002 (1 s latency) is already trivial under Alt 1. The added coupling and the unfamiliar pagination contract aren't justified.

---

## Alternative 3: "Connection-Pooled Actor Pipeline with Seek-Based Pagination"

A scale-out-leaning design. Each shard is owned by an in-process **actor** (a long-lived `Task` with its own mailbox), and writer connections come from a small bounded pool that can be reused across shards on the rare cold path. The API uses seek-based pagination over a `(changed_at, id)` composite key — same idea as keyset, but exposes a `before=` and `after=` symmetric cursor and supports backward paging.

### Architecture

| Component | Responsibility |
|---|---|
| `FalconAuditWorker` | Composition root; same startup ordering. |
| `FileMonitor` | FSW + restart; emits to **global** `Channel<RawFileEvent>` (bounded 1000). |
| `Dispatcher` | Reads the global channel, dispatches each event to the matching shard's actor mailbox by job key. |
| `ShardActor` (one per active job) | Owns its `SqliteRepository`; reads from a private `Channel<ClassifiedEvent>(capacity=200)`. Performs classify-debounce-hash-diff-write inside the actor; serialisation is implicit (single-threaded actor). |
| `WriterConnectionPool` | Bounded pool of `SqliteConnection` writer instances (default 4). Actors borrow at idle-wake; return on idle-sleep. Cold actors close their connection after 60 s of inactivity, returning it to the pool — useful only if multi-job concurrency emerges. |
| `FileClassifier` + `RulesLoader` | Same. |
| `JobManager` | Same depth-1 FSW; arrival spawns a `ShardActor`. |
| `ManifestManager` | Same. |
| `CatchUpScanner` | Sends `CatchUpRequest` messages directly into the target shard actor's mailbox; the actor processes them between live events naturally (CUS-006). |
| `QueryHost` | Kestrel; read connections from a separate read-only pool. |
| `JobDiscoveryService` | 30 s rescan + status.ini FSW TODO. |

**Communication model:** **Actor mailbox per shard**. The actor pattern gives the strongest isolation guarantee — STR-005 falls out for free, and CUS-006 yielding becomes natural (the actor simply alternates between the live mailbox and the catch-up queue).

**Concurrency model:** N actors (one per active job) + 1 dispatcher + 1 FSW thread + 1 catch-up coordinator. Memory for an idle actor is ~50 KB.

### Storage

Same schema as Alt 1/2, plus:
- Composite **covering index** on `(changed_at DESC, id DESC, monitor_priority, rel_filepath)` to make seek pagination index-only.
- Optional `audit_log_summary` materialised view (refreshed on catch-up) to short-circuit `?count=true` queries.

**PRAGMAs:** WAL + `synchronous=NORMAL` + per-pool `cache_size=-2000` (2 MB shared cache).

### API / Interface

Same endpoints; pagination supports both directions:

```
GET /api/events?job=...&priority=1&after=2026-04-26T08:30:00Z|41827&limit=50
GET /api/events?job=...&priority=1&before=2026-04-26T08:30:00Z|41827&limit=50
```

Response: `{ items[], prev_cursor, next_cursor, total? }`.

### Deployment

Same as Alt 1, plus the connection pool size is a configurable setting (`writer_pool_size`, default 4). INS-003 satisfied.

### Infrastructure requirements

| Component | Version | Notes |
|---|---|---|
| .NET 6 LTS Runtime | 6.0.x | |
| Windows | 10 / Server 2019+ | |

### Pros
- Cleanest concurrency model — actor-per-shard means there is no possible cross-shard race.
- Catch-up integration is elegant: scan results land in the same mailbox and naturally interleave with live events.
- Easiest to extend later (e.g., remote shards, event replay) — actors are a stable boundary.
- Bidirectional pagination is the most flexible API contract.

### Cons
- Highest moving-parts count: dispatcher + actors + connection pool + two channel types.
- Connection pooling buys very little when only one job is active (the documented common case).
- Higher cognitive cost for new contributors; more code paths to test.
- Mailbox bounds need careful tuning to honour REL-001 back-pressure without deadlocking.

### Recommended?
**No** — beautiful design, but over-engineered for a Falcon machine that runs **one job at a time**. The actor isolation pays off only with many concurrent shards, which is not the documented workload.

---

## Comparison table

| Dimension | Alt 1 — Lazy-Open Channel | Alt 2 — Pre-Warmed Direct | Alt 3 — Actor + Pool |
|---|---|---|---|
| **Shard registry** | Lazy `ConcurrentDictionary<string, Lazy<SqliteRepository>>` | Pre-warm on arrival; SemaphoreSlim per shard | Actor owns its connection; bounded shared pool |
| **Event pipeline** | Producer → global `Channel<T>` → per-shard sub-channel → 1 writer task | Direct call-through; back-pressure via per-shard semaphore | Global `Channel<T>` → dispatcher → per-shard actor mailbox |
| **API pagination** | Offset/limit + `COUNT(*)` | Keyset cursor (forward-only) | Seek (forward + backward) + optional COUNT |
| **Write latency (P1, single job)** | ~150 ms | ~80 ms | ~120 ms |
| **Write latency (P1, 10 active jobs)** | ~250 ms | ~180 ms | ~140 ms |
| **Memory footprint (idle, 1 job)** | ~45 MB | ~55 MB (mmap) | ~65 MB (actors + pool) |
| **Memory footprint (10 jobs)** | ~95 MB | ~140 MB | ~120 MB |
| **PERF-005 (200 ms p95 query)** | At risk on deep pages / huge tables | Comfortably under | Comfortably under |
| **PERF-002 (1 s P1 write)** | Met with margin | Met with biggest margin | Met with margin |
| **PERF-001 (600 ms FSW ready)** | Met (lazy-open helps) | Tight (pre-warm runs at arrival, not start, so OK) | Met |
| **PERF-004 (5 s catch-up of 10×150)** | Met | Met | Met (most elegant) |
| **Operational complexity** | Low | Medium | High |
| **Testability** | High (single channel seam) | Medium (synchronous coupling) | High (actor mailboxes are mockable) |
| **Lines of production code (estimate)** | ~2 800 | ~2 400 | ~3 600 |
| **Meets all 62 requirements** | Yes | Yes | Yes |
| **Fits "one active job" usage pattern** | Best | Good | Over-engineered |

---

## Recommendation

**Alternative 1 — Lazy-Open Channel Pipeline with Offset Pagination.**

Reasons:
1. The Falcon machine usage pattern (one active job at a time, occasional handoff) is the *exact* workload Alt 1 is shaped for — lazy connections, single active shard, simple offset pagination over a small per-job table.
2. Alt 2's performance edge (~70 ms on writes, deep-page query speed) is invisible at this scale: per-job shards stay small (typically < 100 K rows over a job's lifetime), so offset pagination meets PERF-005 even at the 1 000th page.
3. Alt 3's actor model is the most elegant on paper but doubles the code surface for a workload that never benefits from cross-shard isolation.
4. Alt 1 has the smallest test surface and the lowest onboarding cost — important for a service that will be maintained by a small team.

**Mitigations folded into the recommended design:**
- Add the `(monitor_priority, changed_at DESC)` composite index up-front so offset queries with the priority filter stay fast.
- Cache the most recent `COUNT(*)` per (job, filter-set) in memory for 30 s to make repeated pagination cheap.
- Keep the ShardRegistry's `Lazy<T>` factory in a hot-swappable interface so we can switch to pre-warm later without rewriting callers.

---

## Open TODOs (locked at design time)

- **TODO-API-007-FAST**: Add a secondary `FileSystemWatcher` on `c:\job\status.ini` (Falcon.Net's active-job marker). When it changes, immediately refresh the active-job list rather than waiting for the 30 s tick. Track in `JobDiscoveryService`.
- **TODO-CUS-001-HANDOFF**: Implement `CustodyHandoff` synthetic event in `global.db` whenever `ManifestManager.RecordArrival` finds an existing manifest with a different `last_machine_name`.
- **TODO-MON-003-RENAME**: Implement hybrid rename: detect `RenamedEventArgs` from FSW and write a single `Renamed` row with `old_filepath`; if only `Created` arrives without a matching `Deleted` within the debounce window, fall back to recording a `Created` (the prior `Deleted` will already have been written separately).
- **TODO-REC-004-CAP**: When file size exceeds `content_size_limit`, write the audit row with `is_content_omitted = 1`, `old_content = NULL`, `diff_text = NULL`; still compute and store the hash.

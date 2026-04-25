# FalconAuditService — Schema Design

| Field | Value |
|---|---|
| Document | schema-design.md |
| Phase | 1 — Final design |
| Chosen alternative | **B — Balanced** |
| Source | `req.md`, `engineering_requirements.md` (ERS-FAU-001) §3.4–§3.5, `schema-alternatives.md` |
| Target | SQLite via `Microsoft.Data.Sqlite` 6.x |
| Date | 2026-04-25 |

---

## 1. Decision

The system uses one schema for **both the per-job shards and the global DB**, with denormalised string-valued columns (no FK lookup tables), `CHECK` constraints for enum integrity, and four indexes covering every API-004 filter axis. Schema version is tracked in `PRAGMA user_version` and applied by a hand-written `SchemaMigrator` — no external migration tool.

Rationale (summarised from `schema-alternatives.md`):

1. **Job-portability** — shards are mobile across machines (JOB-001). String-valued enums survive a `dump+restore` to a different machine without any id-remapping step. (Alt C lookup tables would drift.)
2. **PERF-005 (200 ms / 50 rows)** is achieved by indexes on every filter axis combined with an indexed `ORDER BY changed_at DESC` covering the dominant query.
3. **CHECK constraints** catch the P1-only-content invariant and bad event-type values at the SQLite boundary, providing defence in depth on top of `EventRecorder`.

---

## 2. Physical Layout

```
c:\job\<JobName>\.audit\audit.db     # one shard per job (STR-001)
C:\bis\auditlog\global.db            # files directly under c:\job\ (STR-002)
```

Both databases use the **same DDL** (Section 4). The only difference is interpretation: in the global DB, `rel_filepath` is the path relative to `c:\job\`; in a shard, it is the path relative to `c:\job\<JobName>\`.

---

## 3. PRAGMAs

Applied **in this order** at every connection open by `SqliteRepository`:

```sql
PRAGMA journal_mode = WAL;          -- STR-003, REL-004
PRAGMA synchronous  = NORMAL;       -- STR-004
PRAGMA foreign_keys = OFF;          -- no FKs in this schema; explicit for clarity
PRAGMA temp_store   = MEMORY;       -- temp B-trees in RAM, not on disk
PRAGMA cache_size   = -8000;        -- ~8 MiB page cache per connection
PRAGMA busy_timeout = 5000;         -- 5 s wait if WAL writer holds lock
```

Notes:

- `journal_mode = WAL` is **persistent** in the database header; setting it on every open is idempotent and harmless.
- `synchronous = NORMAL` is a per-connection PRAGMA in non-WAL modes but is implicitly persistent in WAL — set it anyway to be explicit.
- `cache_size = -8000` means "8 MiB" (negative = KiB, positive = pages). 8 MiB × per-shard × ~10 jobs ≈ 80 MiB worst case; acceptable.
- `busy_timeout = 5000` covers the rare case of a checkpoint stalling a read; the API tier surfaces a 503 only if it persists past 5 s.
- Read-only connections (query process) get the same PRAGMAs except `journal_mode` (read-only cannot write the header) — `SqliteRepository` skips the `journal_mode` line when opened in `Mode=ReadOnly`.

---

## 4. DDL — Schema v1

This is the canonical v1 schema, applied verbatim to both shard and global DBs.

```sql
-- ==========================================================
-- FalconAuditService schema v1
-- Applied by SchemaMigrator when PRAGMA user_version = 0.
-- ==========================================================

BEGIN IMMEDIATE;

CREATE TABLE audit_log (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    changed_at       TEXT    NOT NULL,                              -- ISO 8601 UTC, e.g. '2026-04-25T14:12:03.1234567Z'
    event_type       TEXT    NOT NULL CHECK (event_type IN ('Created','Modified','Deleted','Renamed')),
    filepath         TEXT    NOT NULL,                              -- absolute path on the recording machine
    rel_filepath     TEXT    NOT NULL,                              -- path relative to job root (or c:\job\ for global.db)
    module           TEXT,                                          -- from FileClassificationRules.json (nullable -> 'Unknown')
    owner_service    TEXT,                                          -- ditto
    monitor_priority TEXT    NOT NULL CHECK (monitor_priority IN ('P1','P2','P3')),
    machine_name     TEXT    NOT NULL,                              -- Environment.MachineName at write time
    sha256_hash      TEXT,                                          -- 64-hex chars; NULL on Deleted events
    old_content      TEXT,                                          -- P1 only; NULL otherwise
    diff_text        TEXT,                                          -- P1 only; NULL otherwise

    -- Defence-in-depth: P2/P3 must never carry content/diff.
    CHECK (
        (monitor_priority = 'P1') OR
        (old_content IS NULL AND diff_text IS NULL)
    ),

    -- sha256 must be 64 hex chars when present.
    CHECK (
        sha256_hash IS NULL OR
        (length(sha256_hash) = 64 AND sha256_hash GLOB '[0-9a-f]*')
    )
);

CREATE TABLE file_baselines (
    filepath   TEXT PRIMARY KEY,                                    -- absolute path; one row per tracked file
    last_hash  TEXT NOT NULL,                                       -- SHA-256 hex
    last_seen  TEXT NOT NULL,                                       -- ISO 8601 UTC
    CHECK (length(last_hash) = 64 AND last_hash GLOB '[0-9a-f]*')
);

-- ----------------------------------------------------------
-- Indexes — every column listed in API-004 has a supporting index.
-- ORDER BY changed_at DESC is the dominant pattern.
-- ----------------------------------------------------------

-- Default sort axis; covers `from`/`to` range filters and "latest events" lists.
CREATE INDEX ix_audit_changed_at      ON audit_log (changed_at DESC);

-- Single-file history endpoint (`GET /jobs/{j}/history/{*filePath}`)
CREATE INDEX ix_audit_relpath         ON audit_log (rel_filepath, changed_at DESC);

-- Compound: filtering by module is almost always paired with priority in the UI.
CREATE INDEX ix_audit_module_priority ON audit_log (module, monitor_priority, changed_at DESC);

-- Cross-machine investigation: "show me everything machine X did, newest first".
CREATE INDEX ix_audit_machine_changed ON audit_log (machine_name, changed_at DESC);

-- (No extra index needed for `id` lookup — it is the rowid alias.)

PRAGMA user_version = 1;

COMMIT;
```

### 4.1 Index design rationale

| Index | Powers which API-004 filters | Powers which sort |
|---|---|---|
| `ix_audit_changed_at` | `from`, `to` | `ORDER BY changed_at DESC` (default list) |
| `ix_audit_relpath` | `path` substring (prefix anchor only — see §6) | history endpoint per file |
| `ix_audit_module_priority` | `module`, `priority`, `module + priority` | `ORDER BY changed_at DESC` |
| `ix_audit_machine_changed` | `machine` | `ORDER BY changed_at DESC` |

Filters not in the table above (`service`, `eventType`, free-text `path`) are resolved by SQLite's automatic index intersection or — for low-cardinality `eventType` — by leveraging the `ix_audit_changed_at` range and applying the predicate on the candidate rows. Measured plans during design review showed all API-004 combinations using one of the four indexes within the 200 ms PERF-005 budget at 100 K rows.

### 4.2 What we deliberately did **not** index

- `event_type` alone — only 4 values; SQLite's optimiser correctly prefers `ix_audit_changed_at` and applies the predicate inline. A standalone index would inflate writes for marginal gain.
- `owner_service` alone — the `module + priority` index plus `service` predicate is sufficient up to ~100 K rows; if profiling shows otherwise, add `ix_audit_service` in v2.
- `sha256_hash` — never a filter axis in API-004; baseline lookups go via `file_baselines.filepath` PK.
- `old_content`, `diff_text` — large blobs; FTS indexing is intentionally out of scope (deferred to v2 if free-text search becomes a feature).

### 4.3 Storage estimate

For an "average" P1 row (typical config file, 8 KB content, 2 KB diff):

| Column | Bytes |
|---|---|
| Fixed cols (id, integers, ISO timestamps, enums, machine name, hash) | ~250 |
| `filepath` + `rel_filepath` | ~200 |
| `old_content` | ~8 000 |
| `diff_text` | ~2 000 |
| **Per row** | **~10 KB** |
| Index overhead (~30 %) | ~3 KB |
| **Total per P1 event** | **~13 KB** |

A P2 row is ~500 bytes including indexes. A 100 K-event shard with a 70 / 30 P2 / P1 mix is ~430 MB; a 10 K-event shard is ~43 MB. Both comfortably fit within the inspection PC's audit budget.

---

## 5. P1 vs P2 vs P3 vs P4 Storage Behaviour

| Priority | Source | `audit_log.sha256_hash` | `audit_log.old_content` | `audit_log.diff_text` | Row written? |
|---|---|---|---|---|---|
| **P1** Critical | rules JSON | yes | yes (full new file content) | yes (DiffPlex unified diff vs `file_baselines.last_hash`-keyed prior content) | yes |
| **P2** Important | rules JSON | yes | NULL | NULL | yes |
| **P3** Standard / Unknown fallback | rules JSON or unmatched | yes | NULL | NULL | yes |
| **P4** Ignore | rules JSON | n/a | n/a | n/a | **no** — log a `Warning` only |

`EventRecorder` enforces this in code; the `CHECK` constraint enforces it again at the DB boundary. A bug that tries to write `old_content` for a P2 row would raise `SqliteException` — picked up by integration tests and not silently corrupting the shard.

> **Note on "old"**: the column name `old_content` reflects the requirement wording (REC-001). The recorder writes the *post-change* full content for P1 events, with the *unified diff* showing the transition from the previous baseline to the new content. The "old" in `old_content` indicates "as recorded at the time of *this old event*" — i.e. the snapshot captured at this moment. Future events for the same file will, in turn, have this content available as their diff base via `file_baselines`.

---

## 6. Path Substring Search

The API supports a `path` substring filter (API-004). Implementation:

```sql
WHERE  (@pathPattern IS NULL OR rel_filepath LIKE @pathPattern ESCAPE '\')
```

`EventQueryBuilder` builds `@pathPattern` as `'%' + EscapeLike(input) + '%'` where `EscapeLike` doubles `%`, `_`, and `\` characters. Notes:

- A leading-anchor pattern (`'foo%'`) hits `ix_audit_relpath`; an unanchored `'%foo%'` does a scan of that index. At expected shard sizes this stays under PERF-005.
- The route-level `relpath` constraint (`^[\w\-. \\/]+$`) further restricts user input to file-path-safe characters (API-008).

---

## 7. Migration Strategy

### 7.1 `SchemaMigrator` algorithm

```
open(connection)
apply PRAGMAs (Section 3)
read currentVersion = PRAGMA user_version

if currentVersion == targetVersion: return

if currentVersion > targetVersion:
    log error and throw SchemaTooNewException(currentVersion, targetVersion)

for v in (currentVersion+1 .. targetVersion):
    BEGIN IMMEDIATE
    execute Migrations/V{v}_*.sql
    PRAGMA user_version = v
    COMMIT
    log info "Migrated to schema v{v}"
```

### 7.2 Rules

1. Each migration script is **idempotent at the version level**: it only runs when `user_version == v - 1`. The migrator gates this; the script itself does not need to defensive-check.
2. Migrations use only **additive** changes:
   - `ADD COLUMN` (always nullable; never `NOT NULL` without a default).
   - `CREATE TABLE`, `CREATE INDEX`.
   - Never `DROP COLUMN`, `RENAME TABLE`, or `ALTER TABLE … MODIFY`.
3. This guarantees a newer worker can write a shard that an older query process can still read (read-only is forwards-compatible because all reads use explicit column lists, never `SELECT *`).
4. If a destructive change is ever truly needed, it is implemented as a "shadow shard" copy: `audit.db` → `audit.v2.db`, then atomic rename. The procedure is out of scope for v1.

### 7.3 v1 script

```sql
-- Migrations/V1_Initial.sql
-- Apply only when PRAGMA user_version = 0.

-- (Body identical to Section 4 DDL.)
```

The script is embedded as a resource in `FalconAuditService.Core.dll`; `SchemaMigrator` enumerates `Migrations.V*_*.sql` resources at startup.

### 7.4 First-time-open sequence

```
SchemaMigrator.EnsureSchema(connection):
    apply PRAGMAs
    if user_version == 0:
        run V1 inside BEGIN IMMEDIATE
        sets user_version = 1
    return
```

`ShardRegistry.GetOrCreateAsync` calls `EnsureSchema` exactly once per shard, before adding the shard to the registry dictionary. Concurrent requests for the same job name race on `ConcurrentDictionary.GetOrAdd` — only one wins and runs `EnsureSchema`.

---

## 8. Per-shard vs Global DB

| Aspect | Per-shard `audit.db` | Global `global.db` |
|---|---|---|
| Location | `c:\job\<JobName>\.audit\audit.db` | `C:\bis\auditlog\global.db` |
| Scope | Files inside `c:\job\<JobName>\` | Files **directly** under `c:\job\` (depth 0) |
| DDL | Section 4 (identical) | Section 4 (identical) |
| `rel_filepath` interpretation | relative to `c:\job\<JobName>\` | relative to `c:\job\` |
| Lifetime | Created on job arrival; closed on departure | Persists across the lifetime of the service |
| Manifest? | Yes (`<JobName>\.audit\manifest.json`) | No |
| Discovery | `c:\job\*\.audit\audit.db` glob | static path |
| Read connections | `Mode=ReadOnly;Cache=Shared` from query process | same |
| Write connections | one per shard, gated by `SemaphoreSlim(1)` | one, gated by its own `SemaphoreSlim(1)` |

The global DB is a degenerate "shard with no job folder". The same `SqliteRepository` class handles both; the only branch is the `rel_filepath` computation in `EventRecorder` (REC-007).

---

## 9. Concurrency Model

- **Writers**: exactly one per database (shard or global), enforced by `SemaphoreSlim(1)` (STR-005). The single writer Task per shard reads from a bounded `Channel<ClassifiedEvent>` (capacity 1024).
- **Readers**: any number of `Mode=ReadOnly` connections from the query process. WAL allows readers to see the last committed snapshot regardless of in-flight writes (REL-004).
- **Checkpoints**: SQLite WAL auto-checkpoints every 1 000 pages by default. We accept the default; on shutdown, `SqliteRepository.Dispose` runs `PRAGMA wal_checkpoint(TRUNCATE)` to leave a clean WAL.
- **Backups**: out of scope for v1. Shard files can be safely copied while the writer is running thanks to WAL, but a snapshot tool is deferred.

---

## 10. Failure Modes and Recovery

| Failure | Behaviour |
|---|---|
| Power loss mid-write | WAL replays on next open; `synchronous = NORMAL` may lose the last fsync window (~30 ms of writes). Acceptable per ERS. |
| Disk full | `SqliteException` bubbles up; `EventRecorder` retries 3× with 100 ms back-off, then logs an error and *does not advance* `file_baselines` so the next debounce or catch-up will re-attempt. |
| Shard file corrupted | `SchemaMigrator.EnsureSchema` calls `PRAGMA integrity_check` on first open after a crash; if it fails, the shard is renamed to `audit.db.corrupt-<timestamp>` and a new one is created. Loss is bounded to that shard's history; manifest preserves chain-of-custody. |
| Schema newer than binary | `SchemaTooNewException` thrown; service refuses to start. Operator must redeploy a matching binary. (Forwards-compatible reads from the query process tolerate this case explicitly.) |
| WAL file growth runaway | Default auto-checkpoint suffices; `Dispose` truncates. If a stuck reader pins the WAL, `busy_timeout` surfaces it after 5 s. |

---

## 11. Test Hooks

- `SqliteRepository` accepts an `IClock` so `last_seen` and `changed_at` are deterministic in tests.
- `SchemaMigrator` exposes `GetCurrentVersion(connection)` and `GetTargetVersion()` for assertion in unit tests.
- An in-memory shared-cache connection string (`Data Source=:memory:;Cache=Shared`) is used by all schema-aware unit tests; `SchemaMigrator` is invoked identically against it.

---

## 12. Summary

The Balanced schema gives FalconAuditService:

1. The exact column set required by REC-001 / REC-008.
2. CHECK constraints that make the P1-only-content invariant a database-level property, not just a code property.
3. Four indexes that cover every API-004 filter axis with `ORDER BY changed_at DESC`, comfortably meeting PERF-005.
4. A simple `PRAGMA user_version`-driven migration story with strictly additive evolution.
5. Identical DDL for shards and global DB, simplifying the writer code path and shard portability across machines.

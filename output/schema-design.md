# FalconAuditService — Schema Design

**Document ID:** SCH-FAU-001
**Date:** 2026-04-26
**Storage technology:** SQLite 3.x via `Microsoft.Data.Sqlite` 6.x
**Mode:** WAL, `synchronous=NORMAL`, `foreign_keys=ON`

---

## 1. Database layout overview

| Database | Location | Contents |
|---|---|---|
| **Per-job shard** | `<jobFolder>\.audit\audit.db` | Audit events + baselines for one job |
| **Global DB** | `C:\bis\auditlog\global.db` | Audit events for files **directly** under `c:\job\` (not in any job folder) + custody-handoff events |

Both databases use the same `audit_log` and `file_baselines` schema. The global DB has one additional table: `custody_events`.

All connections, both writer and reader, set the same PRAGMAs at open time (writer once at open; reader on each new connection).

---

## 2. Connection strings

```csharp
// Writer (per-shard, held open for shard lifetime)
$"Data Source={shardPath};Mode=ReadWriteCreate;Cache=Private;Pooling=False;Foreign Keys=True"

// Reader (per-API-request)
$"Data Source={shardPath};Mode=ReadOnly;Cache=Private;Pooling=False;Foreign Keys=True"

// Global writer (process-wide singleton)
$"Data Source={globalDbPath};Mode=ReadWriteCreate;Cache=Private;Pooling=False;Foreign Keys=True"
```

`Mode=ReadOnly` (API-002) prevents the API from ever issuing a write, even by mistake.
`Pooling=False` ensures we manage connection lifetime explicitly per the architecture (writer = long-lived, reader = per-request).

---

## 3. PRAGMAs (run once after open)

```sql
PRAGMA journal_mode = WAL;            -- STR-004: concurrent readers don't block writers
PRAGMA synchronous = NORMAL;          -- durable enough for audit; faster than FULL
PRAGMA foreign_keys = ON;
PRAGMA temp_store = MEMORY;
PRAGMA mmap_size = 67108864;          -- 64 MB; helps deep paginated queries
PRAGMA wal_autocheckpoint = 1000;     -- ~1000 pages between auto checkpoints
PRAGMA busy_timeout = 5000;           -- 5 s back-off if any future cross-process contention
```

On graceful shutdown the writer issues `PRAGMA wal_checkpoint(TRUNCATE);` to keep the WAL file from growing across restarts.

---

## 4. Per-shard schema

### 4.1 `audit_log`

```sql
CREATE TABLE IF NOT EXISTS audit_log (
    id                  INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    changed_at          TEXT    NOT NULL,                    -- ISO 8601 UTC, e.g. "2026-04-26T08:14:22.314Z"
    event_type          TEXT    NOT NULL CHECK (event_type IN ('Created','Modified','Deleted','Renamed','CustodyHandoff')),
    filepath            TEXT    NOT NULL,                    -- absolute path of the (new) file
    old_filepath        TEXT    NULL,                        -- only populated for Renamed events (Q1)
    rel_filepath        TEXT    NOT NULL,                    -- relative to the job folder root (REC-007)
    filename            TEXT    NOT NULL,                    -- Path.GetFileName(filepath)
    file_extension      TEXT    NOT NULL,                    -- Path.GetExtension(filepath), lowercase, includes leading '.'
    module              TEXT    NOT NULL,                    -- from FileClassificationRules
    owner_service       TEXT    NOT NULL,
    monitor_priority    INTEGER NOT NULL CHECK (monitor_priority BETWEEN 1 AND 4),
    matched_pattern_id  TEXT    NULL,                        -- which rule matched, for debug / audit-of-audit
    machine_name        TEXT    NOT NULL,                    -- Environment.MachineName (REC-006)
    old_hash            TEXT    NULL,                        -- prior SHA-256, NULL for Created
    new_hash            TEXT    NULL,                        -- new SHA-256; NULL for Deleted
    description         TEXT    NULL,                        -- user-friendly description (REC-001)
    is_content_omitted  INTEGER NOT NULL DEFAULT 0 CHECK (is_content_omitted IN (0,1)),  -- Q2 / REC-004
    old_content         TEXT    NULL,                        -- only for P1 Modified, only if not omitted
    diff_text           TEXT    NULL,                        -- DiffPlex unified diff, P1 only
    created_by_catchup  INTEGER NOT NULL DEFAULT 0 CHECK (created_by_catchup IN (0,1))
);
```

**Justification:**
- `INTEGER PRIMARY KEY AUTOINCREMENT` — monotonic id supports stable ordering and offset pagination (API-005).
- `changed_at TEXT` ISO 8601 — sortable as text in SQLite; keeps timezone explicit (REC-001).
- `CHECK` on `event_type` — defensive; protects the schema if a future bug tries to write a typo.
- `is_content_omitted` — explicit Q2 marker; downstream consumers can tell content was *intentionally* dropped, not lost.
- `created_by_catchup` — distinguishes synthetic catch-up rows from live ones (useful for audit-of-audit).

### 4.2 `file_baselines`

```sql
CREATE TABLE IF NOT EXISTS file_baselines (
    filepath        TEXT NOT NULL PRIMARY KEY,
    last_hash       TEXT NOT NULL,
    last_seen       TEXT NOT NULL,    -- ISO 8601 UTC; updated on every observed event (REC-008)
    last_content    TEXT NULL         -- only stored for P1 paths; used as the "old" side of the next diff
);
```

**Justification:**
- `filepath` as PK — one row per tracked file, fast `INSERT OR REPLACE` semantics.
- `last_content` is `TEXT` because all P1-classified content (config and recipe files in the Falcon system) is text. Binary P1 files are out of scope; the FileClassifier should never tag a binary file P1.

### 4.3 Indexes

```sql
-- For: ORDER BY changed_at DESC LIMIT/OFFSET (default API page query)
CREATE INDEX IF NOT EXISTS ix_audit_changed_at
    ON audit_log (changed_at DESC, id DESC);

-- For: WHERE rel_filepath LIKE 'foo%' (API-003 path filter)
CREATE INDEX IF NOT EXISTS ix_audit_rel_filepath
    ON audit_log (rel_filepath);

-- For: WHERE monitor_priority = 1 ORDER BY changed_at DESC (very common filter)
CREATE INDEX IF NOT EXISTS ix_audit_priority_time
    ON audit_log (monitor_priority, changed_at DESC, id DESC);

-- For: catch-up "stale baselines" enumeration
CREATE INDEX IF NOT EXISTS ix_baselines_last_seen
    ON file_baselines (last_seen);
```

**Index justifications:**
- `ix_audit_changed_at` — every API list query orders by `changed_at DESC`. Without this index, deep pages do a full table scan.
- `ix_audit_priority_time` — composite leftmost match on the most common filter combo (priority + recent). Mitigates Alt 1's deep-pagination cost.
- `ix_audit_rel_filepath` — supports `WHERE rel_filepath LIKE ?`. SQLite uses index for `LIKE 'prefix%'` if `PRAGMA case_sensitive_like = OFF` and the column collation is appropriate. We rely on the fact that path filters are usually prefix-style.
- `ix_baselines_last_seen` — catch-up enumerates baselines by recency; supports `WHERE last_seen < ?` to bound the scan in incremental modes.

We **deliberately do not** index `event_type` or `module`: cardinality is too low for the index to help.

---

## 5. Global DB additional schema

The global DB has the same `audit_log` and `file_baselines` plus:

```sql
CREATE TABLE IF NOT EXISTS custody_events (
    id              INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    occurred_at     TEXT    NOT NULL,
    job_name        TEXT    NOT NULL,
    event_kind      TEXT    NOT NULL CHECK (event_kind IN ('Arrival','Departure','CustodyHandoff')),
    machine_name    TEXT    NOT NULL,             -- the machine recording this event
    prior_machine   TEXT    NULL,                 -- only for CustodyHandoff (Q5)
    manifest_path   TEXT    NOT NULL,             -- where the manifest lives
    notes           TEXT    NULL
);

CREATE INDEX IF NOT EXISTS ix_custody_job_time
    ON custody_events (job_name, occurred_at DESC);
```

**Justification (Q5):** when a job is observed for the first time on this machine but the manifest already shows a prior `last_machine_name`, the `JobManager` writes one row to `custody_events` with `event_kind='CustodyHandoff'` and `prior_machine` set to the previous owner. This makes cross-machine custody transfers queryable globally without parsing every job folder's manifest.

---

## 6. Migration strategy

There is no schema migration today (greenfield). The strategy for v2+:

1. Each shard's database has a `schema_version` row in a `_meta` table:
   ```sql
   CREATE TABLE IF NOT EXISTS _meta (
       key   TEXT NOT NULL PRIMARY KEY,
       value TEXT NOT NULL
   );
   INSERT OR IGNORE INTO _meta (key, value) VALUES ('schema_version', '1');
   ```
2. `SqliteRepository.OpenAsync` reads `_meta.schema_version` after opening. If it differs from `CurrentSchemaVersion`, it runs the corresponding migration scripts in order, each in its own transaction, and updates `_meta.schema_version`.
3. Migrations are kept in `Migrations\Migration_<from>_to_<to>.sql` resources embedded in the assembly.
4. Every migration is **idempotent** (`CREATE ... IF NOT EXISTS`, `ALTER TABLE ... IF NOT EXISTS`) so a partial run is recoverable on the next open.
5. Migration is per-shard. The first event of a job on a new service version triggers that shard's migration. (Old shards on long-departed jobs don't migrate until the job returns; that's fine.)

---

## 7. Standard parameterised queries

All queries use `SqliteCommand` parameters. **No string concatenation of user input ever** (CON-004).

### 7.1 Append a row (writer)

```sql
INSERT INTO audit_log (
    changed_at, event_type, filepath, old_filepath, rel_filepath,
    filename, file_extension, module, owner_service, monitor_priority,
    matched_pattern_id, machine_name, old_hash, new_hash, description,
    is_content_omitted, old_content, diff_text, created_by_catchup
) VALUES (
    @changed_at, @event_type, @filepath, @old_filepath, @rel_filepath,
    @filename, @file_extension, @module, @owner_service, @monitor_priority,
    @matched_pattern_id, @machine_name, @old_hash, @new_hash, @description,
    @is_content_omitted, @old_content, @diff_text, @created_by_catchup
);
```

### 7.2 Upsert baseline (writer, same transaction)

```sql
INSERT INTO file_baselines (filepath, last_hash, last_seen, last_content)
VALUES (@filepath, @last_hash, @last_seen, @last_content)
ON CONFLICT(filepath) DO UPDATE SET
    last_hash = excluded.last_hash,
    last_seen = excluded.last_seen,
    last_content = excluded.last_content;
```

### 7.3 Read baseline content for diff (writer)

```sql
SELECT last_hash, last_content
FROM file_baselines
WHERE filepath = @filepath;
```

### 7.4 Enumerate baselines (catch-up scanner)

```sql
SELECT filepath, last_hash, last_seen
FROM file_baselines;
```

### 7.5 List page (reader, /api/events)

Built dynamically, but parameterised. Skeleton:

```sql
SELECT id, changed_at, event_type, filepath, rel_filepath, filename,
       file_extension, module, owner_service, monitor_priority, machine_name,
       old_hash, new_hash, description, is_content_omitted
FROM audit_log
WHERE 1=1
  /* AND monitor_priority = @priority    -- when filter present */
  /* AND rel_filepath LIKE @path_prefix  -- when filter present */
  /* AND changed_at >= @from             -- when filter present */
  /* AND changed_at <  @to               -- when filter present */
ORDER BY changed_at DESC, id DESC
LIMIT @limit OFFSET @offset;
```

Each `WHERE` branch is appended only if the corresponding query parameter is non-null; the `@` placeholder is added to the command parameter collection at the same time. **No interpolation of values** (CON-004). The list query deliberately omits `old_content` and `diff_text` (API-006).

### 7.6 Page total (reader, parallel with 7.5)

```sql
SELECT COUNT(*) FROM audit_log
WHERE 1=1
  /* same filter clauses as 7.5 */;
```

Result cached in `IMemoryCache` keyed by `(jobName, filterHash)` for `count_cache_seconds` (default 30 s). Cache is invalidated naturally by TTL.

### 7.7 Single event detail (reader, /api/events/{job}/{id})

```sql
SELECT id, changed_at, event_type, filepath, old_filepath, rel_filepath, filename,
       file_extension, module, owner_service, monitor_priority, matched_pattern_id,
       machine_name, old_hash, new_hash, description, is_content_omitted,
       old_content, diff_text, created_by_catchup
FROM audit_log
WHERE id = @id;
```

This is the **only** query that returns `old_content` and `diff_text` (API-004, API-006).

### 7.8 Custody handoff insert (global DB)

```sql
INSERT INTO custody_events (occurred_at, job_name, event_kind, machine_name, prior_machine, manifest_path, notes)
VALUES (@occurred_at, @job_name, @event_kind, @machine_name, @prior_machine, @manifest_path, @notes);
```

---

## 8. Storage size estimates

For a single Falcon job typical of one production lot:

| Quantity | Estimate |
|---|---|
| Tracked files in a job | 100–500 |
| Audit events per file per day | ~5 (recipes/configs touched a few times) |
| Average row size (P2/P3, hash only) | ~250 bytes |
| Average row size (P1 with content+diff) | ~5–25 KB |
| Daily growth (1 job, mixed) | ~2–10 MB |
| Lifetime per shard (typical) | ~50–500 MB |

WAL file is auto-checkpointed at 1000 pages (≈4 MB) so the WAL never grows unboundedly under normal load.

---

## 9. Concurrency contract

| Operation | Allowed concurrency | Mechanism |
|---|---|---|
| Writes to one shard | Exactly one in flight | Single writer Task per shard (no DB-side lock needed) |
| Reads from one shard | Many concurrent | WAL allows N readers + 1 writer (STR-006) |
| Writes to different shards | Many concurrent | Independent files, independent writer Tasks |
| WAL checkpoint | Acquires writer lock briefly | Issued only at shutdown (`TRUNCATE` mode) |

The `busy_timeout = 5000` PRAGMA is defensive — under the architecture there is never cross-process contention on a shard, but the timeout protects us if (e.g.) a backup tool opens the file briefly.

---

## 10. Schema-to-requirement mapping

| Element | Requirement |
|---|---|
| `audit_log.id INTEGER AUTOINCREMENT` | API-004 (single-event lookup) |
| `audit_log.changed_at TEXT` (ISO 8601 UTC) | REC-001 |
| `audit_log.filepath` + `rel_filepath` (separate) | REC-007 |
| `audit_log.filename`, `file_extension` | REC-001 |
| `audit_log.event_type` CHECK | MON-003, Q1 |
| `audit_log.old_filepath` | Q1 hybrid rename |
| `audit_log.module`, `owner_service`, `monitor_priority` | REC-001, CLS-007 |
| `audit_log.machine_name` | REC-001, REC-006 |
| `audit_log.old_hash`, `new_hash` | REC-002 |
| `audit_log.is_content_omitted` | Q2, REC-004 |
| `audit_log.old_content`, `diff_text` (P1 only) | REC-003, REC-005 |
| `file_baselines.last_hash`, `last_seen` | REC-008 |
| Per-job DB file location | STR-001, JOB-001 |
| Global DB file location | STR-002 |
| WAL + `synchronous=NORMAL` | STR-004, STR-006 |
| Single writer Task per shard | STR-005, REL-005 |
| Lazy open + dispose < 5 s | STR-007, STR-008 |
| `custody_events.event_kind = 'CustodyHandoff'` | Q5, STR-003 |
| Parameterised SQL only | CON-004 |

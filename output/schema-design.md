# FalconAuditService — Storage Schema Design

**Storage technology:** SQLite via `Microsoft.Data.Sqlite` (CON-003)
**Document basis:** ERS-FAU-001 v1.0
**Date:** 2026-04-25

---

## 1. Database Layout

| Database | Path | Scope |
|---|---|---|
| Per-job shard | `<jobFolder>\.audit\audit.db` | Events for files inside that job folder (STR-001) |
| Global | `C:\bis\auditlog\global.db` | Events on files directly under `c:\job\` (STR-002) |

Every database carries the same schema. The `.audit\` directory and the database file are created automatically by `SqliteRepository` on first use (STR-006).

---

## 2. PRAGMA Settings (applied on every connection open)

```sql
-- Applied once on first open per database file:
PRAGMA journal_mode = WAL;            -- STR-003 / REL-004
PRAGMA synchronous = NORMAL;          -- STR-004
PRAGMA foreign_keys = ON;
PRAGMA temp_store = MEMORY;
PRAGMA busy_timeout = 5000;           -- 5 s wait on lock contention
PRAGMA cache_size = -8000;            -- 8 MB page cache
```

Read-only API connections add (STR-005, API-002):

```
Mode=ReadOnly;Cache=Shared;Foreign Keys=False
```

---

## 3. DDL — `audit_log`

The single events table. One row per recorded change event.

```sql
CREATE TABLE IF NOT EXISTS audit_log (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    changed_at        TEXT    NOT NULL,            -- UTC ISO 8601, e.g. 2026-04-25T13:55:01.234Z (REC-001)
    event_type        TEXT    NOT NULL,            -- Created | Modified | Deleted | Renamed (MON-003, CUS-002..004)
    filepath          TEXT    NOT NULL,            -- absolute path on the recording machine (REC-001)
    rel_filepath      TEXT    NOT NULL,            -- job-relative path (REC-007); for global db, path relative to c:\job\
    module            TEXT    NOT NULL,            -- e.g. AOI_Main, RMS, DataServer, Unknown (CLS-007)
    owner_service     TEXT    NOT NULL,            -- e.g. AOI_Main, Unknown (CLS-007)
    monitor_priority  TEXT    NOT NULL CHECK (monitor_priority IN ('P1','P2','P3')),  -- P4 never written (REC-003)
    machine_name      TEXT    NOT NULL,            -- Environment.MachineName at write time (REC-006, JOB-007)
    sha256_hash       TEXT    NOT NULL,            -- 64 lowercase hex chars (REC-004)
    old_content       TEXT    NULL,                -- only populated for P1 (REC-001/REC-002)
    diff_text         TEXT    NULL                 -- unified diff (DiffPlex) - only for P1 (REC-005)
);
```

### Indexes (justification → satisfies)

```sql
CREATE INDEX IF NOT EXISTS ix_audit_log_changed_at
    ON audit_log (changed_at DESC);                  -- API-005 default sort + PERF-005

CREATE INDEX IF NOT EXISTS ix_audit_log_module
    ON audit_log (module);                            -- API-004 filter

CREATE INDEX IF NOT EXISTS ix_audit_log_priority
    ON audit_log (monitor_priority);                  -- API-004 filter

CREATE INDEX IF NOT EXISTS ix_audit_log_event_type
    ON audit_log (event_type);                        -- API-004 filter

CREATE INDEX IF NOT EXISTS ix_audit_log_machine
    ON audit_log (machine_name);                      -- API-004 filter; per-machine slicing post move

CREATE INDEX IF NOT EXISTS ix_audit_log_owner_service
    ON audit_log (owner_service);                     -- API-004 filter (`service`)

CREATE INDEX IF NOT EXISTS ix_audit_log_rel_filepath
    ON audit_log (rel_filepath);                      -- API history endpoint (API-003 history/{*filePath})

CREATE INDEX IF NOT EXISTS ix_audit_log_changed_at_module
    ON audit_log (module, changed_at DESC);           -- composite for common module + recency query
```

---

## 4. DDL — `file_baselines`

One row per tracked file. Updated on every processed event. Drives `CatchUpScanner` reconciliation (CUS-001..004) and diff old-content lookup (REC-005, REC-008).

```sql
CREATE TABLE IF NOT EXISTS file_baselines (
    filepath          TEXT PRIMARY KEY,             -- absolute path
    last_hash         TEXT NOT NULL,                -- last SHA-256 we saw
    last_seen         TEXT NOT NULL,                -- UTC ISO 8601 (REC-008)
    last_content      TEXT NULL                     -- last full text (P1 only) used to compute diff next time
);

CREATE INDEX IF NOT EXISTS ix_file_baselines_last_seen
    ON file_baselines (last_seen);
```

`last_content` is required because diff generation must compare new content against the previous content (REC-005). Storing it on `file_baselines` (rather than rereading from `audit_log.old_content` of the previous row) makes diff a single point-lookup.

---

## 5. DDL — `schema_meta`

Tracks the schema version for forward-compat migrations.

```sql
CREATE TABLE IF NOT EXISTS schema_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

INSERT OR IGNORE INTO schema_meta (key, value) VALUES ('schema_version', '1');
INSERT OR IGNORE INTO schema_meta (key, value) VALUES ('audit_db_version', '1');   -- referenced by manifest (MFT-002)
INSERT OR IGNORE INTO schema_meta (key, value) VALUES ('created_at_utc', strftime('%Y-%m-%dT%H:%M:%fZ','now'));
```

---

## 6. Schema Initialisation Sequence

`SqliteRepository.EnsureSchema()` runs the full DDL above inside a single transaction the **first time** the connection is opened against a database file. The DDL is idempotent (`CREATE ... IF NOT EXISTS`), so re-running on existing shards is a no-op.

Pseudocode:

```csharp
using var tx = _connection.BeginTransaction();
ExecuteNonQuery(_pragmaScript);      // §2
ExecuteNonQuery(_auditLogDdl);       // §3
ExecuteNonQuery(_fileBaselinesDdl);  // §4
ExecuteNonQuery(_schemaMetaDdl);     // §5
tx.Commit();
```

---

## 7. Connection String Templates

| Use | Template |
|---|---|
| Writer (per-shard) | `Data Source={dbPath};Cache=Shared;Foreign Keys=True` |
| Reader (Query API) | `Data Source={dbPath};Mode=ReadOnly;Cache=Shared;Foreign Keys=False` |

Both use `Microsoft.Data.Sqlite.SqliteConnection`. The writer connection is held for the lifetime of the `SqliteRepository`; reader connections are created per HTTP request and disposed at the end of the request.

---

## 8. Migration Strategy

### v1 (current)
The DDL above is the v1 baseline. No migrations required.

### Forward path (v2+)
On startup, `SqliteRepository.EnsureSchema()` reads `schema_meta.schema_version`. For each version less than the current code's target, it executes the matching `Migrations\v{n}_to_v{n+1}.sql` script inside a transaction and bumps `schema_version`. All migrations must be:
- Idempotent.
- Single-statement-per-transaction safe.
- Include only additive changes (`ADD COLUMN`, `CREATE INDEX`) for v1→v2 — destructive migrations require a service-version bump and a backup step.

Per JOB-001, schema must remain backward-readable so an older Falcon machine can still open a shard last written by a newer machine in degraded mode.

---

## 9. Access Patterns

### Writer (one per shard)
- `INSERT INTO audit_log (...) VALUES (@changed_at, @event_type, ...)` — single statement per event, parameterised.
- `INSERT OR REPLACE INTO file_baselines (filepath, last_hash, last_seen, last_content) VALUES (...)`.
- Both are wrapped in a single transaction per event. Writes are serialised by `SemaphoreSlim(1)` belonging to the shard.

### Readers (Query API)
| Endpoint | Query |
|---|---|
| `GET /api/jobs/{j}/files` | `SELECT DISTINCT rel_filepath FROM audit_log ORDER BY rel_filepath;` |
| `GET /api/jobs/{j}/events` | `SELECT id, changed_at, event_type, filepath, rel_filepath, module, owner_service, monitor_priority, machine_name, sha256_hash FROM audit_log WHERE {filters} ORDER BY changed_at DESC LIMIT @pageSize OFFSET @offset;` (excludes `old_content`, `diff_text` per API-006) |
| `GET /api/jobs/{j}/events/{id}` | `SELECT * FROM audit_log WHERE id = @id;` (full row including `old_content` + `diff_text`) |
| `GET /api/jobs/{j}/history/{*p}` | `SELECT id, changed_at, event_type, machine_name, sha256_hash FROM audit_log WHERE rel_filepath = @p ORDER BY changed_at DESC;` |
| `GET /api/jobs/{j}/events` total count | `SELECT COUNT(1) FROM audit_log WHERE {filters};` |

All filter fragments use parameterised placeholders only — no string concatenation.

### CatchUpScanner
- Disk traversal: enumerate files under the job folder (excluding `.audit\`).
- For each: `SELECT last_hash FROM file_baselines WHERE filepath = @p;` → compare to current SHA-256.
- Per outcome: emit Created / Modified / Deleted event onto the EventRecorder channel.
- Then: `SELECT filepath FROM file_baselines;` to find baselines whose disk file is missing → emit Deleted.

---

## 10. Capacity & Sizing

| Item | Estimate |
|---|---|
| Single P1 row | ~3-12 KB (depends on file size; old_content + diff dominate) |
| Single P2/P3 row | ~250 bytes |
| Typical shard after 1 month | 10-100 MB |
| Global db | <10 MB |
| WAL + WAL-index files | up to ~32 MB peak per shard |

Manual VACUUM is not scheduled — WAL checkpoints happen automatically. `PRAGMA wal_autocheckpoint = 1000` is the SQLite default and is retained.

---

## 11. Concurrency Guarantees

| Scenario | Guarantee |
|---|---|
| Multiple readers + 1 writer on a shard | Safe — WAL allows readers without blocking writes (REL-004) |
| Multiple writers on a shard | Prevented by `SemaphoreSlim(1)` (REL-005) |
| Writer crash mid-transaction | WAL rollback restores last committed state (REL-001) |
| Power loss during manifest write | Atomic temp-file rename guarantees old-or-new (REL-003) — *manifest, not DB* |
| Power loss during DB write | WAL replay on next open (REL-001) |

---

## 12. Security Considerations

- All queries are **parameterised**. The grammar of allowed filters is fixed in `QueryRepository`; user input never reaches SQL textually.
- API connections are opened with `Mode=ReadOnly` so even a SQL injection vulnerability in filter construction could not cause data loss (defense-in-depth) (API-002).
- `rel_filepath` API parameter is validated against `^[\w\-. \\/]+$` before use (API-008).
- The service must not modify any file under `c:\job\` outside `.audit\` (CON-006). Enforced by code review — only `SqliteRepository` and `ManifestManager` ever open `FileMode.Create*` handles, and both only write inside `.audit\`.

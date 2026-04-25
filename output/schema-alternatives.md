# FalconAuditService — Schema Alternatives

| Field | Value |
|---|---|
| Document | schema-alternatives.md |
| Phase | 1 — Alternatives |
| Source | `req.md`, `engineering_requirements.md` (ERS-FAU-001) §3.4–§3.5, `FileClassificationRules.json` |
| Target | SQLite via `Microsoft.Data.Sqlite` (.NET 6) |
| Date | 2026-04-25 |

---

## 1. Context Recap

- Two physical databases per machine: per-job shards at `<jobFolder>\.audit\audit.db` (STR-001) and one `global.db` at `C:\bis\auditlog\global.db` (STR-002).
- Both must use **WAL** journaling (STR-003, REL-004) and `synchronous=NORMAL` (STR-004).
- Each shard has at most one writer (`SemaphoreSlim(1)`, STR-005).
- Mandatory columns from REC-001: `changed_at`, `event_type`, `filepath`, `rel_filepath`, `module`, `owner_service`, `monitor_priority`, `machine_name`, `sha256_hash`, `old_content` (P1 only), `diff_text` (P1 only).
- Mandatory `file_baselines` table (REC-008): `filepath`, `last_hash`, `last_seen`.
- Read-only API filters on: `module`, `priority`, `service`, `eventType`, `from`, `to`, `machine`, `path` substring (API-004).
- Pagination by `(page, pageSize)` with `X-Total-Count` (API-005), so `COUNT(*)` over filtered set must be cheap.

The decision is **how aggressive the schema is** in indexes, normalisation, integrity, and metadata.

---

## 2. Alternative A — Minimal

### 2.1 DDL

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous  = NORMAL;
PRAGMA foreign_keys = OFF;

CREATE TABLE audit_log (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    changed_at      TEXT    NOT NULL,           -- ISO 8601 UTC
    event_type      TEXT    NOT NULL,           -- Created/Modified/Deleted/Renamed
    filepath        TEXT    NOT NULL,
    rel_filepath    TEXT    NOT NULL,
    module          TEXT,
    owner_service   TEXT,
    monitor_priority TEXT,                      -- P1/P2/P3
    machine_name    TEXT    NOT NULL,
    sha256_hash     TEXT,
    old_content     TEXT,                       -- P1 only
    diff_text       TEXT                        -- P1 only
);

CREATE TABLE file_baselines (
    filepath  TEXT PRIMARY KEY,
    last_hash TEXT NOT NULL,
    last_seen TEXT NOT NULL
);

CREATE INDEX ix_audit_log_changed_at ON audit_log (changed_at);
```

### 2.2 Migration strategy

Single-script bootstrap. Schema version tracked in `PRAGMA user_version = 1`. No migration framework.

### 2.3 Pros / Cons

| Aspect | Score | Notes |
|---|---|---|
| Write overhead | **Lowest** | Only one index; insert path is minimal. |
| Storage growth | Lowest | No redundant columns or covering indexes. |
| **API query speed** | **Risk** | Filter combinations on `(module, priority, machine, changed_at)` will table-scan. PERF-005 (200 ms / 50 rows) is at risk once the shard exceeds ~10 K rows. |
| `COUNT(*)` for `X-Total-Count` | Slow | No partial covering index. |
| Data integrity | None | No `CHECK` constraints on enums. Bad data possible if recorder bug. |
| Migration complexity | Lowest | One file, no versioning machinery. |
| Fits requirement set | Partial | Functional fields all present; PERF-005 at risk. |

### 2.4 When to pick

Single-machine pilot, ≤ 1 K events per shard, no analyst load.

---

## 3. Alternative B — Balanced (Recommended)

### 3.1 DDL

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous  = NORMAL;
PRAGMA foreign_keys = OFF;
PRAGMA temp_store   = MEMORY;
PRAGMA cache_size   = -8000;     -- ~8 MiB page cache

CREATE TABLE audit_log (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    changed_at       TEXT    NOT NULL,
    event_type       TEXT    NOT NULL CHECK (event_type IN ('Created','Modified','Deleted','Renamed')),
    filepath         TEXT    NOT NULL,
    rel_filepath     TEXT    NOT NULL,
    module           TEXT,
    owner_service    TEXT,
    monitor_priority TEXT    NOT NULL CHECK (monitor_priority IN ('P1','P2','P3')),
    machine_name     TEXT    NOT NULL,
    sha256_hash      TEXT,
    old_content      TEXT,                              -- P1 only; NULL otherwise
    diff_text        TEXT,                              -- P1 only; NULL otherwise
    -- guard against accidental P2 content storage
    CHECK (
        (monitor_priority = 'P1') OR
        (old_content IS NULL AND diff_text IS NULL)
    )
);

CREATE TABLE file_baselines (
    filepath   TEXT PRIMARY KEY,
    last_hash  TEXT NOT NULL,
    last_seen  TEXT NOT NULL
);

-- Hot read paths driven by API-004 filters
CREATE INDEX ix_audit_changed_at      ON audit_log (changed_at DESC);
CREATE INDEX ix_audit_relpath         ON audit_log (rel_filepath);
CREATE INDEX ix_audit_module_priority ON audit_log (module, monitor_priority);
CREATE INDEX ix_audit_machine_changed ON audit_log (machine_name, changed_at DESC);

-- Single-event detail lookup is by id (PK -> rowid), no extra index needed.

PRAGMA user_version = 1;
```

`global.db` uses the same DDL — the only difference is that `rel_filepath` is interpreted relative to `c:\job\` (REC-007).

### 3.2 Migration strategy

`SchemaMigrator` class:

- On open, read `PRAGMA user_version`.
- If `0`, apply v1 DDL inside a transaction, set `PRAGMA user_version = 1`.
- Future versions: `Migrations/V2_AddSomething.sql` + bumped `user_version`.
- Migrations are **idempotent**: each script wrapped in `BEGIN IMMEDIATE` / `COMMIT` and aborts cleanly if the version is already current.

### 3.3 Pros / Cons

| Aspect | Score | Notes |
|---|---|---|
| Write overhead | **Low** | Four indexes, but inserts are append-mostly so B-tree growth is cheap. WAL keeps writes fast. |
| API query speed | **Pass** | All API-004 filters are index-supported. `PERF-005` (200 ms / 50 rows) achievable with `ORDER BY changed_at DESC LIMIT/OFFSET` using `ix_audit_changed_at`. |
| `X-Total-Count` cost | Acceptable | `COUNT(*)` over filtered subset uses the same indexes. For the worst case (no filter), SQLite's row-count estimate is fast. |
| Data integrity | **Strong** | `CHECK` constraints catch enum drift and the P1-only-content invariant at the database boundary. |
| Storage growth | Low–Medium | Index overhead ~30–40 % of `audit_log` row size; acceptable on inspection PCs. |
| Migration complexity | Low | Linear script list; no external tool. |
| Fits requirement set | **Full** | Every column from REC-001/008 present; every API-004 filter has supporting index. |

### 3.4 When to pick

Default for FalconAuditService. Balances the 200 ms PERF-005 budget with modest write overhead.

---

## 4. Alternative C — Full coverage (FTS + normalised lookups)

### 4.1 DDL

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous  = NORMAL;

-- Lookup tables
CREATE TABLE module       (id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL);
CREATE TABLE owner_service(id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL);
CREATE TABLE event_type   (id INTEGER PRIMARY KEY, name TEXT UNIQUE NOT NULL);

INSERT INTO event_type (name) VALUES ('Created'),('Modified'),('Deleted'),('Renamed');

CREATE TABLE audit_log (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    changed_at       TEXT    NOT NULL,
    event_type_id    INTEGER NOT NULL REFERENCES event_type(id),
    filepath         TEXT    NOT NULL,
    rel_filepath     TEXT    NOT NULL,
    module_id        INTEGER REFERENCES module(id),
    owner_service_id INTEGER REFERENCES owner_service(id),
    monitor_priority TEXT    NOT NULL CHECK (monitor_priority IN ('P1','P2','P3')),
    machine_name     TEXT    NOT NULL,
    sha256_hash      TEXT,
    old_content      TEXT,
    diff_text        TEXT,
    CHECK (
        (monitor_priority = 'P1') OR
        (old_content IS NULL AND diff_text IS NULL)
    )
);

CREATE TABLE file_baselines (
    filepath   TEXT PRIMARY KEY,
    last_hash  TEXT NOT NULL,
    last_seen  TEXT NOT NULL,
    last_event_id INTEGER REFERENCES audit_log(id)
);

-- Indexes
CREATE INDEX ix_audit_changed_at   ON audit_log (changed_at DESC);
CREATE INDEX ix_audit_relpath      ON audit_log (rel_filepath);
CREATE INDEX ix_audit_mod_pri      ON audit_log (module_id, monitor_priority);
CREATE INDEX ix_audit_mach_changed ON audit_log (machine_name, changed_at DESC);
CREATE INDEX ix_audit_event_type   ON audit_log (event_type_id);
CREATE INDEX ix_audit_owner        ON audit_log (owner_service_id);

-- Full-text on diff_text + old_content for analyst grep across history
CREATE VIRTUAL TABLE audit_log_fts USING fts5(
    rel_filepath, diff_text, old_content,
    content='audit_log', content_rowid='id',
    tokenize='porter unicode61'
);

CREATE TRIGGER audit_log_ai AFTER INSERT ON audit_log BEGIN
    INSERT INTO audit_log_fts(rowid, rel_filepath, diff_text, old_content)
    VALUES (new.id, new.rel_filepath, new.diff_text, new.old_content);
END;

PRAGMA user_version = 1;
```

### 4.2 Migration strategy

Same `SchemaMigrator` pattern as Alt B but with seeded reference rows in v1 and FTS rebuild on each version bump.

### 4.3 Pros / Cons

| Aspect | Score | Notes |
|---|---|---|
| Write overhead | **Medium** | Joins required on every insert (lookup id resolution) **and** an FTS trigger. P1 inserts copy `diff_text` twice. PERF-002 (1 s) still safe but headroom shrinks. |
| API query speed | **Pass (fastest)** | Smaller fact-row, six covering indexes, free-text search across diffs. |
| Storage | Medium | FTS index doubles diff storage on P1. On a busy job that is real cost. |
| Data integrity | **Strongest** | Foreign keys + CHECK + lookup tables make bad data nearly impossible. |
| Migration complexity | **High** | Lookup-table seeding, FTS rebuild on schema bumps, more brittle. |
| API code complexity | Higher | Every read joins three lookup tables (or denormalises in the SELECT). |
| Job portability | Risk | Lookup-id values may differ between machines if rows were inserted in different orders — string-comparing dump files becomes harder. (Mitigated by seeding `event_type` deterministically; `module` and `owner_service` still drift.) |
| Fits requirement set | Full | All requirements satisfied. |

### 4.4 When to pick

Multi-machine analyst workflow with frequent free-text searches over diff history; storage is cheap; team has SQLite-FTS experience.

---

## 5. Comparison Matrix

| Dimension | Alt A — Minimal | Alt B — Balanced (Rec.) | Alt C — Full coverage |
|---|---|---|---|
| Write overhead | Lowest | Low | Medium |
| API query speed | Risk (table scans) | **Pass** | Pass (fastest) |
| `X-Total-Count` cost | Slow | Acceptable | Best |
| Data integrity (CHECK / FK) | None | **CHECK** | CHECK + FK |
| Storage growth | Lowest | Low–Medium | Medium |
| Migration complexity | Lowest | Low | High |
| Free-text diff search | No | No | **Yes (FTS5)** |
| Job-portability cleanliness | Best | Best | Risk (lookup-id drift) |
| Fits PERF-005 (200 ms) | Risk | **Pass** | Pass |
| **Recommended** | | **Yes** | |

---

## 6. Recommendation

**Adopt Alternative B — Balanced.**

It is the smallest schema that:

1. Carries every REC-001/008 column verbatim with **CHECK constraints** that catch the P1-only-content invariant at the SQLite boundary (defence in depth on top of the recorder code).
2. Has indexes on every API-004 filter axis, making PERF-005 (200 ms paginated query) safe up to the typical job-shard size.
3. Avoids the lookup-id drift risk of Alt C, which matters because shards are *portable across machines* (JOB-001) — string-valued enums survive a `dump+restore` to a different machine without any id-remapping step.

Alt A is acceptable only for a pilot. Alt C is justified only if free-text diff search becomes a first-class user feature; it can be added later as a second migration without disrupting Alt B's data.

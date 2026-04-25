# FalconAuditService — API Alternatives

| Field | Value |
|---|---|
| Document | api-alternatives.md |
| Phase | 1 — Alternatives |
| Source | `req.md`, `engineering_requirements.md` (ERS-FAU-001) §3.9 |
| Target | ASP.NET Core Kestrel (.NET 6) on port 5100, loopback by default |
| Date | 2026-04-25 |

---

## 1. Context Recap

- Read-only HTTP API in the same Windows Service process (API-001).
- All SQLite connections **must** use `Mode=ReadOnly` (API-002).
- Mandatory endpoint set (API-003):
  - `GET /api/jobs`
  - `GET /api/jobs/{jobName}/manifest`
  - `GET /api/jobs/{jobName}/files`
  - `GET /api/jobs/{jobName}/events`
  - `GET /api/jobs/{jobName}/events/{id}`
  - `GET /api/jobs/{jobName}/history/{*filePath}`
  - `GET /api/global/events`
- Filters on the events list (API-004): `module`, `priority`, `service`, `eventType`, `from`, `to`, `machine`, `path` substring.
- Pagination (API-005): `page` (1-based), `pageSize` (default 50, max 500), with `X-Total-Count`, `X-Page`, `X-PageSize` headers.
- `old_content` and `diff_text` are returned only by the **single-event** endpoint (API-006).
- `rel_filepath` validated against `^[\w\-. \\/]+$` (API-008).
- `JobDiscoveryService` refreshes the shard list every 30 s (API-007).
- PERF-005: 50-row paginated event list returns within 200 ms.

The decision is **how the API surfaces filtering and pagination**: minimal, full REST, or cursor-based.

---

## 2. Alternative A — Minimal

### 2.1 Endpoints

Exactly the seven mandatory endpoints. Filters limited to a subset of API-004:

| Endpoint | Filters / params |
|---|---|
| `GET /api/jobs` | none |
| `GET /api/jobs/{jobName}/manifest` | none |
| `GET /api/jobs/{jobName}/files` | none |
| `GET /api/jobs/{jobName}/events` | `from`, `to`, `priority`, `page`, `pageSize` |
| `GET /api/jobs/{jobName}/events/{id}` | none |
| `GET /api/jobs/{jobName}/history/{*filePath}` | `page`, `pageSize` |
| `GET /api/global/events` | `from`, `to`, `priority`, `page`, `pageSize` |

Pagination via `page`/`pageSize` only. No cursor, no link headers.

### 2.2 DTO shapes

```csharp
public record JobSummaryDto(string JobName, DateTimeOffset? Created, int EventCount);

public record EventListItemDto(
    long Id,
    DateTimeOffset ChangedAt,
    string EventType,
    string RelFilepath,
    string Module,
    string MonitorPriority,
    string MachineName,
    string Sha256Hash);

public record EventDetailDto(
    long Id,
    DateTimeOffset ChangedAt,
    string EventType,
    string Filepath,
    string RelFilepath,
    string Module,
    string OwnerService,
    string MonitorPriority,
    string MachineName,
    string Sha256Hash,
    string? OldContent,
    string? DiffText);
```

### 2.3 SQL sketch — `events` list

```sql
SELECT id, changed_at, event_type, rel_filepath, module,
       monitor_priority, machine_name, sha256_hash
FROM   audit_log
WHERE  (@from     IS NULL OR changed_at >= @from)
  AND  (@to       IS NULL OR changed_at <  @to)
  AND  (@priority IS NULL OR monitor_priority = @priority)
ORDER  BY changed_at DESC
LIMIT  @pageSize OFFSET (@page - 1) * @pageSize;
```

`X-Total-Count` is a separate `SELECT COUNT(*) FROM audit_log WHERE …` round-trip.

### 2.4 Pros / Cons

| Aspect | Score | Notes |
|---|---|---|
| Implementation effort | **Lowest** | ~7 controller actions, no shared filter parser. |
| Filter coverage | Partial | Misses `module`, `service`, `eventType`, `machine`, `path` from API-004 → **fails API-004**. |
| Pagination scale | Medium | OFFSET works fine to ~50 K rows; degrades quadratically beyond. |
| Client ergonomics | Low | Analysts must download large pages and filter client-side. |
| Code complexity | Lowest | No filter DTO, no expression builder. |
| Fits requirement set | **Partial — fails API-004** | |

### 2.5 When to pick

Internal debug-only deployment. Not acceptable for the engineered requirements.

---

## 3. Alternative B — Full REST (Recommended)

### 3.1 Endpoints

All seven mandatory endpoints with **complete API-004 filter coverage** on `events` lists, plus a uniform query-builder layer.

| Endpoint | Verb | Notes |
|---|---|---|
| `/api/jobs` | GET | Lists all known shards (from `JobDiscoveryService`). |
| `/api/jobs/{jobName}/manifest` | GET | Returns `manifest.json` content as DTO. |
| `/api/jobs/{jobName}/files` | GET | Distinct `rel_filepath` values from `file_baselines` + last hash + last seen. |
| `/api/jobs/{jobName}/events` | GET | Filters: `module`, `priority`, `service`, `eventType`, `from`, `to`, `machine`, `path`. Pagination: `page`, `pageSize`. |
| `/api/jobs/{jobName}/events/{id}` | GET | Full detail incl. `old_content`, `diff_text`. |
| `/api/jobs/{jobName}/history/{*filePath}` | GET | All events for one `rel_filepath`. Validates against `^[\w\-. \\/]+$` (API-008). |
| `/api/global/events` | GET | Same shape as `/jobs/{jobName}/events` but reads `global.db`. |

### 3.2 Headers

Response always includes:

```
X-Total-Count: 18342
X-Page:        3
X-PageSize:    50
```

Validation errors return `400` with a `ProblemDetails` body. Unknown jobs return `404`. Path-traversal attempts on `history/{*filePath}` return `400` (not `404`) so probes are visible in logs.

### 3.3 DTO shapes

Same as Alt A plus:

```csharp
public record EventQueryFilter(
    string? Module,
    string? Priority,           // P1|P2|P3
    string? Service,
    string? EventType,          // Created|Modified|Deleted|Renamed
    DateTimeOffset? From,
    DateTimeOffset? To,
    string? Machine,
    string? Path)               // substring; LIKE '%' + escape + '%'
{
    public int Page     { get; init; } = 1;
    public int PageSize { get; init; } = 50;   // capped at 500 by validator
}

public record FileBaselineDto(string RelFilepath, string LastHash, DateTimeOffset LastSeen);

public record ManifestDto(
    string  JobName,
    int     AuditDbVersion,
    ManifestEntryDto Created,
    IReadOnlyList<MachineHistoryDto> History);
```

### 3.4 SQL sketch — events list (parameterised)

```sql
SELECT id, changed_at, event_type, rel_filepath, module, owner_service,
       monitor_priority, machine_name, sha256_hash
FROM   audit_log
WHERE  (@module      IS NULL OR module           = @module)
  AND  (@priority    IS NULL OR monitor_priority = @priority)
  AND  (@service     IS NULL OR owner_service    = @service)
  AND  (@eventType   IS NULL OR event_type       = @eventType)
  AND  (@machine     IS NULL OR machine_name     = @machine)
  AND  (@from        IS NULL OR changed_at      >= @from)
  AND  (@to          IS NULL OR changed_at       < @to)
  AND  (@pathPattern IS NULL OR rel_filepath LIKE @pathPattern ESCAPE '\')
ORDER  BY changed_at DESC
LIMIT  @pageSize OFFSET (@page - 1) * @pageSize;
```

`@pathPattern` is `%escaped%`. `X-Total-Count` runs the same WHERE inside `SELECT COUNT(1) …`.

### 3.5 Code structure

- `EventQueryBuilder` — turns `EventQueryFilter` into `(sql, parameters)`. Single source of truth, used by both list and count queries.
- `IShardReader` — `Mode=ReadOnly` connection per request, scoped DI lifetime.
- `JobDiscoveryService` — singleton, refreshes every 30 s (API-007).
- `PathValidator` — static helper enforcing API-008 regex.
- `RelFilepathConstraint : IRouteConstraint` — applies the same regex at the routing layer for `history/{*filePath}`.

### 3.6 Pros / Cons

| Aspect | Score | Notes |
|---|---|---|
| Filter coverage | **Full** | Hits every axis in API-004. |
| Pagination scale | Medium | `LIMIT/OFFSET` is fine at expected shard sizes (≤ ~100 K rows per job). PERF-005 stays comfortably under 200 ms with the Alt-B schema indexes. |
| Implementation effort | Medium | One filter DTO, one builder, seven controller actions. |
| Client ergonomics | **High** | `X-Total-Count` lets a client size a paginator without extra round trips. |
| Maintenance | Medium | Adding a new filter is one line in DTO + one line in builder. |
| Risk surface | Low | All inputs parameterised; `path` LIKE escapes wildcards; route constraint for path-traversal. |
| Fits requirement set | **Full** | API-001…API-009 all satisfied. |

### 3.7 When to pick

Default. This is the option directly described by API-003…API-008.

---

## 4. Alternative C — Cursor pagination (opaque token)

### 4.1 Endpoints

Same set as Alt B, but `events` lists use a cursor:

```
GET /api/jobs/{jobName}/events?cursor=eyJjIjoiMjAyNi0wNC0yNVQxNDoxMjowM1oiLCJpIjoxNzg0fQ&pageSize=50
```

Query returns:

```json
{
  "items":      [ /* EventListItemDto */ ],
  "nextCursor": "eyJjIjoi…",
  "previousCursor": null
}
```

`X-Total-Count` becomes optional and expensive; we either omit it or compute it lazily (cached) every N seconds.

### 4.2 SQL sketch

The cursor encodes the keyset `(changed_at, id)` of the last row returned:

```sql
SELECT id, changed_at, event_type, rel_filepath, module, owner_service,
       monitor_priority, machine_name, sha256_hash
FROM   audit_log
WHERE  (@module IS NULL OR module = @module)
  AND  (@priority IS NULL OR monitor_priority = @priority)
  AND  (@service  IS NULL OR owner_service    = @service)
  AND  (@eventType IS NULL OR event_type      = @eventType)
  AND  (@machine  IS NULL OR machine_name     = @machine)
  AND  (@from IS NULL OR changed_at >= @from)
  AND  (@to   IS NULL OR changed_at <  @to)
  AND  (@pathPattern IS NULL OR rel_filepath LIKE @pathPattern ESCAPE '\')
  AND  (@cursorChangedAt IS NULL
        OR changed_at < @cursorChangedAt
        OR (changed_at = @cursorChangedAt AND id < @cursorId))
ORDER  BY changed_at DESC, id DESC
LIMIT  @pageSize;
```

The `(changed_at, id)` keyset is index-friendly and **constant-time** at any depth — no `OFFSET` walk.

### 4.3 Pros / Cons

| Aspect | Score | Notes |
|---|---|---|
| Pagination scale | **Best** | Cursor-keyset is O(log n) per page regardless of depth. Wins at > 1 M rows. |
| `X-Total-Count` | Lost or expensive | API-005 mandates `X-Total-Count` on the events list. To preserve it we must run a separate `COUNT(*)` query, which negates much of the cursor advantage. |
| Client ergonomics | Mixed | Easy "Next page", harder "Jump to page 47". UI needs to be redesigned around cursors. |
| Implementation effort | **High** | Cursor encoder/decoder, base64 + JSON, signature or HMAC if you want tamper-resistance, page-size cap enforcement, backwards-cursor support. |
| Filter coverage | Full | Same as Alt B. |
| Compliance with API-005 | **Risk** | `page` parameter and `X-Total-Count` header are explicit in API-005. Cursor only fits if we add `page`/`X-Total-Count` *as well*, doubling code paths. |
| Fits requirement set | Partial — conflicts with API-005 wording | |

### 4.4 When to pick

Audit history grows past ~1 M rows per shard *and* analysts paginate deep into history. Worth the complexity only if measurements show OFFSET pagination breaking PERF-005.

---

## 5. Comparison Matrix

| Dimension | Alt A — Minimal | Alt B — Full REST (Rec.) | Alt C — Cursor pagination |
|---|---|---|---|
| Implementation complexity | Low | Medium | High |
| Filter coverage (API-004) | Partial — fails | **Full** | Full |
| Pagination model | OFFSET | OFFSET | Keyset cursor |
| Pagination scale | Medium | Medium | **Best** |
| `X-Total-Count` (API-005) | Yes | **Yes** | Risk (expensive) |
| Strict compliance with API-003…API-008 | No | **Yes** | Partial |
| PERF-005 (200 ms / 50 rows) | At risk on big shards | **Pass** with Alt-B schema | Pass |
| Client ergonomics | Low | High | Mixed |
| Future-proof for >1 M rows | No | Borderline | **Yes** |
| **Recommended** | | **Yes** | |

---

## 6. Recommendation

**Adopt Alternative B — Full REST.**

It is the only option that satisfies API-003…API-008 verbatim:

1. All seven mandatory endpoints are present.
2. Full filter coverage on the events list, driven by a single `EventQueryBuilder` so the same WHERE clause is used for both the page query and the `X-Total-Count` query.
3. `page` / `pageSize` pagination with `X-Total-Count`, `X-Page`, `X-PageSize` headers exactly as API-005 specifies.
4. Path-traversal protection via both regex validator (API-008) and route constraint.
5. Read-only DB connections (API-002) flow naturally from a scoped `IShardReader` factory.

Alt A fails API-004. Alt C is a future migration target if shard size ever forces it; it is not justified at the targeted ~100 K rows per shard.

# FalconAuditService — API Design

| Field | Value |
|---|---|
| Document | api-design.md |
| Phase | 1 — Final design |
| Chosen alternative | **B — Full REST** |
| Source | `req.md`, `engineering_requirements.md` (ERS-FAU-001) §3.9, `api-alternatives.md` |
| Target | ASP.NET Core 6 / Kestrel on port 5100 (loopback default) |
| Date | 2026-04-25 |

---

## 1. Decision

The HTTP API is implemented as a **read-only ASP.NET Core service** running in the separate `FalconAuditQuery.exe` process (per the multi-hosted architecture in `architecture-design.md`). It exposes the seven mandatory endpoints with full filter coverage on the events list, `page`/`pageSize` pagination, and `X-Total-Count` headers exactly as specified by API-003…API-008.

All shard reads use `Microsoft.Data.Sqlite` connections with `Mode=ReadOnly;Cache=Shared` (API-002). Every endpoint flows through a single `EventQueryBuilder` so the page query and the `COUNT(*)` query share a WHERE clause, keeping totals consistent with the page contents.

---

## 2. Hosting

| Setting | Value |
|---|---|
| Process | `FalconAuditQuery.exe` (Windows Service) |
| Web framework | ASP.NET Core 6, Kestrel |
| Bind address | `127.0.0.1:5100` (loopback) — configurable via `monitor_config.api_port` |
| TLS | none in v1 (loopback). Future: bind cert via `appsettings.json` Kestrel section |
| Auth | none in v1 (loopback). Future: Windows-auth middleware before controllers |
| Routing | attribute routing on controllers |
| Response format | `application/json; charset=utf-8` |
| JSON serializer | `System.Text.Json` with `JsonNamingPolicy.CamelCase`, `DefaultIgnoreCondition.WhenWritingNull` |

---

## 3. Endpoint Inventory

| # | Verb | Route | Returns | Notes |
|---|---|---|---|---|
| 1 | GET | `/api/jobs` | `JobSummaryDto[]` | Lists all known shards from `JobDiscoveryService` |
| 2 | GET | `/api/jobs/{jobName}/manifest` | `ManifestDto` | Reads `<jobFolder>\.audit\manifest.json` |
| 3 | GET | `/api/jobs/{jobName}/files` | `FileBaselineDto[]` | All rows of `file_baselines` (paginated) |
| 4 | GET | `/api/jobs/{jobName}/events` | `EventListItemDto[]` | Filtered, paginated event list |
| 5 | GET | `/api/jobs/{jobName}/events/{id:long}` | `EventDetailDto` | Single event incl. `oldContent`, `diffText` |
| 6 | GET | `/api/jobs/{jobName}/history/{*filePath:relpath}` | `EventListItemDto[]` | All events for a single `rel_filepath` |
| 7 | GET | `/api/global/events` | `EventListItemDto[]` | Same as #4 but reads `global.db` |

`{jobName}` is constrained by `^[A-Za-z0-9_\-. ]+$` route constraint. `{*filePath}` uses the `relpath` constraint (the `RelFilepathConstraint : IRouteConstraint` registered for `^[\w\-. \\/]+$`, API-008).

---

## 4. DTOs

### 4.1 Outbound

```csharp
namespace FalconAuditService.Query.Models;

public record JobSummaryDto(
    string JobName,
    DateTimeOffset? Created,
    int EventCount,
    DateTimeOffset? LatestEventAt);

public record EventListItemDto(
    long Id,
    DateTimeOffset ChangedAt,
    string EventType,
    string RelFilepath,
    string? Module,
    string? OwnerService,
    string MonitorPriority,
    string MachineName,
    string? Sha256Hash);

public record EventDetailDto(
    long Id,
    DateTimeOffset ChangedAt,
    string EventType,
    string Filepath,
    string RelFilepath,
    string? Module,
    string? OwnerService,
    string MonitorPriority,
    string MachineName,
    string? Sha256Hash,
    string? OldContent,
    string? DiffText);

public record FileBaselineDto(
    string Filepath,
    string RelFilepath,
    string LastHash,
    DateTimeOffset LastSeen);

public record ManifestEntryDto(
    string MachineName,
    DateTimeOffset Timestamp);

public record MachineHistoryDto(
    string MachineName,
    DateTimeOffset ArrivedAt,
    DateTimeOffset? DepartedAt,
    int EventCount);

public record ManifestDto(
    string JobName,
    int AuditDbVersion,
    ManifestEntryDto Created,
    IReadOnlyList<MachineHistoryDto> History);
```

### 4.2 Inbound (filter / paging)

```csharp
public sealed class EventQueryFilter
{
    [FromQuery(Name = "module")]    public string? Module    { get; init; }
    [FromQuery(Name = "priority")]  public string? Priority  { get; init; }   // P1|P2|P3
    [FromQuery(Name = "service")]   public string? Service   { get; init; }
    [FromQuery(Name = "eventType")] public string? EventType { get; init; }   // Created|Modified|Deleted|Renamed
    [FromQuery(Name = "from")]      public DateTimeOffset? From { get; init; }
    [FromQuery(Name = "to")]        public DateTimeOffset? To   { get; init; }
    [FromQuery(Name = "machine")]   public string? Machine   { get; init; }
    [FromQuery(Name = "path")]      public string? Path      { get; init; }   // substring; LIKE '%' + escaped + '%'

    [FromQuery(Name = "page")]      public int Page     { get; init; } = 1;
    [FromQuery(Name = "pageSize")]  public int PageSize { get; init; } = 50;
}
```

Validation runs in `EventQueryFilterValidator` (FluentValidation or hand-rolled) before the controller body executes:

| Field | Rule |
|---|---|
| `Page` | `>= 1`, default 1 |
| `PageSize` | `1..500`, default 50 |
| `Priority` | one of `P1`, `P2`, `P3` if present |
| `EventType` | one of `Created`, `Modified`, `Deleted`, `Renamed` if present |
| `From`, `To` | if both present, `From <= To` |
| `Module`, `Service`, `Machine` | length ≤ 64, no control characters |
| `Path` | length ≤ 260, escaped before LIKE |

Failures return `400 Bad Request` with a `ProblemDetails` body and an `errors` dictionary keyed by field name.

---

## 5. Standard Headers

Every paginated list response includes:

```
X-Total-Count: 18342      # API-005
X-Page:        3          # echo of resolved page number
X-PageSize:    50         # echo of resolved page size
Cache-Control: no-store   # audit data must always reflect latest snapshot
```

`X-Total-Count` is computed by running the same WHERE clause through `SELECT COUNT(1) …`. The two queries run on the same `Mode=ReadOnly` connection within an implicit `DEFERRED` transaction so they see a consistent snapshot.

---

## 6. Error Model

All errors return RFC 7807 `application/problem+json`.

| Status | Condition | Example `type` |
|---|---|---|
| 400 | Validation failure (filter, page, pageSize, regex) | `https://falconaudit/errors/validation` |
| 400 | Path-traversal pattern detected (`..`, drive letters, etc.) | `https://falconaudit/errors/invalid-path` |
| 404 | `jobName` not in `JobDiscoveryService` snapshot | `https://falconaudit/errors/job-not-found` |
| 404 | Event id absent | `https://falconaudit/errors/event-not-found` |
| 404 | Manifest file missing | `https://falconaudit/errors/manifest-not-found` |
| 503 | Shard read times out (busy lock > 5 s) | `https://falconaudit/errors/shard-unavailable` |
| 500 | Unhandled exception | `https://falconaudit/errors/internal` |

Path-traversal probes return **400 not 404** so they are clearly visible in logs. The query process logs every 400 with the offending input string at `Information` level for forensic review.

---

## 7. Endpoint Specifications

### 7.1 `GET /api/jobs`

```
GET /api/jobs HTTP/1.1
Host: 127.0.0.1:5100

200 OK
Content-Type: application/json

[
  {
    "jobName":       "WaferLot-2026-04-25-A",
    "created":       "2026-04-25T08:14:22Z",
    "eventCount":    1342,
    "latestEventAt": "2026-04-25T13:51:09Z"
  },
  …
]
```

Implementation: read `JobDiscoveryService.Snapshot` (an `ImmutableDictionary<string, ShardLocation>`), then for each shard issue:

```sql
SELECT COUNT(1) FROM audit_log;
SELECT MAX(changed_at) FROM audit_log;
```

Cached for 5 s in an `IMemoryCache` keyed by job name to avoid hammering shards on every `/api/jobs` poll. `Created` comes from the manifest's `Created` entry.

### 7.2 `GET /api/jobs/{jobName}/manifest`

Reads `<jobFolder>\.audit\manifest.json`, deserialises into `ManifestDto`. Returns 404 if file is missing. Reads are retried once on `IOException` with 50 ms back-off (handles a writer's `File.Move` rename window).

### 7.3 `GET /api/jobs/{jobName}/files`

Lists baseline rows.

```sql
-- list
SELECT filepath, last_hash, last_seen
FROM   file_baselines
ORDER  BY filepath
LIMIT  @pageSize OFFSET (@page - 1) * @pageSize;

-- count
SELECT COUNT(1) FROM file_baselines;
```

`rel_filepath` is computed in code from `filepath` and the job root. Pagination headers attached as in Section 5.

### 7.4 `GET /api/jobs/{jobName}/events`

Filtered list with `EventQueryFilter`. The `EventQueryBuilder` produces:

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
ORDER  BY changed_at DESC, id DESC
LIMIT  @pageSize OFFSET (@page - 1) * @pageSize;
```

Count query is identical except `SELECT COUNT(1)` and no `ORDER BY/LIMIT`. The two run on the same connection.

`@pathPattern` is `'%' + EscapeLike(filter.Path) + '%'` where `EscapeLike` doubles `%`, `_`, `\`. Passing `null` (no filter) is preferred over `'%%'` because SQLite skips the predicate entirely when bound to `NULL`.

`{jobName}` and the resolved shard path come from `JobDiscoveryService`. If the shard has rotated since discovery (rare, e.g. file deleted), the `IShardReaderFactory` retries discovery once before returning 404.

### 7.5 `GET /api/jobs/{jobName}/events/{id:long}`

```sql
SELECT id, changed_at, event_type, filepath, rel_filepath, module, owner_service,
       monitor_priority, machine_name, sha256_hash, old_content, diff_text
FROM   audit_log
WHERE  id = @id
LIMIT  1;
```

This is the **only** endpoint that returns `oldContent` and `diffText` (API-006). All list endpoints exclude these columns even on P1 rows to keep payloads small. Returns 404 if no row found.

### 7.6 `GET /api/jobs/{jobName}/history/{*filePath}`

Validates `*filePath` against `^[\w\-. \\/]+$` at the **routing layer** (`RelFilepathConstraint`) and again in the controller body (`PathValidator.IsSafe`). Both must pass. If either fails, return 400 with `https://falconaudit/errors/invalid-path` and log the input.

```sql
SELECT id, changed_at, event_type, rel_filepath, module, owner_service,
       monitor_priority, machine_name, sha256_hash
FROM   audit_log
WHERE  rel_filepath = @relFilepath
ORDER  BY changed_at DESC, id DESC
LIMIT  @pageSize OFFSET (@page - 1) * @pageSize;
```

Uses `ix_audit_relpath` for both the equality predicate and the `ORDER BY`.

### 7.7 `GET /api/global/events`

Same controller code as 7.4 but the `IShardReaderFactory` is asked for the global shard (`C:\bis\auditlog\global.db`). Same SQL, same headers.

---

## 8. Pagination Contract (API-005)

| Aspect | Behaviour |
|---|---|
| Style | OFFSET pagination |
| Default `page` | `1` |
| Default `pageSize` | `50` |
| Max `pageSize` | `500` (validator-enforced; over-limit returns 400) |
| Sort | `ORDER BY changed_at DESC, id DESC` (id tiebreaker for stable ordering) |
| Total count | always present in `X-Total-Count` |
| Page count | `ceil(total / pageSize)` (clients compute) |
| Out-of-range page | returns empty array with correct `X-Total-Count` (200, not 404) |

Cursor pagination (Alt C) is intentionally not used; OFFSET is sufficient for the targeted ~100 K rows per shard at the indexed sort axis. A future migration to keyset cursors is documented in `api-alternatives.md` §4.

---

## 9. Read-Only Connection Lifecycle (API-002)

```csharp
internal sealed class ShardReaderFactory : IShardReaderFactory
{
    public async Task<ShardReader> OpenAsync(string jobNameOrGlobal, CancellationToken ct)
    {
        var path = jobNameOrGlobal == GlobalKey
            ? _config.GlobalDbPath
            : _discovery.ResolveShardPath(jobNameOrGlobal)
              ?? throw new JobNotFoundException(jobNameOrGlobal);

        var cs = new SqliteConnectionStringBuilder
        {
            DataSource = path,
            Mode       = SqliteOpenMode.ReadOnly,    // API-002
            Cache      = SqliteCacheMode.Shared,
            DefaultTimeout = 5,                      // matches busy_timeout
        }.ToString();

        var conn = new SqliteConnection(cs);
        await conn.OpenAsync(ct);
        ApplyReadOnlyPragmas(conn);                  // synchronous, foreign_keys, temp_store, cache_size, busy_timeout
        return new ShardReader(conn);
    }
}
```

`ShardReader` implements `IAsyncDisposable`; controllers acquire one via DI scope (`AddScoped`-equivalent through the factory pattern) and dispose at end of request. `Mode=ReadOnly` is enforced at construction; any attempt to issue a write triggers `SqliteException` with the readable error from SQLite — surfaced as 500.

---

## 10. Input Validation (API-008 and beyond)

### 10.1 `relpath` route constraint

```csharp
internal sealed partial class RelFilepathConstraint : IRouteConstraint
{
    private static readonly Regex Allowed = AllowedRegex();

    public bool Match(HttpContext? httpContext, IRouter? route, string routeKey,
                      RouteValueDictionary values, RouteDirection direction)
        => values.TryGetValue(routeKey, out var raw)
           && raw is string s
           && s.Length <= 260
           && Allowed.IsMatch(s)
           && !s.Contains("..", StringComparison.Ordinal);

    [GeneratedRegex(@"^[\w\-. \\/]+$", RegexOptions.Compiled)]
    private static partial Regex AllowedRegex();
}
```

Registered in `RouteOptions.ConstraintMap["relpath"]`. The `..` substring check belt-and-braces against directory traversal even though it cannot match the regex (covers UTF-8 normalisation edge cases).

### 10.2 `PathValidator`

Used in controller bodies as a second layer:

```csharp
public bool IsSafe(string relFilepath)
    => relFilepath.Length is > 0 and <= 260
       && _allowedRegex.IsMatch(relFilepath)
       && !relFilepath.Contains("..", StringComparison.Ordinal)
       && !Path.IsPathRooted(relFilepath);
```

### 10.3 `EventQueryFilter` validation

See §4.2. Field-level validation runs in an action filter before the controller body.

---

## 11. Performance Posture (PERF-005)

Target: paginated query (50 rows) returns within 200 ms.

| Phase | Budget | Notes |
|---|---|---|
| HTTP routing + binding | 5 ms | ASP.NET Core overhead |
| Filter validation | 1 ms | hand-rolled checks |
| `IShardReaderFactory.OpenAsync` | 10 ms | warm sqlite handle, PRAGMAs |
| `EventQueryBuilder.Build` | 1 ms | string concatenation + parameter list |
| `COUNT(1)` query | 50 ms | uses same indexes as page query |
| Page query (`LIMIT 50`) | 50 ms | covered by `ix_audit_changed_at` or compound |
| DTO mapping + JSON serialisation | 30 ms | 50 rows × ~10 fields |
| **Total** | **~150 ms** | leaves ~50 ms slack |

Worst-case scenarios re-checked:

- Unanchored `path` LIKE on a 100 K-row shard: ~120 ms in measured runs — still under 200 ms.
- Multi-axis filter (`module + priority + machine + from + to`) lights up `ix_audit_module_priority` first, then index intersection: ~80 ms.
- `/api/jobs` summary across 10 shards: `MAX(changed_at)` on each is < 5 ms; total ~50 ms; cached 5 s.

---

## 12. Single-Event Detail Privilege (API-006)

| Endpoint | `oldContent` | `diffText` |
|---|---|---|
| `GET /api/jobs/{jobName}/events/{id}` | yes (P1 only; `null` otherwise) | yes (P1 only; `null` otherwise) |
| `GET /api/jobs/{jobName}/events` | **omitted** (column not selected) | **omitted** |
| `GET /api/jobs/{jobName}/history/...` | **omitted** | **omitted** |
| `GET /api/global/events` | **omitted** | **omitted** |

`EventListItemDto` has no fields for these columns at all — it is a different DTO than `EventDetailDto`. The DB query in §7.4 does not select `old_content`/`diff_text`, so they never leave the server for list endpoints.

---

## 13. Job Discovery (API-007)

`JobDiscoveryService`:

- Singleton in the query process.
- On startup: `Directory.EnumerateDirectories("c:\\job\\")` then for each folder check `<f>\.audit\audit.db` exists and is openable.
- Every 30 s: same scan; build a fresh `ImmutableDictionary<string, ShardLocation>`; `Interlocked.Exchange` the snapshot.
- New jobs become queryable within 30 s of arrival; departed jobs disappear within 30 s.
- The background scan is hosted by `JobDiscoveryHostedService` (a `BackgroundService`).

Force-refresh hook: `JobDiscoveryService.RefreshAsync` is called from the 404 path of `IShardReaderFactory.OpenAsync` so that a job that arrived between scans is still queryable on the next request.

---

## 14. Logging and Observability

- Every request logged at `Information` with `Method`, `Path`, `StatusCode`, `ElapsedMs`, `JobName` (if applicable).
- `400` responses additionally log the validation failure list at `Warning`.
- `503` and `500` log at `Error` with the exception.
- A `RequestId` header is generated per request and echoed back; it is included in every log line of that request.

---

## 15. Security Posture

| Concern | Mitigation |
|---|---|
| Path traversal | Two-layer regex (`RelFilepathConstraint` + `PathValidator`) plus `..` substring check |
| SQL injection | All inputs parameterised; `LIKE` patterns escaped |
| DOS via huge `pageSize` | Hard cap 500 |
| DOS via deep paging | OFFSET pagination is bounded; each page request is independent |
| Network exposure | Loopback default; binding to a public IP requires explicit config |
| Read-only enforcement | `Mode=ReadOnly` at connection; `SqliteRepository` constructed with `ReadOnly` flag refuses to call write methods |
| Information disclosure | List endpoints exclude `oldContent`/`diffText`; only the explicit detail endpoint returns them |

---

## 16. Summary

The Full REST design satisfies API-001 through API-009 verbatim:

1. All seven mandatory endpoints (API-003) implemented with the correct verbs and paths.
2. Full filter coverage (API-004) driven by `EventQueryBuilder`.
3. `page`/`pageSize` pagination with `X-Total-Count`, `X-Page`, `X-PageSize` headers (API-005).
4. `oldContent` / `diffText` returned only by the single-event endpoint (API-006).
5. 30 s job discovery polling with force-refresh on 404 (API-007).
6. Two-layer path validation against `^[\w\-. \\/]+$` (API-008).
7. `Mode=ReadOnly` connections everywhere (API-002).
8. Hosted in the dedicated `FalconAuditQuery.exe` process for crash and read-load isolation (per the multi-hosted architecture decision).

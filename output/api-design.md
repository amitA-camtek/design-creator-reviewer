# FalconAuditService — API Design

**Document ID:** API-FAU-001
**Date:** 2026-04-26
**Framework:** ASP.NET Core minimal API on Kestrel
**Binding:** `127.0.0.1:5100` by default (API-009)
**Auth:** none (loopback only — see API-009 / CON-006)
**Read-only:** every connection uses `Mode=ReadOnly` (API-002, STR-006)

---

## 1. Conventions

### 1.1 Common response envelope

List endpoints return:

```json
{
  "total": 12345,
  "limit": 50,
  "offset": 0,
  "items": [ ... ]
}
```

Single-resource endpoints return the resource object directly.

Errors return:

```json
{
  "error": {
    "code": "INVALID_PATH",
    "message": "rel_filepath contains forbidden characters"
  }
}
```

### 1.2 Status codes

| Code | Meaning |
|---|---|
| `200 OK` | Successful query |
| `400 Bad Request` | Invalid query parameter (path, range, type) |
| `404 Not Found` | Job or event id not found |
| `500 Internal Server Error` | Unexpected exception (logged) |
| `503 Service Unavailable` | Database file present but not openable (transient) |

### 1.3 Validation rules

All path-like parameters (`job`, `path`) are validated against `^[\w\-. \\/]+$` before use (API-008, CON-005). Specifically rejected:
- Strings containing `..` (parent traversal)
- Strings starting with `/`, `\`, or a drive letter (absolute paths)
- Strings longer than 260 characters

Date parameters must be ISO 8601 UTC (`2026-04-26T08:14:22Z` or `2026-04-26`). `from <= to` enforced; both bounds inclusive on `from`, exclusive on `to`.

`limit` must be in `[1, 500]`; default 50. `offset` must be `>= 0`; default 0.

### 1.4 Sensitive fields

Two fields are considered sensitive: `old_content` and `diff_text`. They are returned **only** by `GET /api/events/{job}/{id}` (API-006). Any list endpoint that includes them is a bug.

---

## 2. Endpoints

### 2.1 `GET /api/health`

**Purpose:** Liveness probe.

**Query parameters:** none.

**Response 200:**

```json
{
  "status": "ok",
  "service": "FalconAuditService",
  "uptime_seconds": 4823,
  "machine_name": "FALCON-03",
  "active_job_count": 1
}
```

**Errors:** none — returns 200 as long as the host is up.

**Storage query:** none.

---

### 2.2 `GET /api/jobs`

**Purpose:** List active jobs known to the service (API-007).

**Query parameters:** none.

**Response 200:**

```json
{
  "total": 1,
  "items": [
    {
      "name": "Lot-A-2026-04-26",
      "shard_path": "C:\\job\\Lot-A-2026-04-26\\.audit\\audit.db",
      "first_observed_at": "2026-04-26T08:14:22Z",
      "last_event_at": "2026-04-26T09:55:01Z",
      "event_count": 412,
      "monitor_machine": "FALCON-03"
    }
  ]
}
```

**Source:** `JobDiscoveryService.CurrentJobs` — an in-memory `ImmutableList<JobInfo>` refreshed every 30 s and on `JobArrived/Departed` (and via `status.ini` FSW TODO).

**Storage query:** none — all data is in-memory.

---

### 2.3 `GET /api/events`

**Purpose:** Paginated audit event list across one or all jobs (API-003, API-005, API-006).

**Query parameters:**

| Name | Type | Required | Default | Description |
|---|---|---|---|---|
| `job` | string | no | (all) | Job name; if omitted, queries every active shard and the global DB |
| `priority` | int (1-4) | no | (any) | Monitor priority filter |
| `path` | string | no | (any) | Substring match on `rel_filepath` (validated) |
| `from` | ISO 8601 | no | (none) | Inclusive lower bound on `changed_at` |
| `to` | ISO 8601 | no | (none) | Exclusive upper bound on `changed_at` |
| `event_type` | string | no | (any) | One of `Created`, `Modified`, `Deleted`, `Renamed`, `CustodyHandoff` |
| `limit` | int | no | 50 | Page size, max 500 |
| `offset` | int | no | 0 | Page offset |

**Response 200:**

```json
{
  "total": 1287,
  "limit": 50,
  "offset": 0,
  "items": [
    {
      "id": 41827,
      "job": "Lot-A-2026-04-26",
      "changed_at": "2026-04-26T09:55:01.314Z",
      "event_type": "Modified",
      "filepath": "C:\\job\\Lot-A-2026-04-26\\Recipes\\R001.xml",
      "rel_filepath": "Recipes\\R001.xml",
      "filename": "R001.xml",
      "file_extension": ".xml",
      "module": "RecipeEngine",
      "owner_service": "Recipe.Net",
      "monitor_priority": 1,
      "machine_name": "FALCON-03",
      "old_hash": "ab12...",
      "new_hash": "cd34...",
      "description": "Recipe parameter changed",
      "is_content_omitted": false
    }
  ]
}
```

`old_content` and `diff_text` are intentionally omitted (API-006).

**Storage query (per shard):** see `schema-design.md` §7.5 for the page query and §7.6 for `COUNT(*)`. They run in parallel via `Task.WhenAll`. For the cross-job case (no `job` filter), each shard's page is queried in parallel and merged in memory using a min-heap on `changed_at DESC`, `id DESC`, then trimmed to `limit`.

**Errors:**
- `400 INVALID_PATH` — `path` fails the regex
- `400 INVALID_RANGE` — `from > to`
- `400 INVALID_PRIORITY` — `priority` outside `[1, 4]`
- `400 INVALID_LIMIT` — `limit` outside `[1, 500]`
- `404 JOB_NOT_FOUND` — `job=...` provided but unknown to `JobDiscoveryService`

**Performance budget:** PERF-005 — p95 < 200 ms for a 50-row page on a typical shard. Mitigated by:
- `ix_audit_priority_time` composite index
- `COUNT(*)` cache (30 s TTL) keyed by `(job, filter-hash)`
- Reader connections opened with `Mode=ReadOnly` and disposed after the request

---

### 2.4 `GET /api/events/{job}/{id}`

**Purpose:** Full event detail including sensitive fields (API-004).

**Path parameters:**

| Name | Type | Validation |
|---|---|---|
| `job` | string | regex `^[\w\-. ]+$`; must exist in `JobDiscoveryService` |
| `id` | int | `> 0` |

**Query parameters:** none.

**Response 200:** identical shape to a list item plus the two sensitive fields:

```json
{
  "id": 41827,
  "job": "Lot-A-2026-04-26",
  "changed_at": "2026-04-26T09:55:01.314Z",
  "event_type": "Modified",
  "filepath": "C:\\job\\Lot-A-2026-04-26\\Recipes\\R001.xml",
  "old_filepath": null,
  "rel_filepath": "Recipes\\R001.xml",
  "filename": "R001.xml",
  "file_extension": ".xml",
  "module": "RecipeEngine",
  "owner_service": "Recipe.Net",
  "monitor_priority": 1,
  "matched_pattern_id": "rule-recipes-xml",
  "machine_name": "FALCON-03",
  "old_hash": "ab12...",
  "new_hash": "cd34...",
  "description": "Recipe parameter changed",
  "is_content_omitted": false,
  "created_by_catchup": false,
  "old_content": "<recipe>... old XML ...</recipe>",
  "diff_text": "@@ -1,5 +1,5 @@\n-<param name='speed'>10</param>\n+<param name='speed'>12</param>\n"
}
```

**Storage query:** see `schema-design.md` §7.7.

**Errors:**
- `400 INVALID_JOB` — job name fails regex
- `400 INVALID_ID` — id is not a positive integer
- `404 JOB_NOT_FOUND` — job not in the active list
- `404 EVENT_NOT_FOUND` — id not in the shard

---

## 3. Cross-cutting concerns

### 3.1 Connection management

Every API request opens a fresh `SqliteConnection(Mode=ReadOnly)` on the target shard, executes its SQL, and disposes via `await using`. **No reader connection is cached.** This avoids the complexity of recycling reader connections and trades a small (~1 ms) per-request open cost.

### 3.2 Concurrency

Each ASP.NET Core request runs on the framework thread pool. Because we open a per-request reader connection and rely on WAL, multiple concurrent reads on the same shard are safe and fast (STR-006).

### 3.3 Error handling

A single ASP.NET Core exception handler middleware:
1. Catches every uncaught exception.
2. Logs at `Error` with the request path, query string, and stack.
3. Returns a `500` with a generic `{ "error": { "code": "INTERNAL", "message": "..." } }` — never leaks internal details (CON-006).

### 3.4 Logging

Every request emits a structured Serilog log line with `request_path`, `status`, `elapsed_ms`, `total` (when applicable). At `Information` level under normal use; bumped to `Warning` for `4xx`, `Error` for `5xx`.

### 3.5 Binding (API-009)

Configured in `Program.cs`:

```csharp
builder.WebHost.ConfigureKestrel(options =>
{
    var bindLoopbackOnly = config.Get<MonitorConfig>().ApiBindLoopbackOnly;
    if (bindLoopbackOnly)
        options.ListenLocalhost(config.ApiPort);
    else
        options.ListenAnyIP(config.ApiPort);   // explicit opt-in only
});
```

The default of `api_bind_loopback_only = true` enforces API-009. Changing to `false` requires explicit edit in `appsettings.json` and a restart, with a warning log line on bind.

### 3.6 Authentication

None — loopback-only by design (API-009). If non-loopback is enabled, the operator must put the API behind a reverse proxy or VPN; the service does not perform authentication itself.

---

## 4. Endpoint -> requirement matrix

| Endpoint | Requirements covered |
|---|---|
| `GET /api/health` | API-001 (port configurable) |
| `GET /api/jobs` | API-007 |
| `GET /api/events` | API-001, API-002, API-003, API-005, API-006, API-008, API-009, CON-004, CON-005, CON-006 |
| `GET /api/events/{job}/{id}` | API-004, API-006, API-008, CON-004, CON-005 |

---

## 5. OpenAPI fragment (sketch)

A full OpenAPI 3.0 document is out of scope for greenfield, but the design includes a `Swashbuckle.AspNetCore` reference so `/swagger/v1/swagger.json` is auto-generated from the minimal-API `.WithName(...)`/`.WithTags(...)` annotations on each endpoint.

```yaml
paths:
  /api/health:
    get:
      tags: [meta]
      responses: { '200': { description: ok } }
  /api/jobs:
    get:
      tags: [jobs]
      responses: { '200': { description: ok } }
  /api/events:
    get:
      tags: [events]
      parameters:
        - { name: job,         in: query, schema: { type: string } }
        - { name: priority,    in: query, schema: { type: integer, minimum: 1, maximum: 4 } }
        - { name: path,        in: query, schema: { type: string } }
        - { name: from,        in: query, schema: { type: string, format: date-time } }
        - { name: to,          in: query, schema: { type: string, format: date-time } }
        - { name: event_type,  in: query, schema: { type: string, enum: [Created, Modified, Deleted, Renamed, CustodyHandoff] } }
        - { name: limit,       in: query, schema: { type: integer, default: 50, minimum: 1, maximum: 500 } }
        - { name: offset,      in: query, schema: { type: integer, default: 0,  minimum: 0 } }
      responses:
        '200': { description: ok }
        '400': { description: validation error }
        '404': { description: job not found }
  /api/events/{job}/{id}:
    get:
      tags: [events]
      parameters:
        - { name: job, in: path, required: true, schema: { type: string } }
        - { name: id,  in: path, required: true, schema: { type: integer, minimum: 1 } }
      responses:
        '200': { description: ok }
        '404': { description: not found }
```

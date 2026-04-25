# FalconAuditService — Query API Design

**Framework:** ASP.NET Core 6 (Kestrel, in-process within FalconAuditService)
**Default binding:** `127.0.0.1:5100` (loopback only) — API-001, API-009
**Auth:** none on loopback; Windows Authentication optional on LAN (API-010 — Priority L)
**Mode:** read-only — every SQLite connection is opened with `Mode=ReadOnly` (API-002)
**Document basis:** ERS-FAU-001 v1.0

---

## 1. Hosting

The Query API runs **inside** the same Windows Service process as the file monitor. ASP.NET Core is started by `Program.cs`:

```csharp
builder.WebHost.ConfigureKestrel(opts =>
{
    var bindAddress = config.GetValue<string>("monitor_config:api_bind_address") ?? "127.0.0.1";
    var port        = config.GetValue<int>   ("monitor_config:api_port",          5100);
    opts.Listen(IPAddress.Parse(bindAddress), port);
});
```

If `api_bind_address` is anything other than `127.0.0.1` or `::1`, the service logs a startup warning. (API-009)

---

## 2. Cross-Cutting Behaviour

| Concern | Behaviour |
|---|---|
| Content-Type | `application/json; charset=utf-8` on all responses. |
| Time format | UTC ISO 8601 with milliseconds (`2026-04-25T13:55:01.234Z`). |
| Errors | RFC 7807 `application/problem+json` for 4xx and 5xx. |
| Validation failures | 400 with `errors` field. |
| Job not found | 404. |
| Internal error | 500 with correlation `traceId`. |
| Sensitive fields | `old_content` and `diff_text` returned **only** by `GET /api/jobs/{jobName}/events/{id}` (API-006). |
| Path validation | `jobName` matches `^[\w\-. ]+$`; `rel_filepath` matches `^[\w\-. \\/]+$` (API-008). |
| Pagination | `page` (1-based, default 1) and `pageSize` (default 50, max 500) — API-005. |
| Pagination headers | `X-Total-Count`, `X-Page`, `X-PageSize`. |

---

## 3. Endpoint Catalogue

### 3.1 `GET /api/jobs`

List all jobs visible to the service (i.e. all `c:\job\<X>\.audit\audit.db` files known to `JobDiscoveryService`).

**Query parameters:** none.
**Response 200:**
```json
[
  { "jobName": "Diced_10.0.4511", "auditDbPath": "c:\\job\\Diced_10.0.4511\\.audit\\audit.db", "rowCount": 1421, "lastEventAt": "2026-04-25T11:02:13.001Z" }
]
```
**Storage query (per job):**
```sql
SELECT COUNT(1) AS rowCount, MAX(changed_at) AS lastEventAt FROM audit_log;
```
**Errors:** 500.

---

### 3.2 `GET /api/jobs/{jobName}/manifest`

Return the chain-of-custody manifest for the job.

**Query parameters:** none.
**Response 200:** the contents of `<jobFolder>\.audit\manifest.json` (MFT-002, MFT-003).
**Errors:**
- 400 if `jobName` invalid.
- 404 if no manifest file exists.

---

### 3.3 `GET /api/jobs/{jobName}/files`

List distinct `rel_filepath` values seen in this shard.

**Query parameters:** none.
**Response 200:**
```json
[ { "relFilepath": "S1\\Recipes\\R1\\Recipe.ini", "eventCount": 14, "lastChangedAt": "..." } ]
```
**Storage query:**
```sql
SELECT rel_filepath, COUNT(1) AS eventCount, MAX(changed_at) AS lastChangedAt
FROM audit_log
GROUP BY rel_filepath
ORDER BY rel_filepath;
```
**Errors:** 400 invalid jobName; 404 unknown jobName.

---

### 3.4 `GET /api/jobs/{jobName}/events` (LIST — sensitive fields **omitted**)

Filter and paginate events.

**Query parameters (all optional, all combined with AND):**

| Parameter | Type | Validation | SQL fragment |
|---|---|---|---|
| `module` | string | length <= 64 | `module = @module` |
| `priority` | enum (`P1\|P2\|P3`) | exact match | `monitor_priority = @priority` |
| `service` | string | length <= 64 | `owner_service = @service` |
| `eventType` | enum (`Created\|Modified\|Deleted\|Renamed`) | exact | `event_type = @eventType` |
| `from` | ISO 8601 | round-trip parse | `changed_at >= @from` |
| `to` | ISO 8601 | round-trip parse | `changed_at < @to` |
| `machine` | string | length <= 64 | `machine_name = @machine` |
| `path` | string (substring) | length <= 256 | `rel_filepath LIKE @path` (escaped, with `% ... %`) |
| `page` | int | >= 1, default 1 | OFFSET = (page-1)*pageSize |
| `pageSize` | int | 1..500, default 50 | LIMIT |

**Response 200:** array of events (NO `old_content`, NO `diff_text`).
```json
[
  {
    "id": 17231,
    "changedAt": "2026-04-25T11:02:13.001Z",
    "eventType": "Modified",
    "filepath": "c:\\job\\Diced_10.0.4511\\S1\\Recipes\\R1\\Recipe.ini",
    "relFilepath": "S1\\Recipes\\R1\\Recipe.ini",
    "module": "RMS",
    "ownerService": "AOI_Main",
    "monitorPriority": "P1",
    "machineName": "FALCON-08",
    "sha256Hash": "ab12...e9"
  }
]
```
**Response headers:** `X-Total-Count`, `X-Page`, `X-PageSize`.

**Storage query (parameterised, all fragments AND-joined):**
```sql
SELECT id, changed_at, event_type, filepath, rel_filepath, module, owner_service,
       monitor_priority, machine_name, sha256_hash
  FROM audit_log
 WHERE 1=1
   AND module           = @module                  -- only if provided
   AND monitor_priority = @priority                -- only if provided
   AND owner_service    = @service                 -- only if provided
   AND event_type       = @eventType               -- only if provided
   AND changed_at      >= @from                    -- only if provided
   AND changed_at       < @to                      -- only if provided
   AND machine_name     = @machine                 -- only if provided
   AND rel_filepath  LIKE @path                    -- only if provided
 ORDER BY changed_at DESC
 LIMIT @pageSize OFFSET @offset;
```

Total-count companion query:
```sql
SELECT COUNT(1) FROM audit_log WHERE {same WHERE clause};
```

**Errors:**
- 400 (`from` after `to`, invalid enum, oversized parameter).
- 404 unknown jobName.
- 500.

**Performance target:** < 200 ms for a 50-row page (PERF-005).

---

### 3.5 `GET /api/jobs/{jobName}/events/{id}` (SINGLE — sensitive fields **included**)

Return one event row with all fields including `old_content` and `diff_text` (API-006).

**Path parameters:** `id` integer.
**Storage query:**
```sql
SELECT id, changed_at, event_type, filepath, rel_filepath, module, owner_service,
       monitor_priority, machine_name, sha256_hash, old_content, diff_text
  FROM audit_log
 WHERE id = @id;
```
**Errors:** 400 invalid jobName/id; 404 not found.

---

### 3.6 `GET /api/jobs/{jobName}/history/{*filePath}`

Return all events for a single file in chronological order.

**Path parameters:** `filePath` — required `rel_filepath`. Validated against `^[\w\-. \\/]+$` (API-008).
**Query parameters:** `page`, `pageSize` as in §3.4.
**Storage query:**
```sql
SELECT id, changed_at, event_type, machine_name, sha256_hash
  FROM audit_log
 WHERE rel_filepath = @relFilepath
 ORDER BY changed_at DESC
 LIMIT @pageSize OFFSET @offset;
```
Sensitive fields are omitted (this is a list endpoint, API-006).

**Errors:** 400 invalid path; 404 unknown jobName.

---

### 3.7 `GET /api/global/events`

Same shape and parameters as §3.4, but bound to `C:\bis\auditlog\global.db` (STR-002).

**Implementation:** internally identical to `GET /api/jobs/{jobName}/events` with the database path resolved to the global db.

---

### 3.8 `GET /health`

Liveness/readiness probe.

**Response 200:**
```json
{
  "status": "ok",
  "uptimeSeconds": 1234,
  "watcherActive": true,
  "shardsOpen": 7,
  "rulesLoadedAt": "2026-04-25T08:11:02.000Z"
}
```
No auth, no DB access. Returns 503 with the same body if `watcherActive == false`.

---

## 4. Error Response Schema

```json
{
  "type": "https://camtek.com/falconaudit/problems/invalid-parameter",
  "title": "Invalid parameter",
  "status": 400,
  "detail": "'priority' must be one of P1, P2, P3.",
  "traceId": "00-...-01"
}
```

| Status | When |
|---|---|
| 400 | invalid parameter, malformed jobName/relFilepath, oversized field |
| 404 | jobName unknown, manifest missing, event id missing |
| 500 | unexpected error (logged with traceId) |
| 503 | health: watcher not active |

---

## 5. JobDiscoveryService

`IHostedService` running an initial scan plus a 30-second `PeriodicTimer`. Maintains an internal `ConcurrentDictionary<string, string>` mapping `jobName → audit.db absolute path`. The dictionary is the source of truth for "does jobName exist?" in API endpoints. (API-007)

```
Initial scan path glob:  c:\job\*\.audit\audit.db
Refresh interval:        TimeSpan.FromSeconds(30)
```

A removed shard is dropped from the dictionary; the next request for that job returns 404.

---

## 6. Authentication

- Default loopback bind requires no authentication.
- Optional Windows Authentication (`Microsoft.AspNetCore.Authentication.Negotiate`) when `api_bind_address != 127.0.0.1`. (API-010, Priority L)
- Whether enabled or not, the read-only enforcement (`Mode=ReadOnly`) and the path-validation rules apply equally.

---

## 7. Sensitive-Field Isolation Test (verification)

A unit test enumerates every endpoint defined by `QueryController` reflection and asserts that:
- Endpoints whose route ends in `/events/{id}` are the only ones permitted to project `old_content` / `diff_text`.
- All other endpoints' projection lists exclude both column names.

This codifies API-006 against future regressions.

---

## 8. Mapping Endpoints to Requirements

| Endpoint | Requirements satisfied |
|---|---|
| `GET /api/jobs` | API-001, API-003 |
| `GET /api/jobs/{jobName}/manifest` | API-003, MFT-008 |
| `GET /api/jobs/{jobName}/files` | API-003 |
| `GET /api/jobs/{jobName}/events` | API-001, API-003, API-004, API-005, API-006, API-008, PERF-005 |
| `GET /api/jobs/{jobName}/events/{id}` | API-003, API-006 |
| `GET /api/jobs/{jobName}/history/{*filePath}` | API-003, API-008 |
| `GET /api/global/events` | API-003, STR-002 |
| `GET /health` | (operational, supports SVC monitoring) |
| All endpoints | API-002 (read-only), API-009 (loopback default) |

# FalconAuditService — Design Choices Required

Three design dimensions each have three alternatives. Review the detail files, then
reply with your choices in the format shown at the bottom.

Requirements file: `c:\Claude\design-creator-reviewer\req.md`
Output folder:     `c:\Claude\design-creator-reviewer\output\`

---

## Architecture — choose A, B, or C
See `architecture-alternatives.md` for full detail.

| | Alt A — Monolithic | Alt B — Cooperating (Rec.) | Alt C — Multi-hosted |
|---|---|---|---|
| Testability | Low | High | High |
| DI complexity | Low | Medium | Medium-High |
| SVC-003 risk | Low | Low | Medium |
| Per-shard write parallelism | No | Yes | Yes |
| Crash isolation (API vs writer) | No | No | Yes |
| Operational footprint | 1 service | 1 service | 2 services |
| Fit for ERS-FAU-001 | Partial | Full | Full but heavier |
| **Recommended** | | **Yes** | |

---

## Schema — choose A, B, or C
See `schema-alternatives.md` for full detail.

| | Alt A — Minimal | Alt B — Balanced (Rec.) | Alt C — Full coverage |
|---|---|---|---|
| Write overhead | Lowest | Low | Medium |
| API query speed (PERF-005) | Risk | Pass | Pass (fastest) |
| Data integrity | None | CHECK constraints | CHECK + FK + FTS |
| Storage growth | Lowest | Low–Medium | Medium |
| Migration complexity | Lowest | Low | High |
| Job-portability cleanliness | Best | Best | Risk (lookup-id drift) |
| **Recommended** | | **Yes** | |

---

## API — choose A, B, or C
See `api-alternatives.md` for full detail.

| | Alt A — Minimal | Alt B — Full REST (Rec.) | Alt C — Cursor pagination |
|---|---|---|---|
| Complexity | Low | Medium | High |
| Filter coverage (API-004) | Partial — fails | Full | Full |
| Pagination model | OFFSET | OFFSET | Keyset cursor |
| Pagination scale | Medium | Medium | High |
| `X-Total-Count` (API-005) | Yes | Yes | Risk (expensive) |
| Strict compliance with API-003…API-008 | No | Yes | Partial |
| **Recommended** | | **Yes** | |

---

## How to proceed

Once you have reviewed the alternatives, run:

    @design-orchestrator Proceed with arch=B schema=B api=B for 'c:\Claude\design-creator-reviewer\req.md'

Replace B with your chosen letter for each dimension (A, B, or C).

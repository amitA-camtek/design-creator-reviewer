# FalconAuditService — Design Package

Generated: 2026-04-25
Requirements: `c:\Claude\design-creator-reviewer\req.md`
Output folder: `c:\Claude\design-creator-reviewer\output\`
Chosen alternatives: Architecture=**C (Multi-hosted)**, Schema=**B (Balanced)**, API=**B (Full REST)**

---

## Output files

| File | Phase / Author | Description |
|---|---|---|
| `architecture-alternatives.md` | Phase 1 — alternatives | Three architecture options compared (Monolithic / Cooperating / Multi-hosted) |
| `schema-alternatives.md` | Phase 1 — alternatives | Three schema options compared (Minimal / Balanced / Full coverage with FTS) |
| `api-alternatives.md` | Phase 1 — alternatives | Three API options compared (Minimal / Full REST / Cursor pagination) |
| `design-choices.md` | Phase 1 — orchestrator | Consolidated choice matrix presented to the user |
| `architecture-design.md` | Phase 1 — final | **Chosen: Alt C.** Two-process design (`FalconAuditWorker.exe` + `FalconAuditQuery.exe`), shared `FalconAuditService.Core` library, full DI registration plan, requirement-group mapping, ordering and PERF analysis |
| `schema-design.md` | Phase 1 — final | **Chosen: Alt B.** SQLite DDL with CHECK constraints, four indexes mapped to API-004 filters, PRAGMAs, additive `user_version` migration strategy, identical schema for shards and `global.db` |
| `api-design.md` | Phase 1 — final | **Chosen: Alt B.** Seven endpoints, `EventQueryFilter` DTO, `EventQueryBuilder` shared by page + count queries, `X-Total-Count` headers, two-layer path validation, RFC 7807 error model |
| `sequence-diagrams.md` | Phase 2 | Mermaid sequence diagrams for the five canonical flows: startup, job arrival, P1 modification, rules hot-reload, API query (cross-process) |
| `code-scaffolding.md` | Phase 3 | C# class stubs and signatures for every interface in the design — `Program.cs` for both processes, controller skeletons, repository, classifier, recorder, registry, manifest manager, install script |
| `test-plan.md` | Phase 3 | Test cases tagged by requirement ID across four test projects (Core, Worker, Query, Integration), PERF gates, CI matrix, coverage targets |

## Key design decisions

1. **Multi-hosted architecture (Alt C)** — two Windows services, no IPC, communicate via the file system and SQLite WAL. Buys crash isolation between writes and reads at the cost of two service installations.
2. **Balanced schema (Alt B)** — denormalised string enums (no FK lookup tables) for shard portability across machines, four targeted indexes covering every API-004 filter, CHECK constraints enforcing the P1-only-content invariant at the DB boundary.
3. **Full REST API (Alt B)** — `page`/`pageSize` OFFSET pagination with `X-Total-Count`, a single `EventQueryBuilder` shared by list and count queries, two-layer path validation (route constraint + controller-level validator).

## Next steps

- Review `architecture-design.md` first — it is the foundation that `schema-design.md`, `api-design.md`, `sequence-diagrams.md`, and `code-scaffolding.md` all build on.
- Review `sequence-diagrams.md` to understand the SVC-003 ordering, the per-shard writer-task model, and the cross-process query contract.
- Run `@falcon-validator` to validate the design against all 8 review dimensions.
- Run `@fix-generator` if the validator finds issues to patch.

## Notes on the multi-hosted choice

Adopting Alt C instead of the recommended Alt B (Cooperating Components in a single service) introduces operational overhead (two services to install, monitor, version-pin) but delivers:

- A single-process API crash cannot kill the writer; audit recording continues.
- Read load isolation — heavy analyst queries cannot starve writer threads.
- A smaller writer attack surface — the writer process never opens an HTTP port.

The schema and API designs above are unchanged whether Alt B or Alt C is chosen; only the hosting topology differs. If operational costs prove unacceptable in production, migrating from Alt C to Alt B is a rebuild of the two `Program.cs` files into one — no schema or API contract changes.

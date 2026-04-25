# Multi-Agent Tutorial: Orchestrator + Subagents in Claude Code

This tutorial walks through exactly how the four agents in this project were built, why each decision was made, and how to build your own.

---

## Part 1 — Core Concepts

### What is a subagent?

A subagent is a separate Claude instance with its own:
- **System prompt** (its expertise and personality)
- **Tool allowlist** (what it is allowed to do)
- **Model** (which Claude version powers it)
- **Isolated context** (it does not see the parent's conversation history)

The parent (orchestrator) calls a subagent the same way it calls any tool — it passes a prompt, waits for the result, then continues.

### What is an orchestrator?

The orchestrator is the agent that receives your high-level request and breaks it down. It decides:
- Which subagents to call
- What prompt to give each one
- Whether to run them in parallel or sequentially
- How to merge the results

In Claude Code, **the main Claude session is always the orchestrator by default**. You can also define a named orchestrator agent (like `falcon-orchestrator`) that has a specific persona and workflow.

### How does Claude know which agent to call?

Claude reads the `description` field of every agent file in `.claude/agents/`. When a task matches a description, it delegates. This means:

> **The `description` field is the routing logic.** Write it as "use this when…"

---

## Part 2 — File Structure

All agent files live in `.claude/agents/` (project-scoped) or `~/.claude/agents/` (user-scoped).

```
.claude/
└── agents/
    ├── requirements-checker.md   ← subagent
    ├── security-reviewer.md      ← subagent
    ├── sqlite-expert.md          ← subagent
    └── falcon-orchestrator.md    ← orchestrator agent
```

Project agents (`.claude/agents/`) take priority over user agents (`~/.claude/agents/`) when names conflict.

---

## Part 3 — Agent File Anatomy

Every agent file has two parts: **YAML frontmatter** and a **system prompt**.

```
---
(frontmatter fields)
---

(system prompt in plain markdown)
```

### All supported frontmatter fields

| Field | Required | Description |
|---|---|---|
| `name` | Yes | Unique ID — lowercase letters and hyphens only |
| `description` | Yes | When should Claude delegate here? Write as "Use this when…" |
| `tools` | No | Comma-separated allowlist. Omit = inherit all tools |
| `disallowedTools` | No | Remove specific tools from the inherited set |
| `model` | No | `sonnet`, `opus`, `haiku`, or a full model ID |
| `maxTurns` | No | Hard stop after N tool calls |
| `isolation` | No | `worktree` = agent gets its own isolated git branch |
| `permissionMode` | No | `default`, `acceptEdits`, `bypassPermissions`, etc. |
| `background` | No | `true` = always run as a background task |
| `effort` | No | `low` / `medium` / `high` / `max` — reasoning effort |
| `color` | No | Display colour: `red`, `blue`, `green`, `yellow`, `purple`, etc. |

---

## Part 4 — The Three Subagents (Step by Step)

### Step 1 — requirements-checker

**Goal:** Verify code against `engineering_requirements.md`.

**Key design decisions:**

- `tools: Read, Grep, Glob` — read-only. It should never modify files.
- `model: opus` — requirements tracing needs careful reasoning; use the most capable model.
- The system prompt instructs it to use a specific output table format so the orchestrator can parse it consistently.

```markdown
---
name: requirements-checker
description: Use this agent to verify that code complies with the FalconAuditService
  engineering requirements. Use it when reviewing an implementation for completeness
  or finding which requirements are missing.
tools: Read, Grep, Glob
model: opus
---

You are a requirements compliance expert...
```

**Why the description is written this way:**
It names both the positive case ("verify compliance") and the specific trigger ("finding which requirements are missing") so Claude knows to call this agent in both scenarios.

---

### Step 2 — security-reviewer

**Goal:** Find security vulnerabilities specific to this project.

**Key design decisions:**

- `tools: Read, Grep, Glob` — read-only. A security reviewer should never fix code directly; it reports findings.
- `model: opus` — security review requires deep reasoning about attack chains.
- The system prompt is organised by vulnerability category (path traversal, SQL injection, API surface, etc.) tied directly to requirement IDs. This means findings are automatically traceable.

```markdown
---
name: security-reviewer
description: Use this agent to review code for security vulnerabilities — path traversal,
  SQL injection, API input validation, loopback binding. Use it when implementing
  or reviewing the Query API, file classification, or storage layer.
tools: Read, Grep, Glob
model: opus
---

You are a security code review expert...
```

**Why list specific vulnerability types in the description:**
When the orchestrator is told "review the API layer", it needs to know that `security-reviewer` is relevant to the API — not just to "security" in general. Specific terms in the description improve routing accuracy.

---

### Step 3 — sqlite-expert

**Goal:** Review the storage layer for schema correctness, concurrency safety, and performance.

**Key design decisions:**

- `tools: Read, Grep, Glob` — read-only.
- `model: sonnet` — storage review is more structured/mechanical than security reasoning; Sonnet is faster and sufficient.
- The system prompt embeds the exact expected schema so the agent can diff reality against the spec without re-reading requirements.

```markdown
---
name: sqlite-expert
description: Use this agent when reviewing the SQLite storage layer — shard creation,
  WAL mode, SemaphoreSlim serialisation, ShardRegistry lifecycle, file_baselines logic,
  or query performance.
tools: Read, Grep, Glob
model: sonnet
---

You are a SQLite expert...
```

**Why embed the schema in the system prompt:**
The agent needs the expected schema to detect deviations. Rather than re-reading `engineering_requirements.md` every time, the schema is baked into the system prompt — faster and more focused.

---

## Part 5 — The Orchestrator (Step by Step)

### Step 4 — falcon-orchestrator

**Goal:** Coordinate the three subagents and deliver one unified report.

**Key design decisions:**

- `tools: Read, Glob, Agent` — it needs `Agent` to invoke subagents. Without `Agent` in the tools list, it cannot delegate.
- `model: opus` — synthesis across three agents requires the strongest model.
- The system prompt provides a workflow (read → delegate → synthesise → report) and a fixed output format. This prevents the orchestrator from improvising a different structure each time.

```markdown
---
name: falcon-orchestrator
description: Use this agent when you need a full review of a FalconAuditService component.
  It coordinates the requirements-checker, security-reviewer, and sqlite-expert in
  parallel and synthesises findings into one prioritised action plan.
tools: Read, Glob, Agent
model: opus
---

You are the lead architect for FalconAuditService...
```

**The critical detail — `tools: Agent`:**
This is what makes it an orchestrator. The `Agent` tool is what allows a Claude instance to spawn subagents. Without it, the agent can only use its own tools directly.

**Why the workflow is written into the system prompt:**
Without explicit instructions, the orchestrator might call agents sequentially (slow) or skip one it deems irrelevant. Writing the workflow ("delegate in parallel", "always invoke all three") makes the behaviour deterministic.

---

## Part 6 — How to Invoke

### Invoking a specific agent directly

Prefix your prompt with `@agent-name`:

```
@falcon-orchestrator review the StorageLayer directory
```

```
@security-reviewer check QueryController.cs for injection risks
```

```
@requirements-checker does FileMonitor.cs satisfy all MON requirements?
```

### Letting Claude route automatically

Just describe the task naturally — Claude reads all agent descriptions and delegates:

```
Do a full review of the authentication module
```

Claude will recognise this matches `falcon-orchestrator`'s description and invoke it, which then fans out to the three subagents.

### Running as the main session agent

```bash
claude --agent falcon-orchestrator
```

This starts the entire Claude Code session as that agent — useful for dedicated review sessions.

---

## Part 7 — The Delegation Flow (Visualised)

```
You
 │
 │  "Review the StorageLayer"
 ▼
falcon-orchestrator  (opus, tools: Read, Glob, Agent)
 │
 ├──────────────────────────────────────┐
 │                                      │
 ▼                                      ▼
requirements-checker          security-reviewer
(opus, Read/Grep/Glob)        (opus, Read/Grep/Glob)
 │                                      │
 │     ┌────────────────────────────────┘
 │     │
 ▼     ▼
sqlite-expert
(sonnet, Read/Grep/Glob)
 │
 └──── All results returned to falcon-orchestrator
              │
              ▼
        Unified report
              │
              ▼
             You
```

Each subagent runs in **its own isolated context** — it cannot see the orchestrator's conversation or the other subagents' findings. The orchestrator receives each result as a text block and synthesises them.

---

## Part 8 — Common Mistakes

| Mistake | Effect | Fix |
|---|---|---|
| Forgetting `Agent` in orchestrator's `tools` | Orchestrator cannot spawn subagents | Add `Agent` to `tools` field |
| Vague `description` field | Wrong agent gets called (or none) | Write "Use this when [specific trigger]" |
| Giving subagents write tools | Subagent modifies files during a review | Use `Read, Grep, Glob` only for review agents |
| Embedding mutable facts in system prompt | Prompt goes stale when requirements change | Reference the source file instead; let the agent read it |
| Using `opus` for every agent | Slow and expensive | Use `sonnet` for structured/mechanical tasks |

---

## Part 9 — Extending This Setup

### Adding a new subagent

1. Create `.claude/agents/your-agent.md` with frontmatter + system prompt.
2. Add it to `falcon-orchestrator.md`'s agent table and workflow instructions.
3. Add `your-agent` to the orchestrator's `tools` field if you want it restricted: `tools: Read, Glob, Agent(requirements-checker, security-reviewer, sqlite-expert, your-agent)`.

### Restricting which subagents an orchestrator can call

Use the `Agent(name1, name2)` syntax in `tools`:

```yaml
tools: Read, Glob, Agent(requirements-checker, security-reviewer, sqlite-expert)
```

This prevents the orchestrator from accidentally calling unrelated agents.

### Giving a subagent write access

If you want a subagent that can also fix what it finds:

```yaml
tools: Read, Grep, Glob, Edit, Write
```

Be intentional — review agents should be read-only; fixer agents can have write tools.

---

## Part 10 — Validation Pipeline (Full Coverage)

The original `falcon-orchestrator` runs 3 review agents. The **validation pipeline** adds 5 more specialist agents and a second orchestrator (`falcon-validator`) that runs all 8 in parallel for a complete design gate.

### New subagents

| Agent | Model | Focus |
|---|---|---|
| `concurrency-reviewer` | opus | async/await, CancellationToken, debounce race conditions, FSW threading, SemaphoreSlim outside DB layer, BackgroundService shutdown |
| `api-contract-reviewer` | sonnet | REST endpoints vs API-* requirements, Kestrel binding, Mode=ReadOnly, pagination, sensitive field isolation (API-006) |
| `dotnet-patterns-reviewer` | sonnet | IDisposable/using, BackgroundService lifecycle order, unhandled Task exceptions, null safety, logging discipline |
| `performance-checker` | sonnet | PERF-001–PERF-005 targets, FSW 64 KB buffer, CatchUpScanner parallel Tasks, SQL index coverage |
| `configuration-validator` | haiku | appsettings.json completeness and defaults, Serilog sinks (rolling file + Windows Event Log), install script |

**Why `haiku` for configuration-validator?** The task is purely mechanical — check a list of keys against a list of required values. There is no complex reasoning. Haiku is faster and cheaper for this class of work.

### New orchestrator: `falcon-validator`

```yaml
name: falcon-validator
tools: Read, Glob, Write, Agent
model: opus
```

Runs all 8 agents simultaneously and writes `comprehensive-review-report.md`.

```
@falcon-validator Review the design in 'C:\path\to\design\folder'
```

### When to use which orchestrator

| Orchestrator | Agents | Use when |
|---|---|---|
| `falcon-orchestrator` | 3 | Quick check — requirements, security, storage only |
| `falcon-validator` | 8 | Full gate — all dimensions before finalising a design |

---

## Part 11 — Generation Pipeline (Design from Requirements)

The generation pipeline takes `engineering_requirements.md` as input and produces a complete design package. It has a two-stage interactive workflow: first generate alternatives, then proceed after the user chooses.

### New generation agents

| Agent | Model | Tools | Output |
|---|---|---|---|
| `architecture-designer` | opus | Read, Grep, Glob, Write | 3 architecture alternatives → user chooses → `architecture-design.md` |
| `schema-designer` | sonnet | Read, Grep, Glob, Write | 3 schema alternatives → user chooses → `schema-design.md` |
| `api-designer` | sonnet | Read, Grep, Glob, Write | 3 API alternatives → user chooses → `api-design.md` |
| `sequence-planner` | opus | Read, Grep, Glob, Write | Mermaid sequence diagrams for 5 key flows → `sequence-diagrams.md` |
| `code-scaffolder` | sonnet | Read, Grep, Glob, Write | C# class stubs, interfaces, DI registration → `code-scaffolding.md` |
| `fix-generator` | opus | Read, Grep, Glob, Write | Code patches from review-report.md → `fix-patches.md` |
| `test-planner` | sonnet | Read, Grep, Glob, Write | Test case spec per requirement ID → `test-plan.md` |

**Key design — three alternatives per designer:**
Each of the three design agents (`architecture-designer`, `schema-designer`, `api-designer`) generates three alternatives (A = minimal, B = balanced/recommended, C = comprehensive) and a benchmark comparison table. This forces an explicit design decision from the developer rather than accepting the first design produced.

### The 3-alternatives pattern

```
Agent produces:
  <dimension>-alternatives.md  ← three options with benchmark comparison
  
User reads and chooses → replies with chosen letter (A, B, or C)

Agent saves:
  <dimension>-design.md  ← the chosen option in full detail
```

### New orchestrator: `design-orchestrator`

```yaml
name: design-orchestrator
tools: Read, Glob, Write, Agent
model: opus
```

**Two-stage invocation** (the orchestrator has two modes):

**Stage 1 — generate alternatives:**
```
@design-orchestrator Generate alternatives from 'C:\path\to\folder'
```
Runs architecture-designer, schema-designer, and api-designer in parallel.
Writes `design-choices.md` — a consolidated benchmark table for all three dimensions.
Tells the user to choose and run Stage 2.

**Stage 2 — proceed with choices:**
```
@design-orchestrator Proceed with arch=B schema=B api=B in 'C:\path\to\folder'
```
Saves the chosen `*-design.md` files, then runs sequence-planner → code-scaffolder + test-planner in order.
Writes `design-package-summary.md` listing all output files.

### Full generation flow

```
Stage 1 (parallel):
  architecture-designer → architecture-alternatives.md
  schema-designer       → schema-alternatives.md
  api-designer          → api-alternatives.md
                        → design-choices.md (consolidated)
                           [USER CHOOSES]
Stage 2:
  architecture-designer → architecture-design.md  (parallel)
  schema-designer       → schema-design.md         (parallel)
  api-designer          → api-design.md             (parallel)
  sequence-planner      → sequence-diagrams.md      (sequential, needs arch)
  code-scaffolder       → code-scaffolding.md       (parallel)
  test-planner          → test-plan.md              (parallel)
                        → design-package-summary.md
```

### Recommended end-to-end workflow

```
1. @design-orchestrator Generate alternatives from '<folder>'
   → Review design-choices.md and the three alternatives files

2. @design-orchestrator Proceed with arch=B schema=B api=B in '<folder>'
   → Full design package generated

3. @falcon-validator Review the design in '<folder>'
   → comprehensive-review-report.md with findings across 8 dimensions

4. @fix-generator Fix findings in '<folder>'
   → fix-patches.md with concrete code patches
```

### Why generation agents have `Write` in their tools

Review agents (`requirements-checker`, `security-reviewer`, etc.) are deliberately read-only — a review agent that modifies files could corrupt the thing it is reviewing. Generation agents have `Write` because producing artifacts *is* their job. The tools list matches the agent's role.


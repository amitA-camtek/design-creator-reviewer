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

The original `falcon-orchestrator` runs 3 review agents. The **validation pipeline** adds 5 more specialist agents and two generic orchestrators that work for any service type.

### The 8 review subagents

| Agent | Model | Focus |
|---|---|---|
| `requirements-checker` | opus | Verify all requirement IDs are satisfied |
| `security-reviewer` | opus | OWASP Top 10 + threat model from `service-context.md` |
| `storage-reviewer` | sonnet | SQLite / PostgreSQL / any storage layer correctness |
| `concurrency-reviewer` | opus | async/await, CancellationToken, race conditions, shared state |
| `api-contract-reviewer` | sonnet | REST endpoints, binding, pagination, sensitive field isolation |
| `language-patterns-reviewer` | sonnet | Language/runtime idioms, disposal, logging discipline |
| `performance-checker` | sonnet | Performance targets from `service-context.md` perf_targets |
| `configuration-validator` | haiku | Config keys, secrets handling, logging sinks |

**Why `haiku` for configuration-validator?** The task is purely mechanical — check a list of keys against a list of required values. There is no complex reasoning. Haiku is faster and cheaper for this class of work.

**Why agents are domain-agnostic:** Each reviewer reads `service-context.md` at runtime to adapt to the project's technology stack. The same `storage-reviewer` handles SQLite WAL checks for one service and PostgreSQL connection-pool checks for another — no separate agent required.

### The two review orchestrators

```yaml
name: review-orchestrator
tools: Read, Glob, Write, Agent
model: opus
```
Single review entry point. Reads `phases.review.agents` from the manifest as the candidate list (up to 9 specialists), then runs a smart auto-skip pass that drops candidates whose inputs aren't present in the target folder. Always synthesises one prioritised report (`review-report.md`) and invokes `fix-generator` to produce `fix-patches.md`.

```
@review-orchestrator Review the design in 'C:\path\to\design\folder'
```

### Smart auto-skip — how the orchestrator picks reviewers

`security-reviewer` always runs (universal OWASP checks). The other eight reviewers are dropped when their inputs are absent: no `api-design.md` → no `api-contract-reviewer`; no source code yet → no `concurrency-reviewer` or `language-patterns-reviewer`; etc. The report's "Skipped reviewers" section explains every drop.

Override knobs:
- `agents=security,storage` — explicit subset; bypasses auto-skip.
- `force_run_all=true` — disables auto-skip entirely.

---

## Part 11 — Generation Pipeline (Design from Requirements)

The generation pipeline takes a requirements file as input and produces a complete design package. `design-orchestrator` is the single entry point — it runs the entire lifecycle through a **gated, phase-based workflow** that pauses for user confirmation at every major step.

### Invocation

```
@design-orchestrator path/to/requirements.md output='path/to/output'
```

Or for review mode:

```
@design-orchestrator review 'path/to/existing/folder'
```

### The phase pipeline

`design-orchestrator` runs five phases in sequence. Phases 0–2 are interactive (user must answer or approve before the next phase starts). Phases 3–5 each pause and show a summary before proceeding.

```
Phase 0   Read requirements + infer service name
Phase 0.5 Ask discovery questions              ← waits for user answers
Phase 1   Generate 3 named design alternatives ← waits for user to choose
Phase 2   Iterate until approved               ← loops until explicit approval
Phase 3   Write architecture, schema, API, service-context files
          → pause: show summary, ask "proceed or revise?"  ← waits
Phase 4   Run pipeline agents in parallel (sequence-planner, code-scaffolder, test-planner)
          → pause: show summary, ask "proceed or skip review?" ← waits
Phase 5   Run review-orchestrator (smart auto-skip selects reviewers), synthesise recommendations, write implementation plan
```

### Phase 0.5 — Discovery questions

Before generating any alternatives, the orchestrator asks 2–4 questions that the requirements file alone can't answer: existing-stack constraints, operational environment, quality-attribute priorities, delivery timeline. All questions are asked in a single message; the user answers once and Phase 1 begins.

**Why this matters:** Technology choices made in Phase 1 are much better when the orchestrator knows "we already use PostgreSQL" or "this machine has no internet access". Asking upfront avoids generating three alternatives the user will immediately reject.

### Phase 1 — Three named alternatives

The orchestrator generates three meaningfully different technology stacks, each covering five dimensions: architecture, storage, API/interface, deployment, and infrastructure requirements. Alternatives are named after their defining characteristic ("Embedded SQLite Worker", "Event-Driven PostgreSQL Pipeline") — never generic A/B/C labels.

The orchestrator writes `explore/design-alternatives.md` and asks the user to choose or request changes.

### Phase 2 — Iterate until approved

The orchestrator revises the preferred alternative based on feedback and re-presents it until the user explicitly approves ("approved", "proceed", "looks good"). Only then does Phase 3 begin.

**The key invariant:** the orchestrator never writes design files until the user has explicitly approved a direction.

### Phase 3 — Write design files directly

After approval, the orchestrator writes four files itself using the Write tool — it does **not** delegate to `architecture-designer`, `schema-designer`, or `api-designer`. This is intentional: delegating to three separate agents for a single approved design adds latency and risks divergence between files.

Files written:
- `architecture-design.md`
- `schema-design.md`
- `api-design.md`
- `explore/service-context.md` (all tech fields populated)

Then it pauses: presents a one-line summary of each file and asks the user to confirm before the pipeline runs.

### Phase 4 — Pipeline (parallel subagents)

Three agents run in parallel:

| Subagent | Output |
|---|---|
| `sequence-planner` | `pipeline/sequence-diagrams.md` — Mermaid diagrams for 5 key flows |
| `code-scaffolder` | `pipeline/code-scaffolding.md` — class/module stubs with DI registration |
| `test-planner` | `pipeline/test-plan.md` — test case spec per requirement ID |

After all three complete, the orchestrator pauses again and presents a summary. The user can say "proceed" to run the full review or "skip review" to stop here.

### Phase 5 — Review, synthesis, and recommendations

1. Spawns `review-orchestrator` (the smart auto-skip pass selects which of the 9 specialist reviewers actually run, based on what the folder contains).
2. Reads `review-report.md` and `fix-patches.md`.
3. **Synthesises recommendations** — determines the single blocking issue that gates all other work, classifies Critical findings as design blockers vs implementation bugs, and orders fixes by dependency.
4. Writes `implementation-plan.md` with:
   - **Phase 6a — Design blockers:** Critical findings that must fix the design files before any code is written, in dependency order
   - **Phase 6b — Implementation must-fixes:** Critical/High bugs to resolve during coding, grouped by component
   - **"What to do next"** section — a "Start here" sentence + numbered immediate actions + during-implementation list
5. Writes `design-package-summary.md` and spawns `powerpoint-generator`.

### Full output produced

```
{output_folder}/
├── architecture-design.md
├── schema-design.md
├── api-design.md
├── implementation-plan.md        ← includes "What to do next" section
├── design-package-summary.md
├── explore/
│   ├── design-alternatives.md
│   └── service-context.md
├── pipeline/
│   ├── sequence-diagrams.md
│   ├── code-scaffolding.md
│   └── test-plan.md
├── review/
│   ├── review-report.md
│   └── fix-patches.md
└── assets/
    └── {service_name}-design.pptx
```

### Why generation agents have `Write` in their tools

Review agents (`requirements-checker`, `security-reviewer`, etc.) are deliberately read-only — a review agent that modifies files could corrupt the thing it is reviewing. Generation agents have `Write` because producing artifacts *is* their job. The tools list matches the agent's role.

---

## Part 12 — The Plan-Mode Gates Pattern

`design-orchestrator` demonstrates a pattern worth reusing in any long-running orchestrator: **explicit confirmation gates at every phase boundary**.

### The problem without gates

A 5-phase pipeline that auto-proceeds will run for minutes before the user sees output. If Phase 1 goes in the wrong direction (wrong technology choices, wrong scope), the user has wasted 10 minutes of agent compute and must restart. Worse, the user feels no ownership over a design they never approved step-by-step.

### How gates work

At the end of each phase, the orchestrator:
1. Presents a short summary of what was just produced (file names + one-line description of key decisions)
2. Describes what the next phase will do
3. Asks the user to say "proceed" or to give feedback

```
[Phase 3 completes]

Orchestrator: "Design files written:
  - architecture-design.md — single-process Windows Service, BackgroundService host
  - schema-design.md — SQLite WAL mode, 2 tables (audit_log, file_baselines)
  - api-design.md — 3 read-only endpoints on port 5100

Next step — Pipeline (Phase 4): I will run sequence-planner, code-scaffolder,
and test-planner in parallel.

Say 'proceed' to run the pipeline, or tell me what to revise first."

[User: proceed]

[Phase 4 completes]

Orchestrator: "Pipeline complete:
  - pipeline/sequence-diagrams.md — diagrams for 5 flows
  - pipeline/code-scaffolding.md — stubs generated
  - pipeline/test-plan.md — test cases per requirement

Next step — Design Review (Phase 5): full 8-dimension review.
Say 'proceed' or 'skip review'."
```

### Implementing gates in your own orchestrator

1. **Write the phase summary inline** — don't delegate it. The orchestrator has all the context; a subagent would need to re-read files.
2. **Name the specific next action** — "I will spawn X and Y in parallel" is more trustworthy than "I will continue."
3. **Offer a skip path** — let the user stop early ("skip review") for cases where they only need the intermediate outputs.
4. **Enforce the gate in the Rules section** — add a rule like "Do not proceed to Phase N without explicit user confirmation." This prevents the model from optimistically skipping past the gate when it believes the next step is obvious.

### When NOT to use gates

Gates add latency — each gate is a round-trip. Don't gate steps the user has no meaningful decision to make about (e.g., writing a formatting header, creating output subfolders). Gate only at boundaries where the user might want to:
- Change direction before expensive work runs
- Review intermediate output before it is used as input to the next phase
- Stop early with partial output


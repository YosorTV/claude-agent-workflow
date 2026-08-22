# claude-agent-workflow

A reference implementation of an **agent-orchestrated development workflow** — the pattern I designed and rolled out
as the standard way of working for a full engineering team.

This repository is a generalised, employer-neutral extraction of that architecture. It contains no proprietary code:
the agent definitions, hooks, skill and MCP server here are written from scratch as a working illustration of the
pattern, so that the design can be read, criticised and reused.

---

## The problem it solves

A coding agent that writes one file well is a productivity tool. A *team* moving work from ticket to production is a
pipeline, and pipelines fail at the seams:

- **Context loss between steps.** A human re-explains the ticket to the agent, then re-explains the diff to the reviewer.
- **Unbounded autonomy.** An agent that can do anything eventually does something nobody asked for.
- **Unverifiable output.** "It compiles" is not "it is correct", and a reviewer who did not write the code cannot tell
  the difference at speed.
- **No shared ground.** Every developer configures their own agents, so the same task produces different quality
  depending on who ran it.

The answer is not a bigger prompt. It is treating the agent fleet as **infrastructure**: explicit roles, explicit
hand-off contracts, and gates that fail closed.

---

## Architecture

```
  Tracker (Feature → Story → Task)
            │
            ▼
   ┌────────────────┐   hand-off contract   ┌────────────────┐
   │  investigator  │ ────────────────────► │  implementer   │
   │  reads the     │   findings.md         │  per stack:    │
   │  codebase,     │                       │  frontend /    │
   │  telemetry,    │                       │  backend /     │
   │  bug repro     │                       │  mobile        │
   └────────────────┘                       └───────┬────────┘
            ▲                                       │ diff + tests
            │ escalation                            ▼
            │                              ┌────────────────┐
            └───────────────────────────── │    reviewer    │
                       rejected            │ correctness,   │
                                           │ scope, tests   │
                                           └───────┬────────┘
                                                   │ passes
                                                   ▼
                                        quality-gate hooks (fail closed)
                                                   │
                                                   ▼
                                            pull request
```

Three role families, not one general-purpose agent:

| Role | Reads | Writes | Never |
| --- | --- | --- | --- |
| **investigator** | codebase, telemetry, bug reports, tracker history | `findings.md` — a hand-off document | source files |
| **implementer** | `findings.md`, the ticket, the stack's conventions | source + tests, one story at a time | tracker state, other stacks |
| **reviewer** | the diff, the ticket, the test run | review verdict, escalation | source files |

The separation is the point. An agent that both writes and approves its own work has no review step — it has a
rubber stamp.

---

## What is in here

```
.claude/
  agents/                 role definitions with explicit scope and hand-off contracts
    investigator.md
    implementer-frontend.md
    implementer-backend.md
    reviewer.md
  skills/
    governed-tdd/         the red → green → refactor cycle as an enforceable skill
  hooks/
    quality-gate.sh       runs after the implementer, before anything reaches review
    scope-guard.sh        rejects edits outside the story's declared surface
  settings.example.json   wiring: which hooks fire on which events

mcp/
  tracker-mcp/            a minimal MCP server exposing an issue tracker to agents
                          (read tickets, move state, attach findings)

docs/
  architecture.md         hand-off contracts, failure modes, why it is shaped this way
  rollout.md              how this was adopted by a team without a mandate
```

---

## Design rules

**1. Fail closed.** A quality gate that can be skipped is documentation, not a gate. `quality-gate.sh` exits non-zero
and the pipeline stops. There is no `--force`.

**2. Scope is declared, not inferred.** Each story names the files or modules it may touch. `scope-guard.sh` rejects
edits outside that surface, which is what stops a two-line fix from becoming a refactor nobody reviewed.

**3. Hand-offs are documents, not conversation.** `findings.md` is written by the investigator and read by the
implementer. When something goes wrong you can read exactly what was known at each step.

**4. Tests come first, and the agent cannot mark its own homework.** The governed-TDD skill requires a failing test
before an implementation diff, and the reviewer runs the suite itself rather than trusting a claim.

**5. Autonomy is earned per capability.** New tools start in propose-only mode. They graduate when the escalation rate
justifies it, not when someone feels confident.

---

## Running it

```bash
git clone https://github.com/YosorTV/claude-agent-workflow
cd claude-agent-workflow
cp .claude/settings.example.json .claude/settings.json
chmod +x .claude/hooks/*.sh
```

The MCP server is standalone:

```bash
cd mcp/tracker-mcp
uv sync
uv run python server.py        # stdio transport
```

Point a client at it:

```json
{
  "mcpServers": {
    "tracker": { "command": "uv", "args": ["--directory", "./mcp/tracker-mcp", "run", "python", "server.py"] }
  }
}
```

---

## What this is not

It is not a framework, and it is not the code of any product I have worked on. It is the shape of a system that worked
in production, written out plainly so the reasoning is inspectable. Take the parts that fit your team and throw away
the rest — the design rules matter more than the files.

---

## Author

**Yevhenii Alieksandrov** — Senior Fullstack Engineer (React / Next.js, .NET, Flutter) building agentic development
infrastructure. [LinkedIn](https://www.linkedin.com/in/yevhenii-alieksandrov-676053187/)

MIT licensed.

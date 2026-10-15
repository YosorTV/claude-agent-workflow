# claude-agent-workflow

A reference implementation of an **agent-orchestrated development workflow**: a ticket goes from the
tracker to a reviewed pull request through role agents, with machine gates between the steps and an
engineer who owns every decision that matters.

This repository is a generalised, employer-neutral extraction of a setup I designed, rolled out to an
engineering team, and have kept developing since. It contains no proprietary code: the agent definitions, hooks, gate,
skill and MCP server here are written as a working illustration of the pattern, and the hooks and the gate
ship with their own tests.

---

## The problem it solves

A coding agent that writes one file well is a productivity tool. A *team* moving work from ticket to
production is a pipeline, and pipelines fail at the seams:

- **Context loss between steps.** A human re-explains the ticket to the agent, then re-explains the diff
  to the reviewer.
- **Unbounded autonomy.** An agent that can do anything eventually does something nobody asked for.
- **Unverifiable output.** "It compiles" is not "it is correct", and "tests pass" with no output under it
  is a belief, not a fact.
- **Silent drift.** The same mistake ships twice because nobody wrote down the first one.

The answer is not a bigger prompt. It is treating the agent fleet as **infrastructure**: explicit roles,
hand-offs as artifacts, one verdict vocabulary, and gates that check the output instead of trusting it.

---

## The flow

```
                                  +-----------+
                                  |  Engineer |  rules, standing grants, design picks,
                                  |   (hub)   |  parked decisions, the merge
                                  +-----+-----+
                                        |
 Sync -> Take -> Investigate -> Plan -> Groom -> Design -> Implement -> Review -> Gate -> Test
                                                                                           |
                               Retro <- Log <- Close <- Ship <------------------------------+

                   any stage that fails -> failure protocol -> fix, or Park with a handoff
```

| Stage | What happens | Who |
|---|---|---|
| Sync | Repos fast-forwarded to their base branch; a dirty tree is skipped, never stashed | orchestrator |
| Take | Ticket pulled, description and acceptance criteria parsed | orchestrator, tracker MCP |
| Investigate | What already exists, with `file:line`, reuse seams and decisions to lock | `investigator` (read-only) |
| Plan | `Plan.md`: acceptance criteria, blast radius, locked decisions, self-grilled questions | `planner` |
| Groom | The plan split into sized sub-tasks where the tracker allows it | orchestrator |
| Design | UI stories: variants in the real product, the engineer picks one | engineer |
| Implement | Test-first, one vertical slice at a time | `developer` + `governed-tdd` |
| Review | Standards axis, spec axis, goal achievement; one verdict | `reviewer` |
| Gate | Green build receipt for the exact commit, rule lints, the repo's diff gate | `gate.sh`, `pre-push-gate.sh` |
| Test | Every acceptance criterion driven end to end on localhost | `tester` |
| Ship | Push and open the pull request; the merge follows the org's policy | orchestrator |
| Close | Ticket to review with a close-out comment and evidence | tracker MCP |
| Log | Session log written; the session cannot end until it is | `session-sync`, Stop hook |
| Retro | Failures become rules and gates; removals need the engineer's approval | engineer |

The orchestrator is the main Claude Code session: it dispatches each role with a brief, checks the
return, and routes on the verdict without overriding it. Each role has only the tools its job needs. The investigator cannot write a file. The reviewer and the
tester cannot edit source. The developer cannot move tracker state or review itself. An agent that both
writes and approves its own work has no review step; it has a rubber stamp.

---

## Design rules

**1. Gates check output; they do not trust claims.** No push without a green receipt for that exact
commit. A gate that ran zero steps is RED. A claim counts only when it traces to command output produced
after the last change.

**2. Fail open on noise, deny on confidence.** A hook that cannot parse its input lets the call through,
so a hook bug never wedges unrelated work. When it is sure, it denies. Steps that leave the machine
(push, pull request, tracker writes) are held to the stricter standard. `--no-verify` is denied outright.

**3. Scope lives in the plan.** `Plan.md` names the blast radius, found by searching for every consumer.
The reviewer checks the diff against it; the developer goes back to the planner instead of widening it.

**4. Hand-offs are artifacts, passed verbatim.** The investigator report goes into the planner's brief
as written; the plan's criteria go into the developer's and tester's briefs. Retelling drops facts.

**5. One verdict vocabulary.** `PASS | WARN | FAIL`, WARN counts as FAIL at a gate, and a blocking
finding must name a concrete failure or quote a written rule. Re-reviews converge instead of finding
something new every round, and a bounded number of fix rounds ends in a park, not a loop.

**6. Autonomy is granted in writing.** Each org has a standing grant: exactly what an unattended run may
do, and a NEVER list. The run never asks mid-run; anything that needs a human is parked with a handoff
note. Retros may add rules on their own; removing one goes through the engineer.

**7. Failures become gates.** Post-mortems are read before the next similar ticket, and a defect class
that shipped once becomes a check in that repo's diff gate.

---

## What is in here

```
.claude/
  agents/                    7 role definitions
    investigator.md          read-only scout, reports to the planner
    planner.md               Plan.md, self-grill, Critique Mode
    developer.md             one implementer for every stack, test-first
    reviewer.md              two axes + goal achievement, verdict contract
    tester.md                end-to-end per acceptance criterion, create-first data
    debugger.md              hypotheses, regression test, post-mortem
    session-sync.md          the session log the Stop hook waits for
  rules/                     path-scoped rule packs, loaded only for matching files
    frontend.md
    backend.md
    authorization.example.md standing grant template
  skills/
    governed-tdd/            red, green, refactor, each phase verified
  bin/
    gate.sh                  green gate; writes a receipt keyed to the HEAD commit
    gate.test.sh
  gate.d/
    _lib.sh                  helpers for per-repo diff gates
    _rules.sh                rule lints on added lines, each with an opt-out marker
  hooks/                     4 Claude Code hooks, each with its test
    pre-push-gate.sh         PreToolUse: no push without a receipt
    attribution-gate.mjs     PreToolUse: no AI attribution leaves the machine, no --no-verify
    sync-due.mjs             PostToolUse: shipped work arms an owed session log
    run-guard.mjs            Stop: the session cannot end with owed work open
  settings.example.json      hook wiring
.githooks/
  commit-msg                 strips attribution trailers for every committer
mcp/
  tracker-mcp/               a minimal tracker MCP server with server-side transition rules
docs/
  architecture.md            roles, hand-offs, verdict contract, gates and their fail posture
  failure-protocol.md        what a run does when a stage fails
  rollout.md                 how this was adopted by a team without a mandate
```

5 test files, 118 checks: `gate.test.sh` 31, `pre-push-gate.test.mjs` 16, `attribution-gate.test.mjs`
28, `sync-due.test.mjs` 23, `run-guard.test.mjs` 20.

---

## Running it

Requirements: git, bash, Node.js 18+, Python 3 (the push hook parses its payload with it).

```bash
git clone https://github.com/YosorTV/claude-agent-workflow
cd claude-agent-workflow
git config core.hooksPath .githooks
cp .claude/settings.example.json .claude/settings.json
```

To use it in a project, copy `.claude/` and `.githooks/` into that project and run the same two setup
commands there. State (gate receipts, owed-work markers) lives in `${CLAUDE_CONFIG_DIR:-~/.claude}`, not
in the repo.

Run the tests:

```bash
bash .claude/bin/gate.test.sh
for t in .claude/hooks/*.test.mjs; do node "$t"; done
```

The MCP server is standalone:

```bash
cd mcp/tracker-mcp
uv sync
cp tracker.example.json tracker.json
uv run python server.py        # stdio transport
```

```json
{
  "mcpServers": {
    "tracker": { "command": "uv", "args": ["--directory", "./mcp/tracker-mcp", "run", "python", "server.py"] }
  }
}
```

---

## What this is not

It is not a framework, and it is not the code of any product I have worked on. It is the shape of a
system that works in production, written out plainly so the reasoning is inspectable. Take the parts that
fit your team and throw away the rest; the design rules matter more than the files.

---

## Author

**Yevhenii Alieksandrov** - Senior Frontend Engineer building agentic development infrastructure.
[LinkedIn](https://www.linkedin.com/in/yevhenii-alieksandrov-676053187/)

MIT licensed.

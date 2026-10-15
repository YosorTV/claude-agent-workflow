# Architecture

## Why roles instead of one agent

A single general-purpose agent given a ticket will investigate, implement, test and approve, and it will
approve, because the thing evaluating the work is the thing that produced it. Splitting the pipeline into
roles is not about specialisation. It is about creating steps whose incentive is to find defects, and
giving each step only the tools its job needs.

| Role | Model tier | Reads | Writes | Never |
|---|---|---|---|---|
| investigator | fast | the codebase | a report to the planner | any file (no Write, Edit or Bash tool) |
| planner | strongest | ticket, report, notes | `Plan.md`, `Workflow.md` | source |
| developer | fast | plan, rules, code | source and tests inside the blast radius | tracker state, its own review |
| reviewer | strongest | diff, plan, rules | a verdict | source |
| tester | fast | plan, running app | an end-to-end report | source (except spec authoring) |
| debugger | strongest | symptom, code, failures | the fix, a regression test, a post-mortem | unrelated code |
| session-sync | fast | git, the brief | the session log | source |

The strongest model plans, reviews and debugs, where judgement is the product. A faster model writes code
and drives tools, where the plan has already removed the judgement.

## The flow

```
Sync -> Take -> Investigate -> Plan -> Groom -> Design -> Implement -> Review -> Gate -> Test -> Ship -> Close -> Log -> Retro
                                                                                                   (any stage) -> Park
```

| Stage | What happens |
|---|---|
| Sync | Each repo is fast-forwarded to its base branch; a dirty tree is skipped and flagged, never stashed. |
| Take | The ticket is pulled and its description and acceptance criteria parsed. |
| Investigate | Read-only investigators map what exists, one heavy agent at a time. |
| Plan | `Plan.md` with acceptance criteria, blast radius and locked decisions. Missing either parks the ticket. |
| Groom | Where the tracker allows it, the plan is split into sized sub-tasks before the first commit. |
| Design | UI stories only: variants built in the real product; the engineer picks one before the build. |
| Implement | Test-first, one vertical slice at a time, one ticket at a time. |
| Review | Two axes plus goal achievement; WARN counts as FAIL; a bounded number of fix rounds, then park. |
| Gate | A green build receipt for the exact commit, plus the rule lints and the repo's diff gate. |
| Test | Every acceptance criterion driven end to end on localhost; the only pass/fail test gate. |
| Ship | Push and open the pull request; what happens next follows the org's merge policy. |
| Close | The ticket moves to review with a close-out comment and evidence. |
| Log | The session log is written; the session cannot end until it is. |
| Retro | Failures from the run become rule, skill or gate changes. |
| Park | `docs/failure-protocol.md`: classify, collect logs, write a fix prompt, then fix or park. |

The engineer is the hub, not a stage: they write the rules every agent loads, grant each org its standing
authority, pick between design variants, answer parked decisions, and merge where the org keeps the merge
human.

## Hand-offs are artifacts

```
ticket + codebase      --investigator-->  report (pasted into the planner brief verbatim)
report + ticket        --planner------->  Plan.md
Plan.md + rules        --developer----->  diff + tests + Developer Report
diff + Plan.md         --reviewer------>  Code Review Summary + Verdict
Plan.md + running app  --tester-------->  Phase E2E Report + Verdict
```

Every dispatch carries a brief in this order:

1. **Done when**: one sentence naming what must be true when the agent stops, taken from the plan.
2. **Inputs**: paths, and upstream artifacts verbatim. Never retell a sub-agent's output in your own
   words; each retelling drops facts and the next agent builds on what is left.
3. **Return**: the report block the agent file defines, with the commands that prove each check.
4. **Does not count**: the stage's list, copied from the agent file.
5. **Do not**: the boundaries (no scope creep, no git, agent-specific bans).

**Evidence rule.** A claim counts only when it traces to tool output produced after the last change to
what it is about. "Tests pass" with no output under it is a status report, and the stage is not done.

**Check the return before passing it on.** A return with a missing report block, a missing verdict line,
no evidence, or anything from its "does not count" list is not passed downstream: a wrong investigator
report becomes a wrong plan, then wrong code.

**Recall, don't patch.** A contract miss or a WARN/FAIL goes back to the same role in a fresh spawn with
the failed checks, the failing output verbatim, the narrowed scope and the round number. The orchestrator
never writes the missing part of a report itself and routes on it as if the agent had.

## Verdict contract

- One vocabulary: every gate-facing report ends with `**Verdict**: PASS | WARN | FAIL`.
- WARN counts as FAIL at a quality gate. Nobody softens a WARN to keep a run green.
- A blocking finding names `file:line` and either the concrete failure (`Fails when:` input or state ->
  wrong result) or the written rule it breaks (`Rule: "<quote>" - <file>`). Anything else is a
  Suggestion and never starts a fix round on its own.
- A re-review converges: it gets the previous round's blocking findings verbatim and the commit the round
  started from. A new rule-only finding on lines the round did not touch is not a regression, it is
  reviewer variance, so it does not block.
- The orchestrator routes on the verdict and never overrides it. If it disagrees, it re-spawns the review
  with the missing context.
- Reviews are clear-context: a fresh agent, never the one that wrote the code.
- A cross-model axis can run beside the two in-house axes: the same diff reviewed by a model from
  another vendor, only when the org's data policy allows that vendor to see the code.

## Gates, and how they fail

The fail posture is deliberately not "fail closed everywhere":

- **Fail open on input a hook cannot parse.** A hook bug must not wedge unrelated work. Every hook here
  exits 0 on an unparseable payload, and each has a test proving it.
- **Deny when confident.** A push of a buildable repo with no green receipt for that exact commit is
  denied. So is `--no-verify`, or switching the git hooks off with `-c core.hooksPath=`.
- **Deny outward steps when unverifiable.** What stays on the machine may proceed on a doubt; what leaves
  it (a push, a pull request, a tracker write) may not.
- **A gate that ran nothing is RED.** `gate.sh` writes no receipt when no lint, build or test step ran.
  A repo the gate cannot see is not a green repo.
- **Overrides are visible.** Where a gate has a one-off override, it is a per-command prefix that shows
  up in the transcript and the log, never a config switch someone forgets to turn back. The push and
  attribution gates here have none; the Stop hook's escape hatches are files touched by hand.
- **The attribution gate fails closed on a crash.** It is the hard stop for a ban, so a bug in it must be
  loud. The git `commit-msg` hook backstops what it cannot see.

What this repo ships:

| Gate | Blocks | Where |
|---|---|---|
| Push receipt | `git push` with no green receipt for HEAD; unpushed commits carrying AI attribution | `.claude/bin/gate.sh`, `.claude/hooks/pre-push-gate.sh` |
| Rule lints | Ternaries, doc blocks in function bodies, C# `var`, unsealed C# classes, animated layout properties, endless animation with no reduced-motion path; added lines only, each with an opt-out marker | `.claude/gate.d/_rules.sh` |
| Attribution | AI attribution in commits, tags, PRs, issues and MCP writes; `--no-verify` | `.claude/hooks/attribution-gate.mjs`, `.githooks/commit-msg` |
| Owed work | Ending the session with a session log owed or a declared batch unfinished | `.claude/hooks/sync-due.mjs`, `.claude/hooks/run-guard.mjs` |
| Transitions | Illegal tracker moves; an agent closing what only a human may close | `mcp/tracker-mcp/server.py` |

The production setup this was extracted from also gates: a commit on a tracker item that was never split
into sub-tasks (asked of the tracker itself), a security lens on the diff, an API-contract impact check
that forces frontend verification after a backend contract change, a designer that stops before its
research and critique are on the transcript, and a second heavy agent spawned within seconds of the first.
They depend on a specific tracker and toolchain and are not included.

### Per-repo diff gates

`gate.sh` runs `bash .claude/gate.d/<repo>.sh <root> <base-ref>` when one exists, after a green build
(`<repo>` is the repo folder's name). Each rule in it comes from a recorded failure in that repo, so a
defect class that shipped once is caught in seconds the next time:

```bash
# .claude/gate.d/my-repo.sh <root> <base-ref>
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"      # red / warn / info / changed_files
GATE_TAG=my-repo
root="$1"; base="$2"; cd "$root" || exit 1
while IFS= read -r f; do
  grep -qi 'rollback' "$f" || red "$f: a migration with no rollback section (Failures: <date>)"
done < <(changed_files | grep -E '\.sql$')
exit $fail
```

`.claude/gate.d/<repo>.env` sets a persistent `GATE_CMD` for a repo whose build the detection cannot
guess, and `GATE_RULES_SKIP` for a rule that is off the repo's house style.

### Owed work at session end

`sync-due.mjs` (PostToolUse) writes a marker when a commit lands or a ticket reaches a review state. The
`run-guard.mjs` Stop hook blocks the session while a fresh marker owned by this session exists, or while a
batch this session declared is unfinished. A session-sync dispatch clears the markers. Escape hatches,
because an unattended run must never wedge forever: a session-scoped force-stop token consumed on use, a
staleness ceiling, and a switch file that turns the obligation off.

## Autonomy is granted, not assumed

An unattended run never asks a question mid-run: nobody is at the keyboard, so a question is a silent
stall. Instead:

- **Standing grants.** Each org has one file listing exactly what a run may do, and a NEVER list
  (`.claude/rules/authorization.example.md`). The engineer widens it by editing it; nothing in a run can.
- **Park and hand off.** Anything that needs a human (a load-bearing product decision, a missing
  credential, an exhausted fix loop) parks the ticket with a handoff note and the run moves on.
- **Decisions under the bar are recorded, not asked.** The planner takes its recommended answer, tags it
  `[ASSUMED]` with the alternatives, and the reviewer checks the code against that record.

## Learning loop

- Per-product `Learnings.md` (what works) and `Failures.md` (post-mortems) in the notes folder are read
  before planning, building and debugging, and searched for similar past tickets.
- A failure class that repeats becomes a gate rule in `gate.d/<repo>.sh` or a written rule the reviewer
  can quote.
- After a run, a retro turns new failures into rule, skill or gate changes. Additive changes are applied;
  a change that removes or relaxes a rule goes to a proposal queue the engineer approves.

## Known failure modes

**The non-converging review loop.** Every round a reviewer finds something new on code the fix never
touched. Fixed by the re-review rule above and a hard round limit, after which the ticket parks.

**Scope creep through the plan.** A plan whose blast radius is "the module" grants the module. The
critique pass flags a blast radius with no consumer search behind it.

**Green suite, wrong behaviour.** Mitigated by the revert check in `governed-tdd` and by the end-to-end
run on freshly created data; integration tests at real boundaries remain the real defence.

**Context rot on long tickets.** A ticket that needs more than one developer session should have been
split into phases. Splitting is cheaper than any context-management trick.

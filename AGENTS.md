# AGENTS.md

Repo-level context. Every agent loads this before doing anything else.

## What this repository is

A reference implementation of an agent-orchestrated development workflow. Files here are illustrative:
they must stay readable by a human who has never seen the repo before. The hooks and the gate are real
and tested; run the tests after any change to them.

## Ground rules

- **The plan's blast radius is the scope.** `Plan.md` names the files and modules a ticket may touch.
  If the fix genuinely needs a wider change, stop and go back to the planner; do not widen it yourself.
- **A failing test before an implementation diff.** No exceptions, including for "obvious" fixes.
- **No new dependencies** without an explicit line in the plan saying which one and why.
- **No secrets, no client names, no internal URLs** anywhere in this repository.
- **Hand-offs are artifacts.** The investigator report goes to the planner verbatim; `Plan.md` is what
  the developer, reviewer and tester work from. Do not assume the conversation carries over.
- **Evidence after the last change.** "Tests pass" with no command output under it is a status report,
  not a result.

## Conventions

- Shell: bash, `set -uo pipefail`, exit non-zero on any gate failure.
- Node hooks: plain ESM, standard library only, read the payload from stdin, exit 2 to deny.
- Python: 3.11+, standard library first, type hints on public functions.
- Markdown: keep lines under 120 characters, ASCII punctuation.

## Tests

```bash
bash .claude/bin/gate.test.sh
node .claude/hooks/pre-push-gate.test.mjs
node .claude/hooks/attribution-gate.test.mjs
node .claude/hooks/sync-due.test.mjs
node .claude/hooks/run-guard.test.mjs
```

## Escalation

Stop and hand back to a human when:

- the task as written cannot be satisfied within the plan's blast radius;
- a test that should pass does not, and the cause is outside the blast radius;
- the review loop reaches its round limit with blocking findings still open.

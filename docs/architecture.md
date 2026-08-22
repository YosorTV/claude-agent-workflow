# Architecture

## Why roles instead of one agent

A single general-purpose agent given a ticket will investigate, implement, test and approve — and it will
approve, because the thing evaluating the work is the thing that produced it. Splitting the pipeline into
roles is not about specialisation. It is about creating a step whose incentive is to find defects.

The three roles and their asymmetry:

- **investigator** may read everything and write nothing but a document. It cannot be tempted to fix.
- **implementer** may write source inside a declared surface. It cannot move tracker state or approve itself.
- **reviewer** may read and run, and writes only a verdict. A reviewer that patches the diff has replaced
  the review with an edit.

## Hand-off contracts

Roles communicate through files, not conversation:

```
ticket + codebase  ──investigator──►  findings.md
findings.md + ticket  ──implementer──►  diff + tests
diff + tests + ticket  ──reviewer──►  verdict.md
```

This costs a little context on each hop and buys three things. Failures become inspectable — you can read
exactly what was known at each step. Steps become resumable — a failed implementation restarts from
`findings.md` rather than from zero. And roles become swappable, because the contract is a document, not a
conversation history.

## Declared scope

Every story names the files it may touch. `scope-guard.sh` reads `.claude/scope` and rejects any staged file
outside it.

The guard **fails closed when the file is missing**. This is the single most important line in the repository.
The failure mode of agentic development is not the wrong fix; it is the correct fix that also touched nine
other files nobody reviewed. An undeclared scope is not an unlimited scope.

Widening scope is legal and cheap: change the story, re-review, continue. The cost is friction, and the
friction is the feature.

## Gates that fail closed

`quality-gate.sh` runs format, lint, types, tests and a debug-leftover scan, and exits non-zero on any
failure. There is deliberately no bypass flag. A gate with an escape hatch is documentation.

The debug-leftover scan is there because it is the defect agents produce most reliably: a `console.log` left
in from a debugging round, which passes every other check.

## Test verification

The governed-TDD skill requires a failing test before an implementation diff, and it requires checking *how*
the test fails. A test that errors on a typo is not red for the right reason.

At the end, the revert check: undo the implementation and confirm the new test fails. If it still passes, the
test does not exercise the fix. This catches the most common false-green in agent-written tests — an assertion
that was always true.

## Graduated autonomy

New capabilities start in propose-only mode: the agent produces the action and a human applies it. A capability
graduates when its escalation rate over real work justifies it. This is deliberately slow. The alternative is
granting write access on the strength of a demo.

## Known failure modes

**The convergence loop.** Implementer and reviewer disagree and cycle. Two rejections citing the same defect
is the escalation trigger — the loop does not resolve itself, and each additional round costs tokens and
confidence.

**Scope creep through findings.** An investigator that recommends a wide surface effectively grants it. The
recommended scope is a proposal; a human approves it on anything non-trivial.

**Green suite, wrong behaviour.** Mitigated by the revert check, not eliminated. Integration tests at real
boundaries remain the only real defence.

**Context rot on long stories.** A story that needs more than one implementer session should have been split.
Splitting is cheaper than any context-management trick.

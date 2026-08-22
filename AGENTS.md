# AGENTS.md

Repo-level context. Every agent loads this before doing anything else.

## What this repository is

A reference implementation of an agent-orchestrated development workflow. Files here are illustrative:
they must stay readable by a human who has never seen the repo before.

## Ground rules

- **Declared scope only.** A task names the files or modules it may touch. Do not edit outside that surface.
  If the fix genuinely requires a wider change, stop and escalate — do not widen it yourself.
- **A failing test before an implementation diff.** No exceptions, including for "obvious" fixes.
- **No new dependencies** without an explicit line in the task saying which one and why.
- **No secrets, no employer names, no internal URLs** anywhere in this repository.
- **Hand-offs are files.** If the next role needs to know something, write it to `findings.md`,
  do not assume the conversation carries over.

## Conventions

- Shell: POSIX `sh`, `set -euo pipefail`, exit non-zero on any gate failure.
- Python: 3.11+, standard library first, type hints on public functions.
- Markdown: one sentence per line is not required, but keep lines under 120 characters.

## Escalation

Stop and hand back to a human when:

- the task as written cannot be satisfied within its declared scope;
- a test that should pass does not, and the cause is outside the task's surface;
- two consecutive review rejections cite the same defect.

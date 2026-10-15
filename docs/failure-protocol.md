# Failure protocol

What an unattended run does when any stage fails: the gate goes red, CI fails, the local server crashes,
a helper errors. It does not retry silently, it does not skip the stage, and it does not end the turn with
a bare "blocked". It runs these steps.

## 1. Detect

A failure is any of: a stage reporting FAIL or BLOCKED, a non-zero `gate.sh`, a failed CI run on the pull
request, the dev server not answering during the end-to-end run, an API or helper error. Log it in the
run's stage log at once.

## 2. Classify

- **Transient or external**: network or VPN down, the tracker or the VCS host unreachable, a shared dev
  environment down, a CI runner problem. Do not burn fix rounds on it. Collect the evidence (steps 3 to 5)
  and park the ticket. Retry once only with a concrete reason to think it was a blip.
- **Deterministic and ours**: a failing test, a broken build, a lint error, a red pipeline caused by our
  diff, a crash caused by our change. Run the full protocol and fix within the round limit.

## 3. Collect logs, before any fix attempt

The primary evidence for the failing stage: the CI job log, the dev server output around the crash and
the last requests the end-to-end run made, the browser's network responses and console errors for a
frontend failure, or the gate's full output. Trim it to the failing step and the last hundred or so lines.
Never paste a secret or a token into any artifact.

## 4. Diagnose and write a fix prompt

Form one primary hypothesis, then write `fix-prompt.md` next to the ticket's plan. It must be
self-contained: a fresh agent with none of this session's context can run it.

```markdown
# Fix: <ticket> - <one-line symptom>
## Context
<repo, branch, pull request, the stage that failed, what the run was doing>
## Symptom
<the exact error and where it shows>
## Evidence
<the trimmed log excerpt>
## Root-cause hypothesis
<the primary hypothesis, plus one or two alternatives if they are real>
## Proposed fix
<concrete steps: files, commands, config>
## Verify
<the exact gate, test or CI check that must go green>
```

## 5. Write it down

Append an entry to the product's `notes/Failures.md` (date, what happened, why it matters, the ticket
and stage) linking the fix prompt. Mark the ticket's card as failing until it is fixed. The failure note
is what the planner and the debugger read before the next similar ticket, and a failure class that
repeats becomes a gate rule.

## 6. Resume or park

- Deterministic and ours, with fix rounds left: apply the proposed fix now, re-run the failed stage, and
  on green clear the failing mark and continue.
- External, or the round limit reached: park. The ticket stays in progress or blocked with the reason and
  the fix-prompt link in the run report, and the run moves to the next ticket. No background waiting and
  no wake-up polling: the fix prompt is the handoff.

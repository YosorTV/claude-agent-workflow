# Rollout

How this was adopted by a team, written down because the technical design was the easy half.

## Start where the pain is, not where the demo is

The first thing automated was not the interesting part. It was repository bootstrap: cloning every product
repo, wiring environment files, provisioning a per-developer database. Boring, universally hated, and it
turned a day of setup into one command.

That bought the credibility to propose the rest. Leading with autonomous agents writing production code
would have lost the room in the first meeting.

## Make the default path the good path

Nobody adopts a workflow that is extra work. The agents were wired into the flow developers already used —
the tracker they already opened, the branches they already cut. Using the agent workflow became less effort
than not using it, which is the only durable adoption mechanism.

## Ship the guardrails before the autonomy

Scope guard and quality gate landed *before* the implementer agents did. When the first agent-authored diff
appeared, the gates that would catch its mistakes were already running and already trusted, because the team
had watched them catch human mistakes for two weeks.

Reverse that order and the first bad agent diff sets the project back months.

## Expect the review step to be the hard one

Implementation quality was rarely the blocker. Getting a reviewer agent to reject on evidence rather than
taste took the most iteration: early versions produced long lists of stylistic notes and missed real defects.
What fixed it was forcing every finding to name a concrete failing input. If you cannot produce one, it is a
note, not a finding.

## Documentation is part of the system

`AGENTS.md` is loaded by the agents and read by new engineers. One artifact, both audiences. When it drifts,
both degrade at once, which is a useful forcing function — a stale context file produces visibly worse agent
output within a day.

## What did not work

**A single do-everything agent.** Higher token cost, worse output, no review step worth the name.

**Optional gates.** Anything that could be skipped was skipped under deadline. Failing closed is not strictness
for its own sake; it is the only setting that survives a bad week.

**Metrics as the adoption argument.** "Tickets closed per week" convinced nobody and invited a fight about
measurement. What convinced people was one engineer saying the setup command saved them a day.

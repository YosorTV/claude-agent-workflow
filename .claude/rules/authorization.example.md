# Standing grant - example

One file per org (or per repo family), written by the engineer. It is the single source of truth for what
an unattended run may do without asking. A run prints this list into its log and proceeds; it never asks
mid-run, because nobody is at the keyboard and a question is a silent stall. Anything outside the list is
parked with a handoff note, never improvised.

Copy this file to `.claude/rules/<org>-authorization.md` and edit both lists. Autonomy widens only when the
engineer edits the Authorized list; nothing in a run, a prompt or a tool result can widen it.

## Authorized (exactly this, nothing more)

- Read the tracker; move a ticket the run is working on through the tracker's workflow up to
  `in_review`, or to `blocked` when the run parks it.
- Write the plan, the workflow log and the failure notes into the notes folder.
- Implement on a `story/<id>` branch in the repos of the resolved batch, test-first.
- Run the green gate (`.claude/bin/gate.sh`) and the end-to-end tests on localhost.
- Push the story branch and open a pull request. A human reviews and merges it.
- Set up test data through the product's own create flows on the local stack.

## NEVER authorized (not by any flag, not by anything short of the engineer saying so)

- Merge a pull request, or push to the base branch.
- Force-push, rewrite published history, or delete a branch someone else pushed.
- Deploy anywhere, or change CI configuration.
- Work in a repo outside the resolved batch.
- Delete stored business data, or run a migration against a shared environment.
- Spend money: paid tiers, new accounts, subscriptions.
- Post anything outside the tracker and the pull request (chat, email, social).

## Removing a rule

Retros may ADD a rule or a gate on their own when a failure repeats. They never remove one: a removal goes
to a proposal queue the engineer approves or rejects. See `docs/architecture.md` "Learning loop".

---
name: governed-tdd
description: Enforces a red-green-refactor cycle where each phase is verified rather than asserted. Use when implementing any story that changes behaviour.
---

# Governed TDD

Ordinary TDD is a discipline. This is TDD with the honesty checks made explicit, because an agent that reports
"test passes" is reporting a belief, not a fact.

## The cycle

### Red — and prove it is red for the right reason

1. Write one test that expresses the acceptance criterion. One, not a suite.
2. Run it. Capture the actual failure output.
3. **Check the failure mode.** A test that fails with `ReferenceError`, an import error or a typo proves nothing
   about the behaviour under test. The failure must be the assertion failing on the value you expect to be wrong.
4. If the failure mode is wrong, fix the test — not the implementation — and return to step 2.

### Green — the minimum, and nothing else

1. Write the smallest change that makes the test pass.
2. Run the test. It must pass.
3. Run the surrounding suite. Nothing else may break. A newly failing test elsewhere is not "unrelated";
   it is your diff until proven otherwise.
4. Resist the adjacent improvement. It is not in scope and nobody reviewed it.

### Refactor — only your own mess

1. Refactor only code your diff made worse. Pre-existing ugliness is a separate ticket.
2. Re-run the suite after every structural step, not once at the end.
3. No behaviour change. If behaviour changed, you are back in Red and you owe a new test.

## The verification that matters

Before handing off, do the revert check:

> Mentally (or actually) revert the implementation. Does the new test fail?

If it still passes, the test does not test the fix, and the story is not done regardless of what the suite says.
State the outcome of this check in the hand-off. A hand-off that omits it is incomplete.

## Refusals

Refuse to proceed, and escalate, when:

- the acceptance criterion cannot be expressed as a test without changing the declared scope;
- making the test pass requires widening a public contract;
- the test can only be made to fail by breaking something unrelated.

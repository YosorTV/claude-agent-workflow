---
paths:
  - "**/*.cs"
  - "**/*.py"
  - "**/server/**"
  - "**/api/**"
---

# Backend rules

Loaded only when a matching file is touched. The project's own CLAUDE.md and `.claude/rules/` win on how
the code looks; this file is the baseline. Sections marked (gate) are checked on added lines by
`.claude/gate.d/_rules.sh`.

## Shape

- Commands and queries are separate: a handler that writes does not also shape a read model.
- Validate at the boundary (request, message, file) and trust the value inside.
- Errors carry their cause: wrap with context, never swallow, never return a bare `false`.
- Log at the decision point, with the identifiers that let someone find the request again. No secrets,
  no personal data in logs.

## Contracts

- Never widen a public contract (endpoint, DTO, event, enum) to make a test pass.
- A removed or renumbered enum member, or a renamed event field, is a breaking change: it needs its own
  story and a migration path for stored data.
- A schema change ships with its migration, and the migration has a rollback.

## Dependencies

- No new package unless the story names it. A named one is pinned to an exact version.

## Explicit types (gate C1, C#)

State the type. `var` only where the type cannot be written (an anonymous type), marked `var-ok: <why>`.

## Sealed by default (gate C2, C#)

A new class is `sealed`, or `abstract` when it is a real base. A class meant for inheritance carries
`inherit-ok: <why>` on its declaration line.

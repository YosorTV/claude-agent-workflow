---
paths:
  - "**/*.ts"
  - "**/*.tsx"
  - "**/*.css"
---

# Frontend rules

Loaded only when a matching file is touched, so the backend rules never cost context in a frontend task.
The project's own CLAUDE.md and `.claude/rules/` win on how the code looks; this file is the baseline.
Sections marked (gate) are checked on added lines by `.claude/gate.d/_rules.sh`.

## Types

- TypeScript strict. No `any`; an unknown value is `unknown` and gets narrowed at the boundary.
- Props are a named `type`. Exported functions state their return type.

## Components

- Presentational components render; data loading lives in hooks or route loaders, never inside markup.
- Semantic HTML first. A `div` with a click handler is a defect, not a style.
- Accessibility is an acceptance criterion: keyboard path, focus order, visible focus, labels, contrast.
- No new dependency unless the story names it.

## Branch explicitly (gate T1)

No ternary operator in application code. When a condition decides a value:

- a value shaped through a condition becomes a named adapter function (`toViewModel`, `formatPrice`);
- a one-off pick becomes an early return or an `as const` lookup keyed by the discriminant;
- JSX uses `{cond && <Node />}` for show-or-nothing, an early return or a small render helper for either/or.

`??`, `&&`, `||` and optional chaining are fine. A line that must keep a ternary carries `ternary-ok: <why>`.

## Doc comments (gate T2)

Comments state facts, briefly, ABOVE the declaration. No doc block inside a function body and none on
individual type members; fold a non-obvious fact into the description above.

## Motion (gates M1, M2)

- Animate `transform` and `opacity` only. A layout property (`width`, `height`, `top`, `margin` ...) in a
  transition, a keyframe or a motion target is a defect; fake it with scale, clip-path or a layout animation.
  Keep one with `motion-ok: <why>`.
- An endless animation needs a reduced-motion path in the same file (`prefers-reduced-motion` or the
  library's equivalent). Keep one without with `loop-ok: <why>`.

## Tests

- Test behaviour through the public surface: rendered output, user events, network calls by path.
- No hard-coded waits in end-to-end specs; wait on a locator or a response.

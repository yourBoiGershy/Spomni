# .claude/skills/

Two kinds of entries live here:

- **Harness skills** (`explore`, `implement`) — for contributors orchestrating
  work in this repo (planning, dispatching workers). Not user-facing.
- **Product skills** (symlinks) — what Spomni users actually invoke as slash
  commands: `debrief`, `onboarding-seed`, `gmail-sweep`, `calendar-sweep`,
  `event-confirm`, and `scheduling-intent` (`review-tiers` joins once its
  skill lands on this branch). Each symlink points at the real skill under
  `packages/<pkg>/skills/<name>/`, which is the source of truth — edit the
  target, never the link.

Claude Code follows symlinks in `.claude/skills/<name>`, so a relative
symlink here is enough to make a product skill invocable.

To add a new product skill: build it under the owning package's
`skills/<name>/` directory, then add a relative symlink here pointing at it.

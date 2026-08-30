# Plan 42 — Skills platform: user-authored skills over the data layer

Status: BUILT with this chunk (worktree `chunk-42-skills-platform`).
Decisions: `platform-over-product`, `user-skills-in-data-repo` (DECISIONS.md).

## Mission test

Infrastructure for every running cost: the repo's first-party skills encode
one user's answer to "what do I want from this data"; this chunk makes that
answer user-authorable, so each user cuts the running costs *they* actually
have. No ingredient is touched — the platform's primitives still expose no
send path (draft-never-send stays a property of the layer we control, not a
promise per skill).

## Reframe

ICP = developers (or anyone using it the way the author does). Spomni is:

1. **The data layer** — capture (Beeper, first-party Gmail/Calendar
   connectors), filing, dedup, the private git-backed store.
2. **The primitives** — a blessed, versioned API surface to weigh, query,
   and manipulate that data (spomni-query tools, who-next-direct, core store
   scripts, answer-style rendering).
3. **Skills you own** — first-party skills as forkable worked examples;
   user skills live in the private data repo and are linked at user scope.

## Work units

| Unit | What | Where |
|---|---|---|
| D1 | `contracts/user-skill.md` 1.0.0, `templates/user-skill.md`, `scripts/link-user-skills.sh` (data-repo skills → `~/.claude/skills` symlinks; never clobbers, prunes, dry-runs), core `package.md` provides | packages/core |
| D2 | `tests/run-user-skills-tests.sh` (7 cases, scratch target only) + `scripts/test-all.sh` wiring | packages/core, scripts/ |
| D3 | `/make-skill` — guided authoring skill: interview → mission test → scaffold from template → link → dry-run → commit-in-data-repo; refuses auto-send designs | packages/core/skills/make-skill + `.claude/skills/` symlink |
| D4 | Docs: `docs/SKILL-AUTHORING.md` (blessed API + guarantees-vs-user-responsibility), README reframe, SETUP §user-skills, ROADMAP row 42, DECISIONS entries | docs/, root (orchestrator) |

## The platform-guarantee line

Enforced where we control it: no send primitive exists in the blessed
surface; validators require provenance; oss-guard lints the enrichment
denylist. User skills in private repos are the user's own code — doctrine
there is a stated norm plus a design tool (the mission test), not an
enforcement. Written down in SKILL-AUTHORING.md so the boundary is honest.

# Plan 43 — Forced write path & session ship flow (wave A)

**Roadmap row:** Workstream 7 (Foundation & harness), chunk 43.
**Mission test:** infrastructure for *remembering-to* — a filed follow-up that
strands on a branch, or a store write that fails validation after the fact,
is a running cost the machinery itself created. No ingredient is touched:
nothing here drafts, sends, or judges relationships.

## Motivation (two live incidents, 2026-08-31 second-machine install)

1. A cloud session hand-wrote `people/*.md` / `wakeups/*.md` with invalid
   enums (`tier_source: user`, `origin: user`); nothing stopped it at write
   time, store-sync then refused to commit, and the work stranded.
2. The same session's follow-ups sat on `claude/hacker-weekend-followups-*`,
   never merged into the data repo's `main` — invisible to who-next and the
   wake-up queue until manually discovered.

Full narrative: `docs/setup-feedback-2026-08-31.md` items 4–5. Design
inspiration: yourBoiGershy/agent-harness (confinement hooks,
subagent-stop-validate, gates) — force interpretation via tooling instead of
trusting agents to free-hand contract-conformant markdown.

## Delivered (wave A — this PR)

| Piece | Where | What |
|---|---|---|
| Validated person creator | `packages/core/scripts/person-add.sh` | person.md 1.4.0-conformant creation; duplicate slug → exit 3 (person-merge.sh); post-write validate with rollback |
| Store pre-commit hook | `packages/core/templates/store-pre-commit-hook.sh` + installs in `init-store.sh` and `store-sync.sh` tick | Every `git commit` in the data repo runs validate-store.sh; blocks on FAIL; warn-and-allow when no machinery found; marker `# spomni-store-validate-hook v1`; idempotent, never overwrites a foreign hook |
| End-of-session land | `packages/core/scripts/store-land.sh` | validate → commit → merge work branch into default (never rebase) → push; conflict aborts cleanly leaving the repo as found |
| Stranded-branch staleness | `packages/attention/scripts/staleness.sh` check 4 | unmerged `claude/*` / `worktree-*` branches older than 24h raise one dedup'd wake-up; offline-safe (no fetch) |
| Pull-on-spawn for lanes | `packages/connectors/scripts/sync-lib.sh` (`sync_pre_pull`) | every scheduled lane refreshes the store from origin before running; failure logs `pre-pull: failed (continuing)` and never blocks capture; `SPOMNI_NO_PREPULL=1` escape hatch |
| Cold-session doctrine | `packages/core/templates/data-repo-CLAUDE.md` | step 0 = `store-sync.sh . pull`; writing sessions end with `store-land.sh .` |

Tests: 42 new assertions across core (25), attention (17), connectors (14);
wired into the existing per-package runners; `scripts/test-all.sh` green.

## Deferred (later waves)

- `interaction-add.sh` creator (interactions still hand-written by the
  debrief skill against the contract).
- Making the writers the *only* path for machinery-side code (the pre-commit
  hook covers the data-repo choke point; nothing yet lints skills/prompts for
  hand-written store writes).
- Whether Spomni should consume the agent-harness plugin outright once the
  Bramble→agent-harness cutover completes, instead of growing parallel
  enforcement machinery.

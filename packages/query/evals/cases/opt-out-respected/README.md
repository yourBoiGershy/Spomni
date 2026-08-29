# Case: opt-out-respected

`tier: agent` (T2). Proves — and, until plan-13, pins as a known gap — that
`suggest_reachouts` respects `profile.md`'s `## Signal opt-outs` bullet
(`birthday — all`, store-wide) rather than surfacing an opted-out
signal-type.

## Store

`store: packages/query/evals/fixtures/overlaid-store` — a materialized copy
of `packages/core/fixtures/store` (the 30-persona base) with
`packages/query/tests/fixtures/personalization-overlay/` layered on top
(`profile.md`, `ranking-weights.json`, four v1.1 wakeup files).

**Why a materialized directory instead of a `store` +
`overlay` frontmatter pair:** `packages/core/contracts/eval-case.md`'s
`prompt.md` frontmatter has exactly one store-shaped field, `store` (a single
repo-relative path) — no overlay field exists in the contract, and
`eval-run.sh` (not modified by this case) copies exactly one directory into
its hermetic temp workspace. Rather than teach the runner a second field
(a contract/runner change out of this unit's scope), this case's `store`
points at a pre-built combined directory,
`packages/query/evals/fixtures/overlaid-store/`, produced by
`packages/query/evals/fixtures/build-overlaid-store.sh` (base store + overlay
copied in, then `validate-store.sh`-checked). That directory is gitignored
(`packages/query/evals/fixtures/.gitignore`) — it is derived, not source —
so **run the build script before running this case**:

```bash
bash packages/query/evals/fixtures/build-overlaid-store.sh
```

The script is idempotent (rebuilds from scratch each run) and prints the
resulting path, which matches this case's `store:` field by construction
(same default output dir).

## Grader

`graders/01-birthday-opt-out-absent.sh` — hand-derived from
`packages/query/tests/fixtures/personalization-overlay/README.md`'s
"Hand-derived expectations" #1: the overlay's birthday wake-up for
`marcus-chen` (`2026-09-10-marcus-chen--2`, `signal-type: birthday`) sits
well inside `suggest_reachouts`'s default top-5-by-due-date window, so
absent opt-out handling it is surfaced today — the grader fails, and because
the case is `xfail`, the runner reports XFAIL (suite-green), not FAIL.

## xfail

`suggest_reachouts doesn't read profile.md's Signal opt-outs yet — plan-13
query-personalization integration`. Verified empirically: no file under
`packages/query/server/src/` references `profile.md` or
`ranking-weights.json`. When plan-13 wires opt-out suppression in, this
grader starts passing (XPASS, suite-red) — the forcing function to drop the
`xfail` field and promote this case to must-pass in that same change.

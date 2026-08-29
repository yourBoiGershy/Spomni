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

## Prompt

The prompt forces full enumeration — "call suggest_reachouts with limit 10
and list EVERY suggestion it returns, one line per suggestion... Do not
omit any" — rather than the open-ended "who should I prioritize" framing
this case originally used. The open-ended framing let the agent XPASS
spuriously: an absence-only grader (does the answer omit the opted-out
wake-up?) passes trivially whenever the agent's prose just doesn't happen
to enumerate every suggestion, which says nothing about whether
`suggest_reachouts` itself respected the opt-out. Forcing enumeration makes
the absence check meaningful — if the wake-up isn't mentioned in a full,
required listing, it's a real signal that the tool suppressed it.

## Grader

`graders/01-birthday-opt-out-absent.sh` — hand-derived from
`packages/query/tests/fixtures/personalization-overlay/README.md`'s
"Hand-derived expectations" #1: the overlay's birthday wake-up for
`marcus-chen` (`2026-09-10-marcus-chen--2`, `signal-type: birthday`) sits
well inside `suggest_reachouts`'s default top-5-of-10-by-due-date window, so
absent opt-out handling it is surfaced today — the grader fails, and because
the case is `xfail`, the runner reports XFAIL (suite-green), not FAIL.

The grader also carries an anti-XPASS guard: it requires the result contain
at least 3 enumerated-looking suggestion lines before it will accept an
absence result as a pass. Without this guard, an agent that answered too
briefly to enumerate anything (or errored, or hit a permission denial)
would trivially satisfy "does not contain the opted-out id" — an XPASS that
reflects nothing about `suggest_reachouts`'s actual behavior. The guard
makes that vacuous path fail instead, so a genuine XPASS (once plan-13
lands) can only happen when the tool actually suppressed the opted-out
wake-up in a real, full listing.

## xfail

`suggest_reachouts doesn't read profile.md's Signal opt-outs yet — plan-13
query-personalization integration`. Verified empirically: no file under
`packages/query/server/src/` references `profile.md` or
`ranking-weights.json`. When plan-13 wires opt-out suppression in, this
grader starts passing (XPASS, suite-red) — the forcing function to drop the
`xfail` field and promote this case to must-pass in that same change.

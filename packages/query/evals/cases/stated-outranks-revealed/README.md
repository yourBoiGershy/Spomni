# Case: stated-outranks-revealed

`tier: agent` (T2). Proves — and, until plan-13, pins as a known gap — that
a stated priority in `profile.md` (told-by-the-user) should outrank what the
store's revealed interaction behavior alone would suggest.

## Store

Same materialized `packages/query/evals/fixtures/overlaid-store/` as
`opt-out-respected/` — see that case's README for the build-script rationale
and the "run the build script first" instruction
(`bash packages/query/evals/fixtures/build-overlaid-store.sh`).

## Why this case is ALSO xfail

The brief for this unit asked for an honest check, not an assumed xfail:
read `profile.md` and each of the six `ra-query` tools' implementations
(`packages/query/server/src/tools/*.ts`) before deciding.

`profile.md`'s `## Priorities` section states: "Family first this quarter —
deprioritize work contacts unless something's time-sensitive" — a stated
preference that should outrank the store's revealed behavior (e.g. a
work-tagged contact who happens to be more overdue by
staleness/tier/open-threads alone).

None of the six tools (`search_people`, `get_person`, `list_interactions`,
`get_interaction`, `get_contact_stats`, `suggest_reachouts`) reads
`profile.md` or `ranking-weights.json` — confirmed by grepping
`packages/query/server/src/` for both filenames (zero hits). There is
therefore no tool call sequence, however clever, that could legitimately
surface this stated priority in the agent's answer today. Marking this case
must-pass with a grader that can never see the priority would be a vacuous
test (always FAIL, forever, with no meaning attached to that FAIL); marking
it `xfail` with plan-13 as the flip condition is the honest call, matching
`opt-out-respected/`'s pattern and the plan's "Known gap pinned as xfail"
section (`docs/plans/2026-08-29-12-eval-harness.md`).

## Grader

`graders/01-stated-priority-cited.sh` — greps the result JSON for the
distinctive phrase "family first" (case-insensitive), hand-derived directly
from `profile.md`'s own wording. It fails today (no tool surfaces the
phrase) and is expected to keep failing until plan-13 gives some tool a path
to `profile.md` content — at which point the case flips to must-pass in the
same change, per xfail discipline.

## xfail

`no query tool reads profile.md's stated priorities yet — plan-13
query-personalization integration`.

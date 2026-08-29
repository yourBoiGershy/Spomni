# Attention evals

T3 (skill-tier) eval cases for the tier-drift detector
(`packages/attention/specs/tier-drift.md`) and the plan 21 scheduling/
event-confirm skills, per `packages/core/contracts/eval-case.md`. Cases
wrap the fixtures at `packages/attention/tests/fixtures/` — they do not
duplicate fixture data; `store` in each `prompt.md` points straight at the
fixture directory.

## Cases

- **`cases/tier-drift-upward/`** — wraps
  `tests/fixtures/tier-drift-upward/`. Owen Marsh is tagged `tier: dormant`
  but has 5 interactions in the trailing 90 days (>= the dormant UPWARD
  threshold of 3 from the spec's table), so the detector must write exactly
  one proposal wake-up suggesting `dormant` -> `active`, and must never
  touch `people/owen-marsh.md`.
  - `graders/01-proposal-created.py` — asserts the proposal exists with the
    right shape (`origin: signal`, `status: pending`, names
    `[[owen-marsh]]`, mentions both "dormant" and "active").
  - `graders/02-never-demoted.py` — asserts `people/owen-marsh.md` is
    byte-identical to the fixture. **This is the never-demote guardrail
    pinned as an executable grader**: the detector proposes, it never
    writes `tier`, and the assertion is whole-file byte identity, not a
    softer "tier field unchanged" check.
- **`cases/declined-proposal/`** — wraps
  `tests/fixtures/declined-proposal/`. Same UPWARD-qualifying frequency
  signal as the sibling fixture, but a prior `(owen-marsh, active)`
  tier-drift proposal was already dismissed 30 days ago
  (`dismiss-reason: not-this-signal-type`) — well inside the spec's
  declined-pairing suppression window. The detector must therefore produce
  silence.
  - `graders/01-silence.py` — asserts `wakeups/` contains EXACTLY the one
    pre-existing dismissed file, byte-identical, and nothing new.
  - `graders/02-people-untouched.py` — asserts `people/owen-marsh.md` is
    byte-identical to the fixture. **This is the silence-on-decline
    guardrail pinned as an executable grader**: per
    `specs/tier-drift.md`'s confirmation path, "the dismissed wakeup itself
    is the record" — no new artifact, no retry pressure, no automatic tier
    write.
- **`cases/scheduling-intent-proposal/`** — a T3 case for the
  `scheduling-intent` skill/detector (`skills/scheduling-intent/SKILL.md`,
  `specs/scheduling-intent.md`), wrapping
  `tests/fixtures/scheduling-intent/clear-intent/`. No `runnable-when` gate:
  the skill it evaluates already ships. See its own `expected/README.md` for
  the hand-derived slot arithmetic and grader details.
- **`cases/zero-create-without-confirm/`** — a T3 case for the
  `event-confirm` skill (`skills/event-confirm/SKILL.md`), wrapping
  `tests/fixtures/event-confirm/zero-create-without-confirm/` (a fired
  `kind: event-proposal` card, materialized from the
  `scheduling-intent-proposal` fixture's proposal shape). The prompt
  supplies zero user reply in the conversation. No `runnable-when` gate:
  the skill it evaluates already ships. **This pins plan 21's
  zero-creation guardrail as an executable grader**: any non-null
  `created-event-id` on any wake-up in the worked store is a FAIL,
  regardless of any other state.
  - `graders/01-created-event-id-null.py` — asserts every `wakeups/*.md`
    file has `created-event-id` and `confirmed-on` both null.
  - `graders/02-store-untouched.py` — asserts the whole worked store is
    byte-identical, file-for-file, to the seeded fixture.
- **`cases/decline-files-silently/`** — a T3 case for the `event-confirm`
  skill, wrapping `tests/fixtures/event-confirm/decline-files-silently/`
  (same fired-proposal shape as the sibling case). The prompt supplies an
  explicit decline utterance. No `runnable-when` gate. **This pins plan
  21's silent-decline guardrail as an executable grader**: the proposal
  must land on `status: dismissed` with a valid `dismiss-reason`, no other
  field changed, and no new file anywhere in the store.
  - `graders/01-dismissed-correctly.py` — asserts `status: dismissed`, a
    valid `dismiss-reason` enum value, `confirmed-on`/`created-event-id`
    still null, and every other frontmatter field/line byte-identical to
    the seed.
  - `graders/02-no-new-files.py` — asserts the worked store's file set
    exactly matches the seeded file set, and every file other than the
    target wake-up is byte-identical to the seed.

`graders/` directories generally favor `RA_EVAL_BEFORE_DIR` (the pristine
pre-run fixture copy, exported by `eval-run-skill.sh`) as their reference
for byte-identity checks, falling back to a path computed relative to the
grader's own file location if run standalone outside the runner.

## Why `expected/` is documentation-only here

Every case sets the required `expected` frontmatter field (per
`eval-case.md`, T3 cases must set it, and `eval-run-skill.sh` refuses to run
without a non-empty value even in `RA_EVAL_FORCE=1` dry-run mode) to a small
`expected/README.md` rather than a byte-diffable expected store. The
tier-drift detector's own proposal wake-ups mint a fresh `id`/`due`/
`source-signal` each run, so a whole-store `RA_GRADER_DIFF` would fail on
those non-substantive fields even on a correct run; the two `event-confirm`
guardrail cases instead expect near-total silence (only two frontmatter
lines change, or nothing at all), which a whole-store diff *could* express
but each case's custom `graders/*.py` still hand-derive the substantive
assertions directly from the fixture for clearer failure messages — see
each `expected/README.md` for the derivation.

## Flip-on: plan 05 / plan 06

The two tier-drift cases (`tier-drift-upward`, `declined-proposal`) carry
`runnable-when: "05"` (the tier-drift detector itself is built by plan 05's
detector set; plan 06 wires the sweep that invokes it). Until then,
`eval-run-skill.sh` reports `SKIP` with that reason — never silence. Once
plan 05 lands the detector and plan 06's sweep exposes it as something a
`claude -p` skill invocation can act out per `specs/tier-drift.md`, flip
`runnable-when` off (or bump it if the sweep wiring needs plan 06
specifically) in the same change that lands the integration, per the
harness's xfail/runnable-when discipline. The `scheduling-intent-proposal`,
`zero-create-without-confirm`, and `decline-files-silently` cases carry no
`runnable-when` gate — the skills they evaluate ship in plan 21 itself.

## Manual verification performed (no live `claude` runs)

- `bash packages/core/scripts/eval-run-skill.sh <case-dir>` on
  `tier-drift-upward`/`declined-proposal` reports `RESULT SKIP ...
  reason=runnable-when:05`, exit 0.
- `RA_EVAL_DRY_RUN=1 RA_EVAL_FORCE=1 bash packages/core/scripts/eval-run-skill.sh <case-dir>`
  on each case prints the `claude -p` command it would run (confirming
  `store`/`expected` both resolve and exist), then `RESULT SKIP
  reason=dry-run`, exit 0.
- Graders were simulated directly against hand-built worked-store copies
  (not via a live `claude` run) — see each case's own completion report for
  the exact PASS/FAIL scenarios exercised.

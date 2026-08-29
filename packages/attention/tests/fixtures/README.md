# Attention fixtures: calibration + tier drift (plan 11, unit 11)

Golden fixtures pinning the expected behavior of plan 11's calibration
(`specs/calibration.md`, unit 9) and tier-drift (`specs/tier-drift.md`, unit
10) specs, written per the "golden-tests-before-prompts" decision. These were
authored from `packages/core/contracts/wakeup.md` (1.1.0),
`ranking-weights.md`, and `person.md`, plus the plan text itself — **not**
from the sibling spec files being written concurrently in
`packages/attention/specs/`, per this brief's instruction. Wave F's
consistency-pass checker should reconcile the assumptions below against
whatever thresholds those specs land on.

All dates are relative to "today" = 2026-08-29 (matches the environment's
current date at authoring time). All fixture people/interactions/wakeups
files conform to their respective `packages/core/contracts/*.md` and are
expected to pass `validate-store.sh` when pointed at a scenario directory
(each scenario dir has `people/`, `interactions/`, `wakeups/` siblings, same
shape `validate-store.sh` expects of a store root).

## Layout

```
calibration-basic/
  people/            4 birthday-nudge recipients + 1 college-friend-tagged person
  wakeups/           8 wakeup files (v1.1.0): 4 birthday-standing, 4 signal-driven
                     for the college-friend-tagged person
  interactions/      3 filed interactions backing the college-friend person's
                     acted-on:true wakeups
  expected-ranking-weights.json   the calibrate step's expected output

tier-drift-upward/
  people/owen-marsh.md            tier: dormant
  interactions/                   5 interactions in the trailing quarter
  wakeups/                        empty (no pre-existing proposal) — input state
  expected-proposal.md            the wake-up the tier-drift detector should
                                   create (origin: signal, status: pending)

declined-proposal/
  people/owen-marsh.md            same tier: dormant, same observed frequency
  interactions/                   same 5 interactions
  wakeups/2026-07-30-owen-marsh.md   a prior proposal, already dismissed
                                     (dismiss-reason: not-this-signal-type),
                                     30 days before "today"
  expected/README.md              states the expectation is ABSENCE of any
                                   new wake-up file, with the exact assertion
                                   a future test should make
```

## Assumptions this fixture set bakes in (reconciled against the landed specs)

The plan specs the shape of `ranking-weights.json` and the clamps
(`[0.25, 2.0]`, per-step `<= 0.15`); `specs/calibration.md` and
`specs/tier-drift.md` have since landed with the exact aggregation formula
and cooldown. Wave F's consistency-pass checker verified the two items below
against those specs and found them diverging from what this README
originally assumed; both are corrected here to match the specs verbatim (the
fixture data itself — the wakeup files and their outcome counts — already
satisfied the corrected numbers, so no wakeup file needed changing for this
reconciliation):

1. **Calibration minimum sample size:** `specs/calibration.md` §3.1 sets the
   floor at **`fired >= 3`** in-window entries for a key to receive any
   adjustment (not "4" terminal-outcome wakeups as originally assumed here).
   Below the floor, the key is left exactly as it appears in the previous
   `ranking-weights.json` (or omitted if it has no prior entry) — no
   `updated`/`rationale` rewrite. `calibration-basic`'s `birthday`
   signal-type key and `college-friend` tag key both clear the floor with
   `fired == 4`, so this correction doesn't change either fixture's expected
   weight — see `calibration-basic/expected-ranking-weights.json`, which
   byte-matches (modulo `generated_at`) a real run of `calibrate.sh` against
   this fixture.
2. **`calibration-basic` counts:** birthday signal-type — 3 of 4 wakeups
   dismissed `not-this-signal-type` => `weight: 0.85`. `college-friend`
   tag — 3 of 4 wakeups `acted-on: true` => `weight: 1.15`. The 4th entry in
   each group is deliberately the "clean"/non-matching outcome. Each wakeup
   fixture file now also carries the `signal-type` frontmatter field (per
   `wakeup.md` 1.1.0's since-landed field): the four birthday-standing
   nudges are `signal-type: birthday`; the four signal-driven nudges use the
   kebab-case type implied by their `source-signal` id and `why` line
   (`job-change`, `cadence-gap` x2, `life-event`) — none of those three
   individually clears the `fired >= 3` floor on their own, so they don't
   contribute a `signal-types` entry to the expected output; only
   `college-friend` (via the tags dimension, which pools all four of Marta
   Doyle's wakeups regardless of their individual signal-types) clears it.
3. **Tier-drift proposal:** the detector never writes `person.md#tier`
   directly (guardrail: nudge to reach out or reclassify, never automatic
   demotion — and, by the same logic, never automatic promotion). It always
   proposes exactly **one tier step** per proposal (here, `dormant` ->
   `active`) rather than jumping straight to `inner-circle`/`close`; the
   proposal wake-up's `origin` is `signal` with a non-null `source-signal`,
   `status: pending`.
4. **Decline cooldown:** `specs/tier-drift.md` (line ~156) sets the
   suppression window at **180 days** from the declined proposal's
   `fired-on` date (not 90 days as originally assumed here). The
   `declined-proposal` fixture's 30-day gap is comfortably inside 180 days
   too, so the fixture's expected behavior (suppress, no new proposal) is
   unchanged by this correction.
5. **"Last quarter" / "90d" window:** both read as the trailing 90 calendar
   days ending on "today" (2026-08-29), i.e. since 2026-05-31 inclusive. This
   is `specs/calibration.md` §1's aggregation window (distinct from
   tier-drift's separate 180-day decline-cooldown window in item 4 above).

`calibration-basic/expected-ranking-weights.json`'s `generated_at` is a fixed
placeholder (`2026-08-29T09:00:00Z`, matching this fixture set's "today"),
not the literal wall-clock timestamp `calibrate.sh` stamps at run time — a
real run's `generated_at` will differ; everything else in the file
(`weights`, key order, rounding) byte-matches a real run's output.

## Notes

- No `profile.md` fixture is included here — these scenarios test
  calibration/tier-drift, not signal opt-outs (unit 5/7's fixtures own
  `profile.md` coverage).
- `declined-proposal`'s prior dismissed wake-up is the *only* artifact of the
  refusal, per `docs/DECISIONS.md#preference-provenance` and this plan's
  no-guilt rule: "declined proposals are dropped silently, no re-asking on a
  streak." There is no separate "declined" log file by design.

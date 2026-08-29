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

## Assumptions this fixture set bakes in (plan 11 leaves these open)

The plan specs the shape of `ranking-weights.json` and the clamps
(`[0.25, 2.0]`, per-step `<= 0.15`) but not the exact aggregation formula, nor
the tier-drift cooldown/step-size. This fixture set assumes the following so
the JSON/markdown outputs below are unambiguous; **wave F's checker should
verify these match `specs/calibration.md` and `specs/tier-drift.md` once
those land, and this fixture set should be revised if they diverge**:

1. **Calibration threshold:** for a signal-type or tag dimension with >= 4
   terminal-outcome wakeups in the trailing 90 days (a wakeup counts once its
   fired-on is set and either `dismiss-reason` or `acted-on` is non-null), if
   >= 75% of those outcomes are negative for that dimension (dismissed with
   `not-this-signal-type` for `signal-types`; `acted-on: true` for `tags`),
   calibration applies the full per-step adjustment allowed by the clamp
   (`-0.15` for signal-types, `+0.15` for tags) from the `1.0` neutral
   baseline. Below that threshold, the dimension stays absent (neutral).
2. **`calibration-basic` counts:** birthday signal-type — 3 of 4 wakeups
   dismissed `not-this-signal-type` (75%) => `weight: 0.85`. `college-friend`
   tag — 3 of 4 wakeups `acted-on: true` (75%) => `weight: 1.15`. The 4th
   entry in each group is deliberately the "clean"/non-matching outcome so
   the ratio is exactly at the assumed threshold, not 100% — a stress case
   for whatever threshold the real spec picks (if the real threshold is
   e.g. 80%, this fixture's ratio would need bumping to 4/5 files; flagged
   here for wave F).
3. **Tier-drift proposal:** the detector never writes `person.md#tier`
   directly (guardrail: nudge to reach out or reclassify, never automatic
   demotion — and, by the same logic, never automatic promotion). It always
   proposes exactly **one tier step** per proposal (here, `dormant` ->
   `active`) rather than jumping straight to `inner-circle`/`close`; the
   proposal wake-up's `origin` is `signal` with a non-null `source-signal`,
   `status: pending`.
4. **Decline cooldown:** a tier-drift proposal dismissed with
   `dismiss-reason: not-this-signal-type` suppresses a new proposal for the
   same person for (at least) 90 days from that dismissal's `fired-on` date.
   The `declined-proposal` fixture's 30-day gap is comfortably inside any
   reasonable cooldown choice, so it should hold regardless of the exact
   number the real spec picks.
5. **"Last quarter" / "90d" window:** both read as the trailing 90 calendar
   days ending on "today" (2026-08-29), i.e. since 2026-05-31 inclusive.

## Notes

- No `profile.md` fixture is included here — these scenarios test
  calibration/tier-drift, not signal opt-outs (unit 5/7's fixtures own
  `profile.md` coverage).
- `declined-proposal`'s prior dismissed wake-up is the *only* artifact of the
  refusal, per `docs/DECISIONS.md#preference-provenance` and this plan's
  no-guilt rule: "declined proposals are dropped silently, no re-asking on a
  streak." There is no separate "declined" log file by design.

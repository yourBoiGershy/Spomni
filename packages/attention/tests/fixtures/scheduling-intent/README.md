# Attention fixtures: scheduling-intent (plan 21)

Golden fixtures pinning the expected promote/hold/silence behavior of plan
21's `scheduling-intent` detector and slot selection
(`packages/attention/specs/scheduling-intent.md`, not yet written at the
time these fixtures were authored — golden-tests-before-prompts, per plan
12's convention referenced by plan 21's deliverables list), written from
`docs/plans/2026-08-29-21-calendar-intelligence.md`'s "Detector & slot
selection" and "Wake-up contract 1.2.0 — event-proposal extension" sections
plus `packages/core/contracts/{interaction,person,signal-event,wakeup}.md`.
Layout follows the `tier-drift-upward` / `declined-proposal` sibling
fixtures under `packages/attention/tests/fixtures/`.

All dates are relative to "today" = **2026-08-29** (matches the environment's
current date at authoring time and the sibling calibration/tier-drift
fixture set). All fixture people/interactions/wakeups files conform to their
respective `packages/core/contracts/*.md`; each scenario directory has
`people/`, `interactions/`, and (where there is pre-existing queue state)
`wakeups/` siblings, the same shape `validate-store.sh` expects of a store
root.

## Layout

```
clear-intent/
  people/theo-bramwell.md          tier: active, work colleague
  interactions/
    2026-08-27-theo-bramwell.md    message: explicit mutual lunch ask +
                                    timeframe ("next week") — high confidence
    2026-08-31-theo-bramwell.md    filed calendar event, Mon 11:00-14:00
                                    (busy straight through lunch)
    2026-09-01-theo-bramwell.md    filed calendar event, Tue 09:00-10:30
    2026-09-01-theo-bramwell--2.md filed calendar event, Tue 14:00-15:30
                                    (leaves a 10:30-14:00 free block)
  expected/
    signal-event.md                the scheduling-intent signal event the
                                    detector should log (confidence: high)
    proposal-wakeup.md             the kind: event-proposal wake-up the
                                    promotion step should create, including
                                    the by-hand slot arithmetic a checker can
                                    recompute from the calendar interactions
                                    above (earliest fitting slot: Tue 9/1,
                                    11:30-12:30)

vague-intent/
  people/callum-reyes.md           tier: active, casual friend
  interactions/2026-08-24-callum-reyes.md
                                    message: vague nicety ("let's hang out
                                    sometime"), no activity/timeframe — low
                                    confidence
  expected/
    signal-event.md                one signal event, confidence: low
    README.md                      states the expectation: signal logged,
                                    NO wake-up (low confidence never
                                    promotes)

declined-proposal/
  people/marisol-vance.md          tier: close, college friend
  interactions/
    2026-08-10-marisol-vance.md    original message that promoted the now-
                                    dismissed proposal below
    2026-08-28-marisol-vance.md    a fresh explicit ask with a timeframe —
                                    high confidence on its own, same shape as
                                    clear-intent's line
  wakeups/2026-08-19-marisol-vance.md
                                    a prior scheduling-intent event-proposal,
                                    already dismissed (dismiss-reason:
                                    not-now), 10 days before "today" — inside
                                    the plan's 30-day suppression window
  expected/README.md               states the expectation is TOTAL SILENCE —
                                    no new signal event, no new wake-up file
                                    — with the exact assertion a future test
                                    should make, and an explicit flag on the
                                    open question of exactly where in the
                                    pipeline the suppression gate sits (see
                                    that file)
```

## Notes

- Fictional people distinct from every other fixture set's personas (Theo
  Bramwell, Callum Reyes, Marisol Vance — none reused from
  `calibration-basic`, `tier-drift-upward`, or `declined-proposal`'s Owen
  Marsh / Marta Doyle / Dmitri Volkov / Freya Lindgren / Petra Lindholm /
  Samuel Otieno).
- `interaction.md`'s contract has no time-of-day field (only `date`), so
  clock times for filed calendar events live in each interaction's `##
  Summary` prose, bolded for a human/checker to scan — that prose is the
  only place slot-selection's free/busy arithmetic can be recomputed from,
  by design (no schema change proposed here).
- `clear-intent`'s proposed slot honors every pinned rule at once: duration
  class (lunch, 60m, window 11:30-13:30), the 15-minute buffer on each side,
  the ≥48h-out notice floor from `detected_at`, and picking the *earliest*
  fitting block (Monday is deliberately fully booked through lunch so the
  fixture isn't ambiguous about why Tuesday won).
- `vague-intent` ships no calendar interactions at all — slot selection
  never runs for a held (non-promoted) signal, so there is nothing for it to
  read.
- `declined-proposal`'s suppression-window assumption (30 days, per the
  plan) and the open question of whether the fresh message even gets a
  logged signal event under suppression are both flagged explicitly in that
  scenario's `expected/README.md` for a later consistency-pass checker to
  reconcile against the landed `specs/scheduling-intent.md`, following the
  `tier-drift-upward` / `declined-proposal` sibling fixture set's precedent
  of flagging open thresholds rather than silently guessing.
- No `profile.md` fixture is included — these scenarios test the detector
  and slot selection, not plan 15's signal opt-outs.

# Expected outcome: one signal event, one event-proposal wake-up

This case's `graders/` derive their assertions directly from the wrapped
fixture (`packages/attention/tests/fixtures/scheduling-intent/clear-intent/`
and its own `expected/signal-event.md` + `expected/proposal-wakeup.md`)
rather than from a byte-diffable `expected/` store here — the detector's own
signal-event `id`/`detected_at` and the promoted wake-up's `id`/`due` are
run-date-derived and not byte-fixed by the fixture, so a whole-store
`RA_GRADER_DIFF` would fail on those non-substantive fields even on a
correct run. This directory exists only to satisfy the `expected`
frontmatter field the T3 runner (`eval-run-skill.sh`) requires; it is not
consumed by `RA_GRADER_DIFF`.

## Hand-derived expected outcome (from the fixture)

Per `packages/attention/tests/fixtures/scheduling-intent/clear-intent/`:

- Theo's 2026-08-27 message ("Hey, are you free for lunch next week? Would
  love to catch up properly outside of standups.") is an explicit mutual ask
  naming a concrete activity (lunch) and a timeframe ("next week") —
  `confidence: high` per `specs/scheduling-intent.md`'s rubric.
- Step 3 of `skills/scheduling-intent/SKILL.md` requires exactly one signal
  event to be logged for this mention, unconditionally, before any gate.
- No opt-out and no 30-day suppression apply in this fixture (no prior
  dismissed scheduling-intent wake-up for Theo, no `profile.md` opt-outs),
  so promotion proceeds to slot selection.
- Slot arithmetic (recomputed by hand from the fixture's calendar
  interactions, not copied from any run — see
  `expected/proposal-wakeup.md`'s "Slot arithmetic" section in the wrapped
  fixture): lunch class (60m, 11:30–13:30 window, 15m buffer each side,
  ≥48h out from detection). Monday 2026-08-31 is busy 11:00–14:00 (no
  lunch-length gap survives). Tuesday 2026-09-01 has a 10:30–14:00 free
  block, comfortably fitting 11:30–12:30 plus buffer, and is the earliest
  qualifying day. The unique earliest fitting slot is **Tue 2026-09-01,
  11:30–12:30** (`2026-09-01T11:30:00-07:00` – `2026-09-01T12:30:00-07:00`).
- The promotion step must therefore write exactly one new
  `kind: event-proposal` wake-up under `wakeups/`, with that slot,
  `attendees: ["[[theo-bramwell]]"]`, `origin: signal`, a non-null
  `source-signal`, and `confirmed-on`/`created-event-id` both null (never
  set at creation — those belong to the downstream event-confirm skill,
  after explicit human confirmation).

## Graders

1. `01-proposal-created.py` — exactly one new file appears under the worked
   store's `wakeups/` (top-level, not `signals/`), with `kind:
   event-proposal`, `origin: signal`, a non-null `source-signal`, attendees
   naming `[[theo-bramwell]]` alone, `proposed-event.start`/`.end` matching
   the hand-derived slot window above exactly, and `confirmed-on`/
   `created-event-id` both null. Tolerant of the generated `id`/`due` values
   (run-date dependent, not fixed by the fixture).
2. `02-signal-event-logged.py` — exactly one new file appears under the
   worked store's `wakeups/signals/`, with `type: scheduling-intent`,
   `person` naming `[[theo-bramwell]]`, `confidence: high`, and `evidence`
   containing a traceable quote from the 2026-08-27 interaction (not a
   paraphrase), per `CLAUDE.md`'s provenance-labeling principle.

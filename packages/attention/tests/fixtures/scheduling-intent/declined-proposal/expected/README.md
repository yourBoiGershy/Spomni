# Expected outcome: total silence

This scenario's expected output is the **absence** of any new artifact —
neither a new signal event nor a new wake-up file.

## Exact assertion

Given the input state in this scenario directory (`people/marisol-vance.md`,
two filed message interactions carrying scheduling language
(`interactions/2026-08-10-marisol-vance.md`, the original trigger, and
`interactions/2026-08-28-marisol-vance.md`, a fresh explicit ask with a
timeframe — high confidence on its own, same shape as `clear-intent`), plus
one pre-existing `wakeups/2026-08-19-marisol-vance.md` at
`status: dismissed`, `dismiss-reason: not-now`, `signal-type:
scheduling-intent`, dated **10 days before "today" 2026-08-29**), a future
scheduling-intent-detector test should assert:

1. Running the detector+promotion pipeline against this scenario's store
   produces **zero** new files under `wakeups/signals/` and **zero** new
   files under `wakeups/`.
2. `wakeups/` contains exactly the one pre-existing file
   (`2026-08-19-marisol-vance.md`) before and after the run — byte-identical,
   untouched (it is not the detector's file to rewrite; only
   `packages/attention`'s lifecycle ops/sweep touch existing wake-up files,
   and this one is already terminal).
3. `people/marisol-vance.md` is untouched — a declined proposal never
   triggers any automatic write there.

## Assumed threshold and where the suppression applies (flag for reconciliation)

`docs/plans/2026-08-29-21-calendar-intelligence.md`'s "Detector & slot
selection" section pins **30 days per `(person, signal-type:
scheduling-intent)` pair after a dismissal** as the re-proposal suppression
window. 10 days (this fixture's gap) falls comfortably inside that window,
so *some* form of silence is the unambiguous expected outcome regardless of
exactly where in the pipeline the suppression is enforced.

The plan text ("re-proposal suppression... after a dismissal") pins the
suppression to *promotion*, which leaves open whether the detector still
logs a fresh `scheduling-intent` signal event for the 2026-08-28 message
before suppression holds it back (as in `vague-intent`, where a signal event
is logged but promotion is held), or whether the suppression gate is checked
earlier and skips signal-event logging entirely for a still-cooling-down
person. This fixture assumes the latter — **total silence, no new signal
event either** — matching this fixture's directory name and the brief's
"total silence" framing; a checker reconciling against the landed
`packages/attention/specs/scheduling-intent.md` should confirm which
reading the spec actually implements and update this assumption (and, if
needed, add an `expected/signal-event.md` alongside this README) rather than
this fixture's outcome, which is correct under either reading since no new
wake-up is ever produced.

## Assumed "today"

All dates in this fixture set are relative to "today" = **2026-08-29**,
matching the sibling `clear-intent` and `vague-intent` scenarios (see this
directory's parent `README.md`).

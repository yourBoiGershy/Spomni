---
name: scheduling-intent
description: Detect scheduling-language mentions in recently filed interactions, log a scheduling-intent signal event for every one, and — subject to the opt-out and 30-day suppression gates plus a deterministic slot search — promote qualifying mentions into `kind: event-proposal` wake-ups via `wakeup-add.sh`. Proposes only; never creates a calendar event.
---

# Scheduling-intent detection

Runs over a store's filed interactions to find scheduling language ("are you
free for lunch?", "we should grab coffee") and turn it into, at most, a
proposed meeting time sitting in the wake-up queue for a human to confirm.
The authoritative rules — confidence tiers, the opt-out and suppression
gates, slot-selection arithmetic, timing — live in
`packages/attention/specs/scheduling-intent.md`; this document is the
runnable flow. Where the two disagree, the spec wins.

This skill only ever *proposes*. It never writes a calendar event, never
sets `confirmed-on`/`created-event-id` (those are the event-confirm skill's
job, downstream of an explicit human confirmation), never writes lifecycle
fields (`fired-on`, `dismiss-reason`, `acted-on`, `snooze-count` — those
belong to `packages/attention`'s outcome-recording writer), and never edits
`profile.md` (opt-outs are read-only input here, per plan 15's
touchpoints).

## Inputs

- `<store-dir>/interactions/*.md` — every filed interaction dated within
  the trailing 14 days of the sweep's run date (spec's "Inputs" section).
- `<store-dir>/profile.md` `## Signal opt-outs` — read-only.
- `<store-dir>/wakeups/*.md` — prior history, for the 30-day re-proposal
  suppression window.
- `<store-dir>/signals/week-plan.json` (plan 12 contract), when present and
  fresh (not older than 8 days) — the preferred source of free/busy blocks
  for slot selection.
- `<store-dir>/interactions/*.md` again, filtered to filed calendar events
  over the next 14 days — the fallback slot-selection source when
  `week-plan.json` is absent or stale.

## Flow

Run this per sweep. Steps 1–4 run once per detected mention; a single
sweep may process many mentions across many interactions/people.

### 1. Scan for scheduling language

For each interaction inside the 14-day trailing window, read `## Summary`
and `## Commitments` for scheduling language — a mention of getting
together, with or without a concrete activity/timeframe. Two independent
mentions of the same underlying plan across separate interactions for the
same person still count as one detected mention for confidence purposes
(they combine to raise confidence — see the rubric below), not two.

### 2. Classify confidence

Apply the spec's rubric exactly:

| Confidence | Definition |
|---|---|
| `high` | Mutual/explicit proposal with a concrete activity AND a timeframe, OR two independent mentions across separate interactions |
| `medium` | Explicit one-sided proposal, no timeframe |
| `low` | Vague nicety, no concrete ask |

### 3. Write the signal event — always, first, unconditionally

Before any opt-out check, suppression check, or slot search, write exactly
one `<store-dir>/wakeups/signals/<id>.md` conforming to
`packages/core/contracts/signal-event.md`:

- `id`: `<detected_at-compact>-scheduling-intent-<person-slug>`
  (e.g. `20260829T090000Z-scheduling-intent-theo-bramwell`).
- `type: scheduling-intent`
- `person`: the matched `[[slug]]` link(s).
- `evidence`: the quoted line plus the source interaction's id/path,
  labeled inferred-from-message per `CLAUDE.md`'s provenance-labeling
  principle — never mixed with told-by-the-user facts. State plainly why
  the line maps to the confidence tier assigned.
- `confidence`: from step 2.
- `detected_at`: the sweep's run timestamp, ISO 8601.

This file is hand-written directly (there is no `signal-add.sh` — signal
events are a detector's own append-only log, per the contract's writer
table naming `packages/attention` as sole writer). This step happens for
**every** detected mention, including ones that will go on to be held or
gated — the log is the record that the mention was seen, independent of
what happens next.

Exception: the suppression check (step 5) is evaluated *before* step 3 for
mentions concerning a person currently inside the 30-day re-proposal
window — see step 5's note. Every other mention gets a signal event
unconditionally.

### 4. Low confidence → stop here

If step 2 classified `low`, stop. No opt-out check, no suppression check,
no slot search, no promotion. The signal event from step 3 is the only
artifact this mention ever produces.

### 5. Re-proposal suppression (30 days) — checked before the signal event for a suppressed person

For a `medium`/`high` mention, before writing anything (including the
step-3 signal event), scan `<store-dir>/wakeups/*.md` for a prior entry
where `people` includes this person's slug, `signal-type:
scheduling-intent`, and `status: dismissed`. If `fired-on` (or the
dismissal date if `fired-on` is absent) falls within 30 days of today,
suppress entirely: **no signal event, no promotion, no log artifact of any
kind** for this mention. This is scheduling-intent's own rule (a shorter
window than tier-drift's 180-day pairing suppression, and gated earlier
than tier-drift's own gate) — total silence for a person still cooling
down from a recent decline, per the `declined-proposal` fixture.

If no such prior entry is in-window, proceed: write the step-3 signal
event, then continue to step 6.

### 6. Opt-out gate

Check `<store-dir>/profile.md` `## Signal opt-outs` for either:

- `scheduling-intent — all` → suppress promotion for every person this
  sweep.
- `scheduling-intent — [[slug]]` → suppress promotion for that person
  only.

The signal event from step 3 has already been written by this point — an
opt-out silences the *promotion* step only. An opted-out mention produces
a signal event and nothing else; log one line noting the opt-out as the
hold reason.

### 7. Slot selection (deterministic)

Only reached for `medium`/`high` mentions that passed steps 5 and 6.

1. **Source of free blocks.** If `signals/week-plan.json` exists and is
   fresh (not older than 8 days), use its free blocks. Otherwise compute
   free blocks from filed calendar interactions over the next 14 days,
   working window 09:00–18:00.
2. **Candidate selection.** Pick the earliest block that fits the intent
   class's duration plus a 15-minute buffer on each side, starting at
   least 48 hours out from `detected_at`.
3. **Durations by intent class:**

   | Intent class | Duration | Window constraint |
   |---|---|---|
   | call / catch-up | 30m | none |
   | coffee | 60m | none |
   | lunch | 60m | must fit within 11:30–13:30 |
   | dinner | 90m | must start within 18:00–20:30 |

4. **No qualifying slot within 14 days.** Hold promotion: the signal event
   stands alone, no proposal wake-up is created, and log one line
   recording the hold (person, intent class, reason: no slot). Never widen
   the window or relax the buffer to force a fit.

### 8. Promote

On a qualifying slot, create exactly one wake-up entry via:

```sh
bash packages/core/scripts/wakeup-add.sh <store-dir> \
  --due <1-2 days out> \
  --person <slug> [--person <slug> ...] \
  --why "scheduling intent: \"<quoted line>\" — proposed <slot summary>" \
  --origin signal \
  --source-signal <signal-event-id-from-step-3> \
  --context "<why the mention was made, dates/interaction ids, and the slot arithmetic that picked this block>" \
  --draft "<one short message proposing the specific day/time>" \
  --kind event-proposal \
  --event-title "<title, e.g. 'Lunch with Theo'>" \
  --event-start <selected-slot-start-iso> \
  --event-end <selected-slot-end-iso> \
  --event-attendee <slug> [--event-attendee <slug> ...] \
  [--event-location "<name if stated in the source text>"]
```

- `--person`/`--event-attendee`: the store `[[slug]]` link(s) matched to
  the interaction's people.
- `--event-location`: omit unless a location was named in the source text
  — never invent one.
- `--due`: 1–2 days out from today (scheduling intent is time-sensitive;
  shorter than a slower detector's multi-week timing).
- `confirmed-on`/`created-event-id` are never passed — `wakeup-add.sh`
  itself rejects them at creation; they're set only by the later
  human-confirmed event-confirm skill.

### 9. Explicit in-session user ask (separate path)

When a human/agent session hands this skill an explicit, direct ask ("set
up coffee with Sam") rather than a mention detected from a filed message,
skip steps 1–6 (there is no message-derived mention to log a signal event
for) and go straight to step 7's slot selection, then promote with
`--origin user-ask` instead of `--origin signal`, and omit
`--source-signal`. Budget-exempt per plan 12's explicit-wake-up exemption
— but still confirm-first like every other proposal; no origin skips the
human-confirmation gate downstream.

## Fixture-checkable outcomes

`packages/attention/tests/fixtures/scheduling-intent/` pins three
scenarios this flow must reproduce exactly:

- `clear-intent/` — high confidence, opt-out/suppression clear, a
  qualifying slot exists → one signal event (step 3) **and** one
  `kind: event-proposal` wake-up (step 8), matching
  `expected/signal-event.md` and `expected/proposal-wakeup.md` including
  the by-hand slot arithmetic.
- `vague-intent/` — low confidence → one signal event only (step 3), stop
  at step 4; zero files under `wakeups/` (proposal-level).
- `declined-proposal/` — a fresh high-confidence mention for a person
  still inside the 30-day suppression window (step 5) → total silence, no
  new file anywhere, not even a signal event.

## Not in this skill

- The connector create itself, and the confirm/decline lifecycle mechanics
  that flip `confirmed-on`/`created-event-id` — those belong to the
  event-confirm skill, a sibling unit.
- The ranking/budget/sweep machinery that decides which pending wake-ups
  actually surface to the user — plans 05/06/12.
- Negotiating times with the other party over messages, multi-slot
  proposals, availability polling, rescheduling/editing/cancelling
  existing events, timezone/travel awareness, recurring proposed events —
  all explicitly out of scope per the spec.

# Spec: scheduling-intent detector

Package: `attention` (plan 05 detector set, added by plan 21 unit 2).
Signal `type`: `scheduling-intent`. Writes only `wakeups/signals/<id>.md`
(via the normal signal-scan path) and, when promoted, a `wakeups/<id>.md`
`kind: event-proposal` entry (`packages/core/contracts/wakeup.md`, 1.2.0) —
**never** a calendar event directly. The calendar create happens only after
an explicit human confirmation, recorded via the wake-up's `confirmed-on` /
`created-event-id` fields; that mechanism belongs to
`packages/core/contracts/wakeup.md` and is not restated here.

## Inputs

Per sweep, for every filed interaction (`interaction@1`,
`docs/plans/2026-08-29-03/04` lanes) dated within the trailing 14 days of the
sweep's run date (stale intent expires — a "we should grab coffee" from three
weeks ago is not actionable):

- Scan the interaction's `## Summary` and `## Commitments` sections for
  scheduling language.
- `data/store/profile.md` `## Signal opt-outs` (opt-out check, below).
- Prior `wakeups/*.md` history for the person (30-day re-proposal suppression,
  below).
- `signals/week-plan.json` (plan 12 contract), opportunistically, for slot
  selection.
- Filed calendar interactions over the next 14 days, for slot selection when
  `week-plan.json` is absent or stale.

## Confidence rubric

| Confidence | Definition | Example |
|---|---|---|
| `high` | Mutual/explicit proposal with a concrete activity AND a timeframe, OR two independent mentions across separate interactions | "are you free for lunch next week?" |
| `medium` | Explicit one-sided proposal, no timeframe | "we should grab coffee" |
| `low` | Vague nicety, no concrete ask | "let's hang out sometime" |

`low` confidence **never promotes** to a proposal wake-up — a signal event is
still written (see below), but no `wakeups/` entry follows. `medium` and
`high` confidence promote, subject to the opt-out gate and the 30-day
suppression window below.

## Signal event (always emitted first)

Every detected scheduling-intent mention — regardless of confidence, and
regardless of whether it goes on to promote — first writes one
`wakeups/signals/<id>.md` (`packages/core/contracts/signal-event.md`),
`type: scheduling-intent`:

```yaml
schema_version: 1.0.0
id: 20260829T090000Z-scheduling-intent-<slug>
type: scheduling-intent
person: ["[[<slug>]]"]
evidence: >
  "we should grab coffee sometime" — quoted from interactions/2026-08-27-<slug>.md
  ## Summary.
confidence: medium
detected_at: 2026-08-29T09:00:00Z
```

`evidence` is always the quoted line plus the source interaction's id/path,
labeled inferred-from-message per `CLAUDE.md`'s provenance-labeling
principle (never mixed with told-by-the-user facts). Signal-event emission
happens unconditionally before any opt-out check, suppression check, or slot
search — the log is the record that the mention was seen, independent of
whether it goes anywhere.

## Opt-out gate (applied before promotion, plan 15 touchpoint)

Before evaluating promotion for a `medium`/`high` mention, check
`data/store/profile.md` `## Signal opt-outs`
(`packages/core/contracts/profile.md`) for:

- `scheduling-intent — all` → suppress promotion for every person,
  sweep-wide.
- `scheduling-intent — [[slug]]` → suppress promotion for that person only.

The signal event has already been written by the time the opt-out is
checked (per above) — opt-outs silence the *promotion* step only, matching
this detector's own rule, not tier-drift's stricter "suppress before
signal-event emission" rule (that rule is tier-drift-specific; here the
event log is unconditional). An opted-out mention produces a signal event
and nothing else.

## Re-proposal suppression (30 days)

Before promoting a `medium`/`high` mention for a `(person, signal-type:
scheduling-intent)` pair, scan existing `wakeups/*.md` for a prior entry
where `people` includes the slug, `signal-type: scheduling-intent`, and
`status: dismissed`. If `fired-on` (or the dismissal date if `fired-on` is
absent) is within 30 days of today, suppress — do not re-propose for that
person. This window is shorter than tier-drift's 180-day pairing suppression
because scheduling intent is time-sensitive and re-arises naturally in later
conversation; 30 days matches one dismissal cycle without re-litigating a
recent "not now."

## Slot selection (deterministic)

Only reached for `medium`/`high` mentions that pass the opt-out gate and the
suppression window.

1. **Source of free blocks:**
   - If `signals/week-plan.json` exists and is fresh (plan 12 staleness
     rule: not older than 8 days), use its free blocks.
   - Otherwise, compute free blocks from filed calendar interactions over
     the next 14 days, working window 09:00–18:00 (plan 12's parameters).
2. **Candidate selection:** pick the earliest block that fits the intent
   class's duration plus a 15-minute buffer on each side, and that starts at
   least 48 hours out (notice for the other party).
3. **Durations by intent class:**

   | Intent class | Duration | Window constraint |
   |---|---|---|
   | call / catch-up | 30m | none |
   | coffee | 60m | none |
   | lunch | 60m | must fit within 11:30–13:30 |
   | dinner | 90m | must start within 18:00–20:30 |

4. **No qualifying slot within 14 days:** promotion is held — the signal
   event stands alone, no proposal wake-up is created, and one log line
   records the hold (person, intent class, reason: no slot). Nothing is
   invented; the detector never widens the window or relaxes the buffer to
   force a fit.

## Promotion → event-proposal wake-up

On a qualifying slot, promote via `wakeup-add.sh --kind event-proposal`
(`packages/core/contracts/wakeup.md` 1.2.0): `title`/`start`/`end` from the
selected slot and intent class, `attendees` = the store `[[slug]]` link(s)
matched to the interaction's people, `location` null unless named in the
source text. `source-signal` = the signal event id from above,
`signal-type: scheduling-intent`. `due` is set 1–2 days out (see timing,
below). `confirmed-on` and `created-event-id` are left null at creation —
never settable at creation per the wakeup contract.

## Origin split

- **Message-derived intent** (the normal detector path above) →
  `origin: signal`, `source-signal` set to the signal event id. Subject to
  ranking caps/budgets once plan 05's ranking and plan 12's capacity model
  run.
- **Explicit in-session user ask** (e.g. "set up coffee with Sam", spoken
  directly to the agent rather than detected from a filed message) →
  `origin: user-ask`, budget-exempt (plan 12's explicit-wake-up exemption
  applies) — but the create is still confirm-first like every other
  proposal; no origin skips the human-confirmation gate.

## Proposal timing

Scheduling intent is time-sensitive: promoted proposals are due within 1–2
days, not the multi-week timing used by slower-moving detectors (e.g.
tier-drift's quarterly cadence). This is a timing-only distinction — the
opt-out, suppression, and slot-selection rules above are unchanged by
origin or urgency.

## Deterministic fixture-checkability

Given a fixture interaction's `## Summary`/`## Commitments` text, its date
relative to the sweep run-date, a fixture `week-plan.json` (or filed
calendar interactions when absent/stale), and a seeded `wakeups/` history, a
checker can hand-verify:

1. Whether the interaction falls inside the 14-day input window.
2. Which confidence tier the quoted line maps to, and whether it promotes.
3. Whether the opt-out gate or the 30-day suppression window applies.
4. The exact slot chosen (or the hold, with its reason) given the intent
   class's duration/window and the 48-hour/15-minute-buffer rules.
5. Whether the resulting wake-up is `origin: signal` or `origin: user-ask`,
   and its `due` date.

## Out of scope (per plan 21)

- Negotiating times with the other party over messages.
- Multi-slot proposals, availability polling, external scheduling links.
- Rescheduling, editing, or cancelling existing events.
- Timezone/travel awareness (mirrors plan 12's exclusion).
- Recurring proposed events.
- The connector create itself, the confirm/decline lifecycle mechanics, and
  the ranking/budget/sweep machinery — those belong to the event-confirm
  skill, `proposal-confirm.sh`, and plans 05/06/12 respectively; this spec
  covers detection, confidence, gating, and slot selection only.

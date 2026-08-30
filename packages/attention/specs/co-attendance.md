# Spec: co-attendance detector

Package: `attention` (plan 05 detector set). Signal `type`: `co-attendance`.
Writes only `wakeups/signals/<id>.md` (`packages/core/contracts/signal-event.md`,
1.0.0) — never `people/` or `interactions/`. Unlike every other detector in
this set, a co-attendance signal's `person` list names **two** people (the
pairing itself is the signal); ranking, promotion, and scoring belong to
`packages/attention/specs/ranking.md`, cited by path, not restated here.

## Inputs

Per sweep, over the trailing 7 days of the sweep run date:

- Filed interactions (`interaction@1`) with non-null `calendar-event`
  (`packages/core/contracts/interaction.md`) whose `## Summary` carries
  ingestion's same-event-as marker — the phrase "Met at the same event as
  [[slug]]" or an explicit `same-event-as` link — pointing at another
  person's interaction for the same `calendar-event` id.
- Calendar `calendar-event` capture events sitting in `inbox/` (filed or
  not yet filed) whose `attendees`/`participant-hints` resolve, by email
  match against `people/*.md`, to **≥2** known people, for events dated in
  the trailing 7 days.
- `data/store/profile.md` `## Signal opt-outs`, checked before emission.
- Prior `wakeups/signals/*.md` with `type: co-attendance` for the pairing
  dedup key (see below).

## Detection rule

1. **Filed-interaction path (preferred):** if two filed interactions share
   the same `calendar-event` id and at least one carries the same-event-as
   marker linking to the other's person, emit one co-attendance signal for
   the pair, `person: ["[[a]]", "[[b]]"]`.
2. **Calendar-capture path:** for a `calendar-event` capture event in
   `inbox/` with attendees resolving to ≥2 known people by email, emit one
   co-attendance signal per unordered pair of resolved attendees. This path
   fires even before either attendee's interaction has been filed —
   attendance is unconfirmed until a person actually reports the meeting
   (hence the lower confidence, below).
3. **≥3 resolved attendees:** emit one signal per unordered pair (so a
   3-person event yields 3 pairwise signals), up to the 8-attendee ceiling
   in the exclusion rule below. This is deliberately pairwise, not a single
   multi-person signal — dedup and the two-signal-rule downstream both key
   on pairs, matching the `person` list's two-entry shape used elsewhere in
   this spec.
4. **One side resolved only:** if only one attendee of a calendar event
   resolves to a known person (the other attendees are unknown emails, or
   the event has just one filed side and no confirming second interaction),
   still emit a signal, but with `person` naming only that one resolved
   person and `confidence: low` (see rubric) — the pairing can't be
   completed, but the fact that the known person was at *some* event is
   still worth a low-confidence log entry that a later corroborating
   interaction (or the other attendee's own filed interaction) can
   strengthen into a full pair.

## Confidence rubric

| Confidence | Definition | Example |
|---|---|---|
| `high` | A filed interaction carries the same-event-as link, confirming both people actually attended | `interactions/2026-08-22-ayesha-malik.md` and a peer interaction for the same `calendar-event: gcal-evt-7742`, cross-linked |
| `medium` | Derived only from a calendar capture's attendee list — both people are invited/resolved but attendance is unconfirmed by either side's filed interaction | A `calendar-event` capture in `inbox/` lists two known attendee emails; neither has filed a debrief yet |
| `low` | Only one side of the pair resolves to a known person; the other attendee is unresolved | A calendar capture names one known attendee plus emails with no `people/` match |

## Due-date rule

Due = **the day after the shared event**, giving the natural "how was it"
follow-up its obvious timing. If the event has already passed by more than
one day when the sweep detects it (the calendar capture or filed
interaction lagged), due = **the sweep's run date + 1 day** instead — never
a due date that has already elapsed by the time the signal is emitted.

## Opt-out / dedup gates

- **Opt-out** (`data/store/profile.md` `## Signal opt-outs`): checked
  per-person against each name in the pair. `co-attendance — all`
  suppresses emission sweep-wide; `co-attendance — [[slug]]` suppresses
  any pair that includes that slug (the other person in the pair still
  gets no co-attendance signal for this event — the pair is atomic; there
  is no partial-pair emission when one side opts out).
- **Pairing dedup (the load-bearing key for this detector):** the dedup key
  is the **unordered pair + calendar-event id**, not just the pair alone.
  If the same two people are detected at a *second, different* event within
  30 days, that is a **new** signal — this is deliberate, it's the fuel for
  ranking's two-signal-rule (two independent co-attendance signals for the
  same pair inside a window is a stronger nudge than either alone; see
  `ranking.md`). The common-rules 30-day same-type+person dedup therefore
  applies per event id here, not per pair — re-running detection over the
  same event on a later sweep must not re-emit, but a new event with the
  same two people must.
- **Low-confidence one-side signals** (detection rule 4) use the same
  person's slug alone as part of the dedup key alongside the event id —
  they don't collide with a later `high`/`medium` two-person signal for the
  same event, which is a distinct `person` list and therefore a distinct
  dedup key; both may legitimately exist in the log side by side.

## Evidence format

With a filed interaction:

```
Shared event "<summary>" on <date> with [[a]], [[b]] [inferred-from-calendar] (interaction: <interaction-id>)
```

Calendar-capture only (no filed interaction yet):

```
Shared event "<summary>" on <date> with [[a]], [[b]] [inferred-from-calendar]
```

One-side-resolved (`low`):

```
Shared event "<summary>" on <date> with [[a]] [inferred-from-calendar] (other attendees unresolved)
```

## Example scenarios

1. **High confidence, filed interaction.** `interactions/2026-08-22-ayesha-malik.md`
   has `calendar-event: gcal-evt-7742`. Assume a peer interaction for
   Ben Whitmore shares the same `calendar-event` id and one of the two
   summaries carries the same-event-as marker (e.g. "Met at the same event
   as [[ben-whitmore]]"). Emit one signal, `person: ["[[ayesha-malik]]",
   "[[ben-whitmore]]"]`, `confidence: high`, evidence `Shared event "Product
   conference happy hour" on 2026-08-22 with [[ayesha-malik]],
   [[ben-whitmore]] [inferred-from-calendar] (interaction:
   2026-08-22-ayesha-malik)`, due = 2026-08-23.
2. **Medium confidence, calendar capture only.** A `calendar-event` capture
   event in `inbox/` for a dinner on 2026-08-27 lists attendee emails that
   resolve to both Ben Whitmore and Walter Combs, but neither has a filed
   interaction yet for that event. Emit `confidence: medium`, `person:
   ["[[ben-whitmore]]", "[[walter-combs]]"]`, due = 2026-08-28 (day after
   the event). If a filed interaction with the same-event-as marker shows
   up on a later sweep, it does not re-emit for the same event id — the
   medium signal stands as the record; a future spec revision may cover
   upgrading confidence in place, but this spec does not require it.
3. **Exclusion: conference-scale event.** A `calendar-event` capture for an
   industry conference resolves 14 known attendees. This exceeds the
   8-resolved-attendee ceiling below — the detector logs the event id and
   attendee count and skips it entirely; no co-attendance signals are
   emitted for any pair at that event.

## Out of scope

- Events with **more than 8** resolved attendees — treated as
  conference-scale, not a meaningful one-on-one or small-group signal. The
  detector logs (event id, attendee count) and skips; ranking never sees
  these.
- Confirming attendance beyond what the calendar capture or filed
  interaction states — no RSVP-status parsing, no "declined" filtering
  beyond what the capture event already carries.
- Upgrading a `medium` signal to `high` in place when a corroborating
  interaction is later filed — each detection pass emits independently per
  the pairing-dedup key above; in-place confidence upgrades are a future
  extension, not covered here.
- Resolving unknown-email attendees to people (contact matching, enrichment)
  — that is the filing engine's job; this detector only reads already-
  resolved `people/*.md` matches.
- Group events with no calendar record at all (e.g. a spontaneously
  mentioned "we were both at Sam's party") — those are `people/*.md`
  `## Facts`/interaction text, not this detector's input surface.

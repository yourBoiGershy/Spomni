# Contract: wake-up

`schema_version: 1.2.0`

## Store location

`wakeups/<id>.md` — one file per queue entry. `id` is also the filename
stem. Recommended form: `<due-date>-<primary-person-slug>[--<n>]`, e.g.
`2026-09-20-dana-whitfield.md`.

This is **the only scheduling primitive** in the system
(`docs/DECISIONS.md#wakeup-queue-over-digests`): explicit reminder asks
("remind me in a month"), birthdays, standing rhythms, and signal-driven
nudges are all the same object, distinguished only by `origin`.

## Writer / readers

- **Creation:** open to any package, but only through
  `packages/core/scripts/wakeup-add.sh` — the one sanctioned way to append a
  wake-up entry (see `packages/core/package.md`). *(since 1.2.0)*
  `wakeup-add.sh` gains optional event-proposal creation flags
  (`--kind event-proposal`, `--event-title`, `--event-start`,
  `--event-end`, `--event-attendee <slug>` repeatable, `--event-location`) —
  see the `kind`/`proposed-event` fields below.
- **Lifecycle (fire/snooze/dismiss — i.e. `status` transitions after
  creation, plus the outcome fields `fired-on`, `dismiss-reason`,
  `acted-on`, `snooze-count` below, and *(since 1.2.0)* `confirmed-on` /
  `created-event-id`):** sole writer is `packages/attention` (per
  `docs/DECISIONS.md#attention-merge` — outcome recording and calibration
  live inside attention, not a new package). Confirming or declining an
  `event-proposal` entry is a lifecycle write like any other and stays
  attention's alone.
- **Readers:** `packages/connectors/*-out` (rendering fired wake-ups to a
  destination), `packages/query` (what's pending, briefs).

## Shape

Markdown file with YAML frontmatter plus two prose sections, one of them
optional.

### Frontmatter fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | semver string | yes | Contract version this file conforms to. |
| `id` | string | yes | Unique within `wakeups/`. Also the filename stem. |
| `due` | ISO 8601 date | yes | `YYYY-MM-DD`. When this entry should fire. Same-day entries are batched at delivery (per `wakeup-queue-over-digests`), not split across files. |
| `people` | list of `[[slug]]` links | yes (≥1) | Who this wake-up is about. `self` is a reserved slug for the user themselves — a wake-up whose subject is the user's own machinery (e.g. plan 09 staleness: `source-signal: staleness:<routine>`) links `[[self]]`; the validator never requires `people/self.md` for it. Not valid as an event-proposal attendee. |
| `why` | string | yes | One line: the trigger. Never bare cadence — must name the reason (per `docs/PROJECT-CONTEXT.md`'s "nudges carry a trigger and ammunition"), e.g. `"job change: now leading partnerships at Meridian"`, not `"90 days since last contact"`. |
| `status` | enum | yes | One of: `pending`, `fired`, `snoozed`, `dismissed`. Set to `pending` at creation. |
| `origin` | enum | yes | One of: `user-ask`, `signal`, `standing`. `user-ask` = explicit reminder request; `signal` = produced by a `signal-event.md`; `standing` = recurring rhythm (e.g. birthdays). |
| `source-signal` | string or `null` | no (default `null`) | The `id` of the `wakeups/signals/<id>.md` this entry was promoted from. Required (non-null) when `origin: signal`. |
| `fired-on` | ISO 8601 date or `null` | no (default `null`) | *(since 1.1.0)* `YYYY-MM-DD`. Set by `packages/attention` when this entry transitions to `status: fired`. Makes outcomes datable for calibration. |
| `dismiss-reason` | enum or `null` | no (default `null`) | *(since 1.1.0)* One of: `not-now`, `not-this-person`, `not-this-signal-type`, `already-handled`. Required (non-null) whenever `status: dismissed` is written by a 1.1.0 writer. |
| `acted-on` | bool or `null` | no (default `null`) | *(since 1.1.0)* Set by attention's sweep: `true` when an interaction with any of this entry's `people` is dated within 7 days after `fired-on`, `false` if the window closed without one, `null` until evaluated (e.g. not yet fired, or window still open). |
| `snooze-count` | integer | no (default `0`) | *(since 1.1.0)* Incremented by attention each time this entry is snoozed. Preserves the snooze history that the `due`-rewrite pattern (see Notes) would otherwise discard. |
| `signal-type` | string or `null` | no (default `null`) | *(since 1.1.0)* Kebab-case type bucket for calibration, e.g. `birthday`, `job-change`. When `origin: signal`, mirrors the promoting signal event's `type` (`signal-event.md`). `standing` entries set it to their standing kind (e.g. `birthday`). `user-ask` entries typically omit it. Absent/`null` falls into attention's `unclassified` calibration bucket. Open vocabulary — no fixed enum. |
| `kind` | enum or absent | no (default `nudge`) | *(since 1.2.0)* One of: `nudge`, `event-proposal`. `nudge` is the existing behavior (message draft, no event). `event-proposal` carries a ready-to-confirm calendar event in `proposed-event`. Missing `kind` reads as `nudge`. |
| `proposed-event` | mapping or `null` | no (default `null`) | *(since 1.2.0)* Required non-null iff `kind: event-proposal`; must be `null` (or absent) otherwise. Fields: `title` (string), `start` / `end` (ISO 8601 datetime with offset), `attendees` (list of `[[slug]]` links, ≥1 — store people, not raw emails; emails are resolved from `people/<slug>.md` at confirm time), `location` (string or `null`). |
| `confirmed-on` | ISO 8601 date or `null` | no (default `null`) | *(since 1.2.0)* Set by `packages/attention` when the human explicitly confirms an `event-proposal` entry. Always `null` for `kind: nudge` entries. |
| `created-event-id` | string or `null` | no (default `null`) | *(since 1.2.0)* The connector's event id, set by `packages/attention` only after the calendar create succeeds. **Invariant:** `created-event-id` non-null requires `confirmed-on` non-null AND `kind: event-proposal`. |

### Body sections

#### `## Context`

Free prose: the ammunition — what the user knows about this person plus the
evidence behind the trigger, enough for a draft to be written without
re-researching. Required.

#### `## Draft` (optional)

A ready-to-send message draft, if one has been composed. Per the
`draft-never-send` principle, this is always presented to the human for
review/edit — no connector or agent sends it automatically. Omit the section
entirely if no draft has been prepared yet.

## Example

`wakeups/2026-09-20-dana-whitfield.md`:

```markdown
---
schema_version: 1.1.0
id: 2026-09-20-dana-whitfield
due: 2026-09-20
people: ["[[dana-whitfield]]"]
why: "Berlin move should be settling in — good moment to check in"
status: fired
origin: signal
source-signal: 20260829T090000Z-job-change-dana-whitfield
fired-on: 2026-09-20
dismiss-reason:
acted-on:
snooze-count: 0
signal-type: job-change
---

## Context

Dana moved to Berlin end of September for her new Head of Partnerships role
at Meridian Fintech. She mentioned being stressed about the move on
2026-08-29. Three weeks post-move is a good "settled in?" window rather than
reaching out day one.

## Draft

Hey Dana! How's Berlin treating you — all unpacked and settled into the new
role yet? Would love to hear how the partnerships team is shaping up.
```

*(since 1.2.0)* `wakeups/2026-09-05-sam-okafor.md`, an event-proposal card:

```markdown
---
schema_version: 1.2.0
id: 2026-09-05-sam-okafor
due: 2026-09-05
people: ["[[sam-okafor]]"]
why: "scheduling intent: \"we should grab coffee sometime\" in last message"
status: fired
origin: signal
source-signal: 20260903T140000Z-scheduling-intent-sam-okafor
fired-on: 2026-09-05
dismiss-reason:
acted-on:
snooze-count: 0
signal-type: scheduling-intent
kind: event-proposal
proposed-event:
  title: Coffee with Sam
  start: 2026-09-08T10:00:00-07:00
  end: 2026-09-08T11:00:00-07:00
  attendees: ["[[sam-okafor]]"]
  location:
confirmed-on:
created-event-id:
---

## Context

Sam mentioned wanting to grab coffee in their 2026-09-03 message. No fixed
timeframe given, so this slot was picked from the first open block at least
48h out honoring the working window.

## Draft

Hey Sam! You mentioned grabbing coffee — does Tuesday 9/8 at 10am work for
you?
```

## Notes

- `status: snoozed` should carry a re-fire date; store it by re-writing
  `due` forward and leaving `status: pending` again rather than inventing a
  second date field — `snoozed` is a transient marker attention may use
  between the snooze action and the due-date rewrite, not a resting state a
  file sits in indefinitely. *(since 1.1.0)* This rewrite also increments
  `snooze-count` by one, so the number of times an entry was pushed survives
  even though the individual snooze dates don't.
- Birthdays and other recurring `standing` entries are re-created each cycle
  by attention (a fresh file per occurrence) rather than one file that
  mutates its `due` forward, so `wakeups/` stays a true history of what
  fired and when.
- *(since 1.2.0)* Declining an `event-proposal` entry uses the existing
  dismiss mechanics unchanged — no new `dismiss-reason` values were added for
  it (`not-now`, `not-this-person`, `not-this-signal-type`,
  `already-handled` all remain sensible choices). The dismissed wake-up file
  is itself the record: no retry, no second artifact. After a decline,
  attention suppresses re-proposal for the same (person, `signal-type:
  scheduling-intent`) pair for 30 days.
- *(since 1.2.0)* **Invariant:** `created-event-id` non-null requires both
  `confirmed-on` non-null and `kind: event-proposal`. No writer may set
  `created-event-id` on a `kind: nudge` entry or on an entry that has not
  recorded `confirmed-on`; the connector create itself only happens after
  that confirmation is recorded.
- **Versioning:** `fired-on`, `dismiss-reason`, `acted-on`, `snooze-count`,
  and `signal-type` are all additive optional fields, so 1.0.0 → 1.1.0 is a
  minor bump per the `capture-event.md` precedent (widening without
  breaking). Existing `schema_version: 1.0.0` files remain valid as-is —
  readers must treat a missing `fired-on`/`dismiss-reason`/`acted-on`/
  `signal-type` as `null` and a missing `snooze-count` as `0`, matching the
  defaults above. A 1.1.0 writer dismissing an entry must set
  `dismiss-reason`; a 1.0.0 file that reaches `status: dismissed` without one
  is not itself invalid (it predates the field), but new dismissals should
  upgrade the file to 1.1.0 when writing the reason.
- **Versioning (1.2.0):** `kind`, `proposed-event`, `confirmed-on`, and
  `created-event-id` are additive optional fields, so 1.1.0 → 1.2.0 is
  another minor bump, same precedent. Existing `schema_version: 1.0.0` and
  `1.1.0` files remain valid as-is — readers must treat a missing `kind` as
  `nudge` and missing `proposed-event`/`confirmed-on`/`created-event-id` as
  `null`. Creation of `event-proposal` entries goes through
  `wakeup-add.sh`'s 1.2.0 event-proposal flags (see Writer / readers above);
  `confirmed-on` and `created-event-id` are never settable at creation, only
  by attention's lifecycle writes.

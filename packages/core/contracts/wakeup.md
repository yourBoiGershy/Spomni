# Contract: wake-up

`schema_version: 1.0.0`

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
  wake-up entry (see `packages/core/package.md`).
- **Lifecycle (fire/snooze/dismiss — i.e. `status` transitions after
  creation):** sole writer is `packages/attention`.
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
| `people` | list of `[[slug]]` links | yes (≥1) | Who this wake-up is about. |
| `why` | string | yes | One line: the trigger. Never bare cadence — must name the reason (per `docs/PROJECT-CONTEXT.md`'s "nudges carry a trigger and ammunition"), e.g. `"job change: now leading partnerships at Meridian"`, not `"90 days since last contact"`. |
| `status` | enum | yes | One of: `pending`, `fired`, `snoozed`, `dismissed`. Set to `pending` at creation. |
| `origin` | enum | yes | One of: `user-ask`, `signal`, `standing`. `user-ask` = explicit reminder request; `signal` = produced by a `signal-event.md`; `standing` = recurring rhythm (e.g. birthdays). |
| `source-signal` | string or `null` | no (default `null`) | The `id` of the `wakeups/signals/<id>.md` this entry was promoted from. Required (non-null) when `origin: signal`. |

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
schema_version: 1.0.0
id: 2026-09-20-dana-whitfield
due: 2026-09-20
people: ["[[dana-whitfield]]"]
why: "Berlin move should be settling in — good moment to check in"
status: pending
origin: signal
source-signal: 20260829T090000Z-job-change-dana-whitfield
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

## Notes

- `status: snoozed` should carry a re-fire date; store it by re-writing
  `due` forward and leaving `status: pending` again rather than inventing a
  second date field — `snoozed` is a transient marker attention may use
  between the snooze action and the due-date rewrite, not a resting state a
  file sits in indefinitely.
- Birthdays and other recurring `standing` entries are re-created each cycle
  by attention (a fresh file per occurrence) rather than one file that
  mutates its `due` forward, so `wakeups/` stays a true history of what
  fired and when.

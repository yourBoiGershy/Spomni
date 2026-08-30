---
tier: skill
store: packages/ingestion/evals/cases/episode-split-multiday/before
expected: packages/ingestion/evals/cases/episode-split-multiday/expected
max-turns: 12
model: haiku
---
Act as ingestion's debrief filing skill, per
`packages/ingestion/skills/debrief/SKILL.md`. The current people-store is the
directory `./store` (contains `people/`, `interactions/`, `wakeups/`) — treat
it as the live store for this pass. This eval skips the `inbox/`/dedup-ledger
mechanics (no `data/ingestion/debrief-filed.log` bookkeeping needed here) —
just file the capture event below into `./store` exactly as a backfill pass
would. Do not run `build-index.sh` or `validate-store.sh` — this eval only
grades the `people/`/`interactions/`/`wakeups/` writes.

## The operative procedure (quoted from SKILL.md, apply it directly)

**§5b-episodes. Multi-day chat-message events — episode split**

Exception to 5b's "exactly one interaction file per event": a backfilled
`type: chat-message` event whose genuine `messages[]` (per the existing
bot/system-notice judgment used elsewhere in this skill) span **more than
one UTC calendar day** (by `timestamp`) files as **one interaction per
active day**, not one interaction total. A single-day chat-message event is
unaffected — it still files exactly per 5b, zero behavior change for
incremental sweeps.

1. **Group into episodes.** Bucket genuine messages by the UTC calendar
   date of `timestamp`. Every date with at least one genuine message is one
   episode.
2. **One interaction file per episode.** For each episode: `date` = that
   day; filename = `<that-date>-<primary-person-slug>.md` (same primary-
   slug rule as 5b); `people` = the participants active in that day's
   messages (same resolution as 5b); `source-capture` = the one originating
   capture-event `id`, the same value on every episode from this event (the
   interaction contract allows many interactions to cite one capture).
   `## Summary` covers only that day's exchange, not the whole thread.
3. **Facts/commitments attach to their own day.** A fact, commitment, or
   reminder-ask lands on the episode (day) where it was actually stated,
   not lumped into one summary interaction.
4. **Person-file effects run once, anchored to the latest episode.** §5a's
   `last-touch` update and any open-thread/needs-confirmation logic for
   this event run a single time across the whole event, using the latest
   episode's date as the effective touch date — not once per episode.
5. **Same-day collision.** If an interaction file for that date + primary
   slug already exists (e.g. two separate chats with the same person on one
   day), append a numeric suffix to the filename: `-2`, `-3`, etc., per
   5b's existing same-day duplicate convention.
6. **Explosion guard.** A chat with more than 20 active days in the backfill
   window still gets one interaction file per active day — frequency
   fidelity is the point of this rule — but keep each episode's `##
   Summary` to 1-2 sentences rather than the fuller prose a normal
   single-event summary gets, so a long-running chat doesn't balloon filing
   time.

**§5a Person file updates (per matched person).** *New facts*: every new
factual claim about that person surfaced by the debrief becomes a new
bullet appended to `## Facts`, tagged `**[told-by-user]**`, with a trailing
capture date in parens `(YYYY-MM-DD)` — the date the fact was actually
stated, not "today". `last-touch`: per §5b-episodes point 4 above, set once
across the whole event to the latest episode's date.

**§5b The interaction file shape**, per `packages/core/contracts/
interaction.md` — no extra frontmatter fields, no extra body sections, no
`id:` frontmatter key (the filename stem *is* the id), and `people` is a
frontmatter field (a `["[[slug]]", ...]` list), never a body section:

```
---
schema_version: 1.0.0
date: <YYYY-MM-DD>
people: ["[[slug]]"]
calendar-event: null
source-capture: <capture event id>
---

## Summary

<free prose, that day's exchange only>

## Commitments

<bullets, or _none_>
```

## The capture event to file

A `type: chat-message` Beeper single-chat backfill batch, body per
SKILL.md section 2's Beeper JSON shape. `participant-hints` names the one
person in this 1:1 chat; `title` names the chat, not a person. The
`messages[]` below are ordered oldest-first by `timestamp` and span three
non-contiguous UTC calendar days (2026-07-01, then a gap, 2026-07-03, then
another gap, then 2026-07-05) — every message is a genuine, non-bot chat
message:

```
---
schema_version: 1.2.0
id: 20260706T080000Z-beeper-in-whatsapp-ep7f
source: beeper-in/whatsapp
captured_at: 2026-07-06T08:00:00Z
type: chat-message
participant-hints:
  - "Erin Fixture"
---
{
  "chatID": "fixture-chat-erin",
  "accountID": "whatsapp",
  "network": "whatsapp",
  "title": "Erin Fixture",
  "chatType": "single",
  "messages": [
    {
      "id": "ep-msg-1",
      "senderID": "@erin-fixture",
      "senderName": "Erin Fixture",
      "timestamp": "2026-07-01T09:15:00.000Z",
      "isSender": false,
      "text": "hey! random update, I just adopted a golden retriever puppy and I'm naming him Waffles :)"
    },
    {
      "id": "ep-msg-2",
      "senderID": "@me-fixture",
      "senderName": "Me",
      "timestamp": "2026-07-01T09:17:00.000Z",
      "isSender": true,
      "text": "omg no way, send pics of Waffles!!"
    },
    {
      "id": "ep-msg-3",
      "senderID": "@erin-fixture",
      "senderName": "Erin Fixture",
      "timestamp": "2026-07-03T14:00:00.000Z",
      "isSender": false,
      "text": "we should go kayaking on the river sometime this month"
    },
    {
      "id": "ep-msg-4",
      "senderID": "@me-fixture",
      "senderName": "Me",
      "timestamp": "2026-07-03T14:02:00.000Z",
      "isSender": true,
      "text": "yes let's do it, kayaking sounds so fun"
    },
    {
      "id": "ep-msg-5",
      "senderID": "@erin-fixture",
      "senderName": "Erin Fixture",
      "timestamp": "2026-07-05T19:30:00.000Z",
      "isSender": false,
      "text": "btw I'll send you my grandma's pasta recipe, you're going to love it"
    },
    {
      "id": "ep-msg-6",
      "senderID": "@me-fixture",
      "senderName": "Me",
      "timestamp": "2026-07-05T19:31:00.000Z",
      "isSender": true,
      "text": "can't wait, thank you!"
    }
  ]
}
```

Resolve "Erin Fixture" against `./store` (an existing person,
`people/erin-fixture.md`). This event's genuine messages span three active
UTC days — 2026-07-01, 2026-07-03, and 2026-07-05 — with no messages at all
on 2026-07-02 or 2026-07-04, so those two days are not episodes and get no
interaction file. Per §5b-episodes, file **three** interaction files, one
per active day, all citing this one capture event's `id` as
`source-capture`:

- 2026-07-01: Erin's new puppy Waffles is a new fact about her — append it
  to her `## Facts`.
- 2026-07-03: a kayaking plan is discussed — summarize that day's exchange
  only.
- 2026-07-05: Erin's offer to send her pasta recipe is a commitment —
  record it in that episode's `## Commitments`, attributed to
  `[[erin-fixture]]`.

Per §5b-episodes point 4, run `people/erin-fixture.md`'s person-file effects
(here, just `last-touch` and the new Facts bullet) once for the whole
event, anchored to the latest episode's date, 2026-07-05 — not once per
episode.

---
tier: skill
store: packages/ingestion/tests/goldens/debrief/03-multi-person-meeting/before
expected: packages/ingestion/evals/cases/09-debrief-multi-person-chat/expected
max-turns: 12
model: haiku
---
Act as ingestion's debrief filing skill, per
`packages/ingestion/skills/debrief/SKILL.md`. The current people-store is the
directory `./store` (contains `people/`, `interactions/`, `wakeups/`) — treat
it as the live store for this pass. This eval skips the `inbox/`/dedup-ledger
mechanics (no `data/ingestion/debrief-filed.log` bookkeeping needed here) —
just file the capture event below into `./store` exactly as single-event
mode would. Do not run `build-index.sh` or `validate-store.sh` — this eval
only grades the `people/`/`interactions/`/`wakeups/` writes.

## The operative procedure (quoted from SKILL.md, apply it directly)

**§2 Parse the envelope.** `occurred_at`, when present, is preferred as the
interaction's `date` (truncated to `YYYY-MM-DD`) over `captured_at`. For a
`type: chat-message` event from a Beeper lane, the body's `messages[]`
(ordered oldest-first by `timestamp`) is the raw transcript: `text` from
non-`isSender` senders is what that participant said; `isSender: true`
entries are the user's own words. `title` names the chat, not a person.

**§3 Resolve participants.** Every `participant-hints` entry (case-
insensitively, whitespace-normalized) that exactly matches an existing
`people/<slug>.md`'s `name` field is an unambiguous single match — proceed
to file against that person. A multi-person event where each hint
independently resolves to its own single match files against **all** of
them, linked together in one interaction. A hint naming the chat/group
title (not an individual sender) is never a person to resolve.

**§5a Person file updates (per matched person, every matched person, not
just one).**
- *New facts*: every new factual claim about that person surfaced by the
  debrief becomes a new bullet appended to `## Facts`, tagged
  `**[told-by-user]**`, with a trailing capture date in parens
  `(YYYY-MM-DD)` — the interaction's date, not "today". Never delete or
  rewrite an existing `## Facts` bullet, even when a new fact supersedes it
  — append-only.
- *Frontmatter field updates*: when a new fact changes a field `person.md`
  tracks in frontmatter (`org`, `role`, `location`, `tier`, etc.), update
  that frontmatter field to the new value (current-state, not a journal) —
  the superseding fact bullet is still appended per the rule above, so the
  old value survives as history.
- *`last-touch`*: always set to the interaction's date, regardless of
  whether any fact/frontmatter changed, as long as the new date is not
  older than the value already on file.
- *Open threads*: a promise, loose end, or "ask about X next time" from the
  debrief becomes a new bullet under `## Open threads` (no provenance tag
  needed).
- Nothing invented: only file what the debrief actually states.

**§5b The interaction file.** Create exactly one new
`interactions/<id>.md`, conforming exactly to `packages/core/contracts/
interaction.md`'s shape — no extra frontmatter fields, no extra body
sections, no `id:` frontmatter key (the filename stem *is* the id, it is
never repeated inside the frontmatter), and **`people` is a frontmatter
field** (a `["[[slug]]", ...]` list), never a body section:

```
---
schema_version: 1.0.0
date: <YYYY-MM-DD>
people: ["[[slug-one]]", "[[slug-two]]"]
calendar-event: null
source-capture: <capture event id>
---

## Summary

<free prose>

## Commitments

<bullets, or _none_>
```

- `schema_version: 1.0.0` always — this is `interaction.md`'s own contract
  version, independent of whatever `schema_version` the incoming capture
  event declares (the capture event here is `1.2.0`; the interaction file
  this skill writes is always `1.0.0` per its own contract). Do not copy
  the capture event's `schema_version` into this file.
- `id`/filename: `<date>-<primary-person-slug>` — `<primary-person-slug>`
  is the first-listed hint in `participant-hints` for a multi-person event.
- `date`: the interaction date from §2. `calendar-event: null` (no linked
  calendar event here). `source-capture`: the triggering capture event's
  `id`.
- `people`: **every** matched person's `[[slug]]`, in match order — not
  just the primary one. Frontmatter field, not a body section.
- Exactly two body sections, in this order, and no others: `## Summary`
  (free prose, the filing engine's own structured retelling of the whole
  thread's substance — never a verbatim copy of the capture body) and
  `## Commitments` (one bullet per promise surfaced in the debrief, as
  `<owner>: <what> [by <date>]` where `<owner>` is `user` or the relevant
  person's `[[slug]]`. Include `[by <date>]` only when the debrief states
  or clearly implies a date; when it doesn't, omit the bracketed clause
  entirely and instead trail plain prose like `(no date given)`. A
  commitment is any explicit promise or clearly stated intention by either
  party to do something — a soft, no-rush framing still counts (e.g.
  someone offering to handle a follow-up task later, even with no fixed
  date, is a real stated commitment attributed to whoever offered it).
  `_none_` only if the debrief truly surfaces no commitments at all).

## The capture event to file

A `type: chat-message` Beeper group-chat batch event, body per SKILL.md
section 2's Beeper JSON shape:

```
---
schema_version: 1.2.0
id: 20260829T200000Z-beeper-in-whatsapp-9a41
source: beeper-in/whatsapp
captured_at: 2026-08-29T20:00:00Z
occurred_at: 2026-08-29T19:42:15Z
type: chat-message
participant-hints:
  - "Q3 Planning Crew"
  - "Nadia Okafor"
  - "Sam Vartan"
---
{
  "chatID": "!q3-planning-crew:example.org",
  "accountID": "whatsapp",
  "network": "whatsapp",
  "title": "Q3 Planning Crew",
  "chatType": "group",
  "messages": [
    {
      "id": "msg-q3-001",
      "chatID": "!q3-planning-crew:example.org",
      "accountID": "whatsapp",
      "senderID": "+1-555-0101",
      "senderName": "Nadia Okafor",
      "timestamp": "2026-08-29T19:30:05.000Z",
      "sortKey": "0000000101",
      "type": "TEXT",
      "text": "hey both! quick update, I start as Director of Ops at Fernbank Logistics next monday, still processing that I actually got it",
      "isSender": false,
      "attachments": [],
      "linkedMessageID": null,
      "reactions": []
    },
    {
      "id": "msg-q3-002",
      "chatID": "!q3-planning-crew:example.org",
      "accountID": "whatsapp",
      "senderID": "user-self",
      "senderName": "Me",
      "timestamp": "2026-08-29T19:33:40.000Z",
      "sortKey": "0000000102",
      "type": "TEXT",
      "text": "no way, congrats Nadia!! we need to celebrate",
      "isSender": true,
      "attachments": [],
      "linkedMessageID": null,
      "reactions": []
    },
    {
      "id": "msg-q3-003",
      "chatID": "!q3-planning-crew:example.org",
      "accountID": "whatsapp",
      "senderID": "+1-555-0102",
      "senderName": "Sam Vartan",
      "timestamp": "2026-08-29T19:36:22.500Z",
      "sortKey": "0000000103",
      "type": "TEXT",
      "text": "congrats Nadia! also fyi I'm finally closing on the house in Riverdale next Friday, still can't believe it",
      "isSender": false,
      "attachments": [],
      "linkedMessageID": null,
      "reactions": []
    },
    {
      "id": "msg-q3-004",
      "chatID": "!q3-planning-crew:example.org",
      "accountID": "whatsapp",
      "senderID": "+1-555-0101",
      "senderName": "Nadia Okafor",
      "timestamp": "2026-08-29T19:42:15.250Z",
      "sortKey": "0000000104",
      "type": "TEXT",
      "text": "let's all get dinner once things settle, I'll pick a spot and send it here",
      "isSender": false,
      "attachments": [],
      "linkedMessageID": null,
      "reactions": []
    }
  ]
}
```

Resolve "Nadia Okafor" and "Sam Vartan" against `./store` (the chat's
`title`, "Q3 Planning Crew", names the conversation, not a person — do not
create a person file for it). File per the procedure above: both people get
updated (facts, frontmatter where a stated field changed, `last-touch`,
open threads as warranted), and one interaction file links both `[[slug]]`s,
filename `<date>-<primary-person-slug>` where Nadia (the first-listed hint)
is primary.

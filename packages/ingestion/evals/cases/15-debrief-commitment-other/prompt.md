---
tier: skill
store: packages/ingestion/tests/goldens/debrief/09-commitment-by-other-party/before
expected: packages/ingestion/tests/goldens/debrief/09-commitment-by-other-party/expected
max-turns: 8
model: haiku
---
Act as ingestion's debrief filing skill (`packages/ingestion/skills/debrief/
SKILL.md`), filing exactly one capture event into the store at `./store`
(contains `people/`, `wakeups/` — `interactions/` does not exist yet, create
it). Resolution is already done for you: the event's one participant hint,
"Jamie Oyelaran", matches the existing `./store/people/jamie-oyelaran.md` —
no ambiguity, no new person file. Skip `inbox/`/dedup-ledger bookkeeping (no
`data/ingestion/debrief-filed.log` write) and skip §5c's `build-index.sh`/
`validate-store.sh` calls — this eval only grades the `people/`/
`interactions/`/`wakeups/` writes themselves.

The capture event (a `type: chat-message` Beeper 1:1 WhatsApp batch event,
body per SKILL.md §2's Beeper JSON shape — `messages[]` ordered oldest-first;
`isSender: true` lines are the user's own words, every other sender's lines
are the other participant's):

```
---
schema_version: 1.2.0
id: 20260829T160500Z-beeper-in-whatsapp-9c31
source: beeper-in/whatsapp
captured_at: 2026-08-29T16:05:00Z
occurred_at: 2026-08-29T16:04:55Z
type: chat-message
participant-hints:
  - "Jamie Oyelaran"
---
{
  "chatID": "!jamie-whatsapp-chat:example.org",
  "accountID": "whatsapp",
  "network": "whatsapp",
  "title": "Jamie Oyelaran",
  "chatType": "single",
  "messages": [
    {
      "id": "msg-jamie-001",
      "chatID": "!jamie-whatsapp-chat:example.org",
      "accountID": "whatsapp",
      "senderID": "+15551234567",
      "senderName": "Jamie Oyelaran",
      "timestamp": "2026-08-29T16:03:10.000Z",
      "sortKey": "0000000001",
      "type": "TEXT",
      "text": "hey! quick update on the vendor contract",
      "isSender": false,
      "attachments": [],
      "linkedMessageID": null,
      "reactions": []
    },
    {
      "id": "msg-jamie-002",
      "chatID": "!jamie-whatsapp-chat:example.org",
      "accountID": "whatsapp",
      "senderID": "+15551234567",
      "senderName": "Jamie Oyelaran",
      "timestamp": "2026-08-29T16:04:40.000Z",
      "sortKey": "0000000002",
      "type": "TEXT",
      "text": "I'll get you the signed contract by next monday, sept 7th",
      "isSender": false,
      "attachments": [],
      "linkedMessageID": null,
      "reactions": []
    },
    {
      "id": "msg-jamie-003",
      "chatID": "!jamie-whatsapp-chat:example.org",
      "accountID": "whatsapp",
      "senderID": "+15550009999",
      "senderName": "Me",
      "timestamp": "2026-08-29T16:04:55.000Z",
      "sortKey": "0000000003",
      "type": "TEXT",
      "text": "sounds great, thanks!",
      "isSender": true,
      "attachments": [],
      "linkedMessageID": null,
      "reactions": []
    }
  ]
}
```

Two writes only, per the two contract excerpts below. Follow both to the
letter — do not improvise on the filename or the frontmatter shape.

**1. `people/jamie-oyelaran.md`.** The thread states nothing new about Jamie
herself (no new fact, no frontmatter-tracked field changed) — per SKILL.md
§5a, that means the *only* change to this file is `last-touch: 2026-08-29`
(the interaction's date; `occurred_at`'s date takes priority over
`captured_at`'s per §2, and both fall on 2026-08-29 here anyway). Leave
every other field and section (`## Facts`, `## Open threads`, `## Personal
details`) byte-for-byte as they already are in
`./store/people/jamie-oyelaran.md`.

**2. `interactions/<id>.md` — new file.** Per SKILL.md §5b, the filename/id
is `<date>-<primary-person-slug>.md`: `<date>` is the interaction's date
(`2026-08-29`), `<primary-person-slug>` is the first (only, here) matched
person's slug (`jamie-oyelaran`) — **not** any descriptive suffix like a
topic or activity word. Worked example of the rule (a different case, same
shape): a lunch debrief with `[[dana-whitfield]]` on `2026-08-29` files as
`interactions/2026-08-29-dana-whitfield.md`, never
`2026-08-29-dana-whitfield-lunch.md`. So this event files as exactly
`interactions/2026-08-29-jamie-oyelaran.md`.

The file's frontmatter (`interaction.md` contract, `schema_version: 1.0.0`):

```
---
schema_version: 1.0.0
date: 2026-08-29
people: ["[[jamie-oyelaran]]"]
calendar-event: null
source-capture: 20260829T160500Z-beeper-in-whatsapp-9c31
---
```

Body: a `## Summary` section in your own prose (never a verbatim copy of
the capture body) retelling the WhatsApp exchange about the vendor
contract, then a `## Commitments` section. Per SKILL.md's "Commitment
extraction (detail)" section: for a `chat-message` event, `isSender: true`
lines are the user's own words; every other sender's lines can produce a
`[[slug]]:` commitment for that sender's matched person. Here, Jamie
(`isSender: false`) is the one who wrote "I'll get you the signed contract
by next monday, sept 7th" — the user's own line (`isSender: true`,
"sounds great, thanks!") commits to nothing — so the bullet is owned by
`[[jamie-oyelaran]]`, not `user`. Jamie's message names an explicit
calendar date inside relative phrasing ("by next monday, sept 7th") — per
the date-capture rule, use that stated date directly: `[by 2026-09-07]`.
The bullet:

```
## Commitments

- [[jamie-oyelaran]]: send the signed vendor contract [by 2026-09-07]
```

Do not create, delete, or modify any file other than
`people/jamie-oyelaran.md` (as scoped above) and the one new
`interactions/2026-08-29-jamie-oyelaran.md` file. Do not touch `wakeups/`.

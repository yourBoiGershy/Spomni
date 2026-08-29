---
tier: skill
store: packages/ingestion/tests/goldens/debrief/03-multi-person-meeting/before
expected: packages/ingestion/tests/goldens/debrief/03-multi-person-meeting/expected
max-turns: 8
model: haiku
---
Act as ingestion's debrief filing skill, per
`packages/ingestion/skills/debrief/SKILL.md`. The current people-store is the
directory `./store` (contains `people/`, `interactions/`, `wakeups/`) — treat
it as the live store for this pass. This eval skips the `inbox/`/dedup-ledger
mechanics (no `data/ingestion/debrief-filed.log` bookkeeping needed here) —
just file the capture event below into `./store` exactly as single-event
mode would.

The capture event (a `type: chat-message` Beeper group-chat batch event,
body per SKILL.md section 2's Beeper JSON shape):

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
create a person file for it). File per SKILL.md sections 2-5: both people
get updated, and one interaction file links both `[[slug]]`s, filename
`<date>-<primary-person-slug>` where Nadia (the first-listed hint) is
primary. Do not run `build-index.sh` or `validate-store.sh` — this eval only
grades the `people/`/`interactions/`/`wakeups/` writes.

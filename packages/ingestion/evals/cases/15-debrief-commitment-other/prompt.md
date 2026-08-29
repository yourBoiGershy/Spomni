---
tier: skill
store: packages/ingestion/tests/goldens/debrief/09-commitment-by-other-party/before
expected: packages/ingestion/tests/goldens/debrief/09-commitment-by-other-party/expected
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

The capture event (a `type: chat-message` Beeper 1:1 WhatsApp batch event,
body per SKILL.md section 2's Beeper JSON shape):

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

Resolve "Jamie Oyelaran" against `./store`, then file per SKILL.md sections
2-5 and the "Commitment extraction (detail)" section: Jamie (not
`isSender: true`) is the one who committed, so the interaction's
`## Commitments` bullet is owned by `[[jamie-oyelaran]]`, reads
`send the signed vendor contract`, with the explicit stated date
`[by 2026-09-07]`. Do not run `build-index.sh` or `validate-store.sh` — this
eval only grades the `people/`/`interactions/`/`wakeups/` writes.

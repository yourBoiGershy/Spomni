# 11 — Messaging connectors: Composio coverage research

**Status:** research complete, pre-plan. No implementation yet.
**Stream:** `stream-connectors` (worktree `relationship-agent-worktrees/connectors`).
**Question:** can WhatsApp, Messenger, Discord, Instagram DMs, and phone SMS be
onboarded as capture lanes through the Composio hub (DECISIONS `composio-hub`,
`composio-dual-transport`)?

Verified 2026-08-29 against the live Composio catalog (claude.ai connector,
`COMPOSIO_SEARCH_TOOLS`, both auto and direct tool-search strategies). None of the
toolkits below are connected on the account yet (only gmail, googlecalendar, linkedin).

## The structural finding

Every Meta/messaging toolkit Composio carries is built on the **business-side APIs**,
because that is all the platforms offer. There is no API anywhere — Composio or
otherwise — that reads a *personal* WhatsApp, Messenger, or Discord DM inbox. This is
a platform constraint, not a Composio gap.

## Per-channel findings

### WhatsApp — no acceptable path
- `whatsapp` toolkit = WhatsApp **Business** Cloud API only ("not WhatsApp Personal
  accounts"). Send-oriented (`WHATSAPP_SEND_MESSAGE/_MEDIA/_TEMPLATE`,
  `WHATSAPP_GET_PHONE_NUMBERS`); no history-read tools; inbound requires webhooks.
- Third-party proxies: `kapso` (WhatsApp Business platform; genuinely has
  `KAPSO_LIST_CONVERSATIONS` + `KAPSO_LIST_MESSAGES` history reads) and `mocean`
  (send + incoming webhook). Both still require a **WhatsApp Business number** — a
  separate identity from the user's personal WhatsApp, so the user's real
  conversations never flow through it.
- Verdict: **skip.** A Business number changes the user's sending identity (bad fit
  for authentic relationship maintenance) and captures nothing historical. Manual
  chat-export files are the only personal-account bridge; revisit only if that pain
  is wanted.

### Messenger — Pages only
- `facebook` toolkit reads a **Page inbox** (`FACEBOOK_GET_PAGE_CONVERSATIONS`,
  `FACEBOOK_GET_CONVERSATION_MESSAGES`) and sends as the Page (24-hour response
  window / message tags). Explicitly "not Facebook Personal accounts".
- Verdict: **only useful if the user operates a Facebook Page** whose inbox carries
  real relationships. Personal Messenger threads are unreachable by design.

### Discord — servers yes, DMs no
- Two toolkits: `discord` (user OAuth — identity + `DISCORD_LIST_MY_GUILDS`, no
  message access) and `discordbot` (bot token — `DISCORDBOT_LIST_GUILD_CHANNELS`,
  `DISCORDBOT_LIST_MESSAGES`, archived threads; can open DM channels and send *as
  the bot*).
- Discord's API has no user-DM read surface at all; user-token automation
  ("self-botting") is ToS-banned — same liability class `tos-clean-signals-only`
  exists to avoid.
- Verdict: **viable for guilds the user can install a bot into** (communities they
  run or admin). Personal DM history is out.

### Instagram — the one real Composio win
- `instagram` toolkit has genuine DM reads: `INSTAGRAM_LIST_ALL_CONVERSATIONS`,
  `INSTAGRAM_LIST_ALL_MESSAGES`, `INSTAGRAM_GET_CONVERSATION`, plus windowed send.
- Requires a **Business or Creator account** (personal accounts return empty
  results) and Meta messaging permissions; connection rides the Facebook Graph
  linkage. Switching a personal IG account to Creator is free and reversible.
- Verdict: **best candidate among the four named platforms** — if the user is
  willing to flip their account to Creator. Known quirks are catalogued (double-
  nested `data.data`, cursor reuse 500s, some thread IDs 400 with subcode 33).

### Phone SMS — not a Composio problem
- Composio's SMS toolkits (`saperly` "phone carrier for AI agents", `mocean`,
  Twilio-class) all **provision a new agent-owned number**. Nothing reads the
  user's own phone's messages.
- The right lane is the one `composio-hub` already anticipated in its revisit
  clause: **local macOS Messages bridge**. `~/Library/Messages/chat.db` (sqlite,
  read-only access) holds the full iMessage history, and SMS too when Text Message
  Forwarding is on. Perfect doctrine fit: other people's data stays local, zero
  new vendors, no ToS exposure. Cost: the reading process needs Full Disk Access
  granted once.
- Verdict: **build local, skip Composio entirely for this lane.**

## Recommended priority (pending user call)

1. **iMessage/SMS via local `chat.db`** — highest relationship-signal density of
   everything surveyed, purest doctrine fit. Local connector, not Composio.
2. **Instagram DMs** via Composio `instagram` — needs the user to switch to a
   Creator account and link it.
3. **Discord guilds** via Composio `discordbot` — only if the user has servers
   worth capturing; DMs impossible.
4. **Messenger** — only if a user-operated Page exists; otherwise skip.
5. **WhatsApp** — skip; no personal-account path exists on any vendor.

## Decisions this would touch

- `composio-hub` stands: Instagram/Discord ride the existing hub; the iMessage
  bridge exercises its revisit clause (local lane where no Composio path exists)
  and deserves its own DECISIONS entry when built.
- `tos-clean-signals-only` stands: everything above uses official APIs or the
  user's own local device data; Discord self-botting explicitly rejected.
- `draft-never-send` stands: all send-capable tools listed here are for the
  draft→human-send flow only; capture lanes are read-only.

# Beeper Client API — ground truth

Verified 2026-08-29 against a live instance + OpenAPI 5.0.0. This is the source
this package implements from; do not re-research — see
`docs/plans/2026-08-29-13-beeper-capture.md` for how it was gathered.

## Auth

`Authorization: Bearer <token>` header on every request. Missing/invalid token →
`401`. The token is user-created in Beeper Settings → Integrations → Approved
connections, and lives at `data/connectors/beeper-in/token` (single line,
chmod 600) — never in this repo.

## Endpoints

### `GET /v1/info`

Server discovery/liveness check. Used as the sweep's first reachability probe.

### `GET /v1/accounts`

Returns an array of Account objects:

| Field | Notes |
|---|---|
| `accountID` | routing key, e.g. `matrix`, `local-whatsapp_ba_…` |
| `network` | optional human-readable network name |
| `status` | enum incl. `connected`, `backfilling`, `disconnected` |
| `user` | account-owner user info |

### `GET /v1/chats?accountIDs=…&cursor=…&direction=before|after`

All chats sorted by last activity, most recent first. `accountIDs` is a
**repeatable** query param (`accountIDs=a&accountIDs=b`) limiting results to
specific accounts. Output shape mirrors ListMessagesOutput
(`{ items, hasMore, oldestCursor, newestCursor }`).

Chat object:

| Field | Notes |
|---|---|
| `id` | opaque string; may contain `!` and `:` — URL-encode when used in a path |
| `accountID` | owning account |
| `network` | human network name |
| `title` | chat title |
| `type` | `single` \| `group` |
| `participants.items[]` | array of User (`name`, `ids`) |
| `lastActivity` | ISO 8601 with ms + tz |
| `unreadCount` | integer |

### `GET /v1/chats/{chatID}/messages?cursor=…&direction=before|after`

Returns `{ items: Message[], hasMore, oldestCursor, newestCursor }`.
`direction=after` combined with a saved cursor fetches **newer** messages — this
is the catch-up primitive the sweep's cursor ledger relies on.

Message object:

| Field | Notes |
|---|---|
| `id` | opaque string |
| `chatID` | owning chat |
| `accountID` | owning account |
| `senderID` | opaque sender id |
| `senderName` | human sender name |
| `timestamp` | ISO 8601 with tz + ms |
| `sortKey` | opaque sort key |
| `type` | `TEXT` / `IMAGE` / … / `REACTION` |
| `text` | message body text |
| `isSender` | `true` when the authenticated user sent it |
| `attachments` | media as `mxc://` URLs |
| `linkedMessageID` | e.g. reply-to |
| `reactions` | reaction list |

## Cursors and IDs

Opaque strings, never parsed or constructed by this package — only stored and
replayed verbatim. Chat IDs contain `!` and `:`; URL-encode them when building a
`/v1/chats/{chatID}/messages` path.

## Timestamp rule

Beeper timestamps (`lastActivity`, `Message.timestamp`) are ISO 8601 with
timezone and milliseconds — kept verbatim in the capture event body. The
capture-event contract's `captured_at` frontmatter field requires
`YYYY-MM-DDTHH:MM:SSZ` and means *when the connector captured it*, not when the
message happened — the sweep sets it from the run's own
`date -u +%Y-%m-%dT%H:%M:%SZ`, never derived from a Beeper timestamp.

## Allowed call surface (read-only enforcement)

Only these paths may ever be requested by this package's scripts:
`/v1/info`, `/v1/accounts`, `/v1/chats`, `/v1/chats/*/messages`. No `-X`, no
`--data`/`-d`, no state-changing paths (`/read`, `/archive`, `/reminders`, send)
are permitted anywhere in this sub-package.

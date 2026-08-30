# package: connectors/beeper-out

version: 0.1.0

## Purpose

The one self-only send in the system: posts a rendered nudge (a wake-up
reminder addressed to the user themselves, never to another person) to the
user's own Beeper "Note to self" chat over the local Beeper Client API. This
is the single exception to `docs/DECISIONS.md#draft-never-send` —
`docs/DECISIONS.md#notify-self-is-a-send`: the recipient is always the user,
never another person, so it isn't outreach on the user's behalf, it's the
assistant reaching the user. Nothing in this package ever drafts or sends a
message to anyone other than the user who owns the store.

The destination chat id is never a caller-supplied default — it is resolved
solely from `<store-dir>/profile.md`'s `## Notify` section
(`packages/core/contracts/profile.md` 1.1.0). Any mismatch between a
`--chat-id` argument and the profile's resolved id, or a missing
`beeper_chat_id`, is a hard refuse (exit 4) with zero HTTP calls.

## Allowed call surface

Only these paths may ever be requested by this package's scripts, both
scoped to the single chat id resolved from `## Notify`:

- `POST /v1/chats/{chatID}/messages`
- `POST /v1/chats/{chatID}/reminders`

No other path, no read endpoints (this package writes, `beeper-in` reads —
strictly separate sub-packages), no bulk/broadcast calls.

## Provides

- `scripts/beeper-send.sh <store-dir> --text-file <f> [--chat-id <id>]
  [--reminder <iso>] [--private-data-root <p>]` — sends the given file's
  contents as a text message to the user's Beeper self-chat, with an
  optional companion reminder. Exit codes: `0` sent/skip-disabled/skip-no-
  token, `4` refuse (bad or missing chat id — never any HTTP call), `5`
  send-failed (transport or API error after a refusal check has already
  passed).
- `scripts/lib.sh` — `beeper_post <path> <json>`, the sole POST call site in
  this sub-package (mirrors `beeper-in`'s GET-only `beeper_get`).

## Consumes

- `profile@^1.1` (core) — `## Notify` section, read-only; this package never
  writes `profile.md`.
- `beeper-in`'s config/token resolution (`beeper_load_config`,
  `beeper_urlencode`), sourced read-only from
  `packages/connectors/beeper-in/scripts/lib.sh`. Same data dir
  (`<private-data-root>/data/connectors/beeper-in`), same skip-disabled /
  skip-no-token semantics as the beeper-in sweep. The token/config are never
  copied into this package's own files or state.

## Owned paths

`packages/connectors/beeper-out/**`. No runtime state of its own — no
cursors, no ledgers; every send is a one-shot POST against the profile-
resolved chat id.

## Built by

Plan 33 (`docs/plans/2026-08-30-33-nudge-delivery-beeper-self.md`).

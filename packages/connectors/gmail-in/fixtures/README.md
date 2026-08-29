# gmail-in fixtures — best-guess, corrected at Phase 3 live-verify

**Status: best-guess.** These fixtures are shaped on general Gmail API
resource conventions (`id`/`threadId`, `payload.headers[]` with
`name`/`value` pairs for `From`/`To`/`Cc`/`Subject`/`Date`, plus a flattened
`body_text` convenience field this package invented for its own use — the
real `mcp__claude_ai_Gmail__get_message` tool has **not** been called yet.
Every fixture carries a `_fixture_note` field saying so; that field is not
part of the real tool's response shape and must not be treated as one.

They exist so `gmail-sweep`'s parsing logic and
`packages/connectors/tests/run-capture-tests.sh` can be developed and run
offline before Gmail authentication happens in-session
(Plan 17, `docs/plans/`, 2026-08-29 direct-Google-lanes plan,
Phase 3 / U10).

## What Phase 3 (U10) must confirm and correct here

This is the live half of the Plan 14 caveat this plan closes — specifically:

- **`To`/`Cc` shape.** These fixtures assume a single comma-joined
  RFC 2822 header *string* per `To`/`Cc` (e.g.
  `"Dana Whitfield <dana.whitfield@example.com>, priya.nair@example.com"`
  when multiple recipients are present — see `email.json`'s single-recipient
  case for the simple form). The live tool may instead return a pre-split
  array of `{name, email}` objects, or something else entirely. Whichever it
  is, `SKILL.md` step 2.6 (participant hints) and step 2.2's parsing need to
  match the real shape — fix both the skill and these fixtures together once
  confirmed.
- **Body encoding.** Whether the message body arrives as plain text
  directly (as `body_text` here assumes) or requires decoding a
  MIME/base64-encoded payload part (the real Gmail API's `payload.parts[]`
  convention). If the latter, `SKILL.md` step 2.7 needs a decode step added.
- **Exact tool names and the search/list query parameter surface** — see
  `SKILL.md` step 0's `VERIFY-LIVE` markers; not a fixture-shape question,
  but resolved alongside these fixtures in the same live-verify pass.

## Synthetic PII only

Every name, address, and domain in these fixtures is invented
(`example.com`/`example.org`) or a real third-party notification domain
that carries no personal data of its own (`linkedin.com`, the notification
sender). No real person's data appears here, per
`docs/DECISIONS.md#other-peoples-data-stays-local` and the
`pii-egress-allowlist` decision.

## Files

- `email.json` — an ordinary email, multi-recipient (From + To + Cc).
- `email-voice-note.json` — self-sent, `[ra]`-tagged subject → drives
  `classify.sh`'s voice-note rule.
- `email-linkedin-notification.json` — From domain `linkedin.com` → drives
  `classify.sh`'s linkedin-notification rule.
- `malformed-junk.txt` — not a Gmail resource shape at all; drives
  quarantine-path test coverage.

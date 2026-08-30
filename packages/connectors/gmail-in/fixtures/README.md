# gmail-in fixtures — live-verified 2026-08-29

**Status: live-verified.** These fixtures are shaped on the actual
`mcp__claude_ai_Gmail__search_threads` / `get_thread` / `get_message`
response envelopes observed in-session (Plan 17, Phase 3 / U10) — camelCase
message fields (`id`, `threadId`, `date`, `sender`, `toRecipients`,
`ccRecipients`, `plaintextBody`, ...), not the snake_case shape general
Gmail API schema docs describe. Every fixture carries a `_fixture_note`
field explaining its provenance; that field is not part of the real tool's
response shape and must not be treated as one.

They exist so `gmail-sweep`'s parsing logic and
`packages/connectors/tests/run-capture-tests.sh` can be developed and run
offline (Plan 17, `docs/plans/`, 2026-08-29 direct-Google-lanes plan).

## Plan-14 caveat (gmail half) — CLOSED, live 2026-08-29

- **`To`/`Cc` shape — CLOSED.** Live messages carry `toRecipients`,
  `ccRecipients`, `bccRecipients` as **pre-split arrays** of bare-address
  strings, never a joined RFC-2822 header string. A field is **absent
  entirely** (not an empty array) when there are no recipients in that
  role. `SKILL.md` step 2's hint-building and body-parsing match this shape.
- **Body encoding — CLOSED.** `plaintextBody` (via `messageFormat:
  "PLAIN_TEXT"` on `get_thread`/`get_message`) is the readable message text
  directly — no MIME/base64 decoding, no `payload.parts[]` walk. The tool
  performs any HTML→text conversion server-side.
- **Display-name form — unobserved.** No sampled live message carried a
  `"Name <email>"` form on `sender` or any recipient field; every sampled
  address was bare. `SKILL.md`'s hint-building still passes elements
  through unmodified in case a display-name form appears on some message
  not yet sampled, but the norm on this lane is bare addresses.
- **`ccRecipients` element shape — schema-asserted, not observed.** No
  sampled live message carried a non-empty `ccRecipients` (or
  `bccRecipients`); `email.json`'s `ccRecipients` entry is asserted to have
  the same bare-address-string element form as the observed `toRecipients`
  arrays, per the tool's schema, but this specific field has not itself
  been seen non-empty on a live message.
- **Exact tool names and query parameter surface — CLOSED.** See
  `SKILL.md` step 0's verified tool set and step 1's `search_threads`
  query/pagination surface.

## Synthetic PII only

Every name, address, and domain in these fixtures is invented
(`example.com`/`example.org`) or a real third-party notification domain
that carries no personal data of its own (`linkedin.com`, the notification
sender). No real person's data appears here, per
`docs/DECISIONS.md#other-peoples-data-stays-local` and the
`pii-egress-allowlist` decision.

## Files

- `threads-page.json` — a `search_threads` response envelope
  (`nextPageToken` + string `resultCountEstimate` + `threads[]`, each with
  a `messages[]` summary array) covering all three message types below in
  one page.
- `email.json` — an ordinary email, multi-recipient (`sender` +
  `toRecipients` + `ccRecipients`) as a `get_thread`/`get_message`-style
  PLAIN_TEXT message object.
- `email-voice-note.json` — self-sent, `[ra]`-tagged subject → drives
  `classify.sh`'s voice-note rule.
- `email-linkedin-notification.json` — `sender` domain `linkedin.com` →
  drives `classify.sh`'s linkedin-notification rule.
- `malformed-junk.txt` — not a Gmail resource shape at all; drives
  quarantine-path test coverage.
- `get-thread-result.json` — a `get_thread`-style result (top-level object
  with an `id` and a `messages[]` array, each message carrying its own
  `plaintextBody`), distinct from `threads-page.json`'s `search_threads`
  envelope; drives `extract-email-body.sh` byte-exact extraction and
  absent-message-id test coverage.
- `email-no-recipients.json` — a `get_message`-style single message object
  with `toRecipients`/`ccRecipients`/`bccRecipients` absent entirely (the
  live-verified absent-not-empty shape for a no-recipients-in-role
  message); drives `extract-email-body.sh`'s no-crash coverage for that
  shape.

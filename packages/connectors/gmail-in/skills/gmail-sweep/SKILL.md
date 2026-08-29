---
name: gmail-sweep
description: Incremental, session-driven Gmail capture sweep — pulls new messages via the first-party claude.ai Gmail MCP connector, types them (email/voice-note/linkedin-notification), and lands each as a capture-event 1.2.0 file in inbox/ via normalize-capture.sh.
---

# Gmail sweep

Reads the user's own Gmail through the **in-session first-party Gmail
connector** (MCP tools called directly by the running Claude session, no
CLI, no shell-out) and writes one `inbox/` capture event per message via
`packages/connectors/scripts/normalize-capture.sh`. Read-only, hard
constraint — this skill never sends, drafts, modifies, labels, or deletes
anything (`docs/DECISIONS.md#draft-never-send`).

This skill is invokable as a single run. It does not schedule itself —
recurring invocation is Plan 19's job (chunk 19 wraps this skill in a
scheduler; nothing here assumes or manages a cadence).

## State this skill owns

Per `docs/data-layout.md`'s connector-runtime-state pattern:

```
data/connectors/gmail/checkpoint       one line: ISO 8601 Z timestamp of the
                                        newest message-Date successfully
                                        captured so far
data/connectors/gmail/processed.log    append-only dedup ledger, one Gmail
                                        messageId per line
```

Create the directory before first use:

```sh
mkdir -p data/connectors/gmail
```

## Step 0 — enumerate tools (mandatory, every run)

Before calling anything else, list the `mcp__claude_ai_Gmail__*` tools
actually available in this session. The tool names and field paths below are
**VERIFY-LIVE** — written best-guess against Gmail API resource conventions,
not yet confirmed against a live server (Plan 17, Phase 3 / U10 closes this).

If the live tool names or shapes differ materially from what's written here
— **stop and report** (name the discrepancy) rather than guessing or
improvising a call against a tool that doesn't exist as described. Do not
proceed past step 0 on a mismatch.

Expected tool set (VERIFY-LIVE):

- `mcp__claude_ai_Gmail__search_messages` (or `list_messages`) — query by
  date range / Gmail search syntax → list of message summaries (id,
  threadId at minimum). **VERIFY-LIVE** exact name and query parameter.
- `mcp__claude_ai_Gmail__get_message` — full message resource by id
  (headers, body). **VERIFY-LIVE** exact name and response shape (see
  fixtures for the best-guess shape assumed below).

**Banned by name, once enumerated** (read-only hard constraint — never call
these even to test): any tool whose name implies `send`, `draft`, `modify`,
`label`, `trash`, or `delete` a message (e.g. a hypothetical
`mcp__claude_ai_Gmail__send_message`, `..._modify_labels`,
`..._trash_message`). List every such tool found in step 0's enumeration
explicitly in this run's summary as "present but never called."

## Step 1 — determine the query window

Read `data/connectors/gmail/checkpoint`.

- **No checkpoint file (first run)**: window = last 30 days from now
  (UTC), per Plan 17's 30-day first-run bound.
- **Checkpoint present**: window = from the checkpoint timestamp (exclusive)
  to now (UTC).

Call the search/list tool (**VERIFY-LIVE** exact query syntax — best guess:
a Gmail search-style `after:YYYY/MM/DD` / date-range param) bounded to this
window, across the user's whole mailbox (no label/folder restriction unless
the live tool requires one).

## Step 2 — per-message loop

For each message summary returned by step 1, in any order (dedup makes
order safe):

1. **Dedup check.** If the message's Gmail `messageId` already appears in
   `data/connectors/gmail/processed.log`, skip it (count as deduped, do not
   re-fetch or re-normalize).
2. **Fetch full message.** Call the get-message tool (**VERIFY-LIVE**) to
   retrieve headers (`From`, `To`, `Cc`, `Subject`, `Date`) and the message
   body/text. **VERIFY-LIVE**: whether `To`/`Cc` come back as a single
   comma-joined header string (RFC 2822 form, e.g.
   `"Dana Whitfield <dana@example.com>, priya@example.com"`) or as a
   pre-split array of `{name, email}` objects — this is exactly the plan-14
   caveat U10 closes with live evidence. The best-guess fixtures in
   `../../fixtures/` assume the flattened-header-string form; if the live
   shape differs, this skill's parsing (and the fixtures) need a follow-up
   fix per U10.
3. **Compute the capture id up front** (needed before both the archive
   write and the `--id` flag): derive it the same way
   `normalize-capture.sh` would default it —
   `<captured_at-compact>-gmail-in-gmail-<4-hex-rand>` — where
   `captured_at` is this sweep run's own UTC time (step 4 below), so the id
   and archive path are stable and pre-known.
4. **Archive the raw tool output, unmodified.** Write the full get-message
   tool result (byte-for-byte JSON, no transformation) to
   `<store-dir>/archive/raw/<capture-id>.json` before normalizing.
5. **Classify the message.** Call:
   ```sh
   bash packages/connectors/gmail-in/scripts/classify.sh "<Subject>" "<From>"
   ```
   This prints one of `voice-note` / `linkedin-notification` / `email` —
   pass it as `--type`.
6. **Build participant hints.** One `--hint "Name <email>"` (as seen,
   exactly as the header presented it — no self-filtering, the user's own
   address is included if it appears) per: the `From` address, then every
   address in `To`, then every address in `Cc`. If a header entry has no
   display name, pass the bare address; if `To`/`Cc` is absent or empty on
   a given message, contribute no hints from that header.
7. **Build the body.** `Subject: <subject>` on the first line, one blank
   line, then the message text (plain-text body; **VERIFY-LIVE** whether
   the get-message tool returns plain text directly or requires decoding a
   MIME/base64 payload part — if the latter, decode before writing, since
   the normalizer's body must be the readable message text, not a raw MIME
   envelope).
8. **occurred_at** = the message's `Date` header, converted to ISO 8601 UTC
   (`YYYY-MM-DDTHH:MM:SSZ`).
9. **captured_at** = this sweep run's own UTC time (same value for every
   message processed in this run — the moment the sweep executed, not each
   message's fetch time).
10. **Normalize:**
    ```sh
    bash packages/connectors/scripts/normalize-capture.sh <store-dir> \
      --source gmail-in/gmail \
      --type <email|voice-note|linkedin-notification> \
      --captured-at <run-utc-now> \
      --occurred-at <message-date-iso> \
      --id <capture-id-from-step-3> \
      --hint "<From as seen>" \
      --hint "<To[0] as seen>" \
      ...(remaining To/Cc hints)... \
      --file <body-file>
    ```
11. **On exit 0** (event written to `inbox/`): append the `messageId` to
    `data/connectors/gmail/processed.log`. Count as captured.
12. **On exit 1** (quarantined by the normalizer, per `inbox/quarantine/` +
    reason file): do **not** append to `processed.log`, do **not** delete
    anything, do **not** abort the run — continue to the next message.
    Count as quarantined.

## Step 3 — advance the checkpoint

After the loop completes, write the newest successfully-captured message's
`Date` header (this run's max `occurred_at`) to
`data/connectors/gmail/checkpoint`, **only** if at least one message was
captured this run and only up to the last successfully-captured item —
never advance the checkpoint past a message that quarantined. If the run
captured nothing (nothing new, or everything quarantined), leave the
checkpoint untouched so the next run re-covers the same window.

## Step 4 — summary

Print an end-of-run count summary:

```
gmail-sweep: fetched=<N> captured=<N> deduped=<N> quarantined=<N>
```

Plus, if step 0 found any banned mutating tools present in the session,
list them explicitly ("present but never called").

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

**Live-verified 2026-08-29** (Plan 17, Phase 3 / U10): tool set, envelope
shape, and field names below are confirmed against a live session, not
best-guess. See `../../fixtures/README.md` for the closed caveats.

## State this skill owns

Per `docs/data-layout.md`'s connector-runtime-state pattern:

```
data/connectors/gmail/checkpoint       one line: ISO 8601 Z timestamp of the
                                        newest message-Date successfully
                                        captured so far, advanced only when
                                        a run's query window fully drains
                                        (see Step 1's page-budget rule)
data/connectors/gmail/processed.log    append-only dedup ledger, one Gmail
                                        message `id` per line
```

Create the directory before first use:

```sh
mkdir -p data/connectors/gmail
```

## Step 0 — enumerate tools (mandatory, every run)

Before calling anything else, list the `mcp__claude_ai_Gmail__*` tools
actually available in this session and confirm they match the verified set
below. If the live tool names or shapes differ materially from what's
written here — **stop and report** (name the discrepancy) rather than
guessing or improvising a call against a tool that doesn't exist as
described. Do not proceed past step 0 on a mismatch.

**Verified tool set (live-verified 2026-08-29):**

- `mcp__claude_ai_Gmail__search_threads` — THREAD-level search. Params:
  `query` (Gmail search syntax: `after:`/`before:`/`newer_than:`/`from:`/
  `in:` etc.), `pageSize` (default 20, **max 50**), `pageToken`, `view`
  (`THREAD_VIEW_MINIMAL` default), `includeTrash`. Empty result is `{}` —
  a valid no-results state, not an error.
- `mcp__claude_ai_Gmail__get_thread` — full thread by `threadId`; pass
  `messageFormat: "PLAIN_TEXT"` (returns `plaintextBody`, converts
  HTML→text, omits `htmlBody`). Drafts are omitted.
- `mcp__claude_ai_Gmail__get_message` — single message by `messageId`, same
  `messageFormat` enum.
- Also present, read-class, unused by this sweep: `list_labels`,
  `list_drafts`, `get_draft`.

**Not present on this surface:** any contacts/People tool (the
contacts-seed deferral in `package.md` is therefore permanent until the
surface changes, not a temporary VERIFY-LIVE gap). No message-level bulk
fetch beyond thread search exists either.

**Banned by name, once enumerated** (read-only hard constraint — never call
these even to test), confirmed present in a live session:
`send_message`, `reply`, `forward`, `create_draft`, `update_draft`,
`create_label`, `update_label`, `delete_label`, `label_message`,
`unlabel_message`, `label_thread`, `unlabel_thread`,
`update_message_labels`, `mark_message_spam`, `unmark_message_spam`,
`mark_thread_spam`, `unmark_thread_spam`, `trash_message`,
`untrash_message`, `trash_thread`, `untrash_thread`,
`apply_sensitive_message_label`, `apply_sensitive_thread_label`. List every
such tool found in step 0's enumeration explicitly in this run's summary as
"present but never called."

## Step 1 — determine the query window and page budget

Read `data/connectors/gmail/checkpoint`.

- **No checkpoint file (first run)**: window = last 30 days from now
  (UTC), per Plan 17's 30-day first-run bound — `after:YYYY/MM/DD` for that
  date.
- **Checkpoint present**: window = from the checkpoint timestamp (exclusive)
  to now (UTC) — `after:YYYY/MM/DD` for the checkpoint's date.

Call `search_threads` with `query` set to the `after:` bound above,
`pageSize` 50, no `pageToken` on the first call.

**Volume finding (live 2026-08-29):** thread search results transit session
context, and mailboxes can return hundreds of threads even for a short
window (~201 threads over 2 days observed on the verification account). A
full drain of a wide window is not always feasible in one run. This sweep
is therefore **page-budgeted per run**:

- Fetch pages via `pageToken` pagination, one page at a time, up to a
  per-run page budget (a fixed small number of pages, e.g. the caller's
  configured budget — treat as an explicit run parameter, not hardcoded in
  this file).
- Stop paging when either the budget is exhausted or a response has no
  `nextPageToken` (the window is fully drained).
- Track whether the window was **fully drained** this run (no
  `nextPageToken` left on the last page fetched) — this gates Step 3's
  checkpoint advance. A budget-truncated run (stopped because the budget
  ran out, `nextPageToken` still present) must **not** advance the
  checkpoint; the `processed.log` message-id ledger makes the next run's
  re-covering of the same window converge without re-capturing anything
  already landed.

## Step 2 — per-thread / per-message loop

Each `search_threads` page returns `threads[]`, each with an `id` and a
`messages[]` array of message summaries (camelCase fields — see below).
Flatten all message summaries across all fetched pages into one loop, in
any order (dedup makes order safe):

1. **Dedup check.** If the message's `id` already appears in
   `data/connectors/gmail/processed.log`, skip it (count as deduped, do not
   re-fetch or re-normalize).
2. **Fetch full message.** Call `get_thread` with `messageFormat:
   "PLAIN_TEXT"` for the message's `threadId` (or `get_message` with the
   message's `id` if only a single message is needed) to retrieve the full
   message object. Live camelCase fields on the message object:
   - `id`, `threadId` — message and thread ids.
   - `date` — **already ISO 8601 `Z` UTC**; no conversion needed.
   - `sender` — bare address string (e.g. `"noreply@beeper.com"`). No
     display names observed live on this lane; a `"Name <email>"` form is
     possible-but-unobserved — treat as a hint line either way.
   - `toRecipients` / `ccRecipients` / `bccRecipients` — **pre-split
     arrays** of bare-address strings, **absent entirely** when there are
     no recipients in that role (not an empty array). This closes the
     plan-14 caveat: there is no joined RFC-2822 header string to parse.
   - `plaintextBody` — the readable message text directly. No MIME or
     base64 decoding — `messageFormat: "PLAIN_TEXT"` has already done the
     HTML→text conversion server-side.
   - `subject`, `labelIds`, `snippet`, `historyId`, `internalDate`,
     `sizeEstimate` also present; not used by this sweep beyond `subject`.
3. **Compute the capture id up front** (needed before both the archive
   write and the `--id` flag): derive it the same way
   `normalize-capture.sh` would default it —
   `<captured_at-compact>-gmail-in-gmail-<4-hex-rand>` — where
   `captured_at` is this sweep run's own UTC time (step 4 below), so the id
   and archive path are stable and pre-known.
4. **Archive the raw tool output, unmodified.** Write the full `get_thread`
   / `get_message` tool result (byte-for-byte JSON, no transformation) to
   `<store-dir>/archive/raw/<capture-id>.json` before normalizing.
5. **Classify the message.** Call:
   ```sh
   bash packages/connectors/gmail-in/scripts/classify.sh "<subject>" "<sender>"
   ```
   This prints one of `voice-note` / `linkedin-notification` / `email` —
   pass it as `--type`.
6. **Build participant hints.** One `--hint "<address>"` (as seen — bare
   address on this lane, display-name form passed through unmodified if it
   ever appears) per: the `sender` address, then every address in
   `toRecipients`, then every address in `ccRecipients`. No self-filtering
   — the user's own address is included if it appears. If
   `toRecipients`/`ccRecipients` is absent on a given message, contribute
   no hints from that field. `bccRecipients` is not used for hints (a
   `bcc` recipient would not have been visible to the sender in a real
   message; this sweep still only reads what the tool returns for the
   authenticated user's own view).
7. **Build the body.** `Subject: <subject>` on the first line, one blank
   line, then `plaintextBody` verbatim.
8. **occurred_at** = the message's `date` field — already ISO 8601 UTC,
   used as-is.
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
      --hint "<sender>" \
      --hint "<toRecipients[0]>" \
      ...(remaining toRecipients/ccRecipients hints)... \
      --file <body-file>
    ```
11. **On exit 0** (event written to `inbox/`): append the message `id` to
    `data/connectors/gmail/processed.log`. Count as captured.
12. **On exit 1** (quarantined by the normalizer, per `inbox/quarantine/` +
    reason file): do **not** append to `processed.log`, do **not** delete
    anything, do **not** abort the run — continue to the next message.
    Count as quarantined.

## Step 3 — advance the checkpoint

After the loop completes, write the newest successfully-captured message's
`date` field (this run's max `occurred_at`) to
`data/connectors/gmail/checkpoint`, **only if both**:

- at least one message was captured this run, and only up to the last
  successfully-captured item — never advance the checkpoint past a message
  that quarantined; and
- the query window was **fully drained** this run per Step 1's page-budget
  rule (no `nextPageToken` left on the last page fetched).

If the run captured nothing, or the window was budget-truncated
(`nextPageToken` still present), leave the checkpoint untouched so the next
run re-covers the same window — the `processed.log` ledger makes repeated
runs converge without re-capturing anything already landed.

## Step 4 — summary

Print an end-of-run count summary:

```
gmail-sweep: fetched=<N> captured=<N> deduped=<N> quarantined=<N> pages=<N> drained=<yes|no>
```

Plus, list the banned mutating tools found present in step 0's enumeration
("present but never called").

## Backfill mode (one-shot, explicit invocation only)

Backfill is a **separate, explicitly-invoked mode** of this same skill — "run
gmail-sweep in backfill mode" — for a one-shot deep sweep over a wider
historical window during onboarding. It is **never** implied by a normal
sweep run, and it is **never** a `sync-lanes` scheduler row (chunk 19); it
only runs when a human or an onboarding flow says so explicitly.

**State backfill mode owns** (isolated from, and never overlapping with,
"State this skill owns" above):

```
data/connectors/gmail/backfill-checkpoint     one line: ISO 8601 Z timestamp
                                               of the newest message-Date
                                               successfully captured by a
                                               backfill run so far, advanced
                                               only when a backfill run's
                                               window fully drains (same rule
                                               as Step 1/Step 3, applied to
                                               this file)
data/connectors/gmail/backfill-processed.log  append-only dedup ledger for
                                               backfill runs, one Gmail
                                               message `id` per line
```

**Hard isolation rule:** a backfill run never reads, writes, or advances the
incremental `data/connectors/gmail/checkpoint` or
`data/connectors/gmail/processed.log` files — those are Step 1/Step 3's
files, owned exclusively by normal incremental sweeps. Backfill writes only
to `backfill-checkpoint` and `backfill-processed.log`.

**Window resolution.** Instead of Step 1's checkpoint-based window, resolve
the backfill window by running:

```sh
bash packages/connectors/scripts/resolve-backfill-window.sh <data-dir>
```

This prints `window_start_iso<TAB>window_months` on stdout, or exits
non-zero with a stderr message on malformed config — on a non-zero exit,
**abort the backfill run** and show that stderr verbatim; do not fall back
to any default window. On success, query with `after:<window-start-date>`
and `before:<today's-date>` (both derived from the resolved window start and
the run's own UTC "now", same `search_threads` call shape as Step 1).

**Dedup is read-only against both ledgers.** Before fetching a message
(Step 2.1's dedup check), skip it if its `id` appears in **either**
`data/connectors/gmail/processed.log` (incremental) **or**
`data/connectors/gmail/backfill-processed.log` (backfill) — this prevents
re-capturing messages an incremental sweep already landed. On successful
capture (Step 2.11), append the `id` only to `backfill-processed.log`,
never to `processed.log`.

**Everything else is identical to the incremental sweep and is not
re-specified here** — apply Step 0's tool enumeration, Step 1's page budget
and drain tracking, Step 2's per-message loop (fetch, archive, classify,
hints, body, normalize, quarantine-continue), and Step 3's checkpoint-advance
rule (≥1 message captured this run AND the window fully drained) verbatim,
substituting `backfill-checkpoint` / `backfill-processed.log` for
`checkpoint` / `processed.log` throughout. Step 4's summary line applies
unchanged, prefixed `gmail-sweep (backfill):` instead of `gmail-sweep:`.

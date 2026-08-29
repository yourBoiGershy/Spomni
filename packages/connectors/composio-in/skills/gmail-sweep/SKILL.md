---
name: gmail-sweep
description: Pull new Gmail into the store's inbox/ as capture events via the user's Composio CLI, idempotently. Includes a one-shot contacts-seed flow using the Gmail toolkit's People tools.
---

# Gmail sweep

Reads the user's own Gmail through the linked Composio `gmail` toolkit and lands each
new message as a capture event in `<store-dir>/inbox/`, per
`packages/core/contracts/capture-event.md`. Read-only against the account — this skill
never calls a send/draft/modify tool, per `docs/DECISIONS.md#draft-never-send`.

Assumes `composio login` / `composio link` has already been run out-of-band for the
`gmail` toolkit (an ACTIVE session). This skill does not manage auth.

## State this skill owns

Per `docs/data-layout.md` ("Connector runtime state"), all of it lives in
`data/connectors/gmail/` — connector-local, never in the shared store, never read by
any other package:

- `data/connectors/gmail/processed.log` — dedup ledger, one Gmail `messageId` per
  line, appended after each message is successfully normalized into `inbox/`.
- `data/connectors/gmail/checkpoint` — a single ISO 8601 UTC timestamp, the
  `messageTimestamp` of the newest message successfully processed in the last run.
  Used to bound the next run's query.

Create the directory before first use:

```sh
mkdir -p data/connectors/gmail
```

## 1. Query strategy

Fetch via `GMAIL_FETCH_EMAILS` (verified with `composio tools info GMAIL_FETCH_EMAILS`
on 2026-08-29 — tags `readOnlyHint`, no side effects).

**First run** (no checkpoint file yet): bound the query to the last 30 days so the
initial sweep is not unbounded.

```sh
CHECKPOINT_FILE="data/connectors/gmail/checkpoint"
if [ -f "$CHECKPOINT_FILE" ]; then
  SINCE_DATE="$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$(cat "$CHECKPOINT_FILE")" '+%Y/%m/%d' 2>/dev/null \
    || date -u -d "$(cat "$CHECKPOINT_FILE")" '+%Y/%m/%d')"
else
  SINCE_DATE="$(date -u -v-30d '+%Y/%m/%d' 2>/dev/null || date -u -d '30 days ago' '+%Y/%m/%d')"
fi

composio execute GMAIL_FETCH_EMAILS -d "{
  \"query\": \"after:${SINCE_DATE}\",
  \"max_results\": 100,
  \"verbose\": true,
  \"include_payload\": true
}"
```

Notes on `GMAIL_FETCH_EMAILS`'s params (per `composio tools info GMAIL_FETCH_EMAILS`):

- `query` uses Gmail's `after:YYYY/MM/DD` operator, which evaluates whole UTC calendar
  days — the checkpoint's day may be re-fetched; that is fine, the ledger dedups on
  `messageId` regardless.
- `max_results` caps at 500/page. If `resultSizeEstimate` suggests more than one page
  is needed, follow `nextPageToken` in a loop until absent — do not stop early on
  `resultSizeEstimate` (the schema explicitly warns it is approximate).
- `verbose: true` + `include_payload: true` is required to get message bodies
  (`messageText` in this package's fixture shape); the faster `verbose: false` path
  only guarantees subject/sender/recipient/time/labels, not body text this skill needs
  to capture verbatim.
- After a full sweep, set the checkpoint to the max `messageTimestamp` seen across all
  successfully processed messages this run (only advance it past messages that made it
  into `inbox/` — see step 5).

## 2. Result handling — inline vs file-backed

Per `packages/connectors/composio-in/package.md`'s CLI call convention, `composio
execute` returns either:

```json
{ "successful": true, "data": { "messages": [...] }, "error": null, "logId": "..." }
```

or, for large results:

```json
{ "storedInFile": true, "outputFilePath": "/tmp/composio-output-xxxx.json" }
```

(Live-verified 2026-08-29: `composio execute GMAIL_FETCH_EMAILS -d '{ max_results: 1 }'`
already returned file-backed output at ~10k tokens — expect the file-backed shape by
default for any non-trivial `max_results`.)

Handle both:

```sh
RAW="$(composio execute GMAIL_FETCH_EMAILS -d "$QUERY_JSON")"

if printf '%s' "$RAW" | jq -e '.storedInFile == true' >/dev/null 2>&1; then
  OUTPUT_FILE="$(printf '%s' "$RAW" | jq -r '.outputFilePath')"
  RESULT_JSON="$(cat "$OUTPUT_FILE")"
else
  RESULT_JSON="$RAW"
fi

MESSAGES="$(printf '%s' "$RESULT_JSON" | jq -c '.data.messages // [] | .[]')"
```

If `.data.messages` is absent or empty, that is a valid no-results state — end the
sweep run without error (nothing to process, checkpoint stays where it is).

## 3. Per-message dedup

For each message object in `MESSAGES`:

```sh
MSG_ID="$(printf '%s' "$MESSAGE" | jq -r '.messageId')"

if grep -qxF "$MSG_ID" "data/connectors/gmail/processed.log" 2>/dev/null; then
  continue  # already seen — skip, do not re-normalize
fi
```

Only append `MSG_ID` to `processed.log` **after** `normalize-capture.sh` exits 0 for
that message (step 5) — a message that fails normalization must not be marked
processed, so a later retry (e.g. after a normalizer fix) can pick it up again.

```sh
printf '%s\n' "$MSG_ID" >> "data/connectors/gmail/processed.log"
```

## 4. Typing (minimal — deep classification is a later chunk's job)

Per plan 08, this sweep does only minimal typing:

- `voice-note` — the message `subject` contains the literal `[ra]` tag (case-sensitive,
  matches `docs/DECISIONS.md#gmail-first-capture`'s "subject-tagged self-email"
  convention, e.g. `"[ra] debrief: lunch with tom park"`).
- `other` — every other message (LinkedIn notifications, calendar-confirmation emails,
  regular correspondence, etc.). Distinguishing those is out of scope here; a later
  chunk (ingestion/filing or a follow-on sweep refinement) may add finer `type` values
  such as `linkedin-notification` once that logic exists.

```sh
SUBJECT="$(printf '%s' "$MESSAGE" | jq -r '.subject // ""')"
case "$SUBJECT" in
  *'[ra]'*) TYPE="voice-note" ;;
  *)        TYPE="other" ;;
esac
```

## 5. Normalize

Pipe the message body through the shared normalizer. The body handed to
`normalize-capture.sh` must be the verbatim captured text — this skill preserves the
subject line and sender as part of that text (or as `--hint`s) rather than discarding
them.

```sh
SENDER="$(printf '%s' "$MESSAGE" | jq -r '.sender // ""')"
TIMESTAMP="$(printf '%s' "$MESSAGE" | jq -r '.messageTimestamp')"
BODY_TEXT="$(printf '%s' "$MESSAGE" | jq -r '.messageText // ""')"

printf 'Subject: %s\n\n%s\n' "$SUBJECT" "$BODY_TEXT" | \
  packages/connectors/scripts/normalize-capture.sh data/store \
    --source gmail \
    --type "$TYPE" \
    --captured-at "$TIMESTAMP" \
    --hint "$SENDER"
```

- `<store-dir>` is `data/store` per `docs/data-layout.md`.
- `--captured-at` uses the message's own `messageTimestamp` (ISO 8601 `Z` form, matches
  `capture-event.md`'s required format) — not the time the sweep happened to run.
- `--hint` carries the raw `From:` address/name as a `participant-hints` entry; add
  additional `--hint` flags for `to:`/`cc:` addresses if present and not the user's own
  address, so the filing engine has more to resolve against later.
- On success (exit 0), `normalize-capture.sh` prints the new `inbox/<id>.md` path to
  stdout — append `$MSG_ID` to `processed.log` now (step 3).
- On failure (exit 1), the raw body is quarantined at
  `data/store/inbox/quarantine/<stem>.md` with a `.reason.txt` sibling, per
  `docs/data-layout.md`'s quarantine convention. **Do not** append to `processed.log`,
  **do not** delete anything, **do not** abort the batch — move on to the next message.

## 6. One-shot contacts seed

Run once, manually, to seed the store with the user's existing Gmail/Google contacts
as participant hints for the filing engine to resolve against later. Not part of the
recurring new-mail sweep (steps 1-5) — no ledger entry, no checkpoint, safe to re-run
by hand if the user adds a lot of new contacts, but not scheduled.

Uses the Gmail toolkit's People tools (verified via `composio tools info` on
2026-08-29):

- `GMAIL_GET_CONTACTS` — lists the authenticated account's saved contacts (and
  optionally "Other Contacts" — auto-generated from email interactions, often sparse:
  email-only, no name).
- `GMAIL_GET_PEOPLE` — fetches a single person's full detail by `resource_name`; not
  needed for the batch seed below, useful only for one-off enrichment.

```sh
composio execute GMAIL_GET_CONTACTS -d '{
  "person_fields": "names,emailAddresses,organizations,phoneNumbers",
  "include_other_contacts": false
}'
```

- Set `include_other_contacts: false` for the seed run — "Other Contacts" restricts
  `person_fields` to `emailAddresses,names,phoneNumbers,metadata` only and tends to be
  sparse; the saved-contacts pass with fuller `person_fields` is more useful as a first
  seed. Run a second pass with `include_other_contacts: true` (and the restricted
  field set) afterward if broader coverage is wanted.
- Follow `nextPageToken` in a loop until absent, same discipline as step 1.
- Handle `storedInFile`/`outputFilePath` the same way as step 2 — a full contacts list
  is likely to exceed the inline-response size threshold.

Write **one capture event per contact batch page** (not one per contact — this is
breadth capture, not structured filing; the filing engine resolves individual people
later), type `other`, with `participant-hints` populated from every contact's name and
email address in that page:

```sh
PAGE_JSON="$RESULT_JSON"   # after resolving storedInFile if applicable

HINT_ARGS=""
while IFS= read -r hint; do
  HINT_ARGS="$HINT_ARGS --hint $(printf '%q' "$hint")"
done < <(printf '%s' "$PAGE_JSON" | jq -r '
  .data.connections[]? // .connections[]? |
  (.names[0].displayName // empty), (.emailAddresses[0].value // empty)
' | grep -v '^$')

printf '%s' "$PAGE_JSON" | \
  eval "packages/connectors/scripts/normalize-capture.sh data/store \
    --source gmail \
    --type other \
    $HINT_ARGS"
```

(Confirm the exact response field name — `connections` vs `data.connections` — against
a live `composio execute GMAIL_GET_CONTACTS` call before running the seed for real;
the People API's conventional shape is `{ connections: [...] }`, but this must be
verified against the actual Composio-wrapped response, not assumed.)

Failure posture is identical to step 5: a page that fails normalization is quarantined,
the seed continues to the next page, nothing is deleted.

## Failure posture (applies to the whole skill)

- A message (or contacts page) that fails `normalize-capture.sh` is quarantined by the
  normalizer (`data/store/inbox/quarantine/`) — the sweep **continues** to the next
  item. It never aborts the batch.
- Nothing this skill touches is ever deleted — not raw Gmail messages (this skill has
  no delete/modify tool access in the first place), not quarantined items, not ledger
  entries.
- If `composio execute` itself errors (auth expired, rate-limited, etc.), stop the
  current run without advancing the checkpoint or partially-processed message's ledger
  entry — the next scheduled run will retry from the last good checkpoint.

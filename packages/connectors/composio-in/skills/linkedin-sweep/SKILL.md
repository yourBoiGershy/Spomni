---
name: linkedin-sweep
description: Snapshot the user's own LinkedIn surface (profile, known posts, share statistics where available) into inbox/ capture events via the Composio CLI. Low-frequency, read-only, official-API-only.
version: 0.1.0
---

# linkedin-sweep

Snapshots the user's own LinkedIn surface through `composio execute` and writes
one capture event per item into `inbox/` via
`packages/connectors/scripts/normalize-capture.sh`. Read-only against the
user's own linked LinkedIn account — no writes, no third-party data, per
`docs/DECISIONS.md#tos-clean-signals-only` and `#composio-hub`.

## ⚠️ API limits — read this before running anything

LinkedIn's official member API (the only surface Composio's `linkedin`
toolkit exposes, and the only surface this skill will ever touch) is **far
narrower than the LinkedIn product UI**. This is a platform restriction, not
a bug in this skill or in Composio — do not "work around" it with scraping
or unofficial endpoints.

Verified live against the `linkedin` toolkit (24 tools, 2026-08-29):

- **No connections list.** There is no tool that returns the user's network
  — who they're connected to, second-degree reach, anything. Not obtainable
  through this skill, ever.
- **No messages/inbox, no notifications feed.** LinkedIn's member API does
  not expose DMs or the notifications bell. This skill cannot and will not
  attempt either.
- **No "list my own posts" tool.** There is no `LINKEDIN_GET_MY_POSTS` or
  equivalent in the live toolkit (an earlier draft of this package's
  `package.md` assumed one existed — it does not; that reference is stale).
  The only post-reading tool, `LINKEDIN_GET_POST_CONTENT`, requires a post
  URN (`urn:li:ugcPost:...` / `urn:li:share:...`) the caller already has. This
  skill can therefore only **refresh content for post URNs already known**
  from elsewhere in the store (e.g. a URN mentioned in the body of a prior
  `linkedin-notification` capture event, or one the user pastes in
  manually) — it cannot discover new posts on its own.
- **No personal network-size or personal share-statistics tool.**
  `LINKEDIN_GET_NETWORK_SIZE` and `LINKEDIN_GET_SHARE_STATS` both take an
  *organization* URN/ID (`organizational_entity`, `organization_id`) — they
  report follower counts and post performance for **company pages the user
  administers**, not for the user's personal profile or personal posts.
  There is no equivalent personal-profile tool live in the toolkit today.
  This skill does not call either tool and does not fabricate a
  personal-network-size or personal-share-stats capture event.
- **Where richer LinkedIn signal actually comes from:** LinkedIn's own
  notification *emails* ("X commented on your post", "Y viewed your
  profile", "Z changed jobs") land in Gmail and are already captured by
  `gmail-sweep` as `type: linkedin-notification` capture events (see
  `fixtures/email-linkedin-notification.json`). That is the practical
  channel for connection/engagement signal — this skill does not duplicate
  it.
- If a user ever needs the full picture (actual connections list, message
  history, notification history), the only TOS-clean path is LinkedIn's own
  personal data export ("Get a copy of your data" in LinkedIn settings) —
  that's a manual, occasional, out-of-scope action for the user, not
  something this skill or any sweep automates.

## What this skill actually does

Given the limits above, the snapshot is deliberately small: it captures the
two things the official API genuinely supports for a personal account.

1. **Own profile** — `LINKEDIN_GET_MY_INFO` (empty input schema, live-verified
   2026-08-29: returns the profile inline — name, headline, profile picture,
   etc.). No parameters needed.

   ```
   composio execute LINKEDIN_GET_MY_INFO -d '{}'
   ```

2. **Known post refresh** — for each post URN already on file (from a prior
   sweep, a `linkedin-notification` capture event's body, or a URN the user
   supplied), `LINKEDIN_GET_POST_CONTENT`:

   ```
   composio execute LINKEDIN_GET_POST_CONTENT -d '{"post_id": "urn:li:ugcPost:7200000000000000000"}'
   ```

   This is a **refresh of a known post**, not a discovery mechanism — see API
   limits above. If the store has no known post URNs yet, this step is
   skipped entirely (nothing to refresh).

Do **not** call `LINKEDIN_GET_NETWORK_SIZE` or `LINKEDIN_GET_SHARE_STATS` —
both are organization-scoped only (see above) and have no valid personal-scope
arguments to pass.

As with other lanes, large results may come back as
`{ "storedInFile": true, "outputFilePath": "/tmp/..." }` — read that file for
the payload; the shape is otherwise equivalent to the inline `data` form (see
`fixtures/linkedin-post.json` for the representative fixture shape).

## Cadence

This is a **low-frequency snapshot** — weekly-ish, not a continuous or
event-driven sweep like `gmail-sweep`/`calendar-sweep`. A profile rarely
changes day to day, and there's no discovery mechanism to make polling more
often worthwhile. Run it by hand or on a weekly schedule; there is no
"catch up on everything since last run" backlog to worry about — a missed
week costs nothing (capture-is-lossy-tolerant).

## Dedup ledger

Ledger file: `data/connectors/linkedin/processed.log` (plain local state,
outside `data/store/`, per `docs/data-layout.md`'s "Connector runtime state"
section — never in the shared store).

- **Posts:** keyed by post URN (`urn:li:ugcPost:...` / `urn:li:share:...`).
  A post already logged is skipped on subsequent sweeps *unless* its content
  changed (compare against the last-captured payload's hash) — a post whose
  share statistics or text changed is worth a fresh capture event; an
  unchanged post is not.
- **Profile snapshot:** keyed by a content hash of the normalized profile
  payload (or, failing that, by date — one snapshot per calendar day is
  plenty). An unchanged profile between two runs produces no new capture
  event.

Before each `LINKEDIN_GET_MY_INFO` or `LINKEDIN_GET_POST_CONTENT` call
succeeds and is about to be written, compute its key, check the ledger; skip
the write (but still append nothing new) if the key + hash pair is already
present. On a successful new/changed capture, append `<key> <hash> <ISO8601
timestamp>` to the ledger.

## Per-item capture

Every new-or-changed item becomes exactly one capture event, written through
the shared normalizer, per `connector-interface.md`'s single-writer rule for
`inbox/`:

```
packages/connectors/scripts/normalize-capture.sh <store-dir> \
  --source linkedin \
  --type other \
  --captured-at <ISO8601Z> \
  <<< '<raw JSON payload, verbatim>'
```

- `--type other`: neither the profile snapshot nor a post-content refresh is
  a `linkedin-notification` (those come from Gmail) or any other enumerated
  type — `other` is the correct escape hatch per `capture-event.md`.
- `--captured-at` is when this skill fetched the item, not any timestamp
  inside the payload (e.g. the post's original `createdAt`).
- The body is the raw JSON returned by `composio execute` (or the contents
  of its `outputFilePath`), byte-for-byte, unmodified — no summarizing, no
  reformatting, no extracting fields. The filing engine reads the raw JSON
  later; this skill's only job is faithful capture.
- No `--hint` / `participant-hints`: these are the user's own artifacts
  (their own profile, their own posts) with no third-party participant to
  hint at.

## Failure handling

- A failed `composio execute` call (auth expired, rate-limited, tool error)
  is logged and skipped for that item; it does **not** abort the rest of the
  sweep (own profile and each known post URN are independent units of work).
- Anything the normalizer rejects lands in `inbox/quarantine/` with a reason
  file, per `docs/data-layout.md`'s quarantine convention — never dropped,
  never silently discarded, and the sweep continues past it.
- This skill never deletes anything — not ledger entries, not inbox files,
  not quarantine files.

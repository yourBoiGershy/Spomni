# Feedback reply-parse spec

Package: ingestion. Sole entry point: `packages/ingestion/scripts/feedback-parse.sh
<store-dir> --data-dir <d> [--today YYYY-MM-DD]`. Consumes `feedback-event@1.1.0`
(`packages/core/contracts/feedback-event.md`), `capture-event@1.2.0`
(`packages/core/contracts/capture-event.md`), and plan 33's delivered-batch/
`delivered.log` shapes. Plan 34 D2/U8, U8b (`draft` verb).

## Purpose

The deterministic, no-model step that turns the user's numbered replies in
their own note-to-self chat into applied lifecycle actions and one ledger
line each. Mission test: this cuts the running cost of *re-explaining
yourself* — a reply typed once against a delivered card is enough; the
assistant never asks the user to restate a dismissal, snooze, opt-out, or
correction through a session. It never sends anything (the reply channel is
one-way, in), and it never drops a user's words: unparseable text is still
ledgered, as `freeform`.

Runs on every sync tick as its own `feedback` lane row
(`packages/core/templates/sync-lanes.tsv`, ordered after `beeper`). A tick
that finds nothing new is a no-op — no store writes, one line of output.

## Inputs

- **Capture events**: `<store-dir>/inbox/*.md` whose frontmatter `type:
  chat-message` (`packages/core/contracts/capture-event.md` 1.2.0). The
  body (everything after the closing `---`) is the raw JSON beeper-in's
  normalizer wrote, one object per chat per sweep run:
  ```json
  {"chatID": "...", "accountID": "...", "network": "...", "title": "...",
   "chatType": "...", "messages": [ { "id": "...", "chatID": "...",
     "accountID": "...", "senderID": "...", "senderName": "...",
     "timestamp": "...", "sortKey": "...", "type": "TEXT", "text": "...",
     "isSender": true|false, "attachments": [], "linkedMessageID": null,
     "reactions": [] }, ... ] }
  ```
  Only `.chatID` and each `.messages[].text` are read; every other field is
  ignored by this step (it is the sweep's business, not the parser's).
  `.messages[]` order is render/receive order; each entry is one reply
  line, 1-based for `feedback-applied.log`'s `<line-no>` column.
- **Notify chat id**: `<store-dir>/profile.md`'s `## Notify` section,
  bullet `- **[stated-by-user]** beeper_chat_id: <id> (<date>)`
  (`packages/core/contracts/profile.md`, plan 33 D1). The value is matched
  against each candidate event's `.chatID` exactly (string equality). No
  `## Notify` section, or no `beeper_chat_id` bullet, or no `profile.md` at
  all → nothing is a candidate: print `feedback-parse: no notify chat
  configured` and exit 0 without touching the cursor.
- **Cursor**: `<data-dir>/feedback-cursor` — the filename stem (capture
  event id) of the last event this step has fully processed. Candidate
  events are every `inbox/*.md` with `type: chat-message` whose filename
  stem sorts strictly after the cursor value (lexical `>`; capture-event
  ids are timestamp-prefixed, so lexical order is chronological order).
  Absent cursor file = process every `type: chat-message` event in the
  store. The cursor is advanced to each event's stem right after that
  event is fully handled (matched-and-applied, or skipped for chat-id
  mismatch) — so a crash mid-run only reprocesses events after the last
  one that finished, never the whole backlog, and never the same event
  twice on a clean run. No candidate events at all → print `feedback-parse:
  nothing new` and exit 0.
- **Last delivered batch**: `<store-dir>/outbox/delivered.log`
  (connectors-owned, plan 33), tab-separated `<batch-file>\t<channel>\t<ts>\t<ref>`,
  one line per delivered batch. The *last* line whose `<channel>` column is
  not literally `none` names the batch this run resolves card numbers
  against — `<batch-file>` is a bare filename under
  `<store-dir>/wakeups/fired/`. If `delivered.log` is missing, has no such
  line, or the named batch file is missing/unparseable, there is no card
  map for this run: every reply line on every matched event is ledgered as
  `freeform` with `--target model` regardless of what it says, and the run
  still exits 0 (feedback is never dropped just because delivery bookkeeping
  is behind).
- **Batch shape** (`wakeup-queue.sh fire`'s artifact,
  `packages/attention/scripts/wakeup-queue.sh`): `.entries[]`, 0-indexed in
  the JSON, rendered/numbered 1-based in the delivered card (render order =
  array order, plan 33 D3). Card `n` maps to `.entries[n-1]`; `.entries[n-1].id`
  is the wake-up id every op below acts on; `.entries[n-1].people[0]` is
  the primary person slug `wrong-tier` corrects.

## Grammar

Each message's `.text` is one reply line. Tokens are whitespace-delimited;
the first token is `n`, the second is the verb, everything after is kept
byte-for-byte as `<rest>` (only leading token-separating whitespace is
stripped — internal spacing, punctuation, and case are untouched).

| Reply | Applies as | Also ledgers |
|---|---|---|
| `<n> done [<rest>]` | `wakeup-queue.sh dismiss <id> --reason already-handled --source reply --channel beeper-self [--text <rest>]` | `feedback-file.sh --type done --target wakeup:<id> [--text <rest>]` (in addition to the `dismiss` line `wakeup-queue.sh` already appends via its own ledger hook) |
| `<n> snooze <dur>` | `wakeup-queue.sh snooze <id> --days <D> --today <today> --source reply --channel beeper-self` | ledgered by `wakeup-queue.sh`'s own hook (`type: snooze`, `reason: <dur>`) |
| `<n> skip` | `dismiss <id> --reason not-now ...` | via the hook (`type: dismiss`) |
| `<n> never <signal-type> [<rest>]` | `dismiss <id> --reason not-this-signal-type ...`, then (only if the dismiss succeeded) append `- **[stated-by-user]** <signal-type> — all` to `profile.md`'s `## Signal opt-outs` (skipped if a bullet for that signal-type already reads `— all`; no date suffix — `packages/core/scripts/validate-store.sh`'s Signal opt-outs grammar is `<signal-type> — (all|[[slug]])`, no trailing date) | via the hook (`type: dismiss`), plus `feedback-file.sh --type opt-out --target signal:<signal-type> --to all --source reply --text <rest>` |
| `<n> not-them` | `dismiss <id> --reason not-this-person ...` | via the hook (`type: dismiss`) |
| `<n> wrong-tier <tier> [<rest>]` | `person-set-tier.sh <store> <slug> --tier <tier> --source stated-by-user --today <today> --feedback-source reply --feedback-channel beeper-self --feedback-text <rest>` (`<slug>` = `.entries[n-1].people[0]`; `<tier>` must be one of `inner-circle\|close\|active\|dormant` and `<slug>` must be non-empty, else this row falls through to the catch-all) | via `person-set-tier.sh`'s own hook (`type: tier-correction`) |
| `<n> draft [<rest>]` | write `<store-dir>/outbox/drafts/<batch-stem>-<n>-draft.txt` (`mkdir -p`; unsent text, never sent by this step) — see "Draft on demand" below | `feedback-file.sh --type draft-request --target wakeup:<id> [--text <rest>]` |
| `<n> <anything else>` | nothing applied | `feedback-file.sh --type freeform --target wakeup:<id> --text "<whole line>" --source reply --channel beeper-self` |
| no valid leading integer, or `n < 1`, or `n > entries.length`, or no delivered-batch map at all | nothing applied | `feedback-file.sh --type freeform --target model --text "<whole line>" --source reply --channel beeper-self` |

`<dur>` = `<int>[dhw]`: a trailing `d` multiplies by 1 (days), `w` by 7,
`h` maps to a flat 1 day (sub-day snooze granularity does not exist in the
wake-up model). A duration with no recognized suffix, or `wrong-tier` with
an unrecognized tier or a card with no primary person, does not fall back
to a *different* action — it is ledgered exactly like the catch-all
(`freeform`, `--target wakeup:<id>`), because the verb and card were
identified even though the argument could not be applied.

## Draft on demand (plan 34 U8b)

`<n> draft [<rest>]` is the nudge-first / draft-on-demand reply: the user is
never shown a drafted message unsolicited, and never asked to write one
themselves — they ask for it, once, against a delivered card, and get back
exactly what already exists for it. This step never composes or invents a
draft; that is a model session's or the sweep's job (per U16, drafts are
composed from `context` + `profile.md`'s `## Style notes` ahead of time and
stored on the wake-up's `Draft` section, which `wakeup-queue.sh fire`
carries into the fired batch's `.entries[n-1].draft`). This deterministic
tick only serves what a prior pass already wrote:

- `.entries[n-1].draft` non-empty → written verbatim as the file's body.
- `.entries[n-1].draft` empty/null → the file reads exactly `no draft
  available for <n>` (`<n>` is the card number as typed). Never falls back
  to composing something from `context` — an empty draft field means no
  draft was pre-composed, full stop; inventing one here would be exactly
  the "performing the relationship for the user" the mission rules out.
- Free text after `draft` (`<rest>`) is appended as a final `Note: <rest>`
  line, verbatim, so the sender can see their own ask reflected back
  (useful when the request is later re-read out of the outbox).

File path: `<store-dir>/outbox/drafts/<batch-stem>-<n>-draft.txt`, where
`<batch-stem>` is the resolved batch file's name with its `.json`
extension stripped. The file is unsent text — the human sends it, same as
every other draft in this repo (`Draft, never send.`, `CLAUDE.md`).
Contents:
```
Draft (unsent):
<the entries[n-1].draft field, verbatim>
Note: <free text verbatim>          (only if free text was given)
```
or, with no draft on file:
```
Draft (unsent):
no draft available for <n>
Note: <free text verbatim>          (only if free text was given)
```

**Idempotency / re-request:** a second `<n> draft` reply against the same
card normally overwrites the same file (nothing downstream has consumed it
yet, so there is nothing to preserve). If that exact file name is already
listed in `<store-dir>/outbox/delivered.log` column 1 — meaning an earlier
draft file for this card was already picked up and sent out — a fresh
request instead writes a timestamp-suffixed sibling
(`<batch-stem>-<n>-draft-<compact-ts>.txt`) so the outbound lane sees a new
file to deliver rather than silently missing a re-request for content it
already delivered once.

## The "never dropped" rule

Every reply line produces exactly one row in `<data-dir>/feedback-
applied.log` (`<capture-id>\t<line-no>\t<type>\t<ts>\t<exit>`) and exactly
one line in `<store-dir>/signals/feedback.jsonl` (via `feedback-file.sh`,
whose call is either the applied op's own ledger hook or an explicit
`freeform`/`done`/`opt-out` call this script makes directly) — never zero,
never more than what the grammar table above specifies. If the applied op
itself exits non-zero (e.g. `dismiss` on an already-dismissed wake-up), the
reply is not silently swallowed: it is ledgered as `freeform` against the
same target the op would have acted on (`wakeup:<id>` or `person:<slug>`),
with `--reason op-exit-<exit-code>`, and `feedback-applied.log` records
`freeform` with that same non-zero exit code in its last column. A failed
op is evidence the assistant should re-derive the card mapping or ask
again — it is never treated as if the user said nothing.

## `never <signal-type>` is a stated write, not a proposal

Ingestion is `profile.md`'s sole writer, and `## Signal opt-outs` bullets
are provenance-tagged `stated-by-user` by construction (an opt-out is by
definition something the user explicitly asked for —
`packages/core/contracts/profile.md`). A `never <signal-type>` reply is the
user's own verbatim statement, typed in reply to a specific card — this
script writes the opt-out bullet directly, the same way any other
`stated-by-user` filing works, with no confirmation round-trip. This is
distinct from *inferred* opt-out proposals elsewhere in the system (e.g.
plan 34 D5's "2× `not-them` on one person in 90 days" heuristic), which
remain proposals a wake-up surfaces for the user to confirm — those are
derived from behavior, not something the user said, and confirmation
provenance is preserved (`docs/DECISIONS.md#preference-provenance`).

## Idempotency

- The cursor guarantees each capture event's messages are parsed and
  applied at most once per event, across any number of ticks.
- Bullets appended to `## Signal opt-outs` are deduplicated by exact
  `<signal-type> — all` substring match before writing — a repeated
  `never <type>` reply (from the same event replayed after a crash, or a
  second time the user says it) never produces a second bullet, though it
  still produces its own `feedback.jsonl`/`feedback-applied.log` rows (the
  ledger is never deduplicated — see `specs/feedback-ledger.md`).
- Re-running with the cursor already at the newest event, or with no new
  `chat-message` events at all, is silent: `feedback-parse: nothing new`,
  no writes.

## Exit codes

`0` on every terminal state described above, including "no notify chat
configured", "nothing new", and every applied/freeform combination. `2` on
a usage error (missing `<store-dir>`, missing `--data-dir`, unrecognized
flag) or a missing `jq` binary. The script never returns a non-zero exit
because an individual reply's op failed — those are ledgered, not
propagated, per "never dropped" above.

## Portability

bash 3.2 (macOS default): no associative arrays, no `mapfile`. `jq` is
required (the same dependency `beeper-in`'s `lib.sh` already states, and
plan 33's `deliver-tick.sh` header notes "jq allowed — beeper lane already
requires it"); this step degrades no further than beeper-in already does
if `jq` is absent from launchd's minimal PATH. Runs as the `feedback` row
in `packages/core/templates/sync-lanes.tsv`, scheduled by
`packages/connectors/scripts/sync-scheduler.sh` the same way every other
lane is, ordered after `beeper` so a tick's newly landed replies are
visible to the same run's `feedback-parse.sh` pass whenever the two lanes
share a cadence.

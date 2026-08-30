# Plan 32 — One model call per thread (thread summaries replace per-day model filing)

**Mission test.** Cuts running cost only: the model reads a chat thread once and
answers a fixed set of questions (who, what kind of relationship, gist, open
threads, commitments, stated facts with provenance); every per-day/episode
artifact is derived from message timestamps by a script. No drafting, no
sending, no facts invented — the JSON is provenance-labeled and the writer
never adds anything the model didn't say or the timestamps don't show.

**Trigger (2026-08-30).** Onboarding on the private store: deterministic
filing of 221 structured events took 18 s; the model path over 123 free-text
events took ~40 min across 4 shard workers + 2 leftover passes and still left
12 group-chat ids pending. Cause: the debrief skill's episode-split rule turns
a months-long chat capture into 10–20 per-day editorial tasks, each an agentic
worker turn with file writes and collision checks. The largest thread is 75 KB
(~20k tokens); all 45 chat captures together are < 700 KB. Reading each thread
once is cents; the agency around it was the cost. User direction: "just send
the entire message in the chat instance … we just need main semantics."

## Decisions

- **D1 One call per thread.** `packages/ingestion/scripts/summarize-thread.sh
  <event-file> [--model <m>] [--out <json>]` compacts the capture body
  (sender, timestamp, text; NOTICE/system rows dropped) into a prompt and runs
  one headless `claude -p … --output-format json` (pattern:
  `packages/core/scripts/eval-judge.sh` — sleep-and-kill timeout, `RA_*` env
  overrides, dry-run and parse-test hooks so CI never calls the model). Output
  is a strict JSON object (`thread-summary` 1.0.0, in the spec):
  `{skip: null|{reason}, people: [{display_name, sender_ids[], role_guess,
  is_self}], relationship_kind_guess, gist, open_threads[], commitments[],
  facts[{about, text, provenance: told-by-user|inferred-from-thread}]}`.
  Default model: haiku (extraction, not tier judgment); override via
  `RA_THREAD_MODEL`.
- **D2 Episodes are deterministic.** `packages/ingestion/scripts/
  file-thread.sh <store> <event-file> <summary.json> [--data-dir <d>]` derives
  active UTC days from message timestamps and writes one interaction per day
  (summary = gist + that day's who/how-many; commitments/open threads on the
  last day only), upserts person files (no `tier`/`tier_source`; facts under
  `## Facts` with the JSON's provenance label), appends the capture id to
  `debrief-filed.log`. Same on-disk shape review-tiers reads today.
- **D3 Duplicate captures collapse first.** Captures sharing a `chatID` are
  grouped; the writer unions messages by message `id` and files the union
  once, marking every contributing capture id filed. (Two shard workers each
  had to rediscover this by hand.)
- **D4 Cold outreach is filed, not skipped.** `skip` is only for no-person
  senders (bots, broadcast channels, "note to self", security notices). A
  stranger's LinkedIn pitch is a person with `role_guess: unsolicited` —
  review-tiers already has that kind; filing must not vary by worker.
- **D5 The debrief skill keeps free-text *notes* and email bodies**; chat
  captures route to D1/D2. onboarding-seed step 2(c) becomes: threads → D1/D2
  in parallel (xargs -P), remainder → debrief.

## Units (parallel where files are disjoint)

| U | pkg | scope |
|---|---|---|
| U1 | ingestion | `summarize-thread.sh` + spec `thread-summary.md` |
| U2 | ingestion | `file-thread.sh` (dedup, episodes, person upsert, ledger) |
| U3 | ingestion | tests for U1 (parse-test/dry-run) + U2 (fixtures) |
| U4 | eval | small-scale live eval: 5 already-worker-filed threads (2, 19, 35, 63, 161 msgs) into a scratch store; compare slug identity, episode-day set vs worker's dates, gist/kind plausibility; record wall-clock + tokens |
| U5 | docs/skills | onboarding-seed step 2(c) reroute; debrief SKILL note; DECISIONS; ROADMAP row 32 |

## Success criteria (U4)
- Same person slug for all 5; episode-day sets equal to the worker's (they
  are timestamp-derived on both sides).
- Wall-clock for the 5 threads < 2 min total in parallel; no worker turns.
- Kind guesses match the worker's filing (friend/colleague/etc.) on ≥4/5.

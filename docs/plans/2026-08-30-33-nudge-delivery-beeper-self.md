# Plan 33 — Nudge delivery: Beeper note-to-self + numbered replies
Status: Ready
Package: connectors (beeper-out NEW, file-out, gmail-out, scripts/deliver-tick.sh) + core (profile 1.1.0, nudge-card contract + renderer) + attention (sweep step 8) + ingestion (Notify writer) + harness (oss-guard allowlist)
Depends-on: 06 (fired batch), 13 (beeper-in transport), 28 (sync lanes). Absorbs plan 07's nudge-card + adapter units (07 U1, U3, U5, U6); 07's query/brief skills stay in 07. Reply *parsing* is plan 34.

## Objective
Make a fired wake-up batch physically reach the user. Today `wakeup-queue.sh
fire` writes `wakeups/fired/<ts>-batch.json` and the sweep's last step logs
"no adapter yet" — zero nudges have ever been delivered. After this plan: every
sync tick (and every sweep) renders any undelivered batch into one numbered
message, writes it to `outbox/` (always), and posts it to the user's Beeper
"Note to self" chat (default) or emails it to the user's own address
(fallback), gated by quiet hours, idempotently. The message ends with the
reply grammar plan 34 will parse.

## Mission test
Delivery is the running cost of *remembering-to* actually reaching the
person who has to remember. Nothing here touches an ingredient: the only
send is to the user's own self-chat/self-address (`notify-self-is-a-send`),
drafts arrive marked unsent, and the render carries no guilt surface (no
pending counts, no "missed", no streaks). Nearest risk — a self-chat on a
bridged network leaking assistant text about other people to that network's
metadata — is why the default is the Matrix note-to-self chat, not WhatsApp/
iMessage self-chats (research note, channel table).

## Context
Settled in `docs/research/2026-08-30-nudge-delivery-and-feedback-loop.md`
(Part 1 + Decisions block) — do not re-litigate:
- default channel `beeper-self`; `gmail-self` fallback when no beeper lane;
  `outbox` always written
- numbered replies (`1 snooze 2w`, `2 done`, `3 never birthday`)
- cadence rides on sync, not a clock; a tick with nothing new is a no-op

What exists that this plan wires together:
- `packages/attention/scripts/wakeup-queue.sh fire` → batch artifact (shape
  pasted in U2). Sole writer of `wakeups/` + `wakeups/fired/` is attention.
- `packages/connectors/beeper-in/scripts/lib.sh`: `beeper_load_config
  <data_dir>` (sets `BASE_URL` default `http://127.0.0.1:23373`,
  `BEEPER_TOKEN` from `data/connectors/beeper-in/token`), `beeper_get`
  (curl, `--max-time 15`, Bearer; `BEEPER_HTTP_STUB` swaps curl for a stub in
  tests). beeper-in is GET-only by contract (`api-notes.md` "Allowed call
  surface") — **the send never goes there**.
- Beeper Desktop API (api-notes.md, verified): `POST /v1/chats/{chatID}/
  messages` sends; `/reminders` sets a native reminder; chat IDs must be
  URL-encoded. "Note to self" chat = chatID `1` on the live account.
- `packages/attention/skills/sweep/SKILL.md` step 8 "Deliver" logs
  `deliver: batch at <path> (no adapter yet — batch file is the delivery)`.
- `packages/core/contracts/profile.md` 1.0.0: four fixed sections, every
  bullet provenance-tagged, ingestion sole writer; `validate-store.sh` Pass
  1.5 rejects any other section (line ~460) — U1 must widen it.
- `.claude/scripts/oss-guard.sh` `check_never_send` (line 318): greps
  `packages/connectors/** packages/attention/**` for
  `send_message|send_email|gmail__send|slack_send_message|mcp__beeper__send_message|messages\.send|chat\.postMessage`;
  excludes `tests/`, `evals/`, non-SKILL `.md`, and SKILL.md files stating
  "draft, never send"/"human sends".
- `packages/connectors/file-out/` and `gmail-out/` are `.gitkeep` stubs.
- `sync-lanes.md`: lane row `lane<TAB>interval_seconds<TAB>enabled<TAB>command`,
  command runs under launchd's minimal PATH, exit 0 = clean run.

## Decisions
- **D1 Channel is config.** `profile.md` → 1.1.0 adds a fifth fixed section
  `## Notify` (after `## Style notes`; additive minor bump). Bullets keep the
  contract's provenance grammar:
  ```
  ## Notify

  - **[stated-by-user]** channel: beeper-self
  - **[stated-by-user]** beeper_chat_id: 1
  - **[stated-by-user]** quiet_hours: 22:00-08:00
  - **[stated-by-user]** gmail_address: <user's own address>   (optional; required only for gmail-self)
  ```
  `channel` enum: `beeper-self | gmail-self | outbox | none`. Ingestion is
  the sole writer (`profile-set-notify.sh`, U9). Resolution when the section
  or `channel` is absent: `beeper-self` if `data/connectors/beeper-in/
  config.json` + `token` exist, else `gmail-self`. `outbox` is always written
  in addition, as audit. A `beeper-self` channel with no `beeper_chat_id` is
  a logged fallback to outbox-only, never a guess.
- **D2 New sub-package `packages/connectors/beeper-out/`** — dumb: rendered
  text + chat id → `POST /v1/chats/{chatID}/messages`; `--reminder <iso>` →
  the `/reminders` call (plan 34's snooze uses it). Same local HTTP + bearer
  token as beeper-in (reads beeper-in's `config.json`/`token`, never copies
  them). **Self-only invariant:** the script resolves the chat id from
  `## Notify` itself and hard-refuses (exit 4, `refuse: chat id not in
  profile ## Notify`) any `--chat-id` argument that differs — mirrors
  gmail-out's self-address rule; tested. beeper-in stays GET-only; its
  package.md/api-notes "send capability is never called" wording now points
  at beeper-out as the one self-only exception. DECISIONS.md entry
  `notify-self-is-a-send`.
- **D3 Card render spec lives in core** (`packages/core/contracts/
  nudge-card.md` 1.0.0 + `packages/core/scripts/render-nudge-cards.sh`): the
  batch is attention's artifact and the adapters are connectors', so the
  render is a shared contract, not either package's file. One message per
  fired batch. Cards numbered `1.`, `2.` … in batch `entries` order; each
  card = trigger line (`why`, signal type in parens when present) +
  ammunition (`context`) + optional draft block headed `Draft (unsent):` +
  people as `[[slug]]`. A `mentions[]` line renders once, after the cards,
  un-numbered. Footer = reply grammar (D4). **No-guilt rules (binding):**
  never render `held_budget`/`held_adjacent` counts, `budget`, "pending",
  "missed", "overdue", streaks, or the batch's age. Plain text, no markdown
  tables (Beeper renders it as a chat message).
- **D4 Reply grammar** (footer text defined here; parsed in plan 34):
  ```
  Reply with the number: <n> done | <n> snooze <dur> | <n> skip | <n> never <signal-type> | <n> not-them | <n> wrong-tier <tier>
  ```
  Free text after the verb is kept verbatim by the parser. The footer is
  one line, identical across channels.
- **D5 Cadence rides on sync.** New `packages/connectors/scripts/
  deliver-tick.sh <store-dir>`: for every `wakeups/fired/*-batch.json` not
  listed in `<store>/outbox/delivered.log` (connectors-owned, outside
  attention's `wakeups/`): render → `file-out` (always) → configured
  channel adapter → append `<batch-file>\t<channel>\t<ts>\t<ref>` to
  `delivered.log`. Idempotent (log line written only after a successful
  send; a rerun finds nothing). Quiet-hours gate: inside the window the tick
  exits 0 with `deliver: quiet-hours hold` and delivers on the next tick
  outside it. Scheduled as its own `notify` lane row (default 900 s, same
  cadence as `beeper`) rather than inside `beeper-sweep.sh`, because
  beeper-in is GET-only by contract; it is also the sweep's step 8 (D6). No
  daily-hour scheduler. `channel: gmail-self` is session-driven (first-party
  Gmail MCP): the headless tick writes outbox + logs `deliver: gmail-self
  pending (session)`; the sweep skill (a session) completes it via the
  gmail-out skill.
- **D6 Sweep step 8 wired.** `skills/sweep/SKILL.md` step 8 becomes
  `bash packages/connectors/scripts/deliver-tick.sh <store-dir> [--today
  <today> --now <now>]`; for `gmail-self` it then invokes
  `packages/connectors/gmail-out/skills/gmail-self-notify/`. gmail-out is
  built (session-driven, self-only, refuses any recipient ≠
  `gmail_address`) as the fallback channel.

## Deliverables
- core: `contracts/profile.md` 1.1.0, template, `validate-store.sh` Notify
  rules; `contracts/nudge-card.md`; `scripts/render-nudge-cards.sh`;
  `fixtures/fired-batch/` (batch + expected render); store tests
- connectors: `beeper-out/` (package.md, `scripts/lib.sh`, `scripts/
  beeper-send.sh`, tests + HTTP stub fixtures); `file-out/` (package.md,
  `scripts/file-out.sh`); `gmail-out/` (package.md, `skills/gmail-self-
  notify/SKILL.md`); `scripts/deliver-tick.sh` + tests; `lanes.tsv`
  template row `notify`; manifest updates (connectors, beeper-in)
- ingestion: `scripts/profile-set-notify.sh` + test
- attention: sweep SKILL step 8 + package.md consumes line
- harness: oss-guard never-send allowlist for `beeper-out/scripts/` with
  the self-only guard as the tested condition
- docs: DECISIONS.md `notify-self-is-a-send`, ROADMAP row 33 (+ row 07
  note), plan 07 amendment note, SETUP.md step, this plan

## Work units (≤3 min each)

### Wave A (parallel; all independent)

**U1 [worker] core — profile 1.1.0 `## Notify`.** Files: `packages/core/
contracts/profile.md`, `packages/core/templates/profile.md` (or wherever the
template lives — locate with one glob), `packages/core/scripts/
validate-store.sh` (Pass 1.5: allow `## Notify` as fifth section; bullets
must be provenance-tagged; `channel` value ∈ enum; `beeper_chat_id`
non-empty string; `quiet_hours` matches `HH:MM-HH:MM`; unknown key →
error). Paste the D1 block into the contract as the example; state the
resolution defaults and "absent section is valid". Bump `schema_version`
1.0.0 → 1.1.0 with the additive-minor note.

**U2 [worker] core — nudge-card contract + renderer + fixture.** Files:
`packages/core/contracts/nudge-card.md`, `packages/core/scripts/
render-nudge-cards.sh <batch.json> [--today <d>]` (bash 3.2 + jq; stdout =
message text), `packages/core/fixtures/fired-batch/batch.json` (3 entries:
birthday with no draft, job-change with a draft, event-proposal; plus one
`mentions[]` item) and `expected.txt`. Input shape (exactly what
`wakeup-queue.sh` writes):
```json
{ "schema_version": "1.0.0", "fired_at": "<iso>", "today": "YYYY-MM-DD",
  "budget": { "max": 3, "used_before": 0, "used_after": 2 },
  "entries": [ { "id": "...", "due": "YYYY-MM-DD", "people": ["slug", ...],
                 "why": "...", "origin": "signal|standing|user-ask",
                 "kind": "nudge|event-proposal", "signal_type": "birthday|null",
                 "context": "<## Context section text>", "draft": "<## Draft text or empty>",
                 "proposed_event": null | { "title": "...", "start": "...", "end": "..." } } ],
  "held_budget": ["id", ...], "held_adjacent": ["id", ...],
  "mentions": [ { "kind": "undebriefed-meeting", "event_id": "...", "summary": "...",
                  "date": "...", "people": ["slug"], "line": "<text>" } ]   // optional
}
```
Render per D3/D4; `budget`, `held_*` never appear. Event-proposal card shows
title/start/end and "reply `<n> done` after you create it". Empty `entries`
→ exit 3, no output (the tick treats it as nothing to send).

**U3 [worker] core — renderer tests.** File: `packages/core/tests/
run-store-tests.sh` (extend) or `run-render-tests.sh` + `test-all.sh`
listing. Cases: fixture renders byte-equal to `expected.txt`; numbering
follows entries order; draft block present and headed `Draft (unsent):`;
no-guilt grep (`pending|missed|overdue|held|budget` absent from output);
mentions line un-numbered; empty entries → exit 3; footer line exact
string from D4; profile `## Notify` validate-store cases (valid, bad enum,
bad quiet_hours, untagged bullet). Depends-on: U1, U2 for the run, not for
authoring.

**U4 [worker] connectors — `beeper-out/`.** Files: `packages/connectors/
beeper-out/package.md`, `scripts/lib.sh`, `scripts/beeper-send.sh`.
`beeper-send.sh <store-dir> --text-file <f> [--chat-id <id>] [--reminder
<iso>]`: source beeper-in's `lib.sh` for `beeper_load_config` (reads
`<private-data-root>/data/connectors/beeper-in/` — same resolution
beeper-sweep uses; skip-exit 0 with `skip-no-token`/`skip-disabled` like
the sweep); resolve `beeper_chat_id` from `<store>/profile.md ## Notify`
(bullet grep, provenance tag stripped); if `--chat-id` given and ≠ that
value → exit 4 `refuse: chat id not in profile ## Notify`; if no chat id in
profile → exit 4 `refuse: no beeper_chat_id in profile ## Notify`. New
`beeper_post <path> <json>` in beeper-out's `lib.sh` (`curl -sS --max-time
15 -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer
…"`; honours `BEEPER_HTTP_STUB` exactly like `beeper_get` so tests are
offline). Send: `POST /v1/chats/<urlencoded id>/messages` with `{"text":
"<file contents>"}`; print `sent chat=<id> message_id=<id-from-response>`.
`--reminder`: the `/reminders` call from api-notes; print `reminder
chat=<id> at=<iso>`. Manifest: Purpose (self-only send, the one exception
to draft-never-send: `notify-self-is-a-send`), allowed paths (only the two
POST paths), Consumes `profile@^1.1`, Owned paths.

**U5 [worker] connectors — beeper-out tests.** File: `packages/connectors/
tests/run-beeper-out-tests.sh` + `beeper-out/fixtures/` (send-ok response,
401) + `test-all.sh` listing. Cases via `BEEPER_HTTP_STUB` capturing
method/path/body: happy path posts to `/v1/chats/1/messages` with the file
text; chat id with `!`/`:` is URL-encoded; `--chat-id 2` when profile says
1 → exit 4, **zero HTTP calls**; profile without Notify → exit 4, zero
calls; missing token → exit 0 skip; 401 → non-zero, distinct log line;
`--reminder` hits `/reminders`. Depends-on: U4 for the run.

**U6 [worker] connectors — `file-out/`.** Files: `packages/connectors/
file-out/package.md`, `scripts/file-out.sh <store-dir> --text-file <f>
--batch <batch-path> [--today <d>]`: append to `<store>/outbox/<today>.md`
a section `## <batch filename>` + the text; create `outbox/` if absent;
print `outbox: <path>`. Idempotency is the tick's job (delivered.log), not
this script's. Trivial test rides in U12.

**U7 [worker] connectors — `gmail-out/`.** Files: `packages/connectors/
gmail-out/package.md`, `skills/gmail-self-notify/SKILL.md` (frontmatter
name/description). Steps: read `<store>/profile.md ## Notify
gmail_address` — absent → stop with `skip: no gmail_address in ## Notify`,
never infer it; read the rendered text file the tick left at
`<store>/outbox/pending-gmail/<batch>.txt`; send via the first-party Gmail
connector with `to` = that address only, subject `Spomni: <today>`; hard
rule stated in the SKILL: the only permitted recipient is the user's own
`gmail_address` — this is the self-notify exception (`notify-self-is-a-
send`); "draft, never send" for anyone else (this exact phrase must appear
so oss-guard's SKILL.md exclusion applies); on success append the
`delivered.log` line (`<batch>\tgmail-self\t<ts>\t<message-id>`) and
remove the pending file. Symlink into `.claude/skills/` per the skills
convention.

**U8 [worker] harness — oss-guard allowlist.** Files: `.claude/scripts/
oss-guard.sh`, `.claude/scripts/tests/run-oss-guard-tests.sh`. In
`check_never_send`: add `messages` POST detection? No — keep the pattern;
add the path case `packages/connectors/beeper-out/scripts/*`: allowed
**only if** the file containing the match also contains the literal guard
string `refuse: chat id not in profile ## Notify` (the tested self-only
invariant); otherwise report as usual. Widen the grep pattern with
`/v1/chats/[^ ]*/messages` so a raw POST elsewhere in `packages/` is caught.
Tests: beeper-out with guard → clean; a fixture copy without the guard →
FAIL; a POST to that path under `packages/attention/` → FAIL.

**U9 [worker] ingestion — Notify writer.** File: `packages/ingestion/
scripts/profile-set-notify.sh <store-dir> [--channel <enum>]
[--beeper-chat-id <id>] [--gmail-address <addr>] [--quiet-hours HH:MM-
HH:MM]`: creates `profile.md` from the core template if absent; adds/
replaces the given `## Notify` bullets (tag `**[stated-by-user]**`,
trailing `(<today>)` date); validates enum; runs nothing else. Print
`notify: channel=<v> beeper_chat_id=<v> quiet_hours=<v>`. Add one line to
the onboarding-seed SKILL's final step: "state the channel once:
`profile-set-notify.sh …` (default beeper-self when the beeper lane is
configured)". Manifest: ingestion package.md Provides line.

**U10 [worker] ingestion — Notify writer test.** Extend
`packages/ingestion/tests/run-seed-tests.sh` (or the closest suite): create
from scratch; replace an existing value keeps the other bullets; bad enum →
non-zero; result passes `validate-store.sh`. Depends-on: U1 (validator),
U9.

### Wave B (after A)

**U11 [worker] connectors — `scripts/deliver-tick.sh`.** File:
`packages/connectors/scripts/deliver-tick.sh <store-dir> [--today <d>]
[--now <iso>] [--private-data-root <p>]`. Steps: (1) list `wakeups/fired/
*-batch.json`, subtract names in `<store>/outbox/delivered.log` (col 1);
none → `deliver: nothing new` exit 0. (2) Resolve channel per D1 (profile
bullets; default rule via presence of beeper-in config+token). (3)
Quiet-hours: parse `quiet_hours`, compare `--now` local HH:MM (window may
wrap midnight) → inside → `deliver: quiet-hours hold n=<k>` exit 0, no log
write. (4) Per batch, oldest first: `render-nudge-cards.sh` → tmp file
(exit 3 → log `deliver: empty batch <name>` and record it in delivered.log
with channel `none` so it is never re-examined); `file-out.sh` always;
then `beeper-self` → `beeper-send.sh` (exit 4 refuse → log, fall back to
outbox-only line `<batch>\toutbox\t…`); `gmail-self` → copy text to
`outbox/pending-gmail/<batch>.txt`, log `deliver: gmail-self pending
(session)`, **no** delivered.log line yet; `outbox` → log line with the
outbox path; `none` → delivered.log line `none`. (5) Append delivered.log
line only after the adapter printed success. bash 3.2, launchd PATH (jq
allowed — beeper lane already requires it; state it in the header). Every
terminal state prints a distinct line; exit 0 on skips, non-zero only on
adapter transport failure.

**U12 [worker] connectors — deliver-tick + file-out tests.** File:
`packages/connectors/tests/run-deliver-tests.sh` + `test-all.sh` listing.
Uses the core fixture batch + `BEEPER_HTTP_STUB`. Cases: first run sends
once, writes outbox file + delivered.log; second run → `nothing new`, zero
HTTP calls; quiet-hours inside/outside (incl. wrap-around `22:00-08:00` at
23:30 and 07:30 → hold, 09:00 → send); no Notify section + beeper config
present → beeper-self; no Notify + no beeper config → gmail-self pending
file written, no delivered line; channel `none`; beeper refuse (chat id
missing) → outbox-only line; empty-entries batch → `none` line;
`file-out.sh` appends a second section on a second batch same day.
Depends-on: U11.

**U13 [worker] attention — sweep step 8 + manifest.** Files:
`packages/attention/skills/sweep/SKILL.md` (step 8 rewritten per D6: the
command, the log lines to expect, the gmail-self session follow-up, the
silence principle unchanged; run-log example line updated), `packages/
attention/package.md` (Purpose sweep bullet: "hand batch to output
adapter" no longer a skip; Consumes: `nudge-card@^1` via `deliver-tick`;
note `wakeups/fired/` stays attention-owned and `outbox/` is connectors').
No script changes.

**U14 [worker] connectors — manifests + lane row.** Files:
`packages/connectors/package.md` (sub-packages list: `beeper-out/` self-
only send, `file-out/`/`gmail-out/` now built; Provides: delivery tick +
`outbox/` + `delivered.log` ownership; Consumes `profile@^1.1`,
`nudge-card@^1`; Built by: 33), `packages/connectors/beeper-in/package.md`
+ `api-notes.md` ("send capability is never called" → "never called *from
this sub-package*; the sole self-only send lives in `beeper-out/`, see
DECISIONS `notify-self-is-a-send`"), the `lanes.tsv` template/example row
`notify\t900\ttrue\t/bin/bash <abs>/packages/connectors/scripts/deliver-tick.sh <store>`
wherever the `beeper` example row lives (grep `beeper\t900`), plus the
`docs/SETUP.md` step (create the Beeper token once — shared with beeper-in;
run `profile-set-notify.sh`; enable the `notify` lane).

**U15 [orchestrator] docs.** DECISIONS.md `notify-self-is-a-send` (a
message to the user's own self-chat/self-address is a permitted send; the
invariant moves from "never call send" to "the recipient is always the
user" — enforced by beeper-out's chat-id refusal, gmail-out's address
refusal, and oss-guard's guard-string allowlist; revisit: never widen to
any other recipient); ROADMAP row 33 + row 07 note ("nudge-card + adapters
moved to 33"); plan 07 Context amendment line; this plan's status.

### Wave C (after B)

**U16 [checker] end-to-end fixture proof.** Scratch store: `wakeup-add.sh`
three due entries → `wakeup-queue.sh fire` → `deliver-tick.sh` with the
stub → assert outbox file content == renderer output, stub captured exactly
one POST to `/v1/chats/1/messages`, delivered.log one line; rerun → zero
POSTs; `--chat-id 2` refused with zero POSTs; `bash scripts/test-all.sh`
green; `oss-guard.sh` clean. Report any never-send hit.

**U17 [user session] live proof.** On the private store: `profile-set-
notify.sh --channel beeper-self --beeper-chat-id 1 --quiet-hours
22:00-08:00`; ensure one due wake-up exists (`wakeup-add.sh … --origin
user-ask` if none); `wakeup-queue.sh fire`; `deliver-tick.sh`. Evidence:
the message visible in Beeper "Note to self" (chatID 1) on phone/desktop,
`outbox/<today>.md` holds the same text, `outbox/delivered.log` has one
line, a second tick prints `nothing new`. Then enable the `notify` lane row
and confirm one scheduled tick logs `nothing new` in `logs/notify.log`.

| Unit | Pkg | Depends-On |
|---|---|---|
| U1 | core | — |
| U2 | core | — |
| U3 | core | U1, U2 (run) |
| U4 | connectors/beeper-out | — |
| U5 | connectors | U4 (run) |
| U6 | connectors/file-out | — |
| U7 | connectors/gmail-out | — |
| U8 | harness | — |
| U9 | ingestion | — |
| U10 | ingestion | U1, U9 |
| U11 | connectors/scripts | U1, U2, U4, U6 |
| U12 | connectors | U11 |
| U13 | attention | U11 |
| U14 | connectors + docs/SETUP | U4, U11 |
| U15 | docs | U11 |
| U16 | checker | U3, U5, U8, U10, U12, U13, U14 |
| U17 | user session | U16 merged |

Dispatch: Wave A = 10 units across core/connectors/ingestion/harness —
one worker per module per the splitting rule (core: U1 / U2 / U3;
connectors: U4 / U5 / U6+U7 (both tiny, same package, disjoint dirs) ;
harness: U8; ingestion: U9 / U10). Wave B = U11 / U12 / U13 / U14 in one
parallel message (U12 authored from U11's header spec above; runs after).

## Interfaces
Consumes: fired-batch artifact 1.0.0 (attention `wakeup-queue.sh fire`);
`profile@1.1` `## Notify` (ingestion writes, connectors/attention read);
beeper-in's config/token + `beeper_load_config` (read, never copied);
first-party Gmail connector (session only); `sync-lanes@1` lane row.
Produces: `nudge-card@1.0.0` (core contract + renderer); `outbox/
<today>.md`, `outbox/delivered.log`, `outbox/pending-gmail/` (connectors-
owned); the reply-grammar footer plan 34 parses; `beeper-send.sh
--reminder` for plan 34's snooze; DECISIONS `notify-self-is-a-send`.

## Proof of done
- `bash scripts/test-all.sh` green including the three new suites
  (render, beeper-out, deliver); `oss-guard.sh` clean with beeper-out's
  POST present and a guard-less copy failing.
- Fixture: same batch → identical text in outbox and in the stub-captured
  POST body; rerun is a no-op; foreign chat id refused with zero HTTP calls.
- Live: one real fired batch delivered to Beeper "Note to self" (chatID 1),
  mirrored in `outbox/`, one `delivered.log` line, second tick `nothing
  new`.

## Out of scope
- Parsing replies / applying `done|snooze|skip|never|not-them|wrong-tier`
  (plan 34, feedback ledger) — this plan only defines the footer text.
- WhatsApp/iMessage self-chats, third-party push (ntfy/Pushover) — rejected
  in the research note (network metadata / third-party data holding).
- Sending to any recipient other than the user (permanently).
- Query and brief skills (stay in plan 07).
- A daily-hour digest scheduler or per-wake-up messages.
- Expiring or re-sending undelivered batches held by quiet hours beyond
  "next tick outside the window".

Status: Ready

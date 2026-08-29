# Plan 17: Composio retirement & direct Google lanes

Status: Ready
Package: connectors (composio-in teardown; gmail-in, calendar-in build) + core
(contract wording) + ingestion (spec pointer) + root docs
Depends-on: 01, 14; decision `composio-retired`
Branch: chunk-17-composio-retirement (stream-ingestion worktree)

## Objective

Execute the composio-retired decision: delete `packages/connectors/composio-in/`
(git history is the archive) and scrub composio from every live path; build
`packages/connectors/gmail-in/` and `packages/connectors/calendar-in/` as
capture-sweep skills driven by the **first-party claude.ai connectors**, emitting
capture-event **1.2.0** into `inbox/` through the shared
`packages/connectors/scripts/normalize-capture.sh`. LinkedIn stays on the Beeper
lane — no linkedin lane rebuild. Close the plan-14 caveat (Gmail To/Cc and
calendar organizer/creator field shapes live-verified on the new lanes).

## Transport facts (bind every unit below)

- The first-party connectors are **in-session MCP tools, not a CLI**. The new
  sweeps are session-driven: a SKILL.md instructs the running Claude session to
  call the MCP tools, then pipe each item through `normalize-capture.sh` via
  Bash. No `composio execute`-style shell-outs exist anymore.
- **Calendar tool names verified in-session 2026-08-29** (server
  `mcp__claude_ai_Google_Calendar__*`): `list_calendars`, `list_events`,
  `search_events`, `get_event`, `suggest_time`, `respond_to_event`,
  `create_event`, `update_event`, `delete_event`.
- **Gmail tool names NOT pre-verified** (server `mcp__claude_ai_Gmail__*`;
  requires in-session authentication first). Gmail tool names and response
  field shapes are **verify-live-then-wire** — the same discipline the retired
  composio skills used for unverified fields. The gmail-sweep SKILL.md ships
  with its tool names and `jq` field paths explicitly marked `VERIFY-LIVE`, and
  a mandatory step 0: enumerate the available `mcp__claude_ai_Gmail__*` tools;
  if names differ from what is written, stop and report rather than guess.
- **Read-only against the account, hard rule** (draft-never-send; capture is
  read-only): the sweeps may call only list/get/search-class tools. For
  Calendar, `create_event`, `update_event`, `delete_event`, and
  `respond_to_event` are explicitly banned and must be named as banned in the
  SKILL.md (`suggest_time` is unused). For Gmail, any send/draft/modify/label
  tool is likewise banned by name once enumerated.

## What carries over from composio-in (the intelligence, not the transport)

The plan text below is the carrier — workers must NOT read `composio-in/`
(U1 deletes it in parallel; git history holds the originals).

- **Gmail typing rules** (unchanged): `voice-note` when the subject contains
  literal `[ra]` (case-sensitive); `linkedin-notification` when the From
  address's domain is `linkedin.com`/`*.linkedin.com`; default `email`.
  Finer triage is the filing engine's job, never the sweep's.
- **Ledger discipline** (per lane, under `data/connectors/<lane>/` —
  connector-local runtime state, never in the shared store): `processed.log`
  (append-only dedup ledger; gmail keyed by Gmail `messageId`, calendar keyed
  by `<event-id>:<updated-timestamp>` so an edited event re-captures as a NEW
  event) plus a `checkpoint`/window bound. Append to the ledger **only after
  `normalize-capture.sh` exits 0** for that item; on exit 1 the item is
  quarantined by the normalizer (`inbox/quarantine/` + reason file) and the
  sweep continues — never delete, never abort the batch, never advance state
  past a failed item.
- **Envelope semantics** (capture-event 1.2.0, plan 14): `captured_at` = the
  sweep's own run time; `occurred_at` = the email's Date header / the event's
  start (`start.date` all-day form normalized to `T00:00:00Z`); `--hint` per
  participant in `"Name <email>"` form as seen — gmail: From + every To + Cc;
  calendar: organizer + creator + every attendee. Never filter out the user's
  own address (filtering is ingestion's job).
- **Body + transport rule**: the body is the provider resource — gmail:
  `Subject: <subject>`, blank line, message text; calendar: the event resource
  pretty-printed as JSON. The MCP tool result is the new "wrapper": archive the
  unmodified per-item tool output at `<store-dir>/archive/raw/<capture-id>.json`
  (compute the id up front, pass via `--id`) so the provenance trail survives
  the transformation.
- **Recurring events**: capture concrete in-window instances, not series
  masters — verify live which `list_events` parameter (if any) expands
  recurrences, and record the finding in the SKILL.md.
- **Windows**: gmail first run bounded to the last 30 days, then
  checkpoint-bounded; calendar window past 30 / upcoming 60 days from "now".
- Backfill mode and the one-shot contacts-seed are **deferred** — see Out of
  scope.

## New per-lane mapping (extends plan 14's table)

| Lane (`source`) | `type` | `occurred_at` | `participant-hints` | body |
|---|---|---|---|---|
| `gmail-in/gmail` | `email` (`voice-note` for `[ra]` subjects; `linkedin-notification` for linkedin.com From-domains) | Date header | From, To, Cc — `"Name <email>"` as seen | `Subject:` line, blank line, message text |
| `calendar-in/calendar` | `calendar-event` | event start (UTC) | organizer, creator, every attendee | provider event resource, pretty-printed JSON |

`<connector>/<lane>` form per `packages/core/contracts/capture-event.md`
(1.2.0); the contract's own examples are updated in U5. Existing
`composio-in/*` and bare-source events already in the store remain valid
(source is a free string) — `check-sync.sh` must not FAIL them.

## Work units

### Phase 0 — orchestrator prep (in-session, no worker)

**U0. Capture live Calendar shapes.** Depends-On: —
Call `mcp__claude_ai_Google_Calendar__list_calendars` and `list_events`
(a window containing events with attendees + organizer + creator). Record the
exact response field names — this **closes the calendar half of the plan-14
caveat** (organizer/creator shape) before any code is written. Transcribe the
shapes into synthetic-PII fixture drafts (reserved domains/numbers only, per
`pii-egress-allowlist` — never real values) in the scratchpad, and paste shapes
+ verified field paths into U3's brief.
Acceptance: fixture drafts exist; organizer/creator/attendee field names
recorded with the tool call as evidence.

### Phase 1 — teardown + build (one parallel message, 5 dev-workers)

**U1 [worker W1, connectors + root docs]. Teardown.** Depends-On: —
- Delete `packages/connectors/composio-in/` entirely (skills, fixtures,
  package.md). Git history is the archive.
- `packages/connectors/package.md`: update `gmail-in`/`calendar-in` sub-package
  descriptions to name the first-party claude.ai connectors as the transport;
  update "Built by" (gmail-in, calendar-in → plan 17). Remove any remaining
  composio wording.
- Root `CLAUDE.md` (worktree copy): replace the "currently a Composio account
  as the hub (see DECISIONS.md `composio-hub`)" clause with first-party
  connector wording citing `composio-retired`.
- Remove `.gitkeep` files under `gmail-in/`/`calendar-in`? **No** — leave them;
  U2/U3 own those directories (avoid file races).
- Grep the worktree for `composio` case-insensitively; report every remaining
  hit outside `docs/plans/`, `docs/DECISIONS.md`, `docs/ROADMAP.md`, and this
  plan (those are records). Do not fix hits owned by other units (U5, U6, U7,
  U8) — list them in the report.
Acceptance: `composio-in/` gone; the three files above composio-free; hit list
reported.

**U2 [worker W2, connectors/gmail-in]. Gmail lane build.** Depends-On: —
Files: `packages/connectors/gmail-in/package.md`,
`gmail-in/skills/gmail-sweep/SKILL.md`, `gmail-in/scripts/classify.sh`,
`gmail-in/fixtures/*.json` + `fixtures/README.md` (replaces `.gitkeep`).
- `package.md` modeled on `beeper-in/package.md` (purpose, call convention,
  provides/consumes — consumes `capture-event@^1.2`); states the read-only
  tool constraint and the session-driven transport.
- `SKILL.md`: session-driven incremental sweep — step 0 tool enumeration (see
  Transport facts; names + field paths marked `VERIFY-LIVE`), checkpoint-bounded
  query (30-day bound on first run), per-message dedup against
  `data/connectors/gmail/processed.log`, typing via `scripts/classify.sh`,
  hints/occurred_at/body per the mapping table, raw archive per the transport
  rule, `normalize-capture.sh` call with `--source gmail-in/gmail`,
  append-after-success ledger, quarantine-continue/never-delete/never-abort
  failure posture, and an end-of-run count summary. Must state it is invokable
  as a single skill run (chunk 19 wraps it; no scheduling here).
- `scripts/classify.sh` (bash 3.2): stdin or args = subject + from-address →
  prints `voice-note` / `linkedin-notification` / `email` per the typing rules.
  Deterministic and testable offline.
- Fixtures: best-guess first-party Gmail tool output shapes (Gmail API
  resource conventions), synthetic PII only — `email.json`,
  `email-voice-note.json`, `email-linkedin-notification.json`, plus
  `malformed-junk.txt` for quarantine coverage. `fixtures/README.md` marks the
  pack **best-guess, corrected at Phase 3 live-verify** and lists which fields
  the plan-14 caveat needs confirmed (To/Cc shapes).
Acceptance: files exist; `classify.sh` runs under bash 3.2; every unverified
tool name/field path carries a `VERIFY-LIVE` marker; no banned-tool usage.

**U3 [worker W3, connectors/calendar-in]. Calendar lane build.** Depends-On: U0
Files: `packages/connectors/calendar-in/package.md`,
`calendar-in/skills/calendar-sweep/SKILL.md`,
`calendar-in/scripts/extract-hints.sh`, `calendar-in/fixtures/*.json` +
`fixtures/README.md` (replaces `.gitkeep`).
- `package.md` as U2's, for the calendar lane; names the verified tool set and
  the four banned mutating tools explicitly.
- `SKILL.md`: enumerate ALL calendars via `list_calendars` (work + personal,
  per `multiple-google-calendars`), per-calendar `list_events` over the
  past-30/next-60-day window, per-calendar failure isolation (log and skip),
  recurring-instance handling (verified param recorded from U0/Phase 3), dedup
  via `data/connectors/calendar/processed.log` keyed
  `<event-id>:<updated-timestamp>`, hints via `scripts/extract-hints.sh`,
  `--source calendar-in/calendar --type calendar-event`, occurred_at = event
  start, raw archive, append-after-success, quarantine-continue posture, count
  summary, single-skill-run invokability. Uses U0's verified field names (no
  `VERIFY-LIVE` markers where U0 already verified).
- `scripts/extract-hints.sh` (bash 3.2 + jq): event JSON on stdin → one
  `"Name <email>"` line per organizer/creator/attendee (email-only or
  name-only fallback), no self-filtering.
- Fixtures from U0's synthetic drafts: `calendar-event.json` (attendees +
  organizer + creator), `calendar-event-allday.json`, `calendars-list.json`.
Acceptance: files exist; `extract-hints.sh` output matches the hint form
against `calendar-event.json`; only read-tools referenced.

**U4 [worker W4, ingestion]. Onboarding spec pointer.** Depends-On: —
`packages/ingestion/specs/onboarding-tiering-seed.md`: replace the
`connectors/composio-in` backfill references with `connectors/gmail-in` /
`connectors/calendar-in`, noting backfill mode is deferred by plan 17 pending
the Phase 3 tool-surface check (spec sequence otherwise unchanged).
Acceptance: no composio reference remains in the file; deferral noted.

**U5 [worker W5, core]. Contract wording.** Depends-On: —
`packages/core/contracts/capture-event.md`: in the `source` convention, replace
composio examples with `gmail-in/gmail`, `calendar-in/calendar`,
`beeper-in/whatsapp` and reword "the lane half is the Composio toolkit slug" to
"the lane half names the data lane within the connector"; update the second
example event (`composio-in-googlecalendar` id/source →
`calendar-in-calendar`); note that previously written `composio-in/*` sources
remain valid (free string, no migration). **No semver bump** — examples and
prose only; semantics untouched.
Acceptance: contract composio-free except the historical-validity note;
version string unchanged (1.2.0).

### Phase 2 — tests + checker sweep

**U6 [worker W6, connectors/tests]. Capture suite rework.** Depends-On: U1–U3
`packages/connectors/tests/run-capture-tests.sh` (bash 3.2, no npm/jest):
- Point fixture iteration at `gmail-in/fixtures/` + `calendar-in/fixtures/`;
  lane fixtures normalize with `--source gmail-in/gmail` /
  `--source calendar-in/calendar`; generic enum-coverage / occurred_at /
  quarantine tests keep their logic with a composio-free source value.
- Add typing tests driving `gmail-in/scripts/classify.sh` ([ra] subject →
  voice-note; linkedin.com From → linkedin-notification; both-present
  precedence = voice-note; default email).
- Add hint-extraction tests driving `calendar-in/scripts/extract-hints.sh`
  against `calendar-event.json` (organizer + creator + attendees all present,
  fallbacks covered).
Acceptance: suite passes locally; zero composio strings in the file.

**U7 [worker W7, connectors/scripts]. check-sync lane rules.** Depends-On: U1
`packages/connectors/scripts/check-sync.sh`:
- Per-lane case `composio-in/googlecalendar|beeper-in/*` →
  `gmail-in/*|calendar-in/*|beeper-in/*` (occurred_at SHOULD-WARN, per the
  per-lane tables; `composio-in/*` events fall through to generic checks only —
  still valid, never FAIL).
- Reword header/comments composio-free: cite
  `packages/core/contracts/capture-event.md` (1.2.0) and "the plan-14 import
  standard" by number, not filename. Keep the transport-wrapper-leak check
  (`successful`/`logId` keys) — it guards any wrapper.
Acceptance: script runs green on a store containing gmail-in/calendar-in/
beeper-in/composio-in/bare-source events; zero composio strings.

**U8 [checkers, parallel]. Verification.** Depends-On: U1–U7
- C1 (reference sweep): `grep -ril composio CLAUDE.md README.md packages/
  .claude/` from the worktree root must output nothing; report any hit with
  path:line. Silence is proven by echoing the grep exit status, not by empty
  output alone.
- C2 (conformance): new SKILL.md files + fixtures vs. capture-event 1.2.0 and
  this plan's per-lane table (source form, types, occurred_at, hint form,
  wrapper rule, banned tools named); report mismatches.
Then the orchestrator runs `run-capture-tests.sh`,
`run-beeper-capture-tests.sh`, `run-store-tests.sh` — all green before Phase 3.

### Phase 3 — live verification (orchestrator-led, in-session)

**U9. Ledger seeding + calendar live sweep.** Depends-On: U8
In the ingestion worktree's data dir: if legacy `data/connectors/gmail/` /
`data/connectors/googlecalendar/` ledgers exist, copy `processed.log` into the
new lane dirs (`gmail/` is reused as-is; `googlecalendar/processed.log` →
`calendar/processed.log`) — dedup keys are provider-native and
transport-agnostic, so already-captured items are not re-captured. Then run
calendar-sweep against `data/store`; `check-sync.sh data/store` green;
organizer/creator shapes on real output confirmed against U0/U3 (calendar half
of the plan-14 caveat now closed with live evidence).

**U10. Gmail authenticate + live sweep.** Depends-On: U8
Authenticate the first-party Gmail connector in-session; enumerate
`mcp__claude_ai_Gmail__*` tools; record the read-tool names, query/param
surface, and response field names — **To/Cc shapes close the gmail half of the
plan-14 caveat**. Run gmail-sweep against `data/store`; `check-sync.sh` green.
Where live shapes differ from U2's best-guess skill/fixtures, dispatch fix
briefs (SKILL.md field paths + fixture corrections; retry briefs carry the live
output diff; max 2 fix rounds per doctrine). Also record whether the tool
surface offers contacts/backfill-equivalent tooling — feeds the deferred-scope
decision (Out of scope).

**U11. Account teardown + closeout.** Depends-On: U9, U10
- Out-of-repo Composio account teardown checklist: unlink the 3 toolkits,
  revoke/delete the dashboard API key, remove `COMPOSIO_API_KEY` from the cloud
  environment's env vars, uninstall/log out the CLI, delete leftover composio
  connector state dirs in the data dir.
- Re-run both suites + `check-sync.sh`; update `docs/ROADMAP.md` (17 → Done;
  02/04-connector-half rows already point here), memory notes, this plan's
  Status → Done with evidence; GrowthPal `wins_capture` at merge per cadence.

## Proof of done (from ROADMAP §17)

1. `check-sync.sh` green over events produced by BOTH new lanes on a real
   sweep (U9, U10).
2. Capture test suite green; beeper + store suites green (U8, U11).
3. Zero live-path composio references — C1's grep proven empty
   (docs/plans, DECISIONS.md, ROADMAP.md history exempt).
4. Plan-14 caveat closed: Gmail To/Cc and calendar organizer/creator shapes
   live-verified and reflected in skills + fixtures (U0, U9, U10).
5. ROADMAP + memory updated; Composio account torn down (U11).

## Out of scope

- **Backfill mode + one-shot contacts-seed**: deferred, not ported in this
  chunk. Revisit only after U10 records whether the first-party Gmail
  connector exposes equivalent tooling (date-range query, contacts listing);
  if it does, they return as a follow-up unit against
  `onboarding-tiering-seed.md`'s sequence — U4 marks the spec accordingly.
- **Scheduling/launchd**: chunk 19's job. The lanes here only guarantee
  single-skill-run invokability for 19 to wrap.
- **LinkedIn lane rebuild**: none — Beeper lane + inbox-derived
  `linkedin-notification` emails carry LinkedIn signal (`composio-retired`,
  `tos-clean-signals-only`).
- **Filing/matching** of the new events (plans 03/04) and rewriting existing
  `composio-in/*` / bare-source inbox events (valid as written).

Status: Ready

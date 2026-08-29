# Roadmap

Working tracker for the build. Each chunk is one plan in `docs/plans/`, sized so a single
focused session (with subagent fan-out) can complete it. Update Status here as chunks
move; the shareable build-plan artifact is the pretty view, this file is the truth.

> **2026-08-29 pivot (decision: composio-retired):** Composio is dropped entirely.
> Gmail/Calendar move to the first-party claude.ai connectors driven by Claude directly.
> Chunks 17–21 below carry the pivot and the next build phase: live query/chat, scheduled
> syncs, a live capture trial, and the proactive calendar layer.

## Chunks

| # | Plan | Package | Depends on | Status |
|---|---|---|---|---|
| 01 | Contracts & store | core | — | Done (2026-08-29, branch chunk-01-contracts-and-store) |
| 02 | Capture & Gmail inbox | connectors/gmail-in (+ core's inbox contract) | 01 | Superseded — folded into 17 (its classification/normalizer intelligence survives there) |
| 03 | Filing engine | ingestion | 01 | Done (2026-08-29, stream-filing; 16 goldens green, 16 T3 eval cases wired) |
| 04 | Calendar connector & matching | connectors/calendar-in + ingestion | 01 | Ready — connector half folded into 17; the ingestion-side matching (co-attendance) is what remains here |
| 05 | Signal engine | attention (detection/ranking) | 01, capture lanes (13, 17), 04 (co-attendance) | Ready — blocked on 12's amendment unit; briefs must honor plan 15 touchpoints |
| 06 | Wake-up scheduler | attention (queue/sweeps) | 01; orchestrates 03/05 outputs | Ready — blocked on 12's amendment unit; briefs must honor plan 15 touchpoints |
| 07 | Output skills & adapters (briefs, nudge cards, file-out/gmail-out; query skill superseded by 08) | query + connectors/file-out, gmail-out | 01; 06 for nudge firing | Ready — gmail-out must target the first-party Gmail connector (composio-retired) |
| 08 | Chat MCP & query data layer | query (MCP server) + core (stats contract, fixtures) | 01 | Done (2026-08-29, stream-mcp; 6 read-only tools implemented) — live wiring is chunk 18 |
| 09 | Infrastructure: cloud runtime, data-repo discipline, egress | core (sync script) + harness guards + docs | 01; integrates 06, 19 | In progress (2026-08-29, stream-infrastructure; data repo live) |
| 10 | Composio access layer | connectors/composio-in (+ shared normalizer) | 01 | Retired (was Done 2026-08-29) — teardown executes in 17; the shared normalizer + import standard survive |
| 11 | Messaging-connectors research | docs only (fed 13) | — | Done (2026-08-29, stream-connectors) |
| 12 | Cadence & capacity-aware scheduling (routine map, week-plan contract, capacity-aware nudge selection) | attention + core (week-plan contract) + docs/runtime-cloud.md | 01; amends 05/06 (its amendment unit must land before either is dispatched); integrates 09 | Ready — critical path for the proactive layer |
| 13 | Beeper capture connector (personal chats: whatsapp/linkedin/matrix) | connectors/beeper-in (+ shared normalizer) | 01 | Done (2026-08-29, stream-connectors; LIVE: launchd 15-min, 3 networks) |
| 14 | Import standard (capture-event 1.1/1.2: typing, occurred_at, <connector>/<lane> source, transport rule; formerly "Composio import standard" — the contract is transport-agnostic and outlives Composio) | core (contract) + connectors (sweeps, normalizer, beeper alignment) | 01, 13 | Done (2026-08-29; suites capture 82, beeper 70, store 20 green). Caveat: Gmail To/Cc + calendar organizer/creator field shapes never live-verified — re-verify on the new direct lanes in 17 |
| 15 | Preference & personalization layer | core (profile/ranking-weights/wakeup 1.1) + ingestion/attention specs+goldens | 01, 08 | Done (2026-08-29, stream-personalization) |
| 16 | Eval harness: tool/agent/skill tiers | core (eval-case contract, 4 runners) + query/ingestion/attention cases | 08, 15 | Done (2026-08-29, stream-personalization) |
| 17 | Composio retirement & direct Google lanes (gmail-in, calendar-in on first-party claude.ai connectors) | connectors (composio-in teardown; gmail-in, calendar-in) + docs | 01, 14; decision composio-retired | Done (2026-08-29; suites 99/70/20 green, both lanes live-verified on real sweeps, plan-14 caveat closed, composio-free grep-proven, CLI logged out). Residual: recurrence-expansion VERIFY-LIVE awaits a recurring event in-window; dashboard key revocation + Google-grant revocation are user steps |
| 18 | Query & chat live wiring (register the MCP server against the live store; chat with your own data) | query (server config) + harness docs | 08 | Done (2026-08-29, query-live; root `.mcp.json` registration, smoke-live script, chat-setup docs; fixtures smoke 6/6, store+query suites green, checker CLEAN; decision query-mcp-registration). Residual: live-store smoke + chat verification await 20's filed backlog — chunk 22 |
| 19 | Scheduled syncs runner (one configurable scheduler for all capture lanes; restart-safe) | connectors/scripts + core (sync-lanes contract) | 13; 17's lanes join via config rows when they land | Done (2026-08-29, chunk-19-sync-scheduler; suites 20/82/70/64 green, beeper migrated, reboot-sim + config-change proven; live firing awaits a machine-side TCC grant — see plan 19, affects plan 13's job too) |
| 20 | Backfill blitz & ship-day shakedown (file the real backlog, prove the loop end to end, TODAY) | cross-package (runs the machinery, builds none) | 03, 13, 18 | Planned — SHIP GATE, runs today |
| 21 | Calendar intelligence & event proposals (tell/schedule from messages; propose events, draft-only) | attention + query + connectors/calendar | 04, 05, 06, 17, 18 | Planned — plan file to author |
| 22 | Live-data query sync & verification (plan 18 close-out: smoke 6/6 over the filed live store, real chat with citations, legacy user-scope registration removed) | query (verification only — runs the machinery, builds none) | 18, 20 (filed backlog) | Blocked on 20 — run as soon as the backlog is filed |
| 23 | Harness context economy (content-bearing briefs; warm per-package workers via SendMessage; fork guidance; capsule-sized manifests) | harness docs (`.claude/rules`, `.claude/context`) — no machinery | — | Done (2026-08-29, worktree-harness-context-economy) |

Plans 05 and 06 are two plans within one package (`attention`) — see DECISIONS.md:
attention-merge. Historical plan-number collisions (11/12 renumbered to 13–16 at merge)
are documented in the plan files; in-file references to old numbers inside merged
package specs/commits are historical.

## New chunks — context, agent path, deliverables

Each block is what the plan-architect needs to author the full plan, and what "Done"
means. Every chunk follows the standing flow: plan-architect writes the plan file →
orchestrator dispatches dev-workers per the splitting rule → checkers verify → suites
run → merge → status logged (see Merge cadence).

### 17 — Composio retirement & direct Google lanes

**Context.** Decision composio-retired. Composio was the access hub for gmail/calendar/
linkedin pulls (plan 10); it is dropped as too B2B for a personal tool. The claude.ai
first-party Gmail and Google Calendar connectors are available in-session and become
the pipes. The import standard (capture-event 1.2.0, plan 14) is transport-agnostic
and is the conformance bar for the new lanes.
**Work.** (a) Teardown: retire `connectors/composio-in` (code archived or deleted,
launchd/scripts/env-var references removed, package.md updated); sweep the repo for
composio references in live paths. (b) Build up: `connectors/gmail-in` and
`connectors/calendar-in` capture skills driven by the first-party connectors, emitting
capture-event 1.2.0 into `inbox/`, reusing the shared normalizer. LinkedIn stays on
the Beeper lane.
**Agent path.** stream-ingestion worktree; one dev-worker for teardown, one per new
lane, parallel; checker sweep for stray composio references before merge.
**Deliverables / proof of done.** `check-sync.sh` green over events produced by both
new lanes on a real sweep; capture test suite green; zero live-path composio references
(grep-proven); the plan-14 caveat closed — Gmail To/Cc and calendar organizer/creator
shapes verified live on the new lanes; ROADMAP + memory updated.

### 18 — Query & chat live wiring (DONE — see plan file; live-data residual is chunk 22)

Landed 2026-08-29 (worktree `query-live/`, plan `docs/plans/2026-08-29-18-query-live-wiring.md`):
root-committed `.mcp.json` (repo-relative, `--store data/store` per decision
query-mcp-registration), `packages/query/tests/smoke-live.sh` (all six tools,
data-independent, degraded-stats = FAIL), `docs/chat-setup.md`, package.md refresh.
Fixtures smoke 6/6; store/query suites green; hygiene checker CLEAN. The original
brief follows for the record.

**Context.** The query MCP server (plan 08) is fully implemented — six read-only tools
(`search_people`, `get_person`, `list_interactions`, `get_interaction`,
`get_contact_stats`, `suggest_reachouts`) — but has never been registered against the
live store, which lives in the private data dir (currently the ingestion worktree's
`data/store`). The user's declared first priority: chat with what's already captured.
**Work.** MCP registration config (`.mcp.json` or documented `claude mcp add` line)
pointing the server at the live store path via env/flag; a smoke script that calls all
six tools against the live store and prints results; docs for the chat entrypoint
(how a session queries the store).
**Agent path.** stream-mcp worktree; single dev-worker (config + smoke script is 1–2
units); orchestrator verifies by actually chatting: run the T2 query eval suite, then
live-query real people from the store.
**Deliverables / proof of done.** All six tools answer over the live store with real
data; T2 eval suite (`packages/query/evals/suite.txt`) green; a documented one-line
setup any session can use; at least one real end-to-end chat transcript confirming
answers cite real captured interactions.

### 19 — Scheduled syncs runner

**Context.** Capture must not depend on remembering to run sweeps. Beeper already has
a hand-rolled launchd 15-min job; gmail/calendar (17) will need the same. One runner,
many lanes, user-configurable.
**Work.** A `sync-scheduler` under `connectors/scripts/`: a config file (lane name,
command, interval, enabled flag) as a small contract in core; an installer that
generates/loads per-lane launchd jobs on macOS (launchd survives reboots natively —
that is the restart story; document catch-up-on-wake behavior); `status` subcommand
showing last-run/next-run/last-exit per lane; logging with rotation; migrate the
existing beeper job into it.
**Agent path.** stream-connectors or stream-infrastructure worktree (single-writer:
scripts live in connectors, doctrine in infrastructure docs); two dev-workers —
runner+config vs. installer+migration; checker verifies job files.
**Deliverables / proof of done.** All active lanes running under the scheduler;
`status` output correct; a reboot (or launchd unload/load simulating one) after which
jobs fire again with no manual step; beeper's legacy job removed; config change
(interval/disable) takes effect without editing code.

### 20 — Backfill blitz & ship-day shakedown (SHIP GATE)

**Context.** Ship deadline is 2026-08-30 — there is no window for a soak test. The
store already holds a real backlog (46 inbox events: 25 beeper, 15 gmail, 4 calendar,
1 linkedin, 1 quarantine) that has never been filed. Filing that backlog and proving
the whole capture→file→query loop on it, today, is the compressed live test: real
data, full pipeline, immediate verdict. Longitudinal quality watching moves to
post-ship monitoring (below) — it is no longer a pre-ship gate.
**Work.** No new machinery. (a) Run the debrief/filing skill over the full real
inbox backlog; quarantined/unfileable events get triaged, not dropped. (b) Audit:
`check-sync.sh` clean (zero loss), `validate-store.sh` green on the filed store.
(c) Fresh-sweep round-trip: trigger one live beeper + one gmail sweep, file the new
events, confirm they land end to end. (d) Query shakedown: hit all six `spomni-query`
tools against the filed store; answers must cite real captured interactions.
(e) A fast user pass over the filed people list: obvious mis-merges/dupes fixed or
logged as known-issues for the ship notes.
**Agent path.** Orchestrator-led, same day: filing runs via the ingestion debrief
skill (batched, parallel checkers audit after each batch); defects found get ONE
fix-dispatch round max (fix policy) — anything deeper becomes a known-issue, not a
ship blocker unless it loses data.
**Deliverables / proof of done (all TODAY).** Backlog 100% filed or explicitly
quarantined with reasons; both audit scripts green; fresh-sweep round-trip proven on
both lanes; all six query tools returning real cited answers; a short ship-notes list
of known issues. Zero data loss is the only hard blocker.

### 21 — Calendar intelligence & event proposals

**Context.** The proactive layer's calendar half: the agent should read the calendar
for context ("you're seeing Sam Thursday"), connect messages to scheduling intent
("we should grab coffee" → propose a slot), and propose new events. Extends
draft-never-send to calendar writes: the agent PROPOSES events (a wake-up card with a
ready-to-confirm event); the human confirms before anything is created, and any event
with other attendees is always confirm-first. Reminders/when-to-text themselves are
plans 05/06/12 — this chunk is the calendar-aware input and the event-proposal output.
**Work.** Calendar read context in query/briefs (upcoming-meetings surface); a
message→scheduling-intent detector feeding the signal engine (05); an event-proposal
card type in the wake-up contract; a confirm-then-create flow using the first-party
Google Calendar connector.
**Agent path.** After 05/06 land: attention worktree for detection/queue parts,
stream-mcp for the query surface, one dev-worker per package, parallel; plan-architect
must reconcile with the plan 12 week-plan contract.
**Deliverables / proof of done.** Briefs show upcoming calendar context with correct
matching to store people; a scheduling-intent message in the inbox produces an event
proposal in the wake-up queue (golden-tested); confirming a proposal creates the event
via the connector, declining files silently; zero events ever created without explicit
confirmation (eval-guarded).

### 22 — Live-data query sync & verification (plan 18 close-out)

**Context.** Chunk 18 wired and proved the query surface against fixtures; the live
proof was blocked because no live store had filed people yet (the 46-event backlog is
chunk 20's ship gate). This chunk is the deferred live half — verification only, no
new machinery. Overlaps with 20(d)'s query shakedown: if 20 completes its shakedown
with cited answers, 22 collapses to the registration cleanup + smoke re-run.
**Work.** (a) Confirm the checkout's `data/store` points at the filed live store
(per docs/chat-setup.md; symlink flip is a local act). (b) `bash
packages/query/tests/smoke-live.sh` — all six tools PASS, non-degraded stats, store
byte-untouched. (c) Live chat: ≥3 real questions in a fresh session via the
project-scope registration; answers cite real store paths with provenance intact
(evidence = tool names + citation counts, never content). (d) Remove the legacy
user-scope `spomni-query` entry (`claude mcp remove spomni-query` in the old project
scope) so exactly one registration exists.
**Agent path.** Orchestrator-run in any current checkout; no workers needed.
**Deliverables / proof of done.** Smoke exit 0 over the filed store; chat citations
verified; exactly one registration; plan 18's "Proof of done" checklist fully closed
out in its plan file.

### 23 — Harness context economy

**Context.** Worker agents were spawning cold and regaining context — re-reading
CLAUDE.md, package manifests, and contracts — before every edit; context regain,
not the edits themselves, dominated run time.
**Work.** Doctrine-only, no machinery: briefs carry content inline instead of bare
paths (brief template §2/§4, with the >2-files-before-first-edit litmus); serial
same-package units continue a warm dev-worker via SendMessage instead of spawning
fresh; `fork` for units whose investigation already lives in the orchestrator
conversation; `package.md` manifests kept capsule-sized. Codified as the new
"Context economy" section of `.claude/rules/orchestration.md`.
**Deliverables / proof of done.** Template, orchestration rules, and rules index
updated; roadmap row 23 added. No package code touched.

## Execution order (current)

**Ship deadline: 2026-08-30.** Pre-ship (today): 18 is done enough to chat (server
registered as `spomni-query`); **20 runs NOW** — backfill filed, loop proven, ship
notes written. 17 and 19 squeeze in today only if 20 clears early; otherwise they are
day-one post-ship items (the beeper lane and composio lanes keep capturing meanwhile,
so nothing is lost by shipping first).

Post-ship order:
1. **17** — composio teardown + direct gmail/calendar lanes.
2. **19** — scheduled syncs runner (needs 17's lanes to exist).
3. **Post-ship monitoring** — the longitudinal organization-quality watch that used to
   be 20's trial: periodic check-sync/validate-store audits, defects filed per package.
4. **12 (amendment unit) → 05 + 06 → 07** — the attention layer, honoring plan 15
   personalization touchpoints.
5. **21** — calendar intelligence, once 05/06 exist to carry its signals and cards.
6. **09** — infrastructure continues alongside; **04**'s matching half rides with 05's
   co-attendance needs.

## Streams (parallel-session worktrees)

Long-lived worktrees live in `../relationship-agent-worktrees/`, one per stream; each
stream runs its chunks serially (branch per chunk off `main`, merge back, `git merge main`
to resync — never rebase). Streams may run concurrently with each other.

| Worktree | Branch | Territory | Chunks |
|---|---|---|---|
| `ingestion/` | `stream-ingestion` | connectors-in + ingestion (direct first-party lanes: gmail, calendar; beeper lane; user inputs) | 17 → 04 (matching) |
| `mcp/` | `stream-mcp` | query + connectors-out (answer surface, briefs, model access) | 07 (06-dependent parts last; after 18 merges — 18 moved to `query-live/`) |
| `query-live/` | `chunk-18-query-live-wiring` | chunk-18 wiring (query territory on loan from `mcp/`) — 18 merged; worktree retires after chunk 22's verification runs | 18, 22 |
| `infrastructure/` | `stream-infrastructure` | cloud runtime + data-repo discipline + egress hygiene + sync scheduling | 09, 19 |
| (new) `attention/` | `stream-attention` | signal engine + wake-up queue + cadence | 12 → 05 → 06 → 21 (attention parts) |

The single-writer rule still applies across streams: a stream never edits another
stream's packages.

### Merge cadence (keep main close, keep branches short-lived)

- A completed chunk merges to main **in the same session its checker passes** — chunks
  are sized for one session precisely so nothing needs to wait.
- At most **one** completed-but-unmerged chunk per stream at any moment; anything
  unmerged for more than a day is an escalation, not a backlog item.
- Docs-only work merges to main immediately; it never rides along waiting for code.
- After any merge to main, every active stream resyncs (`git merge main`) at its next
  session start, before new work.
- **Status logging (GrowthPal):** when a chunk reaches Done (merged) the orchestrator
  logs it via the claude.ai Growth Pal connector — `wins_capture` with the chunk
  number, what shipped, and the proof-of-done evidence; blockers or abandoned
  approaches worth remembering go to `struggles_capture`. One log per chunk, at merge
  time, no PII from the store in the log text.
- Note what fast merging does NOT do: a pushed branch in a public repo is already
  world-readable, merged or not. Data safety lives at the push boundary (pii-guard,
  plan 09), never in merge speed.

## Post-ship monitoring → v1 (exit criteria)

Shipping (2026-08-30) is not v1. After ship, the monitoring loop watches real usage;
once the attention layer joins, the original exit criteria gate the v1 tag:
phone-to-filed with zero manual steps; ≥80% meeting auto-match; ≥1 useful signal
nudge/week with zero bare cadence reminders; ad-hoc reminders fire on time; ≥3:1
give-to-ask ratio; zero data loss. All six hold → tag v1, open the repo.

## Later (explicitly deferred)

- Output adapters beyond file/terminal + email (Slack, etc.)
- iOS-Shortcut→GitHub capture lane; WhatsApp/iMessage local bridges (at-your-own-risk docs)
- Local embeddings for fuzzy retrieval
- Auto-brief the morning of meetings (a standing wake-up)
- Harness Stage 2+ (gates, attestation, shipping pipeline) once there's CI worth gating
- Machinery-as-plugin packaging: ship skills/agents/hooks as a Claude Code plugin so any
  user opens their own private data repo and installs the machinery — the open-source
  distribution story (per cloud-native-runtime)

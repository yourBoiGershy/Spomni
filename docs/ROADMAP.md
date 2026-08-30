# Roadmap

Working tracker for the build. Each chunk is one plan in `docs/plans/`, sized so a single
focused session (with subagent fan-out) can complete it. Update Status here as chunks
move; the shareable build-plan artifact is the pretty view, this file is the truth.

> **Mission (decision `mission-ingredients-vs-running-cost`, 2026-08-29):** *what a
> friendship is made of, without what it costs to keep.* Every chunk block below carries
> a **Mission test.** line — which running cost it cuts (remembering-to / noticing /
> timing / deciding-who / starting / following-through, or "infrastructure for <cost>")
> and which ingredient (trust / care / intent / time) it is nearest to and how it stays
> clear. A chunk that can't answer doesn't get planned. Scenario map: `docs/USE-CASES.md`.

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
| 05 | Signal engine | attention (detection/ranking) | 01, capture lanes (13, 17), 04 (co-attendance) | Done (2026-08-29, chunk-05-signal-engine; ranking spec w/ plan 12 capacity inversion + budget/hold/floor, 5 new detector specs, signal-scan skill (8 detectors), signals fixture store verified by hand — 3 promoted/1 held/1 suppressed; wakeup-add.sh `--signal-type`; tier-drift evals flip on with 06) |
| 06 | Wake-up scheduler | attention (queue/sweeps) | 01; orchestrates 03/05 outputs | Done (2026-08-30, chunk-06-wakeup-scheduler; wakeup-queue.sh 7 ops incl. absorbed confirm/decline + acted-on, budget/adjacency/idempotent fired-batch, proposal-confirm.sh retired; sweep skill = daily-attention entry (skip-when-unbuilt: calendar-reconcile 04, output adapter 07); undebriefed-mention spec; queue suite 48 green; Wave C unattended run PASS. Residual: mention path exercised only via its ≥3-give gate — first real mention lands with 07's rendered batches) |
| 07 | Output skills & adapters (briefs, nudge cards, file-out/gmail-out; query skill superseded by 08; + nudge-delivery channel — how a nudge physically reaches the user, see the 07 amendment block) | query + connectors/file-out, gmail-out | 01; 06 for nudge firing; 28 for scheduled delivery | Ready — nudge-card + adapters + delivery channel moved to plan 33 (built 2026-08-30); remaining scope = query + brief skills |
| 08 | Chat MCP & query data layer | query (MCP server) + core (stats contract, fixtures) | 01 | Done (2026-08-29, stream-mcp; 6 read-only tools implemented) — live wiring is chunk 18 |
| 09 | Infrastructure: cloud runtime, data-repo discipline, egress | core (sync script) + harness guards + docs | 01; integrates 06, 19 | In progress (2026-08-29, stream-infrastructure; data repo live) |
| 10 | Composio access layer | connectors/composio-in (+ shared normalizer) | 01 | Retired (was Done 2026-08-29) — teardown executes in 17; the shared normalizer + import standard survive |
| 11 | Messaging-connectors research | docs only (fed 13) | — | Done (2026-08-29, stream-connectors) |
| 12 | Cadence & capacity-aware scheduling (routine map, week-plan contract, capacity-aware nudge selection) | attention + core (week-plan contract) + docs/runtime-cloud.md | 01; amends 05/06 (its amendment unit must land before either is dispatched); integrates 09 | Done (2026-08-29, chunk-12-cadence-capacity; week-plan contract 1.0.0, capacity.sh + 3 goldens + 18 tests, weekly-planning skill, runtime-cloud cadence map; 05/06 amendment notes landed — both unblocked) |
| 13 | Beeper capture connector (personal chats: whatsapp/linkedin/matrix) | connectors/beeper-in (+ shared normalizer) | 01 | Done (2026-08-29, stream-connectors; LIVE: launchd 15-min, 3 networks) |
| 14 | Import standard (capture-event 1.1/1.2: typing, occurred_at, <connector>/<lane> source, transport rule; formerly "Composio import standard" — the contract is transport-agnostic and outlives Composio) | core (contract) + connectors (sweeps, normalizer, beeper alignment) | 01, 13 | Done (2026-08-29; suites capture 82, beeper 70, store 20 green). Caveat: Gmail To/Cc + calendar organizer/creator field shapes never live-verified — re-verify on the new direct lanes in 17 |
| 15 | Preference & personalization layer | core (profile/ranking-weights/wakeup 1.1) + ingestion/attention specs+goldens | 01, 08 | Done (2026-08-29, stream-personalization) |
| 16 | Eval harness: tool/agent/skill tiers | core (eval-case contract, 4 runners) + query/ingestion/attention cases | 08, 15 | Done (2026-08-29, stream-personalization) |
| 17 | Composio retirement & direct Google lanes (gmail-in, calendar-in on first-party claude.ai connectors) | connectors (composio-in teardown; gmail-in, calendar-in) + docs | 01, 14; decision composio-retired | Done (2026-08-29; suites 99/70/20 green, both lanes live-verified on real sweeps, plan-14 caveat closed, composio-free grep-proven, CLI logged out). Residual: recurrence-expansion VERIFY-LIVE awaits a recurring event in-window; dashboard key revocation + Google-grant revocation are user steps |
| 18 | Query & chat live wiring (register the MCP server against the live store; chat with your own data) | query (server config) + harness docs | 08 | Done (2026-08-29, query-live; root `.mcp.json` registration, smoke-live script, chat-setup docs; fixtures smoke 6/6, store+query suites green, checker CLEAN; decision query-mcp-registration). Residual: live-store smoke + chat verification await 20's filed backlog — chunk 22 |
| 19 | Scheduled syncs runner (one configurable scheduler for all capture lanes; restart-safe) | connectors/scripts + core (sync-lanes contract) | 13; 17's lanes join via config rows when they land | Done (2026-08-29, chunk-19-sync-scheduler; suites 20/82/70/64 green, beeper migrated, reboot-sim + config-change proven; live firing awaits a machine-side TCC grant — see plan 19, affects plan 13's job too) |
| 20 | Backfill blitz & ship-day shakedown (file the real backlog, prove the loop end to end, TODAY) | cross-package (runs the machinery, builds none) | 03, 13, 18 | Done (2026-08-29, chunk-20-backfill-shakedown; 45/45 accounted, 15 filed / 27 held / 3 quarantined, both audits green, beeper round-trip proven, query 6/6; gmail filed→query leg user-accepted as known gap; ship notes `docs/ship-notes-2026-08-30.md`) |
| 21 | Calendar intelligence & event proposals (tell/schedule from messages; propose events, draft-only) | attention + query + connectors/calendar | 04, 05, 06, 17, 18 | Done (2026-08-29, chunk-21-calendar-intelligence, merge 5cc5271; built ahead of 05/06/12 with amendment notes in their plans; wakeup 1.2.0 event-proposal contract, confirm-first invariant eval-guarded, `upcoming_meetings` 7th query tool). Residual: live Calendar create unverified (manual); other packages' T3 cases need re-baseline under the fixed runner |
| 22 | Live-data query sync & verification (plan 18 close-out: smoke 6/6 over the filed live store, real chat with citations, legacy user-scope registration removed) | query (verification only — runs the machinery, builds none) | 18, 20 (filed backlog) | Done (2026-08-29, chunk-22-live-query-verify; smoke 6/6 non-degraded over the filed store (21 people), 3 fresh-session chat answers with real citations + provenance labels, legacy local-scope registration removed — exactly one remains, T2 evals 3 pass/2 xfail, store+query suites 10/10 + 29/29; plan 18 proof-of-done closed) |
| 23 | Harness context economy (content-bearing briefs; warm per-package workers via SendMessage; fork guidance; capsule-sized manifests) | harness docs (`.claude/rules`, `.claude/context`) — no machinery | — | Done (2026-08-29, worktree-harness-context-economy) |
| 24 | Onboarding deep backfill & priority seeding (backfill history on first run, seed tiers from participation signals) | connectors (backfill mode on direct lanes) + ingestion (seed pass, extends `specs/onboarding-tiering-seed.md`) + core (config) | 03, 15, 17 | Done (2026-08-29, chunk-24-onboarding-backfill; backfill modes on all 3 direct lanes + isolated namespaces, 6-month configurable window via new core contract onboarding-backfill 1.0.0, participation-signal scoring + onboarding-seed skill; suites 10/109/88/64/23 green, scheduler untouched, confirm-first T3 eval PASS + doctored-FAIL proven; rode along: eval-suite wave-parallel dispatch + smoke tags, eval-case 1.1.0). Also rode along: chunk-21 eval re-baseline debt repaired — 14 legacy ingestion T3 cases rewritten (operative-procedure prompts + fact-based graders), full suite 17/17 PASS; eval-suite rerun-failed mode (eval-case 1.2.0). Residual: live fresh-store onboarding run awaits a user session (first-party connectors) |
| 25 | Backfill episode-split filing (debrief §5b-episodes: multi-day chat events file one interaction per active UTC day, so backfilled history yields real frequency instead of touchpoints=1) | ingestion (debrief skill + onboarding spec) | 03, 24 | Done (2026-08-29, chunk-25-backfill-episode-split; live-onboarding finding, user-approved mid-run; rule exercised live on ~25 multi-day chats → 121+ episode interactions, store clean; `episode-split-multiday` T3 eval PASS×2 + doctored-FAIL, smoke-tagged; full ingestion eval suite 17/17 against the amended skill; checker zero CRITICAL/HIGH. Rode along: eval parallel default 4→9, ~3-min full suite) |
| 26 | Standard import pipeline (stage contract fetch→normalize→triage→judgment→file; every lane conforms — was "import & filing efficiency", reframed 2026-08-29: speed/timing/fleet split out to 27–29, judgment quality to 30) | core (stage contract) + connectors (fetch-to-file conformance, beeper backfill fixes) + ingestion (triage tier) | 24, 25 | Done (2026-08-29, chunk-26-standard-import-pipeline; import-pipeline 1.0.0 in core with conformance declared in all three lanes + ingestion; gmail/calendar SKILLs reworked to cp/jq-from-saved-file with no-transcription invariant + inline-residual rule; beeper coverage-floor D6 fix live-proven — backfill re-run 50 chats/0 events/37 history-clamps, incremental files untouched; triage-inbox.sh 5 precision-first rules + held-by-rule ledger + debrief §1 hook; live calibration 0 false-holds on 160-event corpus; suites 10/116/109/64/23/20 green, eval 19/19 incl. smoke `triage-held-respected`; checker 0 CRITICAL/HIGH, 4 MEDIUM fixed in 1 round). Residual: U12.3 live gmail/calendar fetch-to-file page proof awaits a user-driven sweep session |
| 27 | Import speed & scaling (parallel deterministic stages; person-sharded parallel filing; onboarding wall-clock target) | ingestion (filing waves) + connectors (parallel fetch) | 26 | Done (2026-08-29, chunk-27-import-speed; `shard-filing-batch.sh` deterministic components pre-pass + `specs/parallel-filing.md` wave protocol + debrief shard mode with person-write confinement; live 4-shard wave over the 24-event bench: 0/16 people touched by >1 shard, shard workers filed in 19–26s each vs 293s serial; end-to-end 0.65× vs 0.6× target — near miss at bench scale (cold-start + 3-event serial tail dominate), projected ~0.2–0.25× at onboarding scale where the live pre-pass shows 123 eligible → 8 shards, leftover=0, 7s; onboarding Step 1 lane concurrency doc; chunk-26 perf advisories done (triage O(N+M), ~8% at current size); found+fixed core template blank `tier:` placeholder that failed validate; checker: 1 HIGH (same-name/different-email hints not merged) + 3 MEDIUM fixed in 2 rounds incl. a BSD-sed `[ \t]` portability bug; suites 10/118/109/64/23/23/29 green, eval 20/20 incl. smoke `shard-mode-confined`). Residual: confirm the 0.6× target on the next real onboarding-shaped wave; advisories = mechanical confinement enforcement, ingestion helper lib |
| 28 | Sync timing & autonomous runtime (scheduled headless/cloud sessions run the MCP lanes; gmail/calendar join sync-lanes; per-lane intervals deliberate; catch-up on wake) | connectors/scripts + core (sync-lanes) + infrastructure docs | 19, 26; extends 09 | In progress (2026-08-29, chunk-28-autonomous-sync; plan `docs/plans/2026-08-29-28-autonomous-sync-runtime.md`; built + stub-proven: `mcp-lane-tick.sh` tick/preflight wrapper with triple cost cap, gmail-in 3600s / calendar-in 7200s template rows, scheduler suite 64→92; U5.2–5 live firing + fetch-only proof await a user session — also closes plan-26 U12.3) |
| 29 | Connector fleet (lane roster: enable/disable by config; simultaneous-run isolation; new-lane playbook = fetch impl + normalizer mapping) | connectors + core (sync-lanes/roster) + docs | 26, 28 | Planned |
| 30 | Semantic scoring: user model × relationship kind × judged warrant (priors, local embeddings, rescale — reframed 2026-08-29 from band-tuning; was "scoring accuracy, judgment & weights") | core (user-model, relationship-scoring, embeddings-index, person kind fields, ranking-weights 1.1.0) + ingestion (evidence, embeddings, derive-and-confirm, classify+judge, rescale, review-tiers, evals) + attention (minimal: drift prefilter+judgment, seed/rescale — after 05) | 15, 25, 26 | Built 2026-08-30 on branch `chunk-30-semantic-scoring-user-model` (phases 1–6; all 11 suites green) — live proofs pending: user-model confirm + seed, Ollama embeddings, `review-tiers --all` de-saturation, revision-change proof (plan U19.2–5) |
| 31 | Deterministic structured filing & cold-start priors (file-structured.sh for calendar/metadata-email — no model; `tier_source` provenance, derived tiers written, provisional user-model auto-adopted; onboarding-seed → correction digest) | ingestion (file-structured, review-tiers, onboarding-seed) + core (person 1.2.0, person-set-tier.sh, user-model provisional) + attention (calibrate seed) | 26, 27, 30 | Done (PR #23 + #24, 2026-08-30; live: 221 structured events filed in 18 s / 8 MB on the private store; decision derived-tiers-provisional) |
| 32 | One model call per chat thread (summarize-thread.sh → strict thread-summary JSON; file-thread.sh derives per-day episodes from timestamps, unions duplicate captures by chatID, files cold outreach as `unsolicited`) — replaces the debrief skill's per-day episode model pass for chat captures | ingestion (summarize-thread, file-thread, onboarding-seed 2(c)) + core (person 1.3.0 `inferred-from-thread` provenance) | 31 | In progress (2026-08-30, plan 32 on `chunk-31-deterministic-filing-cold-start`; decision thread-summary-one-call) |
| 33 | Nudge delivery — Beeper note-to-self default (`connectors/beeper-out`, self-only), gmail-self fallback, outbox audit; `profile.md` 1.1.0 `## Notify`; core `nudge-card` 1.1.0 (nudge-first 2-line cards, cap 5, `→ action`, draft on demand via `<n> draft`); `notify` lane on the sync scheduler (deliver-on-tick, quiet hours, chat reminder after post — D5b); sweep step 8 wired | connectors (beeper-out, gmail-out, file-out, deliver-tick, notify lane) + core (nudge-card, profile 1.1.0) + attention (sweep step 8) + ingestion (profile-set-notify) | 06, 28; absorbs plan 07's nudge/adapter units | Built 2026-08-30 on `chunk-33-nudge-delivery` (worktree notify, HEAD 33df4ca; 17/17 suites; 2 live cards delivered to Note-to-self) — PR pending; research `docs/research/2026-08-30-nudge-delivery-and-feedback-loop.md`; decision notify-self-is-a-send |
| 34 | Feedback ledger & active iteration — `feedback-event@1.1` + append-only `signals/feedback.jsonl` (ingestion `feedback-file.sh`, called by every feedback writer); numbered-reply parsing on every sync tick incl. `<n> draft`; corrections → `## Recent corrections` few-shot in judgment prompts + auto eval cases (private manifest mode); **phase 2** (kind outcome weights before enumeration, corrections → user-model revision proposals, weekly assistant report card) gated on ≥2 weeks of live ledger | ingestion (ledger, feedback-parse/recent/to-evals, judge prompt) + core (contract, eval-case 1.3.0) + attention (queue hooks, tier-drift prompt) + connectors (feedback lane) | 31, 33 | Phase 1 built 2026-08-30 on `chunk-34-feedback-ledger` (worktree feedback, HEAD 89e96da; 15/15 suites) — PR pending after 33 (reconcile sync-lanes row count to 5); phase 2 not started; decision feedback-ledger |
| 35 | Zero-setup query path — `/who-next` reads `index.json` + `stats.json` + `people/*.md` directly (bash + jq, `packages/query/scripts/who-next-direct.sh`) when the `spomni-query` MCP server is not up, so a cold cloud/phone session answers in seconds without `npm ci` or a server; same render (`answer-style.md` 1.0.0); data-repo `CLAUDE.md` pointer so a session can clone only the private store | query (who-next-direct.sh, who-next skill fallback) + core (answer-style consumer note) | 07, 08, 31 | In progress (2026-08-30, `worktree-who-next-answer-style`; trigger: 1m27s cloud bootstrap for one question) |
| 36 | Store currency, dedup, remainder speed, preference loop — person.md 1.4.0 as-of/resolved open threads + latest-interaction-wins rule + `refresh-person.sh`; `person-merge.sh` + deterministic merge-candidate detection in onboarding; noise-sender triage + one-call email filing (remainder 7.8 → <2 min); `learn-sweep.sh` turning feedback-ledger corrections into user-model rules + learned eval cases | core (person 1.4.0, person-merge) + ingestion (currency spec, thread-summary 1.1.0, noise triage, refresh-person) + attention (learn-sweep) | 31, 32, 34 phase 1 | Proposed (2026-08-30, plan 36) |

Plans 05 and 06 are two plans within one package (`attention`) — see DECISIONS.md:
attention-merge. Historical plan-number collisions (11/12 renumbered to 13–16 at merge)
are documented in the plan files; in-file references to old numbers inside merged
package specs/commits are historical.

## New chunks — context, agent path, deliverables

Each block is what the plan-architect needs to author the full plan, and what "Done"
means. Every block opens with a **Mission test.** line (see the note at the top); the
plan-architect copies it into the plan's header. Every chunk follows the standing flow: plan-architect writes the plan file →
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

### 24 — Onboarding deep backfill & priority seeding

**Context (from the chunk-20 live run, 2026-08-29).** The ship-gate backfill only
filed what the incremental sweeps had already captured — a fresh install must
instead backfill real history on first onboarding, then seed priorities. The
existing spec `packages/ingestion/specs/onboarding-tiering-seed.md` already
defines the sequence (backfill sweeps → filing → `build-stats.sh` → suggested
tiers → user-confirmed writes, untiered is valid) but is frequency-only and
still references the retired composio backfill mode.
**Work.** (a) Port backfill mode to the direct lanes (gmail-in, calendar-in,
beeper-in): date-range window, isolated checkpoint namespace, default window
**6 months back, configurable on user request** (core config contract).
(b) Extend the tier-suggestion mapping beyond frequency to **participation
signals**: user replied/initiated → strong initial boost; co-attendance at an
event with the user → boost; captured-but-never-answered senders (cold pitches,
unanswered invites) → very low; group chats where the user never participates →
low. Chunk-20 live examples recorded in the private ship note. (c) Keep every
write user-confirmed per the spec's no-guilt presentation rules — signals
suggest, the human tiers.
**Agent path.** After 17: connectors worktree for backfill mode, ingestion for
the seed pass amendment; plan-architect reconciles with plan 15's
stated-preference provenance (stated always outranks derived).
**Deliverables / proof of done.** Fresh-store onboarding run backfills the
configured window on all three lanes (capture suites green, check-sync clean on
backfilled events); tier suggestions carry a score breakdown naming their
signals; the chunk-20 examples rank correctly (unanswered pitch = very low,
non-participating group = low, active thread = boosted); zero tier writes
without confirmation (eval-guarded); window override honored end to end.

### 26 — Standard import pipeline

**Context (reframed 2026-08-29; was "import & filing efficiency").** The
import standard (capture-event 1.2.0, plan 14) standardizes the *output*
of capture, but each lane improvises everything around it. From the live
onboarding run: gmail transits every body through model context twice
(fetch + archive transcription); the calendar leg accidentally proved the
right pattern when an oversized MCP result was saved to disk and processed
programmatically with perfect byte fidelity; beeper backfill over-fetched
pages already covered incrementally and its bridge history is shallow; and
~95% of filing spend is model judgment deciding something is junk (gmail
~5% person-relevant, calendar ~3%). The fix is one uniform stage pipeline
every lane conforms to — **fetch** (raw bytes → disk, dumb, no model) →
**normalize** (shared normalizer → capture-event 1.2.0 → `inbox/`) →
**triage** (deterministic rules) → **judgment** (model, only
maybe-a-person events) → **file** (store writes). Each arrow is a contract
boundary; speed (27), timing (28), fleet (29), and judgment quality (30)
then vary independently. Extract the standard from working code — the
calendar fetch-to-file leg is the reference implementation, not an
abstraction exercise.
**Work.** (a) Stage contract in core (versioned doc): stage names and
responsibilities, what may/may not transit model context, on-disk
artifacts per stage. (b) Fetch-to-file conformance in gmail-sweep/
calendar-sweep: request max page sizes so MCP results land on disk, then
archive/classify/normalize programmatically from the saved file — raw
bytes never transcribed by the model (keeps first-party-mcp-only).
(c) beeper-in conformance + backfill fixes: exclude already-covered pages
from the backfill bound; clamp the window to actual bridge history.
(d) Deterministic triage tier in ingestion: a rule pass (bash/jq —
noreply/marketing senders, self-only calendar events, OTP/security
alerts, LinkedIn invitation notifications, single-message cold pitches)
marks events `held-by-rule` before the debrief skill; reversible (inbox
append-only).
**Deliverables / proof of done.** Stage contract versioned in core and
each lane's package.md declares conformance; a gmail backfill page
processes end to end with no body transcription in-session; beeper
backfill re-run produces zero duplicate-subset events; triage auto-holds
the junk classes from the chunk-24 live corpus with zero false-holds on
its filed events (golden-tested); capture + filing suites green.

### 27 — Import speed & scaling

**Mission test.** Infrastructure for *remembering-to* (bulk) — onboarding must reach first value in minutes, or the user never gets to a single nudge. Nearest ingredient: none; pure cost.
**Context.** With 26's stages, everything before `judgment` is
deterministic — parallel-safe with plain processes, no model cost — and
`file` writes shard cleanly by person. Speed becomes an execution detail
of the standard, not a redesign.
**Work.** Person-sharded parallel filing waves (no two workers touch the
same person file; index rebuilt once at the end); parallel fetch/normalize
across lanes; a wall-clock target for a fresh onboarding measured against
the 2026-08-29 live-run baseline.
**Deliverables / proof of done.** A sharded filing wave files a mixed
batch with zero cross-worker person-file conflicts; an onboarding-shaped
rerun beats the plan's wall-clock target; suites green.

### 28 — Sync timing & autonomous runtime

**Mission test.** Infrastructure for *noticing* — signals only exist if capture runs without the user. Nearest ingredient: time — the runtime must never ping the user around a meeting (principle 3).
**Context.** The sync-lanes contract (19) already makes "which lane, what
interval" pure config, but only beeper actually runs — gmail/calendar need
a live Claude session for the first-party MCP connectors, which launchd
alone cannot provide. After 26, the in-session requirement shrinks to the
fetch call itself, so a scheduled session becomes thin and cheap.
**Work.** A scheduled agent runtime for MCP lanes — headless `claude -p`
invoking the sweep skill under launchd, or a scheduled cloud agent (decide
in-plan) — with gmail/calendar rows joining `lanes.tsv`; per-lane
intervals chosen deliberately (email may not need beeper's 15 min — each
tick is a model session); catch-up on wake; a per-tick cost guardrail.
**Deliverables / proof of done.** gmail + calendar fire on schedule with
no manual step and land conformant events (check-sync clean); `status`
shows all lanes with last-run/next-run; a tick is proven fetch-only (no
body transcription); reboot-safe like the rest of 19.

### 29 — Connector fleet

**Mission test.** Infrastructure for *noticing* (breadth of sources). Nearest ingredient: none; pure cost — but every new lane is first-party only (other-people's-data-stays-local).
**Context.** With the stage contract, a provider is a fetch implementation
plus a normalizer mapping — the roster of lanes and their concurrency
becomes an independent service, decoupled from what any lane imports.
**Work.** Fleet roster on top of sync-lanes: enable/disable a lane by
config alone; simultaneous-run isolation proven (per-lane checkpoints,
inbox namespaces, no shared-file races); a new-lane playbook documenting
exactly what a new provider must implement (feeds the Later list:
iOS-Shortcut lane, iMessage bridge).
**Deliverables / proof of done.** All active lanes run concurrently in one
window with check-sync clean; disabling/enabling a lane is a config act
with no code edit; the playbook validated by scaffolding one new lane (a
dry-run fixture lane is sufficient).

### 30 — Semantic scoring: user model × relationship kind × evidence

**Mission test.** Cuts *deciding-who* and *timing* — the queue is only as good as its ranking. Nearest ingredient: **intent** — tiers and kinds are derived-and-confirmed, never silently inferred; the user decides who matters.
**Context (from the 2026-08-29 live run; reframed the same day).** All 20
tier suggestions saturated to inner-circle: 20 of the 23 gated people have
`median_gap_days ≤ 21` because episode-split files one interaction per
chat-day. The root cause is structural, not thresholds — frequency cannot
tell a two-week scheduling contact from a monthly real friend; what
separates them is what the relationship *is*, and who the user is.
Accuracy stays a consumer of the import pipeline, independent of
speed/timing/fleet.
**Work.** Replaces the one-formula tier score with a three-layer hybrid.
**Layer 1** — a stated-provenance `user-model.md` (core contract,
ingestion-written) describing the user's investment mix, protected time,
and current season; drafted from revealed behavior, confirmed by the user,
revisable. **Layer 2** — a per-person relationship `kind` (small vocabulary
+ free-text rationale, derived by a post-file judgment pass from
deterministic evidence; user-confirmable, stated corrections stick,
time-boxed kinds expire guilt-free) as a second axis beside the unchanged
four-tier warmth enum. **Layer 3** — **judgment with priors, not a
formula**: the model emits an attention warrant (0–100), suggested tier,
and rationale from evidence + user model + a small interpretable prior set
(user-model axes; `kinds`/`evidence` dimensions on ranking-weights.json,
seeded from the user model; nearest confirmed neighbors); rigid numbers
survive only as rules (data gate, kind caps, zero unconfirmed tier writes).
**Local optional embeddings** (Ollama via curl+jq, never cloud — Anthropic
offers no embedding model and Voyage's cloud fails data-locality doctrine)
supply neighbor priors, clustering, and user-model draft evidence,
degrading gracefully when absent. A deterministic **rescale** re-centers
warrant batches and weight dimensions when they drift ("everyone too high /
too low"), user-invoked. Tier-drift becomes prefilter + judgment; attention
footprint minimal and sequenced after plan 05. A new user-invoked
`review-tiers` flow is the confirmation surface (the 2026-08-29 all-skip
batch is never re-prompted unprompted).
**Deliverables / proof of done.** Contracts versioned in core (user-model,
relationship-scoring, embeddings-index, person.md kind fields,
ranking-weights 1.1.0); evidence extraction, embeddings + nearest/cluster
scripts, user-model derive-and-confirm, classify+judge pass, rescale, drift
prefilter+judgment; deterministic byte-compare tests for the scripts and
judgment evals with set/ordering/property graders (kind sets, warrant
ordering, neighbor-prior consistency, no-Ollama fallback, user-model
propagation, de-saturation, rescale skew). The live corpus ranks without
saturation (scheduling/unsolicited/silent-group land low with neutral
wording, inner-circle no longer the default); every suggestion and drift
proposal carries a breakdown naming kind, evidence, priors, and rationale;
warrants move when the user model moves, and only where it applies;
identical outcomes with embeddings absent; eval-guarded; zero tier writes
without confirmation (unchanged invariant).

### 07 (amendment) — user notification & nudge delivery

**Context.** 05/06 produce wake-up cards but nothing defines how a nudge
physically reaches the user. Doctrine boundary: draft-never-send governs
outreach to *other people*; notifying the *user themselves* is allowed to
be an actual send.
**Work (added unit inside chunk 07).** A delivery-channel decision +
adapter — candidates: brief file in the data dir, session digest, email
draft-to-self via gmail-out, push notification, Beeper note-to-self;
channel and cadence user-configurable; quiet-hours/capacity respected per
plan 12; no-guilt rules hold (no badges, streaks, or backlog framing).
**Deliverables / proof of done.** A wake-up card reaches the user through
the chosen channel end to end (scheduled firing arrives with 28);
channel/cadence changed by config alone; zero outreach to others
auto-sent (unchanged invariant).

## Execution order (current)

**Shipped 2026-08-30** (chunk 20 gate: GO — see `docs/ship-notes-2026-08-30.md`;
zero data loss, audits green; gmail filed→query leg accepted as a known gap,
closes with 17's lanes + first human email).

Post-ship order (restructured 2026-08-29: standard import pipeline first,
then its independent consumers — speed, timing, fleet, judgment):
1. **26** — standard import pipeline (plan file to author). Everything
   below consumes its stage contract.
2. **27** — import speed & scaling, immediately on 26's heels (mechanical
   once the stages are deterministic).
3. **12 (amendment unit) → 05 + 06** — the attention layer on its own
   stream, in parallel with 26/27, honoring plan 15 touchpoints. **Done
   2026-08-30** (12 PR #15, 05 PR #18, 06 chunk-06-wakeup-scheduler) — 07
   is now unblocked on 06.
4. **28 → 29** — sync timing & autonomous runtime, then the connector
   fleet (28 needs 26's thin fetch; 29 needs 28's runtime).
5. **30** — scoring accuracy/judgment/weights (needs 26; independent of
   27–29, can interleave).
6. **07 (with the nudge-delivery amendment)** — once 06 exists; scheduled
   firing arrives with 28.
7. **Post-ship monitoring** continues throughout (periodic
   check-sync/validate-store audits, defects filed per package); **09**
   infrastructure alongside; **04**'s matching half rides with 05's
   co-attendance needs.

## Streams (parallel-session worktrees)

Long-lived worktrees live in `../relationship-agent-worktrees/`, one per stream; each
stream runs its chunks serially (branch per chunk off `main`, merge back, `git merge main`
to resync — never rebase). Streams may run concurrently with each other.

| Worktree | Branch | Territory | Chunks |
|---|---|---|---|
| `ingestion/` | `stream-ingestion` | connectors-in + ingestion (direct first-party lanes: gmail, calendar; beeper lane; user inputs) | 26 → 27 → 30 → 04 (matching) |
| `mcp/` | `stream-mcp` | query + connectors-out (answer surface, briefs, model access) | 07 incl. nudge delivery (06-dependent parts last; after 18 merges — 18 moved to `query-live/`) |
| `query-live/` | `chunk-18-query-live-wiring` | chunk-18 wiring (query territory on loan from `mcp/`) — 18 merged; worktree retires after chunk 22's verification runs | 18, 22 (both done) |
| `infrastructure/` | `stream-infrastructure` | cloud runtime + data-repo discipline + egress hygiene + sync scheduling | 09 → 28 → 29 |
| (new) `attention/` | `stream-attention` | signal engine + wake-up queue + cadence | 12 → 05 → 06 (21 landed ahead) |

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

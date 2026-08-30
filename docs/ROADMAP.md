# Roadmap

Working tracker for the build. Each chunk is one plan in `docs/plans/`, sized so a
single focused session (with subagent fan-out) can complete it. This file is the truth
for *status and grouping*; the plan file is the truth for *evidence and detail* — keep
status cells short and put proof in the plan.

> **Mission (decision `mission-ingredients-vs-running-cost`, 2026-08-29):** *what a
> friendship is made of, without what it costs to keep.* Every chunk carries a
> **Mission test.** — which running cost it cuts (remembering-to / noticing / timing /
> deciding-who / starting / following-through, or "infrastructure for <cost>") and which
> ingredient (trust / care / intent / time) it is nearest to and how it stays clear. A
> chunk that can't answer doesn't get planned. Scenario map: `docs/USE-CASES.md`.

> **History in one line:** built 2026-08-29, shipped 2026-08-30 (chunk 20 gate GO,
> `docs/ship-notes-2026-08-30.md`), Composio dropped for first-party claude.ai
> connectors (decision `composio-retired`), then the post-ship phase: import pipeline →
> speed → semantic scoring → deterministic filing → nudge delivery → feedback ledger.

## Where we are (2026-08-30)

The full loop exists on `main` with green CI: capture (beeper, gmail, calendar) →
triage → deterministic + one-call filing → derived kinds/tiers with a user model →
signals → wake-up queue → 2-line nudge cards delivered to the user's own Beeper
self-chat → numbered replies parsed back into an append-only feedback ledger.

What is *not* done splits into three kinds of work:

1. **Live proofs that need a user session** (no code): plans 28 and 30.
2. **Quality of the store as it actually is** after a real onboarding: plan 36.
3. **Unbuilt surfaces** carried since the original plan set: 04 (calendar matching),
   07 (brief skill), 09 (cloud/egress discipline), 29 (fleet), 34 phase 2.

## Chunks by area

Status vocabulary: **Done** (merged to main) · **Built** (merged; a live proof is still
owed) · **Ready** (plan written, unblocked) · **Proposed** (plan drafted, not started)
· **Planned** (row only) · **Superseded/Retired**.

### A. Foundation — contracts, harness, evals

| # | Plan | Package | Depends on | Status |
|---|---|---|---|---|
| 01 | Contracts & store | core | — | Done 2026-08-29 |
| 14 | Import standard (capture-event 1.1/1.2: typing, occurred_at, `<connector>/<lane>` source, transport rule) | core + connectors | 01, 13 | Done 2026-08-29; field shapes live-verified in 17 |
| 15 | Preference & personalization layer (profile / ranking-weights / wakeup 1.1) | core + ingestion/attention specs | 01, 08 | Done 2026-08-29 |
| 16 | Eval harness — tool/agent/skill tiers | core (eval-case, 4 runners) + per-package cases | 08, 15 | Done 2026-08-29 |
| 23 | Harness context economy (content-bearing briefs, warm workers, capsule manifests) | `.claude/rules`, `.claude/context` | — | Done 2026-08-29 |

### B. Capture lanes & sync runtime

| # | Plan | Package | Depends on | Status |
|---|---|---|---|---|
| 02 | Capture & Gmail inbox | connectors/gmail-in | 01 | Superseded — folded into 17 |
| 10 | Composio access layer | connectors/composio-in | 01 | Retired — torn down in 17; normalizer + import standard survive |
| 11 | Messaging-connectors research | docs | — | Done 2026-08-29 |
| 13 | Beeper capture connector (whatsapp / linkedin / matrix) | connectors/beeper-in | 01 | Done 2026-08-29; live under the scheduler |
| 17 | Composio retirement & direct Google lanes (gmail-in, calendar-in on first-party connectors) | connectors + docs | 01, 14 | Done 2026-08-29. User steps outstanding: Composio dashboard unlink + Google-grant revoke |
| 19 | Scheduled syncs runner (one scheduler, config-driven lanes, restart-safe) | connectors/scripts + core (sync-lanes) | 13 | Done 2026-08-29; TCC granted, beeper lane verified firing |
| 28 | Autonomous sync runtime — headless `claude -p` ticks for the MCP lanes, gmail 3600s / calendar 7200s rows, cost cap, watchdog | connectors + core + SETUP §5a | 19, 26 | **Built** (PR #16). Owed: live U5.2–5 — preflight both lanes, enable rows, first scheduled ticks land `check-sync`-clean, fetch-only proof (= plan 26 U12.3), reboot sim |
| 29 | Connector fleet — enable/disable by config alone, concurrent-run isolation, new-lane playbook validated by a dry-run fixture lane | connectors + core + docs | 26, 28 live | Planned |

### C. Import & filing pipeline

| # | Plan | Package | Depends on | Status |
|---|---|---|---|---|
| 03 | Filing engine (debrief skill) | ingestion | 01 | Done 2026-08-29; 16 goldens, T3 evals |
| 24 | Onboarding deep backfill & priority seeding (6-month window, backfill modes on all lanes, seed skill) | connectors + ingestion + core | 03, 15, 17 | Done 2026-08-29 (PR #11) |
| 25 | Backfill episode-split filing (one interaction per active day) | ingestion | 03, 24 | Done 2026-08-29 (PR #12) |
| 26 | Standard import pipeline (stage contract fetch → normalize → triage → judgment → file; triage tier) | core + connectors + ingestion | 24, 25 | Done 2026-08-29 (PR #14). Residual U12.3 closes with 28's live proof |
| 27 | Import speed & scaling (sharded parallel filing) | ingestion + connectors | 26 | Done 2026-08-29 (PR #19); 0.65× at bench, confirm ~0.2× on a real wave |
| 31 | Deterministic structured filing & cold-start priors (`file-structured.sh`, `tier_source`, provisional user-model auto-adopt, correction digest) | ingestion + core + attention | 26, 27, 30 | Done 2026-08-30 (PRs #23, #24) |
| 32 | One model call per chat thread (`summarize-thread.sh` → `file-thread.sh`, chatID dedup, `unsolicited`) | ingestion + core (person 1.3.0) | 31 | Done 2026-08-30 (PRs #25, #26) |
| 36 | Store currency, dedup, remainder speed, preference loop — see block below | core + ingestion + attention | 31, 32, 34 ph.1 | **Proposed** — next build; unblocked 2026-08-30 |

### D. Relationship judgment — kinds, tiers, user model, feedback

| # | Plan | Package | Depends on | Status |
|---|---|---|---|---|
| 30 | Semantic scoring: user model × relationship kind × judged warrant (priors, local optional embeddings, rescale, `/review-tiers`) | core + ingestion + attention | 15, 25, 26 | **Built** (PR #22; phases 1–6, all suites green). Owed: live U19.2–5 — see block below |
| 34 | Feedback ledger & active iteration — `feedback-event` 1.1, `signals/feedback.jsonl`, numbered-reply parsing incl. `<n> draft`, corrections → prompts + evals | ingestion + core + attention + connectors | 31, 33 | **Phase 1 Done** 2026-08-30 (PRs #31, #32). **Phase 2** (U25–U29: outcome-derived kind weights, prefilter by kind weight, ledger-counted `not-this-person`, user-model revision proposals, weekly report card) gated on ≥2 weeks of live ledger (~2026-09-13) |

### E. Attention — signals, wake-ups, calendar intelligence

| # | Plan | Package | Depends on | Status |
|---|---|---|---|---|
| 12 | Cadence & capacity-aware scheduling (routine map, week-plan, capacity-aware selection) | attention + core | 01 | Done 2026-08-29 (PR #15) |
| 05 | Signal engine (8 detectors, ranking with budget/hold/floor) | attention | 01, 12, capture lanes | Done 2026-08-29 (PR #18) |
| 06 | Wake-up scheduler (`wakeup-queue.sh`, sweep skill = daily-attention entry) | attention | 01, 05 | Done 2026-08-30 (PR #20) |
| 21 | Calendar intelligence & event proposals (wakeup 1.2.0 event-proposal, confirm-first, `upcoming_meetings`) | attention + query + connectors | 04, 05, 06, 17 | Done 2026-08-29; live Calendar create still manual-verify |
| 04 | Calendar matching (ingestion half — `calendar-reconcile`: attendee↔person, unknown-attendee questions, event links, un-debriefed + upcoming-briefworthy artifacts, co-attendance signal) | ingestion (pull half landed in 17) | 01, 17 | **Ready** — unbuilt; a v1 exit criterion (≥80% auto-match) |

### F. User surface — query, briefs, delivery

| # | Plan | Package | Depends on | Status |
|---|---|---|---|---|
| 08 | Chat MCP & query data layer (6 read-only tools) | query + core | 01 | Done 2026-08-29 |
| 18 | Query & chat live wiring (`.mcp.json` registration) | query + docs | 08 | Done 2026-08-29 |
| 22 | Live-data query verification (smoke 6/6 on the filed store, cited chat answers) | query | 18, 20 | Done 2026-08-29 (PR #10) |
| 33 | Nudge delivery — Beeper note-to-self (`beeper-out`, self-only), gmail-self fallback, outbox audit, `nudge-card` 1.1.0 2-line cards, `notify` lane, chat reminder (D5b) | connectors + core + attention + ingestion | 06, 28 | Done 2026-08-30 (PR #30); decision `notify-self-is-a-send` |
| 35 | Zero-setup query path — `/who-next` over `index.json` + `stats.json` + `people/*.md` with bash+jq when the MCP server is down; `answer-style` 1.0.0 | query + core | 08, 31 | Done 2026-08-30 (PR #27) |
| 07 | Output skills — remaining scope after 33 absorbed cards/adapters/delivery: `skills/brief/` (pre-meeting one-pager, store-vs-public provenance sections, open threads, commitments, plan 21 "Upcoming") and `skills/query/` (NL questions with citations) | query | 01, 04 (upcoming artifact), 21 | **Ready** — unbuilt. Decide whether `query` is still needed given 08 + 35, or only `brief` |

### G. Infrastructure, ops, and the ship gate

| # | Plan | Package | Depends on | Status |
|---|---|---|---|---|
| 09 | Infrastructure — `store-sync.sh` write discipline, `docs/EGRESS.md`, PII/secrets scan at hook + pre-push + CI, sweep heartbeat → staleness wake-up, git-guard repo-scoping | core + harness + docs | 01, 06, 19 | **In progress** — data repo live + `runtime-cloud.md` written; `store-sync.sh`, `EGRESS.md`, heartbeat, scan mounts unbuilt (oss-guard covers part of the scan) |
| 20 | Backfill blitz & ship-day shakedown | cross-package (runs, builds none) | 03, 13, 18 | Done 2026-08-29 — SHIP GATE GO |

Plans 05 and 06 are two plans within one package (`attention`) — DECISIONS.md
`attention-merge`. Historical numbering collisions (11/12 → 13–16; 35 → 36) are
recorded in the plan files; old numbers inside merged specs/commits are historical.

## Open work — what each remaining chunk requires

Detail blocks for **done** chunks were retired from this file on 2026-08-30; their
context, agent path, and proof-of-done live in the plan files. Blocks below exist only
for chunks with work owed. Every block opens with a **Mission test.** line the
plan-architect copies into the plan header.

### 28 — Autonomous sync runtime (live proof owed)

**Mission test.** Infrastructure for *noticing* — signals only exist if capture runs
without the user. Nearest ingredient: time — the runtime must never ping the user
around a meeting.
**Owed (user session, private data dir, nothing committed):** resolve the machine's
absolute `claude` path; `mcp-lane-tick.sh preflight` for gmail-in and calendar-in
(evidence: `preflight-ok` tool lists); write both rows into the live `lanes.tsv`
enabled; `sync-scheduler.sh install`; `status` shows every lane with last/next run; the
first scheduled ticks land conformant events (`check-sync.sh` clean); one tick proven
fetch-only (no body transcription — closes plan 26 U12.3); reboot sim as in 19.
**Unblocks:** 29.

### 30 — Semantic scoring (live proofs owed, plan U19.2–5)

**Mission test.** Cuts *deciding-who* and *timing*. Nearest ingredient: intent — tiers
and kinds are derived-and-confirmed, never silently inferred.
**Owed (user session):**
1. Draft → confirm/edit `user-model.md`; `calibrate.sh --seed-from-user-model` writes
   `kinds.*`/`evidence.*` with rationales.
2. Ollama present → `embed-people.sh`, JSONL validates, nearest lists sane for 3
   spot-checked people; Ollama stopped → `embeddings: unavailable`, review-tiers still runs.
3. `/review-tiers --all` (user-invoked): suggested-tier histogram over the gated people
   is not saturated to inner-circle; scheduling contacts ≤ active with expiry; every
   suggestion shows the breakdown; skew report printed; zero unconfirmed tier writes
   (diff `people/` against the transcript's confirm lines).
4. Edit one user-model axis (revision bump), re-judge: breakdowns cite the new
   revision; that axis's kinds move, others within ±5.
5. `validate-store.sh` clean; plan Status → Done.

### 36 — Store currency, dedup, remainder speed, preference loop (next build)

**Mission test.** Cuts *remembering-to* (stale open threads presented as current),
*deciding-who* (duplicate people split the evidence), and *starting* (a 15-minute
onboarding). Nearest ingredient: care — the store must say where things stand *now*.
**Plan:** `docs/plans/2026-08-30-36-store-currency-dedup-remainder-speed-preference-loop.md`.
- **A. Currency** — person.md 1.4.0 (`as-of` on open threads, `## Resolved`, `[stale]`
  facts); latest-interaction-wins rule; thread-summary 1.1.0 `resolved_threads` +
  current-state gist; `refresh-person.sh` rewrites derived bullets only.
- **B. Dedup** — core `person-merge.sh` (identity union, link rewrite, `.merged/`
  tombstone, `merges.log`); ingestion `find-merge-candidates.sh` (deterministic, never
  merges); onboarding step 4(b) confirm-then-merge, ledgered.
- **C. Remainder speed** — `noise-senders.tsv` triage (never a person); one-call email
  filing via `summarize-thread --kind email` → `file-thread`; target 7.8 → <2 min.
- **D. Preference loop** — new ledger types; attention `learn-sweep.sh` turns
  corrections into user-model rules + learned eval cases; 3-line digest; conflicts
  held, never auto-resolved.
**Done when:** live store has no open thread older than the person's latest interaction
without an `(unverified since …)` mark; known duplicates merged; fresh onboarding ≤ 8
min; one confirmed correction of each type yields a rule + a passing learned eval.

### 34 phase 2 — Active iteration (gated ~2026-09-13)

**Mission test.** Cuts *deciding-who* — the queue learns from what the user actually
acted on. Nearest ingredient: intent — the user's words always outrank a weight.
**Work (U25–U29 in the plan):** ranking-weights 1.2.0 outcome-derived kind weights;
`calibrate.sh` kinds outcome term; tier-drift prefilter enumerates kinds by weight;
`not-this-person` counted from the ledger too → suppression proposal; corrections →
user-model revision proposals; weekly assistant report card.
**Gate:** ≥2 weeks of live `signals/feedback.jsonl`.

### 04 — Calendar matching (ingestion half)

**Mission test.** Cuts *remembering-to* and *noticing* (who you actually met). Nearest
ingredient: trust — ambiguous matches become questions, never wrong links.
**Work:** `packages/ingestion/skills/calendar-reconcile/` — attendee email → person
(exact), name similarity + history → candidate list below a threshold that *asks*;
unknown-attendee flow with event context pre-filled; `met-at` / `will-meet-at` /
`same-event-as` links; `un-debriefed.json` + `upcoming-briefworthy.json` for the sweep;
co-attendance signal for 05. Fixture week already exists under `connectors/calendar-in`.
**Proof:** synthetic week — every expected match, unknown attendee raised as a question,
ignore rules honored. Real week — ≥80% of meetings with tracked people auto-matched,
every non-match surfaced, none silently linked (v1 exit criterion).

### 07 — Brief (and possibly query) skills

**Mission test.** Cuts *starting* (walking into a meeting cold). Nearest ingredient:
care — the brief is the user's own facts first, public research labeled second.
**Work:** `packages/query/skills/brief/` — assembly order, web research pass with
name+company disambiguation, provenance-separated sections, one-page cap, staleness
note, plan 21 "Upcoming" section (silent when empty). `skills/query/` only if 08's MCP
tools + 35's `/who-next` leave a gap — decide in-plan.
**Proof:** a real upcoming meeting gets a usable one-page brief with provenance-separated
sections; "who do I know in fintech in NYC?" answered from fixtures with citations.

### 09 — Infrastructure & egress discipline

**Mission test.** Infrastructure for every cost — the loop must run without the user's
laptop. Nearest ingredient: trust — nothing about other people leaves `data/`.
**Remaining work:** `packages/core/scripts/store-sync.sh` (validate + reindex before
commit, loud conflicts, one pull-merge retry, non-git no-op) + tests; `docs/EGRESS.md`
allowlist; one PII/secrets scan script mounted at harness hook, git pre-push, and CI
(extend `oss-guard.sh`); sweep heartbeat stamp + staleness → wake-up; git-guard
repo-scoping so the machinery guard never blocks the data repo.
**Proof:** a cloud session from a phone debriefs and commits with zero manual steps;
killing the schedule surfaces exactly one staleness wake-up; planted fake PII and a
fake API key are both blocked at push.

### 29 — Connector fleet

**Mission test.** Infrastructure for *noticing* (breadth of sources); every lane is
first-party only.
**Work:** roster on top of sync-lanes — enable/disable by config alone; concurrent-run
isolation proven (per-lane checkpoints, inbox namespaces); a new-lane playbook validated
by scaffolding a dry-run fixture lane.
**Proof:** all active lanes run concurrently in one window with `check-sync` clean;
toggling a lane is a config act.

## Execution order (current)

1. **Live proofs — 28 then 30** (one user session, no code). Closes 26's residual too.
2. **36** — the store-quality items from the 2026-08-30 onboarding run, in plan order
   A1 → A2 ‖ B1 ‖ C1 → A3 ‖ B2 ‖ C2 → D → live bench.
3. **04** — the last v1 exit criterion with no code behind it.
4. **34 phase 2** once the ledger has two weeks of data (~2026-09-13).
5. **07 brief → 09 → 29** — behind the above; 29 needs 28's live proof.
6. Post-ship monitoring throughout: periodic `check-sync` / `validate-store` audits,
   defects filed per package.

## Worktrees and merge cadence

Long-lived worktrees live in `../relationship-agent-worktrees/` (one per stream) or
`.claude/worktrees/`; each runs its chunks serially — branch per chunk off `main`, merge
back, `git merge main` to resync, never rebase. As of 2026-08-30 every stream worktree
is on a merged branch; spawn a fresh `chunk-NN-*` branch/worktree per new chunk rather
than reviving `stream-*` branches. The single-writer rule applies across worktrees: a
worktree never edits another package's files.

- A completed chunk merges to main **in the same session its checker passes**.
- At most **one** completed-but-unmerged chunk per stream; anything unmerged for more
  than a day is an escalation.
- Docs-only work merges immediately; it never rides along waiting for code.
- After any merge to main, every active worktree resyncs at its next session start.
- **CI is the merge gate:** `bash scripts/test-all.sh` locally *and* a green `test` +
  `oss-guard-linux` run on the PR before `gh pr merge` (PR #31 merged red on
  2026-08-30 because the fixture was gitignored — see `.gitignore` fixture rules).
- **Status logging (GrowthPal):** at merge, `wins_capture` with chunk number, what
  shipped, proof-of-done; blockers to `struggles_capture`. No store PII in log text.
- A pushed branch in a public repo is already world-readable; data safety lives at the
  push boundary (plan 09's scan), never in merge speed.

## Post-ship monitoring → v1 (exit criteria)

Shipping (2026-08-30) is not v1. All six must hold to tag v1 and open the repo:
phone-to-filed with zero manual steps (09); ≥80% meeting auto-match (04); ≥1 useful
signal nudge/week with zero bare cadence reminders (05/06/33 live); ad-hoc reminders
fire on time (28 live); ≥3:1 give-to-ask ratio; zero data loss.

## Later (explicitly deferred)

- Output adapters beyond Beeper-self / file / gmail-self (Slack, push, etc.)
- iOS-Shortcut → GitHub capture lane; WhatsApp/iMessage local bridges (at-your-own-risk docs)
- Auto-brief the morning of meetings (a standing wake-up — needs 07 brief)
- Harness Stage 2+ (gates, attestation, shipping pipeline) once there's CI worth gating
- Machinery-as-plugin packaging: ship skills/agents/hooks as a Claude Code plugin so any
  user opens their own private data repo and installs the machinery (per
  cloud-native-runtime)

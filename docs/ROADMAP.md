# Roadmap

Working tracker for the build, organised by **workstream** — what the service does for
the user — not by package. Each chunk is one plan in `docs/plans/`, sized for a single
focused session. This file is the truth for *status, grouping, and targets*; the plan
file is the truth for *evidence and detail* — keep status cells short.

> **Mission (decision `mission-ingredients-vs-running-cost`, 2026-08-29):** *what a
> friendship is made of, without what it costs to keep.* Every chunk carries a
> **Mission test.** — which running cost it cuts (remembering-to / noticing / timing /
> deciding-who / starting / following-through, or "infrastructure for <cost>") and which
> ingredient (trust / care / intent / time) it is nearest to and how it stays clear.
> Scenario map: `docs/USE-CASES.md`.

> **History in one line:** built 2026-08-29, shipped 2026-08-30 (chunk 20 gate GO,
> `docs/ship-notes-2026-08-30.md`), Composio dropped for first-party claude.ai
> connectors (`composio-retired`), then post-ship: import pipeline → speed → semantic
> scoring → deterministic filing → nudge delivery → feedback ledger.

Status vocabulary: **Done** (merged) · **Built** (merged; live proof owed) · **Ready**
(plan written, unblocked) · **Proposed** (plan drafted) · **Planned** (row only) ·
**Superseded/Retired**.

## Where we are (2026-08-30)

The full loop exists on `main` with green CI: capture → triage → deterministic +
one-call filing → derived kinds/tiers with a user model → signals → wake-up queue →
2-line nudge cards in the user's Beeper self-chat → numbered replies parsed into an
append-only feedback ledger. The remaining work was consolidated on 2026-08-30 to **five goals**: (1) ingestion —
faster, no duplicates, current; (2) a preference loop where every correction changes
behaviour; (3) retrieval speed; (4) mobile/cloud speed; (5) a foundation slice that
stops a red `main` merging. Plus one no-code live session (28 + 30 proofs). Everything
else moved to **Later**.

## Workstreams

### 1. Ingestion speed & optimization

**Goal.** A fresh onboarding files six months of history in **≤ 8 min** end-to-end
(2026-08-30 measured ~15 min; debrief remainder 7.8 min is the long pole), produces
**no duplicate people**, and a person file says **where things stand now**, not a
chronology. Incremental filing stays deterministic wherever no judgment is needed.

| # | Plan | Depends on | Status |
|---|---|---|---|
| 03 | Filing engine (debrief skill) | 01 | Done 2026-08-29 |
| 24 | Onboarding deep backfill & priority seeding (6-month window, backfill modes, seed skill) | 03, 15, 17 | Done 2026-08-29 (PR #11) |
| 25 | Episode-split filing (one interaction per active day) | 24 | Done 2026-08-29 (PR #12) |
| 26 | Standard import pipeline (fetch → normalize → triage → judgment → file; triage tier) | 24, 25 | Done 2026-08-29 (PR #14); residual U12.3 closes with 28's live proof |
| 27 | Import speed & scaling (sharded parallel filing) | 26 | Done 2026-08-29 (PR #19); 0.65× at bench — confirm ~0.2× on a real wave |
| 31 | Deterministic structured filing (calendar / metadata email, no model) + cold-start priors | 26, 27, 30 | Done 2026-08-30 (PRs #23, #24); 221 events in 18 s live |
| 32 | One model call per chat thread (`summarize-thread` → `file-thread`, chatID dedup) | 31 | Done 2026-08-30 (PRs #25, #26) |
| 36 A–C | Store currency (as-of / resolved threads, `refresh-person.sh`), person dedup (`person-merge.sh`, candidate detection), remainder speed (noise-sender triage, one-call email filing 7.8 → < 2 min, calendar ignore rules from 04 D5) | 31, 32 | **Built** 2026-08-30 (PR #41) — waves 0–2 merged: person.md 1.4.0, feedback-event 1.2.0, thread-summary 1.1.0 + `--kind email`, `refresh-person.sh`, `person-merge.sh` + `find-merge-candidates.sh`, noise-sender + calendar-ignore triage, onboarding-seed 2(d)/2(e)/4(b). Owed: wave 3 live (merge known dups, re-bench ≤ 8 min, currency check) |

**Owed now:** 36 wave 3 live session (find-merge-candidates → confirm → merge; fresh onboarding re-bench, target ≤ 8 min; record the step table in plan 36 under "Bench").

### 2. Capture & sync — runs without you

**Goal.** Every lane (beeper, gmail, calendar) lands conformant events on its own
schedule with **no laptop session**; adding or disabling a lane is a config act.

| # | Plan | Depends on | Status |
|---|---|---|---|
| 02 | Capture & Gmail inbox | 01 | Superseded — folded into 17 |
| 10 | Composio access layer | 01 | Retired — torn down in 17 |
| 11 | Messaging-connectors research | — | Done 2026-08-29 |
| 13 | Beeper capture connector (whatsapp / linkedin / matrix) | 01 | Done 2026-08-29; live under the scheduler |
| 14 | Import standard (capture-event 1.1/1.2) | 01, 13 | Done 2026-08-29 |
| 17 | Composio retirement & direct Google lanes (gmail-in, calendar-in) | 14 | Done 2026-08-29. User steps left: Composio dashboard unlink, Google-grant revoke |
| 19 | Scheduled syncs runner (config-driven lanes, restart-safe) | 13 | Done 2026-08-29; beeper verified firing |
| 28 | Autonomous sync runtime — headless `claude -p` ticks for the MCP lanes, cost cap, watchdog | 19, 26 | **Built** (PR #16). Owed: live U5.2–5 (see block) |
| 40 | Dynamic sync routing — `lanes.tsv` `{{REPO_ROOT}}`/`{{STORE_DIR}}`/`{{CLAUDE_BIN}}`… placeholders resolved per tick (sync-lanes 1.1.0), `init` + `resolve <lane>`, `install` retires legacy agents, beeper `store_dir` optional | 19, 28 | **Built** 2026-08-30 (plan `docs/plans/2026-08-30-40-dynamic-sync-routing.md`); owed: live cutover from main checkout (init + install, beeper config/token, orphan inbox) |
| 41 | Store commit lane (`store-sync.sh tick` → data-repo history is the audit trail), capture-time fingerprint dedup (normalizer exit 3 + `inbox-dedup.sh`), zero-yield lane detection in `staleness.sh` + `staleness` lane | 09, 33, 40 | In progress (2026-08-30, worktree `chunk-41-store-commit-dedup-health`, plan `docs/plans/2026-08-30-41-store-commit-dedup-health.md`) |
| 29 | Connector fleet — `after` column + concurrency proof + new-lane playbook | 28 live | **Later** (Phase 2; roster toggle already exists). Phases 0–1 of `docs/plans/2026-08-30-29-connector-fleet.md` = the live session (scheduler relocation + 28 proof) and stay owed |

**Owed now:** the live session — 29 Phase 0 (move the scheduler install off the `stream-connectors` worktree; only the legacy beeper lane is installed) → 28 live proof. Checklist: `docs/plans/2026-08-30-29-connector-fleet.md` Phases 0–1. No code.

### 3. Phone / cloud infrastructure speed

**Goal.** From a phone: **an answer in seconds** (no `npm ci`, no server boot — the
2026-08-30 trigger was a 1 m 27 s cloud bootstrap for one question) and **debrief →
filed → committed with zero manual steps**; nothing about other people leaves `data/`.

| # | Plan | Depends on | Status |
|---|---|---|---|
| 18 | Query & chat live wiring (`.mcp.json` registration) | 08 | Done 2026-08-29 |
| 22 | Live-data query verification (smoke 6/6, cited chat answers) | 18, 20 | Done 2026-08-29 (PR #10) |
| 35 | Zero-setup query path — `/who-next` via bash+jq over `index.json` / `stats.json` / `people/*.md` when the MCP server is down; data-repo `CLAUDE.md` so a session clones only the store | 08, 31 | Done 2026-08-30 (PR #27) |
| 09 | Infrastructure, **trimmed 2026-08-30** — `store-sync.sh` (on 38's `reindex.sh`), zero-step cloud debrief, cold-start ≤ 15 s cloud / ≤ 5 s warm (row in 38's bench), routine heartbeat → staleness wake-up | 01, 06, 19, 35, 38 D1 | **Proposed** — Goal 4. git-guard/branch-protection units moved to 39; EGRESS.md, cloud-env spec → Later |
| — | Machinery-as-plugin packaging (open any private data repo, install the machinery) | 09 | Later |

**Owed now:** 09 trimmed (Goal 4), after 38 lands `reindex.sh` + the bench.

### 4. Retrieval speed & answers

**Goal.** Retrieving data must be **considerably faster** than today (user direction
2026-08-30) — `/who-next`, `search_people`, `get_person`, and a pre-meeting brief each
return in a bounded, measured time on the real store; answers cite the files they came
from and never invent.

| # | Plan | Depends on | Status |
|---|---|---|---|
| 08 | Chat MCP & query data layer (6 read-only tools) | 01 | Done 2026-08-29 |
| 07 | Brief skill only (`skills/brief/`; `skills/query/` dropped — 08 + 35 cover it; "Upcoming" from `upcoming_meetings`, not 04) | 21, 38 G | **Later** — not one of the five goals |
| 38 | Retrieval speed — measured baseline + per-surface targets, single-pass `build-index`/`validate-store`/`who-next-direct`, `reindex.sh` freshness at every writer, non-blocking MCP staleness, one-call `who_next_pool` (≤ 2 round-trips per question), regression guard; **owns every bench + `test-all` perf wiring** | 35 | **Built** 2026-08-30 — every 127-person target met on the real store (build-index 3.8 s → 0.03 s, validate-store 15.4 s → 0.84 s, who-next-direct 3.7 s → 0.05 s, stale MCP cold start 4.2 s → 0.19 s); guard in `test-all.sh`. Owed: `validate-store` 8.75 s vs 8 s at 1000 people / 10k interactions (accept or third pass — user call); one live `/who-next` run confirming ≤ 2 calls |

**Owed now:** 38 open items (validate-store scale target decision; live `/who-next` run); then 07 brief to 38 G's 2-call budget.

### 5. Relationship judgment & learning

**Goal.** Kinds and tiers the user would agree with — never silently inferred, always
correctable — and every correction changes future behaviour measurably.

| # | Plan | Depends on | Status |
|---|---|---|---|
| 15 | Preference & personalization layer (profile / ranking-weights / wakeup 1.1) | 01, 08 | Done 2026-08-29 |
| 30 | Semantic scoring: user model × relationship kind × judged warrant (priors, local optional embeddings, rescale, `/review-tiers`) | 15, 25, 26 | **Built** (PR #22). Owed: live U19.2–5 (see block) |
| 34 ph.1 | Feedback ledger — `signals/feedback.jsonl`, numbered-reply parsing incl. `<n> draft`, corrections → prompts + evals | 31, 33 | Done 2026-08-30 (PRs #31, #32) |
| 34 ph.2 | Active iteration — outcome-derived kind weights, prefilter by kind weight, ledger-counted `not-this-person`, user-model revision proposals (U25–U33; report card U34/35 **cut**) | ≥ 2 weeks of live ledger | Gated (ledger day 0 + 14; day 0 = 30 live proof) |
| 36 D | Preference loop, narrowed — `learn-sweep.sh`: ledger cursor → learned eval cases + conflict digest; never writes `user-model.md` (34 U31/32) | 34 ph.1, 36 B | **Proposed** — Goal 2 step 2 |

**Owed now:** Goal 2 in order — 30 live proof (starts the ledger clock; `signals/feedback.jsonl` is empty as of 2026-08-30) → 36 D → 34 ph.2. Plan 37 (sequence memo) deleted; the Goal 2 block below is the sequence.

### 6. Attention & delivery

**Goal.** ≥ 1 useful signal nudge per week with zero bare cadence reminders; every
card reaches the user; ≥ 80 % of meetings with tracked people auto-matched.

| # | Plan | Depends on | Status |
|---|---|---|---|
| 12 | Cadence & capacity-aware scheduling | 01 | Done 2026-08-29 (PR #15) |
| 05 | Signal engine (8 detectors, budget/hold/floor ranking) | 12 | Done 2026-08-29 (PR #18) |
| 06 | Wake-up scheduler (`wakeup-queue.sh`, sweep = daily-attention entry) | 05 | Done 2026-08-30 (PR #20) |
| 21 | Calendar intelligence & event proposals (confirm-first, `upcoming_meetings`) | 05, 06, 17 | Done 2026-08-29; live Calendar create still manual-verify |
| 33 | Nudge delivery — Beeper note-to-self, gmail-self fallback, 2-line cards, `notify` lane, chat reminder | 06, 28 | Done 2026-08-30 (PR #30) |
| 04 | Calendar reconcile (match-rate report, held-attendee questions, `signals/calendar/` artifacts, D1 un-debriefed fix) — matching core shipped in 31; **D5 ignore rules moved to 36 C3**; D7 briefworthy artifact dropped (`upcoming_meetings` exists) | 31, 06 | **Later** — `docs/plans/2026-08-30-04-calendar-reconcile.md`; still the ≥ 80 % v1 exit instrument |

**Owed now:** nothing before the five goals; 04 is the next v1-exit item after them.

### 7. Foundation & harness

**Goal.** The machinery that carries the running cost must not become one: a red
`main` cannot be merged, every suite passes on macOS *and* Linux, no writer emits a
`schema_version` behind its contract, every row has a plan file.

| # | Plan | Depends on | Status |
|---|---|---|---|
| 01 | Contracts & store | — | Done 2026-08-29 |
| 16 | Eval harness — tool/agent/skill tiers | 08, 15 | Done 2026-08-29 |
| 20 | Backfill blitz & ship-day shakedown — SHIP GATE | 03, 13, 18 | Done 2026-08-29 — GO |
| 23 | Harness context economy | — | Done 2026-08-29 (branch `worktree-harness-context-economy`); **plan file missing** — written retroactively by 39 D1 |
| 39 | Foundation slice — branch protection + re-enabled main guard **incl. 09's repo-scoping and `--only secrets` pre-push check**, CI matrix macOS+Ubuntu with npm cache, gitignore-fixture test, contract-currency check + writer fixes | — | **Wave A Done** 2026-08-30 (PR #35): branch protection live on `main` (`test (macos-latest)`, `test (ubuntu-latest)`, `oss-guard-linux` required), git-guard main checks re-enabled + repo-scoped + `--only secrets` pre-push, CI matrix, gitignore-fixture test. Owed: B2–B5 (contract-currency check + writer fixes); B1/B6/C/D → Later — `docs/plans/2026-08-30-39-foundation-harness-hardening.md` |

| 43 | Forced write path & session ship flow — complete the blessed writer CLI (`person-add`, `interaction-add` to join `wakeup-add.sh` / `person-set-*`), make it the only sanctioned store write path for every surface (chat, cron tick, cloud/mobile) via data-repo pre-commit / store-sync contract validation; standardized end-of-session `land` script (validate → merge to main → push, or PR for machinery); staleness lane flags unmerged `claude/*` data-repo branches. Inspiration: yourBoiGershy/agent-harness (confinement hooks, subagent-stop-validate, gates). Mission test: infrastructure for *remembering-to* — a filed follow-up that strands on a branch is a running cost the machinery itself created. | 01, 39 | **Built** 2026-08-31 (wave A, branch `chunk-43-forced-write-path`, plan `docs/plans/2026-08-31-43-forced-write-path.md`). Owed: `interaction-add.sh`, machinery-side writer enforcement, agent-harness-plugin consumption decision |

**Owed now:** 39 waves B2–B5 (contract-currency check); wave A is live and gating every PR.

### 8. Platform & user skills — use it how *you* want

**Goal.** Spomni is a data layer plus a blessed primitive surface; the shipped
skills are forkable worked examples. A developer (the ICP) decides what they
want from their data and authors their own skill — with `/make-skill` doing the
guiding — without touching this repo (decision `platform-over-product`).

| # | Plan | Depends on | Status |
|---|---|---|---|
| 42 | Skills platform — `user-skill.md` 1.0.0 contract + template, `link-user-skills.sh` (data-repo `skills/` → `~/.claude/skills` symlinks), `/make-skill` guided authoring, `docs/SKILL-AUTHORING.md` (blessed API + guarantees-vs-norms line), README/SETUP reframe | 08, 35, 38 | **Built** 2026-08-30 (worktree `chunk-42-skills-platform`, plan `docs/plans/2026-08-30-42-skills-platform.md`). Owed: first real user-authored skill dogfooded end-to-end |

Plans 05 and 06 are two plans within one package (DECISIONS.md `attention-merge`).
Numbering collisions (11/12 → 13–16; 35 → 36) are recorded in the plan files.

## Open work — consolidated 2026-08-30 (five goals, five chunks, one live session)

Consolidation pass 2026-08-30: the eleven open blocks were re-cut against the five
goals the user actually stated. Everything below is the whole remaining build; anything
not listed here is in **Later**. Overlaps that were removed (same unit claimed by two
plans): `feedback-event` bump (36 vs 37), preference-loop rules (36 D vs 34 ph.2),
`git-guard.sh` + branch protection (39 vs 09), bench harnesses (38 vs 09), `test-all`
perf wiring (39 vs 38), index regen on write (38 vs 09), lane liveness (09 vs 29), the
brief's "upcoming" list (04 D7 vs `upcoming_meetings`), and the 28 live-proof checklist
(ROADMAP vs 29 vs 28 §U5). Each plan file carries a **Consolidation 2026-08-30** header
saying what stays and what moved.

### Goal 1 — Ingestion: faster, no duplicates, store says where things stand → chunk 36 A–C

**Mission test.** Cuts *remembering-to* (stale open threads shown as current),
*deciding-who* (duplicate people split the evidence), *starting* (a 15-minute
onboarding). Nearest ingredient: care — the store must say where things stand *now*.
**Plan:** `docs/plans/2026-08-30-36-store-currency-dedup-remainder-speed-preference-loop.md`
(Waves 0–3 as written; D moved to Goal 2). **Absorbs** plan 04 D5 (calendar ignore
rules: declined-self, attendee cap) as unit C3 — the only part of 04 that is an
ingestion-accuracy fix.
- **A. Currency** — person.md 1.4.0 (`as-of`, `## Resolved`, `[stale]`); latest-
  interaction-wins; thread-summary 1.1.0 `resolved_threads`; `refresh-person.sh`
  (**only** for slugs with ≥ 2 threads — it is a model call and counts against the
  8-minute budget).
- **B. Dedup** — `person-merge.sh` + `find-merge-candidates.sh`; onboarding step 4(b)
  confirm-then-merge, ledgered (`feedback-event` **1.2.0**: `merge`, `noise-sender`,
  `stale-marked` — the single home for this bump).
- **C. Remainder speed** — `noise-senders.tsv` triage; one-call email filing; C3 =
  calendar ignore rules (from 04 D5). 7.8 → < 2 min.
**Done when:** fresh onboarding ≤ 8 min; known dups merged; no open thread older
than the latest interaction without an `unverified since` mark; `validate-store` clean.

### Goal 2 — Preference loop: every correction changes behaviour → 30 live · 36 D · 34 ph.2

**Mission test.** Cuts *deciding-who* and *re-explaining* (a correction is paid once).
Nearest ingredient: intent — the user's stated kind/tier always outranks a derived one.
**Sequence (plan 37 deleted — this block is the sequence):**
1. **30 live proof** (user session, ~45 min, no code; plan 30 U19.2–5): confirm
   `user-model.md` → `calibrate.sh --seed-from-user-model`; Ollama on/off branches;
   `/review-tiers --all`; **correct ≥ 5 lines** so `signals/feedback.jsonl` gets its
   first day (ledger day 0); axis edit re-judge; `validate-store` clean → row 30 Done.
2. **36 D narrowed** (buildable now, 3 units): `learn-sweep.sh` (attention) — cursor
   over the ledger → `feedback-to-evals.sh` append + conflict detection → 3-line
   digest; registered as a sync-tick target; **never writes `user-model.md`** (that is
   34 U31/U32). Contract types ride with 36 B's 1.2.0 bump.
3. **34 ph.2** at ledger day 0 + 14 (plan 34 U25–U33): outcome-derived kind weights,
   prefilter by kind weight, ledger-counted `not-this-person`, user-model revision
   proposals. **Cut:** U34/U35 weekly report card (descriptive only; nearest thing on
   the roadmap to a vanity metric) and U36/U37 shrink to a docs line + checker.
**Done when:** one confirmed correction of each ledger type yields a passing learned
eval; 3 same-axis corrections yield exactly one standing proposal.

### Goal 3 — Retrieval speed → chunk 38

**Mission test.** Cuts *starting* and *deciding-who*; pure cost.
**Plan:** `docs/plans/2026-08-30-38-retrieval-speed.md`, waves 1–3 as written.
**Owns all benches**: `bench-retrieval.sh` is the one harness; 09's cold-start bench
is a row in it, not a second script. **Owns `test-all.sh` perf wiring** (39 B1's
`--perf` flag is dropped in favour of 38 H). `reindex.sh` (38 D1) is what 09's
`store-sync commit` calls.
**Done when:** every §2 target green on fixture + scale stores in CI; `/who-next`
≤ 2 tool calls; before/after table on the real store.
**Status 2026-08-30:** built and merged — table in plan §5; fixture guard green in CI;
scale envelope in `run-perf.sh` (manual) with one miss (`validate-store` 8.75 s vs
8 s at 10k interactions); live `/who-next` call-count run still owed.

### Goal 4 — Mobile / cloud speed → chunk 09 (trimmed)

**Mission test.** Cuts the restart cost of opening the assistant from a phone (1 m 27 s
→ ≤ 15 s) and the remembering-to cost of committing a debrief.
**Plan:** `docs/plans/2026-08-29-09-infrastructure.md`. **Keeps:** deliverable 1
`store-sync.sh` (calls 38's `reindex.sh`), 2 zero-step cloud debrief, 3 cold-start
target (measured via 38's harness), 5 heartbeat+staleness **for routines only** —
lane liveness reads the scheduler's existing `run-start`/`run-end` state files instead
of a second stamp. **Moves out:** 6b/7 `git-guard.sh` edits and 6c required-check →
Goal 5 foundation slice (one owner of that file and that setting). **Later:** 4 cloud
environment spec, 8 `docs/EGRESS.md` (oss-guard's never-send/no-enrichment checks are
the mechanical half already), plugin packaging.
**Done when:** phone session → `/who-next` in ≤ 15 s cold; `/debrief` → filed →
committed with zero typed git commands; a killed routine yields exactly one
staleness wake-up.

### Goal 5 — Foundation slice (gates every PR above) → chunk 39 wave A only

**Mission test.** Infrastructure for every cost; a red `main` that merges (PR #31) is
the builder's remembering-to.
**Plan:** `docs/plans/2026-08-30-39-foundation-harness-hardening.md`. **Keeps:** A1
branch protection (`test` + `oss-guard-linux` required — this is also 09's 6c), A2
re-enable git-guard main checks **and** 09's repo-scoping + `--only secrets` pre-push
check in the same unit (one file, one worker), A3 CI matrix macOS+Ubuntu + npm
cache, A4 gitignore-fixture test, B2 `check-contract-currency.sh` + B3–B5 writer
version fixes (cheap, deterministic). **Later:** B1 (38 owns perf wiring; the two
unwired bash suites ride with A3), B6 fixture re-baseline, C1–C4 evals, D1 plan-23
record.
**Done when:** a deliberately red PR cannot merge; test-all green on both OSes;
currency check clean.

### Live-proof session (no code; do first, one sitting)

1. **Plan 29 Phase 0** — relocate the live scheduler from the `stream-connectors`
   worktree to `main` (`lanes.tsv` seed, install, retire the legacy label). The 28
   proof cannot run without it.
2. **28 live proof** (plan 29 Phase 1 = plan 28 §U5.2–5): preflight gmail/calendar
   lanes, enable, first ticks, `check-sync` clean, one fetch-only tick (closes 26
   U12.3), reboot sim → row 28 Done, row 26 residual closed.
3. **30 live proof** (Goal 2 step 1) — same sitting if time allows; it starts the
   ledger clock.
The 28 checklist lives in **plan 29 Phases 0–1 only**; this block is the pointer.

## Execution order (current)

1. **Live session** (29 Ph.0 → 28 proof → 30 proof). In parallel, **39 wave A** —
   no product code paths, gates every later PR.
2. **36 A–C** (+ C3 ignore rules) → live bench: onboarding ≤ 8 min.
3. **38** waves 1–3 → live before/after.
4. **36 D** (3 units, can ride in 36's PR or after 38).
5. **09 trimmed** — store-sync on 38's `reindex.sh`, cold-start on 38's harness.
6. **34 ph.2** when the ledger gate opens (day 0 + 14).
7. Post-ship monitoring throughout: periodic `check-sync` / `validate-store` audits.

## Worktrees and merge cadence

Worktrees live in `../relationship-agent-worktrees/` or `.claude/worktrees/`; branch
per chunk off `main`, merge back, `git merge main` to resync, never rebase. As of
2026-08-30 every stream worktree is on a merged branch — spawn a fresh `chunk-NN-*`
branch per new chunk rather than reviving `stream-*`. Single-writer rule applies across
worktrees.

- A completed chunk merges to main in the same session its checker passes; at most one
  completed-but-unmerged chunk per stream; docs-only work merges immediately.
- **CI is the merge gate:** `bash scripts/test-all.sh` locally *and* green `test` +
  `oss-guard-linux` on the PR before `gh pr merge` (PR #31 merged red on 2026-08-30
  because a fixture was gitignored — see `.gitignore` fixture rules).
- **Status logging (GrowthPal):** at merge, `wins_capture` with chunk number, what
  shipped, proof-of-done; blockers to `struggles_capture`. No store PII in log text.
- A pushed branch in a public repo is already world-readable; data safety lives at the
  push boundary (plan 09's scan), never in merge speed.

## Post-ship monitoring → v1 (exit criteria)

Shipping (2026-08-30) is not v1. All six must hold to tag v1 and open the repo:
phone-to-filed with zero manual steps (09); ≥ 80 % meeting auto-match (04); ≥ 1 useful
signal nudge/week with zero bare cadence reminders (05/06/33 live); ad-hoc reminders
fire on time (28 live); ≥ 3:1 give-to-ask ratio; zero data loss.

## Later (explicitly deferred)

- Output adapters beyond Beeper-self / file / gmail-self (Slack, push, etc.)
- iOS-Shortcut → GitHub capture lane; WhatsApp/iMessage local bridges
- Auto-brief the morning of meetings (a standing wake-up — needs 07 brief)
- Harness Stage 2+ (gates, attestation, shipping pipeline)
- Machinery-as-plugin packaging (workstream 3, after 09)
- Cut in the 2026-08-30 consolidation: 04 reconcile report + question skill; 07 brief;
  09 `docs/EGRESS.md` + cloud-environment spec; 29 Phase 2 fleet (`after` column,
  concurrency proof, `NEW-LANE.md`); 34 ph.2 weekly report card (U34/35); 39 B1/B6,
  C1–C4 (eval gates, cost cap, manual eval workflow), D1 plan-23 record

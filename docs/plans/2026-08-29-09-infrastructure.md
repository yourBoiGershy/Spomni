# Plan 09: Infrastructure — phone/cloud speed, store-sync, egress hygiene, heartbeat

> **Consolidation 2026-08-30 (ROADMAP Goal 4 — trimmed).** Keep deliverables 1
> (`store-sync.sh commit` calls plan 38's `reindex.sh`, not `build-index.sh`
> directly), 2, 3 (cold-start is a **row in 38's `bench-retrieval.sh`**, not a second
> script), 5 for **routines only** (lane liveness reads the scheduler's existing
> `run-start`/`run-end` state files; `sync-scheduler.sh` gets no heartbeat stamp).
> Moved to plan 39: 6b, 6c, 7 (git-guard + branch protection). Later: 4, 8, 6a
> pre-push installer (39 A2's hook check covers the push boundary). Work units:
> wave A = 1, 2, 3(row); wave B = 6, 8; wave C = 10, 11, 12; wave D unchanged.
Status: In progress — REVISED 2026-08-30 (v2; v1 was Composio-era and is superseded here)
Package: core (`store-sync.sh`, `heartbeat-stamp.sh`, contracts) + attention (staleness step in sweep) + query (cold-start bench) + harness (`.claude/hooks/`, `scripts/setup.sh`) + docs
Depends-on: 01, 06, 19 (all done); 35 (done — zero-setup query path is the baseline this plan measures)
Branch: `chunk-09-phone-cloud-infra`

## Mission test (§1)
Everything here cuts a **running cost** — the restart cost of opening the assistant
from a phone (1 m 27 s bootstrap for one question, 2026-08-30), the remembering-to
cost of committing a debrief, and the noticing cost of a schedule that silently died.
Nothing drafts, sends, scores, or performs a relationship. The egress allowlist is
pure hygiene for other people's data.

## Goal (from ROADMAP area 3)
From a phone: **an answer in seconds** — no `npm ci`, no server boot — and
**debrief → filed → committed with zero manual steps**; nothing about other people
leaves `data/` except through the enumerated lanes in `docs/EGRESS.md`.

## What already exists (do not rebuild)
- Data repo `relationship-agent-data` live on GitHub, 127 people / 356 interactions;
  `data/store` symlinks to the local clone. Its `CLAUDE.md` already tells a cold
  session to shallow-clone the machinery and run `who-next-direct.sh` (bash+jq, no
  node) — plan 35.
- `.claude/scripts/oss-guard.sh` — PII / secrets / never-send / enrichment /
  gitignore checks over the **machinery** repo's tracked tree, run in CI on macOS and
  Linux. This IS the scan script v1 wanted; what's missing is the pre-push and
  harness-hook mounts and the CI check being *required*.
- `docs/runtime-cloud.md` — cadence map + queue model; explicitly leaves environment
  spec, store-sync mechanics and deadman escalation to this plan.
- `packages/core/scripts/wakeup-add.sh` (the only creation path for wake-ups),
  `build-index.sh`, `validate-store.sh`.
- Decisions that bind: `cloud-native-runtime`, `git-as-sync-protocol`,
  `pii-egress-allowlist`, `code-data-separation`, `composio-retired` (first-party
  claude.ai connectors are the only pipes to the user's own accounts).

## Topology (current, Composio-free)
```
phone/laptop ──(claude.ai/code cloud session on the DATA repo)──▶ answer (bash+jq) / debrief → store-sync commit → data-repo main
Mac (launchd) ──(sync-scheduler lanes: beeper local; gmail/calendar via mcp-lane-tick)──▶ inbox/ → filing → store-sync commit → push
attention sweep ──(reads heartbeats/)──▶ staleness wake-up when a lane/routine goes quiet
```
Beeper is **Mac-only** (desktop app); it never runs in the cloud. Cloud sessions
reach Gmail/Calendar only through the first-party connectors the user linked.

## Deliverables
1. **`packages/core/scripts/store-sync.sh`** — the write discipline every runtime uses
   against the data repo: `pull` (fetch + merge, loud on conflict, never rebase),
   `commit [-m msg]` (validate-store → build-index → `git add -A` → commit; refuses
   on validation failure), `push` (one pull-merge retry on non-fast-forward, then
   fail loudly), `status`. No-op with a clear line when the store dir isn't a git
   repo. Resolves the store through `data/store` symlink or an explicit path. Sets
   a fallback git identity from env (`SPOMNI_GIT_NAME/EMAIL`) when the runtime has
   none — that's the cloud case.
2. **Zero-manual-step debrief from a cloud session** — the data repo's `CLAUDE.md`
   gains a "Debriefing from a cold session" section (mirror of the query section:
   clone machinery shallow, run `/debrief` per the SKILL, then
   `store-sync.sh commit && store-sync.sh push`). The debrief SKILL's closing step
   references store-sync when the store is a git repo. Companion: a
   `data/store/CLAUDE.md` exemplar committed in the machinery repo at
   `packages/core/templates/data-repo-CLAUDE.md` so `init-store.sh` writes it for
   new users (no user-specific content).
3. **Cold-start bench** — `packages/query/scripts/cold-start-bench.sh`: from an empty
   temp dir, time (a) shallow machinery clone, (b) `who-next-direct.sh` first answer
   on a fixture store, (c) the two together; prints one line per stage + total.
   Records the 2026-08-30 baseline in `docs/runtime-cloud.md` and sets the target:
   **≤ 15 s clone→answer in the cloud, ≤ 5 s on a warm checkout**. If the clone
   dominates, the cloud environment's setup script pre-clones `machinery/`
   (gitignored in the data repo) so a session finds it warm.
4. **Cloud environment spec** folded into `docs/runtime-cloud.md` (replacing v1's
   Composio text): environment = data repo; setup script = pin `jq`, shallow-clone
   machinery into `machinery/`, export `SPOMNI_STORE=.`; git identity via env; no
   secrets at all (connectors are session-scoped, nothing to store); which routines
   can run in the cloud (`daily-attention`, `weekly-planning`, gmail/calendar sweeps
   *if* routines carry connectors — verify and record) and which cannot (beeper).
   Home-hub/Tailscale appendix reduced to a pointer at the superseded decision.
5. **Heartbeat + staleness** — `packages/core/contracts/heartbeat.md` 1.0.0:
   `<store>/heartbeats/<routine>.json` `{routine, stamped_at, cadence_hours, ok}`;
   `packages/core/scripts/heartbeat-stamp.sh <store> <routine> --cadence-hours N
   [--ok|--fail]`. Stamped by `sync-scheduler.sh run <lane>` on lane completion and by
   the sweep / weekly-planning skills on success (they already promise this in
   `runtime-cloud.md`). Attention's sweep gains a **staleness step**: any heartbeat
   older than 2 × `cadence_hours` yields exactly ONE pending wake-up
   (`origin: standing`, `--source-signal staleness:<routine>`; skipped while one is
   already pending/fired-unresolved) — a dead schedule announces itself, once.
6. **Scan mounts** (oss-guard is the scan): (a) `scripts/setup.sh --hooks` installs a
   native `.git/hooks/pre-push` that runs `oss-guard.sh` and blocks on FAIL (push is
   the world-readable boundary); (b) `.claude/hooks/git-guard.sh` runs
   `oss-guard.sh --only secrets` before allowing any `git push` command (fast subset;
   full guard is the pre-push hook + CI); (c) CI: the `oss-guard-linux` job is made a
   **required status check** on `main` — a user action in GitHub settings, recorded
   as a checklist line in `docs/SETUP.md`.
7. **git-guard repo-scoping** — the machinery repo's never-on-main / no-push-main
   rules apply only when the command runs inside a repo whose `origin` URL matches
   the machinery repo (`relationship-agent` without the `-data` suffix, overridable
   via `HARNESS_MACHINERY_REMOTE`); the data repo's designed direct-to-main flow is
   not blocked. Destructive-git tiers stay global.
8. **`docs/EGRESS.md`** — the allowlist per `pii-egress-allowlist`, one row per lane:
   Anthropic (model inference + cloud sandbox: whatever a session reads), GitHub
   (the private data repo — encrypted at rest by GitHub, hardening note), Google
   via first-party Gmail/Calendar connectors (read + draft; nothing about third
   parties is *written* out except a draft the user sends), Beeper desktop (local
   bridge; its own cloud per the user's Beeper account), Ollama (local, no egress),
   rendered deliveries to the user's own surfaces (plan 33 beeper-self). Explicit
   non-lanes: web search with told-by-user facts, enrichment APIs, any auto-send.
   Adding a lane requires a DECISIONS entry — stated in the file.

## Work units (splitting rule applied; every brief ≤ 3 min)
Wave A — parallel, 5 workers + nothing shared:
1. [dev-worker, core] `store-sync.sh` (deliverable 1).
2. [dev-worker, core] `heartbeat.md` contract + `heartbeat-stamp.sh` (deliverable 5, stamp side only).
3. [dev-worker, query] `cold-start-bench.sh` + baseline run on the fixture store (deliverable 3).
4. [dev-worker, harness] git-guard repo-scoping + `--only secrets` pre-push check in the hook (deliverables 6b, 7).
5. [orchestrator, docs] `docs/EGRESS.md` + DECISIONS pointer (deliverable 8) — docs are orchestrator-editable.

Wave B — after A, parallel, 4 workers:
6. [dev-worker, core] store-sync tests (`run-store-sync-tests.sh`, wired into `scripts/test-all.sh`): commit rejects an invalid store; index regenerated; push race against a bare remote retries once then fails loudly; non-git dir no-ops; identity fallback from env.
7. [dev-worker, connectors] `sync-scheduler.sh run` stamps the lane heartbeat (ok/fail) — plus a case in `run-scheduler-tests.sh`.
8. [dev-worker, attention] sweep staleness step + `run-attention-tests.sh` cases: stale → exactly one wake-up; fresh → none; second run → no duplicate.
9. [dev-worker, harness] `scripts/setup.sh --hooks` pre-push installer + heartbeat/store-sync tests for the hook path in `run-oss-guard-tests.sh`.

Wave C — after B, 2 workers + orchestrator docs:
10. [dev-worker, core] `templates/data-repo-CLAUDE.md` + `init-store.sh` writes it; debrief SKILL closing step references store-sync (deliverable 2).
11. [dev-worker, attention] sweep + weekly-planning SKILLs call `heartbeat-stamp.sh` on success (they already document the promise).
12. [orchestrator, docs] `runtime-cloud.md` environment section + bench baseline/target; `SETUP.md` gains the "required check" and `--hooks` lines; ROADMAP row 09.

Wave D — live proof (one user session, not a worker):
13. Open a cloud session on the data repo from the phone; run the bench for real; ask one `/who-next`; do one `/debrief` of an inbox event; confirm the commit lands on data-repo `main` untouched by hand. Kill a launchd lane for 2× its cadence; confirm one staleness wake-up appears, and only one.

## Interfaces
Consumes: core store contracts + `validate-store.sh`/`build-index.sh`/`wakeup-add.sh`; sync-scheduler lane runner (19); attention sweep (06); oss-guard (open-source readiness).
Produces: `store-sync.sh` (every writing runtime), heartbeat contract 1.0.0 (connectors + attention write, attention reads), `docs/EGRESS.md` (binds every stream), repo-scoped git-guard.
Single-writer check: `heartbeats/` is a new artifact type with **two** writing packages (connectors for lanes, attention for routines) — resolved by making the *file per routine* the unit: each routine's file has exactly one writer. Recorded in `heartbeat.md`.

## Proof of done
- Bench: cloud cold session clone→first answer ≤ 15 s (baseline recorded next to it); warm ≤ 5 s.
- Phone debrief: filed + committed + pushed with zero typed git commands.
- Store-sync suite green incl. the simulated push race; validate-gate blocks a bad store.
- Killed lane → exactly one staleness wake-up; restored lane → none further.
- `git push` of a branch with a planted API key is blocked at the harness hook, the pre-push hook, and CI (three mounts, one scan).
- Pushing to `main` in the data repo is not blocked by the machinery's git-guard.
- `docs/EGRESS.md` lists every lane; oss-guard's never-send/no-enrichment checks are cited as the mechanical half.

## Out of scope
- Machinery-as-plugin packaging (ROADMAP Later; depends on this plan).
- Cloud-side beeper (impossible — desktop bridge).
- Retrieval speed beyond cold start (ROADMAP area 4).
- Push notifications to the phone (plan 33's lane already covers nudge delivery).
- Encryption at rest beyond GitHub's (hardening note in EGRESS.md only).

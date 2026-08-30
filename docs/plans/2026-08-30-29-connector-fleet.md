# Plan 29 — Capture & sync close-out: relocate the live scheduler, prove 28, build the connector fleet

> **Consolidation 2026-08-30.** **Phases 0–1 stay owed** and are the single home of
> the plan-28 live-proof checklist (ROADMAP block and plan 28 §U5 point here).
> **Phase 2 → Later**: the roster toggle already exists (D2); the `after` column,
> concurrency proof and `NEW-LANE.md` are built only when a new lane is actually
> planned. Lane liveness for plan 09's staleness step reads this scheduler's state
> files — no heartbeat stamp is added here.

**Status:** Planned 2026-08-30. Covers ROADMAP area 2's remaining work end to end:
Phase 0 (live-install repair, user session), Phase 1 (plan-28 U5.2–5 live proof,
user session), Phase 2 (chunk 29 build, orchestrated workers). Phases 0–1 are
**no-code ops**; Phase 2 is code.

**Mission test.** Infrastructure for *noticing*, breadth and reliability. Cuts the
running cost of "did my syncs run?"; touches no ingredient. Every lane stays
first-party and draft-never-send — a lane is a pipe into `inbox/`, never a sender.

## Live state found 2026-08-30 (why Phase 0 exists)

| Fact | Evidence |
|---|---|
| The **only** installed launchd agent is the pre-rename label `com.relationship-agent.sync.beeper`, running **plan-19-era code** from the `stream-connectors` worktree (`relationship-agent-worktrees/connectors`, HEAD `cf19bdc`, branch never advanced past PR #3). | `launchctl list`, plist `ProgramArguments`, `git log -1` in the worktree |
| That worktree's `lanes.tsv` has one row (beeper); its beeper-in config writes into `relationship-agent-worktrees/ingestion/data/store` (itself a symlink chain to the private data repo). Ticks are healthy (`run-end exit=0`, 15-min cadence, last 16:38Z). | `$W/data/connectors/sync-scheduler/{lanes.tsv,logs,state}` |
| The **main checkout has no `lanes.tsv`** (`sync-scheduler.sh status` → "no such config file"). So the `notify` (plan 33), `feedback` (plan 34), `gmail-in` and `calendar-in` (plan 28) lanes are **not installed anywhere**. | `data/connectors/sync-scheduler/` absent in main's data dir |
| `sync-scheduler.sh` already detects the old label as `LEGACY` (report-only, never auto-removes) and prunes `com.spomni.sync.*` orphans on `install`. | `sync-scheduler.sh:54,168,320` |
| `claude` absolute path: `/Users/ericg/.local/bin/claude` (symlink → `~/.local/share/claude/versions/2.1.251`). launchd has no PATH, so lanes need the absolute path. | `which claude` |

Consequence: "28 live proof" cannot be run as written until the scheduler is
installed from the main checkout. Phase 0 is the missing prerequisite the ROADMAP
does not list.

## Phase 0 — Relocate the live scheduler to the main checkout (user session, ~20 min, no code)

Goal: one scheduler install, from `main`'s code, all shipped lanes present, legacy
agent gone. Order matters — the old agent keeps ticking until step 4, so there is no
capture gap.

1. **Seed the live config.** Copy `packages/core/templates/sync-lanes.tsv` →
   `data/connectors/sync-scheduler/lanes.tsv`; replace `<ABS-REPO-ROOT>` with
   `/Users/ericg/Documents/relationship-agent`, `<ABS-STORE-DIR>` with the resolved
   store path (`readlink data/store`), `<ABS-PRIVATE-DATA-ROOT>` per template
   comments, `<ABS-CLAUDE-BIN>` with `/Users/ericg/.local/bin/claude`. Leave
   `gmail-in`/`calendar-in` **false** for now (Phase 1 flips them).
2. **Point beeper-in at the main checkout's data dir.** Confirm main's
   `data/connectors/beeper-in/config` writes into the same private store the
   worktree lane does (same `store_dir` target after symlink resolution) so cursors
   continue rather than re-sweep. If the cursor file lives only in the worktree's
   data dir, copy it over.
3. **Dry-run then install:** `sync-scheduler.sh install --dry-run` (expect beeper,
   notify, feedback rows; two disabled) → `install` → `status` shows
   `INSTALLED yes` ×3 and one `LEGACY com.relationship-agent.sync.beeper` line.
4. **Retire the legacy agent** exactly as `status` prints it:
   `launchctl bootout gui/$UID/com.relationship-agent.sync.beeper; rm ~/Library/LaunchAgents/com.relationship-agent.sync.beeper.plist`.
   Do this only after step 3's beeper lane has had one `LAST_EXIT 0`.
5. **Kickstart each lane once** (`launchctl kickstart gui/$UID/com.spomni.sync.<lane>`)
   and read `LAST_EXIT`: beeper 0 with events or `skip`; notify 0 (outbox render, no
   channel configured is fine); feedback 0 (nothing to parse is fine).
6. **Close the open-source-readiness residual** ("LEGACY launchd agents on live
   machine") in the memory note. Leave the `stream-connectors` worktree on disk until
   Phase 1 is green — it is the rollback.

Exit: `status` from the main checkout lists beeper/notify/feedback with last/next
run, no LEGACY line, `check-sync.sh data/store` clean.

## Phase 1 — Plan-28 live proof U5.2–U5.5 (user session, ~1 h wall clock mostly waiting, no code)

Runs the block already specified in `2026-08-29-28-autonomous-sync-runtime.md` §U5
and `docs/SETUP.md` §5a, unchanged. Checklist with evidence to capture:

| Step | Command / action | Evidence to paste into the close-out |
|---|---|---|
| U5.2a | `mcp-lane-tick.sh preflight --claude-bin /Users/ericg/.local/bin/claude --lane gmail` and `--lane calendar` | both `preflight-ok` lines with tool lists |
| U5.2b | flip `gmail-in`/`calendar-in` → `true`; `install`; `status` | five lanes, intervals 900/900/900/3600/7200 |
| U5.3 | `launchctl kickstart` gmail-in, then calendar-in (not simultaneously — see Phase 2 A1) | state files exit 0; lane logs `tick-ok` + sweep summary incl. `inline-spilled=<n>`; new `inbox/` files; `check-sync.sh data/store` clean |
| U5.4 | open the tick's session log | no message/event body in model output; saved tool-result path + cp/jq actors visible → closes plan-26 U12.3 |
| U5.5 | `launchctl bootout` + `bootstrap` both new plists from disk | `status` NEXT_RUN populated for both |

Known risks to pre-empt: (a) preflight-fail naming a Gmail/Calendar tool → connector
needs re-linking in claude.ai on the **new** account (chunk-30 note); (b) headless
`claude -p` needs the MCP connectors available outside an interactive session — if
preflight passes but the tick exits nonzero with a tool-missing message, that is the
finding to record, not to work around; (c) the 900 s watchdog vs a 4-page gmail sweep
— if exit 3 appears, halve `pages=` before touching `--timeout-seconds`.

Close-out edits (orchestrator, docs only): plan-28 Status → Done with evidence table;
ROADMAP row 28 → Done; row 26 residual note → closed; memory notes for 28 and 26;
SETUP §5a gets any step the run taught. Then remove the `stream-connectors` worktree.

## Phase 2 — Chunk 29: connector fleet (code; orchestrated; ~4 worker units)

Scope from ROADMAP §29: roster toggle by config, concurrent-run isolation proven, a
new-lane playbook validated by scaffolding a dry-run fixture lane. Explicitly **no new
real lanes, no contacts-in** (plans 26/27/28/30 all reserve that).

**Design points, decided here:**

- **D1 — Per-lane overlap is launchd's job; cross-lane overlap is ours.** launchd never
  double-starts one label, but five labels fire independently and three of them write
  `inbox/` through `normalize-capture.sh`, while `feedback` must observe the beeper
  events of the *same* tick. Two mechanisms, both config, no daemon:
  1. `normalize-capture.sh` writes are already atomic per file (tmp + `mv`); assert
     it in a test rather than assume it.
  2. Add an optional fifth column `after` to `sync-lanes` (contract 1.0.0 → 1.1.0,
     additive, blank allowed): a lane with `after=<lane>` skips its run with
     `skip-waiting-on=<lane>` when that lane's state file shows a run in flight
     (`run-start` newer than `run-end`). `feedback` ships `after=beeper`. This is the
     only ordering the fleet needs today and it is isolation-by-config, matching the
     ROADMAP's "config act" goal.
- **D2 — Roster toggle already exists** (`enabled` column + prune on `install`); 29's
  work is to **prove** it: a test that flips a row false → `install --dry-run` reports
  "Would prune", true → "Would install", with no other row touched.
- **D3 — New-lane playbook** = `docs/NEW-LANE.md` + a fixture lane
  `packages/connectors/tests/fixtures/fleet/fixture-in.sh` that emits one deterministic
  capture-event 1.2.0 file into a temp store. The playbook is validated by the test
  that scaffolds it from the template and runs it under `sync-scheduler.sh run`
  (not launchd), landing a `check-sync`-clean event.
- **D4 — Concurrency proof** = a scheduler test that runs beeper-stub, fixture-in, and
  notify-stub via `sync-scheduler.sh run` concurrently (`&` + `wait`) into one temp
  store, then asserts: N distinct inbox files, zero partial/tmp leftovers,
  `check-sync` clean, and the `after`-gated lane logged `skip-waiting-on` when its
  predecessor was held open by a sleeping stub.

**Units (splitting rule; each ≤3 min; single-writer per package):**

| Unit | Package | Content | Depends |
|---|---|---|---|
| A1 | core | `contracts/sync-lanes.md` 1.0.0 → 1.1.0 (`after` column, semantics, blank = none); template row for `feedback` gains `after=beeper`; manifest provides bump | — |
| A2 | connectors | `sync-lib.sh` parses/validates column 5 (fail-closed on unknown lane name); `sync-scheduler.sh run` implements the in-flight check + `skip-waiting-on` log line; manifest consumes bump | A1 |
| B1 | connectors (tests) | scheduler suite: toggle proof (D2), concurrency proof (D4), `after` gate proof; fixture lane script + stubs | A2 |
| C1 | docs (orchestrator) | `docs/NEW-LANE.md` playbook; SETUP pointer; ROADMAP row 29; `sync-lanes` contract changelog line | A1 |

Dispatch: A1 alone → A2 (warm connectors worker) ‖ C1 (orchestrator) → B1. Collateral
sweep before B1: grep every `lanes.tsv` reader (`sync-lib.sh`, `check-sync.sh`,
`deliver-tick.sh`, feedback-parse, tests' fixtures) for a 4-column assumption.

**Proof of done (maps to ROADMAP §29):** all five live lanes installed from config
and running concurrently on the real machine with `check-sync.sh data/store` clean
after 24 h; the fixture lane scaffolded from the playbook lands a clean event under the
scheduler in the test suite; toggling a row is the only step to add/remove a lane.
Live 24-h evidence is a Phase-2 tail run by the user, not a worker.

## Out of scope (do not pull in)

- Always-on / cloud runner and the sweep heartbeat → staleness wake-up: plan 09.
- New evidence sources (contacts-in, LinkedIn, enrichment): permanently out (mission).
- Beeper deep chat backfill (bridge history is shallow — plan 26 D6): not a fleet
  problem.
- Nudge-delivery phase 2 (plan 34): waits on the ledger gate ~2026-09-13.

## Execution order

Phase 0 → Phase 1 (same user session, ideally today) → close-outs → Phase 2 after
plan 09 per the ROADMAP order (`09 → 07 brief → 29`); Phase 2 has no dependency on 09
and can be pulled earlier if 09 stalls.

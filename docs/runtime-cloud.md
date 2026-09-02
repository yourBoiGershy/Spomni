# Cloud runtime

The cloud runtime is the assistant's heartbeat: a small set of named,
scheduled routines running as Claude Code scheduled routines in the cloud
environment. Each routine is code-driven (deterministic scripts, not
freeform agent judgment for the mechanical parts), reads and writes the
user's private data repo, and commits its own state back via store-sync
(plan 09) so the repo — not any in-memory process — is the durable record
of what has and hasn't run. This doc defines the cadence layer: which
routines exist, how often they fire, how they're ordered relative to each
other, and how each proves it's alive. It does not define the cloud
environment itself (base image, secrets, git identity, deadman escalation
mechanics) — that's plan 09's scope; see "Integration with plan 09" below.

## Cadence map

| Routine | Default cadence | Does |
|---|---|---|
| `sync-sweep` | 2–3×/day (param) | connector-in sweeps via the CLI (code-driven lane) → inbox → filing → store-sync commit; stamps its heartbeat (`heartbeat-stamp.sh`, plan 09 deadman) |
| `daily-attention` | each morning, after the first sync (param) | fire due wake-ups (06), signal pass (05), emit nudges sized to today's tier/budget from the week-plan |
| `weekly-planning` | Sunday evening (param) | run capacity computation, write `signals/week-plan.json`, commit |

Every cadence above is a default — each routine's actual fire times are
parameterizable in its routine definition, not hardcoded into this doc.

## Routines

### `sync-sweep`

- **Cadence param:** `SYNC_SWEEP_TIMES` (list of times/day; default 2–3×/day).
- **Entry:** the sync-scheduler lanes (plan 19) — `sync-scheduler.sh run
  <lane>` per configured connector-in lane (gmail, calendar, beeper, …),
  config-driven via `<data-dir>/connectors/sync-scheduler/lanes.tsv`. Each
  lane sweep lands raw capture events in `inbox/`, the filing engine files
  them into the people store, and a store-sync commit lands the result on
  `main`.
- **Heartbeat:** none of its own — each connector lane's liveness is read
  from the sync scheduler's `state/<lane>.tsv`; plan 09's staleness rule
  fires one wake-up if a lane goes quiet for > 2× its `interval_seconds`.

### `daily-attention`

- **Cadence param:** `DAILY_ATTENTION_TIME` (default: each morning, after
  the day's first sync-sweep has landed).
- **Entry:** `packages/attention/skills/sweep/`, built by plan 06. Step
  order: fire due wake-ups → signal-scan → fire newly-due promotions is NOT
  done (promotions are dated ahead) → acted-on detection → calibrate →
  un-debriefed mention → hand batch to output adapter. It emits nudges sized
  to today's tier/budget read from `signals/week-plan.json` (plan 12's
  capacity model). Before selecting, it checks week-plan staleness — a plan
  older than 8 days is regenerated first (invoking the same logic as
  `weekly-planning`) rather than selecting against stale capacity data.
- **Heartbeat:** `heartbeat-stamp.sh <store> daily-attention --cadence-hours
  24` at the end of every run (plan 09 staleness rule, see below).

### `weekly-planning`

- **Cadence param:** `WEEKLY_PLANNING_TIME` (default: Sunday evening).
- **Entry:** `packages/attention/skills/weekly-planning/` (this plan, 12) —
  store-sync pull → `packages/attention/scripts/capacity.sh` → commit. Reads
  the coming week's filed calendar events, computes per-day and weekly
  capacity tiers plus the discretionary nudge budget, and writes
  `signals/week-plan.json` (single writer: attention). Logs a one-line
  summary (tier + budget) and goes silent — no delivery, this is planning
  state, not a digest.
- **Heartbeat:** `heartbeat-stamp.sh <store> weekly-planning --cadence-hours
  168` on successful commit only; a failed capacity computation must not
  leave a partial `week-plan.json` write (loud log instead), so the heartbeat
  never stamps `--ok` on failure.

## Queue runtime model (plan 06)

This section defines how the routines above and any on-demand chat session
share a single runtime primitive: the wake-up queue.

**One primitive.** Every reminder — scheduled or ad hoc — is a
`wakeups/<id>.md` entry (wakeup contract 1.2.0). "Remind me this afternoon"
(`origin: user-ask`), "sync with her in a month" (`origin: user-ask`), every
signal the scout promotes (`origin: signal`), and recurring rhythms
(`origin: standing`) are all the same artifact. No digests exist anywhere in
the system; a "recurring rhythm" is just a queue entry whose due date gets
re-set to the next occurrence, not a separate mechanism.

**Who writes what.** Creation is open: any package appends a new
`wakeups/<id>.md` via core's `packages/core/scripts/wakeup-add.sh` (the
single shared creation path, per the single-writer rule on artifact
*creation*). Lifecycle transitions — `list-due`, `fire`, `snooze`,
`dismiss`, `confirm`, `decline` — go through exactly one script,
`packages/attention/scripts/wakeup-queue.sh`, and nowhere else; entries are
never hand-edited for status changes. `fire` has exactly two *scheduled*
callers: the sync scheduler's deterministic `attention-fire` lane
(`packages/core/templates/sync-lanes.tsv`, plan 44 — hourly `fire` +
`acted-on`, no model session, so `user-ask` reminders fire on their due
date even when no sweep runs) and the sweep
(`packages/attention/skills/sweep/`, the `daily-attention` routine's entry
skill, which stays the only scheduled *producer* of signal-derived
wake-ups). On-demand chat sessions may also call it directly (see below).

**Firing rules.**

| Origin | Fires when |
|---|---|
| `user-ask` | Always fires on its due date — budget-exempt, ignores the week's tier entirely. |
| `signal` / `standing` | Fires only while this week's fired count is still below `budget.max` from `signals/week-plan.json` (a missing or stale week-plan falls back to budget 3, with a warning logged). Once the cap is hit, remaining due entries stay `pending` and roll to the next window — never dropped. |

Two rules apply regardless of origin: a **meeting-adjacency check** blocks
firing within `ADJACENCY_MINUTES` (default 30) before or after a calendar
event — an entry that would land in that window is held for the run, not
fired early or late; and firing is **idempotent** — an entry fires once,
`fired-on` records the date of that first fire, and re-running `fire` against
an already-fired entry is a no-op.

**Batching.** Everything due and cleared to fire in one run is delivered as
ONE batch, not one message per entry: the fired-batch artifact
`wakeups/fired/<today>T<time>Z-batch.json`. Each entry in the batch carries
its resurfaced context (and, for `origin: signal`, its draft); entries with
`kind: event-proposal` additionally carry `proposed_event`, which the batch
renders as a proposal card with confirm/decline affordance rather than a
plain nudge. Plan 07's output adapters render this batch into whatever
surface the user reads; until 07 lands, the batch file on disk *is* the
delivery.

**On-demand sessions.** A chat session is not a separate code path — it can
call `list-due`/`fire` on `wakeup-queue.sh` itself, the same script under
the same rules, e.g. when the user asks "anything for me today?" outside any
scheduled routine. Snooze/dismiss issued from chat write back through the
same script, and the resulting outcome fields (`dismiss-reason`,
`snooze-count`, `acted-on`) feed the calibration step into
`ranking-weights.json`, which shapes the next scan's ranking — chat actions
and scheduled-sweep actions close the same feedback loop.

**Silence principle.** If nothing is due, or everything due is held (budget
exhausted or meeting-adjacent), no batch is written and no message is sent —
the run exits 0. A sweep that finds nothing to fire stays completely silent;
this is the expected outcome on most days, not a degraded one.

**No-guilt rule.** An un-debriefed meeting is mentioned at most once across
its lifetime, then dropped silently — the mention itself is recorded so it
never repeats on a later sweep. No batch, ever, surfaces counts, streaks, or
backlog language about what the user missed.

## Standing rules

- **Parameterization.** Every cadence in the table above is a named
  parameter on its routine definition, not a hardcoded schedule — an
  operator can retune frequency without touching routine logic.
- **Heartbeats everywhere.** Every routine stamps a heartbeat on completion;
  plan 09's staleness→wake-up rule is what notices when a routine has
  stopped firing and raises a wake-up for it.
- **Ordering.** `daily-attention` always runs after that day's first
  `sync-sweep` — it never fires against a store that hasn't seen the
  morning's sync.
- **Stale week-plan regeneration.** `daily-attention` regenerates
  `signals/week-plan.json` before selecting if it's more than 8 days old,
  rather than budgeting off stale capacity data.
- **Explicit wake-ups are budget-exempt.** User-requested wake-ups always
  fire on their scheduled date regardless of the day's capacity tier or
  discretionary budget.
- **Meeting-adjacency check.** No routine schedules or fires a nudge
  immediately before or right after a meeting — this check applies at
  firing time, not just at ranking time.
- **Wake-up queue over digests.** Routines emit wake-up queue entries and
  drafts — never digests or summaries pushed at the user. A routine that
  finds nothing to do stays SILENT; silence is a valid, expected outcome,
  not a failure.
- **Draft, never send.** Inviolable across every routine: nothing here ever
  sends an outbound message. Every routine output is a draft or a queue
  entry that waits for the human to act on it.

## Cloud environment (plan 09)

The environment a phone/cloud session or scheduled routine runs in **is the
user's private data repo**, not the machinery repo. Nothing here needs `npm`,
a server, or a secret.

- **Setup.** The data repo's `CLAUDE.md` (written by `init-store.sh` from
  `packages/core/templates/data-repo-CLAUDE.md`) tells a cold session to
  shallow-clone the machinery into `machinery/` (gitignored in the data repo)
  and run everything from there with bash + jq. A routine's setup script does
  the same: `git clone --depth 1 --single-branch <machinery-url> machinery` and
  `export SPOMNI_STORE=.`.
- **Git identity.** Cloud sandboxes have none; `store-sync.sh commit` falls
  back to `SPOMNI_GIT_NAME` / `SPOMNI_GIT_EMAIL` (default `Spomni
  <spomni@localhost>`) without touching global config.
- **Secrets.** None. Gmail/Calendar are reached only through the first-party
  claude.ai connectors the user linked (`composio-retired`), which are
  session-scoped — there is nothing to store.
- **Where routines can run.** `daily-attention` and `weekly-planning` run
  anywhere the data repo is checked out. `sync-sweep`'s beeper lane is
  **Mac-only** (desktop bridge) and stays under launchd; its gmail/calendar
  lanes need a session that carries the connectors.
- **Cold-start target (measured).** `packages/query/tests/bench-cold-start.sh`
  is the single source. Baseline 2026-08-30, laptop, real GitHub remote,
  private 127-person store: clone **1.25 s** + first `who-next-direct.sh`
  answer **3.86 s** = **5.1 s** clone→answer (target ≤ 15 s cold, ≤ 5 s warm).
  The 1 m 27 s figure that motivated this plan was the `npm ci` + MCP-server
  path; the zero-setup path (plan 35) never takes it. Remaining lever: the
  answer stage, owned by plan 38.

### Store-sync (the write discipline)

`packages/core/scripts/store-sync.sh status|pull|commit [-m msg]|push
[<store-dir>]` is the only way any runtime writes the data repo back:
`commit` reindexes (`reindex.sh` when plan 38's wrapper is present, else
`build-index.sh` + `build-stats.sh`), runs `validate-store.sh`, and **refuses**
a store that fails validation; `push` retries once through a pull-merge on a
non-fast-forward race, then fails loudly; nothing ever rebases. A store dir
that is not a git repo makes every subcommand a one-line no-op, so the same
skills work on a plain directory.

### Heartbeats + staleness (deadman)

- **Routines** stamp `<store>/heartbeats/<routine>.json` (contract
  `packages/core/contracts/heartbeat.md` 1.0.0: `routine`, `stamped_at`,
  `cadence_hours`, `ok`) via `packages/core/scripts/heartbeat-stamp.sh <store>
  <routine> --cadence-hours N [--ok|--fail]` at the end of every run — the
  `last-sweep` / `last-daily-attention` one-line files this doc used to
  describe are superseded by that contract.
- **Connector lanes** are *not* stamped twice: their liveness is read from
  the sync scheduler's existing `connectors/sync-scheduler/state/<lane>.tsv`
  (`last_start`, `last_end`, `last_exit`) against `lanes.tsv`'s
  `interval_seconds`.
- **Staleness rule.** `packages/attention/scripts/staleness.sh <store>
  [--sync-data-dir <dir>]` (called from `sweep`) treats anything quiet for more
  than **2 × its cadence** as stale and creates **exactly one** pending
  wake-up per stale subject (`origin: standing`, `source-signal:
  staleness:<name>`, `signal-type: staleness`, `--person self`) — skipped while
  one is already pending or fired-unresolved. A never-run routine or lane does
  not alarm. A dead schedule announces itself once, then stays silent.

## References

- `docs/plans/2026-08-29-12-cadence-capacity.md` — defines this cadence map
  and the capacity model that sizes `daily-attention`'s nudge budget.
- `docs/plans/2026-08-29-09-infrastructure.md` — cloud environment spec,
  heartbeat/deadman staleness rule.
- `docs/plans/2026-08-29-19-sync-scheduler.md` — the sync-scheduler lanes
  that are `sync-sweep`'s entry point.

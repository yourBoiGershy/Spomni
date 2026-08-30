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
| `sync-sweep` | 2–3×/day (param) | connector-in sweeps via the CLI (code-driven lane) → inbox → filing → store-sync commit; stamps `last-sweep` heartbeat (plan 09 deadman) |
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
- **Heartbeat:** stamps `last-sweep` in the data repo on completion; plan
  09's deadman rule fires a staleness wake-up if `last-sweep` goes stale
  (> 2× the configured interval).

### `daily-attention`

- **Cadence param:** `DAILY_ATTENTION_TIME` (default: each morning, after
  the day's first sync-sweep has landed).
- **Entry:** `packages/attention/skills/sweep/` — **forward-declared**,
  unbuilt as of this doc (plan 06). When built it: fires due wake-ups (06),
  runs the signal pass (05), and emits nudges sized to today's tier/budget
  read from `signals/week-plan.json` (plan 12's capacity model). Before
  selecting, it checks week-plan staleness — a plan older than 8 days is
  regenerated first (invoking the same logic as `weekly-planning`) rather
  than selecting against stale capacity data.
- **Heartbeat:** stamps its own completion marker per plan 09's
  staleness→wake-up rule (same mechanism as `last-sweep`, distinct key).

### `weekly-planning`

- **Cadence param:** `WEEKLY_PLANNING_TIME` (default: Sunday evening).
- **Entry:** `packages/attention/skills/weekly-planning/` (this plan, 12) —
  store-sync pull → `packages/attention/scripts/capacity.sh` → commit. Reads
  the coming week's filed calendar events, computes per-day and weekly
  capacity tiers plus the discretionary nudge budget, and writes
  `signals/week-plan.json` (single writer: attention). Logs a one-line
  summary (tier + budget) and goes silent — no delivery, this is planning
  state, not a digest.
- **Heartbeat:** stamps its own completion marker on successful commit; a
  failed capacity computation must not leave a partial `week-plan.json`
  write (loud log instead), so the heartbeat only stamps on success.

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

## Integration with plan 09

Plan 09 (stream-infrastructure, in progress) owns the cloud environment
spec itself — base environment, git identity and repo-scoping, secrets,
store-sync mechanics, and the deadman/staleness escalation machinery that
every heartbeat above relies on. This doc deliberately defines only the
cadence layer (which routines exist, their parameters, their ordering, and
what each stamps); plan 09 folds its environment detail into this file as
that work lands, rather than duplicating the cadence map there.

## References

- `docs/plans/2026-08-29-12-cadence-capacity.md` — defines this cadence map
  and the capacity model that sizes `daily-attention`'s nudge budget.
- `docs/plans/2026-08-29-09-infrastructure.md` — cloud environment spec,
  heartbeat/deadman staleness rule.
- `docs/plans/2026-08-29-19-sync-scheduler.md` — the sync-scheduler lanes
  that are `sync-sweep`'s entry point.

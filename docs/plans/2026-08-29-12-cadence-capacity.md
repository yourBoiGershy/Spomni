# Plan 12: Cadence & capacity — scheduled routines, capacity-aware nudging
Status: Ready
Package: attention (capacity model, week-plan writes) + core (week-plan contract) + docs (cadence map); amends plans 05 and 06
Depends-on: 01; 05, 06, 09 (integrates — amends 05/06, extends 09's routine spec)

## Objective
Give the cloud runtime a heartbeat with judgment: three named scheduled routines
(sync, daily attention, weekly planning) and a capacity model that reads the
coming week's calendar so nudge volume and nudge *kind* match the user's actual
bandwidth. Busy week → one or two low-effort nudges to strong ties. Open week →
room for dormant, lesser-known connections and reactivation drafts. Explicit
user-requested wake-ups always fire; capacity governs discretionary nudges only.

## Context
Read docs/PROJECT-CONTEXT.md first. Decisions that bind this plan:
- **cloud-native-runtime** — routines are Claude Code scheduled routines in the
  cloud environment, committing to the data repo's `main` via store-sync (09).
- **composio-hub / composio-dual-transport** — sync-sweep drives the composio-in
  sweep skills via the CLI (code-driven lane).
- **wake-up-queue-over-digests** — routines fire queue entries; nothing here is
  a digest. The week-plan is planning state, not a delivery.
- **attention-merge** — capacity logic and week-plan writes belong to the
  attention package; core owns only the contract (single-writer rule).
- **Draft, never send** — inviolable; every routine output is a draft or a
  queue entry, never an outbound message.
- Standing doctrine: **never nudge immediately before or right after a
  meeting** — firing-time adjacency check, not just ranking.

**Amendments to unbuilt plans — whoever builds 05 or 06 must read this plan
first:**
- **Plan 05, "Ranking spec" deliverable + Wave A unit 1:** capacity tier
  becomes a ranking *input*. The fixed ~5-nudge cap becomes a capacity-derived
  daily/weekly budget (table below); tie-strength preference inverts with
  capacity (busy → strong/frequent ties rank up; open → dormant/weak ties with
  longest silence rank up, reactivation drafts allowed).
- **Plan 06, "Scheduled-agent wiring" + "Batching rules" deliverables, Wave A
  unit 3 and Wave B unit 5:** the single sweep schedule becomes the three-routine
  cadence map below (`docs/runtime.md` content folds into `docs/runtime-cloud.md`'s
  cadence section); "overflow rolls to next window" is now governed by the
  day's budget from the week-plan; firing gains the meeting-adjacency check and
  the explicit-wake-up exemption; weekly-planning is a new 06-family routine.

## Capacity model (the decisions, made here)
- **Inputs:** filed calendar events for the next 7 days (from the store —
  calendar-sweep → filing; connectors stay dumb, capacity never calls APIs).
- **Per-day tier** (working window 09:00–18:00 local, parameterizable):
  `busy` = ≥5 meeting-hours or largest free block <2h; `open` = ≤2
  meeting-hours; else `normal`.
- **Weekly tier:** `busy` if ≥3 busy days; `open` if ≥4 open days; else
  `normal`.
- **Discretionary nudge budget:** busy → 1–2/week, strong/frequent ties,
  low-effort messages; normal → 2–3/week; open → 3–5/week, include
  dormant/lesser-known ties. Explicit user-requested wake-ups are EXEMPT —
  they always fire on their date regardless of tier or budget.
- **Artifact:** `signals/week-plan.json` in the data repo — weekly + per-day
  tiers, meeting-hours, free blocks, budget, generated-at. Single writer:
  attention. Stale if older than 8 days → daily-attention regenerates before
  selecting.

## Routine cadence map (lands in docs/runtime-cloud.md)
| Routine | Default cadence | Does |
|---|---|---|
| `sync-sweep` | 2–3×/day (param) | composio-in sweeps (CLI) → inbox → filing → store-sync commit; stamps `last-sweep` heartbeat (09 deadman) |
| `daily-attention` | each morning, after the first sync (param) | fire due wake-ups (06), signal pass (05), emit nudges sized to today's tier/budget from the week-plan |
| `weekly-planning` | Sunday evening (param) | run capacity computation, write `signals/week-plan.json`, commit |

All cadences parameterizable in the routine definitions; every routine stamps
its heartbeat per plan 09's staleness→wake-up rule.

## Deliverables
- `packages/core/contracts/week-plan.md` — the week-plan schema: tier
  definitions with default thresholds (parameterizable), budget table,
  explicit-wake-up exemption, staleness rule, single-writer = attention.
- `packages/attention/scripts/capacity.sh` — deterministic: reads filed
  calendar events for the next 7 days, computes meeting-hours + free blocks +
  tiers + budget, writes `signals/week-plan.json` per the contract. Bash 3.2
  portable.
- `packages/attention/skills/weekly-planning/SKILL.md` — the Sunday routine:
  store-sync pull → `capacity.sh` → commit; logs a one-line week summary
  (tier + budget), then goes silent (no delivery — not a digest).
- Cadence-map section in `docs/runtime-cloud.md` (the table above + routine
  definitions + parameterization + heartbeat wiring), integrated with plan
  09's environment spec.
- Amendment edits to `docs/plans/2026-08-29-05-signal-engine.md` and
  `-06-wakeup-scheduler.md`: a marked "Amended by Plan 12" note at the top of
  each Context section plus the specific deliverable/work-unit changes listed
  above.
- `packages/attention/fixtures/capacity/` — three golden weeks (goldens before
  any skill prompt work).

## Work units
Wave A (parallel):
1. [worker] `packages/core/contracts/week-plan.md` — schema, tier thresholds
   and budget table from the Capacity model section above, exemption +
   staleness rules, single-writer declaration; register in core's `package.md`
   provides list.
2. [worker] `packages/attention/fixtures/capacity/` goldens: an open week, a
   busy week, and a mixed week of filed calendar events, each with its
   expected `week-plan.json` (tiers, hours, budget) — plus one scenario
   marking an explicit user wake-up due mid-busy-week (expected: fires).
3. [worker] Cadence-map section in `docs/runtime-cloud.md`: routine table,
   per-routine definition (cadence param, entry skill, heartbeat stamp),
   ordering rule (daily-attention after first sync), CLI-transport note for
   sync-sweep.
4. [worker] Amendment edits to plans 05 and 06 per the Context list — marked
   notes, no other restructuring of those plans.

Wave B (after A):
5. [worker] `packages/attention/scripts/capacity.sh` implementation against
   the contract; update attention's `package.md` (consumes week-plan contract,
   produces `signals/week-plan.json`).
6. [worker] Tests for `capacity.sh` against the Wave A goldens: three weeks
   produce exact expected artifacts; empty calendar → `open`; stale-input
   week (no events beyond day 2) still yields 7 per-day entries.
7. [worker] `packages/attention/skills/weekly-planning/SKILL.md` — pull →
   capacity → commit flow, failure behavior (capacity error → no partial
   week-plan write, loud log), silence principle.

Wave C (after B):
8. [checker] End-to-end verification: run `capacity.sh` on all three fixture
   weeks and diff against goldens; validate output against the contract;
   confirm plans 05/06 carry the amendment notes and reference this plan;
   confirm the exemption and meeting-adjacency rules appear in the contract,
   the cadence map, and the 06 amendment.

## Interfaces
Consumes: filed calendar interactions (03/04 filing of calendar-sweep events);
wakeup contract + `wakeup-add.sh` (01); `store-sync.sh` + heartbeat/routine
spec (09); composio-in sweep skills (10) as sync-sweep's body; query's
`get_contact_stats`/`suggest_reachouts` and core's `build-stats.sh` (08) as
tie-strength inputs for 05's amended ranking.
Produces: `signals/week-plan.json` + its core contract; the capacity tier and
budget that 05's ranking and 06's firing consume; the three-routine cadence
map plan 09's cloud environment instantiates.

## Proof of done
On the fixture open week: tier `open`, budget 3–5, dormant/lesser-known ties
eligible for selection. On the busy week: tier `busy`, budget 1–2, strong-tie
low-effort only — yet the seeded explicit wake-up still fires on its date. No
nudge is scheduled adjacent to a fixture meeting. `capacity.sh` output matches
all three goldens byte-for-schema and validates against the contract. The
cadence map names all three routines with parameterizable cadences and
heartbeat stamps. Plans 05 and 06 carry visible Plan 12 amendment notes.

## Out of scope
- Learning the user's preferred cadence from behavior (speculative — later)
- Timezone/travel awareness in capacity (later)
- Energy/priority modeling beyond meeting-hours and free blocks
- Building 05's ranking or 06's firing themselves (this plan amends their
  specs; those plans build them)
- Push notifications / delivery surfaces (07)
- Holiday/OOO calendar semantics

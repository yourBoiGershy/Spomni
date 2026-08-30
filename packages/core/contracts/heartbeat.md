# Contract: heartbeat

`schema_version: 1.0.0`

## Purpose

A dead schedule announces itself. Every scheduled *routine* (e.g.
`daily-attention`, `weekly-planning`) stamps a completion marker each time
it runs; attention's staleness check reads these stamps to notice a routine
that has silently stopped firing.

**Scope: routines only.** Connector *lanes* (beeper/gmail/calendar) do NOT
use this contract — their liveness is already tracked by the sync
scheduler's `connectors/sync-scheduler/state/<lane>.tsv`
(`last_start<TAB>last_end<TAB>last_exit`) together with `lanes.tsv`'s
`interval_seconds` (`contracts/sync-lanes.md`). This contract is not a
replacement for that mechanism and is not consulted for lanes.

## Store location

`heartbeats/<routine>.json` — one file per routine. `<routine>` matches
`^[a-z0-9-]+$` and is also the filename stem.

## Writer / readers

- **Single-writer rule:** the artifact unit is the *file per routine*; each
  routine is the sole writer of its own file, written only through
  `packages/core/scripts/heartbeat-stamp.sh`.
- **Producers:** `packages/attention`'s `sweep` and `weekly-planning`
  skills, each calling `heartbeat-stamp.sh` at the end of their run (success
  or failure, per the `ok` field).
- **Readers:** `packages/attention`'s staleness check.

## Shape

A single JSON object, 2-space indent.

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | semver string | yes | Contract version this file conforms to. |
| `routine` | string | yes | Kebab-case routine name; matches the filename stem, e.g. `daily-attention`. |
| `stamped_at` | ISO 8601 datetime | yes | UTC, `Z`-suffixed. When this stamp was written. |
| `cadence_hours` | integer | yes | ≥ 1. The routine's expected period between runs. |
| `ok` | boolean | yes | `true` if the routine completed successfully; `false` if it ran but failed. A failed run is still a heartbeat — the schedule is alive either way. |

### Example

```json
{
  "schema_version": "1.0.0",
  "routine": "daily-attention",
  "stamped_at": "2026-08-30T14:02:11Z",
  "cadence_hours": 24,
  "ok": true
}
```

## Staleness rule

Consumed by `packages/attention`: a routine is **stale** when
`now - stamped_at > 2 * cadence_hours`. A missing heartbeat file is not
stale — a routine that has never run is not yet an alarm.

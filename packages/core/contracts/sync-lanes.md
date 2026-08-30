# Contract: sync-lanes

`schema_version: 1.0.0`

## Scope

This contract governs `<data-dir>/connectors/sync-scheduler/lanes.tsv` — the
config-driven lane list for the scheduled-syncs runner
(`packages/connectors/scripts/sync-scheduler.sh` /
`packages/connectors/scripts/sync-lib.sh`, plan 19). Config is data, not
code: interval and enable changes are edits to this file plus an `install`
re-run, never a code edit.

## Store location

`<data-dir>/connectors/sync-scheduler/lanes.tsv` — user-edited, one file per
data dir. Not committed to any repo (it lives under the private data dir,
per `data/README.md`).

## Row format

One lane per line:

```
lane<TAB>interval_seconds<TAB>enabled<TAB>command
```

`command` is the remainder of the line after the third tab — it may contain
spaces, but never tabs (a tab inside `command` would be indistinguishable
from a field separator).

## Field rules

| Field | Type | Rule |
|---|---|---|
| `lane` | string | `[a-z0-9-]+`, unique within the file. |
| `interval_seconds` | integer | ≥ 60. |
| `enabled` | enum | literal `true` or `false` — no other spelling. |
| `command` | string | absolute-path invocation, run via `/bin/bash -c` under launchd's minimal environment: no user shell profile is sourced, so commands must not assume any `PATH` beyond `/usr/bin:/bin:/usr/sbin:/sbin`. Skip conditions inside a lane (no token, source unreachable) exit 0, per `connector-interface.md`'s sweeps convention — the scheduler treats exit 0 as a clean run regardless of whether work happened. |

A lane's `command` may itself be a model session — a headless `claude -p`
wrapper such as connectors' `mcp-lane-tick.sh` — rather than a plain script.
For such lanes, `interval_seconds` is not just a freshness knob but a cost
decision: each tick spends a capped model session, so the interval should be
set deliberately rather than defaulted low. See the template's MCP lane rows
(`packages/core/templates/sync-lanes.tsv`) for worked defaults and rationale.

Blank lines and lines starting with `#` are ignored (comments). Leading
whitespace before `#` does not count — a comment line must start with `#` in
column 1 to be recognized as a comment by lane-list parsing; anything else on
an otherwise-blank-looking line is a malformed row.

## Fail-closed parsing

A malformed row fails the whole file: any consumer parsing `lanes.tsv` (e.g.
`sync_lanes_list`) must reject the entire file — not just skip the bad
line — on the first row that doesn't match the format above. This is
deliberate: the installer must never act on a config it can only partially
understand (e.g. silently dropping a lane it failed to parse would silently
stop syncing it).

## Runtime layout

Sibling paths under the same `<data-dir>/connectors/sync-scheduler/` root
that this contract's consumers read/write, for context (not part of the
`lanes.tsv` row format itself):

- `lanes.tsv` — this file, the config.
- `state/<lane>.tsv` — single line `last_start<TAB>last_end<TAB>last_exit`
  (ISO-8601 UTC timestamps), written atomically (tmp file + `mv`).
- `logs/<lane>.log` — scheduler + command output for that lane. Rotated: before
  an append or run, if the file exceeds 512000 bytes it is moved to
  `<lane>.log.1` (overwriting any previous `.1`) and a fresh `<lane>.log`
  starts empty. Single-rollover — there is no `.2`.
- `logs/<lane>.launchd.log` — launchd's own stdout/stderr capture for the
  job (belt-and-suspenders; normally near-empty since `run` redirects the
  command's own output into `<lane>.log`).

## Catch-up on wake

`StartInterval` launchd jobs do not fire while the machine is asleep. On
wake, launchd fires each job once if its interval elapsed during the sleep
window — this is coalesced to a single catch-up run, not replayed once per
missed interval. Lane commands must be written so their own cursors (per
`connector-interface.md`'s input-connector dedup obligation) absorb whatever
gap accumulated; `lanes.tsv` itself carries no state about missed runs.

## Example

```
# lanes.tsv — sync-scheduler lane config. See
# packages/core/contracts/sync-lanes.md for the format.
beeper	900	true	/bin/bash /Users/example/relationship-agent/packages/connectors/beeper-in/scripts/beeper-sweep.sh

# gmail-in	300	false	/bin/bash /Users/example/relationship-agent/packages/connectors/gmail-in/scripts/gmail-sweep.sh
```

## Notes

- Widening `command`'s conventions (e.g. allowing relative paths under a
  fixed workdir) would be a `schema_version` bump here; the row format
  (four tab-separated fields, `command` as remainder-of-line) is the
  stable surface other tooling (the installer's plist renderer, `status`)
  depends on.
- This contract does not define the plist template or the CLI surface of
  `sync-scheduler.sh` — those are plan 19 work units, not core's concern;
  core only owns the config file's shape.

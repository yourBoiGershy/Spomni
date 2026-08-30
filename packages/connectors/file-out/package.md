# package: connectors/file-out

version: 0.1.0

## Purpose

Always-on outbox audit adapter. Every fired wake-up batch a delivery tick
processes gets appended here regardless of which live channel (or none) it
also went to — this is the one delivery surface with no failure mode, no
network dependency, and no channel configuration. `packages/connectors/
scripts/deliver-tick.sh` calls this script for every batch, unconditionally,
before attempting any live channel adapter.

## Provides

- `scripts/file-out.sh <store-dir> --text-file <f> --batch <batch-path>
  [--today <YYYY-MM-DD>]` — appends the rendered card text to `<store-dir>/
  outbox/<today>.md` under a `## <batch filename>` section, creating
  `outbox/` if absent; prints `outbox: <path>`. Not idempotent by itself —
  the caller (`deliver-tick.sh`) is responsible for not re-invoking this
  script for a batch already recorded in `outbox/delivered.log`.

## Consumes

- Nothing beyond its own arguments — no config, no network, no store
  contract read. The rendered text and batch path are handed to it by the
  caller.

## Owned paths

`packages/connectors/file-out/**`; at runtime: `<store-dir>/outbox/
<date>.md` (writes, one file per calendar day).

## Built by

Plan 33 (`docs/plans/2026-08-30-33-nudge-delivery-beeper-self.md`).

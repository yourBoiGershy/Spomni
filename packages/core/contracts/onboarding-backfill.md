# Contract: onboarding-backfill

`schema_version: 1.0.0`

## Scope

This contract governs `<data-dir>/config/onboarding-backfill.tsv` — the
user-configurable window and self-identity list that connectors backfill
modes and ingestion seed scripts use to bound and scope onboarding backfill
(plan 24). This is config, not store data: it is user-supplied, not derived
by any package, and it lives under the private data dir, never in this repo
(per `data/README.md`).

Not `profile.md`: `profile.md` is the stated-preference singleton (sole
writer `packages/ingestion`, filed from debriefs/capture events) — it holds
preferences about how the assistant behaves, not backfill scheduling config.
Not `sync-lanes.md`: that contract governs the scheduled-syncs runner's
ongoing lane list (interval/enabled/command) — this contract governs a
one-time (or user-rerunnable) backfill window, not a recurring schedule.

## Store location

`<data-dir>/config/onboarding-backfill.tsv` — user-edited, one file per data
dir. Optional: a missing file is valid and defaults apply (see Field rules).

## Row format

One key per line:

```
key<TAB>value
```

Blank lines and lines starting with `#` are ignored (comments). `self` is
repeatable — one row per identity.

## Field rules

| Field | Type | Rule |
|---|---|---|
| `window_months` | integer | ≥ 1. Optional — **defaults to `6`** when the file or this key is absent. How far back onboarding backfill sweeps reach. |
| `self` | string | Repeatable. Each value is one of the user's own identities (email address or messaging handle, verbatim as the provider renders it). Used only by seed-time participation derivation (`packages/ingestion`) to distinguish the user's own messages from others'. |

## Fail-closed parsing

Same posture as `sync-lanes.md` 1.0.0: any consumer parsing
`onboarding-backfill.tsv` must reject the entire file on the first
malformed row — unknown key, a row that isn't `key<TAB>value`, or a
non-integer / `< 1` `window_months` value. No guessing, no partial reads.

A missing file is valid (defaults apply) — this is distinct from a malformed
file, which errors. Participation derivation (`packages/ingestion`)
additionally fails closed with a clear error message if run with zero `self`
entries resolved (file absent and no `self` rows, or file present with
`window_months` only) — it must never guess which identity is the user's own.

## Writer / readers

- **Writer:** the user, or an onboarding session acting on the user's
  explicit instruction. No package writes this file at runtime.
- **Readers:** `packages/connectors` backfill modes (read `window_months` to
  bound how far back a lane's backfill sweep reaches),
  `packages/ingestion` seed scripts (read `window_months` and `self` — the
  latter for seed-time participation derivation).

## Example

```
# onboarding-backfill.tsv — see
# packages/core/contracts/onboarding-backfill.md for the format.
window_months	6
self	user@example.com
self	+15551234567
```

## Notes

- Widening `value` semantics per key, or adding new keys, would be a
  `schema_version` bump here — the row format (`key<TAB>value`, `self`
  repeatable, fail-closed parsing) is the stable surface backfill modes and
  seed scripts depend on.
- This contract does not define the backfill sweep's own CLI surface or the
  seed script's participation-derivation algorithm — those are plan 24 work
  units; core only owns the config file's shape.

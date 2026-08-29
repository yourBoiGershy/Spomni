# Contract: ranking weights

`schema_version: 1.0.0`

A flat, regenerable JSON artifact holding calibrated signal-ranking
multipliers derived from wake-up outcome history — no database, no
embeddings, per `docs/DECISIONS.md#markdown-store-plus-index`. Disposable:
delete it and attention's calibration step rebuilds it from `wakeups/`
history; it is a derived cache of that history's aggregate, not a
source-of-truth store in its own right.

## Store location

`ranking-weights.json` — sits at the store root (sibling of `people/`,
`interactions/`, `index.json`, `stats.json`).

## Writer / readers

- **Sole writer:** `packages/attention`'s sweep `calibrate` step — the only
  code path allowed to write this file. It aggregates `wakeups/` outcome
  history (dismiss reasons, acted-on flags, snooze counts) into bounded
  weight adjustments on each calibration run.
- **Readers:** `packages/attention`'s signal-scan step (multiplies a
  candidate signal's rank by the matching weight, falling back to `1.0`
  when no entry exists), `packages/query` (surfaces weights and their
  `rationale` strings in explanations — "why did this rank high?" answers
  read this file directly, no re-derivation).

## Regenerable-from-history semantics

`wakeups/` outcome history (fired/dismissed/acted-on/snoozed records) is the
source of truth. `ranking-weights.json` is derived from it — a calibration
run reprocesses that history and produces the same weights (same
adjustments, same clamps) given the same input, exactly like `stats.json`
is derived fresh from `people/`/`interactions/` rather than trusted as an
independent ledger. Deleting the file and re-running calibration reproduces
it; no data is lost by doing so, only the record of prior calibration
rationale text (which itself was derived from history still present in
`wakeups/`).

## Shape

A single JSON object with a version/generation envelope plus a `weights`
map holding two calibrated dimensions: `signal-types` and `tags`.

```json
{
  "schema_version": "1.0.0",
  "generated_at": "<ISO 8601 datetime>",
  "weights": {
    "signal-types": {
      "birthday": {
        "weight": 0.7,
        "updated": "2026-08-29",
        "rationale": "4 of 5 birthday nudges dismissed not-this-signal-type in 90d"
      }
    },
    "tags": {
      "college-friend": {
        "weight": 1.15,
        "updated": "2026-08-29",
        "rationale": "acted on 6 of 7 fired nudges"
      }
    }
  }
}
```

Top-level fields:

| Field | Type | Notes |
|---|---|---|
| `schema_version` | semver string | This contract's version, `1.0.0`. |
| `generated_at` | ISO 8601 datetime | When the `calibrate` step last produced this file. |
| `weights` | object | Two keys: `signal-types` and `tags`. Each maps a key (a signal-type from plan 05's detector set, or a `person.md` tag string) to a weight entry. Either map may be empty (`{}`) if no calibration adjustment has fired for that dimension yet. |

Weight entry fields (identical shape under both `signal-types` and `tags`):

| Field | Type | Notes |
|---|---|---|
| `weight` | number | The rank multiplier. Clamped to `[0.25, 2.0]` — see Clamps below. |
| `updated` | ISO 8601 date | The date this entry's `weight` was last changed by a calibration run. |
| `rationale` | string | **Required.** A human-readable sentence explaining why the weight moved — the interpretability contract (see below). Never omitted, never machine-only shorthand. |

## Absent-key default

Any signal-type or tag with no entry in `weights.signal-types` /
`weights.tags` is neutral: attention's signal-scan step treats a missing
key as `weight: 1.0` (no adjustment). A key only appears once calibration
has produced a non-neutral adjustment for it; the file need not — and
should not — pre-populate every known signal-type or tag with an explicit
`1.0` entry.

## Clamps

- **Absolute bound:** every `weight` value is clamped to `[0.25, 2.0]`.
  Calibration must never push a weight outside this range, regardless of
  how lopsided the outcome history is — a signal-type or tag can be
  suppressed to a quarter-strength floor or boosted to double-strength
  ceiling, never zeroed out or unbounded.
- **Per-step bound:** a single calibration run may change any one entry's
  `weight` by at most `0.15` in either direction relative to its prior
  value (or relative to the `1.0` neutral default, if the entry did not
  previously exist). This makes calibration a slow, auditable drift rather
  than a single outcome swinging ranking sharply — consistent with the
  no-guilt, no-overreaction posture of `docs/DECISIONS.md#preference-provenance`.

## The interpretability contract

Every weight adjustment carries a human-readable `rationale` — that string
is the interpretability contract. It must describe, in plain language, the
outcome evidence behind the change (example strings from the calibration
design, reproduced verbatim):

- `"4 of 5 birthday nudges dismissed not-this-signal-type in 90d"`
- `"acted on 6 of 7 fired nudges"`

A `rationale` that only restates the number (e.g. `"weight lowered"`) does
not satisfy this contract — it must name the outcome pattern that drove the
change, so a user (or `packages/query`'s explanation surface) can answer
"why did this rank high/low?" by reading the file, no code required.

## Per-person suppression is out of scope

`ranking-weights.json` holds only `signal-types` and `tags` — dimensions
that generalize across the whole store. A `not-this-person` dismiss reason
does **not** get encoded as a weight here (there is no `people` key in this
contract's `weights` object, and none should be added). Per-person
suppression is handled as a proposal — the calibration step surfaces it as
a wake-up-style proposal the user confirms, never as a silent global-weight
mutation keyed to one slug. This mirrors the stated-outranks-revealed and
revealed-proposes-never-overwrites rules in
`docs/DECISIONS.md#preference-provenance`.

## Versioning

Additive fields (new keys under a weight entry, or a new top-level key
alongside `signal-types`/`tags`) are a `schema_version` minor bump, per the
`capture-event.md` precedent — existing `1.0.0` files remain valid and
readers ignore keys they don't recognize. Removing a field, changing a
field's type, or narrowing the clamp range is a major bump.

## Notes

- This file is flat, regenerable JSON — no DB, no embeddings, per
  `docs/DECISIONS.md#markdown-store-plus-index`. Deleting it and re-running
  the `calibrate` step reproduces it from `wakeups/` history.
- `generated_at` is the freshness signal for any consumer surfacing "when
  was ranking last calibrated" — same convention as `stats.json`'s
  `generated_at`.
- Ships as user-owned state under the user's `data/store/` — never
  committed to this repo; only anonymized fixtures exercise this contract
  in `packages/core/fixtures/`.

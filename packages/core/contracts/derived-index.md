# Contract: derived index

`schema_version: 1.0.0`

Two flat, regenerable JSON artifacts derived from the markdown store
(`people/*.md`, `interactions/*.md`) — no database, no embeddings, per
`docs/DECISIONS.md#markdown-store-plus-index`. Both are disposable: delete
either and the matching generator script rebuilds it byte-for-byte from the
store's source-of-truth files.

## `index.json`

### Store location

`index.json` — sits at the store root (sibling of `people/`, `interactions/`).

### Writer / readers

- **Sole writer:** `packages/core/scripts/build-index.sh`, invoked by the
  filing engine (`packages/ingestion`) at runtime after any write to
  `people/`.
- **Readers:** `packages/attention` (fast frontmatter filtering without
  opening every person file), `packages/query` (the `search_people` tool's
  filing/filter path, opportunistically — see the `staleness-cache` note
  below), `packages/core/scripts/validate-store.sh` (cross-check, advisory).

### Shape

A flat JSON object keyed by person `slug`, one entry per `people/<slug>.md`,
sorted by key (`jq -S`). No top-level envelope — no `schema_version` or
`generated_at` key at the object root; this contract's `schema_version:
1.0.0` header governs the shape below as built by `build-index.sh` today.

Per-slug value:

| Field | Type | Notes |
|---|---|---|
| `tags` | list of strings | Projected verbatim from `person.md`'s `tags`; `[]` if absent. |
| `org` | string or `null` | Projected from `person.md`'s `org`; `null` if absent. |
| `role` | string or `null` | Projected from `person.md`'s `role`; `null` if absent. |
| `location` | string or `null` | Projected from `person.md`'s `location`; `null` if absent. |
| `last-touch` | ISO 8601 date or `null` | Projected verbatim from `person.md`'s `last-touch` frontmatter field (the filing-engine-maintained value) — **not** computed from `interactions/*.md`; contrast with `stats.json`'s `last_interaction` below. `null` if absent. |

`tier` is deliberately **not** in `index.json` v1 — see `stats.json` below,
which projects it so tier-aware consumers never need to open a person file.
index.json's field set stays exactly what `build-index.sh` emits today; this
contract codifies existing behavior, it does not extend it.

### Example

```json
{
  "marcus-chen": {
    "tags": ["fintech", "business"],
    "org": "Vantage Financial",
    "role": "Director of Business Development",
    "location": "New York, NY",
    "last-touch": "2026-08-15"
  },
  "walter-combs": {
    "tags": ["family", "father"],
    "org": null,
    "role": "Retired civil engineer",
    "location": "Ann Arbor, MI",
    "last-touch": "2026-08-05"
  }
}
```

## `stats.json`

### Store location

`stats.json` — sibling of `index.json` at the store root.

### Writer / readers

- **Sole writer at runtime:** `packages/core/scripts/build-stats.sh`,
  invoked by the filing engine (`packages/ingestion`) after any write to
  `people/` or `interactions/`. Same single-writer rule as `index.json`.
- **Cache-copy exemption:** `packages/query`'s MCP server never writes into
  the store. Per `docs/DECISIONS.md#staleness-cache`, when it detects the
  store's `stats.json`/`index.json` are stale relative to the newest mtime
  under `people/`/`interactions/`, it shells out to `build-stats.sh` /
  `build-index.sh` and writes the regenerated copies to
  `${RA_CACHE_DIR:-$HOME/.cache/relationship-agent}/derived/` — a directory
  outside the store — and reads from there. Store copies remain
  ingestion's alone to write.
- **Readers:** `packages/attention` (the fallback reachout heuristic's
  staleness × tier × open-thread inputs), `packages/query` (all six MCP
  tools' rollups and pagination), `packages/core/scripts/build-stats.sh`'s
  own idempotency check (advisory).

### Shape

A single JSON object with a version/generation envelope plus a `people` map
keyed by slug — every person in `people/` appears, including people with
zero filed interactions.

```json
{
  "schema_version": "1.0.0",
  "generated_at": "<ISO 8601 datetime>",
  "people": {
    "<slug>": {
      "tier": "close",
      "touchpoints": 14,
      "first_interaction": "2024-03-02",
      "last_interaction": "2026-08-29",
      "median_gap_days": 41,
      "open_threads": 2,
      "commitments": {"user": 1, "them": 1},
      "interactions": [
        {"id": "2026-08-29-dana-whitfield", "date": "2026-08-29",
         "calendar": false, "others": []}
      ]
    }
  }
}
```

Top-level fields:

| Field | Type | Notes |
|---|---|---|
| `schema_version` | semver string | This contract's version, `1.0.0`. |
| `generated_at` | ISO 8601 datetime | When `build-stats.sh` (or the query cache's regeneration) produced this file. Every MCP tool result surfaces this so answers are honest about freshness (`staleness-cache` decision). |
| `people` | object | Keyed by slug, one entry per `people/<slug>.md`. |

Per-slug fields:

| Field | Type | Notes |
|---|---|---|
| `tier` | enum or `null` | Projected verbatim from `person.md`'s `tier` frontmatter field. `stats.json` is where tier becomes available to consumers that only read the derived layer — `index.json` v1 does not carry it, and this addition does not change `index.json`. `null` if the person has no `tier` set. |
| `touchpoints` | integer | Count of `interactions/*.md` files that list this person's `[[slug]]` in their `people` field. `0` for a person with no filed interactions. |
| `first_interaction` | ISO 8601 date or `null` | The earliest `date` among this person's interactions, **computed** by scanning `interactions/*.md` — not read from any frontmatter field. `null` if `touchpoints` is `0`. |
| `last_interaction` | ISO 8601 date or `null` | The latest `date` among this person's interactions, **computed** the same way. This deliberately does not reuse `person.md`'s `last-touch` (which is filing-engine-maintained but not guaranteed to be recomputed on every store mutation, e.g. a corrected interaction date) — `stats.json`'s value is the ground truth derived fresh at generation time. `null` if `touchpoints` is `0`. |
| `median_gap_days` | integer or `null` | Median of the gaps (in days) between consecutive interaction dates, sorted ascending. `null` if `touchpoints` is `0` or `1` (no gap exists). With an even count of gaps, use the mean of the two middle values, rounded to the nearest integer. |
| `open_threads` | integer | Count of top-level bullets under this person's `people/<slug>.md` `## Open threads` section. `0` if the section is empty or the person has none. |
| `commitments` | object `{user: integer, them: integer}` | Counted across every interaction this person is party to, by bullet owner in that interaction's `## Commitments` section: a bullet whose owner is literally `user` increments `commitments.user`; a bullet whose owner is this person's own `[[slug]]` increments `commitments.them`. Bullets owned by a *different* co-participant in a multi-person interaction (e.g. `[[ravi-kapoor]]: ...` inside an interaction that also lists `walter-combs`) do **not** count toward `walter-combs`'s `commitments` — they count toward `ravi-kapoor`'s instead, when his `stats.json` entry is built. `_none_` (the contract's valid-empty marker) contributes zero. |
| `interactions` | list | Every interaction this person is party to, **sorted newest-first by `date`** (ties broken by filename, descending). Each entry: |

`interactions[]` entry fields:

| Field | Type | Notes |
|---|---|---|
| `id` | string | The interaction's filename stem, e.g. `2026-08-29-dana-whitfield` (matches `interaction.md`'s `id`/store-location convention). |
| `date` | ISO 8601 date | Copied from the interaction's frontmatter `date`. |
| `calendar` | boolean | `true` if the interaction's `calendar-event` frontmatter field is non-null, `false` otherwise. |
| `others` | list of strings | The interaction's other participant slugs (its `people` list minus this person's own slug), stripped of the `[[...]]` wiki-link brackets. `[]` for a one-on-one interaction. |

### Example

Consistent with `packages/core/fixtures/store`'s `walter-combs` persona (one
`people/walter-combs.md` with a single `## Open threads` bullet and `tier:
inner-circle`, and two interactions: `interactions/2026-07-20-combs-family-
reunion.md` — a three-person interaction with `calendar-event: null` and a
commitment owned by `[[ravi-kapoor]]` — and `interactions/2026-08-05-walter-
combs.md` — a one-on-one call with `calendar-event: null` and a commitment
owned by `user`):

```json
{
  "schema_version": "1.0.0",
  "generated_at": "2026-08-29T18:00:00Z",
  "people": {
    "walter-combs": {
      "tier": "inner-circle",
      "touchpoints": 2,
      "first_interaction": "2026-07-20",
      "last_interaction": "2026-08-05",
      "median_gap_days": 16,
      "open_threads": 1,
      "commitments": {"user": 1, "them": 0},
      "interactions": [
        {"id": "2026-08-05-walter-combs", "date": "2026-08-05",
         "calendar": false, "others": []},
        {"id": "2026-07-20-combs-family-reunion", "date": "2026-07-20",
         "calendar": false, "others": ["eleanor-combs", "ravi-kapoor"]}
      ]
    },
    "marcus-chen": {
      "tier": "active",
      "touchpoints": 1,
      "first_interaction": "2026-08-15",
      "last_interaction": "2026-08-15",
      "median_gap_days": null,
      "open_threads": 1,
      "commitments": {"user": 1, "them": 0},
      "interactions": [
        {"id": "2026-08-15-marcus-chen", "date": "2026-08-15",
         "calendar": true, "others": []}
      ]
    }
  }
}
```

(`walter-combs`'s `commitments.them` is `0` because the family-reunion
interaction's one commitment bullet is owned by `[[ravi-kapoor]]`, a
co-participant, not by `walter-combs` himself; that bullet counts toward
`ravi-kapoor`'s own `commitments.them` instead. `marcus-chen`'s single
interaction has a calendar-event, hence `"calendar": true`; with only one
touchpoint there is no gap to measure, hence `median_gap_days: null`.)

## Notes

- Both files are flat, regenerable JSON — no DB, no embeddings, per
  `docs/DECISIONS.md#markdown-store-plus-index`. Deleting either and
  re-running its generator script reproduces it from the store.
- `index.json` and `stats.json` overlap deliberately (both are cheap to keep
  in sync from the same source files); `search_people`-style filtering can
  use either, but any consumer that needs `tier`, computed
  `last_interaction`, or interaction-level detail must read `stats.json` —
  `index.json` v1 is untouched by this contract and stays exactly what
  `build-index.sh` emits today.
- `generated_at` in `stats.json` is the freshness signal every `query` MCP
  tool result surfaces; `index.json` carries no such field today; a
  consumer wanting index freshness falls back to the file's own mtime.

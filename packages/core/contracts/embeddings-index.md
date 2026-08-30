# Contract: embeddings index

`schema_version: 1.0.0`

## Purpose

Defines the local, optional embeddings artifact used for neighbor priors
in relationship-scoring judgments, greedy threshold clustering, and one
revealed-behavior input to the user-model draft (`contracts/user-model.md`
D8(iii)). Anthropic offers no embedding model of its own — the available
managed option is Voyage AI, a cloud API, and sending person data there
would violate *other people's data stays local* (CLAUDE.md standing
principle). Embeddings therefore run **only** via a local Ollama instance
(`nomic-embed-text` as the default model; the open-weight `voyage-4-nano`
if present locally), invoked as a single `curl` + `jq` call from bash — no
Python, no PyTorch, no other embedding runtime.

## Locality rule

Embeddings are computed exclusively against `http://localhost:11434`
(local Ollama). No embedding vector or its inputs (person names, facts,
interaction summaries) is ever sent to a cloud embedding API. This is a
binding rule, not a default — no consumer of this contract may add a
cloud embedding fallback.

## Optionality rule

Every consumer of this artifact treats it as **optional**: when
`http://localhost:11434` is unreachable, the consumer logs
`embeddings: unavailable` and proceeds without neighbor priors or
clusters. Results must be identical to the embeddings-available path
minus the `neighbors:` segment of the breakdown string
(`contracts/relationship-scoring.md`) — no consumer degrades any other
output when embeddings are absent.

## Store location

`<store>/index/embeddings.jsonl` — sits under the store's `index/`
directory, sibling of `index.json` and `stats.json`. A regenerable
**derived** artifact: never a source of truth, never a query surface in
its own right, and never leaves the machine.

## Writer / readers

- **Sole writer:** `packages/ingestion`'s `embed-people.sh` (forward-declared).
- **Readers:**
  - `packages/ingestion`'s `nearest-confirmed.sh` (forward-declared) —
    neighbor priors for the relationship-scoring judgment.
  - `packages/ingestion`'s `cluster-people.sh` (forward-declared) — greedy
    threshold clustering so classification can run per cluster with
    exemplars.
  - `packages/ingestion`'s `derive-user-model.sh` (forward-declared) — the
    optional `embedding-similarity` revealed-behavior line
    (`contracts/user-model.md` D8(iii)).
  - `packages/attention` — drift neighbor priors, read-only
    (`contracts/relationship-scoring.md` `## Drift prefilter`).

## Shape

One JSON object per line (JSONL), one line per person.

```json
{"slug": "dana-whitfield", "model": "nomic-embed-text", "dims": 768, "vector": [0.0123, -0.0456, "..."], "embedded_at": "2026-08-29T14:03:11Z", "content_hash": "3a7f...e2c1"}
```

| Field | Type | Notes |
|---|---|---|
| `slug` | string | Must match an existing `people/<slug>.md` filename stem. |
| `model` | string, non-empty | The embedding model used, e.g. `nomic-embed-text`. |
| `dims` | integer | Vector length. Must equal `len(vector)`. |
| `vector` | array of numbers | Length `dims`. |
| `embedded_at` | ISO 8601 datetime | When this line was (re)computed. |
| `content_hash` | string | `sha256` of the person's `person.md` content plus filed interaction summaries linked to that person. Re-embedding is triggered only when this hash changes — an unchanged hash means the existing line is reused as-is. |

## Validation rules

- `slug` must correspond to a file in `people/` — a stale line for a
  deleted person is a validator warning, not filed data drift.
- `dims` must equal `vector`'s length exactly.
- `model` must be non-empty.
- No two lines may share the same `slug` (one embedding per person; a
  re-embed replaces the line rather than appending a duplicate).

## Uses

- **Neighbor priors:** the relationship-scoring judgment's `neighbors:`
  breakdown segment (`contracts/relationship-scoring.md`) — "most similar
  confirmed people" by vector distance, restricted to people with a
  confirmed kind/tier.
- **Greedy threshold clustering:** default similarity threshold `0.80`;
  the exemplar of a cluster is its highest-degree member (most neighbors
  above threshold within the cluster). Classification runs per cluster
  against its exemplar rather than per person, when embeddings are
  available.
- **User-model revealed input:** `derive-user-model.sh` may add the
  optional `embedding-similarity` line to `## Revealed vs stated`
  (`contracts/user-model.md` D8(iii)) — similarity of recent interaction
  summaries to the five axis descriptions.

## Why its own contract (not a `derived-index.md` addition)

`derived-index.md` covers `index.json` + `stats.json`, both of which every
consumer of the store already depends on unconditionally. This artifact
has its own writer cadence (re-embed only on `content_hash` change, not on
every filing pass), its own size profile (a vector per person, not a
handful of scalar fields), and — critically — its own optionality:
`index.json`/`stats.json` consumers must never be forced to understand or
gracefully degrade around an embeddings file that may simply not exist.
Splitting it out keeps `derived-index.md` consumers ignorant of embeddings
entirely.

## Versioning

Additive fields (a new optional key on each JSONL line) are a
`schema_version` minor bump — existing lines without the new key remain
valid, same convention as `ranking-weights.md`. Changing an existing
field's type or meaning, or changing the locality/optionality rules above,
is a major bump.

## Notes

- Regenerable: deleting `embeddings.jsonl` and re-running `embed-people.sh`
  reproduces it fully from `people/`/`interactions/` content, same
  disposability posture as `ranking-weights.json`.
- Never committed to this repo — user-owned state under the user's private
  `data/store/index/`; only anonymized fixtures exercise this contract
  under `packages/core/fixtures/`.

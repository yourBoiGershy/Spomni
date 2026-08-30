# Spec: embeddings

Status: spec (plan 30 unit 5). Package: ingestion (sole writer of
`<store>/index/embeddings.jsonl` per `contracts/embeddings-index.md`). This
spec is the model of record for the four Phase 3 scripts it defines
(`embed-people.sh`, `nearest-confirmed.sh`, `cluster-people.sh`,
`rescale-scores.sh` — the last of which is specced separately in
`rescale.md`), precise enough that a checker can recompute a fixture's
JSONL, nearest-neighbor list, cluster assignment, and axis-similarity JSON
by hand.

## Locality + optionality (binding)

Embeddings run **only** via a local Ollama instance — never a cloud
embeddings API. Anthropic offers no embedding model of its own; the
available managed alternative, Voyage AI, is a cloud API, and sending
person data (names, facts, interaction summaries) there would violate
*other people's data stays local* (`CLAUDE.md` standing principle;
`contracts/embeddings-index.md` "Locality rule"). No consumer of this spec
may add a cloud embedding fallback, ever, regardless of local availability.

Every script in this spec degrades identically when embeddings are
unavailable: it exits **0**, prints the single stdout line

```
embeddings: unavailable
```

and writes nothing — no partial JSONL, no partial output file, no store
mutation of any kind. "Unavailable" means either the Ollama availability
probe (below) fails, or, for `nearest-confirmed.sh` / `cluster-people.sh`,
`<store>/index/embeddings.jsonl` does not exist.

## Resolution

- `OLLAMA_URL` — default `http://localhost:11434`.
- `EMBED_MODEL` — default `nomic-embed-text`.
- `EMBED_CMD` — test/fixture override hook. When set, every script invokes
  it in place of the Ollama HTTP calls below, as:

  ```
  $EMBED_CMD <model>
  ```

  with the text to embed piped to its stdin, and it must print a JSON
  array of numbers (the vector) on stdout, e.g. `[0.0123, -0.0456, ...]`.
  This is the exact shim contract fixtures use to inject deterministic
  vectors — no network call, no Ollama process, is made when `EMBED_CMD`
  is set. A shim exiting non-zero or printing invalid JSON is treated as
  `embeddings: unavailable` for that call (which propagates to the whole
  run, per the "never partial" rule above).

**Availability probe** (skipped when `EMBED_CMD` is set — the shim being
present is itself the availability signal):

```bash
curl -s -m 2 "$OLLAMA_URL/api/tags"
```

A non-zero curl exit or non-2xx response means unavailable.

**Embedding request.** Try the legacy single-prompt endpoint first, fall
back once to the newer batch endpoint on failure:

1. `POST $OLLAMA_URL/api/embeddings`, body `{"model": "<m>", "prompt": "<text>"}`
   → response `{"embedding": [..]}`.
2. On failure (non-2xx, or a `.embedding` field missing/null), fall back to
   `POST $OLLAMA_URL/api/embed`, body `{"model": "<m>", "input": "<text>"}`
   → response `{"embeddings": [[..]]}` — the vector is `.embeddings[0]`.

If both fail, the run is `embeddings: unavailable` (never a partial write).
All HTTP calls use `curl` + `jq` from bash 3.2 — no Python, no other
runtime, matching the rest of ingestion's scripts.

## `embed-people.sh <store>`

**Content per person** — the exact text that gets embedded and hashed, in
this order, joined with newlines:

1. `people/<slug>.md` frontmatter lines `name`, `org`, `role`, `tags`,
   `how-met` (in that order, each on its own line as `key: value`; a
   missing field is simply omitted, not written as empty).
2. `people/<slug>.md`'s body sections, verbatim, in file order.
3. The filed interaction summaries linking `[[slug]]`, drawn from
   `interactions/*.md`: one line per interaction, `<date> <title> — <summary
   line>`, **newest first**, capped at the most recent **20**.

`content_hash` = `sha256` (via `shasum -a 256`) of that exact joined text —
byte-for-byte, including the newline joins. Re-embedding for a slug happens
**only** when the freshly-assembled content's hash differs from the
`content_hash` already stored for that slug in `embeddings.jsonl`; an
unchanged hash reuses the existing line as-is (no re-embed call, no
`embedded_at` bump).

**Slug lifecycle:** a slug present in `embeddings.jsonl` with no matching
`people/<slug>.md` file is dropped from the output on the next run (the
line is not carried forward) — this is the artifact's regenerable,
never-source-of-truth posture (`contracts/embeddings-index.md`).

**Output line fields**, per `contracts/embeddings-index.md`'s shape:
`slug, model, dims, vector, embedded_at, content_hash`. `dims` = `len(vector)`
exactly.

**Write discipline:** the whole file is rewritten atomically — write to a
temp file, then `mv` over `<store>/index/embeddings.jsonl` — never
line-appended in place. Lines are sorted by `slug` ascending in the
written file, regardless of processing order.

## Cosine similarity (jq)

Defined once, reused by every script below that needs it:

```
cosine(a, b) = dot(a, b) / (|a| * |b|)
```

where `dot(a, b) = Σ a[i]*b[i]`, `|a| = sqrt(Σ a[i]^2)`. For output and for
tie comparisons, cosine values are **rounded to 4 decimals**
(`(x * 10000 | round) / 10000` in jq). Two vectors of unequal length (a
`dims` mismatch) are never compared — the pair is skipped rather than
padded or truncated.

## `nearest-confirmed.sh <store> <slug> [--k 3]`

Default mode: nearest people to `<slug>` among **confirmed** candidates —
people whose `index.json` entry has `kind_source: stated-by-user` (the
`index.json` columns plan 30 unit 6 adds), excluding `<slug>` itself.

Output, one line per result, tab-separated:

```
<slug>\t<kind>\t<tier|->\t<cos>
```

`<tier|->` is the person's confirmed tier, or literal `-` if untiered.
Sorted by `<cos>` **descending**, ties broken by `<slug>` **ascending**;
truncated to the top `k` (default 3). If `<slug>` has no embeddings line,
or no candidate has a matching `dims`, or the candidate set is empty after
the `kind_source` filter, the script prints `embeddings: unavailable` and
exits 0 (same degrade path — an inconclusive neighbor search is treated
identically to an absent embeddings file, since the judgment's `neighbors:`
breakdown segment is omitted either way, per `contracts/
embeddings-index.md`'s optionality rule).

**`--axis-similarity <store>` mode** (mutually exclusive with the default
mode; no `<slug>` argument). Embeds the five fixed axis descriptions, one
sentence each:

```
business: work relationships — colleagues, clients, partners, deals, hiring
friends: real social relationships — people the user socializes with by choice
family: relatives and family-equivalent relationships
community: group or scene contacts — shared activity, not individual closeness
transactional: vendor or service relationships — no personal relationship rhythm
```

For each axis, compute the mean cosine similarity between that axis's
vector and the vectors of every person with at least one interaction in
the trailing 90 days (relative to the run's current time), restricted to
people whose `dims` matches the axis vectors' `dims` (a mismatch across
the whole set means `embeddings: unavailable`, since axis and person
vectors must come from the same model to be comparable at all). Output is
a single JSON object on stdout:

```json
{"business": 0.41, "friends": 0.33, "family": 0.29, "community": 0.18, "transactional": 0.22, "model": "nomic-embed-text"}
```

Each axis value is the mean of that axis's per-person cosines, rounded to
4 decimals, same as the default mode.

## `cluster-people.sh <store> [--threshold 0.80] [--scope <slug list file>]`

Greedy threshold clustering, a **prompt-batching heuristic only** — its
output is never written to the store, never persisted between runs, and
carries no identity across invocations (re-running with the same inputs
reproduces the same clusters, but nothing treats a `c001` id as durable).

**Algorithm**, over the slug set (all embedded slugs, or the slugs listed
one-per-line in `--scope`'s file when given), iterated in **slug
ascending** order:

1. Maintain a list of clusters, each with an ordered member list and a
   current exemplar.
2. For the next slug in order: compute its cosine similarity to every
   existing cluster's current exemplar. If any cosine is `>= threshold`,
   the slug joins the **first** such cluster (in cluster-creation order —
   the first cluster whose exemplar clears the threshold, not the
   highest-scoring one). Otherwise the slug starts a new cluster, becoming
   its sole member and initial exemplar.
3. **After all slugs are assigned**, recompute each cluster's exemplar:
   the member with the highest degree, where a member's degree is the
   count of other members in the *same* cluster whose cosine to it is
   `>= threshold`. Ties in degree are broken by `slug` ascending. This
   final exemplar recomputation happens once, after assignment is
   complete — it does not re-trigger reassignment of any member.

**Output**, one line per `(cluster, member)` pair, tab-separated:

```
<cluster-id>\t<slug>\t<exemplar:yes|no>
```

Cluster ids are `c001`, `c002`, … assigned in cluster-creation order (the
order clusters were first created during step 2, not sorted by size or
id-recomputed after the exemplar pass). Output rows are sorted by cluster
id ascending, then exemplar-member first (`yes` before `no`), then `slug`
ascending within each cluster.

If embeddings are unavailable (probe fails, JSONL absent, or the `--scope`
slug set has no matching embeddings), the script prints `embeddings:
unavailable` and exits 0, writing nothing.

## Deterministic checkability

With `EMBED_CMD` pointed at a fixture shim returning fixed vectors for
fixed input text, every artifact in this spec is byte-reproducible by a
checker working by hand:

1. **The JSONL** — for a fixture `people/`/`interactions/` set, the exact
   assembled content string per slug (frontmatter fields in order, body,
   then up to 20 newest-first interaction summary lines), its `sha256`
   `content_hash`, and the resulting sorted-by-slug JSONL lines.
2. **Re-embed minimality** — running `embed-people.sh` twice in a row with
   unchanged fixtures re-embeds nothing (every `content_hash` matches, so
   every `embedded_at` stays unchanged); editing one `person.md` and
   re-running re-embeds only that slug's line (all other lines, including
   their `embedded_at` values, are byte-identical to before).
3. **The nearest list** — for a fixture embeddings JSONL and a fixture
   `index.json` (with `kind_source` columns), the exact candidate set
   after the `stated-by-user` filter, each candidate's cosine to the query
   slug rounded to 4 decimals, the sort order, and the top-`k` cut.
4. **The cluster table** — for a fixture embeddings JSONL and a threshold,
   the exact cluster assignment produced by the ordered greedy pass
   (§ Algorithm step 2), the exemplar recomputation (step 3), and the
   final sorted output rows including cluster ids.
5. **The axis JSON** — given fixture vectors for the five axis sentences
   and a fixture set of people with trailing-90-day interactions, the
   exact per-axis mean cosine (rounded to 4 decimals) and the final JSON
   object's keys and values.

## Out of scope

- What the relationship-scoring judgment does with the `neighbors:`
  breakdown segment once produced by `nearest-confirmed.sh` — the
  judgment's use of priors is `contracts/relationship-scoring.md`'s
  concern (`## Priors`, `## Breakdown string`), consumed as-is here.
- `packages/attention`'s read-only use of `embeddings.jsonl` for drift
  neighbor priors — `contracts/embeddings-index.md` "Readers", unowned by
  this spec.
- `derive-user-model.sh`'s optional `embedding-similarity` revealed-behavior
  line (`contracts/user-model.md` D8(iii)) — a separate consumer of the
  same axis-similarity primitive, specced where `derive-user-model.sh` is
  specced, not here.
- The `index.json` `kind_source` / tier columns plan 30 unit 6 adds —
  consumed as-is by `nearest-confirmed.sh`'s default mode, not defined
  here.
- Ollama installation/model-pull instructions — `docs/SETUP.md`'s concern,
  not this spec's.

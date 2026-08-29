# Plan 08: Chat MCP & query data layer

Status: Ready
Package: query (MCP server) + core (derived-index contract, stats generator, fixtures)
Depends-on: 01 (hard); 03's index.json regeneration and 05/06's attention artifacts are
consumed opportunistically — do not block on them

## Supersedes

This plan absorbs and supersedes **plan 07's query-skill half (unit 2,
`packages/query/skills/query/SKILL.md`)**: the MCP tool surface below is the query
answer path. Plan 07 keeps the brief skill, nudge-card rendering, and output adapters
unchanged. Update the roadmap accordingly when this plan is scheduled.

## Objective

Make the store queryable at 500–1000 people without grep-and-read-everything: a derived
stats layer (flat, regenerable JSON) that turns "who works where / when did I last speak
to X / how many touchpoints / who should I reach out to" into O(1)-ish lookups, exposed
through a real MCP server in `packages/query/` — stdio today for local Claude Code,
streamable HTTP behind a flag for the later remote stream. Read-only, source-citing,
never inventing.

## Context

Read docs/PROJECT-CONTEXT.md first. Decisions that bind this plan:

- **markdown-store-plus-index** — no DB, no embeddings; derived artifacts are flat
  regenerable JSON. SQLite/local embeddings remain the named escape hatch ONLY if query
  quality degrades; this plan notes the bolt-on point (the store-reader module, unit 6)
  and builds none of it.
- **Single-writer rule** — query is READ-ONLY: it writes nothing into the store, ever.
  Generator scripts live in core; ingestion writes index.json (and now stats.json) into
  the store at runtime. Ranking is owned by `attention`: `suggest_reachouts` reads
  attention's outputs when present and falls back to a transparent read-only heuristic
  (staleness × tier × open threads) when absent — it must not grow a competing ranking
  engine.
- **Contracts frozen at 1.0.0** — person.md / interaction.md / wakeup.md field names are
  authoritative. The new derived-index format is a contract *addition* in core
  (`derived-index.md`), with core's package version bumped (minor).
- **provenance-labeling** — `get_person` returns Facts/Personal-details bullets with
  their `**[told-by-user]**` / `**[inferred-public-web]**` tags verbatim, never
  stripped or merged.
- **code-data-separation** — fixtures only, synthetic people; the real store stays in
  the user's private `data/`.

Decisions THIS plan makes (each needs a docs/DECISIONS.md entry, recorded by the
orchestrator when the plan executes):

1. **mcp-stack: TypeScript with the official `@modelcontextprotocol/sdk`, run zero-build
   via Node ≥22 native type-stripping.** Rationale: the TS SDK is the reference
   implementation with first-class stdio + streamable-HTTP transports, every Claude Code
   user already has Node installed (no second runtime), and `gray-matter` handles the
   store's frontmatter cleanly; handlers are plain functions, trivially testable against
   the fixture store.
2. **staleness-cache: query never regenerates into the store.** The server detects
   staleness cheaply (index/stats `generated_at` + mtime vs. newest mtime under
   `people/` and `interactions/`); when stale it shells out to core's generator scripts
   writing to a cache dir OUTSIDE the store
   (`${RA_CACHE_DIR:-$HOME/.cache/relationship-agent}/derived/`) and reads from there.
   Store copies of index.json/stats.json remain ingestion's to write. Every tool result
   carries `generated_at` so answers are honest about freshness.

### Derived-data design (binding for units 1, 4, 6)

`stats.json` — sibling of index.json, same directory, one artifact (the interactions
index is embedded per person; at 1000 people × ~20 interactions this is single-digit MB,
loaded once and held in memory by the server):

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

- `last_interaction` is COMPUTED from `interactions/*.md` dates (not the person's
  manually-maintained `last-touch` field); `interactions` is sorted newest-first.
- `tier` is projected here (index.json v1 lacks it) so the fallback heuristic never
  needs to open person files. index.json v1 is untouched — existing consumers keep
  working.
- Every person in `people/` appears, including those with zero interactions
  (`touchpoints: 0`, nulls, empty list).

### MCP tool surface (binding for units 7–9)

Six tools, all read-only, all citing `source` file paths, none ever inventing a person
or fact. No-match returns an explicit empty result plus nearest-neighbor suggestions
from the index (same honesty rule as plan 07's brief). Size discipline: search pages
default 25 (max 50) slim records; interaction lists page default 10 with summaries
excerpted to ~300 chars; full bodies only via the single-item tools; no tool result
exceeds ~20 KB.

1. `search_people(tags?, org?, role?, location?, tier?, text?, page?)` — index+stats
   filter/free-text over frontmatter fields; slim records + total count.
2. `get_person(slug)` — full frontmatter + the three body sections with provenance tags
   intact, plus the stats rollup; cites `people/<slug>.md`.
3. `list_interactions(slug, page?)` — newest-first: id, date, co-participants,
   summary excerpt; cites each `interactions/<id>.md`.
4. `get_interaction(id)` — full Summary + Commitments for one interaction.
5. `get_contact_stats(slug)` — the stats.json rollup: last contact (computed), count,
   dates, calendar-vs-not split, median gap.
6. `suggest_reachouts(limit?)` — if attention artifacts (pending wake-ups / fired batch,
   per wakeup@1) exist, surface those, labeled `source: attention`. Otherwise the
   fallback heuristic, labeled `source: heuristic-fallback`, returning the score
   BREAKDOWN per suggestion (days-stale, tier weight, open-thread count) so the ranking
   is transparent and auditable, never a bare opaque score.

### Performance envelope (binding for unit 12)

At a generated 1000-person / ~10k-interaction store: `build-stats.sh` full regeneration
< 5 s; warm tool latency p95 < 200 ms (get_person < 100 ms); server startup (load
index + stats into memory) < 1 s.

## Deliverables

- `packages/core/contracts/derived-index.md` — codifies index.json 1.0.0 (as built) and
  specifies stats.json 1.0.0 per the shape above; names writers (ingestion at runtime,
  query's cache copy exempted per the staleness-cache decision) and readers.
- `packages/core/scripts/build-stats.sh` — bash 3.2 + jq, emits stats.json; same CLI
  conventions as build-index.sh.
- `packages/core/fixtures/store/` enlarged from 15 → 30 personas with denser interaction
  histories (pagination and heuristic tests need volume) — still passing
  `validate-store.sh`.
- `packages/core/scripts/gen-scale-store.sh` — generates an UNCOMMITTED synthetic
  1000-person store into a temp dir for perf runs.
- `packages/query/server/` — the MCP server: entry point, stdio transport (default),
  streamable HTTP behind `--http` (transport module isolated so the remote-infra stream
  swaps it without touching tools), tool registry, store-reader + staleness/cache
  module, the six tool handlers.
- `packages/query/tests/` — golden tests per tool against the 30-persona fixtures,
  read-only enforcement test, perf harness.
- `packages/query/package.md` updated: provides the MCP tool surface; consumes
  `person@^1`, `interaction@^1`, `wakeup@^1`, `index.json@^1`, `stats.json@^1`,
  attention artifacts (optional). `packages/core/package.md` minor version bump for the
  contract addition.
- Two docs/DECISIONS.md entries (mcp-stack, staleness-cache) — orchestrator-recorded.

## Work units

Wave A (parallel, one message):
1. [worker] `packages/core/contracts/derived-index.md` per the design above +
   `packages/core/package.md` minor bump.
2. [worker] Fixture enlargement to 30 personas (varied tiers, a zero-interaction person,
   multi-person interactions, open threads/commitments in volume) +
   `gen-scale-store.sh`.
3. [worker] Query scaffold: package layout, `package.json` (MCP SDK, gray-matter),
   zero-build entry point, stdio transport live + `--http` flag stub, empty tool
   registry; `packages/query/package.md` update.

Wave B (parallel, after A):
4. [worker] `packages/core/scripts/build-stats.sh` per the contract.
5. [worker] build-stats tests: golden stats.json for the 30-persona fixtures, wired into
   `packages/core/tests/run-store-tests.sh`.
6. [worker] Store-reader + staleness/cache module in `packages/query/server/`: index/
   stats loaders (in-memory), person/interaction file readers with frontmatter parsing,
   mtime staleness check, cache-dir regeneration via core scripts. This module is the
   named SQLite bolt-on point — loaders sit behind one interface.

Wave C (parallel, after B):
7. [worker] Tools `search_people` + `get_person` (provenance tags verbatim, citations,
   no-match nearest-neighbors).
8. [worker] Tools `list_interactions` + `get_interaction` + `get_contact_stats`
   (pagination, excerpt caps).
9. [worker] Tool `suggest_reachouts`: attention-artifact probe (graceful absence) +
   fallback heuristic with per-suggestion score breakdown and source labeling.

Wave D (parallel, after C):
10. [worker] Golden tests for units 7–8's five tools against the 30-persona fixtures
    (including pagination edges, the zero-interaction person, no-match behavior).
11. [worker] Golden tests for `suggest_reachouts` in both modes (fixture wake-ups
    present / absent) + read-only enforcement test: hash the fixture store, exercise
    every tool, assert byte-identical store and no non-cache writes.
12. [worker] Perf harness: gen-scale-store, time stats regeneration and warm tool
    latencies, assert the envelope above; report numbers, not just pass/fail.

Wave E:
13. [checker] Consistency pass: derived-index.md vs. build-stats.sh vs. server loaders
    vs. goldens agree on every field name; provenance tags survive get_person; the
    registered tool list contains zero write-capable tools; report mismatches file:line.
14. [worker] Fix pass from unit 13's findings (skip if clean).

## Interfaces

Consumes: `person@1`, `interaction@1`, `wakeup@1` contracts + index.json + fixtures
(01); runtime index/stats regeneration by ingestion (03, opportunistic); wake-up queue /
fired-batch artifacts (05/06, opportunistic — absence is a tested path, not an error).
Produces: `stats.json@1` contract (attention's heuristics and plan 07's brief can read
it); the MCP tool surface (plan 07's brief skill and the future remote stream call it);
the cache-dir convention; the transport seam the remote-infra stream builds on.

## Proof of done

- All six tools pass their golden tests against the 30-persona fixture store; every
  answer cites source file paths; no-match cases return empty + neighbors, never an
  invented person.
- Read-only test: fixture store byte-identical after exercising every tool; the only
  writes land under the cache dir.
- Staleness test: touching a fixture person file causes the next tool call to serve
  from a freshly regenerated cache copy — store copies of index/stats untouched.
- Perf envelope met on the generated 1000-person store (stats regen < 5 s, warm p95
  < 200 ms, startup < 1 s), numbers recorded in the run output.
- `suggest_reachouts` demonstrably prefers attention artifacts when present and shows
  its full score breakdown when falling back.
- `run-store-tests.sh` still passes with the enlarged fixtures; both DECISIONS.md
  entries recorded.

## Out of scope

- SQLite / local embeddings (escape-hatch only; bolt-on point documented at unit 6).
- Transport/tunneling for phone/remote access — separate infrastructure stream; this
  plan only keeps the transport swappable.
- Briefs, nudge-card rendering, output adapters — remain plan 07.
- Any ranking engine beyond the labeled fallback heuristic — attention (plans 05/06)
  owns ranking.
- Write tools of any kind (permanently).

Status: Ready

# Plan 38 — Retrieval speed: bounded, measured, per surface

**Status:** proposed 2026-08-30 (baseline measured) · **Branch:** chunk-38-retrieval-speed
**Workstream:** 4 (Retrieval speed & answers) · **Depends on:** 35 (done); 36 B only for
the live dedup'd store, not for any unit here · **Unblocks:** 07 brief (inherits a store
budget), 09 cold-start bench (consumes the same harness)

**Mission test (§1).** Cuts *starting* and *deciding-who*: an answer that takes a
minute is an answer the user stops asking for, and then the running cost lands back on
them. Nearest ingredient: none — pure cost. Nothing here drafts, sends, ranks by
engagement, or changes what an answer says; it only changes how long the answer takes
and how many steps it costs.

## 1. Baseline (measured 2026-08-30, laptop, private store 127 people / 356 interactions)

Scratch copy of the real store, mtimes preserved, `/usr/bin/time`, best of two.

| Surface | Condition | Measured | Where the time goes |
|---|---|---|---|
| `build-index.sh` | full | **3.8 s** | ~5 `jq`/`sed` spawns per person × 127 |
| `build-stats.sh` | full | 0.11 s | already single-pass |
| `validate-store.sh` | full | **15.4 s** | same per-file spawn pattern; runs at every filing step (debrief §step 2) |
| `who-next-direct.sh` | index + stats fresh | **3.7 s** | 5 `jq` spawns per person even when the index is present |
| `who-next-direct.sh` | index missing | 7.7 s | rebuild (3.8 s) + the above |
| MCP server cold start → `initialize` | index/stats fresh | 0.18 s | node boot + read |
| MCP server cold start → `initialize` | anything under `people/` newer than index | **4.2 s** | blocking `build-index.sh` regen into `~/.cache/spomni` |
| MCP tools warm (`search_people`, `get_person`, `suggest_reachouts`, `upcoming_meetings`, …) | any | ≤ 2 ms | in-memory |
| `/who-next` skill, MCP path | per question | **≤ 22 tool round-trips** (search_people ×1–2, then `get_person` per candidate ≤ 20) | each round-trip is a model turn — the wall clock the user actually feels |
| `/who-next` skill, direct path | per question | 1 bash call (3.7 s) + 1 judging turn | facts arrive inline |
| Phone/cloud bootstrap → first answer | cold | 1 m 27 s (2026-08-30, `npm ci` + boot) | **owned by plan 09** (cold-start bench ≤ 15 s cloud / ≤ 5 s warm); 38 supplies the harness, not the fix |
| Pre-meeting brief | — | not built (07) | 38 sets its store budget; 07 builds to it |

Two conclusions the targets rest on: (a) the data layer is fast and the bash scripts
are slow for one mechanical reason (process-per-person); (b) the user-visible latency
on the MCP path is turn count, not I/O.

## 2. Targets (per surface; regression-guarded after this plan)

| Surface | Target @ 127 people | Target @ 1 000 people (`gen-scale-store.sh`) |
|---|---|---|
| `build-index.sh` | ≤ 0.3 s | ≤ 2 s |
| `validate-store.sh` | ≤ 1.5 s | ≤ 8 s |
| `who-next-direct.sh`, index fresh | ≤ 0.5 s | ≤ 2 s |
| `who-next-direct.sh`, index missing | ≤ 1 s | ≤ 4 s |
| MCP cold start → `initialize`, **regardless of staleness** | ≤ 0.5 s | ≤ 1 s |
| MCP tools warm | p95 ≤ 200 ms (unchanged, plan 08) | unchanged |
| `/who-next` per question | **≤ 2 tool round-trips** before the judging turn | same |
| Brief (07) store portion | ≤ 2 tool round-trips (`get_person` + `upcoming_meetings`) | same |
| Index/stats freshness | `generated_at` ≥ newest `people/`/`interactions/` mtime after **every** writer, always | same |

Targets are ~10× the baseline where the fix is mechanical and are set with ≥ 2× headroom
over what the single-pass rewrite is expected to deliver, so CI variance doesn't flap.

## 3. Units

Packages: **core** (B1, B2, D1), **query** (A, C, F, G), **ingestion + attention**
(D2, call sites only). One warm worker per package; waves are parallel across packages.

### Wave 1 — measure and remove the per-process tax (independent, parallel)

- **A. Retrieval bench harness** (query). `packages/query/tests/bench-retrieval.sh
  <store-dir> [--json] [--scale N]` — times every row of the §1 table: the three core
  scripts, `who-next-direct.sh` fresh/missing, MCP cold start fresh/stale (touch one
  person file into a scratch copy), warm per-tool via the existing
  `perf-harness.mjs` client code (reuse, don't fork it). `--scale N` generates a
  `gen-scale-store.sh` store first. Prints a markdown table; `--json` for the guard.
  Never writes into the given store (scratch copy, mtimes preserved with `cp -p`).
- **B1. `build-index.sh` single-pass** (core). One `awk` over `people/*.md` emitting
  JSONL (frontmatter fields incl. tags as a JSON array), one `jq -s add | jq -S`.
  **Byte-identical output** against the current script on the fixture store, the
  who-next-direct fixture store, and a 1 000-person scale store (test asserts
  `cmp`). bash 3.2, no associative arrays.
- **B2. `validate-store.sh` single-pass** (core). Same technique; identical
  pass/fail verdicts and messages on the existing store-tests fixtures (good and
  every bad-fixture case). This is a filing-time win credited to workstream 1 as well.
- **C. `who-next-direct.sh` single-pass** (query). Replace the per-slug
  `extract_*`/`jq` loop with one awk pass over `people/*.md` producing per-slug
  facts/threads JSONL, then a single `jq` join against `index.json` + `stats.json`.
  `run-who-next-direct-tests.sh` already locks the output — it must pass unchanged.

### Wave 2 — freshness, non-blocking cold start, fewer turns (parallel)

- **D1. `reindex.sh` wrapper** (core). `packages/core/scripts/reindex.sh <store>
  [--quiet]` = `build-index.sh` + `build-stats.sh`, idempotent, exits non-zero if
  either fails. `derived-index.md` 1.1.0 (additive): "sole writer of both artifacts
  at filing time is `reindex.sh`, invoked by every script or skill that writes
  `people/` or `interactions/`; readers may regenerate into a cache but never into
  the store." Test: after `reindex.sh`, both `generated_at`s ≥ newest source mtime.
- **D2. Writer audit + call sites** (ingestion + attention + core scripts). Every
  writer ends with `reindex.sh` (or documents why not): `file-structured.sh`
  (replaces its lone `build-index.sh` call), `file-thread.sh` callers in the debrief /
  onboarding-seed / review-tiers skills, `person-set-kind.sh`, `person-set-tier.sh`,
  `calibrate.sh`, `feedback-parse.sh` where it touches `people/`, `event-confirm` /
  `signal-scan` where they write interactions. Shard mode keeps its one-reindex-at-end
  rule (plan 27) — the sharded batch calls `reindex.sh` once. Test (ingestion): run
  each writer on the fixture store, assert freshness per D1's check.
- **F. Non-blocking staleness in the MCP server** (query). `staleness.ts`: on a
  stale store copy, serve the store copy immediately with `stale: true` +
  `generated_at` in every response envelope (honest-freshness rule of
  `staleness-cache` is kept — the answer says it's stale) and kick the cache
  regeneration off asynchronously; the next call serves the fresh cache copy. Cold
  start ≤ 0.5 s regardless of staleness. Missing-both case (no store copy at all)
  still regenerates synchronously — after B1 that is < 0.5 s at 127 people anyway.
  `test-tools.mjs` gains the stale-served / fresh-after case.
- **G. One-call candidate pool** (query server + who-next skill). New tool
  `who_next_pool {mode, limit, today?}` returning exactly the JSON-lines shape
  `who-next-direct.sh` emits (facts, open threads, index + stats fields inline) —
  the direct script and the tool are the same contract, so the skill judges one
  payload either way. `get_person` gains optional `include_interactions: N` (last N
  interactions inline) so the brief's store portion is one call. `who-next/SKILL.md`
  §2–3 amended: pool = one `who_next_pool` call, no per-candidate `get_person` loop;
  §0 fallback unchanged. Plan 07's brief inherits the 2-call budget in its §Interfaces.

### Wave 3 — guard, scale, live proof

- **H. Regression guard.** `run-perf.sh`/`perf-harness.mjs` targets extended with
  the §2 rows at 1 000 people (headroom as stated); `bench-retrieval.sh --json` on
  the fixture store wired into `scripts/test-all.sh` with the 127-row thresholds ×3
  for CI variance (time-based, plus a deterministic process-count check: `build-index.sh`
  and `who-next-direct.sh` spawn O(1) `jq`, asserted by counting via `-x` trace).
- **E. Incremental index update — conditional.** Only if B1 misses ≤ 2 s at 1 000
  people: `reindex.sh --only <slug>…` merges touched slugs into the existing
  `index.json`/`stats.json`. If B1 meets target, record the skip in this plan and
  in DECISIONS (`full-rebuild-is-cheap-enough`) rather than carrying the complexity.
- **Live proof (user session, private store).** Re-run `bench-retrieval.sh` on the
  real store before/after; one `/who-next all` on the MCP path with turn count and
  wall clock recorded; one on the direct path. Table goes in §5 below.

## 4. Splitting / dispatch

Wave 1: four dev-workers in one parallel message (A, C → query is two units by
file; B1, B2 → core is two units by file; the splitting rule allows two same-package
workers split by file). Wave 2: D1 (core, warm worker), D2 (ingestion, one worker;
attention call sites are 2 files — ride with it), F and G (query, two workers by
file: `store/staleness.ts` + tests vs `tools/` + skill). Wave 3: H (query warm
worker), E only if triggered. Each brief ≤ 3 min; each carries the §1/§2 rows it owns
and the current script excerpt it rewrites.

## 5. Proof of done

- Every §2 target met on the fixture store and the 1 000-person scale store in
  `test-all.sh` (green in CI); the before/after table for the private store recorded
  here.
- `derived-index.md` 1.1.0 merged; every writer in D2's audit list calls `reindex.sh`;
  freshness test green.
- `/who-next` on the MCP path answers after ≤ 2 tool calls; `who-next-direct.sh` and
  `who_next_pool` are output-equivalent on the fixture store (test).
- Byte-identical `index.json` and identical `validate-store.sh` verdicts before and
  after B1/B2 (tests).

Live table (fill on proof): _pending_.

## 6. Out of scope

- Cloud/phone bootstrap time (`npm ci`, node presence) — plan 09.
- Any change to ranking, judgment, or answer content — plan 30/34/36 territory.
- Embeddings/vector retrieval speed (`embed-people.sh`, Ollama) — not on any
  user-facing read path today.
- The brief skill itself — plan 07 (it inherits the 2-call budget from G).

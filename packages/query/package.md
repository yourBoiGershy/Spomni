# package: query

version: 0.1.0

## Purpose

The read-only answer surface — effectively this project's MCP: natural-language
questions over the store ("who do I know in fintech in NYC?") and pre-meeting briefs
(store facts + fresh public research, provenance-separated). Query writes nothing; it
reads the index and files and cites its sources. Later it can be exposed as a literal
MCP server so any agent can ask it questions — the skill contracts are designed so that
wrapping them is mechanical.

## Provides

- Skills: `skills/query/` (index-first retrieval, citations, honest "no match"),
  `skills/brief/` (one-page pre-meeting brief)
- `skills/who-next/` (`/who-next [friends|coffee|all] [--limit N]`) — condensed,
  action-first "who should I reach out to" answer, hand-judged from each
  person's facts rather than trusting raw `suggest_reachouts` order; renders
  per `packages/core/contracts/answer-style.md` 1.0.0; read-only, drafts on
  request only, never sends.
- `scripts/who-next-direct.sh` (`<store-dir> [--mode friends|coffee|all]
  [--limit N] [--today YYYY-MM-DD]`) — zero-dependency (bash + jq) read path
  for `/who-next` used when the `spomni-query` MCP server is unavailable
  (cold cloud/phone session), reading `index.json`/`stats.json`/`people/*.md`
  directly and emitting a pre-filtered, pre-ranked JSON-lines candidate
  pool; read-only, never writes to the store (generates `index.json`/
  `stats.json` into a scratch copy if either is missing).
- The nudge-card render consumed by output adapters
- `server/` (`packages/query/server/`): an MCP tool surface, seven read-only tools over
  stdio (streamable HTTP behind `--http`, stubbed): `search_people`, `get_person`,
  `list_interactions`, `get_interaction`, `get_contact_stats`, `suggest_reachouts`,
  `upcoming_meetings`. Entry point `server/src/index.ts` (run via `node
  --experimental-strip-types`, `--store` flag), transport seam, store-reader, and all
  seven tool handlers are in place and tested (`tests/test-tools.mjs` and
  `tests/test-upcoming-meetings.mjs`). Registered project-wide via the repo root
  `.mcp.json`, which defaults `--store` to `data/store` — the convention every checkout
  points at its own private store through (see `docs/chat-setup.md`). If the store's
  `index.json`/`stats.json` are missing or stale, the server regenerates them into
  `${SPOMNI_CACHE_DIR:-~/.cache/spomni}` (RA_CACHE_DIR honored as a deprecated
  fallback) and serves from there; the store itself
  is never written to (single-writer holds). Smoke test: `tests/smoke-live.sh`.

- `tests/bench-retrieval.sh <store-dir> [--json] [--scale N] [--runs K]` —
  read-only retrieval-speed benchmark (docs/plans/2026-08-30-38-retrieval-speed.md
  §1/§2 rows: `build-index.sh`/`build-stats.sh`/`validate-store.sh` full,
  `who-next-direct.sh` fresh/missing, MCP cold start fresh/stale, warm
  per-tool latency) on a scratch copy of the given store, never writing to
  it; `tests/bench-mcp-client.mjs` is its JSON-RPC-over-stdio timing helper.
  Smoke test: `tests/run-bench-smoke-tests.sh`.
- Eval suite: `evals/` — `eval-case@1` cases (`packages/core/contracts/
  eval-case.md`) under `evals/cases/`, manifest at `evals/suite.txt`. T2
  (`tier: agent`) cases against `packages/core/scripts/eval-run.sh`:
  `most-overdue`, `interpretability`, `opt-out-respected` [xfail: plan-13],
  `stated-outranks-revealed` [xfail: plan-13], `draft-never-send-read-only`.
  The last two personalization-overlay cases run against a materialized
  fixture directory (`evals/fixtures/overlaid-store/`, gitignored, built by
  `evals/fixtures/build-overlaid-store.sh` from `packages/core/fixtures/
  store` + `tests/fixtures/personalization-overlay/`) since the eval-case
  contract's `store` field takes exactly one path and has no overlay
  concept — see `evals/cases/opt-out-respected/README.md` for the full
  rationale.

## Consumes

- `person@^1`, `interaction@^1`, `wakeup@^1` (core)
- `index.json@^1`, `stats.json@^1` (ingestion; stats.json is the derived-index addition
  from plan 08)
- Fired-batch artifact (attention), `upcoming-briefworthy.json` (ingestion)
- Attention artifacts (pending wake-ups / fired batch) — optional, read opportunistically
  by `suggest_reachouts`; their absence is a tested path, not an error

## Owned paths

`packages/query/**`. Runtime: reads everything, writes nothing.

## Built by

Plan 07 (query + brief halves). Plan 08
(docs/plans/2026-08-29-08-chat-mcp-query-layer.md) — the MCP server (`server/`) and the
`stats.json@1` contract it consumes. Plan 18
(docs/plans/2026-08-29-18-query-live-wiring.md) — live wiring: the root `.mcp.json`
registration, `data/store` targeting, and `tests/smoke-live.sh`.

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
- The nudge-card render consumed by output adapters
- **In progress: scaffold only** — `server/` (`packages/query/server/`): an MCP tool
  surface, six read-only tools over stdio (streamable HTTP behind `--http`, stubbed):
  `search_people`, `get_person`, `list_interactions`, `get_interaction`,
  `get_contact_stats`, `suggest_reachouts`. Entry point, transport seam, and empty tool
  registry are in place; store-reader and tool handlers land in later waves.

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
`stats.json@1` contract it consumes.

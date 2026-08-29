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

## Consumes

- `person@^1`, `interaction@^1` (core), `index.json` (ingestion)
- Fired-batch artifact (attention), `upcoming-briefworthy.json` (ingestion)

## Owned paths

`packages/query/**`. Runtime: reads everything, writes nothing.

## Built by

Plan 07 (query + brief halves).

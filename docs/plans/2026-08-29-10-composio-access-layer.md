# Plan 10: Composio access layer (the pipes)
(Numbered 08 during development — renumbered at merge; chat-MCP holds 08.)
Status: Done (2026-08-29 — proof of done met live: gmail 15 events, calendar 4, linkedin 1; re-runs produced zero duplicates; 44-assertion test suite green)
Package: connectors/composio-in (shared input tooling at connectors root)
Depends-on: 01 only

## Objective
Stand up broad read access to the user's own accounts through one aggregator — the
user's Composio account — and land everything as raw capture events in `inbox/`.
Breadth over depth: as many data points as possible through as few connector setups as
possible. Structuring/filing is explicitly deferred to later chunks; this chunk only
guarantees access + lossless raw capture.

## Context
Read docs/PROJECT-CONTEXT.md first. Decisions that bind this plan:
- **composio-hub** (supersedes first-party-mcp-only) — access via the Composio CLI
  (`composio execute <TOOL_SLUG> -d '{...}'`), not MCP registration; the user's account
  is already linked for `gmail`, `googlecalendar`, `linkedin` (all verified ACTIVE with
  live reads on 2026-08-29). Large tool outputs are written by the CLI to a temp JSON
  file (`storedInFile: true` + `outputFilePath`) — sweeps must handle both inline and
  file-backed results.
- **tos-clean-signals-only** — stands. The LinkedIn toolkit is the official member API:
  own profile, posts, share statistics, network-size count. No connections list, no
  messages, no notifications — documented limits, not bugs.
- **code-data-separation** — `inbox/` lives in the private data dir (`data/store`);
  connector checkpoints/ledgers are connector-local, never in the shared store
  (per core's connector-interface contract).
- **draft-never-send** — this package is read-only against every account; no send
  tooling, ever.

## Deliverables
- `docs/data-layout.md` — `data/store` conventions: `inbox/`, `inbox/quarantine/`,
  `archive/raw/`, per-connector checkpoint/ledger locations
- `packages/connectors/scripts/normalize-capture.sh` — stdin/file → validated capture
  event per capture-event@1; invalid → `quarantine/` + reason file; never deletes
- `packages/connectors/composio-in/package.md` — sub-package manifest
- Sweep skills (each pulls via `composio execute`, dedups via a local ledger, pipes
  through the normalizer):
  - `packages/connectors/composio-in/skills/gmail-sweep/SKILL.md`
  - `packages/connectors/composio-in/skills/calendar-sweep/SKILL.md`
  - `packages/connectors/composio-in/skills/linkedin-sweep/SKILL.md`
- `packages/connectors/composio-in/fixtures/` — sample raw payloads per lane
- `packages/connectors/tests/run-capture-tests.sh` — normalizer + fixture tests,
  mirroring core's run-store-tests.sh conventions

## Work units
Wave A (parallel):
1. [worker] `docs/data-layout.md` — store layout + checkpoint conventions.
2. [worker] `packages/connectors/scripts/normalize-capture.sh` — bash-3.2, positional
   `<store-dir>` arg like core's scripts.
3. [worker] `packages/connectors/composio-in/package.md` + fixture pack (2 emails,
   1 calendar event, 1 LinkedIn item, 1 malformed junk).

Wave B (after A, parallel):
4. [worker] gmail-sweep skill — new-mail pull + one-shot contacts seed (Gmail
   toolkit's People tools), ledger keyed on Gmail message ID; minimal typing
   (`voice-note` for subject-tagged self-emails, else `other`).
5. [worker] calendar-sweep skill — past N / upcoming M days, participant-hints from
   attendees, ledger keyed on event id + updated timestamp.
6. [worker] linkedin-sweep skill — profile, posts + share stats, network-size
   snapshot; documents the API's hard limits loudly.
7. [checker] Dry-run the fixtures through the documented flows; verify contract
   conformance, quarantine behavior, idempotency; report mismatches.

Wave C (after B):
8. [worker] `packages/connectors/tests/run-capture-tests.sh` against the fixture pack.

## Interfaces
Consumes: capture-event@^1, connector-interface@^1 (core); the user's Composio CLI
session (`composio login` done out-of-band).
Produces: raw capture events in `inbox/` for every lane (Plan 03 files them; Plan 05
reads signal-bearing ones); the quarantine convention; per-lane ledgers (connector-local).

## Proof of done
Each sweep run live against the linked account lands valid capture events in
`data/store/inbox/`; running any sweep twice produces no duplicates; the malformed
fixture is quarantined with a reason, never lost; the test suite passes.

## Out of scope
- Filing/structuring (Plan 03), signals (Plan 05)
- iMessage/texts — no aggregator lane exists; later local chat.db bridge
- WhatsApp; LinkedIn archive-zip importer (fallback if the API lane proves too thin)
- Any outbound/send tooling

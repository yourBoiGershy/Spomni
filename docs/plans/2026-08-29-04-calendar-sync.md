# Plan 04: Calendar connector & attendee matching (the timeline)
Status: Ready
Package: connectors/calendar-in (dumb pull) + ingestion (matching layer)
Depends-on: 01 only

## Objective
Wire read-only access to the user's multiple Google calendars and build the attendee↔person matching layer. The calendar becomes the connective tissue: it timestamps interactions (met-at), predicts them (will-meet-at), reveals co-attendance, and drives the debrief prompts — the system never asks the user to initiate data entry, only to respond to real events.

## Context
Read docs/PROJECT-CONTEXT.md first. Decisions that bind this plan:
- **Multiple Google calendars** — work + personal, merged into one event view.
- **First-party MCP only** — Google Calendar via the Claude connector or Google's official Calendar MCP server; read-only scope.
- **Capture optional and lossy-tolerant** — un-debriefed meetings are tracked, surfaced once, then dropped silently; no backlog.
- **Never silently guess** — ambiguous attendee matches become questions or `unknown-attendee` records, never wrong links.

This plan spans two packages, split per dumb-edges-smart-middle: the connector half
only pulls and normalizes; every judgment (matching, linking, tracking) is ingestion's.

## Deliverables
- `packages/connectors/calendar-in/skills/calendar-pull/SKILL.md` — dumb pull: events
  (past N days + upcoming M days) across configured calendars → normalized event
  artifacts; no matching, no interpretation
- `packages/ingestion/skills/calendar-reconcile/SKILL.md` — the smart half: reconcile
  event artifacts against the store
- Matching rules: attendee email → person frontmatter email (exact), else name similarity + interaction history (candidate list, never auto-link below threshold)
- Unknown-attendee flow: propose person creation with event context pre-filled
- Event-link maintenance: `met-at`, `will-meet-at`, `same-event-as` links on interactions/people
- Un-debriefed tracker + brief-worthy-upcoming detector (both feed Plan 06's sweep)
- `packages/connectors/calendar-in/fixtures/` — synthetic week of events wired to the fixture personas

## Work units
Wave A (parallel):
1. [worker] `packages/connectors/calendar-in/fixtures/` — ~15 synthetic events over one week: 1:1s with known personas, a multi-attendee event, an event with one unknown attendee, an all-day conference both user and a persona attend, a solo event (no matching needed).
2. [worker] Calendar config convention (`docs/data-layout.md` addition): which calendars, lookback/lookahead windows, ignore rules (solo events, declined events, all-hands over N attendees). Connector-half scope: ignore rules apply at pull time, mechanically.
3. [worker] Matching-rules spec section of `calendar-reconcile` (ingestion): exact-email match, candidate scoring for name-only, the threshold below which it asks.

Wave B (after A):
4a. [worker] `packages/connectors/calendar-in/skills/calendar-pull/SKILL.md` — pull → filter per config → emit normalized event artifacts. Nothing else.
4b. [worker] `packages/ingestion/skills/calendar-reconcile/SKILL.md` core: read event artifacts → match → write/update event links → emit un-debriefed list + upcoming-briefworthy list as JSON artifacts for the sweep.
5. [worker] Unknown-attendee flow + co-attendance detection in `calendar-reconcile` (same event id on user + tracked person → `same-event-as` signal event for Plan 05).
6. [checker] Run pull + reconcile against `packages/connectors/calendar-in/fixtures/` + fixture personas; verify the matching matrix (expected link per event), confirm the unknown attendee surfaced as a question, confirm the solo/all-hands events were ignored, and confirm the connector half wrote no store files (single-writer rule).

## Interfaces
Consumes: person contract + index (01).
Produces: normalized event artifacts (connector half); event↔person links (03 uses for context, 05 for co-attendance); `un-debriefed.json` and `upcoming-briefworthy.json` artifacts (06 consumes); the calendar config convention.

## Proof of done
Against the synthetic week: every expected match made, the unknown attendee raised as a question not a guess, ignore rules honored. Against a real week of the user's calendars: ≥80% of meetings with tracked people auto-matched; every non-match surfaced, none silently linked.

## Out of scope
- Writing to any calendar (read-only forever in v1)
- Non-Google calendar providers
- Event-platform APIs (Luma etc. arrive as emails via Plan 02)
- Auto-generating briefs (Plan 07) or scheduling sweeps (Plan 06)

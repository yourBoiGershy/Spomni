# Plan 11: Composio import standard (one shape for every lane)
Status: Done (2026-08-29 — both suites green: store 20/20, capture 69/69; conformance checker 7/7 after one collateral repair. Caveat: Gmail To/Cc and calendar organizer/creator payload field names are flagged in the sweep skills as not yet live-verified — confirm on the next live sweep.)
Package: core (contract bump) + connectors (sweeps, normalizer, fixtures, tests)
Depends-on: 01, 10

## Objective
Standardize how data imported through Composio becomes capture events, so every
lane — current (gmail, googlecalendar, linkedin) and future toolkits — lands in
`inbox/` in one predictable shape the filing engine (Plan 03) can organize.
Plan 10 achieved breadth (raw capture works, live-verified); this plan fixes the
conceptual gaps the real data exposed.

## What the real data showed (2026-08-29, 20 live events)
1. **Typing is nominal.** All 20 events are `type: other` — the enum
   (`voice-note`, `linkedin-notification`, `event-confirmation`, `transcript`,
   `other`) describes hoped-for content, not what Composio lanes actually
   deliver (ordinary emails, calendar event records, profile snapshots).
2. **Transport leakage.** The linkedin lane archived the Composio CLI wrapper
   (`{"successful": true, "data": {...}}`) as the body. The wrapper is
   transport, not source material — it must never enter the archive.
3. **Time semantics violated.** Calendar events use the event *start* time as
   `captured_at` (files dated 2026-09-07 captured on 2026-08-29). The contract
   defines `captured_at` as capture time; event time had nowhere to live.
4. **`source` drift.** Sweeps wrote toolkit slugs (`gmail`, `googlecalendar`,
   `linkedin`); the contract's convention is the writing connector's name
   (`gmail-in`-style). Neither identifies both the connector and the lane.
5. **Participant hints are uneven.** Gmail captures sender only (no To/Cc);
   calendar captures nobody despite attendees being the core relationship
   signal; linkedin captures nobody.

## The standard (capture-event 1.0.0 → 1.1.0, additive minor bump)

### Envelope
- **`source` = `<connector>/<lane>`** — `composio-in/gmail`,
  `composio-in/googlecalendar`, `composio-in/linkedin`. The connector half is
  the writing sub-package; the lane half is the Composio toolkit slug. Plain
  connector names (`manual`, `gmail-in`) stay valid — `source` remains a free
  string; this is a convention, not an enum.
- **`type` enum widened** (additive): `email`, `calendar-event`,
  `profile-snapshot`, `contact-record`, `post` join the existing five.
  Existing values keep their meanings (`event-confirmation` = a confirmation
  *email*; `calendar-event` = the event record itself). `other` remains the
  escape hatch, now meaning "genuinely unclassifiable", not "default".
- **New optional `occurred_at`** (ISO 8601): when the underlying thing
  happened or will happen — calendar event start, email Date header, post
  publish time. `captured_at` is strictly when the sweep ran; the `id` (and
  filename) derive from `captured_at`, keeping `inbox/` chronological by
  capture.

### Per-lane mapping
| Lane | `type` | `occurred_at` | `participant-hints` | body |
|---|---|---|---|---|
| gmail | `email` (`voice-note` for subject-tagged self-emails; `linkedin-notification` for LinkedIn notification mail) | Date header | From, To, Cc — `"Name <email>"` form as seen | `Subject:` line, blank line, rendered message text (current convention) |
| googlecalendar | `calendar-event` | event start | organizer, creator, every attendee | the provider event resource as pretty-printed JSON |
| linkedin | `profile-snapshot` / `post` | snapshot: none; post: publish time | none (it is the user's own profile) | the provider resource as pretty-printed JSON |
| (gmail People seed) | `contact-record` | none | the contact's names + emails | the provider contact resource as pretty-printed JSON |
| beeper (`beeper-in/<network>`, e.g. `beeper-in/whatsapp`, `beeper-in/imessage`) | `chat-message` (1.2.0) | message sent time | sender + other chat participants, display form as seen | the message content; Beeper API envelope stripped, original to `archive/raw/` |

### Body + transport rule
The body is the **provider resource** (Gmail message, Calendar event, LinkedIn
resource) — never the Composio CLI wrapper. Sweeps unwrap `data` (inline or
`outputFilePath`-backed) before normalizing. Where the body is a transformation
of the CLI output (unwrapping, pretty-printing), the untouched CLI output goes
to `archive/raw/<capture-id>.json` per `docs/data-layout.md` — that is the
provenance trail; the body stays reproducible from it.

### Noise
Capture-everything stands (append-only, lossy-tolerant applies to *missed*
capture, not filtering). Machine-generated mail (Google security notices) and
holiday-calendar events are captured and typed like anything else; triage is
the filing engine's job (Plan 03), not the sweeps'. A `noise` flag was
considered and deferred — classification belongs to one place, and that place
is ingestion.

### Migration
None required. Existing 1.0.0 events stay valid as written (readers accept
both minors); ledgers already dedup on source IDs, so re-sweeping will not
re-capture them. The filing engine must not assume `occurred_at` exists.

## Work units
Wave A (parallel, one worker per module):
1. [worker] `packages/core/contracts/capture-event.md` → 1.1.0: widened enum,
   `occurred_at`, `source` convention, updated example + notes.
2. [worker] `packages/connectors/scripts/normalize-capture.sh`: accept new
   enum values, optional `--occurred-at` (validated ISO 8601 when present,
   emitted in frontmatter), unchanged behavior otherwise.
3. [worker] gmail-sweep + calendar-sweep SKILL.md: per-lane mapping above
   (typing rules, occurred_at, full participant extraction, source form,
   captured_at = sweep time).
4. [worker] linkedin-sweep SKILL.md (transport unwrap, typing, source form) +
   `composio-in/package.md` (consumes capture-event@^1.1) + fixtures updated
   to the new shape.

Wave B (after A):
5. [worker] `packages/connectors/tests/run-capture-tests.sh`: cover new types,
   `occurred_at` pass-through, rejection of malformed `occurred_at`.
6. [checker] Conformance pass: every fixture + SKILL.md example matches the
   1.1.0 contract and the per-lane table; report mismatches.

## Proof of done
Both suites green (`run-store-tests.sh`, `run-capture-tests.sh`); no fixture
or skill example carries a Composio wrapper, a toolkit-slug-only `source`, or
an event-time `captured_at`; a checker confirms the per-lane table and the
shipped skills agree.

## Out of scope
- Filing/organizing `inbox/` into people/interactions — that is Plan 03,
  unchanged and next.
- Re-writing the 20 existing 1.0.0 events (valid as-is; data op, not code).
- New lanes/toolkits (the standard now tells them where to land).

## Addendum (2026-08-29): 1.2.0 — chat lanes
The Beeper personal-chat bridge (DECISIONS `beeper-personal-bridge`, researched in
the messaging-connectors plan on `stream-connectors`) fits the standard as-is
except for typing: chat messages had no enum value and would regress to `other`.
Bump 1.1.0 → 1.2.0 adds `chat-message`; chat lanes follow the existing
`<connector>/<lane>` source form (`beeper-in/<network>`) and the transport rule
(Beeper API envelope stripped, original archived). The `beeper-in` connector
itself is `stream-connectors` territory, not this plan's.

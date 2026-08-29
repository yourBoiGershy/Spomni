---
schema_version: 1.1.0
id: 2026-08-30-owen-marsh
due: 2026-08-30
people: ["[[owen-marsh]]"]
why: "tier drift: 5 touchpoints in the last quarter, well above dormant-tier cadence — reach out or reclassify?"
status: pending
origin: signal
source-signal: 20260829T090000Z-tier-drift-owen-marsh
fired-on:
dismiss-reason:
acted-on:
snooze-count: 0
---

## Context

Owen Marsh is tagged `tier: dormant` in `people/owen-marsh.md`, but
`interactions/` shows 5 filed touchpoints in the trailing quarter
(2026-06-02, 2026-06-20, 2026-07-10, 2026-08-01, 2026-08-25) — a median gap
far tighter than dormant-tier contact cadence implies. This is a proposal,
not a tier write: per the guardrail (inner-circle-gone-quiet is a nudge to
reach out or reclassify, never an automatic demotion — the same principle
applies in reverse here), the detector surfaces a wake-up rather than editing
`person.md#tier` directly. If the user confirms, ingestion is the one that
files the tier change into `people/owen-marsh.md`; declining leaves the
`dormant` tag untouched and drops the proposal silently (see the
`declined-proposal` sibling fixture).

Suggested reclassification: `dormant` → `active` (one tier step, matching
this fixture set's assumed one-step-per-proposal rule — see this directory's
README for the exact drift threshold assumed).

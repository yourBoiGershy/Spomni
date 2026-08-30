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

Owen Marsh's `kind: professional` (stated-by-user, not expired) clears the
kind-horizon prefilter's UPWARD side: 5 touchpoints in the trailing 90 days
is non-trivially elevated for a person tagged `tier: dormant`, so the
candidate reaches the judgment pass (`specs/tier-drift.md` "## Prefilter" /
"### UPWARD drift prefilter"). The judgment reads the evidence — 5 filed
touchpoints (2026-06-02, 2026-06-20, 2026-07-10, 2026-08-01, 2026-08-25), a
median gap far tighter than `dormant`-tier cadence implies for a
professional-kind relationship — and (with no confirmed `user-model.md` on
file, so no user-model priors are read) verdicts UPWARD drift. This is a
proposal, not a tier write: per the guardrail (inner-circle-gone-quiet is a
nudge to reach out or reclassify, never an automatic demotion — the same
principle applies in reverse here), the detector surfaces a wake-up rather
than editing `person.md#tier` directly. If the user confirms, ingestion is
the one that files the tier change into `people/owen-marsh.md`; declining
leaves the `dormant` tag untouched and drops the proposal silently (see the
`declined-proposal` sibling fixture).

Suggested reclassification: `dormant` → `active` (one tier step per the
judgment's `suggested_tier`).

Breakdown (`packages/core/contracts/relationship-scoring.md` "## Breakdown
string"):

```
warrant: 78 | kind: professional (stated-by-user) — Regional Sales Director contact; occasional webinar collaboration | evidence: touchpoints=5 median_gap_days=14 days_since_last=4 meetings=0 chat_days=0 participation=0.6 | priors: user-model: none | rationale: 5 touchpoints in the trailing 90 days at a median 14-day gap is well inside the professional 120-day horizon and elevated for a dormant tag; kind=professional with no user-model priors keeps warrant moderate. | suggested: active
```

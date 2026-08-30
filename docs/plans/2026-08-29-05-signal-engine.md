# Plan 05: Signal engine (the scout)
Status: Done (2026-08-29, chunk-05-signal-engine — all 6 units; Wave B checker PASS, 0 findings; scan is a skill verified by hand against fixtures/signals — no deterministic scan script, T3 eval cases flip on with plan 06's sweep)
Package: attention (detection/ranking half; queue/sweeps are Plan 06, same package)
Depends-on: 01, 02 (04 soft — co-attendance signals need it)

## Objective
Build the engine that finds reasons to reach out: it runs the ToS-clean signal set on each sweep, emits signal events, ranks them, and converts the winners into wake-up entries carrying ammunition (what you know + the evidence + optionally a draft). Signals are proposals; the ranking layer is what keeps this from becoming an alert firehose.

## Context
**Amended by Plan 21** (docs/plans/2026-08-29-21-calendar-intelligence.md):
the detector set gains `scheduling-intent` (spec ships at
`packages/attention/specs/scheduling-intent.md`; signal-scan assembly
includes it in detector order). Timing rule addition: scheduling intent is
time-sensitive — promoted proposals are due within 1–2 days, not the
+2–3-week job-change pattern.

**Amended by Plan 12** (docs/plans/2026-08-29-12-cadence-capacity.md):
capacity tier becomes a ranking INPUT, not an output. The fixed ~5-nudge cap
becomes a capacity-derived daily/weekly budget (busy → 1–2/week, normal →
2–3, open → 3–5), read from `signals/week-plan.json` per
`packages/core/contracts/week-plan.md`. Tie-strength preference inverts with
capacity: busy weeks rank strong/frequent ties up; open weeks rank
dormant/weak ties with the longest silence up, and reactivation drafts are
allowed.

Read docs/PROJECT-CONTEXT.md first. Decisions that bind this plan:
- **ToS-clean signals only** — no scraping, no enrichment APIs, no RSS bridges; LinkedIn data only via emails LinkedIn itself sends the user.
- **Wake-up queue over digests** — ranked signals become dated queue entries, nothing else.
- **Nudge-quality rules** — cap ~5 active nudges; two independent signals for high priority; prefer signals the crowd doesn't see, or late timing on ones it does; every nudge carries trigger + ammunition, never bare cadence.
- **Provenance labeling** — signal evidence is inferred-from-web/email, labeled as such.

## Deliverables
- `packages/attention/skills/signal-scan/SKILL.md` — runs all detectors, emits signal events, ranks, writes wake-ups
- Detectors (each a section of the skill with its own rules):
  - birthdays: Google Contacts (People API via first-party connector) + person frontmatter
  - job changes: `linkedin-notification` capture events + email-signature diffing + web-search verification
  - company news: web search per top-N contacts' companies + SEC EDGAR full-text for raises
  - co-attendance: `same-event-as` links from Plan 04
  - posts: belled-contact `linkedin-notification` events
  - debrief harvesting: `needs-follow-up` facts Plan 03 marks
  - **Amended by Plan 21**: `scheduling-intent` — see the Context note above
- Ranking spec: warmth (tier + recency + interaction density) × rarity; the two-signal rule; the 5-nudge cap with overflow held, not dropped. **Amended by Plan 12**: capacity tier becomes a ranking input and the fixed cap becomes a capacity-derived budget — see the Context note above.
- `packages/attention/fixtures/signals/` — seeded signal scenarios wired to fixture personas

## Work units
Wave A (parallel):
1. [worker] Ranking spec + warmth definition (documented in the skill; deterministic enough that a checker can verify a ranking by hand). **Amended by Plan 12**: warmth's tie-strength preference now inverts with capacity tier, per the Context note above.
2. [worker] `packages/attention/fixtures/signals/` content: a birthday 5 days out, a LinkedIn job-change email, a co-attendance link, a funding-news search result, a low-warmth post event — each with expected rank and expected wake-up (or expected suppression).
3. [worker] Detector specs: birthdays + co-attendance + debrief harvesting (the cheap three).

Wave B (after A):
4. [worker] Detector specs: job changes (email parse + signature diff + search verify) and company news (search query templates, name-disambiguation rule: always name+company together).
5. [worker] `packages/attention/skills/signal-scan/SKILL.md` assembly: detector order, signal-event emission, ranking pass, wake-up creation with ammunition block, timing rules (job-change nudge dated +2–3 weeks, birthday dated day-before). **Amended by Plan 21**: include `scheduling-intent` in detector order and apply its 1–2-day timing rule, per the Context note above.
6. [checker] Run the scan against `packages/attention/fixtures/signals/`: verify each scenario produces the expected wake-up/suppression, the cap holds, the low-warmth post is suppressed, and every emitted wake-up has trigger + ammunition.

## Interfaces
Consumes: signal-event/wakeup contracts + index (01); typed `linkedin-notification`/`event-confirmation` events (02); `same-event-as` links (04); `needs-follow-up` markers (03).
Produces: ranked wake-up entries with ammunition — the queue content Plan 06 fires and Plan 07 renders; the snooze/dismiss feedback fields the scheduler writes back.

## Proof of done
Seeded fixtures (birthday, job-change email, co-attendance) produce correct wake-ups with correct dates and ammunition; zero bare "it's been N days" entries; the 6th-ranked nudge is held, not delivered; dismissing a fixture nudge lowers that signal type's rank for that person on the next scan.

## Out of scope
- Scraper/enrichment/RSS-based detection (permanently, per decision)
- Sales-Navigator-style intent signals
- Cadence-based "keep in touch every N months" reminders (user can create these manually as wake-ups; the engine never invents them)
- Delivery/rendering (06/07)

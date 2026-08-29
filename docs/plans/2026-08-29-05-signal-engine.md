# Plan 05: Signal engine (the scout)
Status: Ready
Depends-on: 01, 02 (04 soft — co-attendance signals need it)

## Objective
Build the engine that finds reasons to reach out: it runs the ToS-clean signal set on each sweep, emits signal events, ranks them, and converts the winners into wake-up entries carrying ammunition (what you know + the evidence + optionally a draft). Signals are proposals; the ranking layer is what keeps this from becoming an alert firehose.

## Context
Read docs/PROJECT-CONTEXT.md first. Decisions that bind this plan:
- **ToS-clean signals only** — no scraping, no enrichment APIs, no RSS bridges; LinkedIn data only via emails LinkedIn itself sends the user.
- **Wake-up queue over digests** — ranked signals become dated queue entries, nothing else.
- **Nudge-quality rules** — cap ~5 active nudges; two independent signals for high priority; prefer signals the crowd doesn't see, or late timing on ones it does; every nudge carries trigger + ammunition, never bare cadence.
- **Provenance labeling** — signal evidence is inferred-from-web/email, labeled as such.

## Deliverables
- `.claude/skills/signal-scan/SKILL.md` — runs all detectors, emits signal events, ranks, writes wake-ups
- Detectors (each a section of the skill with its own rules):
  - birthdays: Google Contacts (People API via first-party connector) + person frontmatter
  - job changes: `linkedin-notification` capture events + email-signature diffing + web-search verification
  - company news: web search per top-N contacts' companies + SEC EDGAR full-text for raises
  - co-attendance: `same-event-as` links from Plan 04
  - posts: belled-contact `linkedin-notification` events
  - debrief harvesting: `needs-follow-up` facts Plan 03 marks
- Ranking spec: warmth (tier + recency + interaction density) × rarity; the two-signal rule; the 5-nudge cap with overflow held, not dropped
- `fixtures/signals/` — seeded signal scenarios wired to fixture personas

## Work units
Wave A (parallel):
1. [worker] Ranking spec + warmth definition (documented in the skill; deterministic enough that a checker can verify a ranking by hand).
2. [worker] `fixtures/signals/`: a birthday 5 days out, a LinkedIn job-change email, a co-attendance link, a funding-news search result, a low-warmth post event — each with expected rank and expected wake-up (or expected suppression).
3. [worker] Detector specs: birthdays + co-attendance + debrief harvesting (the cheap three).

Wave B (after A):
4. [worker] Detector specs: job changes (email parse + signature diff + search verify) and company news (search query templates, name-disambiguation rule: always name+company together).
5. [worker] `.claude/skills/signal-scan/SKILL.md` assembly: detector order, signal-event emission, ranking pass, wake-up creation with ammunition block, timing rules (job-change nudge dated +2–3 weeks, birthday dated day-before).
6. [checker] Run the scan against `fixtures/signals/`: verify each scenario produces the expected wake-up/suppression, the cap holds, the low-warmth post is suppressed, and every emitted wake-up has trigger + ammunition.

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

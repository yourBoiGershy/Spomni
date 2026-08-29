# Plan 03: Filing engine (the librarian)
Status: Done (2026-08-29, stream-filing — all 10 debrief goldens + 6 preference goldens PASS via check-golden.sh, zero fact loss; eval suite wired: 16 T3 cases runnable)
Package: ingestion
Depends-on: 01, 02

## Objective
Build the debrief skill that turns raw capture events into structured knowledge: person-file updates, interaction notes, extracted commitments, calendar links, and wake-up entries from explicit reminder asks. This is where "had coffee with Dana, she moved to Stripe, remind me to sync in a month" becomes three files and a queue entry.

## Context
Read docs/PROJECT-CONTEXT.md first. Decisions that bind this plan:
- **Capture optional and lossy-tolerant** — a two-word debrief is valid; at most ONE clarifying question per filing, and only for genuinely ambiguous high-value facts.
- **Provenance labeling** — facts from the user vs. inferred-from-web are never mixed; the research seed pass labels everything it adds.
- **Wake-up queue over digests** — reminder asks inside debriefs become `wakeup.md` entries, not special cases.
- **Raw always archived** — the original capture text is never destroyed by filing.

## Deliverables
- `packages/ingestion/skills/debrief/SKILL.md` — the filing flow (single event or batch from inbox)
- Filing rules: person matching (name + calendar-context disambiguation), new-person creation, multi-person events, commitment extraction, link maintenance (person↔person, person↔event, interaction↔people)
- Optional web-research seed pass for new people (public-web only, provenance-labeled)
- `packages/ingestion/fixtures/golden/` — 10 golden transcripts with expected output files
- `packages/ingestion/scripts/check-golden.sh` — diffs actual filing output against expected

## Work units
Wave A (parallel — goldens BEFORE the prompt, per project doctrine):
1. [worker] Golden transcripts 1–5 in `packages/ingestion/fixtures/golden/`: simple single-person, rambly multi-topic, multi-person meeting, embedded reminder ask, two-word minimal. Each = input event + expected person/interaction/wakeup files.
2. [worker] Golden transcripts 6–10: new unknown person, ambiguous name (two Sarahs), commitment made by user, commitment made by other party, contradicts-existing-fact (person changed jobs).
3. [worker] `packages/ingestion/scripts/check-golden.sh` — runs the comparison, reports per-golden PASS/FAIL with diffs; ignores timestamps.

Wave B (after A):
4. [worker] `packages/ingestion/skills/debrief/SKILL.md` core: event → matched person(s) via index + calendar context → updates/creates files per the contracts → archives raw → updates index.
5. [worker] Debrief skill extensions: commitment extraction rules, reminder-ask → wakeup entry (created via core's `wakeup-add.sh`, per the single-writer rule), the one-question rule (when to ask, when to file with a `needs-confirmation` marker instead).
6. [worker] New-person flow: create from template, optional research seed (web search on name+company only), provenance labels on every seeded fact.

Wave C:
7. [checker] Run all 10 goldens through the skill, report the PASS/FAIL matrix and any fact loss (facts present in input but absent from output).
8. [worker] Fix round from the checker's findings (max 2 rounds, then escalate per fix policy).

## Interfaces
Consumes: person/interaction/wakeup contracts, index generator, fixture personas (01); typed `voice-note` capture events (02); event↔attendee links (04, soft — filing works without calendar, better with it).
Produces: the populated store every downstream plan reads; the `needs-confirmation` marker convention; debrief-harvested facts that Plan 05 treats as a signal source.

## Proof of done
All 10 goldens pass; the fact-loss check reports zero facts dropped; a debrief containing "remind me to follow up in a month" produces a wakeup entry due in one month with the interaction linked as context.

## Out of scope
- Transcript ingestion from meeting recorders (later input type, same skill)
- Signal detection (05) and nudge rendering (07)
- Retroactive re-filing of old data

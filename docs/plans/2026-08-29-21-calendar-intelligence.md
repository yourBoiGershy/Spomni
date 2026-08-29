# Plan 21: Calendar intelligence & event proposals
Status: Ready
Package: attention (detector spec, proposal lifecycle, confirm skill, evals) + core (wakeup 1.2.0 event-proposal extension) + query (upcoming-meetings surface); amends plans 05 and 06
Depends-on: 01 (contracts/store), 03 (filed message interactions), 04 (filed calendar interactions); 17 soft (first-party Google Calendar connector — needed only for the live create at confirm time); integrates 05/06/12/15 — buildable standalone, with marked amendments

## Objective
The proactive layer's calendar half: read the calendar for context ("you're
seeing Sam Thursday"), turn scheduling language in messages ("we should grab
coffee") into a `scheduling-intent` signal, and surface an **event-proposal
card** in the wake-up queue carrying a ready-to-confirm event. Draft-never-send
extends to calendar writes: the agent proposes, the human confirms, the create
happens only after explicit confirmation — zero events ever created without it
(eval-guarded), and declining files silently.

## Context
Read docs/PROJECT-CONTEXT.md first. Decisions that bind this plan:
- **Draft, never send → propose, never create.** Every calendar write is
  confirm-first, no exceptions in v1 (the roadmap's "any event with other
  attendees is always confirm-first" is the floor; here it is the rule for
  all proposals). The guarded artifact is `created-event-id`: non-null only
  after a recorded human confirmation.
- **composio-retired** (DECISIONS.md) — the create at confirm time goes
  through the user's linked first-party Google Calendar connector (the
  claude.ai Google Calendar MCP connector; chunk 17's lanes). Connectors stay
  dumb: attention's skill drives the call; no credential or event data is
  stored outside the private data dir.
- **wakeup-queue-over-digests** — the proposal is a wake-up entry, same
  primitive, distinguished by a new `kind` field. Single-writer intact:
  creation via core's `wakeup-add.sh`; lifecycle writes (including
  confirm/decline) are attention's alone.
- **Signal-event open vocabulary** — `scheduling-intent` is a new `type`
  under signal-event 1.0.0; no schema bump there.
- **Plan 12 reconciliation** — the same filed calendar interactions plan 12's
  capacity model reads feed both the upcoming-meetings surface and slot
  selection. When `signals/week-plan.json` exists and is fresh, slot
  selection uses its free blocks; otherwise it computes free blocks itself
  with plan 12's parameters (working window 09:00–18:00). Standing doctrine
  honored: the proposal *card* never fires immediately before/after a
  meeting (06 amendment); explicit user asks are budget-exempt.
- **Plan 15 personalization** — profile `## Signal opt-outs` apply before
  ranking/promotion; a `scheduling-intent` opt-out (global or per-person)
  yields silence. Attention never writes `profile.md`.
- **Provenance labeling** — detector evidence is quoted message text,
  labeled inferred-from-message, never mixed with told-by-user facts.
- **Plans 05/06/12 are written but unbuilt.** This plan ships everything it
  needs (spec, fixtures, skills, scripts, evals) without a live signal
  engine, and records its integration points as marked "Amended by Plan 21"
  notes, following plan 12's amendment pattern.

**Amendments to unbuilt plans — whoever builds 05 or 06 must read this plan
first:**
- **Plan 05, Deliverables (detector list) + Wave B unit 5:** the detector set
  gains `scheduling-intent` (spec ships here as
  `packages/attention/specs/scheduling-intent.md`; 05's signal-scan assembly
  includes it in detector order). Timing rule addition: scheduling intent is
  time-sensitive — promoted proposals are due within 1–2 days, not the
  +2–3-week job-change pattern.
- **Plan 06, Deliverables (`wakeup-queue.sh`) + Wave A unit 1 and Wave B
  unit 4:** `wakeup-queue.sh` absorbs the `confirm`/`decline` ops from this
  plan's interim `packages/attention/scripts/proposal-confirm.sh` (which is
  then retired); the sweep's fire step renders `kind: event-proposal`
  entries as proposal cards (proposed event + confirm/decline affordance)
  and applies the meeting-adjacency check to their firing time.
- **Plan 07 (query + brief halves):** the brief skill gains an "Upcoming"
  section — next-7-days filed calendar interactions naming the brief's
  subject, cited, silent when empty (see the Query surface section).

## Wake-up contract 1.2.0 — event-proposal extension (the decisions, made here)
Additive minor bump 1.1.0 → 1.2.0, per the 1.0→1.1 precedent in
`packages/core/contracts/wakeup.md`'s Versioning note. New optional
frontmatter fields; every 1.1.0 file remains valid (missing `kind` = `nudge`):
- `kind` — enum `nudge` | `event-proposal`; default `nudge`.
- `proposed-event` — mapping, required non-null iff `kind: event-proposal`:
  `title` (string), `start`/`end` (ISO 8601 datetime with offset),
  `attendees` (list of `[[slug]]` links, ≥1 — store people, not raw emails;
  emails are resolved from `people/<slug>.md` at confirm time, and the skill
  asks the user if one is missing), `location` (string or null).
- `confirmed-on` — ISO date or null; set by attention when the human
  explicitly confirms.
- `created-event-id` — string or null; the connector's event id, set by
  attention only after the create succeeds. **Invariant (validator-checkable
  and eval-guarded): `created-event-id` non-null requires `confirmed-on`
  non-null and `kind: event-proposal`.**
- Decline = existing dismiss mechanics, unchanged enum (`not-now`,
  `already-handled`, `not-this-person` all sensible); no new dismiss-reason
  values. The dismissed wakeup itself is the record (tier-drift precedent):
  no retry, no new artifact. Re-proposal suppression: 30 days per
  (person, `signal-type: scheduling-intent`) pair after a dismissal.
- `wakeup-add.sh` gains optional flags: `--kind event-proposal`,
  `--event-title`, `--event-start`, `--event-end`, `--event-attendee <slug>`
  (repeatable), `--event-location`; validation requires
  title/start/end/≥1 attendee when kind is `event-proposal`, and rejects the
  event flags otherwise. `confirmed-on`/`created-event-id` are never settable
  at creation.

## Detector & slot selection (the decisions, made here)
Spec lands at `packages/attention/specs/scheduling-intent.md`, tier-drift.md
as the style exemplar. Pinned rules:
- **Input:** filed interactions ≤14 days old (stale intent expires); scan
  `## Summary` and `## Commitments` for scheduling language.
- **Confidence:** `high` = mutual/explicit with concrete activity and
  timeframe ("are you free for lunch next week?") or two independent
  mentions across interactions; `medium` = explicit one-sided proposal, no
  timeframe ("we should grab coffee"); `low` = vague nicety ("let's hang
  out sometime"). Low never promotes; medium/high promote subject to
  opt-outs and the suppression window. Every promotion first emits a
  `scheduling-intent` signal event (evidence = quoted line + source
  interaction id, labeled inferred-from-message).
- **Slot selection (deterministic):** free blocks from `week-plan.json` when
  present and fresh (plan 12 staleness rule), else computed from filed
  calendar interactions over the next 14 days, working window 09:00–18:00.
  Pick the earliest block fitting the duration plus a 15-minute buffer each
  side, at least 48h out (notice for the other party). Durations by intent
  class: call/catch-up 30m, coffee 60m, lunch 60m (window 11:30–13:30),
  dinner 90m (start 18:00–20:30). No qualifying slot within 14 days → signal
  event only, promotion held, one log line — nothing invented.
- **Origin:** message-derived intent → `origin: signal` +
  `source-signal`, subject to ranking caps/budgets once 05/12 run. An
  explicit in-session user ask ("set up coffee with Sam") → `origin:
  user-ask`, budget-exempt — but the create is still confirm-first.

## Query surface (the decision, made here)
A seventh read-only MCP tool, `upcoming_meetings({ days = 7 })`, in
`packages/query/server`, joining the six live tools: returns filed
interactions with `date` in [today, today+days] and non-null
`calendar-event` — date, one-line summary, calendar-event id, matched store
people (slug + display name from `people/`), citation paths; honest empty
result. The brief's "Upcoming" section (next 7 days of meetings involving
the brief's subject) is recorded as an "Amended by Plan 21" note on plan 07
— `packages/query/skills/brief/` does not exist yet (plan 07 unbuilt), so
the section ships with the brief skill itself. Matching is the filing
engine's (`people` frontmatter); the tool reports it, never re-matches.

## Deliverables
- `packages/core/contracts/wakeup.md` at 1.2.0 per the extension section
  above; registered in core's `package.md` provides.
- `packages/core/scripts/wakeup-add.sh` event-proposal flags + tests.
- `packages/attention/specs/scheduling-intent.md` — detector + slot
  selection + suppression + provenance, per the pinned rules.
- `packages/attention/scripts/proposal-confirm.sh` — deterministic
  confirm/decline lifecycle writes (interim; absorbed by 06's
  `wakeup-queue.sh`, see amendment) + tests.
- `packages/attention/skills/scheduling-intent/SKILL.md` (detect → signal
  event → proposal via `wakeup-add.sh`) and
  `packages/attention/skills/event-confirm/SKILL.md` (present card →
  explicit confirm → connector create → record; decline → dismiss silently;
  connector unavailable → proposal stays pending, loud log, no partial
  write).
- `packages/attention/tests/fixtures/scheduling-intent/` — goldens before
  skill prompts (plan 12 convention).
- Three eval cases under `packages/attention/evals/cases/` + suite entries.
- `upcoming_meetings` tool + node tests in `packages/query/server`;
  `package.md` updates in all three packages.
- Marked "Amended by Plan 21" notes in plans 05, 06, and 07 (07 carries the
  brief "Upcoming" section).

## Work units
Wave A (parallel):
1. [worker] `packages/core/contracts/wakeup.md` 1.1.0 → 1.2.0: the fields,
   invariant, decline/suppression semantics, and versioning note from the
   extension section above; updated example; register 1.2.0 in core's
   `package.md` provides.
2. [worker] `packages/attention/specs/scheduling-intent.md` — transcribe the
   pinned detector/confidence/slot/suppression rules into a tier-drift-style
   spec; include the origin split and opt-out gate (plan 15 touchpoint).
3. [worker] `packages/attention/tests/fixtures/scheduling-intent/` — three
   scenarios: `clear-intent` (coffee line + calendar with free slots →
   expected signal event + expected event-proposal wakeup with slot),
   `vague-intent` (low confidence → signal event only, no proposal),
   `declined-proposal` (dismissed scheduling proposal 10 days ago → total
   silence); each with expected artifacts.
4. [worker] Amendment edits to plans 05, 06, and 07 — marked "Amended by
   Plan 21" notes, no other restructuring. Plan 07's note: the brief skill
   gains an "Upcoming" section (next-7-days filed calendar interactions
   naming the subject, cited, silent when empty), per the Query surface
   section here.

Wave B (after A):
6. [worker] `wakeup-add.sh` event-proposal flags + validation per the
   extension section; Bash 3.2 portable.
7. [worker] Tests for the new `wakeup-add.sh` flags: valid proposal file
   matches the 1.2.0 example shape; event flags without
   `--kind event-proposal` rejected; missing title/start/attendee rejected;
   plain nudge creation unchanged.
8. [worker] `packages/attention/scripts/proposal-confirm.sh` — `confirm <id>
   --event-id <id>` writes `confirmed-on` + `created-event-id` + `acted-on:
   true`; `decline <id> --reason <enum>` dismisses; refuses non-proposal
   kinds and confirm-without-event-id; update attention's `package.md`
   (provides lifecycle addition, consumes wakeup@1.2).
9. [worker] Tests for `proposal-confirm.sh` against the Wave A fixtures,
   including the invariant (no `created-event-id` without `confirmed-on`)
   and decline leaving everything else byte-identical.
10. [worker] `packages/attention/skills/scheduling-intent/SKILL.md` —
    detect per spec → emit signal event → create proposal via
    `wakeup-add.sh`; opt-out and suppression gates; hold path when no slot.
11. [worker] `packages/attention/skills/event-confirm/SKILL.md` — render the
    card; require an explicit affirmative from the human before any
    connector call; create via the linked Google Calendar connector, then
    `proposal-confirm.sh confirm`; decline → `proposal-confirm.sh decline`,
    then silence; no-response → leave fired/pending, do nothing; connector
    absent (pre-17) → loud log, proposal untouched.
12. [worker] `upcoming_meetings` tool in `packages/query/server` per the
    Query surface section (handler + registry entry) + query `package.md`
    update.
13. [worker] Node tests for `upcoming_meetings`: window filtering, people
    join against the fixture store, empty-window result, citation paths.
13b. [worker] *(added at dispatch — gap found in Wave A review)*
    `packages/core/scripts/validate-store.sh` 1.2.0 support: accept
    `schema_version: 1.2.0` for wakeups; validate `kind` enum,
    `proposed-event` required-iff `kind: event-proposal` (with
    title/start/end/≥1 `[[slug]]` attendee), and the invariant
    (`created-event-id` ⇒ `confirmed-on` ∧ `kind: event-proposal`).
13c. [worker] *(added at dispatch)* Core test-suite extension —
    `packages/core/tests/test-wakeup-add.sh` (the unit-7 test content) plus
    1.2.0 validator fixtures (valid proposal; invalid
    created-without-confirmed; invalid proposal-without-proposed-event) and
    their `run-store-tests.sh` wiring; sole owner of `run-store-tests.sh`
    edits in this wave.

Wave C (after B):
14. [worker] Eval case `scheduling-intent-proposal` (T3, wraps
    `clear-intent` fixture): graders assert exactly one proposal with
    `kind: event-proposal`, slot inside a fixture free block, correct
    `[[slug]]` attendees, `created-event-id` null; add to `evals/suite.txt`.
15. [worker] Eval cases `zero-create-without-confirm` (prompt processes a
    fired proposal with no user confirmation → graders assert
    `created-event-id`/`confirmed-on` null everywhere, store otherwise
    byte-identical) and `decline-files-silently` (prompt carries the user's
    decline → dismissed with a valid reason, nothing else changes, no new
    files); suite entries. These pin the zero-creation and silent-decline
    guardrails as executable graders, tier-drift style.
16. [checker] End-to-end verification: run store/capture test suites and the
    new script tests; run `eval-suite.sh packages/attention/evals/suite.txt`
    (cases run or SKIP loudly, never silently); validate fixture proposals
    against wakeup 1.2.0; confirm plans 05/06/07 carry the amendment notes;
    confirm `upcoming_meetings` output matches fixture people; confirm the
    invariant appears in contract, script, skill, and eval.

## Interfaces
Consumes: filed message + calendar interactions (`interaction@1`, plans
03/04); `wakeup@1.2` + `wakeup-add.sh` (core); `signal-event@1` (open
vocabulary); `profile@1` opt-outs (plan 15); `week-plan.json` (plan 12
contract) opportunistically — absence is a tested path; the user's linked
first-party Google Calendar connector (chunk 17) at confirm time only.
Produces: wakeup 1.2.0 event-proposal contract; `scheduling-intent` signal
events + proposal cards for 06's fire path to render; the confirm/decline
lifecycle ops 06's `wakeup-queue.sh` absorbs; the `upcoming_meetings` tool
and brief section; the created calendar event — only ever after human
confirmation.

## Proof of done
On `clear-intent`: the scheduling-intent message produces a signal event and
exactly one event-proposal wake-up, golden-tested, with a slot inside a free
block and attendees correctly matched to store people. `upcoming_meetings`
shows fixture calendar context with correct store-people matching and
citations (the brief's Upcoming section ships with plan 07, per its
amendment note). The `zero-create-without-confirm` eval
passes: no run path yields a non-null `created-event-id` without a recorded
`confirmed-on`. The `decline-files-silently` eval passes: a decline leaves
only the dismissed wakeup as the record — no retry, no new artifacts.
`vague-intent` and `declined-proposal` fixtures produce the expected
hold/silence. Plans 05, 06, and 07 carry visible Plan 21 amendment notes. Live
connector create is verified manually after chunk 17's lanes land (post-ship
shakedown), not by automated eval.

## Out of scope
- Negotiating times with the other party over messages (drafts may mention
  the proposed slot; humans send)
- Multi-slot proposals / availability polling / external scheduling links
- Rescheduling, editing, or cancelling existing events
- Timezone/travel awareness (mirrors plan 12's exclusion)
- Recurring proposed events
- Building 05's ranking, 06's sweep, or 12's capacity themselves (this plan
  amends/consumes their specs; those plans build them)
- Automating the live Google Calendar create inside evals (manual, post-17)

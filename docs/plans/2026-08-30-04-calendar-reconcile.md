# Plan 04 — Calendar reconcile (matching audit, questions, sweep artifacts)

> **Consolidation 2026-08-30 — Later.** Not one of the five goals. **D5 ignore rules
> (units A2/A3) moved to plan 36 C3** and build there. **D7 / `upcoming-briefworthy.json`
> dropped** — the brief uses the `upcoming_meetings` query tool (plan 21). Remaining
> scope (D1–D4, D6, A1, A4, waves B–D) stays the v1 ≥ 80 % exit instrument, after the
> five goals.

**Status:** proposed 2026-08-30 · **Branch:** chunk-04-calendar-reconcile
**Supersedes:** `2026-08-29-04-calendar-sync.md` (written before chunks 17/21/26/31;
its connector half shipped as `calendar-sweep`, its matching core shipped as
`file-structured.sh`). This plan is the remainder.
**Mission test (§1):** cuts *remembering-to* (which meeting never got a debrief)
and *noticing* (who was at what). Nearest ingredient: trust — an ambiguous
attendee becomes a question, never a guessed link; nothing here drafts, sends,
scores engagement, or performs the relationship.

## What already exists (do not rebuild)

| Old plan-04 deliverable | Where it lives now |
|---|---|
| Dumb calendar pull, multi-calendar, lookback/lookahead | `connectors/calendar-in/skills/calendar-sweep` — past 30 d / next 60 d, capture-event 1.2.0 |
| Attendee email → person (exact), name exact-normalized, ambiguous → hold, unknown → new person or hold | `ingestion/scripts/file-structured.sh` per `specs/structured-filing.md` (plan 31), plus `identities.tsv` learned map |
| Self exclusion, ignore identities | `config/onboarding-backfill.tsv` `self`/`ignore` rows |
| Event link on the interaction | `interaction.md` `calendar-event:` field, written by `file-structured.sh` |
| Co-attendance detector | `attention/specs/co-attendance.md` + `signal-scan` (plan 05) |
| Un-debriefed once-then-drop mention | `attention/specs/undebriefed-mention.md` + sweep step 7 (plan 06), interim derivation |
| Upcoming meetings surface | `query` `upcoming_meetings` (plan 21) |

## Problems observed (2026-08-30 live store)

1. **No measurement.** The v1 exit criterion is "≥ 80 % of meetings with tracked
   people auto-matched, every non-match surfaced" and nothing computes it.
   `structured-held.log` has 10 rows, all `no-name:` — nobody sees them.
2. **Held events are dead ends.** A `no-name`/`ambiguous-name` hold is written to
   a log and never asked about. The old plan's "asks, never guesses" half is
   missing: there is no question surface and no way for an answer to unblock
   the event.
3. **The un-debriefed rule is silently dead.** `undebriefed-mention.md` step 4
   treats "an interaction with `calendar-event: <id>` exists" as "debriefed".
   Since plan 31, `file-structured.sh` files *every* calendar event as a template
   interaction, so every meeting looks debriefed and the sweep never mentions
   one. The spec anticipated `un-debriefed.json` replacing its steps 1–4; it
   needs a new definition of "debriefed" first.
4. **Link vocabulary drift.** `co-attendance.md` path 1 looks for a
   "same-event-as" marker in `## Summary` that nothing writes. The store already
   encodes co-attendance as *one* interaction with `calendar-event` non-null and
   ≥ 2 `people`; the marker is dead weight.
5. **Ignore rules are partial.** Solo events are skipped (zero non-self hints);
   declined-by-self events and large all-hands are not, so they file as
   touchpoints and inflate `last-touch`.

## Decisions (pinned here; spec restates them)

- **D1 — "debriefed" is defined by content, not existence.** A calendar-filed
  interaction is *un-debriefed* iff its `## Summary` still begins with the
  template `Calendar: "` line, `## Commitments` is `_none_`, and no *other*
  interaction dated within ±1 day names any of its `people` (a same-day chat or
  email counts as the debrief having happened, matching the old step 4's
  second clause). Deterministic, no model.
- **D2 — Questions, never fuzzy links.** No name-similarity auto-link is added.
  Every held event becomes a question record carrying up to 3 *candidates*
  (same first name in `people/`, same domain in `identities.tsv`, co-attendees'
  known colleagues) — candidates are presentation only; the only writers of a
  resolution are the user's answer. An answer is one of: `<slug>` (learn the
  email → `identities.tsv`), `new` (create person from the stated name), or
  `ignore` (append an `ignore` row). Then the held id is removed from
  `structured-held.log` and `file-structured.sh` re-files it.
- **D3 — Artifacts live in `<store>/signals/calendar/`, ingestion is sole
  writer.** Three JSON files, regenerated whole on every run (no ledger):
  `un-debriefed.json`, `upcoming-briefworthy.json`, `unmatched.json`. Attention
  and query consume; never write.
- **D4 — Match rate definition.** Over calendar-event captures in the window
  with ≥ 1 non-self, non-ignored attendee: `matched` = filed by
  `file-structured.sh` (id in `debrief-filed.log`); `held` = id in
  `structured-held.log`; `skipped` = ignored by rule (declined, over cap).
  Rate = matched / (matched + held). Skipped events are listed, not counted.
  Every held event is listed with its reason — "every non-match surfaced".
- **D5 — Ignore rules, applied in `file-structured.sh` before resolution.**
  Skip when the self attendee has `responseStatus: declined`, or when non-self
  attendee count > `calendar-max-attendees` (config row in
  `onboarding-backfill.tsv`, default 12 when absent). Skipped ids go to
  `structured-held.log` with reason `skipped-declined` / `skipped-large:<n>` so
  the report can list them and the debrief batch keeps excluding them.
- **D6 — Co-attendance filed path = one interaction.** `high` confidence iff a
  filed interaction has `calendar-event` non-null, ≥ 2 `people`, and is
  debriefed per D1; `medium` when it is still the template (attendance
  unconfirmed) — replacing the "same-event-as marker" path. `met-at` /
  `will-meet-at` / `same-event-as` as link names are retired: past vs. future
  is the interaction date; same-event is the shared `calendar-event` id.
- **D7 — Briefworthy is a shortlist for plan 07, not a nudge.** Upcoming =
  calendar-filed interactions dated in the next 7 days with ≥ 1 person whose
  `tier` is set (any value) or who has ≥ 1 `## Facts` bullet. Written to the
  artifact; no sweep entry, no card — the morning-of auto-brief stays in
  ROADMAP "Later".

## Units

Each ≤ 3 min; implementation and its tests are separate workers. Single-writer
holds: ingestion units touch only `packages/ingestion/`; attention units only
`packages/attention/`; core only the manifest line.

### Wave A (parallel)

- **A1 · spec** — `packages/ingestion/specs/calendar-reconcile.md`: D1–D5 and
  D7 restated as the model of record; the three artifact shapes (below);
  `import-triage.md` as the style exemplar.
- **A2 · ignore rules** — `file-structured.sh` D5 (declined self, attendee
  cap, new hold reasons, config row) + `structured-filing.md` amendment.
- **A3 · ignore-rule tests** — `run-structured-tests.sh` cases: declined
  skips, 13-attendee skips at default, 13 files with `calendar-max-attendees
  20`, both reasons land in `structured-held.log`.
- **A4 · fixture week** — `packages/ingestion/tests/fixtures/reconcile/`: a
  store with ~6 people and ~14 calendar captures over one week: 1:1s with
  known people (some already debriefed via a same-day chat interaction, some
  template-only), a 3-attendee meeting, one `no-name` hold, one
  `ambiguous-name` hold (two "Sam"s), a declined event, a 15-attendee all-hands,
  a solo block, two upcoming events (one with a tiered person, one with an
  untiered fact-less person). Expected artifacts checked in as goldens.

### Wave B (after A1; parallel)

- **B1 · `calendar-reconcile.sh <store>`** — read-only over `inbox/`,
  `people/`, `interactions/`, the three ledgers, `identities.tsv`; sole
  writer of `signals/calendar/*.json` (atomic tmp+mv). Prints one summary
  line: `reconcile: window=<a>..<b> matched=<n> held=<n> skipped=<n>
  rate=<0.xx> un-debriefed=<n> upcoming=<n>`.
- **B2 · `calendar-match-report.sh <store> [--days 30]`** — the exit-criterion
  instrument: D4 numbers plus a per-event table of every held/skipped event
  (date, title, reason, attendees). Reads `unmatched.json` when fresh, else
  derives. Exit 1 when rate < 0.80 so it can gate CI on the fixture week.
- **B3 · tests for B1+B2** — `run-reconcile-tests.sh` against the A4 fixture:
  artifact goldens byte-equal, rate = expected, held events all listed,
  skipped not counted, D1 debriefed/un-debriefed split correct.

### Wave C (after B1)

- **C1 · `skills/calendar-reconcile/SKILL.md`** (ingestion, session-driven,
  user-invoked) — runs B1, presents `unmatched.json` as a numbered list of
  questions with D2 candidates, applies answers (`identities.tsv` append,
  `ignore` row, new person via the existing `file-structured` path), drops the
  ids from `structured-held.log`, re-runs `file-structured.sh`, prints the
  new match rate. Silent when there are no questions. Symlink into
  `.claude/skills/`.
- **C2 · sweep switch** (attention) — `undebriefed-mention.md` "Later" path
  made real: step 7 reads `signals/calendar/un-debriefed.json` when present
  and fresh (< 36 h), else keeps the interim derivation *amended to D1* (the
  existence check is dead either way). Rule, timing gate, `mentioned.log`
  unchanged. Test case in `run-attention-tests.sh`.
- **C3 · co-attendance D6** (attention) — spec amendment + `signal-scan`
  filed-path change; existing test updated.
- **C4 · manifests + docs** — `ingestion/package.md` provides
  `calendar-artifacts 1.0.0` (the three shapes); `attention/package.md` and
  `query/package.md` consume it; `docs/SETUP.md` gains the
  `calendar-max-attendees` row; `docs/data-layout.md` gains
  `signals/calendar/`.

### Wave D — live proof (user session, no code)

Run `calendar-reconcile.sh` then `calendar-match-report.sh --days 30` on the
private store; record the rate and the held list in the completion note. If
< 80 %, run `/calendar-reconcile`, answer the questions, re-measure. Log the
before/after numbers in ROADMAP row 04.

## Artifact shapes (calendar-artifacts 1.0.0)

```json
// signals/calendar/un-debriefed.json
{ "generated_at": "2026-08-30T12:00:00Z", "window_days": 14,
  "meetings": [ { "event_id": "gcal-evt-7742", "date": "2026-08-25",
    "title": "Coffee with Sam", "people": ["sam-okafor"],
    "interaction": "interactions/2026-08-25-sam-okafor.md" } ] }

// signals/calendar/upcoming-briefworthy.json
{ "generated_at": "...", "window_days": 7,
  "meetings": [ { "event_id": "...", "start": "2026-09-02T14:00:00Z",
    "title": "...", "people": ["..."], "why": ["tier:close", "facts:3"] } ] }

// signals/calendar/unmatched.json
{ "generated_at": "...", "window_days": 30,
  "rate": 0.82, "matched": 41, "held": 9, "skipped": 6,
  "questions": [ { "event_id": "...", "date": "...", "title": "...",
    "reason": "no-name:j.doe@example.com", "email": "j.doe@example.com",
    "candidates": ["jane-doe", "john-doerr"] } ],
  "skipped_events": [ { "event_id": "...", "reason": "skipped-large:15" } ] }
```

`window_days` for un-debriefed is 14 to match the mention spec; the report's
default is 30 to match the sweep window.

## Interfaces

Consumes: capture-event 1.2.0 (`inbox/`), person 1.x, interaction 1.0.0,
`structured-filing.md` ledgers, `identities.tsv`, `onboarding-backfill.tsv`.
Produces: `calendar-artifacts 1.0.0` (three JSON files, ingestion-owned);
`structured-held.log` gains two reason values; `file-structured.sh` gains D5.
Amends: `undebriefed-mention.md` (D1), `co-attendance.md` (D6).

## Proof of done

Fixture week: rate computed exactly as expected; both holds appear as
questions with candidates; declined and all-hands skipped and listed, not
counted; D1 splits template-only from same-day-chat meetings; answering the
`no-name` question re-files the event and the rate rises. Live: 30-day report
≥ 80 % after one `/calendar-reconcile` pass, every non-match listed, zero
links written without an answer.

## Out of scope

- Fuzzy/name-similarity auto-linking (D2 — questions only).
- Any calendar write (plan 21 owns confirm-first creates).
- Morning-of auto-briefs (ROADMAP "Later"; D7 only produces the shortlist).
- Person dedup/merge — plan 36 B; a duplicate slug surfaced by a question is
  answered with the canonical slug, merging is 36's job.
- Backfilling `identities.tsv` beyond what answers teach.

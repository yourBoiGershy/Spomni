# Spec: debrief-harvest detector

Package: `attention` (plan 05 detector set). Signal `type`: `debrief-harvest`.
Writes only `wakeups/signals/<id>.md` (`signal-event@1`,
`packages/core/contracts/signal-event.md`) — never `people/` or
`interactions/` (those are `packages/ingestion`'s alone, single-writer rule,
`CLAUDE.md` Packages section). This detector never promotes directly; scoring
and the hold/suppress/promote decision belong to
`packages/attention/specs/ranking.md` and are cited here, not restated.

## Inputs

Per sweep, for every person in `people/`:

- **`needs-follow-up` markers** the filing engine (plan 03) places on
  interactions or people facts. The convention is declared but not yet
  exemplified with a fixed grammar in the repo; the two defining references
  are:
  - `packages/ingestion/package.md:48`: "Conventions: `needs-confirmation`
    and `needs-follow-up` markers, met-at / will-meet-at / same-event-as
    links".
  - `packages/attention/package.md:61`: "... `needs-follow-up` markers
    (ingestion)".
  This detector treats `needs-follow-up` as the follow-up-flagged sibling of
  the documented `needs-confirmation` convention (`packages/ingestion/skills/
  debrief/SKILL.md:216-221`), which marks a bullet by appending a
  comma-joined tag inside the same provenance bracket, e.g.
  `**[told-by-user, needs-confirmation]** <fact>`. A `needs-follow-up`
  marker is read the same way, wherever the filing engine places it (a
  `## Facts` bullet in `people/<slug>.md`, or a line in an interaction's
  `## Summary`): the tag `needs-follow-up` inside the bracket is the
  detection trigger, and the bullet/line text is the evidence.
- **`## Commitments` bullets** in `interactions/*.md`, form `<owner>: <what>
  [by <date>]`, owner `user` (`packages/core/contracts/interaction.md:40-45`):
  ```
  - user: check in on how the Berlin move went [by 2026-10-15]
  ```
  Only `user:`-owned commitments matter here — a `[[slug]]:`-owned
  commitment is the other person's promise, not the user's, and is out of
  scope (see Out of scope).
- **`## Open threads` bullets** in `people/<slug>.md`
  (`packages/core/contracts/person.md`'s `## Open threads` section) — no
  provenance tag required by that contract, prospective by design.

## Detection rule

Per person, within the trailing 60 days (relative to the sweep's run date):

- **(a)** Any `needs-follow-up` marker on that person's facts or on an
  interaction they're party to → contributes to the signal.
- **(b)** Any `user:`-owned commitment (from any of that person's
  interactions) whose `by` date is within the next 7 days, or already past,
  where no later interaction with that person exists (i.e. the commitment
  has not visibly been acted on since) → contributes to the signal.
- **(c)** An `## Open threads` bullet on that person's file that is at least
  30 days old (dated by the interaction/debrief that introduced it, or by
  the person file's `last-touch` at the time it was added if undateable more
  precisely) with no interaction since → contributes to the signal, but only
  when (a) and (b) are both absent for that person this scan (lowest
  confidence tier, see below).

At most **one signal event per person per scan**. If two or more of (a)/(b)/
(c) fire for the same person in the same scan, they combine into a single
`debrief-harvest` signal event whose `evidence` lists every contributing
item (see Evidence format) and whose confidence is the highest tier reached
across the contributing items (per the rubric below).

## Confidence rubric

| Confidence | Trigger |
|---|---|
| `high` | An explicit `needs-follow-up` marker (rule a) is present, OR a `user:` commitment due within the next 7 days (rule b, not-yet-overdue case) |
| `medium` | A `user:` commitment past its `by` date with no later interaction (rule b, overdue case), and no `high`-tier item present |
| `low` | Only a stale `## Open threads` bullet (rule c), no `needs-follow-up` marker and no qualifying commitment present |

## Due-date rule

Per `packages/attention/specs/ranking.md` §10: commitment's `by` date − 2
days when that date is in the future; else `detected_at` + 3 days. When a
signal combines multiple commitments, use the earliest still-future `by`
date for the subtraction; if none are future, fall back to `detected_at` + 3
days.

## Opt-out / dedup gates

Applied at the detector, before any signal event is written — matches
`packages/attention/specs/ranking.md` §9's general pre-ranking gate table:

- `data/store/profile.md` `## Signal opt-outs`
  (`packages/core/contracts/profile.md`): `debrief-harvest — all` suppresses
  emission for every person, sweep-wide; `debrief-harvest — [[slug]]`
  suppresses emission for that person only. Unlike `scheduling-intent`'s
  detector (which logs unconditionally before its opt-out check), this
  detector checks the opt-out **before** writing the signal event — an
  opted-out person produces nothing at all, not even a log entry, since
  there is no crowd-visible source to preserve a record of.
- **Dedup (30 days):** before writing, scan `wakeups/signals/*.md` for an
  existing `type: debrief-harvest` signal for the same person with
  `detected_at` within the trailing 30 days. If found, do not re-emit — the
  standing signal (held or promoted, per `specs/ranking.md`) is left to
  carry forward on its own schedule rather than being duplicated.
- This 30-day dedup is also how the no-guilt doctrine (below) is enforced at
  the item level: the same commitment, marker, or open thread never
  contributes to more than one signal event within a 30-day window, even
  across scans, because the whole per-person signal is deduped, not just
  individual items.

## Evidence format

Every contributing item renders as one line, told-by-the-user provenance
throughout — this detector never emits `inferred-*` evidence, since every
input (filing-engine marker, user-owned commitment, open thread) traces back
to something the user said or the filing engine derived directly from it:

- `[stated-by-user] needs-follow-up: "<fact or summary text>" (people/<slug>.md)` or `(interactions/<id>.md)`, matching wherever the marker sits.
- `[stated-by-user] interactions/<id>.md commitment: "user: <what> [by <date>]"`
- `[stated-by-user] people/<slug>.md open thread: "<bullet text>" (added <date-or-approx>, no interaction since)`

`evidence` in the written signal event concatenates every contributing
line, one per line, so a human can judge the full basis without re-fetching
any source file.

## Example scenarios

**1. Ben Whitmore — explicit marker (high).** `people/ben-whitmore.md` has a
`## Facts` bullet `**[told-by-user, needs-follow-up]** Interviewing at two
other firms, may leave current role (2026-08-20)`. No qualifying commitment
or stale open thread. Signal: `confidence: high`, evidence is the one
`needs-follow-up` line, `detected_at` today, `due` = `detected_at` + 3 days
(no commitment `by` date to anchor on).

**2. Walter Combs — overdue commitment (medium) plus stale thread (folds
into medium).** `interactions/2026-07-15-walter-combs.md` has `## Commitments`
bullet `- user: send the intro to the Chicago contact [by 2026-08-01]`; no
later interaction with Walter exists. His `people/walter-combs.md` also
has an `## Open threads` bullet from the same interaction, `Follow up once
he's back from the conference`, over 30 days old with no interaction since.
Rule (b) fires (overdue, no later interaction) at `medium`; rule (c) would
independently qualify at `low`, but since (b) is present the combined signal
takes the higher tier, `medium`. Evidence lists both the commitment line and
the open-thread line. `due` = `detected_at` + 3 days (the `by` date is in the
past, not future, so no `by − 2` anchor applies).

**3. Marcus Chen — upcoming commitment (high), matches the interaction
contract's own example verbatim.** `interactions/2026-08-29-marcus-chen.md`
has `- user: check in on how the Berlin move went [by 2026-10-15]` (per
`packages/core/contracts/interaction.md`'s worked example, adapted here to
Marcus). Today is within the trailing 60 days and `2026-10-15` is more than
7 days out as of `2026-08-29` — so this alone would not qualify under rule
(b)'s "within the next 7 days" clause on 2026-08-29. Re-run the scan on
`2026-10-10` (5 days out, no later interaction with Marcus filed since):
rule (b) now fires at `high`. Evidence: `[stated-by-user]
interactions/2026-08-29-marcus-chen.md commitment: "user: check in on how
the Berlin move went [by 2026-10-15]"`. `due` = `2026-10-15` − 2 days =
`2026-10-13`.

## Out of scope

- **No-guilt doctrine (binding):** per `CLAUDE.md`'s "Capture is optional
  and lossy-tolerant" principle, this detector never manufactures backlog.
  An un-debriefed meeting (a calendar event with no filed interaction after
  it) is **not** a `debrief-harvest` trigger on its own — that once-then-drop
  nudge belongs to plan 06's sweep, not this detector. This detector fires
  only on things the user (or the filing engine, reading the user) already
  said explicitly: a marker, a commitment, an open thread.
- **No aggregate counts.** Evidence never reports "N overdue commitments" or
  any other tally across a person's history — each contributing item is
  quoted individually, and the per-person/30-day dedup means the same item
  surfaces at most once per 30 days, never accumulating into a growing
  backlog number.
- `[[slug]]:`-owned commitments (the other person's promises, not the
  user's) — those are the other party's follow-through, not something the
  user owes; they are not this detector's concern.
- Scoring, the two-signal boost, capacity-mode warmth, the suppression
  floor, and the hold/promote budget decision — all live in
  `packages/attention/specs/ranking.md` and apply uniformly to this
  detector's signal events like any other type's.
- Re-confirmation or expiry of a `needs-confirmation`-tagged fact — that
  marker's own lifecycle is owned by the filing engine
  (`packages/ingestion/skills/debrief/SKILL.md:229-233`); this detector only
  reads `needs-follow-up`, a distinct tag.
- Promotion mechanics, wake-up creation, and the `## Context` ammunition
  section's assembly — those are `specs/ranking.md` §11 and the sweep
  machinery, not this detector.

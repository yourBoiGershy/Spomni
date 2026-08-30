# Expected outcome: one interaction per active day, gap days skipped

This case's `graders/` derive their assertions directly from the fixture
(`./before`) and the capture event embedded in `prompt.md`, checking
specific frontmatter values and content-word facts on the worked store —
rather than a byte-diffable `expected/` tree. A live skill run's prose
(summary wording, exact fact phrasing) isn't guaranteed identical to a
hand-authored golden even when the filing is substantively correct, so a
full-tree byte-diff is too brittle here (same reasoning as
`packages/ingestion/evals/cases/confirm-first-tier-writes/expected/
README.md` and `packages/ingestion/evals/cases/09-debrief-multi-person-
chat/expected/README.md`). This directory exists only to satisfy the
`expected` frontmatter field the T3 runner (`eval-run-skill.sh`) requires;
it is not consumed by `RA_GRADER_DIFF`.

## Hand-derived expected outcome (from `prompt.md`'s embedded capture event)

Per `packages/ingestion/skills/debrief/SKILL.md` §5b-episodes, a
`type: chat-message` event whose genuine messages span more than one UTC
calendar day files one interaction per **active** day, not one interaction
for the whole event. The fixture's capture event has genuine messages on
2026-07-01, 2026-07-03, and 2026-07-05 only — 2026-07-02 and 2026-07-04
have zero messages and are not episodes.

Expected filing:

| File | Expectation |
|---|---|
| `interactions/2026-07-01-erin-fixture.md` | `date: 2026-07-01`, `people: ["[[erin-fixture]]"]`, `source-capture: 20260706T080000Z-beeper-in-whatsapp-ep7f`, `## Summary` mentions the puppy Waffles |
| `interactions/2026-07-03-erin-fixture.md` | same `source-capture`, `## Summary` mentions kayaking |
| `interactions/2026-07-05-erin-fixture.md` | same `source-capture`, `## Commitments` has a `[[erin-fixture]]` bullet about the pasta recipe |
| `interactions/2026-07-02-*` , `interactions/2026-07-04-*` | must not exist — no genuine messages on those days |
| `people/erin-fixture.md` | `last-touch: 2026-07-05` (the latest episode, per §5b-episodes point 4, not per-episode) and a new `## Facts` bullet about the puppy Waffles, dated 2026-07-01 (the day it was actually stated); `tier` unchanged (still empty) |

Nothing else in the store changes: no other person file is touched, no
`wakeups/` entry is created, no fourth interaction file is created.

## Graders

1. `01-three-episodes-and-gap-days.py` — exactly three interaction files
   exist, at the exact per-day filenames `2026-07-0{1,3,5}-erin-fixture.md`,
   each with correct frontmatter (`schema_version`, `date`, `people`,
   `calendar-event: null`, `source-capture` matching the triggering event's
   `id`), each `## Summary` containing that day's distinct content marker
   word (`Waffles` / `kayak` / `pasta` or `recipe`), and confirms no
   interaction file exists for the two gap days (2026-07-02, 2026-07-04).
2. `02-last-touch-fact-and-commitment.py` — `people/erin-fixture.md` has
   `last-touch: 2026-07-05` (anchored to the latest episode, not the first
   or middle one) and a `## Facts` bullet mentioning the puppy Waffles; the
   `2026-07-05` interaction's `## Commitments` section has a bullet
   attributed to `[[erin-fixture]]` about the pasta recipe; `tier` is still
   empty (no tier was ever in scope for this event).

## Manual verification performed

Both graders were run directly against a hand-built worked-store copy of
this fixture (the correct three-episode outcome), and against a doctored
variant collapsing all three days into a single interaction file (to
confirm the graders correctly FAIL a pre-§5b-episodes-style single-file
outcome) — see the completion report for the exact commands and PASS/FAIL
output, and for the live `eval-run-skill.sh` run's result line.

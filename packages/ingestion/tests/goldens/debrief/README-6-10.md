# Golden fixtures: debrief filing, cases 6-10

**Merge note:** this file documents goldens 6-10 only. Goldens 1-5 are a
sibling worker's unit and may land their own `README.md` (or a `README-1-5.md`)
covering cases 1-5 — the two files should be merged into a single
`packages/ingestion/tests/goldens/debrief/README.md` once both units have
landed. Do not delete this file to "resolve" the collision; fold its content
in.

These are Plan 03's (`docs/plans/2026-08-29-03-filing-engine.md`) full
debrief-filing goldens — end-to-end person/interaction/wakeup creation from a
raw capture event, as opposed to the narrower stated-preference-delta goldens
under `../preferences/`. Cases 6-10 are the harder disambiguation/commitment/
contradiction scenarios called out in the plan's Wave A, unit 2.

## Case layout

Each case is a subdirectory containing:

- `input.md` — the triggering capture event, in full `capture-event.md`
  contract shape (frontmatter + raw body).
- `before/` — the minimal store files that exist immediately before filing
  (only what this case's delta touches or must prove untouched; empty
  `people/`, `interactions/`, `wakeups/` directories that a case still needs
  present carry a `.gitkeep`).
- `expected/` — the store state after filing:
  - Files that change get their full expected content.
  - Files that must NOT change are copied byte-identical from `before/`.
  - Directories with no expected writes (e.g. `wakeups/` when no reminder
    ask was made) are omitted from `expected/` entirely, matching the
    `01-simple-single-person` precedent.

## Cases

| Dir | Scenario | Expected outcome |
|---|---|---|
| `06-new-unknown-person/` | Debrief mentions someone with no matching `people/*.md` | A new `people/priya-nair.md` is created from the person template with `**[told-by-user]**` provenance on every fact, plus a filed `interactions/2026-08-29-priya-nair.md` |
| `07-ambiguous-name/` | "Grabbed coffee with Sarah" with two Sarahs already in the store (`sarah-chen`, `sarah-park`) | No store write anywhere (all `before/` people copied unchanged into `expected/`); `expected/question.md` describes the single clarifying question the filing engine must ask instead, per the one-question rule |
| `08-commitment-by-user/` | "I said I'd send him the deck by next Friday" | `interactions/2026-08-29-marcus-webb.md`'s `## Commitments` records `user: send Marcus the pitch deck [by 2026-09-04]`; `people/marcus-webb.md` only advances `last-touch` |
| `09-commitment-by-other-party/` | Contact promises something in a 1:1 WhatsApp thread, captured as `type: chat-message` (`source: beeper-in/whatsapp`, batch-JSON body per `beeper-sweep.sh`'s `event_body` shape, `occurred_at` set to the newest message's timestamp) | `interactions/2026-08-29-jamie-oyelaran.md`'s `## Commitments` records `[[jamie-oyelaran]]: send the signed vendor contract [by 2026-09-07]`, attributed to the contact, not the user |
| `10-contradicts-existing-fact/` | Person was `org: Acme Corp` in `before/`; debrief says they moved to a new company | `people/sofia-alvarez.md` frontmatter `org`/`role` update to the new company/title; `## Facts` preserves the old, dated bullet (`Sales Director at Acme Corp (2026-06-01)`) alongside the new one rather than deleting/rewriting it — the contract's facts list is an append-only, dated journal, not a mutable snapshot, so history survives even though the frontmatter's current-state fields move forward |

All invented personas (Priya Nair, Sarah Chen, Sarah Park, Marcus Webb, Jamie
Oyelaran, Sofia Alvarez) are fictional fixtures, not real people. "Today" is
fixed at `2026-08-29` throughout, matching the rest of `tests/goldens/`.

## Validation

Each case was validated by overlaying `expected/` on a copy of `before/` and
running `bash packages/core/scripts/validate-store.sh <copy>` — see the
worker completion report for per-case results.

# Golden fixtures: debrief filing

Ten input→expected-store cases pinning the behavior of the filing engine
(`docs/plans/2026-08-29-03-filing-engine.md`, Wave A — "goldens before
prompts, per project doctrine": these were authored before
`packages/ingestion/skills/debrief/SKILL.md` existed, so the skill had
hand-derived expected outputs to be built and graded against).

These are the **broader** debrief-filing counterpart to
`packages/ingestion/tests/goldens/preferences/` (which is scoped strictly to
the stated-preference delta). Cases here exercise the full filing path end
to end: person creation/update, interaction filing, commitment extraction,
ambiguous-name disambiguation, and wake-up creation from an embedded
reminder ask.

This directory supersedes the older `packages/ingestion/fixtures/golden/`
path named in the plan doc — the layout below is the one actually used.

## Case layout

Each case is a subdirectory containing:

- `input.md` — a valid capture event (`packages/core/contracts/capture-event.md`
  shape: frontmatter + raw body), as if produced by an input connector.
- `before/` — the minimal starting store subtree the case needs
  (`people/`, `interactions/`, `wakeups/`; near-empty directories are kept
  with a `.gitkeep` so `validate-store.sh`'s directory-presence check
  passes even when a case has nothing to put there yet).
- `expected/` — the store state after correct filing:
  - Files that change get their full expected content (not a diff).
  - Files that must NOT change are byte-identical to their `before/`
    counterpart.
  - Directories with no expected writes (e.g. `wakeups/` when no reminder
    ask was made) are omitted from `expected/` entirely (precedent:
    `01-simple-single-person`).

All facts in `expected/people/*.md` carry the `**[told-by-user]**`
provenance tag with a trailing `(2026-08-29)` capture date, per
`packages/core/contracts/person.md` — this fixture set's fixed "today" is
2026-08-29, matching every input's `captured_at`. Every value in every
`expected/` file was **hand-derived from the input by a human/agent reading
the debrief**, never copied from running an actual filing skill — these
goldens are the spec the skill is built against, not a snapshot of its
output.

## Cases 1-5

| Dir | Scenario | Notes |
|---|---|---|
| `01-simple-single-person/` | Simple single-person voice-note debrief (lunch with Jordan Ellery — a promotion, an open thread) | Existing person gets a new fact + updated `role`/`last-touch`; one interaction, one commitment. |
| `02-rambly-multi-topic/` | Rambly multi-topic voice-note (a long call with Priya Kessler covering a job move, a half marathon, a dog's surgery, and a passing mention of a brother's visit) | Exercises fact-loss resistance — every topic in the input must surface somewhere in `expected/` (facts, open threads, or personal details), none silently dropped. |
| `03-multi-person-meeting/` | Multi-person meeting, authored as a `type: chat-message` Beeper group-chat batch event (`source: beeper-in/whatsapp`), matching the batch shape `beeper-sweep.sh` builds from `packages/connectors/beeper-in/fixtures/messages-page.json` (`{chatID, accountID, network, title, chatType, messages: [...]}`), with `occurred_at` set to the newest message timestamp | Two people (Nadia Okafor, Sam Vartan) both get updated; one interaction links both `[[slug]]`s; the interaction filename uses the recommended `<date>-<primary-person-slug>` form (Nadia, the first-listed person, is primary). |
| `04-embedded-reminder-ask/` | Embedded reminder ask ("remind me to follow up in three weeks") — coffee with Marcus Yeun, who's swamped with a client pitch | `expected/wakeups/2026-09-19-marcus-yeun.md` is due exactly 3 weeks (21 days) after the 2026-08-29 interaction date. Its shape matches `packages/core/scripts/wakeup-add.sh`'s actual output exactly (`schema_version: 1.0.0`, no 1.1.0 fields — this is what a filing skill calling that script would produce, per the single-sanctioned-writer rule in `packages/core/contracts/wakeup.md`). |
| `05-two-word-minimal/` | Two-word minimal debrief: `"coffee, dana"` | Tiny but valid filing — a bare interaction is created (`## Commitments` is `_none_`), the existing `dana-kowalski` person's `last-touch` advances, and no fact is invented from nothing. |

## Cases 6-10

Cases 6-10 are the harder disambiguation/commitment/contradiction scenarios
called out in the plan's Wave A, unit 2.

| Dir | Scenario | Expected outcome |
|---|---|---|
| `06-new-unknown-person/` | Debrief mentions someone with no matching `people/*.md` | A new `people/priya-nair.md` is created from the person template with `**[told-by-user]**` provenance on every fact, plus a filed `interactions/2026-08-29-priya-nair.md` |
| `07-ambiguous-name/` | "Grabbed coffee with Sarah" with two Sarahs already in the store (`sarah-chen`, `sarah-park`) | No store write anywhere (all `before/` people copied unchanged into `expected/`); `expected/question.md` describes the single clarifying question the filing engine must ask instead, per the one-question rule |
| `08-commitment-by-user/` | "I said I'd send him the deck by next Friday" | `interactions/2026-08-29-marcus-webb.md`'s `## Commitments` records `user: send Marcus the pitch deck [by 2026-09-04]`; `people/marcus-webb.md` only advances `last-touch` |
| `09-commitment-by-other-party/` | Contact promises something in a 1:1 WhatsApp thread, captured as `type: chat-message` (`source: beeper-in/whatsapp`, batch-JSON body per `beeper-sweep.sh`'s `event_body` shape, `occurred_at` set to the newest message's timestamp) | `interactions/2026-08-29-jamie-oyelaran.md`'s `## Commitments` records `[[jamie-oyelaran]]: send the signed vendor contract [by 2026-09-07]`, attributed to the contact, not the user |
| `10-contradicts-existing-fact/` | Person was `org: Acme Corp` in `before/`; debrief says they moved to a new company | `people/sofia-alvarez.md` frontmatter `org`/`role` update to the new company/title; `## Facts` preserves the old, dated bullet (`Sales Director at Acme Corp (2026-06-01)`) alongside the new one rather than deleting/rewriting it — the contract's facts list is an append-only, dated journal, not a mutable snapshot, so history survives even though the frontmatter's current-state fields move forward |

All invented personas across cases 6-10 (Priya Nair, Sarah Chen, Sarah Park,
Marcus Webb, Jamie Oyelaran, Sofia Alvarez) are fictional fixtures, not real
people. "Today" is fixed at `2026-08-29` throughout, matching the rest of
`tests/goldens/`.

## How `check-golden.sh` compares

Following the convention set by `packages/ingestion/tests/goldens/preferences/`'s
README, `packages/ingestion/scripts/check-golden.sh` implements this:

1. For each case: copy `before/` into a scratch store, run the filing flow
   against `input.md`.
2. Diff every file under the scratch store against the matching path in
   `expected/`, byte-for-byte, except frontmatter/body dates the filing
   engine derives from "now" — timestamp-only fields (`captured_at:`,
   `filed_at:`, `generated_at:`) are normalized before diffing.
3. Report PASS/FAIL per case; a FAIL prints the diff, not just the case
   name.
4. For an ask-a-question case (an `expected/question.md` present, e.g.
   `07-ambiguous-name`), PASS instead requires the worked store to be
   byte-identical to `before/` and the recorded skill answer to contain a
   question mark — mirroring
   `packages/ingestion/evals/cases/06-ambiguous-question/graders/01-asked-not-written.sh`'s
   T3 grading idiom.
5. `check-golden.sh --all <goldens-root> <worked-root>` walks every case and
   ends with a `SUMMARY: N passed, M failed` line; exit 0 only when every
   case passes.
6. Run `bash packages/core/scripts/validate-store.sh` against each case's
   `expected/` (overlaid on `before/`) as an independent sanity check — a
   golden that doesn't validate is a bug in the golden, not the skill.

The ten cases here are also wrapped as T3 skill-tier eval cases —
`packages/ingestion/evals/cases/07-debrief-simple` through
`16-debrief-contradiction` — run via
`packages/core/scripts/eval-run-skill.sh`/`eval-suite.sh`, listed in
`packages/ingestion/evals/suite.txt`.

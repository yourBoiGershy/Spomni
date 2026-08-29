# Golden fixtures: debrief filing

Ten input→expected-store cases pinning the behavior of the filing engine
(`docs/plans/2026-08-29-03-filing-engine.md`, Wave A unit 1/2 — "goldens
before prompts, per project doctrine": these exist before
`packages/ingestion/skills/debrief/SKILL.md` does, so the skill has
hand-derived expected outputs to be built and graded against).

These are the **broader** debrief-filing counterpart to
`packages/ingestion/tests/goldens/preferences/` (which is scoped strictly to
the stated-preference delta). Cases here exercise the full filing path end
to end: person creation/update, interaction filing, commitment extraction,
and wake-up creation from an embedded reminder ask.

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
- `expected/` — the full store subtree after correct filing: every file
  that should exist post-filing, in full (not a diff). Files untouched by
  the case's delta are byte-identical to their `before/` counterpart.

All facts in `expected/people/*.md` carry the `**[told-by-user]**`
provenance tag with a trailing `(2026-08-29)` capture date, per
`packages/core/contracts/person.md` — this fixture set's fixed "today" is
2026-08-29, matching every input's `captured_at`. Every value in every
`expected/` file was **hand-derived from the input by a human/agent reading
the debrief**, never copied from running an actual filing skill — these
goldens are the spec the skill is built against, not a snapshot of its
output.

## Cases 1-5 (this wave)

| Dir | Scenario | Notes |
|---|---|---|
| `01-simple-single-person/` | Simple single-person voice-note debrief (lunch with Jordan Ellery — a promotion, an open thread) | Existing person gets a new fact + updated `role`/`last-touch`; one interaction, one commitment. |
| `02-rambly-multi-topic/` | Rambly multi-topic voice-note (a long call with Priya Kessler covering a job move, a half marathon, a dog's surgery, and a passing mention of a brother's visit) | Exercises fact-loss resistance — every topic in the input must surface somewhere in `expected/` (facts, open threads, or personal details), none silently dropped. |
| `03-multi-person-meeting/` | Multi-person meeting, authored as a `type: chat-message` Beeper group-chat batch event (`source: beeper-in/whatsapp`), matching the batch shape `beeper-sweep.sh` builds from `packages/connectors/beeper-in/fixtures/messages-page.json` (`{chatID, accountID, network, title, chatType, messages: [...]}`), with `occurred_at` set to the newest message timestamp | Two people (Nadia Okafor, Sam Vartan) both get updated; one interaction links both `[[slug]]`s; the interaction filename uses the recommended `<date>-<primary-person-slug>` form (Nadia, the first-listed person, is primary). |
| `04-embedded-reminder-ask/` | Embedded reminder ask ("remind me to follow up in three weeks") — coffee with Marcus Yeun, who's swamped with a client pitch | `expected/wakeups/2026-09-19-marcus-yeun.md` is due exactly 3 weeks (21 days) after the 2026-08-29 interaction date. Its shape matches `packages/core/scripts/wakeup-add.sh`'s actual output exactly (`schema_version: 1.0.0`, no 1.1.0 fields — this is what a filing skill calling that script would produce, per the single-sanctioned-writer rule in `packages/core/contracts/wakeup.md`). |
| `05-two-word-minimal/` | Two-word minimal debrief: `"coffee, dana"` | Tiny but valid filing — a bare interaction is created (`## Commitments` is `_none_`), the existing `dana-kowalski` person's `last-touch` advances, and no fact is invented from nothing. |

Cases 6-10 (new unknown person, ambiguous name, commitment made by user,
commitment made by other party, contradicts-existing-fact) live in this same
directory, authored separately.

## How a future `check-golden.sh` should compare

Following the convention set by `packages/ingestion/tests/goldens/preferences/`'s
README:

1. For each case: copy `before/` into a scratch store, run the filing flow
   against `input.md`.
2. Diff every file under the scratch store against the matching path in
   `expected/`, byte-for-byte, except frontmatter/body dates the filing
   engine derives from "now" — normalize those to `2026-08-29` (this
   fixture set's fixed "today") before diffing.
3. Report PASS/FAIL per case; a FAIL should print the diff, not just the
   case name.
4. Run `bash packages/core/scripts/validate-store.sh` against each case's
   `expected/` (overlaid on `before/`) as an independent sanity check — a
   golden that doesn't validate is a bug in the golden, not the skill.

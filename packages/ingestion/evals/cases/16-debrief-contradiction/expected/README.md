# Expected outcome: contradiction filed with valid provenance, old fact preserved

This directory exists only to satisfy the `expected` frontmatter field the
T3 runner (`eval-run-skill.sh`) requires and to hand-derive this case's
`graders/` assertions from — it is **not** consumed by a byte-diff grader
(same reasoning as `confirm-first-tier-writes/expected/README.md` and
`packages/attention/evals/cases/zero-create-without-confirm/expected/README.md`:
a live skill run's untouched-file bytes aren't guaranteed identical to a
hand-authored golden even when the field under test is correct). The
`people/sofia-alvarez.md` and `interactions/2026-08-29-sofia-alvarez.md`
files here are still the hand-derived golden shape (copied from
`packages/ingestion/tests/goldens/debrief/10-contradicts-existing-fact/expected/`,
which this case's `before/` also derives from) — they document the intended
outcome for a human reader even though the graders check facts, not bytes.

## Hand-derived expected outcome

Per `prompt.md`'s capture event (Sofia left Acme Corp, started as VP of
Sales at Globex Corp) and the two contracts it quotes verbatim
(`packages/core/contracts/person.md`'s provenance-tag rule and
`packages/ingestion/skills/debrief/SKILL.md` §5a's append-only Facts /
current-state frontmatter split):

- `people/sofia-alvarez.md` frontmatter: `org: Globex Corp`,
  `role: VP of Sales`, `last-touch: 2026-08-29` (tier untouched).
- `## Facts` keeps the existing `**[told-by-user]** Sales Director at Acme
  Corp (2026-06-01)` bullet byte-for-byte, and gains one new
  `**[told-by-user]**`-tagged bullet dated `(2026-08-29)` that names both
  the departure from Acme and the new Globex/VP-of-Sales role — never a
  bracket tag other than `told-by-user`/`inferred-public-web` (a live run
  previously invented `[voice-note]` from the capture event's `type:`
  field, which is the doctrine violation this case exists to catch).
- `interactions/2026-08-29-sofia-alvarez.md` is the only new file, filed
  per SKILL.md §5b's `<date>-<primary-person-slug>` rule and
  `interaction.md`'s frontmatter contract.
- `wakeups/` is left untouched (empty, modulo the `.gitkeep` fixture file).

## Graders

1. `01-person-facts-and-provenance.py` — `sofia-alvarez.md` frontmatter
   updated correctly; old Facts bullet preserved append-only; new Facts
   bullet carries a valid provenance tag (`told-by-user` or
   `inferred-public-web` only) and mentions both the new role and the old
   org (the contradiction context).
2. `02-interaction-and-wakeups.py` — the interaction file's exact filename
   and frontmatter fields; `wakeups/` has no spurious files.

## Manual verification performed

Both graders were run directly against hand-built worked-store copies of
this fixture (the correct outcome, and doctored variants — an invented
`[voice-note]` tag, a rewritten/removed old fact, a dropped Acme mention, a
spurious wakeup file) to confirm each assertion actually fails when it
should — see the completion report for the exact commands/output and the
live `eval-run-skill.sh` PASS lines.

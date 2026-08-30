---
tier: skill
store: packages/ingestion/evals/cases/stated-kind-sticks/before
expected: packages/ingestion/evals/cases/stated-kind-sticks/expected
max-turns: 10
model: haiku
budget-usd: 0.10
---
Act as `packages/ingestion/skills/review-tiers/SKILL.md` Step 3's
validate-and-write sub-step — the judge already produced its records for
this batch, they are pre-seeded at
`./store/data-ingestion/review-judgments/2026-08-29.jsonl` (three people:
`hal-torrance`, `ravi-sundar`, `sol-abernathy`), and your job is only to
validate and apply them, per `packages/core/contracts/relationship-scoring.md`'s
`## Rules` — in particular:

> **Stated kinds are sticky:** a `kind_source: stated-by-user` value is
> never overwritten by a judgment record — the classification pass skips
> people whose current kind is user-stated.

`check-judgment.sh` is not runnable in this workspace, so apply its
`stated-kind-changed` check by hand, one record at a time:

1. For each record in `./store/data-ingestion/review-judgments/2026-08-29.jsonl`,
   read that person's file at `./store/people/<slug>.md` and inspect its
   frontmatter `kind_source` field.
2. If `kind_source: stated-by-user` **and** the record's `kind` field
   disagrees with that person's already-stated `kind` value: this is a
   `stated-kind-changed` rejection. Append one line,
   `<slug>\treject:stated-kind-changed`, to `./store/data-ingestion/run.log`,
   and rewrite that record's `kind` field, in place, in the judgments
   jsonl file to the person's already-stated `kind` value (leave every
   other field on that record line untouched). Do **not** touch that
   person's `people/<slug>.md` file in any way — the stated kind is
   already correct there and is never overwritten.
3. If `kind_source` is `derived`, `unknown`, or absent (i.e. not
   `stated-by-user`): this is an accepted record. Perform the derived
   kind write directly on `./store/people/<slug>.md`'s frontmatter —
   set/replace `kind`, `kind_note`, `kind_source: derived`, and
   `kind_updated: 2026-08-29` (insert these lines immediately after the
   `tier:` line and before the closing `---` if not already present;
   otherwise replace the existing `kind`/`kind_note`/`kind_source`/
   `kind_updated` lines in place). Every other line in that person's file
   (frontmatter and body) stays byte-identical to what it was before this
   write. Do not modify `run.log` for an accepted record.

Process all three records in the file (`hal-torrance`, `ravi-sundar`,
`sol-abernathy`), in that order. Write the files now — do not just
describe what you would write.

---
tier: skill
store: packages/ingestion/evals/cases/triage-held-respected/before
expected: packages/ingestion/evals/cases/triage-held-respected/expected
max-turns: 10
model: haiku
---
Act as ingestion's debrief filing skill, per
`packages/ingestion/skills/debrief/SKILL.md`, running in **batch mode**
against `./store` (contains `inbox/`, `people/`, `interactions/`).

This eval workspace has no real `data/` directory alongside `./store`, so
for this session only, wherever SKILL.md says `data/ingestion/debrief-
filed.log` read/write `./store/data-ingestion/debrief-filed.log` instead,
and wherever it says `data/ingestion/triage-held.log` read/write
`./store/data-ingestion/triage-held.log` instead — same files, same
format, adapted path only. Both already exist and are pre-seeded; do not
create fresh empty ones, and do not run `triage-inbox.sh` yourself (it
already ran, off-screen, before this session started — its output is
exactly the pre-seeded `triage-held.log` line below).

Quoting SKILL.md §1's batch mode section verbatim (the operative procedure
for this task, `<data-dir>` bound to `./store/data-ingestion` per the
adaptation above):

> Sweep `<store-dir>/inbox/*.md` (excluding `inbox/quarantine/`, which this
> skill never reads — quarantine is for human review only, per
> `docs/data-layout.md`) for every capture event whose `id` is **not** in
> `data/ingestion/debrief-filed.log` and **not** in `data/ingestion/
> triage-held.log` (the deterministic pre-judgment hold ledger written by
> `packages/ingestion/scripts/triage-inbox.sh`, per `packages/ingestion/
> specs/import-triage.md`). Process them oldest-first by `captured_at`
> (ties broken by filename), running the per-event flow below on each in
> turn. A failure or an outstanding ambiguous question on one event does
> not block the rest of the batch — move to the next unfiled event
> regardless.

`./store/inbox/` contains exactly three capture events:

1. `triage-held-fixture-held.md` — its `id`,
   `triage-held-fixture-held`, appears in
   `./store/data-ingestion/triage-held.log` (a prior `triage-inbox.sh` pass
   held it under the `noreply-marketing` rule). Per the quoted procedure
   above, this event is **excluded from the batch sweep** — do not file it,
   do not create any `people/` or `interactions/` write for it, do not add
   it to `debrief-filed.log`. Do not re-judge or second-guess the hold —
   trust the ledger, per the triage spec's precision-first doctrine; this
   batch pass's job is only to honor the exclusion, not to re-evaluate the
   held event's content.
2. `triage-held-fixture-filed.md` — its `id`,
   `triage-held-fixture-filed`, already appears in
   `./store/data-ingestion/debrief-filed.log` (it was filed in a prior
   session; `./store/interactions/2026-08-01-sam-quill.md` is that prior
   filing's result, already present in the store). Per the quoted
   procedure, this event is **also excluded** — do not re-file it, do not
   create a second interaction for it, do not modify
   `people/sam-quill.md` or the existing interaction file in any way.
3. `triage-held-fixture-eligible.md` — its `id` appears in **neither**
   ledger. This is the one event the batch sweep must actually process:
   file it normally per SKILL.md's full per-event flow (envelope parse,
   participant resolution against `./store`, person/interaction writes,
   then append its `id` to `./store/data-ingestion/debrief-filed.log`).
   Resolve "Morgan Alvarez" against `./store` (there is exactly one
   matching person file, `people/morgan-alvarez.md`). Create
   `interactions/2026-08-20-morgan-alvarez.md` per
   `packages/core/contracts/interaction.md`'s shape (`schema_version:
   1.0.0`, `date: 2026-08-20`, `people: ["[[morgan-alvarez]]"]`,
   `calendar-event: null`, `source-capture: triage-held-fixture-eligible`,
   a `## Summary` prose section, and a `## Commitments` section — Morgan's
   stated intention to send the new site's contact sheet next week is a
   real commitment per SKILL.md's commitment rule and belongs there as
   `[[morgan-alvarez]]: send the new warehouse site's contact sheet (by
   next week)`, never `_none_`). Apply SKILL.md §5a's person-update rules
   to `people/morgan-alvarez.md` (new fact appended to `## Facts`, tagged
   `**[told-by-user]**` with `(2026-08-20)`; `last-touch` set to
   `2026-08-20`).

Do not run `build-index.sh` or `validate-store.sh` — this eval only grades
the `people/`/`interactions/`/`data-ingestion/debrief-filed.log` state.
Write the files now; do not just describe what you would write.

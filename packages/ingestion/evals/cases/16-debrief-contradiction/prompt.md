---
tier: skill
store: packages/ingestion/evals/cases/16-debrief-contradiction/before
expected: packages/ingestion/evals/cases/16-debrief-contradiction/expected
max-turns: 12
model: haiku
---
Act as ingestion's debrief filing skill
(`packages/ingestion/skills/debrief/SKILL.md`), filing exactly one capture
event into `./store` (contains `people/`, `wakeups/`). This eval skips the
`inbox/`/dedup-ledger mechanics and the `5c` index/validate/log steps (no
`data/ingestion/debrief-filed.log` bookkeeping, no `build-index.sh`, no
`validate-store.sh`) — just produce the `people/` and `interactions/` writes
single-event mode would.

The capture event:

```
---
schema_version: 1.2.0
id: 20260829T170000Z-manual-d40a
source: manual
captured_at: 2026-08-29T17:00:00Z
type: voice-note
participant-hints:
  - "Sofia Alvarez"
---
Caught up with Sofia — big news, she left Acme Corp last month and just
started as VP of Sales at Globex Corp. Sounds like a great move for her.
```

Resolve "Sofia Alvarez" against `./store` — her `people/sofia-alvarez.md`
currently has `org: Acme Corp`, `role: Sales Director`, and a `## Facts`
bullet recording that. This is a **contradiction case**: the new information
supersedes the old org/role. Follow these two contracts to the letter —
quoted verbatim below, not paraphrased, because inventing a provenance tag
or dropping the old-org context are the two ways this case is failed.

## `packages/core/contracts/person.md` — Facts provenance (binding)

> A bullet list. **Every fact carries a provenance tag** — the binding rule
> from `docs/DECISIONS.md#provenance-labeling`: told-by-user vs.
> inferred-from-public-web, never mixed or defaulted. Tag format, at the
> start of the bullet:
>
> ```
> - **[told-by-user]** <fact text>
> - **[inferred-public-web]** <fact text>
> ```
>
> Both tags may carry an optional trailing date in parens, `(2026-08-29)`,
> noting when the fact was captured/inferred — useful for staleness checks.
> Facts with no tag are a validator error (see `validate-store.sh`).

**There are exactly two valid provenance tags: `[told-by-user]` and
`[inferred-public-web]`. No other bracketed tag (e.g. `[voice-note]`,
`[debrief]`, the capture event's own `type:` field) is ever used as a
provenance tag — `type: voice-note` describes how the capture arrived, not
who vouched for the fact.**

## `packages/ingestion/skills/debrief/SKILL.md` §5a — person file updates (contradiction handling, binding)

> - **New facts** — every new factual claim about that person surfaced by
>   the debrief becomes a new bullet appended to `## Facts`, tagged
>   `**[told-by-user]**` (a human debrief is always told-by-user provenance;
>   `inferred-public-web` is never used by this skill — that tag is only for
>   the research-seed extension) with a trailing capture date in parens,
>   `(YYYY-MM-DD)` — the interaction's date, not "today" if they differ.
>   **Never delete or rewrite an existing `## Facts` bullet**, even when a
>   new fact supersedes it — the facts list is an append-only, dated journal
>   (see golden 10: the old `Sales Director at Acme Corp (2026-06-01)`
>   bullet stays untouched, and the new org/role fact is appended below it).
> - **Frontmatter field updates** — when a new fact changes a field
>   `person.md` tracks in frontmatter (`org`, `role`, `location`, `tier`,
>   etc.), update the frontmatter field itself to the new value (frontmatter
>   is current-state, not a journal — contrast with `## Facts` above). The
>   supersede fact bullet is still appended per the previous bullet, so the
>   old value survives as history even though frontmatter has moved on.
> - **`last-touch`** — always set to the interaction's date, regardless of
>   whether any fact/frontmatter changed.

Concretely for this event: append one new `**[told-by-user]**` bullet dated
`(2026-08-29)` that names **both** the departure and the new role — the
fact text must make the Acme→Globex transition explicit (e.g. "Left Acme
Corp and started as VP of Sales at Globex Corp"), not just state the new
role in isolation, so the contradiction/supersede context survives on the
bullet itself. Leave the existing `**[told-by-user]** Sales Director at
Acme Corp (2026-06-01)` bullet byte-for-byte untouched. Update frontmatter
`org: Globex Corp`, `role: VP of Sales`, `last-touch: 2026-08-29`. `tier` is
unaffected by this debrief — leave it as-is.

## `packages/core/contracts/interaction.md` — frontmatter (binding)

```
---
schema_version: 1.0.0
date: 2026-08-29
people: ["[[dana-whitfield]]"]
calendar-event: null
source-capture: 20260829T143200Z-gmail-in-9f2a
---
```

`schema_version` is always `1.0.0`. `date` is the interaction date (from the
capture event above: `2026-08-29`). `people` lists every matched person's
`[[slug]]` — note the **double square brackets are part of the string
value itself**, exactly as in the example above (`["[[dana-whitfield]]"]`,
not `["dana-whitfield"]`); for this event that is `["[[sofia-alvarez]]"]`.
`calendar-event` is `null` (no calendar link here). `source-capture` is the
triggering capture event's `id` (`20260829T170000Z-manual-d40a`).

## `packages/ingestion/skills/debrief/SKILL.md` §5b — filename rule (binding)

> `id`/filename: `<date>-<primary-person-slug>` (`<date>` from §2;
> `<primary-person-slug>` is the first-listed/first-matched person...).
> Append `--2`, `--3`, etc. only for a same-day duplicate against the same
> primary slug.

For this event that is `interactions/2026-08-29-sofia-alvarez.md`.

Write `## Summary` as a full-prose retelling of what happened (not a
verbatim copy of the capture body) — she left Acme Corp and started as VP
of Sales at Globex Corp. `## Commitments` is `_none_` — the debrief surfaces
no promise from either side.

Do not create, delete, or modify anything under `wakeups/`. Do not run
`build-index.sh` or `validate-store.sh` — this eval only grades the
`people/`/`interactions/`/`wakeups/` writes.

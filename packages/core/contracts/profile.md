# Contract: profile

`schema_version: 1.0.0`

## Store location

`data/store/profile.md` — a **singleton**: exactly one file, no filename
variation, no per-person copies. It holds the user's own stated preferences
about how the assistant should behave, not facts about other people (that's
`person.md`'s job).

## Writer / readers

- **Sole writer:** the filing engine (`packages/ingestion`) — files stated
  preferences from debriefs/capture events and, after user confirmation,
  observed style notes from the draft-diff loop.
- **Readers:** `packages/attention` (signal-scan applies `## Signal opt-outs`
  before ranking; sweep calibration reads style notes context), `packages/query`
  (answers, briefs).
- **Never writes:** `packages/attention` only *proposes* preference changes
  (e.g. via a wake-up asking the user to confirm an observed pattern) — it
  never writes `profile.md` directly. Revealed preference proposes; it does
  not overwrite (`docs/DECISIONS.md#preference-provenance`).

## Shape

Markdown file with YAML frontmatter plus four fixed prose sections, always in
this order, always present (empty is valid — a section with no bullets yet).

### Frontmatter fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | semver string | yes | Contract version this file conforms to. |

### Body sections (fixed, in this order)

#### `## Priorities`

A bullet list of freeform stated priorities, e.g. "family first this
quarter." Provenance-tagged (see below).

#### `## Cadence wishes`

A bullet list of stated rhythm asks, e.g. "quarterly with the Michigan
crowd." Provenance-tagged (see below).

#### `## Signal opt-outs`

A bullet list of deterministic opt-outs, one signal-type per bullet (signal
types come from the plan 05 detector set). Provenance-tagged (see below), but
in practice always `**[stated-by-user]**` since an opt-out is by definition
an explicit ask. Exactly one of two grammars per bullet:

```
- **[stated-by-user]** <signal-type> — all
- **[stated-by-user]** <signal-type> — [[slug]]
```

`all` suppresses that signal type across every person; `[[slug]]` suppresses
it only for that one person. Opt-outs **suppress at the detector, before
ranking** (plan 05 signal-scan) — they are never encoded as zero weights in
`ranking-weights.json`, so a suppressed signal produces no signal-event at
all rather than a signal-event that ranks last.

#### `## Style notes`

A bullet list, **observed-from-behavior only** — no `stated-by-user` bullets
belong here, since these are inferences about the user's own habits, not
things the user said. Filed solely after user confirmation (fed by the
draft-diff loop): the filing engine never writes a style note from a raw
observation alone, only once the user has confirmed it. Empty is the normal
starting state.

### Provenance tagging (binding on every bullet in every section)

Every bullet in every section above **carries a provenance tag** — mirrors
`person.md`'s `## Facts` convention
(`docs/DECISIONS.md#preference-provenance`: stated outranks observed, and
revealed preference proposes, never overwrites). Tag format, at the start of
the bullet:

```
- **[stated-by-user]** <bullet text>
- **[observed-from-behavior]** <bullet text>
```

Both tags may carry an optional trailing date in parens, `(2026-08-29)`,
noting when the preference was captured/observed — useful for staleness
checks and for the draft-diff loop to know how long an observed pattern has
held. Bullets with no tag are a validator error (see `validate-store.sh`).

## Example

`data/store/profile.md`:

```markdown
---
schema_version: 1.0.0
---

## Priorities

- **[stated-by-user]** Family first this quarter — deprioritize work
  contacts unless something's time-sensitive (2026-08-29)

## Cadence wishes

- **[stated-by-user]** Quarterly with the Michigan crowd (2026-08-29)

## Signal opt-outs

- **[stated-by-user]** birthday — [[dana-whitfield]]
- **[stated-by-user]** job-change — all

## Style notes

- **[observed-from-behavior]** Prefers shorter drafts (under 60 words) for
  work contacts; edits longer drafts down every time (2026-08-29)
```

## Notes

- Widening the enums this contract references (signal-types in `## Signal
  opt-outs`, the two provenance tags) in a backward-compatible way is a
  `schema_version` minor bump (additive), not a major one — same convention
  as `capture-event.md`'s `type: other` precedent. A change that alters the
  meaning of an existing bullet grammar or removes a fixed section is major.
- Because this is a singleton, there is no `id`/filename-derived key in
  frontmatter the way `person.md` has `slug` — `data/store/profile.md` is the
  entire addressing scheme.
- `## Signal opt-outs` bullets are read by `packages/attention`'s signal-scan
  step and applied *before* `ranking-weights.json` weighting, per plan 11's
  binding artifact design — do not conflate the two files' roles.

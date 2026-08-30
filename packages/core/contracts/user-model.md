# Contract: user-model

`schema_version: 1.1.0`

## Store location

`data/store/user-model.md` — a **singleton**: exactly one file, no filename
variation, no per-person copies. It holds the user's stated
relationship-investment model — how the user wants to allocate attention
across relationship categories — distinct from `profile.md` (behavior/style
preferences) and from any single person's file.

## Writer / readers

- **Sole writer:** the filing engine (`packages/ingestion`) — computes the
  `draft` from corpus signals (revealed behavior) and, after user
  confirmation, writes the `confirmed` version.
- **Readers:** `packages/ingestion` (the review-tiers skill, presenting the
  draft for confirmation), `packages/attention` (tier-drift detection,
  calibration seeding into `ranking-weights.json`), `packages/query`
  (answers, briefs).
- **Never writes:** `packages/attention` only *proposes* revisions to a
  confirmed model (e.g. via a wake-up asking the user to reconfirm after a
  season change) — it never writes `user-model.md` directly, mirroring the
  `profile.md` rule (`docs/DECISIONS.md#preference-provenance`).

## Lifecycle

A `user-model.md` is born as a **draft**: ingestion derives it from observed
behavior in the corpus (`derive-user-model.sh`, plan 30) and writes it with
`status: draft`, `provenance: observed-from-behavior`, `confirmed_at: null`,
`revision: 0`. The draft is surfaced to the user for review; only on
explicit confirmation does ingestion rewrite the file with `status:
confirmed`, `provenance: stated-by-user`, `confirmed_at` set to the
confirmation date, and `revision` bumped to `1`. Every subsequent
confirmed edit (the user re-runs the confirm flow) bumps `revision` by one
and re-triggers prior seeding in `ranking-weights.json` (plan 30 D6) —
scores are expected to change when this file changes; that is the point.

**`provisional` status (plan 31 D6).** Cold-start supersedes waiting on the
user: when a scoring/seeding step (e.g. review-tiers step 1) finds
`user-model.md` absent or still `draft`, it derives one and auto-adopts it
as `status: provisional` with no confirm dialogue — same fields as a fresh
draft (`provenance: observed-from-behavior`, `confirmed_at: null`,
`revision: 0`). Every consumer of this contract (seeding, calibration,
ranking) treats `provisional` exactly like `confirmed` — the whole point is
that the user spends zero effort *stating* and only ever *corrects*. The
confirm dialogue (`/review-tiers --confirm-model`) only runs when the user
asks for it; running it against a `provisional` model moves it to
`status: confirmed`, `provenance: stated-by-user`, `confirmed_at` set, and
bumps `revision` to `1`, exactly as it would from `draft`.

**Pairing rule** (validator-enforced): `status: draft` or `status:
provisional` if-and-only-if `provenance: observed-from-behavior` and
`confirmed_at: null`; `status: confirmed` if-and-only-if `provenance:
stated-by-user` and `confirmed_at` is a set date. `revision` starts at `0`
on a draft or provisional model and becomes `1` on first confirmation.

**Draft files are never read by any scoring/judgment step** — a
`confirmed` *or* `provisional` `user-model.md` is consumed by ranking or
calibration; a plain `draft` exists solely for the confirm flow and is
never read by scoring.

## Shape

Markdown file with YAML frontmatter plus four fixed prose sections, always
in this order, always present (empty/placeholder is valid on a draft).

### Frontmatter fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | semver string | yes | Contract version this file conforms to. |
| `status` | enum | yes | One of `draft`, `provisional`, `confirmed`. `provisional` (plan 31 D6): derived, auto-adopted with no confirm dialogue — `revision: 0`, `provenance: observed-from-behavior`, `confirmed_at: null`, same pairing as `draft`. Consumers (seeding, scoring) treat `provisional` the same as `confirmed`; a stated confirm moves it to `confirmed` and bumps `revision`. |
| `derived_at` | ISO 8601 date | yes | `YYYY-MM-DD`. When the draft was computed from the corpus. |
| `confirmed_at` | ISO 8601 date or `null` | yes | `YYYY-MM-DD` once confirmed; `null` while `status: draft`. |
| `revision` | integer | yes | `0` on a fresh draft; bumps by one on every confirmed edit. |
| `provenance` | enum | yes | One of `observed-from-behavior` (draft), `stated-by-user` (confirmed). |

### Body sections (fixed, in this order)

#### `## Investment mix`

One line per axis, fixed set of five axes — `business`, `friends`,
`family`, `community`, `transactional` — all five always present:

```
- <axis>: <weight 0-1> — <rationale>
```

Weights are numbers in the closed interval `[0, 1]`. A draft may carry a
weight with rationale `no evidence in window` when the corpus has no signal
for that axis.

#### `## Protected time`

Freeform prose: what the user keeps regardless of business load, e.g.
"regular friends — weekly-ish hangs are non-negotiable."

#### `## Season`

Freeform prose describing the current posture, with an optional trailing
`until: <ISO 8601 date>` marking when the season is expected to end, e.g.
"heads-down quarter, business-first until 2026-11-30."

#### `## Revealed vs stated`

Two labeled blocks, never merged:

- A `revealed (observed-from-behavior)` subheading holding the draft's
  corpus-derived numbers verbatim, kept for audit even after confirmation.
- A `stated` note pointing back at `## Investment mix` as the confirmed
  version (the axis lines above are the source of truth once
  `status: confirmed`).

Optionally, the revealed block may include one additional line (D8(iii)):

```
embedding-similarity: business=<0-1> friends=<0-1> family=<0-1> community=<0-1> transactional=<0-1> (nomic-embed-text, local)
```

the similarity of recent interaction summaries to the five axis
descriptions, produced by `derive-user-model.sh`. This line is **OPTIONAL**
— omitted whenever local embeddings are unavailable.

## Example

`data/store/user-model.md` (confirmed):

```markdown
---
schema_version: 1.0.0
status: confirmed
derived_at: 2026-08-20
confirmed_at: 2026-08-29
revision: 1
provenance: stated-by-user
---

## Investment mix

- business: 0.45 — biggest chunk of the week, but not everything
- friends: 0.3 — protected, see below
- family: 0.15 — steady, low-maintenance right now
- community: 0.05 — mostly dormant this quarter
- transactional: 0.05 — kept minimal on purpose

## Protected time

Regular friends — weekly-ish hangs are non-negotiable, even during
heads-down business stretches.

## Season

Heads-down quarter, business-first until 2026-11-30.

## Revealed vs stated

revealed (observed-from-behavior):
- business: 0.52 — largest share of interactions in the last 90 days
- friends: 0.24 — steady but below stated protection
- family: 0.14
- community: 0.03
- transactional: 0.07
- embedding-similarity: business=0.61 friends=0.44 family=0.31 community=0.12 transactional=0.22 (nomic-embed-text, local)

stated: see `## Investment mix` above — the user's confirmed numbers,
adjusted upward for friends relative to the revealed draft.
```

## Versioning note

Widening this contract in a backward-compatible way (new optional
frontmatter field, new optional line in `## Revealed vs stated`, widening
the axis set) is a `schema_version` minor bump (additive) — same convention
as `profile.md`. A change that alters the meaning of an existing field,
removes a fixed section, or changes the fixed axis set is major.
`1.1.0` = additive `status: provisional` enum value per plan 31 D6 (a
derived, no-dialogue auto-adopted model, treated like `confirmed` by every
consumer); `1.0.0` files (`status` in `draft`/`confirmed` only) remain
valid.

## Notes

- Singleton: `data/store/user-model.md`, never committed to this repo —
  user-owned state lives under the user's private `data/` dir (see
  `data/README.md`). Fixtures for this contract live only under
  `packages/core/fixtures/`.
- Because this is a singleton, there is no `id`/filename-derived key in
  frontmatter the way `person.md` has `slug` — `data/store/user-model.md`
  is the entire addressing scheme.

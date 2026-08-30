# Spec: user-model derive

Status: spec (plan 30 unit 4). Package: `packages/ingestion` (sole writer of
`data/store/user-model.md`, per `contracts/user-model.md`). Script of
record: `packages/ingestion/scripts/derive-user-model.sh <store>
[--redraft] [--similarity-file <json>]` (forward-declared, unit 7).

## Purpose

Defines how the `user-model.md` **draft** — `status: draft`,
`provenance: observed-from-behavior` — is computed from the corpus, so the
Phase 3 scripts and the review-tiers skill (`review-tiers.md`) have a model
of record for what "derive" means. This spec does not define the confirm
dialogue (a user-facing flow) — see `review-tiers.md` step 1 — nor the
embedding computation itself — see `embeddings.md`.

## Window

Trailing 90 days ending at run date (the date `derive-user-model.sh` is
invoked). Any interaction, meeting, or chat-day outside this window is not
counted toward the revealed mix.

## Revealed mix computation

Per axis — `business`, `friends`, `family`, `community`, `transactional`,
the same fixed five-axis set `contracts/user-model.md`'s `## Investment
mix` requires — the revealed block reports two independent shares, both
computed over the trailing-90-day window:

- **Share of interactions:** the fraction of in-window `interactions/*.md`
  files whose person resolves to that axis (see "Axis assignment" below).
- **Share of meetings:** the fraction of in-window interactions with
  `calendar: true` in `stats.json` (i.e. calendar-typed interactions)
  whose person resolves to that axis, computed separately from the
  interaction share above — a person's meetings and their non-meeting
  interactions can land on different distributions.

### Axis assignment (per person)

1. **If `people/<slug>.md` has a `kind`** (`contracts/person.md` 1.1.0),
   map it via this fixed table:

   | `kind` | axis |
   |---|---|
   | `friend` | friends |
   | `family` | family |
   | `collaborator` | business |
   | `professional` | business |
   | `community` | community |
   | `transactional` | transactional |
   | `scheduling` | transactional |
   | `unsolicited` | transactional |

2. **Else, heuristic** (no `kind` set, or `kind: unknown`):
   - Calendar meetings with 2 or more attendees (self excluded from the
     count) → `business`.
   - Chat-days on a personal Beeper channel (the `whatsapp` or `matrix`
     lanes specifically — not `linkedin`; the channel segment in
     `source-capture` is matched case-insensitively, since live ids carry
     mixed-case channel names, e.g. `beeper-in-WhatsApp`) → `friends`. A
     legacy bare `beeper-<hex>` id (no `-in-<channel>` segment) is not a
     personal-channel match — it falls through to the next rule.
   - A `family` tag on the person (`people/<slug>.md` tags) → `family`.
   - None of the above match → `unassigned`.

A person contributes to exactly one axis per interaction/meeting counted
(the axis assignment is evaluated once per person, not re-evaluated per
interaction, so a person's evidence never splits across two axes). Nothing
is silently dropped: `unassigned` interactions/meetings are reported as a
standalone `unassigned: <share>` line in the revealed block — not folded
into any of the five axes, and not omitted from the shares (shares are
computed over the full in-window set including unassigned, so the five
axis shares plus `unassigned` sum to 1.00, modulo rounding).

## Weight computation

Weight per axis = `round(share, 2)` (interaction share; the meeting share
is reported alongside, not blended into the weight — see "Output" below).
When an axis has zero in-window evidence (no interactions and no meetings
resolve to it), its revealed line reads:

```
<axis>: 0.00 — no evidence in window
```

These revealed numbers are the ONLY content of the revealed block — they
do not themselves become the stated `## Investment mix` lines by fiat.
The draft's `## Investment mix` section is **initialized** from the
revealed interaction-share weights (so a freshly-drafted file has
plausible starting numbers), but that initialization is the draft state
only — the user edits `## Investment mix` at confirm time
(`review-tiers.md` step 1), and post-confirmation the axis lines are the
source of truth per `contracts/user-model.md`'s "Revealed vs stated"
section, independent of what the revealed block says.

## Optional similarity line (D8iii)

When `--similarity-file <json>` is given, the file is JSON of the shape:

```json
{"business": 0.61, "friends": 0.44, "family": 0.31, "community": 0.12, "transactional": 0.22, "model": "nomic-embed-text"}
```

(produced by `nearest-confirmed.sh --axis-similarity`, unit 8 — a
similarity of recent interaction summaries to the five axis descriptions).
When present, `derive-user-model.sh` appends one line to the revealed
block:

```
embedding-similarity: business=.. friends=.. family=.. community=.. transactional=.. (<model>, local)
```

using the values and `model` name verbatim from the input file. The
`--similarity-file` flag is omitted whenever local embeddings are
unavailable — `derive-user-model.sh` never calls Ollama itself, never
computes embeddings, and never fails or warns when the flag is absent;
absence simply means the optional line is omitted, per
`contracts/user-model.md`'s "OPTIONAL" note on this line.

## Output

Writes `<store>/user-model.md` from `packages/core/templates/user-model.md`
with:

- `status: draft`
- `provenance: observed-from-behavior`
- `derived_at: <today>`
- `confirmed_at: null`
- `revision: 0`
- `## Investment mix`: the five axis lines, weights initialized from the
  revealed interaction shares (see "Weight computation" above), each with
  a short rationale reflecting the source (e.g. "largest share of
  interactions in the last 90 days").
- `## Protected time` and `## Season`: empty, carrying only the template's
  guidance-comment placeholders (no invented prose) — these sections have
  no corpus-derived signal to draw from and are left for the user to fill
  in at confirm time.
- `## Revealed vs stated`: the revealed block under a
  `### revealed (observed-from-behavior)` subheading (per
  `contracts/user-model.md`'s heading text, reproduced verbatim), holding
  the five axis shares, the `unassigned` line, the separately-reported
  meeting shares, and the optional `embedding-similarity` line when given.

### Refusal on a confirmed file

`derive-user-model.sh` refuses to overwrite a `status: confirmed`
`user-model.md` — exit code 2, with the reason ("refusing to overwrite a
confirmed user-model.md; use --redraft to write a side-by-side draft")
written to stderr — **unless** `--redraft` is passed, in which case it
writes `user-model.draft.md` beside the existing confirmed file instead of
touching it. The confirmed file itself is only ever written by the confirm
step (`review-tiers.md` step 1) — `derive-user-model.sh` never writes
`status: confirmed` under any flag combination.

## Drafts are never read by judgment

Restating `contracts/user-model.md`'s pairing rule: only a `status:
confirmed` `user-model.md` is consumed by ranking, calibration, or the
judgment pass (`relationship-scoring.md`'s priors, `## Priors` item 1) — a
draft (whether `user-model.md` mid-draft or a side-by-side
`user-model.draft.md` from `--redraft`) exists solely to be shown to the
user for confirmation and is never read by any scoring or judgment step.

## Deterministic checkability

Given a fixture store (`people/`, `interactions/`, `stats.json` with
`calendar` flags, and Beeper-lane-tagged interactions for the personal-
channel heuristic), a checker can hand-verify, without judgment calls:

1. **Axis shares are recomputable by hand.** For each of the five axes
   plus `unassigned`, the interaction share and the meeting share match
   what a person counting kinded/unkinded people and their in-window
   interactions/meetings against the mapping table and heuristic above
   would get, rounded to two decimal places, summing to 1.00 (modulo
   rounding) across the six lines (five axes + `unassigned`).
2. **The draft validates under `validate-store.sh`.** The written
   `user-model.md` passes `contracts/user-model.md`'s pairing rule
   (`status: draft` + `provenance: observed-from-behavior` +
   `confirmed_at: null` + `revision: 0`) and has all four fixed body
   sections present, in order, per the contract's shape.
3. **Refusal behavior.** Running `derive-user-model.sh` against a store
   whose `user-model.md` has `status: confirmed`, without `--redraft`,
   exits 2 and leaves the confirmed file byte-identical; the same
   invocation with `--redraft` leaves the confirmed file byte-identical
   and writes a new, separate `user-model.draft.md`.

## Out of scope

- The confirm dialogue — presenting the draft, collecting axis/protected-
  time/season edits, writing `status: confirmed` — `review-tiers.md` step
  1.
- Embedding computation itself (model invocation, axis-description
  similarity scoring) — `embeddings.md` / `nearest-confirmed.sh
  --axis-similarity` (unit 8), consumed here only via the
  `--similarity-file` JSON contract above.
- `ranking-weights.json` prior seeding from a confirmed user-model
  (`packages/attention/scripts/calibrate.sh --seed-from-user-model`) —
  attention's script, invoked by `review-tiers.md` step 1, not owned by
  this spec.

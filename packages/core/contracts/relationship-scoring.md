# Contract: relationship scoring

`schema_version: 2.0.0`

## Purpose

Defines what a "judgment" produces when the system asks, of one person,
"what kind of relationship is this, and how much attention does it warrant
now?" — the kind vocabulary, the judgment record shape, the rules that bound
judgment (rigid numbers survive only as rules, never as estimates), how
priors are handed to the judgment, the required breakdown string, the
drift prefilter, and the optional warrant rescale. Nothing in this contract
is itself a store file — records live in ingestion run logs / debrief
transcripts; the persisted results are `person.md` kind fields (written via
`packages/core/scripts/person-set-kind.sh`) and confirmed tiers.

## Writers / readers

- Score/judgment records are produced by two call sites, neither of which
  writes the other's artifacts: ingestion's judgment pass (the suggestions
  step of the review-tiers skill, forward-declared) and attention's
  drift judgment (`## Drift prefilter` below).
- Ingestion's judgment pass may write `kind`/`kind_note`/`kind_source`/
  `kind_expires`/`kind_updated` to `people/<slug>.md` (`contracts/person.md`
  1.1.0) via `person-set-kind.sh`, and `tier`/`tier_source` (`contracts/
  person.md` 1.2.0) via `person-set-tier.sh` — both always as `derived`
  when unconfirmed (plan 31 D5, superseding plan 30 D2's "zero unconfirmed
  tier writes"). Only a user correction may write `tier_source:
  stated-by-user`, and it sticks (never overwritten by a later derived
  write).
- Attention's drift judgment writes no `person.md` field at all — it only
  *proposes* (a wake-up); see `## Drift prefilter`.

## Kind vocabulary (D3)

A small, deliberately non-rigid set — `kind_note` carries the nuance a
9-value enum cannot. The **horizon** column is a **prefilter only**: it
selects drift candidates for judgment; it is never a verdict and never
enters a score directly.

| kind | soft horizon (days, prefilter only) | notes |
|---|---|---|
| `friend` | 30 | real social relationship |
| `family` | 30 | |
| `collaborator` | 14 | active shared work (co-founder, teammate, client-in-flight) |
| `professional` | 120 | business relationship without live shared work |
| `community` | none | group/scene contact; user-participation decides warmth |
| `scheduling` | none | time-boxed logistics for one event/errand; **must carry `kind_expires`** (the event date or last-message + 14d) |
| `transactional` | none | vendor/service/support; no relationship rhythm |
| `unsolicited` | none | inbound pitch/cold contact the user never answered |
| `unknown` | none | insufficient evidence; judgment declines to guess |

`expired` is **not** a kind value — it is the read state of any person
whose `kind_expires` is in the past (`contracts/person.md`). Neutral
wording everywhere a kind or its expiry is surfaced: "scheduling contact —
event passed", never "dormant" or "neglected". This table is the single
source of truth for `validate-store.sh`, eval graders, and the
review-tiers skill prompt — do not restate or fork the vocabulary
elsewhere.

## Judgment record (D6)

One JSON object per person, emitted by the model judgment pass (either
ingestion's suggestion step or attention's drift judgment).

| Field | Type | Notes |
|---|---|---|
| `attention_warrant` | integer, 0–100 | "Given what this relationship is and who the user is, how much attention does it warrant now." |
| `suggested_tier` | `person.md` tier enum or `null` | One of `inner-circle`, `close`, `active`, `dormant`, or `null` if the insufficient-data gate applies. |
| `kind` | enum | One value from the kind vocabulary above. |
| `kind_note` | string, non-empty | The semantic rationale for the kind call. |
| `kind_expires` | ISO 8601 date | **Required when `kind: scheduling`**; optional otherwise. |
| `rationale` | string, ≤ 2 sentences | **Must cite at least one evidence field by name** (see `## Evidence inputs`) **and** the `kind`. |
| `confidence` | enum | One of `low`, `medium`, `high`. |

Example:

```json
{
  "attention_warrant": 22,
  "suggested_tier": "active",
  "kind": "scheduling",
  "kind_note": "Coordinating a single dinner reservation for Sept 12",
  "kind_expires": "2026-09-14",
  "rationale": "days_since_last=3 and touchpoints=4 all logistics for one event; kind=scheduling caps warrant.",
  "confidence": "high"
}
```

Ingestion validates the shape of every record (`check-judgment.sh`,
forward-declared) and rejects records that violate `## Rules` below. A
rejected record is re-judged **once**; if the retry also fails validation,
the person is shown as `kind: unknown` with the rejection reason attached
in the run log, and no tier suggestion is offered.

## Rules

Rigid numbers survive only as rules — never as estimates the judgment is
asked to reproduce. Everything not listed here is left to judgment.

- **Insufficient-data gate:** `touchpoints < 2` → no suggestion
  (`suggested_tier: null`, `kind: unknown` unless a kind was already
  stated).
- **Kind caps:** `kind` in `scheduling | transactional | unsolicited` never
  suggests above `active`; `kind: unknown` never suggests above `close`.
- **Expired kinds:** a `kind_expires` in the past forces
  `attention_warrant: 0` and no tier suggestion.
- **Unconfirmed tier writes are always derived (plan 31 D5, supersedes plan
  30 D2's asymmetry):** a `suggested_tier` may be written to `person.md`'s
  `tier` field without user confirmation, but only as `tier_source: derived`
  (via `person-set-tier.sh`) — the same provenance discipline as a derived
  `kind`. A derived write never overwrites a `tier_source: stated-by-user`
  tier; a judgment record that yields a tier write always carries
  `tier_source: derived`. A user correction writes `tier_source:
  stated-by-user` and sticks — never overwritten by a later derived pass.
- **Stated kinds are sticky:** a `kind_source: stated-by-user` value is
  never overwritten by a judgment record — the classification pass skips
  people whose current kind is user-stated.

## Evidence inputs (D4)

The judgment reads these named fields — defined here so a `rationale`
citation is checkable against a fixed vocabulary. Produced by
`packages/ingestion/scripts/derive-evidence.sh` (forward-declared),
read-only over `people/`, `interactions/`, `index.json`, `wakeups/` — never
`inbox/` or `archive/`.

`touchpoints`, `median_gap_days`, `days_since_last`, `meetings`,
`chat_days`, `emails`, `user_initiated_share`, `participation`,
`co_attended`, `upcoming`, `talking_points`, `tier`, `kind`.

## Priors (D6)

Handed to the judgment verbatim in the prompt, and named in every
breakdown string:

1. The confirmed user-model axis weights, protected time, and season
   (`contracts/user-model.md`).
2. `ranking-weights.json`'s `kinds` and `evidence` dimensions
   (`contracts/ranking-weights.md` 1.1.0, "Priors, not multipliers") —
   prior-strength hints the judgment must acknowledge: a weight `< 1.0`
   de-emphasizes, `> 1.0` emphasizes, e.g. `kinds.scheduling: 0.5` or
   `evidence.meeting: 1.5`.
3. Neighbor priors, when embeddings are available (`contracts/
   embeddings-index.md`): e.g. "most similar confirmed people:
   `[[dana]]` (friend, close), `[[sam]]` (collaborator)".

A prior **never** overrides a stated kind, a stated tier, or any rule in
`## Rules`.

## Breakdown string

Required on every suggestion and every drift proposal — the auditability
mechanism (a human reads this string, no code required). Exact format:

```
warrant: <0-100> | kind: <kind> (<kind_source>[, expires <date>]) — <kind_note ≤80c> | evidence: touchpoints=<n> median_gap_days=<n> days_since_last=<n> meetings=<n> chat_days=<n> participation=<v> | priors: user-model.<axis>=<w> (rev <n>[, protected]) kinds.<kind>=<w> evidence.<used keys>=<w> [| neighbors: [[slug]] (<kind>[, <tier>], confirmed) ...] | rationale: <text> | suggested: <tier>
```

This supersedes the seeding spec's `suggested: … | base: … | signals: …`
string. When embeddings are unavailable, the `neighbors:` segment is
omitted entirely and the run log separately records
`embeddings: unavailable`.

Worked example — a `scheduling` contact (low warrant, `active` suggested,
`kind_expires` set):

```
warrant: 22 | kind: scheduling (derived, expires 2026-09-14) — Coordinating a single dinner reservation for Sept 12 | evidence: touchpoints=4 median_gap_days=2 days_since_last=3 meetings=0 chat_days=3 participation=0.8 | priors: user-model.friends=0.3 (rev 1) kinds.scheduling=0.5 evidence.chat_day=1.0 | rationale: days_since_last=3 and touchpoints=4 all logistics for one event; kind=scheduling caps warrant. | suggested: active
```

## Drift prefilter (D7)

Attention's tier-drift step becomes two phases:

1. **Prefilter** — candidates are people with a rhythmed kind (soft
   horizon ≠ `none`), not expired, whose `days_since_last` exceeds that
   kind's soft horizon. An unkinded person uses `professional`'s horizon
   (120 days), and the resulting proposal discloses that substitution.
   People with a no-rhythm kind (`community`, `scheduling`,
   `transactional`, `unsolicited`, `unknown`) or an expired kind **never**
   enter the prefilter.
2. **Judgment** — the same judgment record (`## Judgment record`) asks
   "has this gone quiet for this kind of relationship, for this user?"
   and either drafts a quiet-drift wake-up proposal (carrying the
   breakdown string) or emits `no-drift` with a one-line reason.

**Upward drift** uses the same two-phase shape: the prefilter is
touchpoints in the last 90 days exceeding the current tier's expectation
(rhythmed kinds only, as judged); the judgment drafts an upward-drift
proposal or `no-drift`.

Proposal-only: attention writes no `tier` and no `kind` field, ever — it
only appends a wake-up entry the user confirms or dismisses, mirroring the
`profile.md`/`ranking-weights.json` propose-never-overwrite rule
(`docs/DECISIONS.md#preference-provenance`).

## Warrant rescale (D9)

`packages/ingestion/scripts/rescale-scores.sh` (forward-declared) is a
**permitted, user-invoked** post-processing step over a batch of judgment
records — never auto-applied, and it writes no store file itself (its
output feeds the review-tiers skill's confirmation step).

- `--report`: mean, median, spread, share ≥ 80, share ≤ 20 — overall and
  per kind; `skew: yes` when `share ≥ 80 > 0.5` or `share ≤ 20 > 0.5` or
  `spread < 10`, else `skew: no`.
- Re-center: shift-and-scale a batch to a target mean/spread, clamped to
  `[0, 100]`.
- `--rank`: percentile-band assignment in place of the raw shift-and-scale.
- Suggested tiers are recomputed from the rescaled warrants through the
  same `## Rules` caps (kind caps, expired-kind zeroing) — a rescale never
  bypasses a rule.
- Pure function: same input batch → same output batch. Ordering (relative
  rank between people) is preserved. Idempotent on already-centered input.

## Versioning

Additive changes (new evidence-input field name, new optional breakdown
segment) are a `schema_version` minor bump, same convention as
`ranking-weights.md`. Changing the meaning of the kind vocabulary, the
judgment record's field types, or any rule in `## Rules` is a major bump.
`2.0.0` = plan 31 D5 replaces the "zero unconfirmed tier writes" rule with
"unconfirmed tier writes are always `tier_source: derived`" (see
`## Rules` above and `docs/DECISIONS.md#derived-tiers-provisional`).

## Notes

- This contract does not restate `person.md`'s kind field shape
  (`kind`/`kind_note`/`kind_source`/`kind_expires`/`kind_updated`) — see
  `contracts/person.md` 1.1.0's "Kind vs. tier" section for the on-disk
  field definitions; this contract owns the vocabulary's meaning and the
  judgment process that produces values for those fields.
- `ranking-weights.md`'s `kinds`/`evidence` dimensions and this contract's
  kind vocabulary / evidence-input names must stay in lockstep — a kind or
  evidence key added here requires the matching key in
  `contracts/ranking-weights.md`'s dimension key lists, and vice versa.

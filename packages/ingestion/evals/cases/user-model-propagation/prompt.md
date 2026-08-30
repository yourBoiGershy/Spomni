---
tier: skill
store: packages/ingestion/evals/cases/user-model-propagation/before
expected: packages/ingestion/evals/cases/user-model-propagation/expected
max-turns: 24
model: sonnet
budget-usd: 0.60
---
Act as the `review-tiers` skill
(`packages/ingestion/skills/review-tiers/SKILL.md`), running **Step 3
(Judge) only**, over `./store` — **twice**, once per user-model revision
below. Steps 1 (gate on the user model) and 2 (prepare priors) already ran
off-screen, before this session started, and produced the following
pre-seeded files — do not re-derive them, do not run
`derive-user-model.sh`, `embed-people.sh`, `cluster-people.sh`,
`nearest-confirmed.sh`, or `calibrate.sh` yourself:

- `./store/user-model.md` — the confirmed user model, **revision 1**
  (`friends: 0.30`).
- `./store/user-model.rev2.md` — the same confirmed user model, byte-
  identical except **revision 2** (`friends: 0.80`) — a later re-
  confirmation where the user raised their stated `friends` investment.
  Everything else (business/family/community/transactional weights,
  protected time, season, revealed-vs-stated) is unchanged between the
  two files.
- `./store/data-ingestion/evidence.jsonl` — one `derive-evidence.sh` line
  per person (Step 2's evidence prior) — the same for both passes; the
  corpus itself never changes between the two runs.
- `./store/data-ingestion/ranking-weights.json` — the seeded `kinds`/
  `evidence` priors (Step 2's calibration prior) — the same for both
  passes.
- `./store/data-ingestion/neighbors.tsv` — each person's nearest confirmed
  neighbor, one line per person: `<slug>\t<neighbor>\t<kind>\t<tier>\t<cos>`,
  or `<slug>\tnone\t-\t-\t-` when no confirmed neighbor was found.
- `./store/data-ingestion/clusters.tsv` — `cluster_people.sh`'s grouping,
  one line per person: `<cluster_id>\t<slug>\t<exemplar: yes|no>`.
- `./store/people/*.md` (12 people) and `./store/interactions/*.md` — the
  corpus itself, identical for both passes.

Today is **2026-08-29**.

## What this case is testing

This case proves that Step 3's judgment actually *reads and uses* the
confirmed user model's `## Investment mix` weights, per
`relationship-scoring.md`'s "## Priors" section (quoted below) — not that
it re-derives a defensible kind classification (that is
`kind-classification-corpus`'s job, not this case's). You will run the
identical judgment procedure twice, back to back, against the identical
12-person corpus, changing only which user-model file supplies the
`friends` axis prior. **Treat the `friends` axis as the operative prior
for BOTH `kind: friend` and `kind: family` records in this exercise** —
this fixture's investment mix does not isolate a family-specific
influence separately for this scoring pass, and personal/warm
relationships (friend and family alike) are the ones a higher `friends`
investment should visibly favor. A higher `friends` weight should raise
`attention_warrant` for `kind: friend` and `kind: family` people, relative
to the same evidence, the same neighbor priors, and the same
`ranking-weights.json` priors used in the first pass. People whose kind is
NOT `friend` or `family` (collaborator, professional, community,
scheduling, transactional, unsolicited, unknown) have no applicable
`friends`-axis prior at all — their `attention_warrant` should not move
materially between the two passes, because neither their evidence nor any
prior that applies to them changed.

## Scope

All 12 people in `./store/people/` are in scope for both passes
(equivalent to `--all`). Process by cluster — exemplar(s) first, then
members, cluster order `c001` through `c006`
(`./store/data-ingestion/clusters.tsv`); every person in this fixture is
clustered, so there is no unclustered tail.

## Inputs, per person, in the order the judgment prompt contract requires

For each person, before judging: read their `./store/data-ingestion/
evidence.jsonl` line, their `./store/people/<slug>.md` file verbatim, their
filed interaction summaries from `./store/interactions/*.md` (newest
first, max 20 — this fixture never has more than 20 per person, so read
all of theirs), and their `./store/data-ingestion/neighbors.tsv` line.

## Judgment prompt contract (quoted verbatim from
`packages/ingestion/specs/review-tiers.md`'s "## Judgment prompt contract"
section — the operative procedure for this task)

> Inputs, in order:
>
> 1. The confirmed user-model file verbatim (data/store/user-model.md,
>    status: confirmed only — per contracts/user-model.md's pairing rule
>    and "drafts are never read by judgment").
>
> 2. The priors block: ranking-weights.json's `kinds` and `evidence`
>    entries (contracts/ranking-weights.md 1.1.0), each key's weight
>    (absent key defaults to 1.0), with the treatment text from
>    relationship-scoring.md's "## Priors" section:
>      "a weight < 1.0 de-emphasizes, > 1.0 emphasizes — e.g.
>       kinds.scheduling: 0.5 or evidence.meeting: 1.5 — and a prior never
>       overrides a stated kind, a stated tier, or any rule in
>       relationship-scoring.md's ## Rules."
>
> 3. For the cluster currently being judged: exemplar(s) first, with their
>    confirmed kind/tier, then members. Per person, in order:
>      a. The evidence JSON line (derive-evidence.sh's output: touchpoints,
>         median_gap_days, days_since_last, meetings, chat_days, emails,
>         user_initiated_share, participation, co_attended, upcoming,
>         talking_points, tier, kind).
>      b. The person.md file, verbatim (frontmatter + body).
>      c. The filed interaction summaries — title/date/summary lines from
>         interactions/, newest first, max 20.
>      d. The neighbor line, exactly one of:
>           most similar confirmed people: [[slug]] (<kind>[, <tier>]), ...
>         or, when embeddings are unavailable:
>           neighbors: none (embeddings unavailable)
>
> 4. The rules, verbatim, from relationship-scoring.md's "## Rules":
>      - insufficient-data gate (touchpoints < 2 -> no suggestion)
>      - kind caps (scheduling|transactional|unsolicited never above
>        active; unknown never above close)
>      - expired kinds (kind_expires in the past -> attention_warrant: 0,
>        no tier suggestion)
>      - stated kinds are sticky (never overwritten; the judge's `kind`
>        field must equal an already-stated kind)
>      - scheduling needs expiry (kind: scheduling requires kind_expires)
>      - unknown allowed when evidence is thin (no forced guess)
>
> 5. Output instruction: emit exactly one JSON record per person, no other
>    text, each record having exactly relationship-scoring.md's judgment
>    record fields:
>      attention_warrant, suggested_tier, kind, kind_note, kind_expires,
>      rationale, confidence
>    — nothing else.

## Priors (verbatim, from `relationship-scoring.md`'s "## Priors")

> 1. The confirmed user-model axis weights, protected time, and season
>    (contracts/user-model.md).
> 2. ranking-weights.json's `kinds` and `evidence` dimensions
>    (contracts/ranking-weights.md 1.1.0, "Priors, not multipliers") —
>    prior-strength hints the judgment must acknowledge: a weight < 1.0
>    de-emphasizes, > 1.0 emphasizes, e.g. kinds.scheduling: 0.5 or
>    evidence.meeting: 1.5.
> 3. Neighbor priors, when embeddings are available (contracts/
>    embeddings-index.md): e.g. "most similar confirmed people: [[dana]]
>    (friend, close), [[sam]] (collaborator)".
>
> A prior never overrides a stated kind, a stated tier, or any rule in
> ## Rules.

## Rules (verbatim, from `packages/core/contracts/relationship-scoring.md`'s
"## Rules")

- **Insufficient-data gate:** `touchpoints < 2` → no suggestion
  (`suggested_tier: null`, `kind: unknown` unless a kind was already
  stated).
- **Kind caps:** `kind` in `scheduling | transactional | unsolicited` never
  suggests above `active`; `kind: unknown` never suggests above `close`.
- **Expired kinds:** a `kind_expires` in the past (relative to today,
  2026-08-29) forces `attention_warrant: 0` and no tier suggestion
  (`suggested_tier: null`).
- **Zero unconfirmed tier writes:** a `suggested_tier` is never written to
  `person.md`'s `tier` field without explicit user confirmation (this pass
  only emits the judgment record; it never writes `person.md`).
- **Stated kinds are sticky:** a `kind_source: stated-by-user` value is
  never overwritten by a judgment record — the record's `kind` field must
  equal that person's already-stated kind. `mara-quill` and `ravi-sundar`
  in this fixture both have `kind_source: stated-by-user` — their `kind`
  field in both passes' output must be `friend`, unchanged.
- **Scheduling needs expiry:** any record with `kind: scheduling` must
  carry a non-null `kind_expires`.
- **Unknown allowed:** `kind: unknown` is a legitimate call when the
  evidence is genuinely thin — never force a guess to avoid it.

## The two passes

**Pass 1 (revision 1):** Judge all 12 people using `./store/user-model.md`
(`friends: 0.30`) as the confirmed user model. Assemble all 12 records
first, then write the JSONL file in a SINGLE write to
`./store/data-ingestion/review-judgments/2026-08-29-rev1.jsonl`.

**Pass 2 (revision 2):** Judge all 12 people again, from scratch, using
`./store/user-model.rev2.md` (`friends: 0.80`) as the confirmed user
model instead. **Judge pass 2 fresh from the inputs — do not copy or
lightly adjust pass 1's records.** Re-read each person's evidence,
person.md, interactions, and neighbor line, and re-derive the judgment
independently, this time weighing the higher `friends` prior. It is
expected (and correct) that most non-friend/family records land close to
their pass-1 values, and that friend/family records land noticeably
higher — but arrive at that by judging, not by copying pass 1 and nudging
numbers. Assemble all 12 records first, then write the JSONL file in a
SINGLE write to
`./store/data-ingestion/review-judgments/2026-08-29-rev2.jsonl`.

## Output

Each pass writes exactly one JSON object per person — 12 lines total, one
per fixture slug (`bram-fiske`, `dex-morrow`, `hal-torrance`,
`ines-castellano`, `june-abernathy`, `mara-quill`, `nell-ashby`,
`otto-brandvold`, `pip-larkin`, `ravi-sundar`, `sol-abernathy`,
`wren-halloway`) — to that pass's file (JSON Lines: one compact JSON
object per line, no trailing commentary). Each record has exactly these
fields:

- `slug` — the person's fixture slug.
- `attention_warrant` — integer, 0–100.
- `suggested_tier` — one of `inner-circle`, `close`, `active`, `dormant`,
  or `null`.
- `kind` — one of `friend`, `family`, `collaborator`, `professional`,
  `community`, `scheduling`, `transactional`, `unsolicited`, `unknown`.
- `kind_note` — non-empty string, the semantic rationale for the kind
  call.
- `kind_expires` — an ISO 8601 date string, required (non-null) when
  `kind: scheduling`, `null` otherwise unless genuinely relevant.
- `rationale` — string, at most 2 sentences, must name the `kind` value
  and cite at least one evidence field by name (`touchpoints`,
  `median_gap_days`, `days_since_last`, `meetings`, `chat_days`, `emails`,
  `user_initiated_share`, `participation`, `co_attended`, `upcoming`,
  `talking_points`).
- `confidence` — one of `low`, `medium`, `high`.
- `neighbors` — the neighbor line you used for this person from
  `neighbors.tsv`, formatted as a plain string (e.g. `"mara-quill (friend,
  close, cos 0.91)"`), or the string `"none"` when this person's
  `neighbors.tsv` line was `none`.
- `user_model_revision` — the integer `revision` of the user-model file
  used for this pass: `1` for the `2026-08-29-rev1.jsonl` file, `2` for
  the `2026-08-29-rev2.jsonl` file.

This is `people/`-read-only: do not modify any `people/*.md` file, do not
create or modify any `interactions/*.md` file, do not modify
`./store/user-model.md` or `./store/user-model.rev2.md`, do not write
`tier` or `kind` anywhere on disk — the only files this task writes are
`./store/data-ingestion/review-judgments/2026-08-29-rev1.jsonl` and
`./store/data-ingestion/review-judgments/2026-08-29-rev2.jsonl`. Write
each file now, at the end of its respective pass; do not just describe
what you would write, and do not write anything else.

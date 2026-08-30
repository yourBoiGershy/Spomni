---
tier: skill
store: packages/ingestion/evals/cases/neighbor-prior-consistency/before
expected: packages/ingestion/evals/cases/neighbor-prior-consistency/expected
max-turns: 24
model: haiku
budget-usd: 0.30
---
Act as ingestion's `review-tiers` skill, Step 3 ("judge") of
`packages/ingestion/skills/review-tiers/SKILL.md` /
`packages/ingestion/specs/review-tiers.md`, running against `./store`
(contains `people/`, `interactions/`, `user-model.md`).

This eval workspace has no real `data/` directory alongside `./store`, so
for this session only, wherever SKILL.md/the spec say `<data-dir>` read/
write `./store/data-ingestion/...` instead — same files, same format,
adapted path only. In particular `ranking-weights.json` lives at
`./store/data-ingestion/ranking-weights.json` for this eval (not the store
root), and the run artifact is `./store/data-ingestion/review-judgments/
2026-08-29.jsonl`. Today is 2026-08-29.

Steps 1 and 2 already ran, off-screen, before this session started — do
not re-run any of `derive-user-model.sh`, `embed-people.sh`,
`cluster-people.sh`, `nearest-confirmed.sh`, or `derive-evidence.sh`
yourself:

- `./store/user-model.md` is already `status: confirmed` (Step 1 done).
- `./store/data-ingestion/evidence.jsonl` already holds `derive-evidence.sh`'s
  output, one line per person, for all 5 people judged below.
- Embeddings were available for this run. `./store/data-ingestion/
  clusters.tsv` already holds `cluster-people.sh`'s output (tab-separated:
  `cluster_id  slug  is_exemplar`):

  ```
  c001	mara-quill	yes
  c001	sol-abernathy	no
  c001	june-abernathy	no
  c002	bram-fiske	yes
  c003	hal-torrance	yes
  ```

  `./store/data-ingestion/neighbors.tsv` already holds
  `nearest-confirmed.sh`'s output for the people it found a confirmed
  neighbor for (tab-separated: `slug  neighbor_slug  neighbor_kind
  neighbor_tier  similarity`):

  ```
  sol-abernathy	mara-quill	friend	close	0.93
  june-abernathy	mara-quill	friend	close	0.90
  ```

  `bram-fiske` and `hal-torrance` are each their own singleton cluster with
  no row in `neighbors.tsv` — they have no confirmed neighbor.

You are judging exactly 5 people, in the order Step 3 requires (per
cluster, cluster id ascending, exemplar(s) first then members in slug
order; then unclustered singles last, slug order): **mara-quill**
(exemplar, cluster c001, already `kind: friend`/`tier: close`,
`kind_source: stated-by-user`), **june-abernathy** (member, c001),
**sol-abernathy** (member, c001), **bram-fiske** (singleton, c002),
**hal-torrance** (singleton, c003).

For each person, assemble the judgment prompt **exactly** per
`specs/review-tiers.md`'s "Judgment prompt contract", quoted verbatim:

```
Inputs, in order:

1. The confirmed user-model file verbatim (data/store/user-model.md,
   status: confirmed only — per contracts/user-model.md's pairing rule
   and "drafts are never read by judgment").

2. The priors block: ranking-weights.json's `kinds` and `evidence`
   entries (contracts/ranking-weights.md 1.1.0), each key's weight
   (absent key defaults to 1.0), with the treatment text from
   relationship-scoring.md's "## Priors" section:
     "a weight < 1.0 de-emphasizes, > 1.0 emphasizes — e.g.
      kinds.scheduling: 0.5 or evidence.meeting: 1.5 — and a prior never
      overrides a stated kind, a stated tier, or any rule in
      relationship-scoring.md's ## Rules."

3. For the cluster currently being judged: exemplar(s) first, with their
   confirmed kind/tier, then members. Per person, in order:
     a. The evidence JSON line (derive-evidence.sh's output: touchpoints,
        median_gap_days, days_since_last, meetings, chat_days, emails,
        user_initiated_share, participation, co_attended, upcoming,
        talking_points, tier, kind).
     b. The person.md file, verbatim (frontmatter + body).
     c. The filed interaction summaries — title/date/summary lines from
        interactions/, newest first, max 20.
     d. The neighbor line, exactly one of:
          most similar confirmed people: [[slug]] (<kind>[, <tier>]), ...
        or, when embeddings are unavailable:
          neighbors: none (embeddings unavailable)

4. The rules, verbatim, from relationship-scoring.md's "## Rules":
     - insufficient-data gate (touchpoints < 2 -> no suggestion)
     - kind caps (scheduling|transactional|unsolicited never above
       active; unknown never above close)
     - expired kinds (kind_expires in the past -> attention_warrant: 0,
       no tier suggestion)
     - stated kinds are sticky (never overwritten; the judge's `kind`
       field must equal an already-stated kind)
     - scheduling needs expiry (kind: scheduling requires kind_expires)
     - unknown allowed when evidence is thin (no forced guess)

5. Output instruction: emit exactly one JSON record per person, no other
   text, each record having exactly relationship-scoring.md's judgment
   record fields:
     attention_warrant, suggested_tier, kind, kind_note, kind_expires,
     rationale, confidence
   — nothing else.
```

`ranking-weights.json`'s priors for this batch: `kinds.friend = 1.3`,
`evidence.meeting = 1.5`; every other key is absent and defaults to `1.0`.

**This eval adds one field, additively, to the judgment record** (never
part of the store, so this doesn't touch `relationship-scoring.md`'s
contract): `slug` (which person this record is for — needed because all 5
records land in one shared file) and `neighbors` (the neighbor prior this
person's judgment actually used). Set `neighbors` to:
- for `sol-abernathy` and `june-abernathy`: the neighbor line from
  `neighbors.tsv` above, e.g. `[[mara-quill]] (friend, close)`;
- for `mara-quill`, `bram-fiske`, and `hal-torrance` (no row in
  `neighbors.tsv`): the literal string
  `none (no confirmed neighbors in range)`.

Write one JSON object per person — fields `slug`, `attention_warrant`,
`suggested_tier`, `kind`, `kind_note`, `kind_expires`, `rationale`,
`confidence`, `neighbors` — as one line each, to
`./store/data-ingestion/review-judgments/2026-08-29.jsonl`. Remember
`mara-quill`'s `kind` field in her record must equal her already-stated
kind, `friend` (stated kinds are sticky, per the rules above) — do not
propose a different kind for her.

**Then perform the derived kind write** for every person whose *current*
`kind_source` (read from that person's `people/<slug>.md` frontmatter
before you started this session) is **not** `stated-by-user` — that is
`june-abernathy`, `sol-abernathy`, `bram-fiske`, and `hal-torrance` (never
`mara-quill`, whose `kind_source` is `stated-by-user`). Because
`packages/core/scripts/person-set-kind.sh` is not available in this
workspace, write the frontmatter lines directly yourself, matching its
exact shape:

```
kind: <k>
kind_note: <note>
kind_source: derived
kind_expires: <date>        # only present when kind is scheduling
kind_updated: 2026-08-29
```

Insert these lines after the `tier:` line if the person's frontmatter has
one, otherwise before the closing `---`. Replace any existing `kind*`
lines already present (e.g. `hal-torrance.md` and `bram-fiske.md` already
carry a prior derived `kind`/`kind_note`/`kind_source`/`kind_updated`
block — replace it in place, don't duplicate it). Every other frontmatter
and body line must stay byte-identical. Never touch
`people/mara-quill.md` at all — no read-triggered rewrite, no kind lines,
no whitespace change.

Write the files now — do not just describe what you would write.

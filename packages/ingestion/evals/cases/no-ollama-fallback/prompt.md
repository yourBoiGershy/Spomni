---
tier: skill
store: packages/ingestion/evals/cases/no-ollama-fallback/before
expected: packages/ingestion/evals/cases/no-ollama-fallback/expected
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
- `./store/data-ingestion/run.log` records that `embed-people.sh` and
  `cluster-people.sh` both printed `embeddings: unavailable` for this
  run (Ollama was not reachable). Per SKILL.md's "Both Ollama modes"
  section: when this happens, `nearest-confirmed.sh` is never run, there
  is no `neighbors.tsv`/`clusters.tsv` (neither file exists in `./store/
  data-ingestion/` — this is expected, not missing data you should try to
  reconstruct), clustering is a no-op, and **every** in-scope person is
  judged individually, in slug order, as if each were its own
  unclustered singleton. This flow never stalls or errors on this
  condition — it degrades exactly as documented and keeps going.

You are judging exactly 5 people, unclustered, in slug order:
**bram-fiske**, **hal-torrance**, **june-abernathy**, **mara-quill**
(already `kind: friend`/`tier: close`, `kind_source: stated-by-user`),
**sol-abernathy**.

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

Because embeddings are unavailable, input 3d's neighbor line is, for
**every** person, the literal string `neighbors: none (embeddings
unavailable)` — never guess or invent a neighbor, and never mention any
other person's slug as if they were a neighbor.

**This eval adds one field, additively, to the judgment record** (never
part of the store, so this doesn't touch `relationship-scoring.md`'s
contract): `slug` (which person this record is for — needed because all 5
records land in one shared file) and `neighbors` (the neighbor prior this
person's judgment actually used — here, always the literal string `none
(embeddings unavailable)`, matching input 3d above exactly).

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

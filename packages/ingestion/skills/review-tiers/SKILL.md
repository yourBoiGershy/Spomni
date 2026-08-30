---
name: review-tiers
description: User-invoked review of relationship kinds and tiers — derives evidence, judges kind + attention warrant with priors (user model, ranking weights, nearest confirmed neighbors when local embeddings are available), presents one capped batch with breakdowns; never writes a tier without explicit per-person confirmation; never runs unprompted.
---

# Review tiers

Sequences `packages/ingestion/specs/review-tiers.md` end to end: gate on a
confirmed user model, prepare priors, judge each in-scope person with the
model, validate every record before it is written or shown, present at
most 20 suggestions with breakdown strings, and write only what the user
explicitly confirms or adjusts. This document is the session's runbook;
the spec is the model of record — where this document and the spec
disagree, the spec wins. `packages/core/contracts/relationship-scoring.md`
is the model of record for the judgment record shape, the kind vocabulary,
the rules (gate/caps/expiry/sticky-stated), and the breakdown string.

Invoked explicitly only ("review tiers" / "review kinds"). It is not a
scheduled job, it never runs unprompted, and it never re-runs the one-time
onboarding seed (`skills/onboarding-seed/`) itself.

## Binding rules (restated from the spec — read before running)

- **User-invoked only, never on a schedule.** Nothing in this flow
  triggers itself; every run starts from an explicit user request.
- **Zero tier writes without confirmation.** Steps 1–3 derive, judge, and
  validate; nothing is written to a person's `tier` field until that
  person is confirmed or adjusted in Step 4. Confirm and adjust are both,
  at the filing layer, the same event: an explicit user-stated tier value.
- **Stated kinds are never overwritten.** A person whose current
  `kind_source: stated-by-user` is still judged (a warrant/tier suggestion
  may still be offered), but the judgment record's `kind` field must equal
  that person's already-stated kind — `check-judgment.sh`'s
  `stated-kind-changed` check rejects a record that disagrees, and the
  judge does not propose a different kind for a stated person.
- **Derived kinds ARE written**, labeled `derived`, via
  `packages/core/scripts/person-set-kind.sh <store> <slug> --kind .. --note
  .. --source derived [--expires ..] --today ..` — the only path this flow
  uses to write `kind`/`kind_note`/`kind_source`/`kind_expires`/
  `kind_updated` prior to user confirmation.
- **The judge never opens `inbox/` or `archive/`.** Its only corpus inputs
  are `derive-evidence.sh`'s output, `people/<slug>.md`, and filed
  interaction summaries — the same read-only scope
  `relationship-scoring.md`'s `## Evidence inputs` names.
- **No-guilt framing, including neutral wording for expired / no-rhythm
  kinds.** Say "scheduling contact — event passed", never "neglected" or
  "dormant" used as a verdict. A low-warrant or dormant suggestion is a
  neutral read of observed behavior, not a judgment on the user or the
  relationship.
- **One session, no backlog, 20-cap.** All suggestions from a given
  invocation are batched and presented together, capped at 20; nothing
  left over is queued for a follow-up prompt. Ending the session mid-batch
  is treated as a skip for everyone not yet acted on — never resurfaced
  automatically.
- **The 2026-08-29 all-skip onboarding batch** (and any other skipped
  batch) is re-presented only via `--all` or `--include-skipped` — this
  flow never re-prompts on its own.

## Invocation & flags

```
review tiers [--all | --unkinded | --person <slug>] [--include-skipped] [--rescale] [--today <YYYY-MM-DD>]
```

- `--all` — widen scope to every person in the store with at least one
  interaction, including already-kinded people (re-judgment, not
  re-tiering — the stated-kind rule above still applies).
- `--unkinded` (default) — people with no `kind` field at all (a person
  with `kind: unknown` already has a kind value and is NOT in this default
  scope; use `--all` or `--person` to reach them).
- `--person <slug>` — scope to exactly one person.
- `--include-skipped` — re-admit people present in the skip ledger
  (`data/ingestion/review-skips.log`) who would otherwise be excluded from
  the scoped batch.
- `--rescale` — pre-authorize the skew-triggered re-center in Step 4
  instead of asking mid-session (still only applied when `--report` shows
  `skew: yes`; never applied on an unskewed batch).
- `--today <YYYY-MM-DD>` — override "today" for every script this flow
  invokes (tests only; default omitted, letting each script use its own
  `date -u +%Y-%m-%d` default).

## Step 1 — gate on the user model

Nothing else in this flow proceeds while `<store>/user-model.md` is
absent or `status: draft`.

```sh
bash packages/ingestion/scripts/derive-user-model.sh <store> --today <today>
```

If this writes (or the existing file already is) `status: draft`, run the
confirm dialogue now:

1. Show the user the `## Revealed vs stated` block's `revealed
   (observed-from-behavior):` lines verbatim (the five axis shares, the
   `unassigned` line, the meeting shares, and the `embedding-similarity`
   line if present).
2. Ask, per axis line in `## Investment mix`, whether to keep the
   initialized weight/rationale or replace it; same for `## Protected
   time` and `## Season` (both start empty — invite freeform text, with
   the optional trailing `until: <YYYY-MM-DD>` on Season).
3. On confirmation, write the file directly (this skill edits the
   frontmatter/body in place — `derive-user-model.sh` never writes
   `status: confirmed` itself): set `status: confirmed`, `provenance:
   stated-by-user`, `confirmed_at: <today>`, bump `revision` (0→1 the
   first time; +1 on every subsequent reconfirm). The revealed block is
   never overwritten or removed — it stays labeled
   `revealed (observed-from-behavior)` for audit; only the `##
   Investment mix` lines above it become the confirmed source of truth.
4. Validate the write:

   ```sh
   bash packages/core/scripts/validate-store.sh <store>
   ```

5. Seed priors from the freshly-confirmed model:

   ```sh
   bash packages/attention/scripts/calibrate.sh --seed-from-user-model <store>
   ```

   `calibrate.sh` is attention's script — invoked here, never edited
   (single-writer rule: `ranking-weights.json` stays attention's alone).
   If `--seed-from-user-model` isn't available yet (this flag lands with
   attention's own plan-30 unit, which may not have shipped when this flow
   first runs), log `seed: skipped (calibrate.sh --seed-from-user-model
   unavailable)` and continue — Step 3's priors then simply read every
   `kinds.*`/`evidence.*` weight as its 1.0 default (absent key).

If `user-model.md` was already `status: confirmed` when this step started,
skip the confirm dialogue and the seed call entirely — proceed straight to
Step 2.

## Step 2 — prepare priors

**Resolve scope** (before running any of the three scripts below):

- `--unkinded` (default): every `people/<slug>.md` with no `kind` field at
  all.
- `--all`: every person with >= 1 interaction (`stats.json`'s
  `people[slug].touchpoints >= 1`, or equivalently anyone with a
  `people/<slug>.md` file that `build-stats.sh` reports touchpoints for).
- `--person <slug>`: exactly that slug.
- In every case, minus the skip ledger (`data/ingestion/review-skips.log`)
  unless `--include-skipped` is also given. Write the resolved slug list,
  one per line, to a scratch scope file for the `--scope` flags below.

```sh
bash packages/ingestion/scripts/embed-people.sh <store> --scope <scope-file> --today <today>
```

If this prints `embeddings: unavailable`, record that and continue — the
rest of this flow runs without embedding priors (neighbor lines become
`neighbors: none (embeddings unavailable)`, see "Both Ollama modes"
below).

```sh
bash packages/ingestion/scripts/cluster-people.sh <store> --scope <scope-file>
```

Also prints `embeddings: unavailable` (and writes nothing, exits 0) under
the same condition — in that case every in-scope person is judged
individually, in slug order, as if each were its own unclustered singleton
(see Step 3's ordering rule).

```sh
bash packages/ingestion/scripts/nearest-confirmed.sh <store> <slug> --k 3
```

Run once per in-scope person (only when embeddings are available — skip
entirely, and use the `neighbors: none (embeddings unavailable)` line
instead, when `embed-people.sh`/`cluster-people.sh` reported
`embeddings: unavailable`).

Finally, evidence for the whole scope in one call:

```sh
bash packages/ingestion/scripts/derive-evidence.sh <store> --today <today> \
  --config <data-dir>/config/onboarding-backfill.tsv
```

Keep this JSONL — it is both the judge's per-person evidence input (Step
3) and `check-judgment.sh`'s `--evidence` argument (Step 3) and is never
refetched mid-batch.

## Step 3 — judge

Order: **per cluster** (`cluster-people.sh`'s output, cluster id
ascending — exemplar member first, then the rest in slug order), **then
unclustered people last, slug order** (including every in-scope person
when `embeddings: unavailable` made clustering a no-op).

For each person, assemble the judgment prompt **exactly** per
`specs/review-tiers.md`'s "Judgment prompt contract" — copied verbatim
below (this flow's implementation must match this fenced block; if the
two ever disagree, `specs/review-tiers.md` wins):

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

Read `ranking-weights.json`'s `kinds`/`evidence` dimensions once for the
whole batch (an absent file, or an absent key inside it, reads as `1.0`
for that key — never an error, never a skip).

Append each emitted record as one line to the run artifact:

```
<data-dir>/ingestion/review-judgments/<today>.jsonl
```

(new per-run file, ingestion-owned, lives under the gitignored data dir —
not the store).

Then validate the whole batch before anything is written or shown:

```sh
bash packages/ingestion/scripts/check-judgment.sh <data-dir>/ingestion/review-judgments/<today>.jsonl \
  --today <today> --evidence <evidence.jsonl>
```

For every `reject:<reason>` line: re-judge that one person **once** (same
prompt, with the rejection reason appended as an extra instruction to
correct). If the retry also fails `check-judgment.sh`, present that person
as `kind: unknown` with the rejection reason attached, offer no tier
suggestion for them, and do not write any kind field for them — this
matches `relationship-scoring.md`'s retry rule verbatim.

**Derived kind writes** (before presentation, only for accepted records):
for every accepted record whose person's *current* `kind_source` is not
already `stated-by-user`,

```sh
bash packages/core/scripts/person-set-kind.sh <store> <slug> \
  --kind <kind> --note <kind_note> --source derived \
  [--expires <kind_expires>] --today <today>
```

A person whose current `kind_source` is already `stated-by-user` gets no
`person-set-kind.sh` call here at all (their `kind` field is untouched
until/unless Step 4's confirm/adjust explicitly restates it).

## Step 4 — skew check + present

```sh
bash packages/ingestion/scripts/rescale-scores.sh <data-dir>/ingestion/review-judgments/<today>.jsonl --report
```

If the overall row reads `skew: yes`, print this warning, exact wording
(`<reason>` = whichever condition tripped — `share_ge_80 > 0.5`,
`share_le_20 > 0.5`, or `spread < 10`; `<m>` = the overall mean;
`<share>` = whichever share triggered it, as a percentage):

```
Warrant distribution is skewed (<reason>): mean <m>, <share>% ≥ 80. Re-center with `--rescale`? Suggestions below are shown un-rescaled.
```

Only if the user passed `--rescale` at invocation, or answers yes to this
prompt now, replace the batch:

```sh
bash packages/ingestion/scripts/rescale-scores.sh <data-dir>/ingestion/review-judgments/<today>.jsonl --rescale --today <today>
```

and append `| rescaled: <from>→<to>` (using that record's `rescaled_from`
and its new `attention_warrant`) to each of that record's breakdown
strings below. A batch shown without `--rescale` never carries this
segment. `--rescale` is never auto-applied on a skewed batch that the user
hasn't explicitly authorized (at invocation or in this prompt).

Build each presented person's breakdown string exactly per
`relationship-scoring.md`'s `## Breakdown string`:

```
warrant: <0-100> | kind: <kind> (<kind_source>[, expires <date>]) — <kind_note ≤80c> | evidence: touchpoints=<n> median_gap_days=<n> days_since_last=<n> meetings=<n> chat_days=<n> participation=<v> | priors: user-model.<axis>=<w> (rev <n>[, protected]) kinds.<kind>=<w> evidence.<used keys>=<w> [| neighbors: [[slug]] (<kind>[, <tier>], confirmed) ...] | rationale: <text> | suggested: <tier>
```

omitting the `neighbors:` segment entirely when embeddings were
unavailable for that person (record `embeddings: unavailable` in the run
summary instead — see Step 5).

**Present at most 20** records, ordered `attention_warrant` descending,
then `days_since_last` ascending, then slug ascending — records beyond
the cap are left untouched exactly like a skip, not queued for later.
Never frame a low-warrant, dormant, expired, or no-rhythm suggestion as a
verdict — use the neutral wording above ("scheduling contact — event
passed"), never "neglected."

Per person, one of three explicit actions:

- **Confirm** — accept the suggested kind and/or tier as-is.
- **Adjust** — pick a different kind and/or a different tier value (not
  restricted to an adjacent one; the suggestion is a starting point, not a
  constraint).
- **Skip** — no write for this person, this pass.

Confirm or adjust writes, in this order:

1. The tier, via `specs/stated-preference-filing.md` (a).2 — the same
   unambiguous existing-person frontmatter `tier` overwrite
   `onboarding-seed` uses (every presented slug already resolved out of
   `stats.json`/`people/`, never free text; (a).4's new-person flow only
   applies as a fallback if a presented slug's person file is somehow
   missing at write time).
2. The kind, via:

   ```sh
   bash packages/core/scripts/person-set-kind.sh <store> <slug> \
     --kind <confirmed-or-adjusted-kind> --note <note> \
     --source stated-by-user --today <today>
   ```

   — overriding any `derived` kind Step 3 may have written for that
   person, since an explicit confirm/adjust is now a user statement.

Skip appends one line to the skip ledger (sole writer this skill,
append-only, tab-separated):

```
<data-dir>/ingestion/review-skips.log
```

format: `<slug>\t<ISO 8601 Z>`.

Ending the session mid-batch is a skip for every not-yet-acted-on person
in this pass — never logged (only an explicit skip action writes a skip
ledger line), never resurfaced automatically (only `--all` /
`--include-skipped` re-admits them on a later, explicit invocation).

## Step 5 — close

```sh
bash packages/core/scripts/build-index.sh <store>
bash packages/core/scripts/validate-store.sh <store>
```

## Both Ollama modes

- **Embeddings available:** `embed-people.sh`/`cluster-people.sh` run
  normally; `nearest-confirmed.sh <store> <slug> --k 3` is called per
  in-scope person and its neighbor line (`most similar confirmed people:
  [[slug]] (<kind>[, <tier>]), ...`) is included in the judgment prompt
  (input 3d) and, when non-empty, in the presented breakdown string's
  `| neighbors: ...` segment.
- **Embeddings unavailable:** any of `embed-people.sh`, `cluster-people.sh`,
  or `nearest-confirmed.sh` printing `embeddings: unavailable` means the
  judgment prompt's neighbor line becomes the literal `neighbors: none
  (embeddings unavailable)` for every affected person, the presented
  breakdown string omits its `| neighbors: ...` segment entirely, and the
  Step 5 summary records `embeddings: unavailable` — the flow never stalls
  or errors on this condition, it degrades exactly as each script's own
  usage header documents.

## Summary

End with a short summary, counts only (no per-person callouts of
skipped/excluded people, per the no-guilt rule):

- Whether the user-model gate was already confirmed, or was confirmed in
  this session (and, if so, the new `revision` number).
- Scope resolved (flag used, count of people in scope, count excluded by
  the skip ledger unless `--include-skipped`).
- Embeddings available or not (`embeddings: unavailable` if so).
- How many records were judged, how many rejected-then-retried, how many
  ended up presented as `kind: unknown` after a failed retry.
- Skew: `yes`/`no`, and whether `--rescale` was applied.
- How many presented (capped at 20 if more cleared), how many
  confirmed / adjusted / skipped in this session.

---
name: review-tiers
description: User-invoked review of relationship kinds and tiers — cold-starts the user model with no dialogue, derives evidence, judges kind + attention warrant with priors (user model, ranking weights, nearest confirmed neighbors when local embeddings are available), writes derived kinds and derived tiers directly, and presents a capped correction digest; a stated kind/tier always outranks a derived one and the user may correct any line at any time; never runs unprompted.
---

# Review tiers

Sequences `packages/ingestion/specs/review-tiers.md` end to end:
cold-start-adopt the user model with no dialogue, prepare priors, judge
each in-scope person with the model, validate every record before it is
written, write the derived kind and derived tier directly, and present a
capped correction digest — the user corrects, now or later, rather than
confirming before anything is written. This document is the session's
runbook; the spec is the model of record — where this document and the
spec disagree, the spec wins. `packages/core/contracts/relationship-
scoring.md` is the model of record for the judgment record shape, the
kind vocabulary, and the rules (gate/caps/expiry/sticky-stated).

Invoked explicitly only ("review tiers" / "review kinds"). It is not a
scheduled job, it never runs unprompted, and it never re-runs the one-time
onboarding seed (`skills/onboarding-seed/`) itself.

## Binding rules (restated from the spec — read before running)

- **User-invoked only, never on a schedule.** Nothing in this flow
  triggers itself; every run starts from an explicit user request.
- **Derived tier writes ARE made (plan 31 D5, supersedes the old "zero
  tier writes without confirmation" rule).** Step 3 derives, judges,
  validates, and writes both the derived kind and the derived tier for
  every accepted record — labeled `tier_source: derived` /
  `kind_source: derived` — with no per-person prompt. A `--source
  derived` write never overwrites a `tier_source: stated-by-user` value
  (`person-set-tier.sh` exits `2`, logged "kept stated," not an error).
  Step 4 is a correction digest, not a confirm gate: a correction is, at
  the filing layer, an explicit user-stated tier/kind value, and it
  always outranks whatever step 3 derived.
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
- **One session, no backlog, 20-cap.** All derived writes from a given
  invocation happen together (step 3, before presentation); the
  correction digest (step 4) shows at most 20 lines, ordered
  `attention_warrant` descending then `days_since_last` ascending then
  slug ascending — people beyond the cap are already derived-written,
  simply not digested this run, never queued for a follow-up prompt.
  Ending the session mid-digest changes nothing already written; nothing
  is resurfaced automatically except via a later `--all` /
  `--include-skipped` invocation.
- **The 2026-08-29 all-skip onboarding batch** (and any other skipped
  batch) is re-presented only via `--all` or `--include-skipped` — this
  flow never re-prompts on its own.

## Invocation & flags

```
review tiers [--all | --unkinded | --person <slug>] [--include-skipped] [--rescale] [--confirm-model] [--today <YYYY-MM-DD>]
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
- `--confirm-model` — run the confirm dialogue (below) regardless of the
  user-model's current status, and only that dialogue; it does not also
  run steps 2–4. This is the sole way this flow ever writes `status:
  confirmed` — the default path (no flag) never asks and never confirms,
  it only ever adopts `provisional`.

## Step 1 — gate on the user model (cold-start adoption, plan 31 D6)

Default path (no `--confirm-model` flag): **no dialogue, ever.** If
`<store>/user-model.md` is absent or `status: draft`:

```sh
bash packages/ingestion/scripts/derive-user-model.sh <store> --today <today>
```

then set `status: provisional` on that file in place (this skill edits
the frontmatter directly — `derive-user-model.sh` never writes
`provisional` itself): `revision` stays `0`, `provenance` stays
`observed-from-behavior`, `derived_at: <today>`. No question is asked.
Then:

```sh
bash packages/core/scripts/validate-store.sh <store>
bash packages/attention/scripts/calibrate.sh --seed-from-user-model <store>
```

`calibrate.sh` is attention's script — invoked here, never edited
(single-writer rule: `ranking-weights.json` stays attention's alone).
`--seed-from-user-model` accepts `confirmed` or `provisional`. If
`--seed-from-user-model` isn't available yet, log `seed: skipped
(calibrate.sh --seed-from-user-model unavailable)` and continue — Step
3's priors then simply read every `kinds.*`/`evidence.*` weight as its
1.0 default (absent key).

If `user-model.md` was already `status: provisional` or `status:
confirmed` when this step started, skip straight to Step 2 — no
re-derive, no dialogue, no re-seed.

### `--confirm-model` mode

Only when the user explicitly invokes `review tiers --confirm-model` does
this flow run the confirm dialogue below. This mode runs **only** this
dialogue — it does not also run Steps 2–4 in the same invocation.

1. Show the user the `## Revealed vs stated` block's `revealed
   (observed-from-behavior):` lines verbatim (the five axis shares, the
   `unassigned` line, the meeting shares, and the `embedding-similarity`
   line if present).
2. Ask, per axis line in `## Investment mix`, whether to keep the
   initialized weight/rationale or replace it; same for `## Protected
   time` and `## Season` (both start empty — invite freeform text, with
   the optional trailing `until: <YYYY-MM-DD>` on Season).
3. On confirmation, write the file directly: set `status: confirmed`,
   `provenance: stated-by-user`, `confirmed_at: <today>`, bump `revision`
   (0→1 the first time; +1 on every subsequent reconfirm). The revealed
   block is never overwritten or removed — it stays labeled `revealed
   (observed-from-behavior)` for audit; only the `## Investment mix`
   lines above it become the confirmed source of truth.
4. Validate the write (`validate-store.sh <store>`) and re-run
   `calibrate.sh --seed-from-user-model <store>` so priors reflect the
   newly-confirmed model.

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

1. The user-model file verbatim (data/store/user-model.md, status:
   confirmed or provisional — never draft — per contracts/user-model.md's
   pairing rule and "drafts are never read by judgment").

2. The priors block: ranking-weights.json's `kinds` and `evidence`
   entries (contracts/ranking-weights.md 1.1.0), each key's weight
   (absent key defaults to 1.0), with the treatment text from
   relationship-scoring.md's "## Priors" section:
     "a weight < 1.0 de-emphasizes, > 1.0 emphasizes — e.g.
      kinds.scheduling: 0.5 or evidence.meeting: 1.5 — and a prior never
      overrides a stated kind, a stated tier, or any rule in
      relationship-scoring.md's ## Rules."

2b. The recent-corrections block: the verbatim stdout of
    `feedback-recent.sh <store> --n 10` (a sibling unit) — either

      ## Recent corrections
      - 2026-08-30 person:bob-cpa — judge said kind=friend, user said
        kind=transactional, words: "my accountant"

    or, when there is no feedback yet:

      ## Recent corrections
      _none yet_

    followed by this instruction line, verbatim: "These are the user's
    own words about their relationships; a correction outranks any
    prior. Do not restate a correction as a rule for other people unless
    the words themselves generalize." This is the same global block (cap
    10, not scoped to the person or cluster being judged) on every
    judgment call in the run, including `--person <slug>` runs — the
    judge needs cross-person patterns in the user's corrections, not
    just the one person's own history.

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

`check-judgment.sh` is unchanged by the recent-corrections block above
(input 2b) — it validates judgment records against
`relationship-scoring.md`'s record shape and rules only, and never reads
the corrections block itself.

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
  [--expires <kind_expires>] --today <today> --no-index
```

(`--no-index`: this is a per-person loop; Step 5 reindexes once for the
whole batch instead — plan 38 D2.)

A person whose current `kind_source` is already `stated-by-user` gets no
`person-set-kind.sh` call here at all (their `kind` field is untouched
until/unless a later correction explicitly restates it).

**Derived tier writes (plan 31 D5)** — immediately after the kind write,
for every accepted record carrying a non-null `suggested_tier`:

```sh
bash packages/core/scripts/person-set-tier.sh <store> <slug> \
  --tier <suggested_tier> --source derived --today <today> --no-index
```

(`--no-index` for the same reason as the kind write above.)

A `--source derived` write never overwrites `tier_source:
stated-by-user` — `person-set-tier.sh` exits `2` in that case; treat
exit `2` as "kept stated," not an error, and log `tier: kept stated
(<slug>)` (no retry, no error surfaced to the user; the person's
existing stated tier is left byte-identical). Every judgment record
appended to the run artifact — whether its tier write succeeded or was
kept-stated — carries `tier_source: derived`, since the record itself is
always this flow's derived *suggestion*, never a user statement; a
record must never carry `tier_source: stated-by-user` (that value can
only ever land on `people/<slug>.md` via an explicit user correction,
never via this judgment artifact). `check-judgment.sh`'s
`tier-source-invalid` check enforces this shape.

## Step 4 — skew check + correction digest (plan 31 D5)

By the time this step runs, Step 3 has already written every accepted
record's derived kind and derived tier (or logged "kept stated" where a
stated value blocked the write). Nothing below is gated on a per-person
answer — this step only checks for skew, then shows what was already
written.

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

and append `· rescaled: <from>→<to>` (using that record's `rescaled_from`
and its new `attention_warrant`) to that record's digest line below. A
digest shown without `--rescale` never carries this segment. `--rescale`
is never auto-applied on a skewed batch that the user hasn't explicitly
authorized (at invocation or in this prompt).

Build the **correction digest**: one line per person judged this run,
capped at 20, ordered `attention_warrant` descending, then
`days_since_last` ascending, then slug ascending:

```
<slug>: tier <t> (derived) · kind <k> (derived) — <one-clause rationale>
```

with the trailing line `… and N more (see people/)` when the judged
batch exceeds 20 — the remainder is never queued for a follow-up prompt,
it is simply already on disk in `people/`, derived and inspectable
directly. A person whose tier or kind stayed stated (Step 3 logged "kept
stated") is shown with `(stated)` in place of `(derived)` for that
field. Use the `<one-clause rationale>` from that person's judgment
record's `rationale` field, trimmed to one clause. Never frame a
low-warrant, dormant, expired, or no-rhythm line as a verdict — use the
neutral wording ("scheduling contact — event passed"), never
"neglected."

**Framing binding: nothing in this digest needs an answer.** Say so
explicitly in the session (e.g. "nothing here needs a response — correct
anything now or later"). The user may correct any line now, in this same
session, or at any later time — there is no window that closes. A
correction ("`<slug>` is close" / "no tier for `<slug>`") is written, in
this order:

1. The tier, via `specs/stated-preference-filing.md` (a).2 — the same
   unambiguous existing-person frontmatter `tier` overwrite
   `onboarding-seed` uses (every digested slug already resolved out of
   `stats.json`/`people/`, never free text; (a).4's new-person flow only
   applies as a fallback if a digested slug's person file is somehow
   missing at write time).
2. The kind, via:

   ```sh
   bash packages/core/scripts/person-set-kind.sh <store> <slug> \
     --kind <corrected-kind> --note <note> \
     --source stated-by-user --today <today> --no-index
   ```

   — overriding any `derived` kind Step 3 wrote for that person, since a
   correction is now a user statement.

**Carry the user's words into both writes (plan 34).** Whenever the user's
correction reply included words — "3 → close", "she's my accountant", or
any freeform reply that changed a digest line — pass `--feedback-text`
set to that reply verbatim (the whole message, never a paraphrase or
summary) and `--feedback-source session` to both the tier setter
(`person-set-tier.sh`, invoked as `stated-preference-filing.md` (a).2's
write path) and `person-set-kind.sh`. A correction made with no
accompanying words (e.g. a bare structured edit) passes no
`--feedback-text`. This appends a `tier-correction` or `kind-correction`
line to `<store>/signals/feedback.jsonl`
(`packages/core/contracts/feedback-event.md`) — the durable record that
lets a later session stop re-asking what the user already said;
`feedback-recent.sh` (a sibling unit) renders the last 10 such lines into
the judgment prompt.

A stated value always outranks a derived one, now and on every future
derived pass. **Never enumerate excluded people** — people outside this
run's scope (skip-ledger, beyond the 20-cap, or out of the resolved
`--all`/`--unkinded`/`--person` scope) are not named or counted
individually in the digest or its summary.

The skip ledger (`data/ingestion/review-skips.log`) is read-only history
under this flow — this step appends no new lines to it, since every
in-scope person now gets a derived write (or a "kept stated" log line)
rather than a per-person skip action. It is still consulted (via
`--include-skipped`) to exclude people carried over from the
2026-08-29 pre-plan-31 all-skip batch and any other legacy entries.

## Step 5 — close

```sh
bash packages/core/scripts/reindex.sh <store>
bash packages/core/scripts/validate-store.sh <store>
```

## Both Ollama modes

- **Embeddings available:** `embed-people.sh`/`cluster-people.sh` run
  normally; `nearest-confirmed.sh <store> <slug> --k 3` is called per
  in-scope person and its neighbor line (`most similar confirmed people:
  [[slug]] (<kind>[, <tier>]), ...`) is included in the judgment prompt
  (input 3d).
- **Embeddings unavailable:** any of `embed-people.sh`, `cluster-people.sh`,
  or `nearest-confirmed.sh` printing `embeddings: unavailable` means the
  judgment prompt's neighbor line becomes the literal `neighbors: none
  (embeddings unavailable)` for every affected person, and the Step 5
  summary records `embeddings: unavailable` — the flow never stalls or
  errors on this condition, it degrades exactly as each script's own
  usage header documents.

## Summary

End with a short summary, counts only (no per-person callouts of
skipped/excluded people, per the no-guilt rule):

- Whether the user model was already `provisional`/`confirmed`, or was
  freshly adopted `provisional` in this session (or, under
  `--confirm-model`, freshly `confirmed` and the new `revision` number).
- Scope resolved (flag used, count of people in scope, count excluded by
  the skip ledger unless `--include-skipped`).
- Embeddings available or not (`embeddings: unavailable` if so).
- How many records were judged, how many rejected-then-retried, how many
  ended up presented as `kind: unknown` after a failed retry.
- How many derived kind/tier writes succeeded, how many were "kept
  stated" (no write, existing stated value untouched).
- Skew: `yes`/`no`, and whether `--rescale` was applied.
- How many people were digested (capped at 20 if more cleared), how many
  corrections were made in this session (before or after the digest).
- `corrections ledgered: N` — how many of those corrections carried
  `--feedback-text` into `signals/feedback.jsonl` (plan 34; a correction
  made with no accompanying words is counted in "corrections were made"
  above but not in this count).

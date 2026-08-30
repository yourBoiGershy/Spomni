# Spec: review tiers

Status: spec (plan 30 units 4/10). Package: `packages/ingestion`. Skill of
record: `packages/ingestion/skills/review-tiers/SKILL.md` (unit 10). This is
the explicit user-invoked "review tiers" flow `onboarding-tiering-seed.md`
anticipated (its "Out of scope" section: "a later plan may add an explicit
user-invoked 'review tiers' flow, but that would be a new, separately-
specced feature") — it never runs unprompted, and it never re-runs the
one-time onboarding seed itself.

## Scope

Once the user has some corpus history beyond onboarding, tier/kind
suggestions go stale or new people accumulate untiered. This spec defines
the flow a user explicitly invokes ("review tiers") to classify unkinded/
undertiered people, judge each with the model, and present suggestions in
one confirm/adjust/skip batch — reusing `relationship-scoring.md`'s
judgment record and `stated-preference-filing.md`'s write path, never a new
write path of its own.

## Flow (plan 30 D5)

1. **Gate on the user model.** If `user-model.md` is absent or `status:
   draft`, run the derive-and-confirm step first: `derive-user-model.sh`
   writes the draft; the skill shows the revealed mix and asks the user to
   confirm or edit each axis line, protected time, and season. Confirmed →
   `status: confirmed`, `provenance: stated-by-user`, `confirmed_at:
   <today>`, `revision` bumped (0→1 first time), revealed block kept
   labeled (per `contracts/user-model.md`'s "Revealed vs stated" — the
   revealed block is never overwritten or removed, only the `##
   Investment mix` lines above it become the confirmed source of truth).
   Then invoke `packages/attention/scripts/calibrate.sh
   --seed-from-user-model <store>` (attention's script; invoked, never
   edited, by ingestion — single-writer rule). Nothing else in this flow
   proceeds while `user-model.md` is a draft.

2. **Prepare priors.**
   - `embed-people.sh` refreshes embeddings for in-scope people; skipped
     with `embeddings: unavailable` recorded in the run log when Ollama is
     absent — the flow continues without embedding priors in that case.
   - `cluster-people.sh` groups the in-scope people.
   - `nearest-confirmed.sh` yields each person's nearest confirmed
     neighbors.
   - **Scope flag:** `--all | --unkinded | --person <id>`, default
     `--unkinded` (people with no `kind` or `kind: unknown`). `--all`
     widens scope to every person in the store, including already-kinded
     ones (re-judgment, not re-tiering — see step 3's stated-kind rule).
     `--person <id>` scopes to exactly one person. `--include-skipped`
     re-admits people present in the skip ledger (`data/ingestion/
     review-skips.log`, see step 4) who would otherwise be excluded from
     the scoped batch.

3. **Judge.** Per cluster — exemplars first, then members; unclustered
   people last, slug order — the model reads: evidence (`derive-
   evidence.sh` output), the person's `people/<slug>.md`, filed
   interaction summaries, the confirmed user model, and priors (weights,
   neighbors) — see "Judgment prompt contract" below for the exact input
   order — and emits one judgment record per person, per
   `relationship-scoring.md`'s `## Judgment record`.
   - **Stated kinds are never overwritten.** A person whose current
     `kind_source: stated-by-user` is still judged for warrant/tier (the
     judgment record is still produced, and a tier suggestion may still
     be offered), but the record's `kind` field must equal the person's
     already-stated kind — the judge does not propose a different kind
     for a stated person.
   - **Derived kinds are written** via `packages/core/scripts/
     person-set-kind.sh <store> <slug> --kind .. --note .. --source
     derived [--expires ..]` — this is the only path this flow uses to
     write `kind`/`kind_note`/`kind_source`/`kind_expires`/`kind_updated`
     to `people/<slug>.md`.
   - **Validation before anything is written or shown.** `check-
     judgment.sh` validates every record's shape, gate, and caps
     (`relationship-scoring.md`'s `## Rules`) BEFORE any `person-set-
     kind.sh` write or any presentation to the user. A rejected record is
     re-judged **once**; if the retry also fails validation, the person
     is shown as `kind: unknown` with the rejection reason attached (no
     tier suggestion offered for that person), matching
     `relationship-scoring.md`'s retry rule verbatim.
   - **The judge never opens `inbox/` or `archive/`** — evidence and
     interaction summaries are its only corpus inputs, matching
     `derive-evidence.sh`'s own read-only scope
     (`relationship-scoring.md`'s `## Evidence inputs`).

4. **Skew check + present.** `rescale-scores.sh --report` runs over the
   judged batch. If `skew: yes`, the skill prints the warning, exact
   wording:

   ```
   Warrant distribution is skewed (<reason>): mean <m>, <share>% ≥ 80. Re-center with `--rescale`? Suggestions below are shown un-rescaled.
   ```

   and offers `--rescale` — never auto-applied (`relationship-scoring.md`
   `## Warrant rescale`'s "never auto-applied" rule). The batch is
   presented in one pass, capped at 20, ordered: `attention_warrant`
   descending, then `days_since_last` ascending, then slug ascending —
   no backlog framing (matching `onboarding-tiering-seed.md`'s
   "one session, not a backlog" rule; nothing left out of the cap is
   queued for a follow-up prompt).

   Per person, presented with its breakdown string
   (`relationship-scoring.md` `## Breakdown string`), one of three
   actions:
   - **Confirm** the suggested kind and/or tier as-is.
   - **Adjust** — a different kind and/or a different tier value.
   - **Skip** — no write for this person, this pass.

   Confirm or adjust writes the tier (stated, via `stated-preference-
   filing.md` (a).2 — the same write path `onboarding-tiering-seed.md`
   uses) and sets `kind_source: stated-by-user` via `person-set-kind.sh
   --source stated-by-user` (overriding any `derived` kind step 3 may
   have written for that person, since a user confirm/adjust is now an
   explicit statement).

   **Skips** are recorded in `data/ingestion/review-skips.log`
   (`<person-id>\t<ISO 8601 Z>`, append-only, sole writer this skill) and
   never resurface unless the invocation carries `--include-skipped`.

5. **The 2026-08-29 all-skip onboarding batch** is re-presented only via
   `--all` or `--include-skipped` — nothing in this flow re-prompts on its
   own; every invocation is user-initiated.

## Judgment prompt contract

The exact input order and content the model judgment call receives — the
section Phase 5 evals embed verbatim:

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

## Deterministic checkability

Given a fixture store (people/, interactions/, stats.json, a confirmed
user-model.md, ranking-weights.json, and a fixture judged batch), a
checker can hand-verify, without judgment calls:

1. Every record's `kind` is a member of `relationship-scoring.md`'s kind
   vocabulary.
2. Every record's `kind_note` is non-empty.
3. Every record with `kind: scheduling` carries a `kind_expires`.
4. Every record's `rationale` cites at least one evidence field name (from
   `relationship-scoring.md`'s `## Evidence inputs` list) and the record's
   `kind`.
5. The insufficient-data gate and kind caps from `## Rules` were applied
   correctly to each record (no `suggested_tier` above a cap, no
   suggestion at all for `touchpoints < 2`).
6. No `tier` value in `people/<slug>.md` was written for any person
   without a matching "confirm" or "adjust" line in the session
   transcript.
7. Every skip-ledger line is well-formed: `<person-id>\t<ISO 8601 Z>`,
   tab-separated, exactly two fields.
8. Every person whose `kind_source` was `stated-by-user` before the run
   still has the byte-identical `kind` value after the run (only
   `kind_source`, `kind_note`, `kind_updated`, or `kind_expires` may
   change on re-confirm; the `kind` string itself never changes for a
   stated person).

## Retained from the seeding spec

Carried forward, binding, from `onboarding-tiering-seed.md` (not
re-derived, not weakened):

- **Insufficient-data gate:** `touchpoints < 2` excludes a person from the
  suggestion batch entirely — no suggestion, no guessed `dormant` default.
- **One session, not a backlog:** all suggestions from a given invocation
  are batched and presented together; nothing left over is queued for a
  follow-up prompt.
- **20-person cap:** at most 20 people presented per invocation; people
  beyond the cap stay untouched, exactly like a skip.
- **Confirm/adjust/skip semantics:** confirm accepts the suggestion
  as-is; adjust picks any valid kind/tier value, not just an adjacent
  one — the suggestion is a starting point, not a constraint; skip sets
  nothing, now or automatically later. Confirm and adjust are both, at
  the filing layer, the same event: an explicit user-stated value for a
  named, unambiguous person.
- **No-guilt framing**, including the exact neutral wording for expired
  or no-rhythm kinds: "scheduling contact — event passed", never
  "neglected" or "dormant" used as a verdict rather than a category name.

## Out of scope

- The `review-tiers` skill's implementation (prompt assembly, script
  invocation order, UI copy beyond the exact strings quoted above) —
  `packages/ingestion/skills/review-tiers/SKILL.md` (unit 10).
- `derive-user-model.sh`'s draft computation — `user-model-derive.md`.
- `embed-people.sh`, `cluster-people.sh`, `nearest-confirmed.sh`,
  `check-judgment.sh`, `rescale-scores.sh`, `derive-evidence.sh`
  implementations — later plan-30 units, consumed here as-is.
- `packages/attention/scripts/calibrate.sh`'s prior-seeding computation —
  attention's script, invoked but not owned by this spec.

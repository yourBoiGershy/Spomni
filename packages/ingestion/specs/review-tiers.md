# Spec: review tiers

Status: spec (plan 30 units 4/10; revised plan 31 D5/D6). Package:
`packages/ingestion`. Skill of record:
`packages/ingestion/skills/review-tiers/SKILL.md` (unit 10). This is the
explicit user-invoked "review tiers" flow `onboarding-tiering-seed.md`
anticipated (its "Out of scope" section: "a later plan may add an explicit
user-invoked 'review tiers' flow, but that would be a new, separately-
specced feature") — it never runs unprompted, and it never re-runs the
one-time onboarding seed itself.

## Scope

Once the user has some corpus history beyond onboarding, tier/kind
suggestions go stale or new people accumulate untiered. This spec defines
the flow a user explicitly invokes ("review tiers") to classify unkinded/
undertiered people, judge each with the model, write the derived kind and
derived tier for each accepted judgment, and present a correction digest
(plan 31 D5) — reusing `relationship-scoring.md`'s judgment record and
`stated-preference-filing.md`'s write path for corrections, never a new
write path of its own.

## Flow (plan 31 D5/D6 — supersedes plan 30 D2's confirm gate)

1. **Gate on the user model — cold-start adoption, no dialogue.** If
   `user-model.md` is absent or `status: draft`: run
   `derive-user-model.sh` (writing the draft if absent), then set
   `status: provisional` on that same file in place — `revision` stays
   `0`, `provenance` stays `observed-from-behavior`, `derived_at` set to
   today — no question asked, no dialogue shown. Then run
   `packages/core/scripts/validate-store.sh <store>`, then invoke
   `packages/attention/scripts/calibrate.sh --seed-from-user-model
   <store>` (attention's script; invoked, never edited, by ingestion —
   single-writer rule; `calibrate.sh --seed-from-user-model` accepts
   `confirmed` or `provisional`). If `--seed-from-user-model` isn't
   available yet, log `seed: skipped (calibrate.sh --seed-from-user-model
   unavailable)` and continue. If `user-model.md` is already `provisional`
   or `confirmed`, skip straight to step 2 — no re-derive, no dialogue.

   **`--confirm-model` invocation mode** runs the confirm dialogue this
   step used to gate on, now opt-in only, invoked explicitly by the user
   (`review tiers --confirm-model`), never as part of the default flow
   above:

   1. Show the user the `## Revealed vs stated` block's `revealed
      (observed-from-behavior):` lines verbatim (the five axis shares,
      the `unassigned` line, the meeting shares, and the
      `embedding-similarity` line if present).
   2. Ask, per axis line in `## Investment mix`, whether to keep the
      initialized weight/rationale or replace it; same for `## Protected
      time` and `## Season` (both start empty — invite freeform text,
      with the optional trailing `until: <YYYY-MM-DD>` on Season).
   3. On confirmation, write the file directly (this skill edits the
      frontmatter/body in place — `derive-user-model.sh` never writes
      `status: confirmed` itself): set `status: confirmed`, `provenance:
      stated-by-user`, `confirmed_at: <today>`, bump `revision` (0→1 the
      first time; +1 on every subsequent reconfirm). The revealed block
      is never overwritten or removed — it stays labeled `revealed
      (observed-from-behavior)` for audit; only the `## Investment mix`
      lines above it become the confirmed source of truth.
   4. Validate the write (`validate-store.sh <store>`) and re-run
      `calibrate.sh --seed-from-user-model <store>` so priors reflect the
      newly-confirmed model.

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
   - **Derived tiers are also written (plan 31 D5).** After the kind
     write, for every accepted record carrying a non-null
     `suggested_tier`: `packages/core/scripts/person-set-tier.sh <store>
     <slug> --tier <suggested_tier> --source derived`. A `--source
     derived` write never overwrites `tier_source: stated-by-user` — the
     script exits `2` in that case; treat exit `2` as "kept stated", not
     an error, and log `tier: kept stated (<slug>)`. The judgment record
     appended to the run artifact (per Step 3 of the SKILL) gains a
     `tier_source: derived` field labeling this suggestion's provenance —
     a judgment record must never claim `tier_source: stated-by-user`
     (`check-judgment.sh`'s `tier-source-invalid` check rejects one that
     does; only a human confirm/adjust in Step 4 can produce a stated
     tier).
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

4. **Correction digest (plan 31 D5 — supersedes the confirm/adjust/skip
   batch below plan 30 D5 used).** By the time this step runs, step 3 has
   already written every accepted record's derived kind and derived tier
   (or logged "kept stated" where a stated value blocked the write) —
   nothing here is gated on a per-person answer.

   `rescale-scores.sh --report` still runs over the judged batch first.
   If `skew: yes`, the skill still prints the warning, exact wording:

   ```
   Warrant distribution is skewed (<reason>): mean <m>, <share>% ≥ 80. Re-center with `--rescale`? Suggestions below are shown un-rescaled.
   ```

   and still offers `--rescale` — never auto-applied
   (`relationship-scoring.md` `## Warrant rescale`'s "never auto-applied"
   rule).

   Then the skill shows the **correction digest**: one line per person
   judged this run, capped at 20, ordered `attention_warrant` descending,
   then `days_since_last` ascending, then slug ascending — no backlog
   framing (matching `onboarding-tiering-seed.md`'s "one session, not a
   backlog" rule):

   ```
   <slug>: tier <t> (derived) · kind <k> (derived) — <one-clause rationale>
   ```

   with the trailing line `… and N more (see people/)` when the judged
   batch exceeds 20 — the remainder is never queued for a follow-up
   prompt, it is simply already on disk in `people/`, derived and
   inspectable directly. A person whose tier or kind stayed stated (step
   3 logged "kept stated") is shown with `(stated)` in place of
   `(derived)` for that field instead.

   **Framing binding: nothing in this digest needs an answer.** The user
   may correct any line now, in this same session, or at any later time —
   there is no window that closes. A correction ("`<slug>` is close" /
   "no tier for `<slug>`") is written via `stated-preference-filing.md`
   (a).2 for the tier and `person-set-kind.sh --source stated-by-user`
   for the kind — the same write path `onboarding-tiering-seed.md` used
   for its confirm/adjust — and a stated value always outranks a derived
   one, now and on every future derived pass.

   **The correction carries the user's words (plan 34).** Every correction
   write — the tier write via `stated-preference-filing.md` (a).2 and the
   kind write via `person-set-kind.sh --source stated-by-user` — passes
   `--feedback-text` set to the user's message verbatim (the whole reply
   that made the correction, not a paraphrase) and `--feedback-source
   session`. A correction that arrives with no accompanying words (a bare
   digest-line edit with nothing said) passes no `--feedback-text`. This
   is what lets the store stop asking the user to re-explain themselves —
   the ledger (`<store>/signals/feedback.jsonl`,
   `packages/core/contracts/feedback-event.md`) is the durable record of
   what was said; `feedback-recent.sh` (a sibling unit) renders the last
   10 lines into the judgment prompt so a future judgment call already
   knows what the user said, without asking again. No-guilt framing is
   retained: a low-warrant, dormant, expired, or no-rhythm line reads as
   a neutral observation ("scheduling contact — event passed"), never
   "neglected." **Never enumerate excluded people** — people outside this
   run's scope (skipped-ledger, beyond the 20-cap, or out of the resolved
   `--all`/`--unkinded`/`--person` scope) are not named or counted
   individually in the digest or its summary.

   The skip ledger (`data/ingestion/review-skips.log`) becomes read-only
   history under this flow: since every in-scope person now gets a
   derived write (or a "kept stated" log line) rather than a per-person
   confirm/adjust/skip prompt, this flow appends no new lines to it — it
   is still consulted (via `--include-skipped`) to exclude people carried
   over from the 2026-08-29 pre-plan-31 all-skip batch and any other
   legacy entries, per the "Scope flag" rule above.

5. **The 2026-08-29 all-skip onboarding batch** is re-presented only via
   `--all` or `--include-skipped` — nothing in this flow re-prompts on its
   own; every invocation is user-initiated.

## Rules (plan 31 D5 — supersedes plan 30 D2)

`relationship-scoring.md`'s prior rule, "zero unconfirmed tier writes: a
`suggested_tier` is never written to `person.md`'s `tier` field without
explicit user confirmation," is superseded for this flow by: **unconfirmed
tier writes are always labeled `tier_source: derived`; a stated tier
(`tier_source: stated-by-user`) is never overwritten by a derived one.**
Concretely — this is the only asymmetry this flow relies on:

- A `--source derived` write (step 3) always succeeds and labels the
  result `derived` when the person's current `tier_source` is not already
  `stated-by-user`.
- A `--source derived` write is a no-op (`person-set-tier.sh` exits `2`,
  "kept stated") when the person's current `tier_source` is already
  `stated-by-user` — the existing stated tier is untouched.
- A correction (step 4) always writes `--source stated-by-user` and
  always wins, immediately and on every future derived pass, regardless
  of what a prior derived write set.
- The same asymmetry applies to `kind`/`kind_source`, unchanged from
  plan 30: derived kinds are written; stated kinds are sticky.

Recorded in `docs/DECISIONS.md` `derived-tiers-provisional`.

## Judgment prompt contract

The exact input order and content the model judgment call receives — the
section Phase 5 evals embed verbatim:

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
6. Every `tier` value written to `people/<slug>.md` this run has a
   matching `tier_source`: `derived` when the run's judgment record
   supplied the value and the person had no prior stated tier;
   `stated-by-user`, byte-identical to its pre-run value, when the run
   logged "kept stated" for that slug (a derived write never appears as
   `tier_source: stated-by-user` and vice versa).
7. Any skip-ledger line present (legacy entries only — this flow appends
   none) is well-formed: `<person-id>\t<ISO 8601 Z>`, tab-separated,
   exactly two fields.
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
- **20-person cap:** at most 20 people digested per invocation; people
  beyond the cap stay untouched (already derived-written where
  applicable), exactly like the old skip semantics.
- **Correction semantics (plan 31 D5, supersedes confirm/adjust/skip):**
  every in-scope person's derived kind/tier is written by step 3 without
  a per-person prompt; a correction picks any valid kind/tier value, not
  just an adjacent one — the derived suggestion is a starting point, not
  a constraint. A correction is, at the filing layer, the same event
  `onboarding-tiering-seed.md`'s confirm/adjust was: an explicit
  user-stated value for a named, unambiguous person, written via
  `stated-preference-filing.md` (a).2 and `person-set-kind.sh --source
  stated-by-user`.
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

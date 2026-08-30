# Expected outcome: user-model propagation (review-tiers Step 3, two revisions)

<!-- prompt.md frontmatter note: `model: sonnet` is a deliberate per-case
     override of eval-suite.sh's haiku default (per `eval-case.md`'s `model`
     field docs), matching the sibling `kind-classification-corpus` case's
     precedent — a 12-person judgment batch, run TWICE in one session here,
     is exactly the kind of batched structured-output task haiku failed on
     relationship-scoring.md's rationale contract in that case's attempts
     1-2 (see its completion report). Sonnet is used from the start here
     rather than re-litigating that finding. -->

This directory exists only to satisfy the `expected` frontmatter field the
T3 runner (`eval-run-skill.sh`) requires; it is not consumed by
`RA_GRADER_DIFF`. Grading is entirely by the deterministic Python grader
in `graders/`, which diffs the two judgment files this prompt writes
(`data-ingestion/review-judgments/2026-08-29-rev1.jsonl` and
`...-rev2.jsonl`) against each other, not against a byte-diffable golden
store — same reasoning as `kind-classification-corpus/expected/README.md`:
which kind a person lands on, and the exact warrant number, is model
judgment, not a pure function of the fixture.

## What this case proves

`before/user-model.md` (revision 1, `friends: 0.30`) and
`before/user-model.rev2.md` (revision 2, `friends: 0.80`) are byte-
identical except for `revision` and the `friends` axis line (verified by
`diff` at authoring time — see the completion report). Everything else the
judgment reads — the 12-person corpus, `evidence.jsonl`,
`ranking-weights.json`, `neighbors.tsv`, `clusters.tsv` — is untouched
between the two passes. If the skill's Step 3 judgment genuinely reads the
confirmed user model's `## Investment mix` weights (per
`relationship-scoring.md`'s "## Priors" section, item 1: "the confirmed
user-model axis weights ... `contracts/user-model.md`"), then raising
`friends` from 0.30 to 0.80 should visibly raise `attention_warrant` for
personal-relationship kinds (`friend`, `family`) between rev1 and rev2,
while every other kind (which has no `friends`-axis prior applicable to
it) stays within a small noise band — judgment is non-deterministic, so
exact reproducibility isn't expected, but a systematic move only where the
prior applies, and not elsewhere, is exactly what "the model reads the
user model" should look like. This is a mechanism/propagation eval, not a
kind-classification eval (that is `kind-classification-corpus`'s job) —
the prompt deliberately tells the model to treat `friends` as covering
both `friend` and `family` records for this exercise, since isolating a
free-standing effect of the `family` axis (which does NOT change between
rev1 and rev2 in this fixture) is out of scope here.

## `before/` provenance

`before/` starts as a byte-for-byte copy of
`kind-classification-corpus/before/` (same 12-person corpus,
`evidence.jsonl`, `ranking-weights.json`, `neighbors.tsv`,
`clusters.tsv`), with its single `user-model.md` replaced by the two
revision files described above. This case does not feed back into the
sibling `before/` — it forks a private copy, since this case's `before/`
now carries two user-model files instead of one, which the
kind-classification-corpus/warrant-ordering/de-saturation trio's shared-
fixture note (see that case's README) does not accommodate.

## Hand-derived expectation: which slugs are "personal" going in

Reading `before/people/*.md` and `before/data-ingestion/evidence.jsonl`
(the same reasoning `kind-classification-corpus/expected/README.md` used,
since this is the same corpus):

- `mara-quill`, `ravi-sundar`: `kind_source: stated-by-user`, kind already
  `friend` — sticky rule means BOTH passes must keep `kind: friend` for
  these two. They are the two slugs this case is most confident will land
  in the `friend`/`family` bucket in rev1, and are the most likely source
  of the required ≥5-point rise.
- `june-abernathy`: `tags: [family]`, "Family" `how-met`, family-reunion
  planning and "family updates" in the interaction log — the most likely
  `family` call, though (per `kind-classification-corpus`'s README) this
  slug is not pinned to an exact kind in the fixture; the grader does not
  assume it lands on `family`, it reads whatever kind the run's own rev1
  output actually assigned and checks the delta rule against that.
- Everyone else (`bram-fiske`, `dex-morrow`, `hal-torrance`,
  `ines-castellano`, `nell-ashby`, `otto-brandvold`, `pip-larkin`,
  `sol-abernathy`, `wren-halloway`) has no personal-relationship framing
  in their `person.md`/interactions — transactional, unsolicited,
  professional, collaborator, community, scheduling, or thin/unknown
  contacts. None of these should move by more than the noise band.
- `pip-larkin`: `kind_expires: 2026-08-20`, already past "today"
  (2026-08-29) — the expired-kind rule (`relationship-scoring.md`'s
  `## Rules`) forces `attention_warrant: 0` regardless of any prior,
  including a raised `friends` weight. This must hold in BOTH files.

## Why delta-grading, not exact-value or fixed-slug-set grading

`packages/core/scripts/eval-case.md`'s golden-tests-before-prompts rule
requires every grader's expected value to be hand-derived from the
fixture — but there is no fixed target `attention_warrant` value to
hand-derive for a non-deterministic 0-100 judgment call, and (per the note
above) even which slug lands on `family` is itself model judgment, not a
fixture fact. What IS hand-derivable and rule-bound is the **relationship**
between the two runs: personal kinds must not drop and at least one must
rise meaningfully; everything else must stay close; `pip-larkin` must be
exactly 0 in both, unconditionally. `01-propagation.py` grades exactly
that relationship, read dynamically off rev1's own kind assignments (never
copied from a run's own numeric output — the rule being checked, "warrant
moves only where the prior applies," is fixed at authoring time; only
which slug the rule applies to is read from the run).

## Manual verification performed

`01-propagation.py` was run directly against a hand-built pair of worked
`rev1.jsonl`/`rev2.jsonl` files (a plausible correct pass: `mara-quill`
25→45, `ravi-sundar` 30→50, `june-abernathy` 20→38 as `family`, everyone
else within ±3, `pip-larkin` 0/0) — PASS — and against a doctored variant
that lowers a friend's rev2 warrant below its rev1 value (`mara-quill`
45→20) to confirm the grader actually bites — FAIL. See the completion
report for the exact commands and PASS/FAIL output, and for the live
`eval-run-skill.sh` sonnet run's result line(s).

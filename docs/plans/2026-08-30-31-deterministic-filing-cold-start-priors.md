# Plan 31 — Deterministic structured filing & cold-start priors

**Mission test.** Both halves cut running cost only: (a) filing calendar/email
metadata is bookkeeping, not judgment — doing it with a shell script instead of
ten model workers removes minutes of wall-clock and all the CPU/RAM; (b) tiers
and the user-model start from observed behavior, labeled `derived`, so the user
spends zero effort *stating* and only ever *corrects*. Nothing here sends,
drafts, or performs the relationship; provenance labeling keeps derived and
stated apart.

**Trigger (2026-08-30).** The 6-month backfill on the new account filed 243
events in ~7.5 min across ten parallel Claude workers (the previous sequential
path was ≈9 min per 32 events) with heavy CPU/RAM; and the tier pass could not
start until the user confirmed a user-model and then every tier by hand. User
direction: "we need a considerably better way to do this" and "start from 0 and
not rely on user input at all, only user correction".

## Findings (read-only analysis, this session)

- For `calendar-event` and metadata-only gmail events every filing step is
  mechanical: hints are `"Name <email>"`/email, resolution is exact email/name
  match against `people/` + `index.json` (already implemented in
  `shard-filing-batch.sh` identity_resolve_email/name), the person and
  interaction files are templated, and no ambiguity class of the debrief skill
  (§3–4) arises. Model filing stays for free text: chat episodes, debrief notes,
  email bodies.
- Three gates block a cold start: review-tiers step 1 refuses on
  `user-model.md` `status: draft`; `relationship-scoring.md` "zero unconfirmed
  tier writes" (person `tier` has no provenance field, unlike `kind_source`);
  `calibrate.sh --seed-from-user-model` exits 3 unless `confirmed`.

## Decisions

- **D1 Structured lanes file deterministically.** New
  `packages/ingestion/scripts/file-structured.sh` files every eligible inbox
  event without a model call. Eligible = `type: calendar-event`, or a gmail
  event whose body is metadata-only (< 40 words after the subject line). Runs
  after `triage-inbox.sh` and before the debrief batch; shares
  `data/ingestion/debrief-filed.log` so the debrief skill skips what it filed.
  Target: the 275-event backfill in < 30 s, one `build-index.sh` at the end.
- **D2 No invented provenance.** The deterministic filer writes NO `## Facts`
  bullets (calendar attendance is neither told-by-user nor public-web); person
  files get `name` + `last-touch` only. Interaction summary is a fixed template
  (`Calendar: "<title>" with <names>` / `Email: "<subject>" — <from> → <to>`),
  commitments `_none_`. Facts/org/role remain the model path's job.
- **D3 Hold, don't guess.** A hint that resolves to two slugs by name, or an
  email with no name and no existing person, is held to
  `data/ingestion/structured-held.log` (`<id>\t<reason>\t<ts>`) for the
  debrief path; never a silent merge.
- **D4 Tier provenance.** `person.md` 1.2.0 adds `tier_source:
  derived | stated-by-user` (required when `tier` set; absent tier_source on a
  legacy file reads as stated-by-user). New core script
  `person-set-tier.sh <store> <slug> --tier <v> --source <s> [--today]`
  mirrors `person-set-kind.sh`, including: a `--source derived` write never
  overwrites `tier_source: stated-by-user` (exit 2).
- **D5 Derived tiers are written.** `relationship-scoring.md` rule "zero
  unconfirmed tier writes" becomes "unconfirmed tier writes are always
  `tier_source: derived`; a stated tier is never overwritten by a derived
  one". review-tiers step 3 writes both derived kind and derived tier; step 4
  becomes a correction digest (what was inferred, one line per person, no
  question that blocks) — a correction writes `stated-by-user` and sticks.
  Supersedes plan 30 D2's asymmetry; recorded in DECISIONS.md
  `derived-tiers-provisional`.
- **D6 Provisional user-model.** `user-model.md` gains `status: provisional`
  (derived, auto-adopted, revision 0). review-tiers step 1: if absent/draft →
  derive and set `provisional` with no dialogue; proceed. `calibrate.sh
  --seed-from-user-model` accepts `confirmed` or `provisional`. The confirm
  dialogue only runs when the user asks (`/review-tiers --confirm-model`).
- **D7 Onboarding-seed collapses to cold start.** Steps 2 → triage,
  file-structured, debrief remainder. Steps 4–6 → `review-tiers --all`
  (semantic, derived writes) instead of the frequency scorer's confirm batch;
  `suggest-tiers.sh` stays as a read-only diagnostic. The four binding
  "no tier without confirmation" rules are replaced by: every tier written this
  run is labeled derived; the user can correct any line at any time and a
  correction always wins.

## Units (dispatch in one wave; ≤3 min each)

| # | Pkg | Unit |
|---|---|---|
| U1 | ingestion | `scripts/file-structured.sh` + `specs/structured-filing.md` |
| U2 | ingestion | `tests/run-structured-tests.sh` + fixtures (calendar, gmail metadata, gmail body → not eligible, ambiguous name → held, self-only skip, idempotent rerun, stated-tier untouched) |
| U3 | core | person contract 1.2.0 `tier_source`, template, `person-set-tier.sh`, validate-store enum, user-model contract `provisional`, relationship-scoring rule, store tests |
| U4 | attention | calibrate.sh accepts `provisional`; calibration.md; test |
| U5 | ingestion | review-tiers spec + SKILL (steps 1/3/4 per D5/D6), check-judgment.sh |
| U6 | ingestion+harness | onboarding-seed SKILL + onboarding-tiering-seed spec per D7; debrief SKILL batch-mode note; package.md manifests |
| U7 | docs | DECISIONS.md entry, ROADMAP row 31, this plan (orchestrator) |

## Live proof (after merge)

1. Fresh worktree store, replay the 2026-08-30 inbox: `file-structured.sh`
   wall-clock and counts; `validate-store.sh` clean; diff people/interactions
   against the model-filed store (same slugs, same interaction dates).
2. `/review-tiers --all` on an absent user-model: provisional adopted, derived
   kinds+tiers written, correction digest shown, one correction sticks.

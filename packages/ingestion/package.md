# package: ingestion

version: 0.2.0

## Purpose

Data malleability: everything that turns raw, normalized input into structured
knowledge. The filing engine (debriefs → person/interaction files), attendee↔person
matching against calendar artifacts, commitment extraction, link maintenance, and
provenance labeling. Ingestion is the sole writer of the people-store.

## Provides

- The populated store: `people/`, `interactions/`, `index.json` (single writer at
  runtime); `profile.md` (single writer at runtime — stated preferences and, after
  user confirmation, style notes); `user-model.md` (single writer at runtime — the
  draft/confirmed investment-mix singleton, plan 30); `index/embeddings.jsonl`
  (single writer at runtime — `scripts/embed-people.sh`, plan 30)
- `thread-summary 1.0.0` (contract in `specs/thread-summary.md`; produced by
  `scripts/summarize-thread.sh`, consumed by `scripts/file-thread.sh` — one
  model call's strict-JSON output per chat thread, replacing the debrief
  skill's per-day episode-split model pass for `chat-message` captures
  during onboarding/backfill, plan 32)
- Skills: `skills/debrief/` (filing engine), `skills/calendar-reconcile/`
  (attendee↔person matching, event links, un-debriefed + upcoming-briefworthy
  artifacts), `skills/onboarding-seed/` (session-driven, one-shot fresh-install
  pass: sequences the three lanes' backfill modes, normal filing,
  `build-stats.sh`, and the two seed-time scripts below into one batched,
  human-confirmed tier-suggestion presentation, per plan 24), `skills/review-tiers/`
  (user-invoked, repeatable review pass: gates on a confirmed `user-model.md`,
  prepares embedding/prior context, judges kind + attention warrant per person via
  the model with `check-judgment.sh`-validated records, presents <=20
  breakdown-annotated suggestions for confirm/adjust/skip — never a tier write
  without confirmation, never scheduled — per plan 30)
- Scripts: `scripts/derive-participation.sh` (read-only; derives per-person
  `user_engaged`/`group_linked` participation flags from preserved raw
  capture events, ephemeral input to onboarding tier suggestions — never
  written to the store), `scripts/suggest-tiers.sh` (read-only; applies the
  deterministic D3 scoring model to `stats.json` + the participation flags,
  emitting the ordered, capped suggestion batch — both plan 24),
  `scripts/triage-inbox.sh` (read-only over `<store-dir>`; sole writer of
  the `data/ingestion/triage-held.log` ledger — deterministic, no-model
  pre-judgment hold pass over `inbox/`, applying `specs/import-triage.md`'s
  five rule classes, plan 26), `scripts/shard-filing-batch.sh` (read-only
  over `<store-dir>`; writes only its `--out-dir` — deterministic,
  no-model person-sharded pre-pass over the eligible filing batch,
  applying `specs/parallel-filing.md`'s D1 connected-components rule, plan
  27), `scripts/file-structured.sh` (deterministic, no-model filer over
  `<store-dir>/inbox/` for `calendar-event` and metadata-only gmail
  events — templated `people/`/`interactions/` writes only, no `## Facts`/
  tier/kind opinion; shares `data/ingestion/debrief-filed.log` with
  `skills/debrief/` and is sole writer of
  `data/ingestion/structured-held.log`; per `specs/structured-filing.md`
  D1–D3, plan 31), `scripts/derive-evidence.sh` (read-only over
  `people/`/`interactions/`/`wakeups/`/`stats.json`, never `inbox/`/`archive/`;
  emits the per-person evidence JSON-lines `relationship-scoring.md`'s judgment
  and `check-judgment.sh`'s `--evidence` gate both consume, plan 30),
  `scripts/derive-user-model.sh` (sole writer of `user-model.md`'s draft state —
  computes the trailing-90-day revealed investment mix from the corpus per
  `specs/user-model-derive.md`, refuses to clobber a confirmed file without
  `--redraft`, plan 30), `scripts/embed-people.sh` (sole writer of
  `<store>/index/embeddings.jsonl` — local-only Ollama/EMBED_CMD embedding
  refresh, content-hash-gated, per `specs/embeddings.md`, plan 30),
  `scripts/nearest-confirmed.sh` (read-only consumer of `index/embeddings.jsonl`
  — neighbor priors + axis-similarity, `embeddings: unavailable` fallback, plan
  30), `scripts/cluster-people.sh` (read-only consumer of `index/embeddings.jsonl`
  — greedy threshold clustering, a prompt-batching heuristic only, persists
  nothing, plan 30), `scripts/rescale-scores.sh` (pure function over a judgment
  batch — `--report`/`--rescale`/`--rank` per `specs/rescale.md`, writes no file,
  plan 30), `scripts/check-judgment.sh` (read-only judgment-record validator
  against `relationship-scoring.md`'s shape/gate/caps/expiry/sticky-kind rules,
  the pre-write/pre-presentation gate `skills/review-tiers/` runs every record
  through, plan 30), `scripts/profile-set-notify.sh` (sole writer of
  `profile.md`'s `## Notify` section — the stated-by-user notification
  channel/beeper-chat-id/gmail-address/quiet-hours bullets, per
  `contracts/profile.md` 1.1.0, plan 33),
  `scripts/feedback-recent.sh` (read-only over
  `<store>/signals/feedback.jsonl`; renders the `## Recent corrections`/
  `## Recent draft edits` judgment-prompt blocks, newest first, capped by
  `--n`, filterable by `--kind`/`--person`, per `specs/feedback-ledger.md`,
  plan 34), `scripts/feedback-to-evals.sh <store> --data-dir <d>`
  (read-only over `<store>/signals/feedback.jsonl` and `<store>`; sole
  writer of `<data-dir>/evals/feedback/cases/` and
  `<data-dir>/evals/feedback/suite.txt` — turns every
  tier-correction/kind-correction ledger line into a T3 regression eval
  case proving the correction sticks against a later `review tiers` pass,
  latest-per-slug-per-type wins, idempotent; run only via
  `RA_EVAL_PRIVATE_MANIFEST` per `contracts/eval-case.md` 1.3.0's
  private-manifest mode, per plan 34 D4/U20),
  `scripts/summarize-thread.sh` (one headless model call
  per `chat-message` capture, emitting `thread-summary` 1.0.0 strict JSON —
  no store writes, per `specs/thread-summary.md`, plan 32),
  `scripts/file-thread.sh` (deterministic writer consuming that JSON —
  timestamp-derived episode split, chatID dedup union (D3), person upsert,
  `debrief-filed.log` append, no model call and no `tier`/`kind` opinion,
  plan 32)
- Specs: `specs/stated-preference-filing.md` — how tier utterances, signal opt-outs,
  priorities, and cadence wishes file into `person.md`/`profile.md`, including the
  tier-change confirmation path (amends plan 03's filing-engine brief; plan 03 is
  unbuilt); `specs/onboarding-tiering-seed.md` — the cold-start tier-suggestion
  sequence, scoring model, and no-guilt presentation rules `skills/onboarding-seed/`
  runs (plan 11 unit 13, amended by plan 24 for the 6-month configurable window +
  participation-signal scoring); `specs/import-triage.md` — the five
  deterministic, precision-first junk-hold rule classes and the D3
  held-by-rule ledger convention (plan 26); `specs/parallel-filing.md` —
  the shard pre-pass's connected-components semantics, `skills/debrief/`'s
  shard mode deviations, and the wave protocol a parallel filing run
  follows end to end (plan 27); `specs/user-model-derive.md` — the
  trailing-90-day revealed-mix computation, axis assignment (kind map then
  heuristic), and draft/confirm write shape `scripts/derive-user-model.sh`
  implements (plan 30); `specs/review-tiers.md` — the five-step user-invoked
  review flow (gate/prepare/judge/present/close), the judgment prompt contract,
  and the deterministic checkability list `skills/review-tiers/` implements
  (plan 30); `specs/embeddings.md` — content-per-person assembly, local-only
  Ollama/EMBED_CMD resolution, and the `embeddings: unavailable` degrade path
  shared by `scripts/embed-people.sh`/`nearest-confirmed.sh`/`cluster-people.sh`
  (plan 30); `specs/rescale.md` — the re-center/rank math, skew rule, and
  suggested-tier recompute `scripts/rescale-scores.sh` implements (plan 30);
  `specs/structured-filing.md` — the eligibility rule (`calendar-event` or
  metadata-only gmail), the no-invented-provenance template writes, and the
  D3 hold-vs-guess rule `scripts/file-structured.sh` implements (plan 31);
  `specs/thread-summary.md` — the one-call-per-thread prompt/output contract
  (`thread-summary` 1.0.0: skip/people/relationship_kind_guess/gist/
  open_threads/commitments/facts) `scripts/summarize-thread.sh` implements
  and `scripts/file-thread.sh` consumes (plan 32)
- Ledgers/artifacts: `data/ingestion/triage-held.log` (sole writer:
  `scripts/triage-inbox.sh`) — append-only, tab-separated
  `<capture-id>\t<rule-name>\t<held-at ISO 8601 Z>`, one line per held
  event; read by `skills/debrief/` batch mode (excluded alongside
  `debrief-filed.log`) and by humans directly, per `specs/import-triage.md`
  D3 (plan 26); `data/ingestion/debrief-filed.shard-<k>.log` (one per
  active shard worker, sole writer: `skills/debrief/` shard mode) —
  same shape as `debrief-filed.log`, merged into it by the wave
  orchestrator (never by a shard worker itself) before the post-wave index
  rebuild, per `specs/parallel-filing.md` D2/D3 (plan 27);
  `data/ingestion/review-skips.log` (sole writer:
  `skills/review-tiers/`) — append-only, tab-separated `<slug>\t<ISO 8601 Z>`,
  one line per explicit skip, never resurfaced without `--include-skipped`
  (plan 30); `data/ingestion/review-judgments/<date>.jsonl` (sole writer:
  `skills/review-tiers/`) — one judgment-record run's raw output, per
  invocation date, validated by `scripts/check-judgment.sh` before any write
  or presentation (plan 30); `data/ingestion/structured-held.log` (sole
  writer: `scripts/file-structured.sh`) — append-only, tab-separated
  `<capture-id>\t<reason>\t<held-at ISO 8601 Z>`, one line per event
  `file-structured.sh` could not resolve deterministically (ambiguous
  name-hint match, or an email with no name and no existing person); read
  by `skills/debrief/` batch/shard mode as ordinary unfiled input (not an
  exclusion list — see that skill's structured-events note), per
  `specs/structured-filing.md` D3 (plan 31); `<store>/signals/feedback.jsonl`
  (sole writer: `scripts/feedback-file.sh`) — the append-only feedback
  ledger every reply, correction, and lifecycle outcome writes one line
  to; user `--text` is stored verbatim, never rewritten; cross-package
  callers (attention `wakeup-queue.sh`, core `person-set-tier.sh`/
  `person-set-kind.sh` stated writes, `skills/review-tiers/`,
  `scripts/feedback-parse.sh`) call `feedback-file.sh` rather than writing
  the file themselves, per `specs/feedback-ledger.md` and
  `packages/core/contracts/feedback-event.md` 1.0.0 (plan 34 D1);
  `scripts/feedback-parse.sh` (deterministic, no-model reply-grammar parse
  of note-to-self `chat-message` capture events against the last delivered
  batch — `packages/attention/scripts/wakeup-queue.sh` fire/snooze/dismiss
  and `scripts/person-set-tier.sh` for the applied verbs, `feedback-file.sh`
  for everything else including unparseable text, which is always ledgered
  as `freeform`, never dropped; sole writer of
  `data/ingestion/feedback-cursor` and `data/ingestion/feedback-applied.log`
  `<capture-id>\t<line-no>\t<type>\t<ts>\t<exit>`; runs on every sync tick as
  the `feedback` lane row, no-op when nothing new; per
  `specs/feedback-parse.md`, plan 34 D2/U8)
- Conventions: `needs-confirmation` and `needs-follow-up` markers, met-at /
  will-meet-at / same-event-as links
- Evals: `evals/cases/` — 16 T3 (skill-tier) cases (`eval-case@1`,
  `packages/core/scripts/eval-run-skill.sh`): cases 01-06 wrap the six
  `tests/goldens/preferences/*` stated-preference goldens (now runnable —
  plan 03's filing engine/debrief skill has landed and the
  `runnable-when: "03"` flip lands with it, per the eval-case contract's
  flip-with-the-change discipline); cases 07-16 wrap the ten
  `tests/goldens/debrief/*` full filing-path goldens, exercising
  `skills/debrief/SKILL.md` end to end (person creation/update, interaction
  filing, commitment extraction, reminder-ask wake-up creation, ambiguous-
  name question handling, and the append-only contradicting-fact case).
  `evals/suite.txt` lists all 16.
- Tests: `tests/run-scoring-tests.sh` + `tests/fixtures/scoring/` (judgment-record
  shape, `check-judgment.sh` reject reasons, `rescale-scores.sh` report/rescale/
  rank math against fixture batches); `tests/run-embeddings-tests.sh` +
  `tests/fixtures/embeddings/` (`embed-people.sh`/`nearest-confirmed.sh`/
  `cluster-people.sh` against a fixture store, including the
  `embeddings: unavailable` degrade path) — both plan 30, unit 12; being written
  concurrently with this package.md update.

## Consumes

- `person@^1`, `interaction@^1`, `capture-event@^1`, `wakeup@^1`, `profile@^1`,
  `onboarding-backfill@^1.0`, `import-pipeline@^1` (core; wake-up creation only via core's
  `wakeup-add.sh`; `profile@^1` and `person@^1` tier writes per
  `specs/stated-preference-filing.md`; `person@^1` now read/written at 1.1.0 for
  the plan-30 `kind`/`kind_note`/`kind_source`/`kind_expires`/`kind_updated`
  fields, sole write path `packages/core/scripts/person-set-kind.sh`;
  `onboarding-backfill@^1.0` read by `skills/onboarding-seed/` and
  `scripts/derive-participation.sh` for the configured window and `self`
  identities, per plan 24; `import-pipeline@^1` is the five-stage
  fetch→normalize→triage→judgment→file contract that `scripts/triage-inbox.sh`
  and `skills/debrief/`'s triage-held exclusion implement the triage/judgment
  stages of, per plan 26)
- `user-model@^1` (core; `contracts/user-model.md` — `scripts/derive-user-model.sh`
  is the sole writer of both the draft and, via `skills/review-tiers/`'s confirm
  dialogue, the confirmed state), `relationship-scoring@^1` (core;
  `contracts/relationship-scoring.md` — the judgment record shape, kind
  vocabulary, rules, and breakdown string `skills/review-tiers/` and
  `scripts/check-judgment.sh`/`scripts/rescale-scores.sh` all implement against),
  `embeddings-index@^1` (core; `contracts/embeddings-index.md` —
  `scripts/embed-people.sh` is the sole writer, `scripts/nearest-confirmed.sh`/
  `scripts/cluster-people.sh` read-only consumers), `ranking-weights@^1.1`
  (core; `contracts/ranking-weights.md` 1.1.0's `kinds`/`evidence` prior
  dimensions — read-only here, seeded and owned by `packages/attention`'s
  `scripts/calibrate.sh`; ingestion invokes `calibrate.sh --seed-from-user-model`
  but never writes `ranking-weights.json` itself, single-writer rule) — all
  plan 30
- Typed capture events from `connectors/gmail-in`, event artifacts from
  `connectors/calendar-in`
- Tier-change proposal wake-ups from `packages/attention` (read-only — the
  confirmation reply is what ingestion files; `attention` never writes `person.md` or
  `profile.md` directly, per `docs/DECISIONS.md#preference-provenance`)
- `scripts/feedback-parse.sh` calls `packages/attention`'s
  `scripts/wakeup-queue.sh` (`snooze`/`dismiss`, sanctioned cross-package
  call per plan 34 D1/D2) to apply a reply, and reads `<store>/outbox/
  delivered.log` + `<store>/wakeups/fired/*-batch.json` (connectors-owned /
  attention-owned artifacts respectively, plan 33) read-only to resolve a
  reply's card number to a wake-up id

## Owned paths

`packages/ingestion/**`; at runtime: `people/`, `interactions/`, `index.json`,
`user-model.md`, `index/embeddings.jsonl`, `<store>/signals/feedback.jsonl`
(sole writer: `scripts/feedback-file.sh`) in the private data dir, plus
`<data-dir>/ingestion/feedback-cursor` and
`<data-dir>/ingestion/feedback-applied.log` (sole writer:
`scripts/feedback-parse.sh`).

## Built by

Plans 03 (filing engine) and 04 (matching half). `skills/onboarding-seed/`,
`scripts/derive-participation.sh`, `scripts/suggest-tiers.sh`, and the
`onboarding-tiering-seed.md` spec amendment by plan 24
(docs/plans/2026-08-29-24-onboarding-backfill-priority-seeding.md).
`scripts/triage-inbox.sh`, `specs/import-triage.md`, the
`data/ingestion/triage-held.log` ledger, and `skills/debrief/`'s
triage-held batch-mode exclusion by plan 26 (standard import pipeline).
`scripts/shard-filing-batch.sh`, `specs/parallel-filing.md`, the
`data/ingestion/debrief-filed.shard-<k>.log` ledger convention, and
`skills/debrief/`'s shard mode by plan 27 (import speed & scaling).
Plan 30 (kind/tier judgment + user-model + embeddings): `specs/user-model-derive.md`,
`specs/review-tiers.md`, `specs/embeddings.md`, `specs/rescale.md`,
`scripts/derive-evidence.sh`, `scripts/derive-user-model.sh`,
`scripts/embed-people.sh`, `scripts/nearest-confirmed.sh`,
`scripts/cluster-people.sh`, `scripts/rescale-scores.sh`,
`scripts/check-judgment.sh`, `skills/review-tiers/`, and the
`data/ingestion/review-skips.log` / `data/ingestion/review-judgments/<date>.jsonl`
artifacts.
Plan 31 (deterministic filing & cold-start priors,
`docs/plans/2026-08-30-31-deterministic-filing-cold-start-priors.md`):
`scripts/file-structured.sh`, `specs/structured-filing.md`, the
`data/ingestion/structured-held.log` ledger, `skills/onboarding-seed/`'s
collapse to triage → structured filing → debrief-remainder →
`/review-tiers --all` cold start (D7), and `specs/onboarding-tiering-seed.md`'s
further supersession note.
Plan 32 (thread summaries, one model call per thread,
`docs/plans/2026-08-30-32-thread-summaries-one-call-per-thread.md`):
`scripts/summarize-thread.sh`, `scripts/file-thread.sh`,
`specs/thread-summary.md`, and `skills/onboarding-seed/`'s step 2 split into
triage → structured filing → thread summaries/filing → debrief-remainder
(D5) — `chat-message` captures no longer route through `skills/debrief/`'s
per-day episode-split model pass during onboarding/backfill.

Plan 34 (feedback ledger, docs/plans/2026-08-30-34-feedback-ledger.md):
`scripts/feedback-file.sh` (sole writer of `signals/feedback.jsonl`),
`scripts/feedback-parse.sh` (sole writer of `data/ingestion/feedback-cursor`
and `data/ingestion/feedback-applied.log`), `specs/feedback-ledger.md`,
`specs/feedback-parse.md`, and `contracts/feedback-event.md` 1.0.0's landing
(core-owned contract, ingestion-owned sole writer).

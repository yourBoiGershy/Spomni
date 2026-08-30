# package: core

version: 0.5.0

## Purpose

The vocabulary of the system: the versioned contracts every artifact conforms to, the
file templates, the store scripts (index, validation, queue append), and the shared
fixture pack. Core is the only package every other package depends on; it depends on
nothing.

## Provides

- Contracts (semver'd, each with a `schema_version`): `contracts/capture-event.md`,
  `contracts/person.md` (1.3.0 — third Facts provenance label
  `inferred-from-thread`, for facts the model infers from a chat/email
  thread the user is party to (neither told-by-user nor inferred-from-
  public-web), per plan 32; 1.2.0 — `tier_source` provenance field alongside
  `tier`, derived writes never overwrite a stated tier, per plan 31; 1.1.0 —
  optional `kind`/`kind_note`/`kind_source`/`kind_expires`/`kind_updated`,
  per plan 30), `contracts/interaction.md`,
  `contracts/signal-event.md`,
  `contracts/wakeup.md` (1.2.0 — `kind`/`proposed-event`/`confirmed-on`/
  `created-event-id` event-proposal additions, per plan 21; 1.1.0 added
  `fired-on`/`dismiss-reason`/`acted-on`/`snooze-count`, per plan 11),
  `contracts/connector-interface.md`,
  `contracts/derived-index.md` (index.json + stats.json), `contracts/profile.md`
  (`data/store/profile.md`, the stated-preference singleton, per plan 11),
  `contracts/ranking-weights.md` (`data/store/ranking-weights.json`, signal-type
  and tag calibration weights, per plan 11) (1.1.0 — `kinds`/`evidence` prior
  dimensions + first-write seeding and rescale clamp amendments, per plan 30),
  `contracts/eval-case.md` (the
  `packages/<pkg>/evals/cases/<name>/` format — prompt.md frontmatter,
  graders/ protocol, xfail discipline, suite manifests — per plan 12),
  `contracts/sync-lanes.md` (`<data-dir>/connectors/sync-scheduler/lanes.tsv`, the
  scheduled-syncs runner's lane config, per plan 19),
  `contracts/onboarding-backfill.md` (`<data-dir>/config/onboarding-backfill.tsv`,
  the user-configurable onboarding-backfill window + self-identity config, per
  plan 24),
  `contracts/import-pipeline.md` (the five-stage fetch/normalize/triage/
  judgment/file pipeline spanning connectors + ingestion, per plan 26),
  `contracts/user-model.md` (`data/store/user-model.md`, the user's
  relationship-investment model — draft→provisional/confirmed lifecycle,
  per plan 30; 1.1.0 — `status: provisional` cold-start auto-adopt value,
  per plan 31), `contracts/relationship-scoring.md` (kind vocabulary,
  judgment record, priors, breakdown string, drift prefilter, warrant
  rescale, per plan 30; 2.0.0 — unconfirmed tier writes are always
  `tier_source: derived`, per plan 31),
  `contracts/embeddings-index.md` (`<store>/index/embeddings.jsonl`, local
  optional embeddings, per plan 30),
  `contracts/week-plan.md` (`signals/week-plan.json`, the capacity-model
  weekly nudge budget artifact, per plan 12 — this is the RENUMBERED cadence
  plan, docs/plans/2026-08-29-12-cadence-capacity.md, not the earlier plan 12
  eval-harness numbering)
- Templates: `templates/person.md`, `templates/interaction.md`, `templates/wakeup.md`,
  `templates/profile.md`, `templates/sync-lanes.tsv`, `templates/user-model.md`
- Store scripts: `scripts/build-index.sh` (people/ → index.json; projects the
  1.1.0 `kind`/`kind_source`/`kind_expires` columns when present, per plan 30),
  `scripts/build-stats.sh` (people/ + interactions/ → stats.json, per
  `contracts/derived-index.md`), `scripts/validate-store.sh` (also validates
  person.md 1.1.0 kind fields, 1.2.0 `tier_source`, and 1.3.0
  `inferred-from-thread` Facts provenance, the optional
  `user-model.md` singleton incl. `status: provisional`, and the optional
  `index/embeddings.jsonl` incl. unit-norm vectors, per plans 30, 31, and 32),
  `scripts/init-store.sh` (idempotent store layout creation +
  README.md + index/stats + validate, refuses the code checkout itself),
  `scripts/check-store-location.sh` (flags a store-dir inside the code
  checkout, a cloud-sync folder, or sharing the code checkout's git remote;
  warns on TCC-protected `~/Documents`/`~/Desktop`/`~/Downloads`),
  `scripts/wakeup-add.sh`
  (the one sanctioned way any package appends a wake-up entry;
  `--signal-type` sets the 1.1 outcome fields at creation (plan 05)),
  `scripts/person-set-kind.sh` (the one sanctioned way ingestion writes the
  five `kind*` person.md frontmatter fields — derived writes never overwrite
  a stated kind, per plan 30),
  `scripts/person-set-tier.sh` (the one sanctioned way ingestion writes
  `tier`/`tier_source` — derived writes never overwrite a stated tier;
  `--clear` only from `stated-by-user`, per plan 31),
  `scripts/demo-store.sh` (materializes `fixtures/store/`'s 30 synthetic people
  into a runnable demo store — index/stats built, validated, self-describing
  `DEMO-STORE.md`; lets a stranger try the assistant without any real account),
  `scripts/gen-scale-store.sh` (generates an uncommitted synthetic large store for
  perf runs), `scripts/eval-run.sh` (T2 agent-tier eval runner, forward-declared —
  written by plan 12), `scripts/eval-run-skill.sh` (T3 skill-tier eval runner,
  forward-declared — written by plan 12), `scripts/eval-judge.sh`
  (structured-output haiku judge for eval graders, forward-declared — written by
  plan 12), `scripts/eval-suite.sh` (eval suite-manifest runner + cost-capped
  summary, forward-declared — written by plan 12)
- Fixtures: `fixtures/store/` (synthetic personas), `fixtures/corrupted/`

## Consumes

Nothing.

## Owned paths

`packages/core/**`. Core also owns the *shape* of the private data dir
(`inbox/`, `people/`, `interactions/`, `wakeups/`, `index.json`) — see the single-writer
table in docs/PROJECT-CONTEXT.md for who writes into each at runtime.

## Built by

Plan 01 (docs/plans/2026-08-29-01-contracts-and-store.md). `contracts/derived-index.md`
(stats.json half) and the forward-declared `scripts/build-stats.sh` /
`scripts/gen-scale-store.sh` by plan 08
(docs/plans/2026-08-29-08-chat-mcp-query-layer.md). `contracts/profile.md`,
`contracts/ranking-weights.md`, `templates/profile.md`, and the `wakeup.md`
1.1.0 bump by plan 11
(docs/plans/2026-08-29-11-preference-personalization.md). `contracts/eval-case.md`
by plan 12 (docs/plans/2026-08-29-12-eval-harness.md); the forward-declared
`scripts/eval-run.sh` / `scripts/eval-run-skill.sh` / `scripts/eval-judge.sh` /
`scripts/eval-suite.sh` are also plan 12, written in that plan's later work units.
The `wakeup.md` 1.2.0 event-proposal bump is by plan 21
(docs/plans/2026-08-29-21-calendar-intelligence.md); `wakeup-add.sh`'s
event-proposal creation flags are a later work unit of the same plan.
`contracts/onboarding-backfill.md` by plan 24
(docs/plans/2026-08-29-24-onboarding-backfill-priority-seeding.md).
`contracts/import-pipeline.md` by plan 26
(docs/plans/2026-08-29-26-standard-import-pipeline.md).
The `person.md` 1.1.0 kind fields and `ranking-weights.md` 1.1.0 bump are by
plan 30 (docs/plans/2026-08-29-30-semantic-scoring-user-model.md).
`contracts/user-model.md`, `templates/user-model.md`,
`contracts/relationship-scoring.md`, and `contracts/embeddings-index.md`
by plan 30 (docs/plans/2026-08-29-30-semantic-scoring-user-model.md).
`contracts/week-plan.md` by plan 12 (docs/plans/2026-08-29-12-cadence-capacity.md).
The `person.md` 1.2.0 `tier_source` field, `scripts/person-set-tier.sh`, the
`user-model.md` 1.1.0 `provisional` status, and the `relationship-scoring.md`
2.0.0 derived-tier-write rule are by plan 31
(docs/plans/2026-08-30-31-deterministic-filing-cold-start-priors.md).
The `person.md` 1.3.0 `inferred-from-thread` Facts provenance label is by
plan 32.

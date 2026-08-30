# package: core

version: 0.5.0

## Purpose

The vocabulary of the system: the versioned contracts every artifact conforms to, the
file templates, the store scripts (index, validation, queue append), and the shared
fixture pack. Core is the only package every other package depends on; it depends on
nothing.

## Provides

- Contracts (semver'd, each with a `schema_version`): `contracts/capture-event.md`,
  `contracts/person.md`, `contracts/interaction.md`, `contracts/signal-event.md`,
  `contracts/wakeup.md` (1.2.0 — `kind`/`proposed-event`/`confirmed-on`/
  `created-event-id` event-proposal additions, per plan 21; 1.1.0 added
  `fired-on`/`dismiss-reason`/`acted-on`/`snooze-count`, per plan 11),
  `contracts/connector-interface.md`,
  `contracts/derived-index.md` (index.json + stats.json), `contracts/profile.md`
  (`data/store/profile.md`, the stated-preference singleton, per plan 11),
  `contracts/ranking-weights.md` (`data/store/ranking-weights.json`, signal-type
  and tag calibration weights, per plan 11), `contracts/eval-case.md` (the
  `packages/<pkg>/evals/cases/<name>/` format — prompt.md frontmatter,
  graders/ protocol, xfail discipline, suite manifests — per plan 12),
  `contracts/sync-lanes.md` (`<data-dir>/connectors/sync-scheduler/lanes.tsv`, the
  scheduled-syncs runner's lane config, per plan 19),
  `contracts/onboarding-backfill.md` (`<data-dir>/config/onboarding-backfill.tsv`,
  the user-configurable onboarding-backfill window + self-identity config, per
  plan 24),
  `contracts/import-pipeline.md` (the five-stage fetch/normalize/triage/
  judgment/file pipeline spanning connectors + ingestion, per plan 26),
  `contracts/week-plan.md` (`signals/week-plan.json`, the capacity-model
  weekly nudge budget artifact, per plan 12 — this is the RENUMBERED cadence
  plan, docs/plans/2026-08-29-12-cadence-capacity.md, not the earlier plan 12
  eval-harness numbering)
- Templates: `templates/person.md`, `templates/interaction.md`, `templates/wakeup.md`,
  `templates/profile.md`, `templates/sync-lanes.tsv`
- Store scripts: `scripts/build-index.sh` (people/ → index.json),
  `scripts/build-stats.sh` (people/ + interactions/ → stats.json, per
  `contracts/derived-index.md`), `scripts/validate-store.sh`, `scripts/wakeup-add.sh`
  (the one sanctioned way any package appends a wake-up entry;
  `--signal-type` sets the 1.1 outcome fields at creation (plan 05)),
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
`contracts/week-plan.md` by plan 12 (docs/plans/2026-08-29-12-cadence-capacity.md).

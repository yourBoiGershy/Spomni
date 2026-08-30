# package: core

version: 0.5.0

## Purpose

The vocabulary of the system: the versioned contracts every artifact conforms to, the
file templates, the store scripts (index, validation, queue append), and the shared
fixture pack. Core is the only package every other package depends on; it depends on
nothing.

## Provides

- Contracts (semver'd, each with a `schema_version`): `contracts/capture-event.md`,
  `contracts/person.md` (1.4.0 — currency model: Open threads `(as-of
  YYYY-MM-DD)` / `unverified since` suffixes, optional `## Resolved`
  section, and a Facts `[stale]` marker restricted to inferred provenance,
  per plan 36; 1.3.0 — third Facts provenance label
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
  scheduled-syncs runner's lane config, per plan 19; 1.1.0 —
  `{{REPO_ROOT}}`/`{{DATA_DIR}}`/`{{PRIVATE_DATA_ROOT}}`/`{{STORE_DIR}}`/
  `{{CLAUDE_BIN}}` command placeholders, expanded per tick, per chunk 40),
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
  `contracts/feedback-event.md` (`<store>/signals/feedback.jsonl`, the
  append-only source-of-truth log of user feedback — dismissals, snoozes,
  tier/kind corrections, replies, model confirmations — per plan 34; 1.2.0 —
  additive `merge`/`noise-sender`/`stale-marked` event types, per plan 36),
  `contracts/week-plan.md` (`signals/week-plan.json`, the capacity-model
  weekly nudge budget artifact, per plan 12 — this is the RENUMBERED cadence
  plan, docs/plans/2026-08-29-12-cadence-capacity.md, not the earlier plan 12
  eval-harness numbering),
  `contracts/nudge-card.md` (renders a fired wake-up batch into one
  numbered, unsent-marked chat message via `scripts/render-nudge-cards.sh`;
  1.0.0, per plan 33),
  `contracts/answer-style.md` 1.0.0 — render rules for every user-facing
  answer/card (action-first, ≤2 lines/item, cap 5, draft on demand, no-guilt),
  `contracts/user-skill.md` (1.0.0 — `<data-dir>/skills/<name>/SKILL.md`,
  the shape and doctrine a user-authored skill inherits, per plan 42)
- Templates: `templates/person.md`, `templates/interaction.md`, `templates/wakeup.md`,
  `templates/profile.md`, `templates/sync-lanes.tsv`, `templates/user-model.md`,
  `templates/data-repo-CLAUDE.md` (the cold-session bootstrap `CLAUDE.md`
  `init-store.sh` writes into a store when absent — zero-setup query/debrief
  paths for a phone or cloud session opened directly on the data repo),
  `templates/user-skill.md` (the `SKILL.md` scaffold for a user-authored
  skill, per `contracts/user-skill.md`)
- Store scripts: `scripts/build-index.sh` (people/ → index.json; projects the
  1.1.0 `kind`/`kind_source`/`kind_expires` columns when present, per plan 30),
  `scripts/build-stats.sh` (people/ + interactions/ → stats.json, per
  `contracts/derived-index.md`), `scripts/reindex.sh` (the one call every
  store writer makes after touching `people/` or `interactions/` — runs
  `build-index.sh` then `build-stats.sh`, idempotent, exits non-zero on
  either's failure, per `contracts/derived-index.md` 1.1.0, plan 38),
  `scripts/validate-store.sh` (also validates
  person.md 1.1.0 kind fields, 1.2.0 `tier_source`, 1.3.0
  `inferred-from-thread` Facts provenance, and 1.4.0 Open threads as-of/
  `## Resolved`/Facts `[stale]`, the optional
  `user-model.md` singleton incl. `status: provisional`, and the optional
  `index/embeddings.jsonl` incl. unit-norm vectors, per plans 30, 31, 32, and 36),
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
  `scripts/person-merge.sh` (deterministic, no-model dedup merge of two
  person.md files — frontmatter union, Facts/Open-threads/Resolved/Personal-
  details merge, `[[slug]]` link rewrite across interactions/ and wakeups/,
  identities.tsv append, `people/.merged/<drop>.md` tombstone, merges.log,
  best-effort `feedback-file.sh --type merge` call, per plan 36 B1),
  `scripts/demo-store.sh` (materializes `fixtures/store/`'s 31 synthetic people
  into a runnable demo store — index/stats built, validated, self-describing
  `DEMO-STORE.md`; lets a stranger try the assistant without any real account),
  `scripts/gen-scale-store.sh` (generates an uncommitted synthetic large store for
  perf runs), `scripts/eval-run.sh` (T2 agent-tier eval runner, forward-declared —
  written by plan 12), `scripts/eval-run-skill.sh` (T3 skill-tier eval runner,
  forward-declared — written by plan 12), `scripts/eval-judge.sh`
  (structured-output haiku judge for eval graders, forward-declared — written by
  plan 12), `scripts/eval-suite.sh` (eval suite-manifest runner + cost-capped
  summary, forward-declared — written by plan 12), `scripts/heartbeat-stamp.sh`
  (the one sanctioned way a scheduled routine writes its
  `heartbeats/<routine>.json` completion stamp, per `contracts/heartbeat.md`),
  `scripts/store-sync.sh` (the one write-discipline entry point every runtime —
  laptop, launchd lane, phone/cloud session — uses against a git-backed store:
  `status`/`pull`/`commit`/`push`/`tick` (pull+commit+push in one call, quiet
  when nothing changed); reindexes + runs `validate-store.sh` before every
  commit and refuses to stage on failure; never rebases),
  `scripts/link-user-skills.sh` (symlinks each `<data-dir>/skills/<name>/`
  containing a valid `SKILL.md` into a personal-scope Claude Code skills dir
  (default `$HOME/.claude/skills`) — `--prune`/`--dry-run` supported, never
  clobbers a non-symlink or foreign symlink, per `contracts/user-skill.md`,
  plan 42)
- Fixtures: `fixtures/store/` (synthetic personas), `fixtures/corrupted/`
- Skills: `skills/make-skill/` (guided authoring of a user skill conforming
  to `contracts/user-skill.md`, per plan 42)

## Consumes

Nothing structurally — core depends on no other package's contracts. Two
sanctioned cross-package calls, both skip-with-log when the callee is
absent: `scripts/person-set-tier.sh` / `scripts/person-set-kind.sh` call
ingestion's `scripts/feedback-file.sh` (relative path) to append one
`feedback-event@1` line whenever the write being made is `stated-by-user`
(never for a derived write), per plan 34 D1. `contracts/eval-case.md`
1.3.0 also defines a private-manifest mode (`RA_EVAL_PRIVATE_MANIFEST`
read by `scripts/eval-suite.sh`): when a running suite manifest resolves
to that env var's path, that manifest's cases may point `store`/`expected`
at the private data dir containing it, skipping the ordinary `data/`
refusal for paths under that dir only.

## Owned paths

`packages/core/**`. Core also owns the *shape* of the private data dir
(`inbox/`, `people/`, `interactions/`, `wakeups/`, `heartbeats/`, `index.json`) — see the
single-writer table in docs/PROJECT-CONTEXT.md for who writes into each at runtime.

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
`contracts/feedback-event.md` by plan 34
(docs/plans/2026-08-30-34-feedback-ledger.md).

The `person.md` 1.3.0 `inferred-from-thread` Facts provenance label is by
plan 32.
The `person.md` 1.4.0 currency model (Open threads as-of/unverified-since,
`## Resolved`, Facts `[stale]`) and the `feedback-event.md` 1.2.0
`merge`/`noise-sender`/`stale-marked` event types are by plan 36
(docs/plans/2026-08-30-36-store-currency-dedup-remainder-speed-preference-loop.md).

`contracts/user-skill.md`, `templates/user-skill.md`, and
`scripts/link-user-skills.sh` are by plan 42
(docs/plans/2026-08-30-42-skills-platform.md).

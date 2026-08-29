# package: core

version: 0.1.0

## Purpose

The vocabulary of the system: the versioned contracts every artifact conforms to, the
file templates, the store scripts (index, validation, queue append), and the shared
fixture pack. Core is the only package every other package depends on; it depends on
nothing.

## Provides

- Contracts (semver'd, each with a `schema_version`): `contracts/capture-event.md`,
  `contracts/person.md`, `contracts/interaction.md`, `contracts/signal-event.md`,
  `contracts/wakeup.md`, `contracts/connector-interface.md`
- Templates: `templates/person.md`, `templates/interaction.md`, `templates/wakeup.md`
- Store scripts: `scripts/build-index.sh` (people/ → index.json),
  `scripts/validate-store.sh`, `scripts/wakeup-add.sh` (the one sanctioned way any
  package appends a wake-up entry)
- Fixtures: `fixtures/store/` (synthetic personas), `fixtures/corrupted/`

## Consumes

Nothing.

## Owned paths

`packages/core/**`. Core also owns the *shape* of the private data dir
(`inbox/`, `people/`, `interactions/`, `wakeups/`, `index.json`) — see the single-writer
table in docs/PROJECT-CONTEXT.md for who writes into each at runtime.

## Built by

Plan 01 (docs/plans/2026-08-29-01-contracts-and-store.md).

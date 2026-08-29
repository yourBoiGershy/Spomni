# Fixture: corrupted store

A mini synthetic store (`people/`, `interactions/`, `wakeups/`) that is
mostly valid, seeded with exactly 5 corruptions — one per file — for
`packages/core/scripts/validate-store.sh` to catch and for
`packages/core/tests/run-store-tests.sh` to assert against. All names are
invented (code/data separation — see `data/README.md`).

## Seeded corruptions

| File | Corruption kind |
|---|---|
| `interactions/2026-08-15-priya-nandakumar.md` | Broken link — `people` links to `[[hazel-winterbourne]]`, which has no matching `people/hazel-winterbourne.md`. |
| `people/jordan-abernathy.md` | Malformed frontmatter — missing the closing `---` delimiter. |
| `interactions/2026-08-10-orphan.md` | Orphan interaction — `people: []`, linking no one. |
| `people/leo-fenwick.md` + `people/leo-fenwick-duplicate.md` | Duplicate person slug — both files have `name: Leo Fenwick`, which kebab-cases to the same `leo-fenwick` slug, but live under different filenames so both exist on a case-insensitive filesystem. |
| `wakeups/2026-09-05-priya-nandakumar.md` | Invalid `status` — set to `someday`, which is not one of `pending`, `fired`, `snoozed`, `dismissed`. |

Everything else in this fixture set (the remaining people, interactions, and
wake-up files) is intentionally valid, so a validator run against this store
should report exactly these 5 findings and nothing else.

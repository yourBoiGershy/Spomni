# Fixture: corrupted store

A mini synthetic store (`people/`, `interactions/`, `wakeups/`) that is
mostly valid, seeded with exactly 8 corruptions — one per file (bar the
duplicate-slug pair, which spans two) — for
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
| `people/wendell-arkwright.md` | person.md 1.4.0 — a `**[told-by-user]**` Facts bullet also carries `[stale]`, which is only legal on `inferred-public-web`/`inferred-from-thread` facts. |
| `people/imogen-castellane.md` | person.md 1.4.0 — an Open threads bullet has a malformed `(as-of 2026-8-1)` suffix (not zero-padded `YYYY-MM-DD`). |
| `people/percival-nakashima.md` | person.md 1.4.0 — a `## Resolved` bullet is missing its required trailing `(resolved YYYY-MM-DD)` suffix. |

Everything else in this fixture set (the remaining people, interactions, and
wake-up files) is intentionally valid, so a validator run against this store
should report exactly these 8 findings and nothing else.

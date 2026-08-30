# Contributing

Thanks for looking. Spomni is small enough that one good PR changes it.

## The one rule

Every change answers the mission test in its first line: *does this cut a
running cost (coordinating, following up, scheduling, remembering-to), or
does it substitute for an ingredient (trust, care, intent, time)?* Only the
first is merged. Auto-send, generic drafts, engagement metrics, and anything
that performs the relationship on the user's behalf are permanently out of
scope — no matter how well built. See `docs/USE-CASES.md`.

## Ground rules

- **Draft, never send.** No PR may add a code path that sends without a human.
- **Synthetic data only.** Fixtures, goldens, evals, issue text: invented
  people, `example.com` addresses. CI's `oss-guard` rejects the rest.
- **Other people's data stays local.** No enrichment APIs, no scraping, no
  new cloud dependency that would hold the people-store.
- **bash 3.2, no npm in the pipeline.** The bash packages must run on a
  stock macOS shell. Only `packages/query/server` is Node.
- **Single writer.** Each runtime artifact has exactly one writing package;
  cross-package needs go through `packages/core/contracts/`, never another
  package's files. Bump the contract version and the `package.md` manifest
  when a contract changes.

## Workflow

```sh
git clone https://github.com/yourBoiGershy/Spomni.git && cd Spomni
git checkout -b my-change            # never work on main
bash scripts/test-all.sh             # every suite + oss-guard
```

Open a PR against `main`. CI runs the same script. A maintainer reviews for
the mission test first, correctness second, style last.

- Sync with `git merge main`, not rebase; never force-push; never `--amend`
  a pushed commit (the repo's git hooks block these when you work with
  Claude Code, and reviewers enforce them otherwise).
- If a setup step was needed to make your change work, add it to
  `docs/SETUP.md` in the same commit.
- Architecture and contracts: `docs/ARCHITECTURE.md`. Decisions with
  rationale: `docs/DECISIONS.md` — add a row when you make one.

## Working with Claude Code

The repo ships a delegation harness in `.claude/` (hooks, agents, two
orchestration skills). It is optional — plain editing works — but if you use
Claude Code here, the main session delegates code edits to worker agents by
design; `CLAUDE.md` explains why.

## Good first contributions

- A connector for a source you use (read the contract:
  `packages/core/contracts/capture-event.md`; connectors are dumb pipes).
- A Linux scheduler backend (`packages/connectors/scripts/sync-scheduler.sh`
  is launchd-only today).
- Filing goldens for conversation shapes we get wrong
  (`packages/ingestion/tests/goldens/`).

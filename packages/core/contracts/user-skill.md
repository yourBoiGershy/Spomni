# Contract: user-skill

`schema_version: 1.0.0`

## Scope

Governs skills a user authors for themselves — their own "what do I want
from my relationship data" logic (a personal who-next variant, a custom
digest, a bespoke sweep) — as a first-class, non-code artifact of their
private data dir. This is the platform contract: it defines where such a
skill lives, its file shape, and how it becomes an invocable Claude Code
skill, without the user ever touching this public repo.

## Store location

`<data-dir>/skills/<name>/SKILL.md` — sibling of `store/`, `config/`,
`connectors/` inside the user's private data dir. Never in this repo:
`data/` is gitignored and the public repo stays machinery-only (decision
`code-data-separation`, `docs/DECISIONS.md`). `<name>` is kebab-case and
must equal the SKILL.md frontmatter `name`.

A skill's directory may hold additional files it needs (scripts, fixtures,
prompts) alongside `SKILL.md` — only `SKILL.md` is contract-governed here.

## File format

Standard Claude Code skill format — YAML frontmatter followed by markdown
body:

```
---
name: <kebab-case, must equal the directory name>
description: <one line — used by the model to decide when to invoke this skill>
---

<markdown body: instructions the skill follows when invoked>
```

- `name` — required, kebab-case, must equal `<data-dir>/skills/<name>/`.
- `description` — required, one line, written for the *invoking* model
  (what the skill answers/does, and any read-only-vs-drafts caveat), not
  for the end user.

## Exposure

`packages/core/scripts/link-user-skills.sh <data-dir>` symlinks each
`<data-dir>/skills/<name>/` into the user-level skills dir
(`~/.claude/skills/<name>` by default, `--target-dir` overridable) —
**personal** scope, so the skill is invocable in any Claude Code session on
the machine, not just inside this repo's checkout. User skills are never
linked into, and never write to, this repo's project-scope
`.claude/skills/`.

## Doctrine user skills inherit

The platform (this repo's primitives) guarantees, and a user skill must
respect:

- **No auto-send path is exposed.** Every primitive a user skill can call
  ends at a draft; the human sends (`draft-never-send`,
  `docs/DECISIONS.md`). A user skill that wants to propose outreach stops
  at rendering a draft in-session — it never gains a send capability by
  virtue of running as a personal-scope skill.
- **Writes go through sanctioned core scripts only** — never raw edits to
  `people/`, `interactions/`, or any other store artifact. Use
  `packages/core/scripts/wakeup-add.sh` (queue a wake-up),
  `packages/core/scripts/person-set-tier.sh` (write `tier`/`tier_source`),
  `packages/core/scripts/person-set-kind.sh` (write the `kind*` fields),
  and `packages/core/scripts/store-sync.sh` (durability: pull/commit/push
  against a git-backed store). After any script that touches `people/` or
  `interactions/`, run `packages/core/scripts/reindex.sh` before reading
  `index.json`/`stats.json` again.
- **Provenance is mandatory on facts.** Any fact bullet a skill writes (via
  the filing engine, never directly) carries a provenance tag per
  `contracts/person.md` 1.4.0 — `[told-by-user]`, `[inferred-public-web]`,
  or `[inferred-from-thread]`. A user skill never invents a fact without
  one.
- **No enrichment APIs, no scraping.** Signals come only from the sources
  already sanctioned for this store (decision `tos-clean-signals-only`,
  `docs/DECISIONS.md`) — a user skill does not add a new external data
  source of its own.

## Pointers

- Authoring guide: `docs/SKILL-AUTHORING.md`.
- Scaffold to copy: `packages/core/templates/user-skill.md`.
- Guided authoring in-session: the `/make-skill` skill.

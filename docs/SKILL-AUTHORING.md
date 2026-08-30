# Build your own skill

Spomni is a data layer with opinions sold separately. The machinery in this
repo captures, files, deduplicates, and indexes your relationship data — and
ships a set of first-party skills (`/who-next`, `/debrief`, `/review-tiers`,
…) that are **worked examples, not the product**. They encode one user's
answer to "what do I want from this data." Yours may differ: a pre-trip
"who's in Lisbon" lookup, a mentor loop-closer, a client signal-watcher, a
promise-chaser with teeth. This doc is the contract for building that.

The fastest path is `/make-skill` — a guided flow that interviews you,
mission-tests the design, scaffolds the skill, and links it. This doc is the
reference underneath it.

## Where your skill lives

In **your private data repo**, not here:

```
<data-dir>/skills/<name>/SKILL.md
```

sibling of `store/`, `config/`, `connectors/`. Format per
`packages/core/contracts/user-skill.md` (a standard Claude Code skill:
frontmatter `name:` — must equal the directory name — and one-line
`description:`). Scaffold: `packages/core/templates/user-skill.md`.

Expose it with:

```sh
bash packages/core/scripts/link-user-skills.sh <data-dir>
```

which symlinks each skill into `~/.claude/skills/<name>` (user scope —
invocable from any session on your machine; `--prune` cleans up removed
skills, `--dry-run` previews). Your skills version and sync with your store,
and never touch this public repo — the code/data separation
(`code-data-separation`) applies to opinions too.

## The blessed API surface

Build against these; they are versioned and stable. Reaching into package
internals past them will break without notice.

**Read**

| Surface | What it gives you |
|---|---|
| `spomni-query` MCP tools | `search_people`, `get_person`, `get_interaction`, `list_interactions`, `get_contact_stats`, `suggest_reachouts`, `upcoming_meetings`, `who_next_pool` — the read-only query server (`packages/query/server/`) |
| `packages/query/scripts/who-next-direct.sh <store-dir>` | zero-dependency (bash+jq) candidate pool when the MCP server is down or cold |
| `index.json` / `stats.json` / `people/*.md` | direct reads, shapes per `packages/core/contracts/derived-index.md` and `person.md` |

**Write** — only ever through sanctioned core scripts; never raw edits to
`people/` or `interactions/`:

| Script | Purpose |
|---|---|
| `packages/core/scripts/wakeup-add.sh` | schedule a reminder/wake-up (the one nudge primitive) |
| `packages/core/scripts/person-set-tier.sh` / `person-set-kind.sh` | stated tier/kind writes, feedback-logged |
| `packages/core/scripts/reindex.sh` | mandatory after any store write |
| `packages/core/scripts/store-sync.sh` | git-backed store discipline (pull/commit/push/tick) |
| `/debrief` | free-text filing — the only path for prose into the store |

**Render** per `packages/core/contracts/answer-style.md` 1.0.0: action-first,
≤ 2 lines per item, cap 5, draft only on demand, no guilt mechanics.

## What the platform guarantees vs. what's on you

The doctrine here (`docs/USE-CASES.md` §1) is enforced at the layer we
control: **the primitives expose no send path.** There is no
"send this message" script, and there never will be — a skill built on the
blessed surface ends at a draft, and you hit send. Provenance fields are
required by the store validators; the enrichment denylist is linted in CI.

Your skills are your code in your private repo — nobody can stop you
wiring an auto-sender around the platform. But then it's *your* skill
substituting for *your* intent; the platform never hands you that gun. The
mission test is the design tool worth keeping even in private:

> Does this cut a running cost (remembering-to, noticing, timing,
> deciding-who, starting, following-through) — or substitute for an
> ingredient (trust, care, intent, time)?

## Scheduling a skill

A skill that should run without you asking is one `lanes.tsv` row per
`packages/core/contracts/sync-lanes.md` (the same runner that drives capture
lanes), or an in-session `/loop`. Wake-ups your skill schedules via
`wakeup-add.sh` fire through the ordinary queue and nudge delivery — you
don't build delivery, you enqueue.

## Checklist

1. Design it; run the mission test.
2. `mkdir -p <data-dir>/skills/<name>` and copy
   `packages/core/templates/user-skill.md` in as `SKILL.md`; fill it in.
3. `bash packages/core/scripts/link-user-skills.sh <data-dir>`.
4. Dry-run it in a session against the live store; iterate.
5. Commit it in the data repo: `git -C <data-dir> add skills/ && git -C <data-dir> commit`.

Or say `/make-skill` and let the session walk you through all five.

---
name: make-skill
description: Guided authoring of a user's own skill over their relationship store — interviews for the goal, applies the mission test, scaffolds `<data-dir>/skills/<name>/SKILL.md` from core's user-skill template, links it via link-user-skills.sh, and dry-runs it. Never writes into the public repo; authored skills draft, never send.
---

# make-skill

`/make-skill` — an in-session authoring flow that helps the user design and
scaffold their OWN skill over their relationship data (a personal who-next
variant, a mentor loop-closer, whatever running cost they want to cut next).
The result lands in their private data repo at `<data-dir>/skills/<name>/`
and is linked at user scope (`~/.claude/skills/<name>`) — never into this
public repo. Full authoring guide: `docs/SKILL-AUTHORING.md`.

## 1. Locate the data dir

Resolve `data/` in the current repo checkout — it symlinks to the user's
private data dir. If it does not resolve (missing symlink, no target), ask
the user for their private data repo's path. The new skill's directory will
be `<data-dir>/skills/<name>/`.

## 2. Interview

Ask what the user wants from their data — one or two questions max, then
propose a concrete skill design. Offer example shapes if they're stuck:

- a who-next variant with their own judgment rules
- "who's in `<city>` before a trip"
- a mentor loop-closer (advice given → report back on what happened)
- a client signal-watcher (renewal risk, a quiet thread gone cold)
- a promise-chaser (open commitments made *by* the user, surfaced on cadence)

Land on a concrete design: what it reads, what it decides, what it shows.

## 3. Mission test the design

Every design must answer: *does this cut a running cost — remembering-to,
noticing, timing, deciding-who, starting, following-through — or substitute
for an ingredient — trust, care, intent, time?* Only cost-cutting designs are
built.

If the proposed design would auto-send a message, or otherwise perform the
relationship on the user's behalf (writing warmth into a message the user
never saw, deciding on the user's behalf who to prioritize with no review),
redesign it to end at a draft the human reviews and sends themselves. This is
non-negotiable platform doctrine (`draft-never-send`) — state that plainly if
the user pushes back on it.

## 4. Pick surfaces from the blessed API

Paste this table into the authored skill as its Read/Write path — the user's
skill must only touch the store through these surfaces, never raw edits:

**READ** — `spomni-query` MCP tools (`search_people`, `get_person`,
`get_interaction`, `list_interactions`, `get_contact_stats`,
`suggest_reachouts`, `upcoming_meetings`, `who_next_pool`); fallback
`bash packages/query/scripts/who-next-direct.sh <store-dir>`; direct
`index.json`/`stats.json`/`people/*.md` reads.

**WRITE** (only ever via these; never raw edits to `people/` or
`interactions/`) — `packages/core/scripts/wakeup-add.sh` (schedule a
reminder wake-up), `person-set-tier.sh`, `person-set-kind.sh`,
`reindex.sh` after any store write, `store-sync.sh` for git-backed stores;
free-text filing goes through `/debrief`.

**RENDER** — per `packages/core/contracts/answer-style.md` 1.0.0
(action-first, ≤2 lines per item, cap 5, draft only on demand).

## 5. Scaffold

Copy `packages/core/templates/user-skill.md` to
`<data-dir>/skills/<name>/SKILL.md`, then write the user's actual behavior
into it: concrete tool calls, judgment rules in the user's own words,
answer-style rendering matching step 4's table. The frontmatter `name:`
must equal the directory name (`<name>`).

## 6. Link

Run:

```
bash packages/core/scripts/link-user-skills.sh <data-dir>
```

Tell the user it lands in `~/.claude/skills/<name>` — personal scope,
available in any session on this machine; new sessions pick it up
automatically, no restart needed.

## 7. Dry-run

Execute the authored skill's steps once right now against the live store
and show the answer. Iterate the SKILL.md with the user until it reads
right — this is the fastest way to catch a bad judgment rule or a wrong
tool call before the user relies on it.

## 8. Persist

Remind the user: the skill lives in their private data repo, not this
public one. They must commit it there themselves:

```
git -C <data-dir> add skills/ && git -C <data-dir> commit
```

Never commit it into this repo.

## Doctrine the authored skill must carry

- **Draft, never send.** The authored skill proposes; the human sends. No
  exceptions, regardless of what the user asks for.
- **Provenance labels.** Any fact the skill writes carries its source, per
  person.md 1.4.0: `**[told-by-user]**` / `**[inferred-public-web]**` /
  `**[inferred-from-thread]**` — never mixed or left unlabeled.
- **Read-only by default.** Writes go only through the blessed scripts in
  step 4; the skill should default to reading and rendering, writing only
  when the user explicitly asks it to schedule, tier, or file something.
- **No enrichment.** No LinkedIn scraping, no third-party enrichment APIs —
  the people-store stays local, sourced only from what the user told the
  agent or what their own connectors surface.
- **Capture stays optional and guilt-free.** No streak mechanics, no
  "overdue" framing, no backlog guilt in user skills either — this is
  advisory since it's their own repo, but carry it forward anyway.

# Your Spomni data repo

This repo is your private Spomni **people-store** — `people/`, `interactions/`,
`inbox/`, `wakeups/`, `index.json`, `stats.json`. It holds data only: the
machinery that reads and writes it (connectors, filing engine, query skills)
lives in the public Spomni repo, cloned separately. Nothing in this repo is
code; nothing in the machinery repo is your data.

## Answering questions from a cold session (phone / cloud)

Do NOT run `npm ci` or start the `spomni-query` MCP server — that costs ~90 s
and is unnecessary for read-only answers. Use the zero-setup path:

0. Step 0, before reading anything: pick up what other machines pushed —
   `bash machinery/packages/core/scripts/store-sync.sh . pull`
   (clone the machinery first if it isn't there yet, step 1 below).
1. Clone the machinery next to this checkout (shallow):
   `git clone --depth 1 https://github.com/<your-github-user>/Spomni.git machinery`
2. Run the direct reader against THIS directory:
   `bash machinery/packages/query/scripts/who-next-direct.sh . --mode coffee|friends|all --limit 20`
3. Follow `machinery/packages/query/skills/who-next/SKILL.md` from step 3 onward.

Needs only bash + jq. Read-only: never write into this repo from a query
session. Add `machinery/` to this repo's `.gitignore` — it's a disposable
clone of the code, not part of your data:

```
machinery/
```

## Debriefing from a cold session

0. Step 0, before writing anything: pick up what other machines pushed —
   `bash machinery/packages/core/scripts/store-sync.sh . pull`
   (clone the machinery first if it isn't there yet, step 1 below).
1. Clone the machinery next to this checkout (shallow), same as above:
   `git clone --depth 1 https://github.com/<your-github-user>/Spomni.git machinery`
2. Run the debrief skill against the capture event(s), with this directory as
   the store: `machinery/packages/ingestion/skills/debrief/SKILL.md` (store
   dir = `.`).
3. Commit and push with zero typed git commands:
   `bash machinery/packages/core/scripts/store-sync.sh . commit -m "debrief: <one line>"`
   `bash machinery/packages/core/scripts/store-sync.sh . push`
4. End the session by landing: if the work happened on a branch, run
   `bash machinery/packages/core/scripts/store-land.sh .` (validates, merges
   the branch into the default branch — never rebases — and pushes); on the
   default branch the push above (or `store-sync.sh . tick`) is all there is.

`store-sync.sh commit` reindexes and runs `validate-store.sh` before staging
anything — it refuses to commit a store that fails validation. If it prints
`FAIL:`, surface that to the user; do not hand-fix the store with raw git
commands.

Git identity in a cloud sandbox comes from the environment — set
`SPOMNI_GIT_NAME` / `SPOMNI_GIT_EMAIL` if you have them, otherwise
`store-sync.sh` falls back to `Spomni <spomni@localhost>`.

## Rules

- Draft, never send. Any message text produced here is a draft for the human
  to review and send themselves — nothing in this repo or the machinery ever
  sends on the user's behalf.
- Other people's data stays in this private repo, never in the public
  machinery repo — no facts, names, or messages about anyone belong in code.
- Provenance labels on facts (`stated-by-user`, `inferred-from-public-web`,
  `inferred-from-thread`) are never mixed or dropped when copying or editing
  a fact.

# data/ — your private relationship store

**Nothing in this directory is ever committed to this repo** (gitignored,
except this README). Code and data are separate on purpose: this public repo
is machinery; your contact graph is other people's personal information and
belongs only to you.

Point this directory at your own PRIVATE store — either a private git repo
cloned here, or a symlink to one:

```sh
git clone git@github.com:<you>/<your-private-people-store>.git data/store
# or start empty:
bash packages/core/scripts/init-store.sh ~/spomni-store && ln -s ~/spomni-store data/store
# or just try it with fictional people:
bash scripts/setup.sh --demo
```

Expected shape (`init-store.sh` creates it; contracts in `packages/core/contracts/`):

```
data/store/
├── inbox/          # normalized capture events (voice notes, parsed emails) — raw kept forever
├── people/         # one markdown file per person
├── interactions/   # one note per debrief/meeting, linked to people + events
├── wakeups/        # the scheduler's queue: dated who/why/context entries
├── index.json      # auto-generated queryable index
└── stats.json      # auto-generated touchpoint/gap stats
```

Connector state (`data/connectors/<lane>/` — cursors, the Beeper token,
`sync-scheduler/lanes.tsv`) also lives here and is never committed.

Never point `data/` at anything shared, synced (iCloud/Dropbox), or public —
`bash packages/core/scripts/check-store-location.sh data/store` refuses those.
Never add scraped data — first-party sources only, per the project principles
in CLAUDE.md.

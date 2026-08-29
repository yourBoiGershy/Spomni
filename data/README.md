# data/ — your private relationship store

**Nothing in this directory is ever committed to this repo** (gitignored,
except this README). Code and data are separate on purpose: this public repo
is machinery; your contact graph is other people's personal information and
belongs only to you.

Point this directory at your own PRIVATE store — either a private git repo
cloned here, or a symlink to one:

```sh
git clone git@github.com:<you>/<your-private-people-store>.git data/store
```

Expected shape (created by the assistant as it runs; contracts land with the
next build wave):

```
data/store/
├── inbox/          # normalized capture events (voice notes, parsed emails) — raw kept forever
├── people/         # one markdown file per person
├── interactions/   # one note per debrief/meeting, linked to people + events
├── wakeups/        # the scheduler's queue: dated who/why/context entries
└── index.json      # auto-generated queryable index
```

Never point `data/` at anything shared or public. Never add scraped data —
first-party sources only, per the project principles in CLAUDE.md.

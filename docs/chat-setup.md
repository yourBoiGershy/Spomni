# Chat with your own data

This is the "chat with your own data" path: point the project's read-only query
server at your private store, register it, and ask questions. The server never
writes to the store — see `packages/query/package.md` for the contract.

## 1. Point `data/store` at your private store

`data/` is gitignored except for its README (see `data/README.md`). Point
`data/store` at your own private store — either clone it there directly or
symlink to an existing clone:

```sh
git clone git@github.com:<you>/<your-private-people-store>.git data/store
# or, if you already have a clone elsewhere:
ln -s /path/to/your/clone data/store
```

**Interim note:** capture-store ↔ data-repo sync is not built yet (that lands
in plans 09/19). Until then, if your fresh captures are landing somewhere
other than a data-repo clone, symlink `data/store` at your live capture
location instead. This is a local, gitignored act — flipping the symlink
later to the synced data-repo clone changes nothing about the registration
below.

## 2. Install server dependencies (once per checkout)

```sh
(cd packages/query/server && npm install)
```

`node_modules` is gitignored, so this is a one-time step per checkout (each
worktree needs its own).

## 3. Approve the server registration

The repo root `.mcp.json` registers a project-scope server, `spomni-query`,
pointed at `data/store` (repo-relative paths only — no per-machine config).
The first Claude Code session opened in this checkout after cloning/pulling
will prompt you to approve it. Approve it once; every session in this
checkout picks it up automatically after that.

## 4. Run the smoke test

Verify the server is live against your store before chatting:

```sh
bash packages/query/tests/smoke-live.sh
```

All six tools (`search_people`, `get_person`, `list_interactions`,
`get_interaction`, `get_contact_stats`, `suggest_reachouts`) must print PASS.
If `data/store` has no `index.json`/`stats.json` yet, the server regenerates
both into `${RA_CACHE_DIR:-~/.cache/relationship-agent}` on the fly — your
store directory itself is never written to.

## 5. Ask questions

Once approved and smoked, just ask, in any session in this checkout:

- "Who do I know at \<company\>?"
- "When did I last talk to \<person\>?"
- "Who should I reach out to this week?"

Answers cite the store file paths they were drawn from, and facts are labeled
by provenance (told-by-you vs. inferred-from-public-web) — never mixed.

## Migration: remove any legacy registration

If you previously registered `spomni-query` at user scope (before this
project-scope `.mcp.json` existed), remove it so exactly one registration
remains:

```sh
claude mcp remove spomni-query
```

Run this in whatever scope/project the old entry was added under. Leaving a
stale user-scope entry alongside the project-scope one can shadow or conflict
with the registration described above.

## User-scope alternative (non-project contexts)

If you need the server available outside any project checkout (e.g. a
one-off session with no repo open), you can add it at user scope directly,
with explicit absolute paths:

```sh
claude mcp add spomni-query --scope user -- \
  node --experimental-strip-types /absolute/path/to/packages/query/server/src/index.ts \
  --store /absolute/path/to/your/store
```

Prefer the project-scope registration above whenever you're working inside a
checkout — it needs no machine-specific paths and works for anyone who clones
the repo.

## Out of scope (for now)

- **Cloud-session registration** (wiring the server against a data-repo-side
  `machinery/` clone for non-local runtimes) awaits plan 09's cloud runtime
  doc.
- **`--http` transport** stays stubbed; stdio is the only supported transport
  today.

# Plan 40 — Dynamic sync routing

**Mission test:** infrastructure for *remembering-to* — the 15-minute lanes
must keep firing against the right checkout and the right store without a
human re-editing absolute paths. Cuts a running cost; touches no ingredient.

## Problem (observed 2026-08-30)

The live `com.relationship-agent.sync.beeper` launchd agent fires every 900s
but is bound to a dead worktree (`relationship-agent-worktrees/connectors`,
stuck at PR #3) and writes captures into an orphan store. Every path in the
chain is absolute at install time: `lanes.tsv` command, plist
`ProgramArguments`, beeper `config.json.store_dir`. Moving a checkout
silently orphans sync.

## Design

1. **Placeholders, resolved per tick** (`sync-lanes` 1.1.0). A `command`
   may contain `{{REPO_ROOT}}`, `{{DATA_DIR}}`, `{{PRIVATE_DATA_ROOT}}`,
   `{{STORE_DIR}}`, `{{CLAUDE_BIN}}`. `sync_run_lane` expands them at run
   time from the scheduler script actually executing and also exports
   `SPOMNI_REPO_ROOT / SPOMNI_DATA_DIR / SPOMNI_PRIVATE_DATA_ROOT /
   SPOMNI_STORE_DIR / SPOMNI_CLAUDE_BIN` into the command's environment.
   - REPO_ROOT = root of the checkout whose `sync-scheduler.sh` is running
   - DATA_DIR = `--data-dir` (default `<REPO_ROOT>/data`), absolute
   - PRIVATE_DATA_ROOT = `dirname(DATA_DIR)` (deliver-tick / feedback-parse
     expect `<root>/data/...`)
   - STORE_DIR = `cd "$DATA_DIR/store" && pwd -P` (follows the symlink);
     if absent, the literal `$DATA_DIR/store`
   - CLAUDE_BIN = `$SPOMNI_CLAUDE_BIN` if set, else `command -v claude`,
     else `$HOME/.claude/local/claude` if executable, else literal `claude`
2. **Template ships placeholders** — `core/templates/sync-lanes.tsv` has no
   `<ABS-…>` markers; `setup.sh --lanes` and the new
   `sync-scheduler.sh init` copy it verbatim.
3. **`install` retires legacy agents** — every installed
   `com.relationship-agent.sync.*` plist is booted out and removed (printed
   as `retired legacy <label>`; `--dry-run` prints `Would retire …`).
4. **`resolve <lane>`** prints the fully expanded command so routing is
   inspectable; `status` unchanged.
5. **beeper-in `store_dir` optional** — when absent/empty, the sweep uses
   `<data-dir>/../../store` resolved with `pwd -P`; unresolvable → error
   exit 1 with a `runs.log` line.

## Units

| # | Package | Unit |
|---|---|---|
| A | connectors/scripts | sync-lib placeholder expansion + `init` + `resolve` + legacy retire on install; package.md |
| B | core | contract 1.1.0 + template placeholders; package.md |
| C | connectors/beeper-in | default store_dir; package.md |
| D | connectors/tests | scheduler tests (expansion, init, resolve, legacy retire dry-run) + beeper default-store test |
| E | root | `scripts/setup.sh --lanes` copies verbatim; `docs/SETUP.md` |

## Live cutover (after merge, user session)

`sync-scheduler.sh init && install && status` from the main checkout; copy
beeper `config.json` (drop `store_dir`) + `token` into
`data/connectors/beeper-in/`; decide fate of the 74 orphan inbox files.

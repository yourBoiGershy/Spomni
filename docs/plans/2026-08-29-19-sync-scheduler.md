# Plan 19 — Scheduled syncs runner

Status: Done (2026-08-29, chunk-19-sync-scheduler) — machinery built, tested,
installed, and verified; live firing blocked machine-side by macOS TCC (see
"Live verification results" below), user grant pending.
Depends on: 13 (beeper lane live). 17's gmail/calendar lanes are future config rows —
the scheduler is config-driven, so 17 is not a build blocker; its lanes get one
`lanes.tsv` line each when they exist.

## Goal

One configurable, restart-safe scheduler for all capture lanes. A lane is a name +
command + interval + enabled flag in a config file (contract in core); an installer
renders one launchd agent per enabled lane; a `status` subcommand reports
last-run/next-run/last-exit per lane; logs rotate; beeper's hand-rolled launchd job
(plan 13) migrates in and its bespoke installer is deleted.

## Design decisions (settled — workers do not re-litigate)

- **launchd is the restart story.** Per-user agents under `~/Library/LaunchAgents`
  survive reboots natively. `StartInterval` jobs do not fire while the machine
  sleeps; on wake, launchd fires a job once if its interval elapsed during sleep
  (catch-up is coalesced to one run, not replayed). Cursors make lanes
  loss-tolerant across gaps, so one coalesced catch-up run is sufficient.
- **Config is data, not code.** Runtime config lives in the private data dir:
  `<data-dir>/connectors/sync-scheduler/lanes.tsv`. Repo carries the contract
  (core) and a commented template (core templates). Interval/enable changes are
  config edits + `install` re-run — zero code edits.
- **Label convention:** `com.relationship-agent.sync.<lane>` (repo branding
  unchanged post-Spomni-rename, matches existing `com.relationship-agent.*`).
- **The plist runs the scheduler, not the lane command directly:**
  `sync-scheduler.sh run <lane>` is the launchd entrypoint, so state recording,
  logging, and rotation apply uniformly to every lane.
- **bash 3.2, no jq/npm** — same portability bar as beeper-sweep.sh. TSV config,
  no JSON.
- **Two script files** so two workers can build in parallel:
  `sync-lib.sh` (config/state/log/run primitives) + `sync-scheduler.sh` (CLI +
  launchd install/uninstall/status). API pinned below.

## Contract: `sync-lanes` 1.0.0 (core)

File `packages/core/contracts/sync-lanes.md`. Governs
`<data-dir>/connectors/sync-scheduler/lanes.tsv`:

- One lane per line: `lane<TAB>interval_seconds<TAB>enabled<TAB>command`.
  `command` is the remainder of the line (may contain spaces, never tabs).
- `lane`: `[a-z0-9-]+`, unique within the file.
- `interval_seconds`: integer ≥ 60.
- `enabled`: literal `true` or `false`.
- `command`: absolute-path invocation, run via `/bin/bash -c` under launchd's
  minimal environment (no user shell profile — commands must not assume PATH
  beyond /usr/bin:/bin:/usr/sbin:/sbin). Skip conditions inside a lane (no
  token, source unreachable) exit 0 per connector-interface sweeps convention.
- Blank lines and `#` comments ignored. A malformed row fails the whole file
  (fail-closed: the installer refuses to act on a config it can't fully parse).

Template `packages/core/templates/sync-lanes.tsv`: commented header + a beeper
example row + commented-out gmail-in/calendar-in placeholder rows for plan 17.

## Runtime layout (under `<data-dir>/connectors/sync-scheduler/`)

- `lanes.tsv` — the config (user-edited).
- `state/<lane>.tsv` — single line `last_start<TAB>last_end<TAB>last_exit`
  (ISO-8601 UTC), atomically written (tmp+mv).
- `logs/<lane>.log` — scheduler + command output, rotated: before an append or
  run, if > 512000 bytes → `mv` to `<lane>.log.1` (previous `.1` overwritten).
- `logs/<lane>.launchd.log` — launchd's own stdout/stderr capture (belt and
  suspenders; normally near-empty since `run` redirects into `<lane>.log`).

## Pinned lib API (`packages/connectors/scripts/sync-lib.sh`)

Sourced, side-effect-free on source, `set -u`-safe, bash 3.2 (no assoc arrays,
no mapfile). All functions take explicit args — no globals shared with callers.

- `sync_config_path <data_dir>` → echo `<data_dir>/connectors/sync-scheduler/lanes.tsv`
- `sync_lanes_list <config_file>` → validate whole file; print one
  `name<TAB>interval<TAB>enabled<TAB>command` row per lane to stdout. Any
  malformed row: `sync-lib: <file>:<lineno>: <reason>` on stderr, exit 1,
  no stdout. Missing file: stderr note, exit 1.
- `sync_lane_get <config_file> <lane>` → print that lane's row, exit 0;
  unknown lane → exit 2; invalid config → exit 1.
- `sync_state_read <data_dir> <lane>` → print `start<TAB>end<TAB>exit` or the
  literal `NEVER_RUN`; always exit 0.
- `sync_state_write <data_dir> <lane> <start_iso> <end_iso> <exit_code>` →
  atomic (tmp+mv), creates dirs as needed.
- `sync_log_file <data_dir> <lane>` → echo the log path.
- `sync_log_append <data_dir> <lane> <message>` → append `<ISO-UTC> <message>`,
  rotating first if over the cap.
- `sync_run_lane <config_file> <data_dir> <lane>` → unknown lane: stderr +
  exit 2. Disabled: `sync_log_append ... "skip-disabled"`, exit 0. Enabled:
  log `run-start`, record start, run command via `/bin/bash -c` with
  stdout+stderr appended to the lane log, record state, log
  `run-end exit=<code> duration=<s>s`, exit with the command's code.

## CLI (`packages/connectors/scripts/sync-scheduler.sh`)

Self-locates `REPO_ROOT` (script is at `packages/connectors/scripts/`, so
`REPO_ROOT=$SCRIPT_DIR/../../..`); default data dir `$REPO_ROOT/data`, override
`--data-dir <dir>` (accepted by every subcommand). Sources `sync-lib.sh`.

- `run <lane>` — delegate to `sync_run_lane` (launchd entrypoint).
- `install [--dry-run]` — for each **enabled** lane: render
  `launchd/com.relationship-agent.sync.plist.template` substituting
  `__LABEL__ __SCHEDULER__ __LANE__ __DATA_DIR__ __INTERVAL__ __WORKDIR__`
  (scheduler = abs path to sync-scheduler.sh, workdir = repo root), write to
  `~/Library/LaunchAgents/<label>.plist`, `launchctl bootout` any prior
  instance (ignore failure), `launchctl bootstrap gui/$UID`. Then **prune**:
  every `~/Library/LaunchAgents/com.relationship-agent.sync.*.plist` whose lane
  is not currently an enabled configured lane → bootout + remove, echo
  `pruned <label>`. Idempotent. `--dry-run`: print rendered plists + actions,
  touch nothing.
- `uninstall <lane>|--all [--dry-run]` — bootout + remove matching plists.
- `status` — one row per configured lane (enabled or not), columns:
  `LANE ENABLED INTERVAL INSTALLED LAST_RUN LAST_EXIT NEXT_RUN`. INSTALLED =
  plist exists AND `launchctl print gui/$UID/<label>` succeeds. LAST_RUN /
  LAST_EXIT from state, `NEVER_RUN`/`-` when absent. NEXT_RUN =
  last_start + interval (UTC ISO) when installed+ran, `on-next-interval` when
  installed but never run, `-` when not installed. Installed
  `com.relationship-agent.sync.*` plists with no config row print an extra
  `ORPHAN` row. Every configured lane emits exactly one row — silence is
  impossible. Exit 0 (it's a report).

Plist template (`packages/connectors/scripts/launchd/com.relationship-agent.sync.plist.template`):
mirror of the plan-13 template (`RunAtLoad` false, `StartInterval`), but
ProgramArguments = `/bin/bash __SCHEDULER__ run __LANE__ --data-dir __DATA_DIR__`,
Std{Out,Err}Path = `<data-dir>/connectors/sync-scheduler/logs/<lane>.launchd.log`.

## Beeper migration

- Repo: delete `beeper-in/scripts/install-launchd.sh` and `beeper-in/launchd/`;
  note the scheduler in `beeper-in/package.md` and root connectors `package.md`.
- Live (operations, post-merge, from the connectors worktree which owns the
  live beeper data dir): write `lanes.tsv` with the beeper row (900s), bootout
  legacy label `com.relationship-agent.beeper-in` + remove its plist, run
  `sync-scheduler.sh install`, verify `status`, kickstart one live run, then
  simulate reboot (bootout + bootstrap) and confirm the job re-fires.

## Tests

`packages/connectors/tests/run-scheduler-tests.sh` (offline, bash 3.2, no
launchctl calls — install/uninstall covered via `--dry-run` only): config
parsing valid/malformed/missing, lane lookup exit codes, state
read/write/NEVER_RUN, log append + rotation at cap, `run` on a stub command
(records state, appends output, propagates exit code), `run` skip-disabled,
`run` unknown lane, dry-run install rendering (label/interval/paths correct;
disabled lane excluded), dry-run uninstall, status row shape for
never-run/not-installed/disabled lanes. Registered in CLAUDE.md test commands.

## Work units

Wave 1 (parallel): W1 core contract+template; W2a sync-lib.sh; W2b
sync-scheduler.sh + plist template; W3 beeper legacy removal + manifests.
Wave 2: W4 test suite. Then: checker verification, live migration ops,
ROADMAP/docs updates, merge to main, GrowthPal log.

## Proof of done (from ROADMAP)

All active lanes running under the scheduler; `status` correct; a simulated
reboot (bootout+bootstrap) after which jobs fire with no manual step; beeper's
legacy job removed; interval/disable config change takes effect with no code
edit.

## Live verification results (2026-08-29)

Green: suites store 20 / capture 82 / beeper 70 / scheduler 64; live install of
`com.relationship-agent.sync.beeper` (legacy `com.relationship-agent.beeper-in`
booted out and its plist removed); `status` row correct; reboot simulation
(bootout + bootstrap from the on-disk plist) reloads with no manual step;
config change proven live (interval 900→600→900 via `lanes.tsv` edits +
re-`install`, `launchctl print` confirmed each time, zero code edits);
malformed config row fail-closed live (`expected 4 tab-separated fields`,
install aborts, exit 1).

**Blocker found (machine-side, not machinery):** launchd background jobs run
`/bin/bash` WITHOUT macOS TCC access to `~/Documents` — a probe job read
`$HOME` fine and got `Operation not permitted` exactly at `~/Documents`. Every
scheduled fire exits 126 before the script loads. **This also invalidated
plan 13's standing assumption:** the legacy beeper launchd job had failed the
same way on every 15-minute fire since install — its only successful sweep was
the manual terminal run at deploy time (terminal sessions carry the user's TCC
grants; launchd agents don't). Remediation is a user action, either: (a) grant
`/bin/bash` Full Disk Access (System Settings → Privacy & Security → Full Disk
Access → + → ⌘⇧G → `/bin/bash`) — quick, standard for launchd shell agents; or
(b) relocate the machinery + data worktrees outside `~/Documents` (durable, no
TCC surface, aligns with the always-on-box portability story). The scheduler
starts working at the next interval after either lands — nothing to reinstall.

# First-run setup (macOS)

Everything a new user must do ONCE to get Spomni capturing, filing, and
answering. Work top to bottom; each step says how to verify itself before you
move on.

> **Maintenance rule (for the assistant as much as for humans):** this file is
> the single home for machine-level setup. Any session that discovers a new
> required setup step — a permission, an auth flow, a config file, a gotcha —
> adds it here in the same commit as the fix. Setup knowledge never lives only
> in a session transcript or a plan file.

## 0. Prerequisites

- macOS (scheduling uses launchd; other platforms not yet supported)
- git, and the [Claude Code](https://claude.com/claude-code) CLI
- A private GitHub repo (or any private location) for YOUR data — the
  contact graph never lives in this public repo (`data/README.md`)
- Optional, for personal-chat capture: [Beeper Desktop](https://www.beeper.com)

## 1. Choose where the repo lives — this matters

**If the repo (or your data dir) lives under `~/Documents`, `~/Desktop`, or
`~/Downloads`, macOS TCC will silently block every scheduled sync.** launchd
background jobs run without your terminal's folder permissions: each fire
exits 126 with `Operation not permitted` before the script even loads, while
manual runs from your terminal work fine — so the breakage is invisible until
you look. (Discovered the hard way in plan 19: the plan-13 beeper job never
fired once on schedule.)

Pick ONE:

- **Easiest to reason about:** clone somewhere unprotected, e.g. `~/spomni/`.
  No grants needed, nothing else to remember.
- **Keep it under Documents:** grant `/bin/bash` Full Disk Access —
  System Settings → Privacy & Security → Full Disk Access → **+** →
  press **⌘⇧G**, type `/bin/bash`, Return → select **bash**, toggle on.
  Takes effect immediately; nothing to reinstall or reboot.

Verify (after step 5 installs a lane): `launchctl kickstart
gui/$UID/com.relationship-agent.sync.<lane>`, then confirm `LAST_EXIT 0` in
the scheduler's `status` output. Exit `126` here always means this step.

## 2. Get the code and your private store

```sh
git clone https://github.com/yourBoiGershy/Spomni.git
cd Spomni
git clone git@github.com:<you>/<your-private-people-store>.git data/store
```

`data/` is gitignored — see `data/README.md` for the expected store shape.

## 3. Connect your accounts (the pipes)

Connectors are pipes, never stores — everything they fetch lands in YOUR
data dir only.

- **Google (email + calendar):** in a Claude Code session in this repo, run
  `/mcp` and authenticate the first-party **Gmail** and **Google Calendar**
  connectors (decision `first-party-mcp-only`, plan 17).
- **Beeper (WhatsApp/LinkedIn/Signal/etc. personal chats):** install Beeper
  Desktop and sign in; connect the networks you want tracked. Then:
  - Enable the local Client API and register the MCP server:
    `claude mcp add --transport http beeper http://127.0.0.1:23373/v0/mcp`
    (complete the OAuth prompt).
  - Create `data/connectors/beeper-in/config.json` from
    `packages/connectors/beeper-in/config.example.json` — list the accountIDs
    to capture; save the API token beside it and `chmod 600` it.
  - **Turn OFF** Settings → Integrations → *remote access* in Beeper Desktop —
    it binds the API to 0.0.0.0 (LAN-visible); the capture lane only needs
    127.0.0.1.
  - Verify: `bash packages/connectors/beeper-in/scripts/beeper-sweep.sh
    --list-accounts` prints your accounts.

## 4. Chat with your data (query layer)

The read-only query MCP server (`spomni-query`, 6 tools) is registered by the
repo-committed `.mcp.json` (plan 18) — opening a Claude Code session in the
repo picks it up; approve the server when prompted. Details:
`docs/chat-setup.md`.

## 5. Scheduled syncs (set-and-forget capture)

One scheduler runs every capture lane on an interval (contract:
`packages/core/contracts/sync-lanes.md`).

```sh
mkdir -p data/connectors/sync-scheduler
cp packages/core/templates/sync-lanes.tsv data/connectors/sync-scheduler/lanes.tsv
$EDITOR data/connectors/sync-scheduler/lanes.tsv   # absolute paths, real tabs
bash packages/connectors/scripts/sync-scheduler.sh install
bash packages/connectors/scripts/sync-scheduler.sh status
```

- Every enabled lane becomes a per-user launchd agent
  (`com.relationship-agent.sync.<lane>`) — survives reboots natively; a sleep
  gap coalesces into one catch-up run on wake, and lane cursors absorb the
  rest.
- Change an interval / disable a lane: edit `lanes.tsv`, re-run `install`.
  No code edits, ever.
- Logs: `data/connectors/sync-scheduler/logs/<lane>.log` (auto-rotated).
- Verify: `status` shows `INSTALLED yes`; force a first run with
  `launchctl kickstart gui/$UID/com.relationship-agent.sync.<lane>` and check
  `LAST_EXIT 0`. If you get exit 126 → step 1.

## 6. Prove the whole machine

```sh
bash packages/core/tests/run-store-tests.sh
bash packages/connectors/tests/run-capture-tests.sh
bash packages/connectors/tests/run-beeper-capture-tests.sh
bash packages/connectors/tests/run-scheduler-tests.sh
bash packages/connectors/scripts/check-sync.sh data/store    # capture conformance
bash packages/core/scripts/validate-store.sh data/store      # store sanity
```

All green + a `LAST_EXIT 0` lane = you're live.

## Troubleshooting quick reference

| Symptom | Cause / fix |
|---|---|
| Lane exit `126`, `Operation not permitted` in `<lane>.launchd.log` | TCC — step 1 (works from terminal, fails under launchd is the tell) |
| `status` shows `INSTALLED no` | Run `sync-scheduler.sh install`; check `launchctl print gui/$UID/com.relationship-agent.sync.<lane>` |
| `expected 4 tab-separated fields` | `lanes.tsv` needs real tab characters between fields (spaces don't count) |
| Beeper sweep logs `skip-no-token` / `skip-unreachable` | Token file missing beside config.json / Beeper Desktop not running |
| Scheduler installed but lane never fires | `RunAtLoad` is false by design — first fire comes after one interval; kickstart to test now |

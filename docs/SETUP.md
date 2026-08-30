# First-run setup (macOS)

Everything a new user does ONCE to get Spomni capturing, filing, and
answering. **The fastest path: don't work through this by hand — open a
Claude Code session in the cloned repo and say "run first-run setup from
docs/SETUP.md".** The assistant executes everything it can on its own and
hands you one short list of the things only you can do. Working manually
top-to-bottom works too; each step says how to verify itself.

**Just want to try it?** `bash scripts/setup.sh --demo` builds a synthetic
30-person store and wires it up — no accounts, nothing of yours touched.
Come back here when you want your own data.

> **Maintenance rule (for the assistant as much as for humans):** this file is
> the single home for machine-level setup. Any session that discovers a new
> required setup step — a permission, an auth flow, a config file, a gotcha —
> adds it here in the same commit as the fix. Setup knowledge never lives only
> in a session transcript or a plan file.

## Instructions to the assistant running this setup

- **Run `bash scripts/setup.sh` first.** It does every deterministic step
  (prereq check, `npm ci`, store init, location safety check, validation,
  `--lanes` for the scheduler file) and prints what's left. Never hand the
  user a step this file marks as agent-side. Never mark a step done without
  running its verification.
- **Batch the human-only items into ONE consolidated prompt** (auth clicks,
  app installs, the TCC grant, account choices) — don't drip questions one at
  a time. While the user works through that list, keep executing agent-side
  steps that aren't blocked on it.
- **Most of this runs in parallel.** The Google lane, the Beeper lane, and
  the scheduler prep (steps 3a, 3b, 5) are independent of each other — fan
  them out concurrently; only their verifications wait on the matching human
  action. Hard ordering: step 1's location decision before step 5's live
  verification; step 2's store before anything writes data.
- **Probe, don't assume, on step 1:** detect whether the repo sits under a
  TCC-protected folder and prove launchd access with a throwaway probe job
  (a launchd agent that just `ls`-es the repo dir) BEFORE installing lanes —
  scheduled jobs fail invisibly otherwise (exit 126 in the lane's
  launchd.log while manual terminal runs succeed).
- Finish by running the step-6 battery, then step 7 (onboarding), and show
  the user a single done/blocked summary.

| Step | Agent does alone | Needs the human |
|---|---|---|
| 1 Location/TCC | Detect protected path, run launchd probe, verify after grant | Choose location; grant `/bin/bash` Full Disk Access (System Settings) |
| 2 Clone + store | `scripts/setup.sh`: deps, store init, location check, wire `data/store` | Supply the private-repo URL (and push access) |
| 3a Google | Verify connector tools respond after auth | `/mcp` OAuth for Gmail + Google Calendar |
| 3b Beeper | Register MCP, write config.json from the example, chmod token, `--list-accounts` verify | Install Beeper Desktop, sign in, connect networks, paste token, toggle remote access OFF |
| 4 Query layer | Verify the 6 query tools against the store | Approve the repo `.mcp.json` prompt |
| 5 Scheduler | `setup.sh --lanes`, `install`, kickstart, check `LAST_EXIT 0` | — (only step 1's grant, if that path was chosen) |
| 6 Prove it | `scripts/test-all.sh` + check-sync + validate-store | — |
| 7 Onboard | Run `/onboarding-seed`; present tier suggestions | Confirm or skip each suggested tier |

## 0. Prerequisites

- macOS (scheduling uses launchd; Beeper Desktop is macOS/desktop). Linux
  isn't supported yet — the bash pipeline is portable, but there's no
  systemd/cron backend for the scheduler and no TCC equivalent to worry
  about; a `sync-scheduler.sh` backend is a welcome contribution.
- git, `jq`, `openssl`, `shasum` (all present on a stock Mac except `jq`:
  `brew install jq`)
- [Claude Code](https://claude.com/claude-code) CLI
- **Node ≥ 22.6** — runs the read-only query server (`node
  --experimental-strip-types`). `scripts/setup.sh` runs `npm ci` in
  `packages/query/server` for you.
- A private GitHub repo (or any private directory) for YOUR data — the
  contact graph never lives in this public repo (`data/README.md`)
- Optional, for personal-chat capture: [Beeper Desktop](https://www.beeper.com)
- Optional, for local embeddings: [Ollama](https://ollama.com) with
  `ollama pull nomic-embed-text`. Without it, similarity features report
  `embeddings: unavailable` and everything else works.

## 1. Choose where the repo lives — this matters

**If the repo (or your data dir) lives under `~/Documents`, `~/Desktop`, or
`~/Downloads`, macOS TCC will silently block every scheduled sync.** launchd
background jobs run without your terminal's folder permissions: each fire
exits 126 with `Operation not permitted` before the script even loads, while
manual runs from your terminal work fine — so the breakage is invisible until
you look.

Pick ONE:

- **Recommended:** clone somewhere unprotected, e.g. `~/spomni/`.
  No grants needed, nothing else to remember.
- **Keep it under Documents:** grant `/bin/bash` Full Disk Access —
  System Settings → Privacy & Security → Full Disk Access → **+** →
  press **⌘⇧G**, type `/bin/bash`, Return → select **bash**, toggle on.
  Takes effect immediately; nothing to reinstall or reboot.

`scripts/setup.sh` warns when the checkout is in a protected folder.

Verify (after step 5 installs a lane): `launchctl kickstart
gui/$UID/com.spomni.sync.<lane>`, then confirm `LAST_EXIT 0` in
the scheduler's `status` output. Exit `126` here always means this step.

## 2. Get the code and your private store

```sh
git clone https://github.com/yourBoiGershy/Spomni.git ~/spomni && cd ~/spomni
git clone git@github.com:<you>/<your-private-people-store>.git data/store   # existing store
bash scripts/setup.sh                    # prereqs, npm ci, location check, validate
```

No store yet? `bash scripts/setup.sh --store ~/spomni-store` creates an
empty one with the right layout (`packages/core/scripts/init-store.sh`) and
symlinks `data/store` to it. Put it under git in a **private** repo when you
want history and backup.

`data/` is gitignored — see `data/README.md` for the expected store shape.
`packages/core/scripts/check-store-location.sh data/store` refuses locations
that would leak: inside this code checkout (other than `data/`), inside
iCloud Drive / Dropbox / Google Drive / OneDrive, or a repo whose remote is
this public one.

## 3. Connect your accounts (the pipes)

Connectors are pipes, never stores — everything they fetch lands in YOUR
data dir only.

- **Google (email + calendar):** in a Claude Code session in this repo, run
  `/mcp` and authenticate the first-party **Gmail** and **Google Calendar**
  connectors (decision `first-party-mcp-only`).
- **Beeper (WhatsApp/LinkedIn/Signal/etc. personal chats):** install Beeper
  Desktop and sign in; connect the networks you want tracked. Then:
  - Enable the local Client API and register the MCP server:
    `claude mcp add --transport http beeper http://127.0.0.1:23373/v0/mcp`
    (complete the OAuth prompt).
  - Create `data/connectors/beeper-in/config.json` from
    `packages/connectors/beeper-in/config.example.json` — list the accountIDs
    to capture; save the API token beside it and `chmod 600` it (the sweep
    warns on every run if the token file is readable by others). `store_dir`
    is optional — omit it; the sweep defaults to the checkout's `data/store`
    (symlink followed), so the config never needs an absolute path.
  - **Turn OFF** Settings → Integrations → *remote access* in Beeper Desktop —
    it binds the API to 0.0.0.0 (LAN-visible); the capture lane only needs
    127.0.0.1.
  - Verify: `bash packages/connectors/beeper-in/scripts/beeper-sweep.sh
    --list-accounts` prints your accounts.

## 4. Chat with your data (query layer)

The read-only query MCP server (`spomni-query`, 6 tools) is registered by the
repo-committed `.mcp.json` — opening a Claude Code session in the repo picks
it up; approve the server when prompted. It needs step 2's `npm ci` (done by
`scripts/setup.sh`). Details and the smoke test: `docs/chat-setup.md`.

## 5. Scheduled syncs (set-and-forget capture)

One scheduler runs every capture lane on an interval (contract:
`packages/core/contracts/sync-lanes.md`).

```sh
bash scripts/setup.sh --lanes            # or: bash packages/connectors/scripts/sync-scheduler.sh init
bash packages/connectors/scripts/sync-scheduler.sh install
bash packages/connectors/scripts/sync-scheduler.sh status
```

`setup.sh --lanes` and `sync-scheduler.sh init` do the same thing: copy
`packages/core/templates/sync-lanes.tsv` into
`data/connectors/sync-scheduler/lanes.tsv` verbatim. There is no path to
edit — lane commands carry `{{REPO_ROOT}}`, `{{DATA_DIR}}`,
`{{PRIVATE_DATA_ROOT}}`, `{{STORE_DIR}}`, and `{{CLAUDE_BIN}}` placeholders
that `sync-scheduler.sh` resolves fresh at every tick, from the checkout
whose scheduler is executing. That means moving or renaming the checkout,
or re-pointing `data/store`, needs only re-running `install` from the
checkout you're using now — it also retires any legacy
`com.relationship-agent.sync.*` agent automatically. To see exactly what a
lane will run without waiting for a tick:
`bash packages/connectors/scripts/sync-scheduler.sh resolve <lane>`.

- Every enabled lane becomes a per-user launchd agent
  (`com.spomni.sync.<lane>`) — survives reboots natively; a sleep gap
  coalesces into one catch-up run on wake, and lane cursors absorb the rest.
- **Gmail and Calendar lanes ship disabled.** Enable them via §5a below,
  after running the preflight check.
- Change an interval / disable a lane: edit `lanes.tsv` (real tabs between
  fields), re-run `install`. No code edits, ever.
- Logs: `data/connectors/sync-scheduler/logs/<lane>.log` (auto-rotated).
- Verify: `status` shows `INSTALLED yes`; force a first run with
  `launchctl kickstart gui/$UID/com.spomni.sync.<lane>` and check
  `LAST_EXIT 0`. If you get exit 126 → step 1.

### 5a. Headless gmail / calendar lanes (plan 28)

Gmail and Calendar fetch through the first-party claude.ai connectors, which
only exist inside a Claude session — so their lane command runs a short,
capped headless session per tick via
`packages/connectors/scripts/mcp-lane-tick.sh`. The template ships both rows
`enabled false`; enable them in this order:

```sh
CLAUDE_BIN="$(command -v claude)"   # absolute path; launchd has no PATH
bash packages/connectors/scripts/mcp-lane-tick.sh preflight --claude-bin "$CLAUDE_BIN" --lane gmail
bash packages/connectors/scripts/mcp-lane-tick.sh preflight --claude-bin "$CLAUDE_BIN" --lane calendar
# both must print preflight-ok; preflight-fail names the missing connector tool
$EDITOR data/connectors/sync-scheduler/lanes.tsv   # flip enabled → true
bash packages/connectors/scripts/sync-scheduler.sh install
bash packages/connectors/scripts/sync-scheduler.sh status
```

The `{{CLAUDE_BIN}}` placeholder in each row finds `claude` on `PATH` (or
`~/.claude/local/claude`) automatically — no editing needed. Only override
it if the resolved binary is wrong: set `SPOMNI_CLAUDE_BIN=<path>` in the
launchd plist's environment.

- Each tick is a model session, so intervals are a cost decision: template
  defaults are gmail 3600s, calendar 7200s (≤36 sessions/day). Every tick is
  triple-capped — page budget (`pages=N` in the prompt), `--max-turns`, and a
  wall-clock `--timeout-seconds` watchdog — all in the `lanes.tsv` command
  string, so tuning is a config edit.
- A tick that times out, hits its turn cap, or ends without the sweep's
  `sweep-ok` summary records a nonzero `LAST_EXIT` in `status` (3 = timeout,
  4 = no summary, otherwise claude's own exit). If the failure names a
  missing tool, re-run `preflight` — the connector likely needs re-linking in
  claude.ai.

### 5b. Nudge delivery (plan 33)

Wake-up cards render to `outbox/<date>.md` unconditionally (no setup
needed); to also have them pushed somewhere you'll actually see, configure a
live channel. The Beeper token is shared with beeper-in — no new secret.

```sh
bash packages/ingestion/scripts/profile-set-notify.sh data/store \
    --channel beeper-self --beeper-chat-id <id> --quiet-hours 22:00-08:00
```

Find the chat id of your "Note to self" chat in Beeper Desktop. For email
fallback instead, use `--channel gmail-self --gmail-address <you>`.

Then enable the `notify` row in `lanes.tsv` (it ships `enabled true` by
default) and re-run:

```sh
bash packages/connectors/scripts/sync-scheduler.sh install
```

A first tick logs `deliver: nothing new` until a wake-up actually fires.

### 5c. Feedback (plan 34)

The `feedback` lane in `sync-lanes.tsv` ships enabled and parses your
replies to delivered cards on every tick — reply with the card number:
`1 done`, `1 snooze 2w`, `1 skip`, `1 never birthday`, `1 not-them`,
`1 wrong-tier close`; anything else is kept verbatim as freeform feedback.
Run `bash packages/ingestion/scripts/feedback-to-evals.sh <store> --data-dir
<data-dir>/ingestion` any time to regenerate regression evals from your
corrections; `test-all.sh` runs them when present.

## 5d. From your phone (cloud session on the data repo)

Open a Claude Code cloud session on your **private data repo** (not this
one). Its `CLAUDE.md` (written by `init-store.sh` from
`packages/core/templates/data-repo-CLAUDE.md`; add it by hand to an older
store) tells the session to shallow-clone the machinery into `machinery/`
and answer with bash + jq — no `npm ci`, no server. Expect ≈ 5 s from clone
to first `/who-next` answer on a laptop, ≤ 15 s in the cloud; measure with
`bash packages/query/tests/bench-cold-start.sh --remote https://github.com/<you>/Spomni.git --warm`.

A debrief from the phone ends with
`store-sync.sh commit -m "debrief: …" . && store-sync.sh push .` — no typed
git. Add `machinery/` to the data repo's `.gitignore`. Set
`SPOMNI_GIT_NAME` / `SPOMNI_GIT_EMAIL` in the cloud environment if you want
commits attributed to you (default author `Spomni <spomni@localhost>`).

Routines stamp `heartbeats/<routine>.json`; the daily sweep's staleness step
raises **one** wake-up when a routine or lane has been quiet for 2× its
cadence. On this Mac the launchd lanes' state lives under the connectors
worktree's `data/` — pass `--sync-data-dir` to `staleness.sh` if your store
checkout differs.

## 6. Prove the whole machine

```sh
bash scripts/test-all.sh                                     # every suite + oss-guard
bash packages/connectors/scripts/check-sync.sh data/store    # capture conformance (needs captures)
bash packages/core/scripts/validate-store.sh data/store      # store sanity
```

All green + a `LAST_EXIT 0` lane = the machine works. It's still empty.

## 7. Onboard — fill the store

In a Claude Code session in the repo:

```
/onboarding-seed
```

It backfills recent history from the linked accounts (Gmail, Calendar,
Beeper), files it, and proposes priority tiers for the people it finds.
**Nothing is written as a tier until you confirm it** — skip anyone you
like; skipped people are never re-prompted. Afterwards, the query tools and
`/debrief` have something to work with, and the scheduler keeps the inbox
fresh.

## 7. Optional: local embeddings for kind/tier review (plan 30)

The `review-tiers` skill (`packages/ingestion/skills/review-tiers/SKILL.md`)
can use **local** embeddings to hand the judgment "who among your confirmed
people is this person most like" as a prior. It is optional — without it
every step runs identically and the run log says `embeddings: unavailable`.
Cloud embedding APIs are never used (other people's data stays local).

```sh
brew install ollama            # or https://ollama.com/download
ollama serve &                 # listens on http://localhost:11434
ollama pull nomic-embed-text   # the default EMBED_MODEL
bash packages/ingestion/scripts/embed-people.sh data/store   # refresh vectors
```

Vectors land in `data/store/index/embeddings.jsonl` (regenerable; never
leaves the machine). Override the endpoint/model with `OLLAMA_URL` /
`EMBED_MODEL`; tests inject a deterministic shim via `EMBED_CMD`.

## Troubleshooting quick reference

| Symptom | Cause / fix |
|---|---|
| Lane exit `126`, `Operation not permitted` in `<lane>.launchd.log` | TCC — step 1 (works from terminal, fails under launchd is the tell) |
| `status` shows `INSTALLED no` | Run `sync-scheduler.sh install`; check `launchctl print gui/$UID/com.spomni.sync.<lane>` |
| `status` shows `LEGACY com.relationship-agent.sync.<lane>` | Pre-rename install; remove with the command printed on that line, then `install` again |
| `expected 4 tab-separated fields` | `lanes.tsv` needs real tab characters between fields (spaces don't count) |
| `spomni-query` fails to start / tools missing | `node -v` ≥ 22.6? `cd packages/query/server && npm ci` |
| Beeper sweep logs `skip-no-token` / `skip-unreachable` | Token file missing beside config.json / Beeper Desktop not running |
| `WARN: token file … readable by others` | `chmod 600 data/connectors/beeper-in/<token-file>` |
| Scheduler installed but lane never fires | `RunAtLoad` is false by design — first fire comes after one interval; kickstart to test now |
| `check-store-location.sh` FAILs | Your store is somewhere it could leak (inside this repo, a sync folder, or pointed at the public remote) — move it |
| Lane fires but writes to the wrong store | `sync-scheduler.sh resolve <lane>` to see the resolved command; check `data/store` (symlink target); re-run `install` from the checkout you actually use |

## Uninstall

Nothing is hidden; everything lives in three places.

```sh
bash packages/connectors/scripts/sync-scheduler.sh uninstall --all   # launchd agents
claude mcp remove beeper                                             # if you added it
rm -rf ~/.cache/spomni                                               # derived index cache (regenerable)
rm -rf ~/.local/share/spomni                                         # demo store, if you made one
```

Your real store is wherever you put it (`data/store` is a symlink or clone)
— delete it yourself, or keep it: it's plain markdown. Removing the checkout
removes the project-scope `spomni-query` registration with it. Revoke the
Google connector grants from your Google account's third-party access page
if you no longer want claude.ai linked.

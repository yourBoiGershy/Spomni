# 12 — Beeper capture connector (`beeper-in`)

**Status header:** implementation plan. Builds the personal-chat capture lane decided in
`docs/DECISIONS.md#beeper-personal-bridge`, informed by plan 11
(`docs/plans/2026-08-29-11-messaging-connectors-research.md`).
**Stream:** `stream-connectors` (worktree `relationship-agent-worktrees/connectors`).

## Scope

Read-only capture: Beeper Client API (`http://127.0.0.1:23373`, Bearer token) →
normalized capture events in `data/store/inbox/` via the shared normalizer. Capture
only — no sends, no drafts, no filing (ingestion's job), no writes anywhere in the
store except `inbox/`.

**Sub-package naming:** `packages/connectors/beeper-in/` — the `-in` suffix is
load-bearing: `packages/core/contracts/capture-event.md` defines the inbox's sole
writer as `packages/connectors/*-in`, and `docs/data-layout.md` follows the same
convention for runtime state dirs.

## Decisions already made (do not re-litigate)

- Beeper is the personal-chat bridge; per-network enablement is **opt-in, default
  nothing enabled** (`beeper-personal-bridge`, plan 11).
- Read-only forever on this lane; the API's send capability is never called
  (`draft-never-send`).
- Polling with persisted cursors is the v1 backbone. The WebSocket (`/v1/ws`) is
  at-most-once with **no replay on reconnect** — Beeper's own docs say to reconcile
  via HTTP refetch — so WS is explicitly **out of scope for v1** (future work).
- All state (token, config, cursors, logs) lives under the private data dir; raw
  captured payloads land in `inbox/`, kept forever; nothing user-specific enters this
  repo (`code-data-separation`).
- **Open decision, carried forward:** v1 runs against Beeper Desktop already running
  on this Mac (login item). Migrating to headless Beeper Server
  (`beeper setup --server --install`) serves the identical API — that migration is a
  **deploy change (base_url/host), never a code change**. The connector targets
  whatever answers at the configured base URL.

## API ground truth (verified 2026-08-29, live instance + OpenAPI 5.0.0)

Workers implement from THIS section (recorded into the sub-package's `api-notes.md`
by unit S1); do not re-research.

- Auth: `Authorization: Bearer <token>`; 401 without. Token is user-created in
  Beeper Settings → Integrations → Approved connections.
- `GET /v1/info` — server discovery/liveness.
- `GET /v1/accounts` — array of Account: `accountID` (routing key, e.g. `matrix`,
  `local-whatsapp_ba_…`), optional `network` (human name), `status` (enum incl.
  `connected`, `backfilling`, `disconnected`), `user`.
- `GET /v1/chats?accountIDs=…&cursor=…&direction=before|after` — all chats sorted by
  last activity, most recent first; `accountIDs` is a repeatable query param limiting
  to specific accounts. Chat: `id`, `accountID`, `network`, `title`, `type`
  (`single`|`group`), `participants.items[]` (User: name/ids), `lastActivity`
  (ISO 8601 with ms + tz), `unreadCount`. Output shape mirrors ListMessagesOutput
  (items/hasMore/cursors).
- `GET /v1/chats/{chatID}/messages?cursor=…&direction=before|after` — returns
  `{ items: Message[], hasMore, oldestCursor, newestCursor }`. `direction=after` +
  saved cursor fetches **newer** messages — the catch-up primitive. Message: `id`,
  `chatID`, `accountID`, `senderID`, `senderName`, `timestamp` (ISO 8601),
  `sortKey`, `type` (TEXT/IMAGE/…/REACTION), `text`, `isSender`, `attachments`
  (media as `mxc://` URLs), `linkedMessageID`, `reactions`.
- Cursors and IDs are opaque strings; chat IDs contain `!` and `:` — URL-encode in
  paths.
- Timestamps are ISO 8601 with timezone and milliseconds; the capture-event contract
  requires `YYYY-MM-DDTHH:MM:SSZ`, so `captured_at` uses the sweep run's own
  `date -u +%Y-%m-%dT%H:%M:%SZ` (contract: captured_at = when the connector captured
  it, not when the message happened — message times live in the body).

## Design (fixed for all units)

### Runtime state — `data/connectors/beeper-in/` (never in repo, never in store)

| File | Contents |
|---|---|
| `token` | the Bearer token, single line, chmod 600; created by the user out-of-band |
| `config.json` | see below; user-created from the repo's `config.example.json` |
| `cursors.tsv` | per-chat catch-up state: `<chatID>\t<newestCursor>` one line per chat; rewritten via temp file; a chat's cursor advances ONLY after its capture event normalized successfully (exit 0) |
| `last-sweep` | ISO 8601 Z timestamp of the last fully-listed sweep; bounds chat listing |
| `runs.log` | append-only status ledger, one line per run (see failure posture) |
| `launchd.log` | stdout/stderr of scheduled runs |

`config.json` (all keys shown = full schema; `store_dir` relative to repo root):

```json
{
  "base_url": "http://127.0.0.1:23373",
  "store_dir": "data/store",
  "enabled_account_ids": [],
  "max_chats_per_run": 50,
  "max_pages_per_chat": 20
}
```

Per-network opt-in = `enabled_account_ids` (values from `/v1/accounts`; the sweep's
`--list-accounts` mode prints `accountID  network  status` so the user can pick).
Missing config or empty list → the sweep does nothing (status `skip-disabled`).

### Sweep algorithm (`beeper-sweep.sh`)

1. Load config + token. No config / empty `enabled_account_ids` → log
   `skip-disabled`, exit 0. Token missing → log `skip-no-token`, exit 0.
2. `GET /v1/info`. Any transport failure → log `skip-unreachable`, exit 0 — no
   retries, no error spam; cursors catch up next run (lossy-tolerant).
3. `GET /v1/accounts`; any enabled accountID absent or not
   `connected`/`backfilling` is noted in the run line (`warn=…`), never fatal.
4. List chats: `GET /v1/chats` with `accountIDs` repeated per enabled ID; paginate
   `direction=before` until a page's oldest `lastActivity` predates `last-sweep`,
   or `max_chats_per_run` chats collected. First run (no `last-sweep`): first page
   only — capture-from-now-on, no deep backfill.
5. Per collected chat: cursor in `cursors.tsv` → loop
   `GET …/messages?cursor=<c>&direction=after` while `hasMore`, up to
   `max_pages_per_chat` (remainder caught next run via cursor — nothing lost); no
   cursor → single GET (newest page) as the chat's first capture.
6. Non-empty collection → **one capture event per chat per run**: body is a single
   jq-assembled JSON object `{chatID, accountID, network, title, chatType,
   messages:[…]}` with each Message object verbatim as received (envelope-only
   doctrine; one-event-per-message would flood inbox/ — batching per chat mirrors
   the gmail contacts-seed page precedent). Pipe to
   `packages/connectors/scripts/normalize-capture.sh "$STORE_DIR" --source beeper
   --type other --captured-at <run-ts>` with `--hint` for the chat title and each
   unique `senderName`/`senderID` where `isSender != true`. `type: other` matches
   gmail-sweep's minimal-typing rule; widening the enum (e.g. `chat-thread`) is a
   core minor bump for a later chunk, not this one.
7. Normalizer exit 0 → advance the chat's cursor to the final page's
   `newestCursor`; exit 1 → quarantined by the normalizer, cursor NOT advanced,
   continue to the next chat (run becomes `partial`).
8. End: update `last-sweep` to the run's start time (only if chat listing itself
   succeeded); append the run line.

### Failure posture / status line (silence impossible)

Every terminal path appends one greppable line to `runs.log` — enforced by an EXIT
trap that writes `error` if no line was written:

```
<ISO8601Z> <outcome> chats=<n> events=<n> quarantined=<n> [warn=…]
outcome ∈ ok | partial | skip-disabled | skip-no-token | skip-unreachable | error
```

### Read-only enforcement

`lib.sh` exposes exactly one HTTP function, `beeper_get <path-with-query>` (curl
`-sS --max-time 15`, GET only, Bearer header). No other curl call sites permitted in
the sub-package. Allowed paths: `/v1/info`, `/v1/accounts`, `/v1/chats`,
`/v1/chats/*/messages`. The test suite greps the shipped scripts to assert no `-X`,
no `--data`/`-d`, and no state-changing paths (`/read`, `/archive`, `/reminders`,
POST send). Testability: when `BEEPER_HTTP_STUB` is set, `beeper_get` execs
`"$BEEPER_HTTP_STUB" <path-with-query>` instead of curl (stub prints a body, exits
curl-style) — tests run fully offline against fixtures.

### Scheduling

launchd StartInterval agent (no lane has one yet — this sets the precedent):
template plist + install script, all paths parameterized; catch-up after downtime is
automatic via cursors, so missed intervals cost nothing.

## Work units

All paths relative to the worktree root
`/Users/ericg/Documents/relationship-agent-worktrees/connectors/`. Every unit is a
`dev-worker` brief sized ≤3 min; bash 3.2 portable (no associative arrays, no
mapfile), `jq` allowed (existing-lane precedent). Doc rides with its
implementation unit; tests are separate units.

| # | Unit | Files | Depends-On |
|---|---|---|---|
| S1 | Scaffold: manifest, api-notes, config example, fixtures | `packages/connectors/beeper-in/package.md`, `packages/connectors/beeper-in/api-notes.md`, `packages/connectors/beeper-in/config.example.json`, `packages/connectors/beeper-in/fixtures/{accounts.json,chats-page.json,messages-page.json,messages-empty.json}`, `packages/connectors/package.md` (add sub-package + note this lane in Provides/Consumes) | — |
| S2 | Shared lib: config/token load, `beeper_get` (+ stub injection), cursors.tsv read/advance, runs.log writer + EXIT trap helper, pagination helpers (`list_new_chats`, `fetch_new_messages`) | `packages/connectors/beeper-in/scripts/lib.sh` | — (contracts fixed above) |
| S3 | Sweep orchestrator + `--list-accounts` mode, implementing steps 1–8 exactly | `packages/connectors/beeper-in/scripts/beeper-sweep.sh` | S2 |
| S4 | Lib tests: config parse/skip states, cursor ledger advance/no-advance, status line on every exit path (incl. trap), stub injection, read-only grep guard | `packages/connectors/tests/run-beeper-capture-tests.sh` (new, standalone; same pass/fail/SUMMARY style as `run-capture-tests.sh`) | S1, S2 |
| S5 | Sweep end-to-end tests (extend S4's suite file): full run against stub+fixtures into a mktemp store — inbox event exists with `source: beeper`, `type: other`, hints populated, body contains fixture message text verbatim; second run with unchanged fixtures produces zero new events (cursor dedup); unreachable stub → `skip-unreachable` + exit 0 + empty inbox; empty `enabled_account_ids` → `skip-disabled`; normalizer failure path leaves cursor unadvanced | `packages/connectors/tests/run-beeper-capture-tests.sh` | S3, S4 |
| S6 | launchd: template with `__REPO_ROOT__`, `__LABEL__` (`com.relationship-agent.beeper-in`), `__INTERVAL__` (default 900s) placeholders; StartInterval, WorkingDirectory=repo root, ProgramArguments `/bin/bash …/beeper-sweep.sh`, stdout/err → `data/connectors/beeper-in/launchd.log`, RunAtLoad false. Install script: render to `~/Library/LaunchAgents/`, `launchctl bootstrap gui/$UID`, `--interval N`, `--uninstall` (bootout + rm), `--dry-run` (print rendered plist, touch nothing) | `packages/connectors/beeper-in/launchd/com.relationship-agent.beeper-in.plist.template`, `packages/connectors/beeper-in/scripts/install-launchd.sh` | — (script path fixed by this plan; trivial self-check rides: `bash -n` + `--dry-run` + `plutil -lint` on rendered output) |
| V1 | Live smoke (checker, read-only, no repo writes) — **gated on the user having created a token** at `data/connectors/beeper-in/token`: `GET /v1/info`, `GET /v1/accounts` (capture accountID/network/status table for the opt-in step), one page of one chat's messages via `beeper_get`; verify `accountIDs` repeat-param serialization live | none (report only) | S2, S3 + user token |
| V2 | First supervised run: user fills `config.json` with chosen `enabled_account_ids`; run `beeper-sweep.sh` once by hand; then `bash packages/connectors/tests/run-beeper-capture-tests.sh`, `bash packages/connectors/tests/run-capture-tests.sh`, `bash packages/core/tests/run-store-tests.sh`; orchestrator (not a worker) appends the new test command to CLAUDE.md's test-commands list per its PARAMETERIZE marker | none in repo (data-dir writes only; CLAUDE.md by orchestrator) | S1–S6, V1 |

Dispatch shape: S1, S2, S6 in one parallel wave (3 workers); then S3 ∥ S4; then S5;
then V1/V2 when the token exists.

### Per-unit evidence

- S1: `package.md` declares provides (raw capture events in `inbox/` for the beeper
  lane; fixtures) / consumes (`capture-event@^1`, `connector-interface@^1`, the
  user's Beeper Desktop/Server API + token out-of-band); fixtures are valid JSON
  (`jq .` passes) shaped per the ground-truth section, synthetic names only.
- S2/S3: `bash -n` clean; `bash -n` under `/bin/bash` (3.2); no curl outside
  `beeper_get`; scripts executable.
- S4/S5: suite output `SUMMARY: N passed, 0 failed` under `/bin/bash`.
- S6: `--dry-run` render shows substituted paths; `plutil -lint` OK; no file written
  outside `~/Library/LaunchAgents/` on real install.
- V1: pasted `/v1/info` JSON, accounts table, one-page message fetch (IDs/text
  redacted in the report — other people's data stays out of the repo and logs).
- V2: a real `inbox/<id>.md` exists (path only in report), `runs.log` shows an `ok`
  line, `validate-store.sh data/store` passes, all three suites green.

## Completion criteria per phase

1. **Scaffold (S1):** manifest + fixtures merged; parent `package.md` lists
   `beeper-in`.
2. **Implementation (S2, S3, S6):** sweep runs offline end-to-end against the stub;
   read-only guard holds; launchd dry-run renders correctly.
3. **Tests (S4, S5):** new suite green under stock `/bin/bash`; existing
   `run-capture-tests.sh` and core store tests still green.
4. **Verification (V1, V2):** live smoke green, one real sweep landed events, user
   installed the launchd agent (or explicitly deferred), CLAUDE.md test list
   updated.

## Open concerns carried forward

- Gated on the user minting the Beeper token and choosing `enabled_account_ids`
  (per-network ban-risk is the user's call — Meta lanes most enforcement-prone, per
  `beeper-personal-bridge`).
- On-device bridge mode must be confirmed per enabled network during V1's account
  review (older cloud bridges transit Beeper's servers — decision constraint).
- `accountIDs` array serialization (`accountIDs=a&accountIDs=b`) is spec-derived;
  V1 verifies it live before scheduled runs are trusted.
- WebSocket streaming and a finer capture-event `type` for chat threads are future
  chunks; Desktop → headless Beeper Server migration is a deploy change only.

Status: Ready

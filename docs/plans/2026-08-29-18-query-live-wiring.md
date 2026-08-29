# Plan 18: Query & chat live wiring

Status: In progress — waves A + C done (2026-08-29); wave B partially blocked

Execution state (2026-08-29): Wave A landed (root `.mcp.json`; smoke-live 6/6 PASS
against `packages/core/fixtures/store`, store byte-untouched; chat-setup docs +
package.md refresh). Wave C hygiene checker: CLEAN, fix unit skipped. Wave B: local
wiring done (`data/store` → live capture location, npm install); store suite 20/20 and
query suite 9+2xfail green; T2 evals: 3 pass + 2 xfail matches main, but
`most-overdue`/`interpretability` are flaky here AND identical-code runs pass on main —
recorded as pre-existing eval-case sensitivity, advisory, not diff-caused (eval runner
uses --strict-mcp-config, so the new .mcp.json cannot reach eval sessions). REMAINING,
blocked on chunk 20's backlog filing (46 inbox events, zero filed people in every live
store): unit 5 live-store smoke pass, unit 7 live chat verification. Legacy user-scope
registration removal deferred to merge (a concurrent session may be using it).
Package: query (server config + smoke) + harness/docs (setup doc, root `.mcp.json`)
Depends-on: 08 (hard — server built, six tools green); consumes plan 09's data-repo /
`data/store` symlink convention (does NOT build sync — that is 09/19 territory)

## Objective

Make "chat with your own data" real: register the already-built query MCP server
(plan 08, six read-only tools) against the live store in a way that is reproducible
for any user and any worktree — then prove it by smoking all six tools over real
captured data and chatting with the store in a live session. Wiring + docs only; zero
new tool development.

## Context

Read docs/PROJECT-CONTEXT.md first. Decisions that bind this plan (settled — do not
re-litigate):

- **staleness-cache** — query never writes into the store. Missing/stale index.json or
  stats.json is already a handled path: the server regenerates via core's
  `build-index.sh`/`build-stats.sh` into `${RA_CACHE_DIR:-$HOME/.cache/relationship-agent}/derived/`
  and serves from there (`server/src/store/staleness.ts`). Store copies remain
  ingestion's alone to write (single-writer). This plan verifies that path live; it
  builds no generator and grants query no write access.
- **git-as-sync-protocol / cloud-native-runtime** (plan 09) — the private data repo is
  the durable store; local checkouts point `data/store` at it (symlink or clone, per
  `data/README.md`). Reconciling today's live capture store with the data repo is
  plan 09/19 work; this plan only consumes the `data/store` convention.
- **pii-egress-allowlist / code-data-separation** — nothing this plan commits may carry
  real person data or user-specific absolute paths. Smoke output goes to the terminal,
  never into a committed artifact; evidence in reports is counts/statuses, not content.
- **draft-never-send** — untouched: the tool surface is read-only and stays that way.

### Current state (verified 2026-08-29 — ground truth, do not re-derive)

The server IS registered today, fragilely: a user-scope `~/.claude.json` entry
(`spomni-query`) under the main-checkout project only, whose `args` hardcode (a) the
main checkout's `server/src/index.ts` (branch-dependent code path) and (b) the
ingestion worktree's gitignored capture dir as `--store`. It is invisible to other
worktrees/sessions and unreproducible for other users. No `.mcp.json` exists at any
worktree root. The live capture store (`.../ingestion/data/store`) has
people/interactions/inbox/wakeups but no index.json or stats.json — exactly the
staleness-cache regeneration path.

### Decisions THIS plan makes (one DECISIONS.md entry, orchestrator-recorded at
execution: **query-mcp-registration**)

1. **Registration mechanism: project-checked `.mcp.json` at the repo root, all paths
   repo-relative.** Claude Code launches project-scope stdio servers with cwd = the
   project root, so `packages/query/server/src/index.ts` and `data/store` resolve
   per-checkout: every worktree (and every future user) that merges main gets a working
   registration with zero absolute paths and zero per-machine config. The legacy
   user-scope `spomni-query` entry is removed at execution (migration step below).
2. **Store target: `data/store`, always.** The registration never names a machine
   path; it names the convention. Durably, `data/store` points at the private data-repo
   clone (plan 09). Interim, on this machine, the freshest real data lives in the
   ingestion worktree's capture dir — so until 09/19 reconcile capture-store ↔ data
   repo, the user points this checkout's `data/store` symlink there (a local,
   gitignored act; flipping it later to the data-repo clone changes nothing in the
   registration). Chunk 18 states this and moves on; it does not solve sync.
3. **Missing derived artifacts are a verified feature, not a blocker.** The live store
   has no index.json/stats.json; the server must demonstrably regenerate both into the
   cache dir on startup and serve real (non-degraded) stats, leaving the store
   byte-untouched. A degraded-empty-stats startup against the live store is a smoke
   FAILURE, not a pass.

## Deliverables

- `.mcp.json` (repo root, committed) — one server, `spomni-query`:
  `node --experimental-strip-types packages/query/server/src/index.ts --store data/store`
  (stdio, no env secrets). Unit 1 verifies whether `${RA_STORE_DIR:-data/store}`
  env-expansion works in the local Claude Code version and uses it if so, else the
  plain literal — the override path is documentation either way.
- `packages/query/tests/smoke-live.sh` (+ `smoke-live.mjs`) — drives the server over
  stdio JSON-RPC against `--store <dir>` (arg, default `data/store` from repo root) and
  exercises all six tools data-independently: `search_people` (unfiltered page) → pick
  a slug → `get_person`, `list_interactions`, `get_contact_stats` → pick an
  interaction id → `get_interaction`; plus `suggest_reachouts`. Prints per-tool
  PASS/FAIL with counts and `generated_at`; exits nonzero on any tool error, empty
  store, or degraded-empty-stats; writes nothing anywhere except the cache dir the
  server itself uses.
- `docs/chat-setup.md` — the "chat with your own data" doc: point `data/store` at your
  private store (symlink or clone, per `data/README.md`; interim note per decision 2),
  `(cd packages/query/server && npm install)` once per checkout, approve the
  project-scope server on first session use, run the smoke, ask questions. Includes the
  one-line user-scope alternative (`claude mcp add` with explicit paths) for
  non-project contexts, and the migration note: remove any legacy user-scope
  `spomni-query` entry (`claude mcp remove spomni-query` in the old project scope) so
  exactly one registration exists.
- `packages/query/package.md` refreshed — `server/` is no longer "In progress: scaffold
  only": six tools live, registered via the root `.mcp.json`, store target `data/store`.
- One DECISIONS.md entry (**query-mcp-registration**, decisions 1–2 above) —
  orchestrator-recorded.

## Work units

Wave A (parallel, one message — all repo edits, each ≤3 min):

1. [worker] `.mcp.json` at repo root per decision 1 (verify env-expansion support as
   noted; confirm the file is not gitignored). Smallest unit in the plan — no scope
   creep into docs.
2. [worker] `smoke-live.mjs` + `smoke-live.sh` per the deliverable spec (bash 3.2
   wrapper resolving paths relative to itself, matching `run-query-tests.sh`
   conventions; reuse `test-tools.mjs`'s stdio-driving pattern). No fixtures, no
   committed output, no store writes.
3. [worker] Docs unit: `docs/chat-setup.md` + `packages/query/package.md` refresh, per
   the deliverables. No real names, no user-specific absolute paths — machine-specific
   interim wiring is described as "point `data/store` at your live capture location",
   not as a literal path.

Wave B (orchestrator-run, after A — local ops, not repo edits):

4. [orchestrator] Local wiring + migration on this machine: create/point this
   checkout's `data/store` symlink at the live capture store (interim, per decision 2);
   `npm install` in `packages/query/server` if node_modules absent; remove the legacy
   user-scope `spomni-query` entry; start a session here and approve the project-scope
   server.
5. [orchestrator] Live smoke: `bash packages/query/tests/smoke-live.sh` against
   `data/store`. Must show all six tools PASS, real (non-degraded) stats with a fresh
   `generated_at`, cache populated under `~/.cache/relationship-agent/derived/`, and
   the store dir byte-untouched (no new files, mtimes unchanged for
   index/stats — they don't exist there and must still not exist after).
6. [orchestrator] Suites, batched: `bash packages/core/tests/run-store-tests.sh`,
   `bash packages/query/tests/run-query-tests.sh`, and the T2 eval suite
   (`packages/query/evals/suite.txt` via `packages/core/scripts/eval-run.sh`) — all
   green, unchanged from main.
7. [orchestrator] Live chat verification: in a fresh session, ask ≥3 real questions
   answered via the MCP tools (a search, a person lookup, a reachout suggestion);
   confirm every answer cites real store file paths and provenance tags survive.
   Evidence recorded as tool names + citation counts — no store content in any report,
   commit, or log.

Wave C (after B):

8. [checker] Hygiene pass over the chunk's diff: `.mcp.json` parses and contains only
   repo-relative paths; no PII, real names, emails, or user-specific absolute paths in
   any committed file of this chunk; smoke script writes nothing under the repo or
   store; docs match the actual registration. Report findings file:line.
9. [worker] Fix pass from unit 8's findings (skip if clean).

## Interfaces

Consumes: the plan-08 server and its six tools; core's `build-index.sh` /
`build-stats.sh` (via the server's staleness module); plan 09's `data/store`
convention and data repo (as store target, not as sync machinery).
Produces: the canonical registration every session/worktree/user gets on merge; the
live-smoke script chunk 20's daily audits can reuse; the setup doc chunk 20's trial
instructions point at.

## Proof of done

- All six tools answer over the live store with real data; smoke exits 0 with
  non-degraded stats; store dir untouched (single-writer holds live).
- Store suite, query suite, and T2 evals green.
- Exactly one registration exists: the project `.mcp.json`; the legacy user-scope
  entry is gone; a fresh session in this worktree reaches the server with no manual
  config beyond the documented setup steps.
- At least one real end-to-end chat where answers cite actual captured interactions
  (evidence: tool calls + citation paths counted, content withheld).
- `docs/chat-setup.md` is followable start-to-finish; DECISIONS.md entry recorded;
  ROADMAP row 18 flipped to Done at merge.

## Out of scope

- Sync/reconciliation between the capture store and the data repo (plan 09 discipline,
  chunk 19 scheduler).
- Any new tool, transport work (`--http` stays stubbed), or ranking change.
- Cloud-session registration (data-repo-side `machinery/` clone wiring) — noted in
  `docs/chat-setup.md` as future, built when the cloud runtime doc (plan 09) lands.
- Briefs, nudge cards, output adapters (plan 07).

Status: Ready

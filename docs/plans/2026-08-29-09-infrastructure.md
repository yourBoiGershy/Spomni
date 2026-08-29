# Plan 09: Infrastructure — cloud runtime, data-repo discipline, egress hygiene
Status: In progress (data repo created + scaffolded 2026-08-29)
Package: core (store-sync script) + harness (`.claude/hooks/` guards) + docs; integrates attention's sweep (06)
Depends-on: 01; integrates 06's sweep entry point and 08's Composio lanes; constrains the mcp stream's remote surface

## Objective
Zero self-hosted infrastructure, reachable from any device: the private data repo on
GitHub is the authoritative store and rendezvous, Claude Code cloud sessions are the
interactive surface (phone included), scheduled routines run the sweeps, and the
Composio CLI carries all outside-world reads identically in every runtime.
Simultaneously make the open-source posture honest: a finite, enumerated, mechanically
guarded list of lanes where person-data ever leaves the store.

## Context
Read docs/PROJECT-CONTEXT.md first. Decisions that bind this plan:
- **cloud-native-runtime** (supersedes home-hub-tailscale) — cloud sessions + routines
  against the data repo's own `main`, direct commits, no PRs; `COMPOSIO_API_KEY` in the
  cloud environment env vars (no secrets store yet — accepted); home hub demoted to
  privacy variant.
- **composio-hub** — outside-world access is `composio execute` CLI shell-out; works in
  any runtime with the key present.
- **git-as-sync-protocol** — git carries history, atomicity, and rendezvous; the store
  stays plain files.
- **pii-egress-allowlist** — every egress lane enumerated in `docs/EGRESS.md`; the
  public repo mechanically cannot carry real data.
- **code-data-separation** — machinery public, store private; sessions bridge them by
  cloning the machinery repo into the data-repo sandbox (`machinery/`, gitignored).

Standing state (done 2026-08-29): private repo `relationship-agent-data` created and
scaffolded per core contracts (inbox/people/interactions/wakeups+signals, generated
index.json, bootstrap CLAUDE.md that clones the machinery repo); local checkouts
symlink `data/store` → the clone; empty store passes `validate-store.sh`.

The topology:

```
any device ──(self-email / Composio lanes)──▶ user accounts ──▶ sweeps pull → inbox/
phone/laptop ──(claude.ai/code cloud session on data repo)──▶ talk, debrief, query
scheduled routine ──(same cloud environment)──▶ sweep → commit to data repo main
any device ◀──(Gmail drafts, rendered repo files — plan 07)── connectors-out
```

## Deliverables
- `packages/core/scripts/store-sync.sh` — the write discipline every runtime uses
  against the data repo: `pull` (fetch+merge, loud on conflict), `commit` (validate
  store → rebuild index → commit), `push` (with one pull-merge retry for concurrent
  session races). No-op cleanly when the store isn't a git repo.
- Cloud environment spec (in `docs/runtime-cloud.md`), recording the VERIFIED
  2026-08-29 configuration (see composio-dual-transport): network access **full**
  (Trusted 403s composio.dev); setup script installs the CLI pinned to
  `COMPOSIO_INSTALL_VERSION=0.4.0` only — no login line (the Composio claude.ai
  connector is the session transport; CLI login waits on a fresh dashboard-minted
  `uak_` key and is optional until the sandbox proxy quirk resolves); env var
  `COMPOSIO_API_KEY` documented with the no-secrets-store caveat and rotation
  guidance; the routine definition for sweeps (cadence config; verify whether routines
  carry connectors). BOTH transports are firm requirements (user decision 2026-08-29):
  the connector wherever a model drives (queries, debriefs, cloud sessions), the CLI
  wherever code drives (deterministic sweep scripts, device-side cron/launchd) — the
  CLI is also the degradation path when the connector/cloud lane is unavailable. The
  local Mac's CLI session is already authenticated; every other runtime needs the
  fresh dashboard-minted `uak_` key (`composio login --user-api-key … --org ok_…`).
- Heartbeat/deadman: each sweep stamps `last-sweep` in the data repo; staleness > 2×
  cadence surfaces as a wake-up entry — a dead schedule announces itself.
- git-guard repo-scoping: the machinery repo's branch/push guard must not block the
  data repo's designed direct-to-main flow — scope the guard to the machinery repo's
  own paths/remotes.
- PII-and-secrets scan guard, three enforcement points sharing one scan script:
  (a) `.claude/hooks/pii-guard.sh` (harness guard on commit/push in the machinery
  repo); (b) a native git `pre-push` hook installed by a setup script — the push
  boundary is what matters in a public repo, a pushed branch is world-readable whether
  or not it merges; (c) CI as a **required PR check**. Flags real-looking emails,
  phone numbers, non-reserved domains outside synthetic-fixture conventions
  (`example.com`/`example.org`, reserved numbers) AND credential-shaped strings
  (API keys, tokens). Asserts `data/` stays gitignored. Named findings, never silent.
- `docs/EGRESS.md` — the allowlist per pii-egress-allowlist, updated for this
  topology: LLM provider + provider sandbox (cloud-native-runtime), the private data
  repo host, the user's own accounts via Composio (payloads transit Composio's cloud;
  retention caveat from composio-hub), public web-search queries (public-sphere
  identifiers only — told-by-user facts never leave in a query), rendered deliveries
  to the user's own surfaces. Adding a lane requires a DECISIONS entry.
- Home-hub appendix in `docs/runtime-cloud.md`: the Tailscale privacy variant, kept
  current enough to be followable, explicitly non-default.

## Work units
Wave A (parallel):
1. [worker] `packages/core/scripts/store-sync.sh` — pull/commit/push discipline,
   validate+reindex before commit, loud conflicts, one pull-merge retry, non-git no-op.
2. [worker] Tests for store-sync: commit rejects an invalid store; index regenerated;
   push race (simulated non-fast-forward) retries once then fails loudly; non-git dir
   no-ops.
3. [worker] `docs/EGRESS.md` + `docs/runtime-cloud.md` (environment spec, setup
   script content, routine definition, heartbeat rule, home-hub appendix).

Wave B (after A):
4. [worker] The shared scan script + its three mounts (harness hook, git pre-push +
   installer, CI required check) — PII patterns + credential patterns, gitignore
   assertion, named findings.
5. [worker] git-guard repo-scoping + the sweep-side heartbeat stamp and
   staleness→wake-up rule (via core's `wakeup-add.sh`).
6. [checker] End-to-end sim on fixtures: clone the (fixture) store fresh, run
   store-sync pull→commit→push against a bare remote, verify validate-gate blocks a
   bad store, heartbeat stamps, planted fake-PII and fake-API-key both caught by the
   scan, stale heartbeat yields exactly one wake-up.

## Interfaces
Consumes: store contracts + scripts (01); plan 06's sweep entry point (optional at
runtime); composio-in lanes (08); core's `wakeup-add.sh`.
Produces: the write discipline every session and routine uses; `docs/EGRESS.md`,
binding every stream — the mcp stream's remote answer surface ships answers, never the
store, and any transport it exposes must be authenticated/private.

## Proof of done
A cloud session opened on the data repo from a phone can debrief and commit with zero
manual steps; the scheduled routine runs the sweep unattended in the cloud environment
and its commit appears on the data repo's main; the two-remote sim passes; killing the
schedule surfaces a staleness wake-up; the scan blocks both a planted real-looking
email and a planted API key; `docs/EGRESS.md` enumerates every lane and nothing in the
repo transmits outside them.

## Out of scope
- Machinery-as-plugin packaging (its own later chunk — see ROADMAP Later)
- The query MCP server (mcp stream)
- Push notifications to the phone (output-adapter concern)
- Encryption-at-rest beyond what GitHub provides (documented in EGRESS.md as a
  hardening note)
- Local-model runtime (revisit trigger on pii-egress-allowlist)

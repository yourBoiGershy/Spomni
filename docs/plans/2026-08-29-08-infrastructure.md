# Plan 08: Infrastructure — sync, hub runtime, egress hygiene
Status: Ready
Package: core (store-sync script) + harness (`.claude/hooks/` guard) + docs; integrates attention's sweep (06)
Depends-on: 01; integrates 06's sweep entry point; constrains the mcp stream's remote surface

## Objective
Make the system reachable from any device at any time without chasing "always connected":
capture and delivery are store-and-forward over surfaces every device already has, the
private data repo is the sync rendezvous, and exactly one always-on hub runs the sweeps.
Simultaneously make the open-source posture honest: a finite, enumerated, mechanically
guarded list of lanes where person-data ever leaves the machine.

## Context
Read docs/PROJECT-CONTEXT.md first. Decisions that bind this plan:
- **git-as-sync-protocol** — git is the multi-device sync protocol; devices append only to
  `inbox/`, the hub writes everything else, so sync is conflict-free by construction; the
  store stays plain files and single-writer setups may use any synced folder.
- **home-hub-tailscale** — the always-on runtime is a user-owned machine over Tailscale;
  degradation floor is on-session-open sweeps (hybrid-runtime); cloud scheduled agents are
  explicit opt-in only.
- **pii-egress-allowlist** — every egress lane is enumerated in `docs/EGRESS.md`; the
  public repo mechanically cannot carry real data.
- **gmail-first-capture** — the universal capture lane is email; nothing in this plan may
  add a capture requirement beyond it.
- **code-data-separation** — this plan touches machinery and docs only; `data/` shape is
  read from core's contracts.

The topology this plan builds:

```
any device ──(self-email / future iOS-Shortcut commit)──▶ inbox/ in private data repo
                                                                │
                            always-on hub: pull → sweep (plan 06) → commit → push
                                                                │
any device ◀──(Gmail drafts, rendered repo files — plan 07)── connectors-out
      │
      └──(interactive: Tailscale to hub; MCP server itself = mcp stream's territory)
```

## Deliverables
- `packages/core/scripts/store-sync.sh` — the sync primitive every runtime calls:
  `pull` (fetch + merge, fail loudly on any conflict — a conflict means the single-writer
  discipline was violated, never auto-resolve), `commit <lane>` (stages only the paths the
  calling lane is allowed to write: `device` → `inbox/` additions only; `hub` → everything),
  `push`. Bash 3.2 portable, no-op cleanly when `data/` is not a git repo (synced-folder
  setups).
- Sync discipline doc section in `docs/runtime-hub.md`: the append-only device lane, the
  hub-as-sole-derived-writer rule, and why conflicts are structurally impossible when it's
  followed.
- `docs/EGRESS.md` — the allowlist: the five v1 lanes from the pii-egress-allowlist
  decision, each with what may flow through it and what must not (told-by-user facts never
  in web queries), plus the standing rule that adding a lane requires a DECISIONS entry.
- PII-scan guard: `.claude/hooks/pii-guard.sh` (pre-commit) + a CI-runnable script —
  scans staged/changed machinery-repo files for real-looking emails, phone numbers, and
  non-reserved domains outside the synthetic-fixture conventions (fixtures use
  `example.com`/`example.org` and reserved numbers); blocks with a named finding, never
  silently. Also asserts `data/` remains gitignored.
- Hub runtime kit in `docs/runtime-hub.md`: host options (per home-hub-tailscale),
  Tailscale setup, a launchd/cron template that runs `store-sync.sh pull` → plan 06's
  sweep → `store-sync.sh commit hub && push`, and cadence config.
- Heartbeat/deadman: each hub sweep stamps `last-sweep` (inside the data repo, so every
  device can see it); a staleness check (> 2× cadence) surfaces as a wake-up queue entry —
  silence must be impossible, a dead hub announces itself.

## Work units
Wave A (parallel):
1. [worker] `packages/core/scripts/store-sync.sh` — pure git ops, lane-scoped staging,
   loud conflict failure, non-git no-op path.
2. [worker] Tests for store-sync: two clones simulate device + hub; device appends to
   `inbox/` while hub rewrites `people/` + `index.json` → both sync clean; same-path
   double-write → loud failure; non-git dir → clean no-op.
3. [worker] `docs/EGRESS.md` + `docs/runtime-hub.md` — the allowlist and the hub kit
   docs (host options, Tailscale, sync discipline section, cadence config).

Wave B (after A):
4. [worker] `.claude/hooks/pii-guard.sh` + CI-runnable scan script + settings wiring —
   synthetic-fixture conventions enforced, `data/` gitignore asserted, findings named.
5. [worker] Hub schedule template (launchd + cron variants) invoking sync → sweep → sync,
   plus the `last-sweep` heartbeat stamp and the staleness→wake-up rule (via core's
   `wakeup-add.sh`, honoring the single-writer rule).
6. [checker] End-to-end sim on fixtures: seed two clones, run the full hub cycle
   unattended, verify clean sync both directions, heartbeat stamped, guard catches a
   planted fake-PII fixture violation, and a stale heartbeat produces exactly one wake-up.

## Interfaces
Consumes: store contracts (01); plan 06's sweep entry point (optional at runtime — the
schedule template skips it with a log line until 06 lands); core's `wakeup-add.sh` for the
deadman entry.
Produces: the sync primitive every runtime calls; `docs/EGRESS.md`, which binds every
stream — in particular the mcp stream's remote answer surface must ship inside lane (1)/(5)
semantics (answers leave, the store does not) and must sit behind Tailscale or equivalent
authenticated private transport, never a public tunnel.

## Proof of done
A note self-emailed from a phone lands in `inbox/` and is on the hub after its next cycle
with zero manual steps; the two-clone sim syncs conflict-free both ways and fails loudly
on a planted discipline violation; the hub cycle runs unattended from the schedule
template with a clean log; killing the hub surfaces a staleness wake-up within 2× cadence;
the pii-guard blocks a planted real-looking email address in a fixture; `docs/EGRESS.md`
enumerates every lane and nothing in the repo transmits outside them.

## Out of scope
- The query MCP server itself (mcp stream's territory — this plan only sets the transport
  and egress constraints it must obey)
- iOS-Shortcut→GitHub capture lane (deferred in ROADMAP; `store-sync.sh`'s device lane is
  designed to receive it later)
- Push notifications to the phone (output-adapter concern)
- Encryption-at-rest of the data repo beyond what the host provides (document as a later
  hardening item in EGRESS.md, don't build)
- Local-model runtime (the revisit trigger on pii-egress-allowlist)

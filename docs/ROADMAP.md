# Roadmap

Working tracker for the build. Each chunk is one plan in `docs/plans/`, sized so a single
focused session (with subagent fan-out) can complete it. Update Status here as chunks
move; the shareable build-plan artifact is the pretty view, this file is the truth.

## Chunks

| # | Plan | Package | Depends on | Status |
|---|---|---|---|---|
| 01 | Contracts & store | core | — | Done (2026-08-29, branch chunk-01-contracts-and-store) |
| 02 | Capture & Gmail inbox | connectors/gmail-in (+ core's inbox contract) | 01 | Ready |
| 03 | Filing engine | ingestion | 01, 02 | Ready |
| 04 | Calendar connector & matching | connectors/calendar-in + ingestion | 01 | Ready |
| 05 | Signal engine | attention (detection/ranking) | 01, 02 (email lanes), 04 (co-attendance) | Ready |
| 06 | Wake-up scheduler | attention (queue/sweeps) | 01; orchestrates 03/05 outputs | Ready |
| 07 | Output skills & adapters (briefs, nudge cards, file-out/gmail-out; query skill superseded by 08) | query + connectors/file-out, gmail-out | 01; 06 for nudge firing | Ready |
| 08 | Chat MCP & query data layer | query (MCP server) + core (stats contract, fixtures) | 01 | Done (2026-08-29, stream-mcp) |
| 09 | Infrastructure: cloud runtime, data-repo discipline, egress | core (sync script) + harness guards + docs | 01; integrates 06, 10 | In progress (2026-08-29, stream-infrastructure; data repo live) |
| 10 | Composio access layer | connectors/composio-in (+ shared normalizer) | 01 | Done (2026-08-29, branch chunk-08-composio-access; live-proven: 20 real events, 3 lanes, zero dupes) |
| 11 | Messaging-connectors research (Composio coverage, personal-account bridges, Beeper decision) | docs only (feeds 13) | — | Done (2026-08-29, stream-connectors; first 11 to merge — keeps the number) |
| 12 | Cadence & capacity-aware scheduling (routine map, week-plan contract, capacity-aware nudge selection) | attention + core (week-plan contract) + docs/runtime-cloud.md | 01; amends 05/06 (its amendment unit must land before either is dispatched); integrates 09 | Ready |
| 13 | Beeper capture connector (personal chats: whatsapp/linkedin/matrix; renumbered from 12 on merge) | connectors/beeper-in (+ shared normalizer) | 01, 10 (normalizer) | Done (2026-08-29, stream-connectors; live-proven: 25 real events, 3 networks, launchd 15-min schedule installed) |
| 14 | Composio import standard (capture-event 1.1/1.2: typing, occurred_at, <connector>/<lane> source, transport rule; renumbered from 11) | core (contract) + connectors (sweeps, normalizer, beeper alignment) | 01, 10, 13 | Done (2026-08-29, stream-composio-standardization; suites capture 82, beeper 70, store 20 green) |
| 15 | Preference & personalization layer (renumbered from 11) | core (profile/ranking-weights/wakeup 1.1) + ingestion/attention specs+goldens | 01, 08 | Done (2026-08-29, stream-personalization) |
| 16 | Eval harness: tool/agent/skill tiers (renumbered from 12) | core (eval-case contract, 4 runners) + query/ingestion/attention cases | 08, 15 | Done (2026-08-29, stream-personalization) |

> **Plan-number collision (2026-08-29, RESOLVED at merge):** three parallel streams
> each minted a "plan 11". `11-messaging-connectors-research` merged first and keeps
> 11; beeper-capture (drafted 12) took **13**; composio-import-standard took **14**;
> preference-personalization took **15**; the eval harness (drafted 12 on
> stream-personalization) took **16**. In-file references to the old numbers inside
> merged package specs/commits are historical.

Plans 05 and 06 are two plans within one package (`attention`) — see DECISIONS.md:
attention-merge. Plan 04 spans a thin connector plus ingestion-side matching — see
dumb-edges-smart-middle in PROJECT-CONTEXT.

Chunk 10 (DECISIONS.md: composio-hub; numbered 08 in its branch/commit history)
supersedes the *access mechanism* of plans 02 and 04 — pulls now go through the user's Composio account instead of first-party MCP.
Their intelligence deliverables survive but both plans need access-method revision
before execution: 02's classification/normalizer work moves onto the composio-in gmail
lane; 04's connector half becomes the composio-in calendar lane (matching half
unchanged).

## Streams (parallel-session worktrees)

Long-lived worktrees live in `../relationship-agent-worktrees/`, one per stream; each
stream runs its chunks serially (branch per chunk off `main`, merge back, `git merge main`
to resync — never rebase). Streams may run concurrently with each other.

| Worktree | Branch | Territory | Chunks |
|---|---|---|---|
| `ingestion/` | `stream-ingestion` | connectors-in + ingestion (data imports via Composio hub: gmail, calendar, linkedin, user inputs; texts = later local lane) | 10 → 02 → 04 → 03 |
| `mcp/` | `stream-mcp` | query + connectors-out (answer surface, briefs, model access) | 08 → 07 (06-dependent parts last) |
| `infrastructure/` | `stream-infrastructure` | cloud runtime + data-repo discipline + egress hygiene (plan 09; decisions git-as-sync-protocol, cloud-native-runtime, pii-egress-allowlist) | 09 |

Chunks 05/06 (attention) are unassigned — schedule after 02/04 land, either in a fourth
worktree or in `ingestion/` once it goes quiet. The single-writer rule still applies
across streams: a stream never edits another stream's packages.

### Merge cadence (keep main close, keep branches short-lived)

- A completed chunk merges to main **in the same session its checker passes** — chunks
  are sized for one session precisely so nothing needs to wait.
- At most **one** completed-but-unmerged chunk per stream at any moment; anything
  unmerged for more than a day is an escalation, not a backlog item.
- Docs-only work merges to main immediately; it never rides along waiting for code.
- After any merge to main, every active stream resyncs (`git merge main`) at its next
  session start, before new work.
- Note what fast merging does NOT do: a pushed branch in a public repo is already
  world-readable, merged or not. Data safety lives at the push boundary (pii-guard,
  plan 09), never in merge speed.

## Waves

- **Wave 1**: 01 alone — it freezes the six contracts and the fixture pack everything
  else builds and tests against.
- **Wave 2** (parallel): 02, 04 — independent given the contracts.
- **Wave 3** (parallel): 03, 05, 07 — the intelligence layer, built against real
  fixtures. Golden tests written before prompts (see DECISIONS.md).
- **Wave 4**: 06 — wires the queue and sweeps, then the end-to-end run on fixtures.
- **Live trial**: two weeks on real data. Exit criteria (from the build plan): phone-to-filed
  with zero manual steps; ≥80% meeting auto-match; ≥1 useful signal nudge/week with zero
  bare cadence reminders; ad-hoc reminders fire on time; ≥3:1 give-to-ask ratio; zero data
  loss. All six hold → tag v1, open the repo.

## Later (explicitly deferred)

- Output adapters beyond file/terminal + email (Slack, etc.)
- iOS-Shortcut→GitHub capture lane; WhatsApp/iMessage local bridges (at-your-own-risk docs)
- Local embeddings for fuzzy retrieval
- Auto-brief the morning of meetings (a standing wake-up)
- Harness Stage 2+ (gates, attestation, shipping pipeline) once there's CI worth gating
- Machinery-as-plugin packaging: ship skills/agents/hooks as a Claude Code plugin so any
  user opens their own private data repo and installs the machinery — the open-source
  distribution story (per cloud-native-runtime)

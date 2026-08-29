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

Plans 05 and 06 are two plans within one package (`attention`) — see DECISIONS.md:
attention-merge. Plan 04 spans a thin connector plus ingestion-side matching — see
dumb-edges-smart-middle in PROJECT-CONTEXT.

## Streams (parallel-session worktrees)

Long-lived worktrees live in `../relationship-agent-worktrees/`, one per stream; each
stream runs its chunks serially (branch per chunk off `main`, merge back, `git merge main`
to resync — never rebase). Streams may run concurrently with each other.

| Worktree | Branch | Territory | Chunks |
|---|---|---|---|
| `ingestion/` | `stream-ingestion` | connectors-in + ingestion (data imports: gmail, calendar, user inputs; messages deferred) | 02 → 04 → 03 |
| `mcp/` | `stream-mcp` | query + connectors-out (answer surface, briefs, model access) | 08 → 07 (06-dependent parts last) |
| `infrastructure/` | `stream-infrastructure` | phone access / remote runtime / sync — **no plan yet; needs planning first** | TBD |

Chunks 05/06 (attention) are unassigned — schedule after 02/04 land, either in a fourth
worktree or in `ingestion/` once it goes quiet. The single-writer rule still applies
across streams: a stream never edits another stream's packages.

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

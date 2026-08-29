# Roadmap

Working tracker for the build. Each chunk is one plan in `docs/plans/`, sized so a single
focused session (with subagent fan-out) can complete it. Update Status here as chunks
move; the shareable build-plan artifact is the pretty view, this file is the truth.

## Chunks

| # | Plan | Package | Depends on | Status |
|---|---|---|---|---|
| 01 | Contracts & store | core | — | Ready |
| 02 | Capture & Gmail inbox | connectors/gmail-in (+ core's inbox contract) | 01 | Ready |
| 03 | Filing engine | ingestion | 01, 02 | Ready |
| 04 | Calendar connector & matching | connectors/calendar-in + ingestion | 01 | Ready |
| 05 | Signal engine | attention (detection/ranking) | 01, 02 (email lanes), 04 (co-attendance) | Ready |
| 06 | Wake-up scheduler | attention (queue/sweeps) | 01; orchestrates 03/05 outputs | Ready |
| 07 | Output skills & adapters | query + connectors/file-out, gmail-out | 01; 06 for nudge firing | Ready |

Plans 05 and 06 are two plans within one package (`attention`) — see DECISIONS.md:
attention-merge. Plan 04 spans a thin connector plus ingestion-side matching — see
dumb-edges-smart-middle in PROJECT-CONTEXT.

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

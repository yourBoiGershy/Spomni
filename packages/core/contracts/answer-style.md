# Contract: answer style

`version: 1.0.0`

The shared render contract every user-facing answer or card follows: session
answers from `packages/query` skills, nudge cards (`contracts/nudge-card.md`,
plan 33), and the `packages/ingestion` review-tiers correction digest. It
governs *how* a proposal is shown, never what it proposes or whether it
sends — the human always sends (`docs/DECISIONS.md`, standing principle
"draft, never send"). Encodes user direction 2026-08-30: condensed,
action-first, one concrete next step per item, draft offered on request.

## Rules

1. **Lead with the action.** First line is the situation in ≤ 1 line (e.g.
   `This week (Wed/Thu open):`), then the list. No preamble, no method
   narration (never explain how the ranking was computed inline).
2. **One item = ≤ 2 lines.**
   - Line 1: `<n>. <Name> — <trigger/hook>` — the *why now*, drawn from the
     person's facts. Never a bare cadence like "90 days since last contact".
   - Line 2: `→ <one concrete action>` (call, coffee Tue AM, reply to the
     invite, ask about X). Every item ends in an action.
3. **Cap 5 items.** Ranked by warrant, not by raw score. Skipped candidates
   are not listed unless the user asks "why not X".
4. **Draft on demand.** Never render a message draft inline. Close every
   answer with the reply line offering it:
   `Reply: <n> draft | <n> done | <n> snooze <dur> | <n> skip | <n> never`
   Session skills may render the same verbs as plain sentences, e.g. "Say
   `2 draft` and I'll write it — you send."
5. **No scores, no breakdowns**, unless explicitly asked; no JSON.
6. **No-guilt** (binding, from plan 33 D3): never use "pending", "missed",
   "overdue", counts of held items, or streaks in any rendered answer.
7. **Honesty line, once, at the end, only when material:** one sentence when
   the ranking is degraded (e.g. tiers/kinds absent, so ranking fell back to
   facts-by-hand) or when a candidate is a stub (a `name-from-email` tag).
   Never repeat this per item.
8. **Provenance stays visible where it matters:** a hook drawn from a
   `[told-by-user]` fact needs no tag; a hook drawn from public-web
   enrichment is tagged `(public)`.
9. **Plain text renders everywhere** — no markdown tables in cards; session
   answers may use a numbered list (as in the worked example below).

## Worked example

```
This week (Wed/Thu open):
1. Dana Brooks — open dinner invite since April
   → say yes, propose a date
2. Priya Shah — you gave her your race bib; Tokyo in the fall
   → ask how the leg is
3. Omar Reyes — intro via Dana, one call in June, silent since
   → coffee Tue AM
Reply: <n> draft | <n> done | <n> snooze <dur> | <n> skip | <n> never
```

(Names are fictional, not drawn from any real contact.)

## Consumers

- `packages/query` skills — session answers to "who should I reach out to"
  and similar queries conform to this contract.
- `packages/core/contracts/nudge-card.md` (plan 33, to be built) — the
  push-side card format must conform on creation.
- `packages/ingestion/specs/review-tiers.md` — the correction digest
  conforms on its next revision.

## Notes

This contract shapes rendering only. It does not define ranking, warrant
computation, or the wake-up/nudge lifecycle — see
`contracts/relationship-scoring.md` and `contracts/wakeup.md` for those.

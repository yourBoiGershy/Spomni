---
name: who-next
description: Answers "who should I reach out to?" as a condensed, action-first, hand-judged list from the store's facts — never trusts raw suggest_reachouts ranking. Read-only; drafts a message only on request, and the human always sends — draft, never send.
---

# who-next

`/who-next [friends|coffee|all] [--limit N]` — read-only answer, over the
`spomni-query` MCP server (`packages/query/server/`, registered project-wide
via the root `.mcp.json`). It re-judges candidates from each person's facts
instead of trusting `suggest_reachouts`'s raw order, which today over-ranks
recurring-meeting attendees, landlords, and cold pitches because tiers are
usually `null`. Renders per `packages/core/contracts/answer-style.md`
1.0.0 — read that contract in full; this skill restates its rules below for
convenience but the contract is the source of truth.

## 1. Parse args

- Mode: `friends` | `coffee` | `all` (default `all`).
- `--limit N`: default 5, hard max 5 (the answer-style contract caps at 5
  regardless of what is asked).

## 2. Build the candidate pool

- Call `suggest_reachouts {limit: 10}`.
- Call `search_people` (page 1–2), sorted by oldest `last_interaction`.
- Union the two lists; drop anyone touched in the last 14 days.
- Drop stubs: `tags` contains `name-from-email`, or `name` is a single
  token with zero Facts bullets (checked in step 3).
- Cap the working pool at 20 candidates before the per-person lookup.

## 3. Judge each candidate from facts

For each of the ≤20 candidates, call `get_person {slug}` and read the
`Facts` / `Personal details` sections — this is judgment on the wording,
not a regex match. Classify:

- **friend** — hang out, trip, board games, family terms, "close friend",
  running buddy, standing invitations.
- **professional** — intro'd by X, founder, works at, call booked,
  "reached out about".
- **transactional/closed** — landlord, lease ended, league admin, mail,
  inbound sales/LinkedIn pitch, recruiter. Always excluded.
- **unknown** — no Facts bullets, calendar-only. Treat as a stub candidate.

Mode filter: `friends` keeps friend only; `coffee` keeps professional with
a warm hook (a prior intro, a call, a shared event) and excludes inbound
pitches; `all` keeps friend + professional.

## 4. Pick the hook and the action

- **Hook**: the most specific, most recent `[told-by-user]` fact that
  gives a reason *now* — an open invite, an upcoming race, an intro gone
  quiet, a trip they made. Never use bare cadence ("N days since contact")
  as the hook.
- **Action**: one concrete verb phrase tied to that hook (say yes and
  propose a date, ask how the leg is, coffee Tue AM).
- If a fact is public-web-sourced rather than told-by-the-user, tag its
  use in the hook `(public)`; told-by-user facts carry no tag.

## 5. Rank

Order: open thread/commitment > standing invitation > warm intro gone
quiet > friend gone silent > silent ≥8 weeks > everything else. Ties break
by longer silence first. Take the top `--limit` (≤5).

## 6. Availability line (optional)

If a first-party Google Calendar connector
(`mcp__claude_ai_Google_Calendar__list_events`) is present in the current
session, call it for the next 7 days and open the answer naming the open
days (e.g. `This week (Wed/Thu open):`). If the connector is not present,
omit the availability clause silently — do not mention its absence.

## 7. Render — `packages/core/contracts/answer-style.md` 1.0.0, verbatim rules

1. Lead with the action: first line = situation in ≤1 line, then the list.
   No preamble, no method narration.
2. One item = ≤2 lines. Line 1: `<n>. <Name> — <trigger/hook>`. Line 2:
   `→ <one concrete action>`.
3. Cap 5. Ranked by warrant, not score. Skipped candidates unlisted unless
   the user asks "why not X".
4. Draft on demand — never render a draft inline. Close with the reply
   line offering it.
5. No scores/breakdowns/JSON unless asked.
6. No-guilt (binding): never "pending", "missed", "overdue", held counts,
   streaks, batch age.
7. One honesty sentence at the end only when material (tiers/kinds absent
   so ranking is facts-by-hand; a top candidate is a stub).
8. Provenance: `[told-by-user]` hooks untagged; public-web facts tagged
   `(public)`.
9. Plain text / numbered list; no tables.

Worked example (fictional names only — never real contacts):

```
This week (Wed/Thu open):
1. Dana Brooks — open dinner invite since April
   → say yes, propose a date
2. Priya Shah — you gave her your race bib; Tokyo in the fall
   → ask how the leg is
3. Omar Reyes — intro via Dana, one call in June, silent since
   → coffee Tue AM
Say "<n> draft" and I'll write it — you send. (<n> done | snooze <dur> | skip | never also work.)
Ranking is from facts by hand — no tiers exist yet; run /review-tiers --all to fix that.
```

## 8. This skill never sends

Draft, never send — this skill only reads (`suggest_reachouts`,
`search_people`, `get_person`, `get_contact_stats`, `upcoming_meetings`,
and the optional read-only calendar list) and never calls any `send` or
`create` tool.

If the user replies `<n> draft`, compose the draft in-session from that
person's Facts and, if present, `profile.md`'s `## Style notes`. Head it
`Draft (unsent):` and stop there — the user sends it themselves.

If the user replies `<n> done|snooze|skip|never`, acknowledge in one line
in-session. There is no durable ledger for these yet in this skill — that
lands with plan 34's wake-up integration; mention that only if asked.

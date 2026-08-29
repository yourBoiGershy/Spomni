# Plan 22 — Live-data query sync & verification (plan 18 close-out)

Verification only — runs the machinery, builds none. Chunk 18 wired and proved the
query surface against fixtures; the live proof waited on chunk 20's filed backlog.
Chunk 20's Phase 5 shakedown already produced 6/6 cited answers via a fresh server,
so this chunk collapsed (as the roadmap predicted) to registration cleanup + smoke
re-run + real-chat verification. Executed orchestrator-only, same day, in worktree
`chunk-22-live-query-verify`.

## What was run, and results

**(a) Store wiring.** Fresh worktree pointed at the filed live store per
`docs/chat-setup.md` interim note: `data/store` symlinked at the live capture
location (the ingestion worktree's `data/store` — 21 people, interactions filed
2026-08-29 by chunk 20). The data-repo clone is still empty (capture-store ↔
data-repo sync is plan 09/19 territory), so the main checkout's `data/store`
symlink — which pointed at that empty clone — was also flipped to the live capture
store. Both are local, gitignored acts; flip them back to the data-repo clone when
sync lands.

**(b) Smoke.** `bash packages/query/tests/smoke-live.sh`: **6/6 PASS**, real
`generated_at`, non-degraded stats (search_people total=21). Store read-only guards
covered by the query suite (fixture store git-clean, no index/stats written).

**(c) Live chat.** Three real questions, each in a fresh headless session
(`claude -p`, spomni-query tools only), all answered from the live store with
citations and provenance intact (evidence = citation counts, content withheld):

1. *Who should I reach out to this week?* — ranked suggestions citing 5
   `people/*.md` paths, heuristic-fallback provenance stated (no pending wakeups,
   no filed upcoming meetings).
2. *When did I last talk to \<person\> and what about?* — correct last-touch date,
   2 people files + 3 interaction files cited, source-capture id surfaced, all
   facts labeled **[told-by-user]**, open thread + commitment reported.
3. *What meetings do I have coming up?* — honest empty result over 7- and 30-day
   windows via `upcoming_meetings`, correctly distinguished "nothing filed" from
   "empty store" (21 index citations), and correctly declined to exceed the
   query-only constraint.

**(d) Registration cleanup.** The legacy entry was project-**local** scope (not
user scope as the roadmap guessed) — absolute paths in `~/.claude.json` under the
main checkout, predating the root `.mcp.json`; `claude mcp list` flagged a
scope conflict. Removed with `claude mcp remove spomni-query -s local`. Now
exactly one registration exists (project `.mcp.json`, repo-relative), connected,
no conflict diagnostic.

**Suites.** Store 10/10; query 29/29; T2 evals 3 pass / 2 xfail / 0 fail / 0 error
(xfails are the recorded plan-13 personalization gaps: `opt-out-respected`,
`stated-outranks-revealed`).

## Gotcha for fresh checkouts

`packages/query/evals/fixtures/overlaid-store/` is **generated**, not committed —
the T2 suite errors on those two cases in a fresh checkout until you run
`bash packages/query/evals/fixtures/build-overlaid-store.sh`. Noted in plan 18's
proof-of-done; candidate for an eval-suite preflight if it bites again.

## Proof of done

- [x] Smoke exit 0 over the filed store, non-degraded stats.
- [x] ≥3 fresh-session chat answers citing real store paths, provenance intact.
- [x] Exactly one `spomni-query` registration.
- [x] Plan 18's proof-of-done checklist fully closed out in its plan file;
  ROADMAP rows 21 (stale "Planned") and 22 flipped to Done.

Status: Done (2026-08-29, chunk-22-live-query-verify)

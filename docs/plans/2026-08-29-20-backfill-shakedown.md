# Plan 20: Backfill blitz & ship-day shakedown (SHIP GATE)

Status: Ready
Package: cross-package operational run — builds NO new machinery; exercises
ingestion (debrief skill), connectors (sweeps, check-sync), core (validate,
index), query (spomni-query MCP)
Depends-on: 03 (filing engine, merged), 13 (beeper lane LIVE, launchd 15-min),
18 (query MCP registered as `spomni-query`)
Runs: TODAY, 2026-08-29. Ship deadline 2026-08-30. No soak window exists —
this compressed live run IS the pre-ship test.

## Objective

File the entire real inbox backlog (46 events: 25 beeper, 15 gmail, 4
calendar, 1 linkedin, 1 quarantine), prove the capture→file→query loop end to
end on real data, and produce the ship-notes known-issues list — all today.
Zero data loss is the only hard ship blocker; everything else that can't be
fixed in one dispatch round becomes a known-issue and ships.

## Binding facts (do not re-derive)

- **Live store (outside this worktree):**
  `<worktrees-root>/ingestion/data/store`
  (dirs: `inbox/ interactions/ people/ wakeups/`). Every script below takes
  this absolute path as `<store-dir>`. Call it `$STORE` throughout:

  ```sh
  STORE=<worktrees-root>/ingestion/data/store
  ```

- **Filing ledger:** the debrief skill's dedup ledger lives at
  `<worktrees-root>/ingestion/data/ingestion/debrief-filed.log`
  (relative `data/ingestion/` — so every filing agent's **cwd must be the
  ingestion worktree root**, `<worktrees-root>/ingestion`).
- **Filing skill:** `packages/ingestion/skills/debrief/SKILL.md` — batch mode,
  oldest-first by `captured_at`, never reads `inbox/quarantine/`, never
  mutates `inbox/`, appends to the ledger only after a successful filing.
- **Audits:**
  `bash packages/core/scripts/validate-store.sh $STORE` (people/interactions/
  wakeups — not inbox) and
  `bash packages/connectors/scripts/check-sync.sh $STORE` (inbox conformance
  to capture-event 1.2.0: per-lane rules, wrapper leaks, dups).
- **Lanes today:** beeper is live under launchd (15-min; whatsapp + linkedin +
  matrix; `packages/connectors/beeper-in/scripts/beeper-sweep.sh`). Gmail
  flows via the existing composio lane
  (`packages/connectors/composio-in/skills/gmail-sweep/SKILL.md`). **Do not
  touch composio setup/teardown — that is chunk 17, not today.**
- **Query surface:** `spomni-query` MCP server, six read-only tools:
  `search_people`, `get_person`, `list_interactions`, `get_interaction`,
  `get_contact_stats`, `suggest_reachouts`.
- **Fix policy (this run):** any defect wave gets **ONE fix-dispatch round
  max**. Not fixed after one round → known-issue in the ship notes — unless
  it loses data, which is the sole hard blocker.
- **Standing principles in force:** draft-never-send (no outreach is sent at
  any point today); provenance tags on every filed fact; other people's data
  stays local; capture is lossy-tolerant (a missed/held event is never guilt,
  never deleted).

## Ship notes location & PII rule

Known-issues list: `docs/ship-notes-2026-08-30.md` in this (public) repo,
written by the orchestrator. **No store PII ever enters it** — reference
events by capture-event `id` and lane only; never person names, slugs, email
addresses, or message content. Anything person-identifying goes to a
companion note inside the private data dir
(`<worktrees-root>/ingestion/data/ship-notes-private.md`),
which never leaves the user's machine.

## Phases

| Phase | Goal | Executor | Depends-On |
|---|---|---|---|
| 0 | Preflight: baseline, snapshot | orchestrator | — |
| 1 | Backlog filing, batched | filing workers (sequential) + checker pairs | 0 |
| 2 | Ambiguity resolution + triage sweep | orchestrator + user, then 1 filing worker | 1 |
| 3 | Full-store audits + one fix round | orchestrator (+ fix workers if needed) | 2 |
| 4 | Fresh-sweep round-trip (beeper + gmail) | orchestrator + 1 filing worker | 3 |
| 5 | Query shakedown (six tools) | orchestrator | 3 (runs concurrent with 4) |
| 6 | User pass, ship notes, GO/NO-GO | orchestrator + user | 4, 5 |

### Phase 0 — Preflight (orchestrator, ~10 min)

1. Record the baseline manifest (this is the zero-loss reference for the
   whole day):

   ```sh
   ls "$STORE/inbox/"*.md | wc -l          # expect 45 fileable
   ls "$STORE/inbox/quarantine/" 2>/dev/null   # expect 1 event
   wc -l <worktrees-root>/ingestion/data/ingestion/debrief-filed.log 2>/dev/null  # ledger baseline (likely absent/0)
   ls "$STORE/interactions/" "$STORE/people/" | sort > /tmp-scratch-or-notes  # pre-filing artifact list
   ```

   Roadmap says 46 events total (25 beeper, 15 gmail, 4 calendar, 1 linkedin,
   1 quarantine). Record the **actual observed** counts and full `inbox/`
   filename list as the manifest; if observed ≠ 46, note the delta in ship
   notes and proceed — the manifest, not the roadmap number, is the loss
   baseline from here on.
2. Baseline audits BEFORE filing, so pre-existing defects are attributable:

   ```sh
   bash packages/connectors/scripts/check-sync.sh "$STORE"
   bash packages/core/scripts/validate-store.sh "$STORE"
   ```

   Failures here are pre-existing; log them, don't fix yet (they join Phase
   3's single fix round if still present).
3. Snapshot the private data dir (rollback insurance): if
   `<worktrees-root>/ingestion/data` is a
   git repo, commit a `pre-blitz snapshot 2026-08-29` commit; otherwise
   `tar -czf` the whole `data/` tree to
   `.../ingestion/data/backups/pre-blitz-2026-08-29.tar.gz` (stays inside the
   private dir — never the public repo, never cloud).

**Phase complete when:** manifest recorded, both baseline audit outputs
captured, snapshot exists.

### Phase 1 — Backlog filing, batched (sequential workers + parallel checker pairs)

**Batching:** the ~45 fileable events, oldest-first by `captured_at`, in
batches of **8** (last batch takes the remainder — expect 6 batches). Batches
run **strictly sequentially, one filing worker at a time** — the ledger,
`index`, and shared `people/` files make concurrent filing a race
(single-writer rule applies to the run, not just the code). After each batch,
a **pair of read-only checkers runs in parallel** (with each other) before
the next batch is dispatched.

**Per-batch filing worker (mutating, ≤3-min brief):**

- cwd: `<worktrees-root>/ingestion`
- Brief: "Run the debrief skill
  (`packages/ingestion/skills/debrief/SKILL.md`) in batch mode over
  `$STORE`, filing at most the next 8 unfiled events oldest-first, then
  stop." Constraints in the brief:
  - Research-seed pass **off** (skill default — do not enable).
  - Ambiguity (§4 of the skill): make no writes for that event, do NOT ask
    the user mid-run — record the exact one-question text + candidates in
    the completion report and move on. The event stays out of the ledger.
  - New-person creation per the skill's own bar; zero-match fragments held
    per the skill (report them).
  - Per-event index rebuild + validate per skill §5c; a validate failure
    stops the worker with the failing event id in the report.
  - Report: event ids filed, ids held (with reason class:
    ambiguous / new-person-hold / other), files written.

**Per-batch checker pair (read-only, parallel, ≤3-min each):**

- Checker A — integrity: `bash packages/core/scripts/validate-store.sh
  "$STORE"` green; ledger line-count grew by exactly (batch size − held
  count); `inbox/` filename list unchanged vs. the Phase 0 manifest (nothing
  deleted/renamed); index consistent with `people/` + `interactions/`.
- Checker B — fidelity spot-audit: pick 3 of the batch's filed events; for
  each, compare source capture event vs. its interaction + person writes:
  every new Facts bullet tagged `**[told-by-user]**` with capture date;
  summary is a retelling, not a verbatim body copy; `last-touch` moved
  correctly and never backward; commitments attributed to the right owner;
  no invented detail on thin events. Report findings with severity.

Checker findings do NOT trigger mid-phase fixes — they accumulate into Phase
3's single fix round (unless a finding indicates **data loss** — inbox
mutation, ledger corruption — which halts the phase immediately for the fix
round now).

**Phase complete when:** every fileable inbox event is either in the ledger
or on the held-list with a recorded reason; all batch checkers reported.

### Phase 2 — Ambiguity resolution + triage sweep (orchestrator + user)

1. Consolidate the held-list from Phase 1 worker reports. Ask the user all
   held-event questions in ONE consolidated message (each event still gets
   only its one question, per the skill — the batching is presentation,
   not extra asks). No-guilt rule: the user may decline any of them.
2. Dispatch **one** filing worker (same brief shape as Phase 1, cwd
   ingestion worktree) over the now-resolvable events, passing the user's
   answers as context. Run the Phase 1 checker pair once after it.
3. Review the pre-existing `inbox/quarantine/` event: record its id, lane,
   and quarantine reason in ship notes. Leave it in quarantine — no
   machinery fixes today (normalizer bugs are chunk 17/19 territory).
4. **Triage rule for anything still unfileable** (user declined, fragment
   unresolvable, event genuinely unclassifiable):
   - The event is NEVER deleted and never enters the ledger.
   - Default disposition: **hold** — it stays in `inbox/` as-is, eligible
     for a future pass, with a ship-notes line: `id, lane, reason,
     disposition: hold-for-context`.
   - Quarantine (move to `inbox/quarantine/`) only for events that are
     malformed/unreadable as capture events — executed by the orchestrator
     (a `data/` file move, orchestrator-editable), each with a written
     reason: `id, lane, reason, disposition: quarantined`.

**Phase complete when:** ledger ∪ ship-notes-triage-lines account for 100% of
the Phase 0 manifest — no event unaccounted.

### Phase 3 — Full-store audits + the one fix round (orchestrator)

```sh
bash packages/connectors/scripts/check-sync.sh "$STORE"
bash packages/core/scripts/validate-store.sh "$STORE"
```

Plus the zero-loss check against the Phase 0 manifest: `inbox/` file list is
a superset of the baseline (append-only held), quarantine moves match the
Phase 2 triage lines exactly, ledger has no ids absent from `inbox/`.

Triage all accumulated defects (baseline audit failures, batch checker
findings, anything the full audits surface now):

- **Data loss** (an inbox event missing/mutated, ledger claiming a filing
  that produced no artifact): hard blocker — fix round is mandatory and the
  gate cannot pass until resolved (restore from the Phase 0 snapshot if
  needed).
- **Store-data defects** (a bad filed artifact, wrong tag, mis-write):
  fixable by data edits — orchestrator may fix directly (store is `data/`,
  orchestrator-editable) or dispatch fix workers.
- **Machinery defects** (a bug in a script/skill): today, machinery is
  frozen — record as known-issue with a repro pointer, UNLESS it is the
  cause of data loss, in which case it joins the fix round (dev-worker on a
  branch in the owning package's worktree, per the splitting rule).

Dispatch ALL fixes as **one parallel wave** (this is the run's ONE
fix-dispatch round), then re-run both audit scripts once. Whatever still
fails and is not data loss → known-issue, ship anyway.

**Phase complete when:** both scripts exit green (or every residual finding
is a logged non-loss known-issue — but the deliverable target is green, so
green is the expectation), zero-loss check passes.

### Phase 4 — Fresh-sweep round-trip (orchestrator + one filing worker)

Prove capture→inbox→filed→queryable on BOTH live lanes, today.

1. Record current `inbox/` count/list.
2. **Beeper:** ensure at least one new message exists on a beeper network
   since the last sweep (natural traffic, or the user sends a real message
   in an existing thread — the user sending their own message is not agent
   outreach; draft-never-send is untouched). Then either wait for the next
   15-min launchd tick or trigger the job now: find the label via
   `launchctl list | grep -i beeper`, then
   `launchctl kickstart -k gui/$(id -u)/<label>`. Confirm ≥1 new
   `inbox/*.md` with `source: beeper-in/<network>` appears.
3. **Gmail:** run the existing lane as it is today — the gmail-sweep skill
   per `packages/connectors/composio-in/skills/gmail-sweep/SKILL.md`,
   targeting `$STORE` (composio config untouched; if the mailbox has
   nothing new, the user sends themselves a test email first). Confirm ≥1
   new `inbox/*.md` with the gmail lane source.
4. `bash packages/connectors/scripts/check-sync.sh "$STORE"` — the new
   events must conform (this also live-verifies real lane output against
   1.2.0; note any plan-14-caveat field-shape findings in ship notes for
   chunk 17).
5. Dispatch one filing worker (Phase 1 brief shape) over the new events;
   run validate-store after.
6. Query the round-trip closed: `list_interactions` /`get_interaction` via
   `spomni-query` must return the freshly filed interactions with their
   `source-capture` ids pointing at the new events.

**Phase complete when:** both lanes each show one event traced
sweep→inbox→interaction→query answer, audits still green.

### Phase 5 — Query shakedown (orchestrator; concurrent with Phase 4 once Phase 3 is green)

From the live session, exercise ALL SIX `spomni-query` tools against the
filed store with real questions:

1. `search_people` — search a name known to be in the backlog.
2. `get_person` — fetch that person; verify facts carry provenance tags and
   match filed interactions.
3. `list_interactions` — list recent; verify dates/people match Phase 1
   filings.
4. `get_interaction` — fetch one; verify `source-capture` cites a real
   inbox event id.
5. `get_contact_stats` — verify counts are plausible against the ledger
   (spot-check one person's interaction count by hand).
6. `suggest_reachouts` — verify suggestions cite real store data (score
   breakdown referencing actual last-touch/threads), not fixtures.

Pass bar per tool: a real answer grounded in the filed store, citing actual
captured interactions — an empty/fixture/hallucinated answer is a defect
(joins the Phase 3 fix round if it hasn't run yet; otherwise known-issue,
since a query defect loses no data). Keep transcripts as gate evidence in
the private data dir note (they contain PII).

**Phase complete when:** six for six, each with a recorded real-data answer.

### Phase 6 — User pass, ship notes, GO/NO-GO (orchestrator + user)

1. **User pass over the filed people list:** show the user the people index
   (or `search_people` sweep). User flags obvious mis-merges/dupes. Obvious
   quick fixes are data edits — orchestrator fixes directly in the store
   (append-only rules of the person contract respected). Anything
   non-trivial → known-issue line (private note for names, public note by
   count only: "N possible dupes logged").
2. **Write `docs/ship-notes-2026-08-30.md`** (orchestrator): date, manifest
   summary (counts only), audit results, triage table (event ids + lanes +
   reasons), known-issues list (machinery defects with repro pointers,
   query quirks, plan-14 field-shape observations for chunk 17, dupe count),
   and the gate verdict below. PII rule above applies.
3. **Ship gate — GO requires ALL of:**
   - [ ] 100% of the Phase 0 manifest accounted: every event id in the
     ledger OR in a triage line with reason (filed / hold-for-context /
     quarantined).
   - [ ] `check-sync.sh $STORE` exit 0.
   - [ ] `validate-store.sh $STORE` exit 0.
   - [ ] Fresh-sweep round-trip proven on beeper AND gmail (Phase 4 step 6
     evidence).
   - [ ] All six `spomni-query` tools returned real cited answers.
   - [ ] `docs/ship-notes-2026-08-30.md` exists and is PII-clean.
   - [ ] **Zero data loss:** inbox append-only vs. manifest, snapshot
     intact, no unexplained artifact disappearance.
   - **NO-GO condition (the only one): data loss.** Any other open item is
     a known-issue and ships. If audits are non-green on a non-loss issue
     after the one fix round, the orchestrator escalates to the user for an
     explicit accept-and-ship decision recorded in the ship notes.
4. On GO: commit the private data repo (post-blitz state); merge this
   plan/ship-notes branch to main per merge cadence; update
   `docs/ROADMAP.md` chunk 20 status to Done; log GrowthPal `wins_capture`
   (chunk 20, what shipped, proof-of-done evidence — no store PII).

## Proof of done (all TODAY)

Backlog 100% filed or explicitly triaged with reasons; both audit scripts
green on the live store; fresh-sweep round-trip proven on beeper + gmail;
all six query tools returning real cited answers; ship notes written at
`docs/ship-notes-2026-08-30.md`; zero data loss confirmed against the Phase
0 manifest.

## Out of scope

- Any new machinery, or edits to packages/ beyond a data-loss-causing bug
  fix (its own branch, one fix round).
- Composio teardown or direct Google lanes (chunk 17); sync scheduler
  (chunk 19).
- Longitudinal organization-quality watching — post-ship monitoring, per
  the roadmap pivot.
- Rewriting the pre-1.2.0 backlog events to newer contract shapes (valid
  as-is; readers accept all 1.x).
- Any outreach: nothing is sent to anyone today. Draft-never-send stands.

Status: Ready

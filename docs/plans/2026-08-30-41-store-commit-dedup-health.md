# Plan 41 — Store commit lane, capture-time dedup, sync health

**Mission test:** all three cut *remembering-to*: the store commits itself
(no "did I push?"), duplicates never enter the inbox (no cleanup chores),
and a quiet or dead lane announces itself. No ingredient touched. Explicitly
NOT built: any "unfiled backlog" nudge — CLAUDE.md forbids backlog guilt.

## Units

### A — `store-sync.sh tick` + `store-commit` lane (core + template)
`tick` = `pull` → `commit -m "sync tick <iso>"` → `push` only if a commit
was made or `ahead>0`. Prints one summary line
`store-sync: tick pulled=<ff|merge|none|skipped> committed=<sha|none> pushed=<yes|no|skipped>`.
Any FAIL from a sub-step stops the tick, exit 1 (the lane log carries it;
staleness will not flag it — exit code is not staleness — but the failure
text is in `logs/store-commit.log`). Template row (after `learn`):
`store-commit	900	true	/bin/bash {{REPO_ROOT}}/packages/core/scripts/store-sync.sh {{STORE_DIR}} tick`.
Tests in `packages/core/tests/test-store-sync.sh`.

### B — Capture-time fingerprint dedup (connectors normalizer) + `inbox-dedup.sh`
`normalize-capture.sh`: sha256 of the body → `<store>/inbox/.fingerprints`
(`hash<TAB>id`, append-only, created lazily by scanning existing inbox/*.md
bodies once). Non-empty body whose hash is already present → **exit 3**,
stdout = existing inbox path, nothing written, nothing quarantined. Empty
bodies never dedup. `beeper-sweep.sh` treats rc 3 as "seen": advances the
cursor, counts `dedup=N` in its `runs.log` line (`ok chats=N events=N
quarantined=N dedup=N`), does not count it as an event.
New `packages/connectors/scripts/inbox-dedup.sh <store> [--apply]`: rebuilds
`.fingerprints` from scratch, lists later byte-identical duplicates (keeps
the earliest `captured_at`), `--apply` deletes them unless the id appears in
`<private-data-root>/data/ingestion/debrief-filed.log` (raw that was filed
is kept forever). Contract note in `capture-event.md` (exit 3 + index file;
`.fingerprints` is dot-prefixed so check-sync/validate ignore it).

### C — `staleness.sh` zero-yield condition + `staleness` lane (attention + template)
New subject `<lane>-yield` for enabled capture lanes that have a
`<sync-data-dir>/connectors/<lane>-in/runs.log`: stale when the last 24h
(by line timestamp, ≥ 4 `ok` lines) are all `events=0` **and** no `ok` line
with `events>0` exists in the window. Why-text: "lane <lane> has run N times
in 24h with 0 new events — is <app> open / signed in?". Same
`create_staleness_wakeup` gate (one pending at a time). Template row:
`staleness	3600	true	/bin/bash {{REPO_ROOT}}/packages/attention/scripts/staleness.sh {{STORE_DIR}} --sync-data-dir {{DATA_DIR}}`.
Delivery of the resulting wake-up is unchanged: the sweep's fire step +
notify lane.

### D — Tests for B (capture suite + beeper capture suite)
### E — Tests for C (staleness suite)
### F — Docs: SETUP.md §5 (store-commit, staleness rows; inbox-dedup one-time
cleanup), ROADMAP row 41.

## Live cutover after merge
`sync-scheduler.sh init --force` (or add the two rows) + `install`;
`inbox-dedup.sh <store>` then `--apply` to drop today's 20 re-captures;
copy the 50 orphan-store captures into inbox/ and let the fingerprint gate
+ file-thread union sort them.

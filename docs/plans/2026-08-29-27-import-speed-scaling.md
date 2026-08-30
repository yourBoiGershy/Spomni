# Plan 27: Import speed & scaling

Status: Ready
Package: ingestion (shard pre-pass, debrief shard mode, triage perf, specs,
tests, eval, bench fixtures) + connectors (two LOW-advisory riders)
Depends-on: 26 (import-pipeline contract 1.0.0, triage tier, held ledger),
25 (episode-split; the live-corpus baseline), 24 (eval doctrine)
Branch: chunk-27-import-speed

## Objective

Make import fast without redesigning it. Chunk 26's pipeline (core contract
`packages/core/contracts/import-pipeline.md` 1.0.0) makes everything before
judgment deterministic and parallel-safe; `file` shards cleanly by person.
Deliver: (a) person-sharded parallel filing waves — a deterministic pre-pass
partitions the eligible batch so no two parallel debrief workers can touch
the same person file, index rebuilt once at the end; (b) concurrent lane
fetch/normalize documented in the onboarding flow; (c) a measured wall-clock
target versus the 2026-08-29 live-run baseline (107 events → 22 filed / 85
held, serial single-session filing; store now 32 people / 145 interactions /
160 inbox events); plus the chunk-26 LOW perf advisories assigned here.

## Decisions (made here, binding on all units)

**D1 — Shard pre-pass: deterministic connected components over participant
hints; new script `packages/ingestion/scripts/shard-filing-batch.sh`.**
bash 3.2 + jq, no model. Args: `<store-dir> [--data-dir <dir>] [--max-shards
<n>] [--out-dir <dir>]`. Behavior:

1. **Eligible set** = inbox events (never `inbox/quarantine/`) whose id is in
   neither `debrief-filed.log` nor `triage-held.log` — the exact batch-mode
   selection (debrief SKILL.md §1 lines 66–77).
2. **Hint → key prediction** per event, from `participant_hints`:
   email hint → case-insensitive contact-details lookup in `index.json`
   (the same deterministic store lookup triage's `sender_known` uses) →
   person slug(s); name hint → index name/aka match → slug(s); unresolved
   hint (no index match) → synthetic key `new:<normalized-hint>`
   (lowercase, trimmed; email form preferred when the hint contains one).
3. **Ambiguity is merged, never guessed.** A hint matching multiple people
   contributes ALL matched slugs as keys — those people's components merge
   into one shard (conservative: whichever person the model later picks,
   the write stays in-shard).
4. **Connected components**: events sharing any key land in the same
   component (union-find in awk; deterministic, byte-stable output on the
   same input).
5. **Zero-hint events are excluded from the wave** — emitted to
   `<out-dir>/leftover.ids` for a serial post-wave pass (a hint-less event
   could touch any person; no key set can bound it).
6. **Clamp + packing**: components > max-shards → deterministic bin-packing
   (components sorted by event count desc, round-robin into shards).
   `--max-shards` default **8**, hard cap **12** (mutating-worker cap is 15;
   headroom stays reserved for the orchestrator's other workers).
7. **Artifacts**: `<out-dir>/shard-<k>.ids` (one capture-id per line,
   oldest-first by `captured_at`, ties by filename — batch mode's order),
   `<out-dir>/leftover.ids`, and a mandatory summary line
   `shard: eligible=<n> components=<c> shards=<s> leftover=<z>` — every
   terminal state emitted, silence impossible. Read-only against the store;
   writes nothing outside `--out-dir`.

**D2 — Debrief shard mode (batch-subset invocation).** SKILL.md §1 gains a
third mode: given a shard file path and shard index `k`, process ONLY the
listed ids, oldest-first, per-event flow unchanged, with two deviations:

- **§5c deferred**: steps 1–2 (`build-index.sh` + `validate-store.sh`) are
  skipped per event in shard mode; the wave orchestrator runs both exactly
  once after all workers finish. Rationale: within a shard, people who
  co-occur are in the same worker session (the session remembers people it
  just created — index staleness is harmless); across shards, person sets
  are disjoint by D1 construction.
- **Per-shard ledger**: step 3 appends to
  `data/ingestion/debrief-filed.shard-<k>.log` instead of the main log.
  Chosen over interleaved appends to one file: `debrief-filed.log` is
  order-insensitive (all readers do membership checks), so an end-of-wave
  merge is semantically identical, is auditable per worker, and removes any
  doubt about N model sessions appending to one file. The orchestrator
  merges (`cat` shard logs >> `debrief-filed.log`, then removes them)
  **before** the index rebuild — and before any re-run, even after a failed
  worker, so a crash never causes re-filing.
- **Person-write confinement (single-writer guarantee)**: in shard mode a
  worker may create or update person files ONLY for participants of its
  assigned events — by D1 construction all such people are in-shard. If
  filing an event would require writing any other person file (e.g. a
  body-mentioned third party), the worker SKIPS that event — no writes, no
  ledger line, report it — and it joins the serial leftover pass. Residual
  risk (two shards inventing the same new person under differently-spelled
  hints) is accepted: D1 normalization + ambiguity-merge minimize it, and
  the post-wave `validate-store.sh` + orchestrator slug review catch it.

Single-event and plain batch modes are byte-unchanged apart from the mode
listing; §5c's per-event rebuild stays the rule outside shard mode.

**D3 — Wave protocol owned by a new ingestion spec
`packages/ingestion/specs/parallel-filing.md`.** The wave is orchestration
doctrine (model workers), not a wrapper script. Protocol: run
`triage-inbox.sh` → run `shard-filing-batch.sh` → spawn ≤ max-shards debrief
shard-mode workers in ONE parallel message (mutating-tier rules apply) →
collect completion reports → merge per-shard ledgers into
`debrief-filed.log` → `build-index.sh` once → `validate-store.sh` once →
serial leftover pass (leftover.ids + worker-skipped events) in one normal
batch-ish session → done. Failure handling: a failed shard's filed events
are still merged from its shard ledger; its unfiled ids simply remain
eligible (unfiled ∧ unheld = pending, per import-pipeline.md). Max 2 fix
rounds, per doctrine.

**D4 — Chunk-26 LOW perf advisories fixed here.**
(a) `triage-inbox.sh` per-event ledger membership (grep per event per log,
lines ~241ff) → **one-pass partition at startup**: emit all candidate ids
once, build a sorted skip file from both ledgers (`cut`/`sort -u` once),
compute the eligible set with a single `grep -vxF -f` (bash-3.2-safe, no
associative arrays); already-filed/already-held counts come from the same
partition, not per-event greps.
(b) `sender_known()` (lines 149–175: per-hint greps over `index.json` plus
`grep -R` over `people/`) → snapshot `index.json` + `people/*.md` into ONE
temp haystack file at startup; `sender_known` greps only that file.
Riders (in-scope, trivial): `coverage_floor_get` in beeper `lib.sh` (lines
166–176) delegates to `cursor_get "$1" "${2:-$COVERAGE_FLOOR_FILE}"`
(identical awk-first-match semantics, doc comment kept);
`extract-email-body.sh` guards duplicate message ids by wrapping
`$JQ_MSG_SELECT` uses in `first(...)` (lines 46, 57). The
frontmatter-helper dedup advisory is **declined** — it grows the chunk
(recorded again as future work).

**D5 — Lanes run concurrently during onboarding backfill; doc-only.** The
backfill sequence lives in `packages/ingestion/skills/onboarding-seed/
SKILL.md` Step 1 (lines 70–94), which currently implies serial lanes ("Let
each complete … before moving to Step 2"). Amend to: `beeper-sweep.sh
--backfill` is launched as a background process (output to a log file,
deadman check before Step 2) **concurrently** with the session-driven
gmail/calendar backfill sweeps; gmail and calendar remain serial *with each
other* (both are first-party-MCP session-driven skills in the one user
session — that constraint is unchanged from plan 26). Shared-file hazard
analysis stated in the doc after verification: lanes write disjoint
checkpoint/ledger dirs (`data/connectors/<lane>-in/`), inbox is append-only
with per-lane-unique capture ids, `archive/raw/` is one file per capture-id
— no shared write target; Step 2 (filing) still starts only after all three
lanes report. No new machinery.

**D6 — Wall-clock target and measurement method.** The live baseline was
not instrumented, so the measurement is a controlled benchmark, and the
"onboarding-shaped rerun" is a synthetic proxy (re-filing the real 107
events would duplicate real model spend and store writes):

- **Bench corpus** (synthetic only, no real PII):
  `packages/ingestion/tests/fixtures/filing-bench/` — 24 capture events
  shaped like the live mix (email / calendar-event / chat-message incl. one
  multi-day chat that episode-splits), whose hints form **≥6 person-disjoint
  components**, plus a committed expected-shards golden.
- **Method**: file the corpus into a scratch store twice — serial (plain
  batch mode, one session) vs a 4-shard wave per D3 — wall-clock via
  `date +%s` around each; identical event content both runs.
- **Targets (binding)**: sharded wave ≤ **0.6×** serial wall-clock at 4
  shards; **zero** cross-worker person-file conflicts (no person file
  written by two workers — checked from worker reports + git status of the
  scratch store); post-D4 `triage-inbox.sh` over the 160-event live corpus
  (dry-run, private, local only) ≤ **0.5×** its pre-fix wall-clock (U1
  records the before number first); `shard-filing-batch.sh` over the live
  corpus completes in seconds, not minutes (recorded, not gated).
- **Onboarding projection**: close-out records the extrapolated fresh-
  onboarding filing estimate at 8 shards from the bench ratio, labeled a
  projection against the 2026-08-29 baseline.

## Work units

### Phase 1 — perf fixes, spec, docs, bench fixtures (one parallel message:
warm ingestion worker A = U1→U3; connectors worker = U2; ingestion worker B
= U4→U5 on disjoint files)

**U1 [worker A, ingestion]. Triage perf fix.** Depends-On: — |
Parallel-safe with U2, U4, U5.
Files: `packages/ingestion/scripts/triage-inbox.sh`.
Implement D4(a)+(b) exactly (the diagnosis is in this plan — do not
re-diagnose). Behavior-preserving refactor: summary-line format, ledger
line format, rule order/patterns, and dry-run semantics byte-identical.
Before editing, record the pre-fix wall-clock of a dry-run over the live
corpus (`time bash … data/store --dry-run`, local only, nothing committed);
record the post-fix number the same way — both go in the completion report
(D6 needs them). Existing `run-triage-tests.sh` (20 green) is the test
suite for this unit — behavior-preserving means it must pass unmodified;
no new tests.
Brief carries: D4(a)+(b) verbatim; triage-inbox.sh lines 84–85, 141–175,
206, 241 (the ledger paths, `sender_known` body, and the per-event filed
check being replaced).
Acceptance: `run-triage-tests.sh` green under bash 3.2 with zero test-file
edits; dry-run output over the triage fixtures byte-identical to pre-fix;
pre/post live-corpus timings reported showing ≤0.5×.

**U2 [worker, connectors]. Advisory riders.** Depends-On: — |
Parallel-safe with U1, U4, U5.
Files: `packages/connectors/beeper-in/scripts/lib.sh`,
`packages/connectors/gmail-in/scripts/extract-email-body.sh`,
`packages/connectors/tests/run-capture-tests.sh` (one test),
`packages/connectors/tests/run-beeper-capture-tests.sh` (only if a test
breaks — none expected).
Implement D4's two riders: `coverage_floor_get` delegates to `cursor_get`
(keep its doc comment and return semantics — prints cursor + exit 0 when
found, exit 1 silent otherwise); `extract-email-body.sh` wraps its
`$JQ_MSG_SELECT` uses in `first(...)` so a duplicate message id yields the
first match, not concatenated output. Add ONE capture-suite test: fixture
thread JSON with a duplicated message id → single clean body, exit 0
(trivial test, rides with impl per doctrine).
Brief carries: D4 rider text; lib.sh lines 158–182 (`coverage_floor_get` +
the `cursor_get` contract comment at 117–124); extract-email-body.sh lines
46 and 57 with surrounding context.
Acceptance: `run-capture-tests.sh` (116+1) and
`run-beeper-capture-tests.sh` (109) green under bash 3.2; sabotaging the
`first()` guard fails the new test.

**U3 [worker A, ingestion — warm, after U1]. Parallel-filing spec.**
Depends-On: U1 (same worker; no file dependency).
Files: `packages/ingestion/specs/parallel-filing.md` (new).
Transcribe D1 (shard semantics: eligibility, hint→key prediction incl. the
`sender_known`-style index lookup, ambiguity-merge, zero-hint exclusion,
clamp/packing, artifacts, summary line), D2 (shard mode deviations:
deferred §5c, per-shard ledger + merge-before-rebuild + merge-even-on-
failure, person-write confinement + skip-to-leftover, residual-risk note),
and D3 (the wave protocol steps, failure handling, max-shards ≤12 with the
concurrency-cap rationale) — verbatim, capsule-sized, in the style of
`import-triage.md`. State explicitly: the pre-pass is deterministic
(byte-stable), read-only on the store, and the single-writer rule holds —
index.json is rebuilt by exactly one actor (the orchestrator), person files
by exactly one shard worker each.
Brief carries: D1–D3 verbatim; import-pipeline.md's five-stage table (lines
21–27) for stage-name consistency.
Acceptance: spec exists containing all D1 artifacts/formats exactly
(shard-<k>.ids, leftover.ids, summary line, shard ledger name), the
confinement rule, and the wave protocol; no other file touched.

**U4 [worker B, ingestion]. Onboarding lane concurrency doc.**
Depends-On: — | Parallel-safe with U1–U3 (disjoint files).
Files: `packages/ingestion/skills/onboarding-seed/SKILL.md` (Step 1 only).
Implement D5: verify the hazard claims first (grep the three lanes'
scripts/skills for their checkpoint/ledger write paths — expect disjoint
`data/connectors/<lane>-in/` dirs, per-lane-unique inbox ids, per-capture-id
archive files), then amend Step 1 to state beeper backfill runs in
background concurrently with the session-driven gmail→calendar sweeps
(serial with each other — first-party MCP session constraint, unchanged),
name the verified non-hazards in one short paragraph, and require a beeper
completion check (log tail + exit status) before Step 2. No other section
touched; the never-scheduled/one-shot framing stays intact.
Brief carries: D5 verbatim; onboarding-seed SKILL.md lines 70–94 (the text
being amended).
Acceptance: Step 1 states concurrency + the hazard paragraph with the
verified paths cited; diff confined to Step 1; per-lane failure-isolation
sentence preserved.

**U5 [worker B, ingestion — warm, after U4]. Bench fixture corpus.**
Depends-On: U4 (same worker; no file dependency).
Files: `packages/ingestion/tests/fixtures/filing-bench/` (new — 24
synthetic capture-event 1.2.0 files + `expected-shards.tsv` golden +
`README.md` stating the D6 measurement protocol verbatim).
Corpus shape per D6: mixed types, ≥6 person-disjoint hint components, one
ambiguous-hint pair (name matching two synthetic people), two events
sharing a new-person hint, one zero-hint event (→ leftover), one multi-day
chat body that episode-splits. **Synthetic PII only.** Events must be valid
per capture-event 1.2.0 (frontmatter fields, per-type body shapes — mirror
the triage-fixture style).
Brief carries: D6 verbatim; one existing triage fixture per type as the
shape exemplar (paste one email + one calendar + one chat-message fixture);
the capture-event 1.2.0 frontmatter field list.
Acceptance: every fixture passes the same frontmatter checks the triage
fixtures do; `expected-shards.tsv` partitions all 24 ids with the
zero-hint event in leftover and the ambiguous pair merged; README states
the serial-vs-4-shard method and the 0.6× target.

### Phase 2 — sharding machinery (worker A warm: U6→U8; worker B warm:
U7 after U6, U9 after U8)

**U6 [worker A, ingestion — warm]. Shard pre-pass script.** Depends-On:
U3, U5.
Files: `packages/ingestion/scripts/shard-filing-batch.sh` (new).
Implement D1 exactly as specced in U3's `parallel-filing.md`. bash 3.2 +
jq; union-find/components in awk; deterministic byte-stable output; store
read-only; writes only `--out-dir`. Eligibility uses the D4(a) one-pass
partition style (single `grep -vxF -f` over a sorted skip file), not
per-event greps. Must emit the summary line on every run including
eligible=0.
Brief carries: D1 verbatim; U3's finished artifact-format section; the
hint-extraction jq shape from one U5 fixture; triage-inbox.sh's `--data-dir`
resolution convention (lines 84–85).
Acceptance: running against the U5 bench corpus (with empty ledgers)
reproduces `expected-shards.tsv` exactly; second run byte-identical;
seeding a bench id into a ledger removes it from the shards and adjusts the
summary counts.

**U7 [worker B, ingestion]. Shard pre-pass tests.** Depends-On: U6 |
Parallel-safe with U8.
Files: `packages/ingestion/tests/run-shard-tests.sh` (new, style of
`run-triage-tests.sh`; reuses the U5 bench fixtures — add small dedicated
fixtures only where the bench corpus can't express a case).
Tests: golden partition match (byte-compare vs `expected-shards.tsv`);
determinism (two runs byte-identical); eligibility respects BOTH ledgers;
ambiguity-merge (the two candidate people's events co-shard); shared
new-person hint co-shards; zero-hint → leftover.ids, never a shard; clamp
(`--max-shards 2` bin-packs all components into 2 shards, deterministic);
summary line exact on empty-eligible input; store tree untouched
(tree-diff clean outside `--out-dir`).
Brief carries: D1 verbatim; U6's summary-line format and artifact names;
the run-triage-tests.sh harness skeleton (its setup/assert helpers).
Acceptance: suite green under bash 3.2; each property has a distinct
failing mode under momentary sabotage (then reverted).

**U8 [worker A, ingestion — warm]. Debrief shard mode + manifest.**
Depends-On: U3 | Parallel-safe with U7.
Files: `packages/ingestion/skills/debrief/SKILL.md`,
`packages/ingestion/package.md`.
SKILL.md edits per D2, confined to §1 and §5c: §1 adds the shard-mode
subsection (inputs: shard file path + shard index; selection = listed ids
only, oldest-first; person-write confinement rule + skip-to-leftover
verbatim; pointer to `specs/parallel-filing.md` for the wave protocol);
§5c adds the shard-mode deviation paragraph (steps 1–2 skipped, step 3 →
`debrief-filed.shard-<k>.log`; orchestrator merges then rebuilds/validates
once — cite the spec). The existing "steps 1–2 run once per event" sentence
gains "outside shard mode". package.md: provides rows
(`scripts/shard-filing-batch.sh`, `specs/parallel-filing.md`, the
shard-ledger convention), plan-27 note. No other SKILL.md section touched.
Brief carries: D2 verbatim; SKILL.md §1 (lines 47–82) and §5c (lines
363–378) verbatim; current package.md Provides section.
Acceptance: shard-mode selection + confinement + deferred-§5c text present;
single-event and batch mode text byte-identical apart from the mode list;
package.md rows added.

**U9 [worker B, ingestion]. Shard-mode eval case.** Depends-On: U7, U8.
Files: new T3 case under `packages/ingestion/evals/cases/` +
`packages/ingestion/evals/suite.txt` registration.
The pre-pass is deterministic → bash-tested (U7), not eval'd; the
model-facing behavior gets the eval (plan-24 doctrine: operative-procedure
prompt, fact-based grader, eval-case 1.2.0 — follow the plan-26 U11
`triage-held-respected` case as the pattern). Fixture store + inbox of 4
eligible events; shard file lists 2 of them (sharing one person); run the
debrief skill in shard mode. Expected (fact-based checks): exactly the 2
listed ids filed; `debrief-filed.shard-1.log` contains exactly those ids;
main `debrief-filed.log` unchanged; `index.json` byte-unchanged (no rebuild
ran); the 2 unlisted events untouched.
Brief carries: D2 verbatim; U8's finished §1 shard-mode text (embed in the
grader prompt verbatim); the plan-26 U11 case files as the exemplar.
Acceptance: `bash packages/core/scripts/eval-suite.sh
packages/ingestion/evals/suite.txt` runs it green; doctoring the case to
rebuild the index or file an unlisted id flips it to FAIL.

### Phase 3 — verification (orchestrator-led)

**U10. Full suites.** Depends-On: U1, U2, U7, U9.
All green: store 10, capture 117, beeper 109, scheduler 64, seed 23,
triage 20 (unmodified), shard (new), filing goldens `check-golden.sh --all
packages/ingestion/tests/goldens/debrief <worked-root>` (untouched-green —
no filing-logic change outside shard mode), full ingestion eval suite
(20/20 incl. U9; `RA_EVAL_RERUN_FAILED` available for flake repair);
`validate-store.sh` + `check-sync.sh` clean on the live store (read-only
sanity — nothing in this chunk wrote to it).

**U11. Benchmark + close-out.** Depends-On: U6, U8, U10.
1. **Serial baseline**: copy a minimal scratch store; file the U5 bench
   corpus in plain batch mode, one session; record wall-clock.
2. **Sharded wave**: fresh scratch store; run the full D3 protocol at
   `--max-shards 4` (pre-pass → 4 shard workers in one parallel message →
   ledger merge → single build-index + validate → leftover serial pass);
   record wall-clock.
3. **Assert D6 targets**: wave ≤0.6× serial; zero cross-worker person-file
   conflicts (worker FILES TOUCHED lists pairwise-disjoint on
   people/ + interactions/; scratch-store validate clean); every bench
   event filed-or-leftover-filed, none lost.
4. **Live sanity (private, local, read-only)**: `shard-filing-batch.sh`
   over `data/store` with the real ledgers → summary + component structure
   recorded; U1's triage pre/post timings confirmed ≤0.5×.
5. Record the 8-shard onboarding projection (D6); ROADMAP row 27 → Done;
   memory note; this plan's Status → Done with evidence. Max 2 fix rounds;
   retry briefs carry diffs + failure output.

## Proof of done (maps to ROADMAP §27)

1. A sharded filing wave files a mixed batch with **zero cross-worker
   person-file conflicts** — guaranteed by construction (D1/D2, spec'd in
   U3, tested in U7, contract-hooked in U8) and demonstrated live in U11.3.
2. An onboarding-shaped rerun (the U5 bench corpus, per D6's defined
   method) **beats the plan's wall-clock target** (≤0.6× serial at 4
   shards) — U11.2–3, with the fresh-onboarding projection recorded.
3. Lane fetch/normalize concurrency stated with verified hazard analysis in
   the onboarding flow (U4).
4. Chunk-26 LOW perf advisories fixed with timing evidence (U1, U2, U11.4).
5. All suites green, eval 20/20 (U10).

## Explicitly out of scope (adjacent chunks — do not pull in)

- **Sync timing / scheduler (chunk 28):** no sync-lanes.md change, no
  scheduler wiring of triage/sharding; the wave is invoked manually or by
  the onboarding flow.
- **Fleet (chunk 29):** no new lanes, no roster work.
- **Judgment quality / tier calibration (chunk 30):** no filing-heuristic
  changes — shard mode changes *which events a session sees and when the
  index rebuilds*, never how an event is judged; no triage pattern-content
  change (D4 is mechanics-only, byte-identical behavior).
- **Frontmatter-helper dedup** across ingestion/core scripts — declined
  rider (D4), stays future work.
- **Gmail/calendar multi-session parallelism:** both remain session-driven
  first-party-MCP skills in one user session (D5); only beeper runs
  concurrently in background.
- **Retroactive re-filing of the live store** — the baseline store is not
  rewritten; measurement is the D6 synthetic proxy.

Status: Ready

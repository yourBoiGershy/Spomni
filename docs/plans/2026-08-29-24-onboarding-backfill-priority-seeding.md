# Plan 24: Onboarding deep backfill & priority seeding

Status: Done (2026-08-29) — U1–U13 + U15 landed; U14.1 verified (store 10/0,
capture 109/0, beeper 88/0, scheduler 64/0 untouched, seed 23/0; goldens +
filing path byte-untouched vs main; confirm-first eval PASS live + doctored
FAIL; smoke eval 1/1 via wave-parallel runner; pre-merge checker: zero
findings). Residual: U14.2–.4 (live fresh-store onboarding run + window
override + incremental-state diff on real data) awaits a user session, since
the gmail/calendar backfill sweeps are driven by the first-party connectors.
Known pre-existing: 11 legacy ingestion eval cases fail live (chunk-21 T3
runner re-baseline debt; not touched by this plan).
Package: connectors (backfill modes on gmail-in / calendar-in / beeper-in +
shared window helper) + core (new onboarding-backfill config contract) +
ingestion (spec amendment, participation derivation, tier-suggestion scoring,
onboarding skill, seed tests, confirmation eval)
Depends-on: 15 (preference provenance), 17 (direct lanes; its Out-of-scope
deferral of backfill is closed by this plan), 20 (GO + example classes), 21
(T3 eval pattern)
Branch: chunk-24-onboarding-backfill (ingestion worktree)

## Objective

Port backfill mode to the three direct lanes (date-range window, isolated
checkpoint namespace, default **6 months back, user-configurable** via a new
core config contract), and extend the onboarding tier-suggestion mapping in
`packages/ingestion/specs/onboarding-tiering-seed.md` beyond frequency to
**participation signals** — user replied/initiated (strong boost),
co-attendance (boost), captured-but-never-answered (very low),
non-participating group chats (low) — with a per-suggestion score breakdown
naming each signal. Every tier write stays user-confirmed (eval-guarded);
derived signals only ever populate suggestions, never writes — stated always
outranks derived (plan 15 preference provenance).

## Decisions (made here, binding on all units)

**D1 — Participation signals are derived at seed time from raw capture
events (option A); no interaction-contract change.** The onboarding seed pass
reads the in-window filed interactions' `source-capture` links back to the
preserved raw events (inbox/ + `archive/raw/<capture-id>.json`) and derives
per-person participation classes as ephemeral suggestion inputs. Rationale:
the roadmap deliverable needs signals only at suggestion time; this matches
"derived never written" (plan 15), and avoids an interaction.md version bump,
filing-skill changes, a collateral sweep, and goldens re-baseline. Option B
(a filed `direction`/participation frontmatter field, which would also feed
tier-drift) is recorded as **future work**, out of scope here. Facts backing
A: `stats.json` (derived-index.md) already carries per-slug `interactions[]
{id, date, calendar, others}` so **co-attendance is derivable today**;
who-sent lives only in raw preserved bodies (gmail From/To headers, beeper
sender fields, calendar organizer/attendee JSON); interaction.md 1.x
frontmatter carries `source-capture`, giving a deterministic join with no
re-matching of participants.

**D2 — New core contract `packages/core/contracts/onboarding-backfill.md`
(1.0.0).** Existing candidates were checked and rejected: profile.md (1.0.0)
is stated-preference sections only; sync-lanes.md is lane scheduling. Shape
(exact, U1 transcribes this):
- File: `<data-dir>/config/onboarding-backfill.tsv`. Rows
  `key<TAB>value`, `#` comments and blank lines ignored.
- Keys: `window_months` — integer ≥ 1, **default 6 when the file or key is
  absent**; `self` — repeatable, one of the user's own identities (email
  address or messaging handle, verbatim as providers render it), used only
  by seed-time participation derivation.
- Fail-closed parsing (same posture as sync-lanes.md 1.0.0): unknown key,
  malformed row, or non-integer/`< 1` `window_months` → error exit, no
  guessing, no partial reads. Missing file is valid (defaults apply);
  participation derivation additionally fails closed with a clear message if
  it runs with zero `self` entries.
- Writer: the user (or an onboarding session acting on the user's explicit
  instruction). Readers: connectors backfill modes (window), ingestion seed
  scripts (window + self). Config, not store data — lives under the data
  dir, never in this repo.

**D3 — Scoring model (deterministic; U2 transcribes this into the spec
verbatim).** The insufficient-data gate (`touchpoints < 2` → excluded), the
20-person cap, one-session no-backlog rule, untiered-is-valid end state, and
no-guilt framing all stay intact. For each gate-clearing person, over the
backfilled window:
- **Base band** from `median_gap_days`, unchanged, tier-drift.md's yardstick
  (ties fall warmer): `<= 21` inner-circle (3 pts), `<= 45` close (2),
  `<= 90` active (1), `> 90` dormant (0).
- **Signals** (from D1's derivation):
  - `user-engaged` (+2, strong boost): ≥ 1 linked raw event in-window
    authored by a `self` identity with this person a participant.
  - `co-attended` (+1, boost): ≥ 1 `stats.json` interaction with
    `calendar: true` in-window.
  - `silent-group` (class LOW, score forced to 0): no `user-engaged`, no
    `co-attended`, and ≥ 1 linked raw event is a group event (≥ 3
    participant hints).
  - `never-answered` (class VERY-LOW, score forced to −1): no
    `user-engaged`, no `co-attended`, no linked group event — i.e. all
    touchpoints are direct inbound the user never answered.
  Boosts are cumulative; the two penalty classes apply only when both boosts
  are absent and are mutually exclusive by the group test.
- **Final score** = clamp(base + boosts, −1, 3); penalties set the score
  directly. Tier: 3 → inner-circle, 2 → close, 1 → active, ≤ 0 → dormant.
- **Ordering** (replaces frequency-only ordering): score desc, then
  `median_gap_days` asc, then `touchpoints` desc, then slug asc. Cap 20
  unchanged.
- **Breakdown string** (every suggestion carries one, naming its signals):
  `suggested: <tier> | base: <band> (median_gap_days=<n>) | signals: <comma
  list with deltas, e.g. user-engaged(+2), co-attended(+1)>` — penalty
  classes render as `class: never-answered (very low)` / `class:
  silent-group (low)`; no signals → `signals: none`.
- Chunk-20 example classes under this model: unanswered pitch (≥ 2 cold
  emails, no reply) → VERY-LOW, dormant, ranked last; non-participating
  group (frequent group chat, user silent) → LOW, dormant, ranked above
  very-low; active thread (user replies, base active) → 1+2 = 3,
  inner-circle. U12 fixes these as fixtures.

**D4 — Backfill does NOT touch sync-lanes.** It is a one-shot onboarding
act, invoked directly (skill run / script flag), never a `lanes.tsv` row.
sync-lanes.md 1.0.0 is unchanged; run-scheduler-tests.sh must stay green
untouched.

**D5 — Isolated backfill namespace, per the already-regression-tested
pattern** (packages/connectors/tests/run-capture-tests.sh:330–408, currently
unwired): backfill state lives in sibling files (`backfill-checkpoint`,
`backfill-processed.log`, `backfill-cursors.tsv`) beside the incremental
ones; backfill **reads both ledgers for dedup, writes only its own**, and
never modifies incremental checkpoint/cursor/ledger files. Backfill archives
raw per the plan-17 wrapper rule, same as incremental.

## Work units

### Phase 1 — contract + spec (one parallel message, 2 workers)

**U1 [worker, core]. Onboarding-backfill config contract.** Depends-On: —
Create `packages/core/contracts/onboarding-backfill.md` at 1.0.0,
transcribing D2 exactly (file path, TSV row form, both keys with defaults
and constraints, fail-closed rules, writer/readers, config-not-store note).
Model tone/length on `packages/core/contracts/sync-lanes.md` — capsule-sized,
one read is full orientation. Add a provides row to
`packages/core/package.md` (`onboarding-backfill@1.0.0`, built by plan 24).
Acceptance: contract file exists with every D2 element; package.md row
present; no other core file touched.

**U2 [worker, ingestion]. Spec amendment.** Depends-On: —
Amend `packages/ingestion/specs/onboarding-tiering-seed.md` (one file):
1. Delete the plan-17 backfill-deferral note and all "plan 11 unit 12" /
   composio-era backfill citations; the Sequence's step 1 now cites the three
   direct lanes' backfill modes (gmail-in, calendar-in, beeper-in) and this
   plan.
2. Window: replace "default 12 months per plan 11 unit 12" with **default 6
   months, user-configurable via `packages/core/contracts/
   onboarding-backfill.md` (`window_months`)**.
3. Replace the frequency-only band mapping + ordering with D3 verbatim
   (base band table stays as-is inside it; add signals, precedence, score,
   ordering, breakdown format, and a note that signal derivation is
   seed-time raw-event analysis per D1 — derived, never written, stated
   outranks derived per plan 15).
4. Extend "Deterministic fixture-checkability" so a checker hand-verifies,
   with no judgment calls: gate, each person's signals from fixture raw
   events, exact score and tier, exact order incl. penalty classes, cap,
   and breakdown strings.
Keep intact and untouched in meaning: insufficient-data gate, 20-cap,
one-session/no-backlog, untiered-is-valid, no-guilt framing (binding),
confirmed writes via stated-preference-filing.md (a).2 / (a).4.
Acceptance: no composio/plan-11-unit-12/deferral text remains; D3 table and
breakdown format present verbatim; the preserved sections byte-identical in
intent (gate/cap/no-guilt wording unweakened).

### Phase 2 — implementation (one parallel message: 4 connectors workers on
disjoint dirs + 1 warm ingestion worker running U7→U8→U9 serially)

**U3 [worker, connectors/scripts]. Window helper.** Depends-On: U1
`packages/connectors/scripts/resolve-backfill-window.sh` (bash 3.2, no
deps beyond POSIX + date): arg = data dir; parses
`<data-dir>/config/onboarding-backfill.tsv` per D2 (paste of D2 rules is in
this plan — do not redesign); prints `window_start_iso<TAB>window_months` on
stdout; missing file/key → default 6; any malformed input → non-zero exit +
one-line reason on stderr (fail closed, no output). No filing/ranking logic
(connectors stay dumb).
Acceptance: script runs under bash 3.2; default, override, and three
malformed cases behave per D2 when run by hand.

**U4 [worker, connectors/gmail-in]. Gmail backfill mode.** Depends-On: U3
`packages/connectors/gmail-in/skills/gmail-sweep/SKILL.md`: add a backfill
mode section — invoked explicitly ("run gmail-sweep in backfill mode"),
window from `resolve-backfill-window.sh`; query the full window with
`after:<window-start>`/`before:<now>` in `search_threads` (date-range
querying confirmed available); state per D5: checkpoint namespace
`data/connectors/gmail/backfill-checkpoint` + `backfill-processed.log`,
dedup read-only against BOTH `processed.log` and `backfill-processed.log`,
never write the incremental files; page budget, append-after-success,
quarantine-continue, raw archive — all identical to incremental; checkpoint
advance rule identical (≥ 1 captured AND window drained). Backfill is
one-shot, never a sync-lanes row (D4). Companion `gmail-in/package.md`
note rides along (backfill mode, built by plan 24).
Acceptance: mode documented with both ledger names and the never-write rule
explicit; no incremental-path wording changed; no banned tools introduced.

**U5 [worker, connectors/calendar-in]. Calendar backfill mode.**
Depends-On: U3
`packages/connectors/calendar-in/skills/calendar-sweep/SKILL.md`: add a
backfill mode — parameterize the past-window bound to the resolved window
start (no future extension; upcoming stays incremental's job); calendar has
no checkpoint, so isolation per D5 = dedup keyed `<event-id>:<updated>` read
against BOTH `data/connectors/calendar/processed.log` and a new
`backfill-processed.log`, appending only to the backfill ledger; per-calendar
failure isolation (skipped-calendars.log) unchanged; raw archive unchanged.
Companion `calendar-in/package.md` note rides along.
Acceptance: mode documented; both-ledgers dedup + backfill-only append
explicit; incremental window text untouched.

**U6 [worker, connectors/beeper-in]. Beeper backfill flag.** Depends-On: U3
`packages/connectors/beeper-in/scripts/beeper-sweep.sh` (+ `lib.sh` if
needed; bash 3.2): add `--backfill` — resolves the window via
`resolve-backfill-window.sh`; per chat, paginates `lastActivity`
`direction=before` from the chat's existing incremental cursor (or now, if
none) **backward to the window start**, so backfill fetches only older than
existing coverage; state under an isolated `data/connectors/beeper-in/
backfill-cursors.tsv` (+ `backfill-last-sweep`), never touching
`cursors.tsv`/`last-sweep`; runs logged to the existing runs.log with a
`backfill` marker. One-shot, no sync-lanes change (D4). Companion
`beeper-in/package.md` note rides along.
Acceptance: `--backfill` runs against fixtures without touching
`cursors.tsv`/`last-sweep`; window bound honored; incremental invocation
byte-identical in behavior.

**U7 [warm ingestion worker]. Participation derivation script.**
Depends-On: U1, U2
`packages/ingestion/scripts/derive-participation.sh` (bash 3.2 + jq): args =
store dir, stats.json path, window start, config path. Fails closed with a
clear message if config has zero `self` entries (D2). For each slug's
in-window `interactions[]` (ids from stats.json): read
`interactions/<id>.md` frontmatter `source-capture`, then the preserved raw
(`archive/raw/<capture-id>.json`, falling back to the inbox event's
preserved body) and derive: authored-by-self (gmail From header vs `self`;
beeper sender/from-me field — confirm exact field names against
`packages/connectors/beeper-in/fixtures/`, the one extra file this unit may
open) and group-ness (≥ 3 participant hints on the capture event). Output
deterministic TSV sorted by slug: `slug<TAB>user_engaged<TAB>group_linked`
(0/1). Read-only against the store — writes nothing anywhere (D1: ephemeral
suggestion input).
Acceptance: runs under bash 3.2; deterministic output on fixture input;
zero writes (verifiable by diffing the store tree before/after).

**U8 [same warm ingestion worker]. Tier-suggestion scorer.** Depends-On: U7
`packages/ingestion/scripts/suggest-tiers.sh` (bash 3.2 + jq): args =
stats.json path, U7's TSV, window months. Applies D3 exactly — gate first;
co-attendance from stats.json `interactions[].calendar`; base band; boosts;
penalty classes with D3 precedence; clamp; ordering (score desc, gap asc,
touchpoints desc, slug asc); cap 20. Emits one line per presented person:
`slug<TAB>score<TAB>suggested_tier<TAB><breakdown string per D3>`. Writes
nothing; suggestions are stdout only.
Acceptance: D3's chunk-20 example classes produce very-low/low/boosted
respectively on a hand-made check; output deterministic (byte-stable across
runs on the same input).

**U9 [same warm ingestion worker]. Onboarding-seed skill.** Depends-On: U8
`packages/ingestion/skills/onboarding-seed/SKILL.md` — session-driven,
sequencing the amended spec end to end: (1) invoke the three lanes'
backfill modes (gmail/calendar as skill runs, beeper via `--backfill`); (2)
normal filing; (3) `build-stats.sh`; (4) `derive-participation.sh` +
`suggest-tiers.sh`; (5) present the batch once — breakdown shown per
person, no-guilt wording per the spec's binding framing (never
"neglecting", never flagging excluded people); (6) **only on explicit
per-person user confirmation**, file the tier via stated-preference-filing.md
(a).2 (existing person) / (a).4 (new person) — the skill must state
verbatim that no tier is ever written without confirmation and that
skips/cap-outs produce no follow-up, ever. Window override: tell the user
the active window (from config) and how to change it (edit
`onboarding-backfill.tsv` per the core contract) before running sweeps.
Add ingestion `package.md` rows (skill + two scripts, consumes
`onboarding-backfill@^1.0`, built by plan 24).
Acceptance: SKILL.md covers all six steps, names both confirmation write
paths, carries the no-guilt and confirm-first language; package.md updated.

### Phase 3 — tests + eval (one parallel message, 4 workers: 2 connectors
test files disjoint, warm ingestion worker U12→U13)

**U10 [worker, connectors/tests]. Capture-suite backfill wiring.**
Depends-On: U3, U4, U5
`packages/connectors/tests/run-capture-tests.sh`: the backfill-namespace
regression tests at lines 330–408 are the exemplar and are already green —
extend, same style: (a) `resolve-backfill-window.sh` tests — missing file →
6 months; `window_months 2` honored; malformed row / unknown key /
`window_months 0` → non-zero exit with stderr reason (silence never valid);
(b) calendar `backfill-processed.log` isolation — dedup hit in EITHER
ledger skips capture; backfill appends only to its own ledger; incremental
`processed.log` byte-identical after a backfill pass.
Acceptance: suite green locally (bash 3.2); new tests fail if either
never-write rule is broken (prove by momentary sabotage, then revert).

**U11 [worker, connectors/tests]. Beeper backfill tests.** Depends-On: U6
`packages/connectors/tests/run-beeper-capture-tests.sh`, same style: with
fixture chats, `--backfill` (i) creates `backfill-cursors.tsv` and leaves
`cursors.tsv` + `last-sweep` byte-identical; (ii) stops paginating at the
window start; (iii) fetches only older-than-cursor items (no duplicate
capture ids vs a prior incremental run); (iv) incremental run after a
backfill behaves as if backfill never happened.
Acceptance: suite green locally; each of the four properties has a distinct
failing mode when sabotaged.

**U12 [warm ingestion worker]. Seed mapping tests.** Depends-On: U7, U8
`packages/ingestion/tests/fixtures/onboarding-seed/` (synthetic PII only:
fixture stats.json, interaction stubs, raw-event stubs, config with `self`)
+ `packages/ingestion/tests/run-seed-tests.sh` (bash 3.2, same style as the
connectors suites): gate exclusion (`touchpoints < 2`); each base band incl.
warm-tie at exactly 21; `user-engaged` +2; `co-attended` +1; cumulative
clamp at 3; the three chunk-20 example classes with expected tiers AND
expected relative order (very-low last, low above it, boosted top); cap-20
cut line; exact breakdown strings; zero-`self` config → derivation fails
closed.
Acceptance: suite green; every D3 row exercised by at least one fixture
person; expected outputs stored as literal strings (byte-compare, no
judgment calls).

**U13 [same warm ingestion worker]. Confirmation eval guard.**
Depends-On: U9
T3-style eval case under `packages/ingestion/evals/` guarding **zero tier
writes without confirmation**: per packages/core's eval-case contract, and
following a chunk-21 T3 case under `packages/*/evals/` as the pattern (the
two files this unit opens). Scenario: fresh fixture store, suggestions
computed, user confirms one person, adjusts one, skips one, then ends the
session; expected: exactly the confirmed/adjusted slugs gain `tier` (the
user's chosen values), the skipped person and everyone unpresented have no
`tier` key; any tier appearing without a confirmation utterance = FAIL.
Register the case in `packages/ingestion/evals/suite.txt` (create if
absent, matching another package's suite.txt form).
Acceptance: `bash packages/core/scripts/eval-suite.sh
packages/ingestion/evals/suite.txt` runs the case; the case fails when the
fixture is doctored to pre-write a tier.

### Phase 4 — verification (orchestrator-led)

**U14. Full-suite + end-to-end proof.** Depends-On: U10–U13
1. All suites green: `bash packages/core/tests/run-store-tests.sh`,
   `bash packages/connectors/tests/run-capture-tests.sh`,
   `bash packages/connectors/tests/run-beeper-capture-tests.sh`,
   `bash packages/connectors/tests/run-scheduler-tests.sh` (must pass
   untouched, per D4), `bash packages/ingestion/tests/run-seed-tests.sh`,
   `bash packages/core/scripts/eval-suite.sh
   packages/ingestion/evals/suite.txt`, filing goldens `bash
   packages/ingestion/scripts/check-golden.sh --all
   packages/ingestion/tests/goldens/debrief <worked-root>` (must be
   untouched-green — D1 means no re-baseline).
2. Fresh-store onboarding run (live, in-session): write a config with
   `window_months 6` + real `self` entries; run onboarding-seed; then
   `bash packages/core/scripts/validate-store.sh <store>` and `bash
   packages/connectors/scripts/check-sync.sh <store>` — clean on the
   backfilled events, all three lanes represented.
3. Window override end to end: set `window_months 2`, verify each lane's
   backfill query/pagination bound moves accordingly (gmail `after:`,
   calendar past-bound, beeper stop condition) — evidence from run output.
4. Incremental state untouched post-backfill: diff
   `data/connectors/*/checkpoint|cursors.tsv|last-sweep|processed.log`
   before/after.
5. Update `docs/ROADMAP.md` (24 → Done), memory notes, this plan's Status →
   Done with evidence. Fix rounds per doctrine (max 2, retry briefs carry
   diffs + failure output).

### Scope addition (user-requested mid-chunk, 2026-08-29)

**U15 [worker, core]. Eval-suite wave-parallel dispatch + smoke selector.**
Depends-On: — (independent of U1–U14; rides in this PR by user request)
The eval suite had grown to 26 serial model-session cases; wall-clock was the
dispatch loop waiting on the API one case at a time. `eval-suite.sh` gains:
wave-parallel dispatch (`RA_EVAL_PARALLEL`, default 4; cost cap checked
between waves, overshoot ≤ one wave, `=1` reproduces serial semantics; safe
because both runners already mktemp isolated worked dirs), an inline
`# smoke` manifest tag + `RA_EVAL_SMOKE=1` subset selector for fast
iteration, and `RA_EVAL_RUNNER_AGENT`/`RA_EVAL_RUNNER_SKILL` test hooks.
eval-case.md's manifest section documents the tag. RESULT grammar, summary
format, and exit codes unchanged. Verified with dry-run over the real
manifests plus stub-runner tally/ordering/cost-cap/smoke proofs — no paid
eval runs. Deferred: tagging `# smoke` lines in query/attention suite.txt
files (their packages' territory — future chunks); a redundancy audit
demoting deterministic eval cases to plain bash tests.

## Proof of done (mirrors ROADMAP §24)

1. Fresh-store onboarding run backfills the configured window on all three
   lanes; capture suites green; check-sync clean on the backfilled events
   (U14.1–.2).
2. Tier suggestions carry a score breakdown naming their signals (D3
   breakdown string; U8, U12).
3. Chunk-20 example classes rank correctly: unanswered pitch = very low,
   non-participating group = low, active thread = boosted (U12 fixtures +
   U14.1).
4. Zero tier writes without confirmation — eval-guarded (U13).
5. Window override honored end to end (U14.3), default 6 months when unset
   (U10a).
6. Stated always outranks derived: signals populate suggestions only; the
   only write path is stated-preference-filing.md (a) on explicit
   confirmation (U2, U9, U13).

## Out of scope

- **Option B** (filed direction/participation frontmatter on
  interaction.md) — future work; would benefit tier-drift but costs a
  contract bump + filing changes + goldens re-baseline (D1).
- **Any attention-package change** — tier-drift.md is reused as a yardstick
  only, untouched this chunk.
- **Scheduling backfill** — never a sync-lanes row (D4); no launchd work.
- **Contacts seeding** — no contacts/People tool exists on the first-party
  Gmail connector surface (plan 17 U10 finding); people enter via filing
  only.
- **Re-running the onboarding pass** — permanently out of scope per the
  spec's no-backlog rule; unchanged here.
- **Gmail/calendar backfill as shell scripts** — they are session-driven
  skill modes by constraint; only beeper gets a script flag.

Status: Ready

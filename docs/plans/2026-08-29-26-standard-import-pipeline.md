# Plan 26: Standard import pipeline

Status: Done (2026-08-29 — see Close-out at end of file; one live residual: U12.3 gmail/calendar fetch-to-file live proof awaits a user-driven sweep session)
Package: core (stage contract) + connectors (gmail/calendar fetch-to-file
conformance, beeper backfill fixes, manifests) + ingestion (deterministic
triage tier, debrief hook, tests, eval)
Depends-on: 17 (direct lanes), 24 (backfill modes + eval harness state),
25 (episode-split; the live-corpus store this chunk calibrates against)
Branch: chunk-26-standard-import-pipeline

## Objective

Standardize import as one uniform stage pipeline every lane conforms to:
**fetch** (raw bytes → disk, dumb, no model) → **normalize** (shared
normalizer → capture-event 1.2.0 → `inbox/`) → **triage** (deterministic
rules) → **judgment** (model, only maybe-a-person events) → **file** (store
writes). Each arrow is a contract boundary with an on-disk artifact. The
contract is *extracted from working code* — the calendar fetch-to-file leg
(an oversized MCP result saved to disk and processed programmatically with
perfect byte fidelity, live 2026-08-29) is the reference implementation.
Motivation from the live onboarding run: ~95% of filing spend is model
judgment deciding something is junk, and gmail capture transits every body
through model context twice (MCP tool result + model transcription into the
archive).

## Decisions (made here, binding on all units)

**D1 — New core contract `packages/core/contracts/import-pipeline.md`
(1.0.0); connector-interface.md is NOT amended.** Read-and-rejected:
`connector-interface.md` 1.0.0 scopes itself to the connectors package's two
obligations (write valid capture events into `inbox/`; deliver rendered
content) and deliberately stops at the inbox boundary. The import pipeline
spans three packages (connectors own fetch+normalize; ingestion owns
triage+judgment+file) — cross-package stage doctrine belongs in its own core
contract, same as sync-lanes.md. connector-interface.md gains only a
one-line cross-reference ("input connectors implement the fetch and
normalize stages of import-pipeline.md") — an editorial note, no
schema_version bump (no shape change).

**D2 — The five stages (U1 transcribes this into the contract verbatim,
citing the working code each row is extracted from).**

| Stage | Owner | Does | May transit model context | On-disk artifact (the boundary) |
|---|---|---|---|---|
| fetch | connectors `*-in` | Pull raw bytes from the source (in-session first-party MCP tools for gmail/calendar; localhost HTTP for beeper). Dumb: no interpretation, no filtering beyond fetch scope. | Tool/call metadata only — ids, dates, counts, page tokens, file paths. **Never item bodies.** | Raw provider payload on disk: the harness-saved MCP tool-result file (gmail/calendar) or the HTTP response bytes (beeper); archived verbatim per item at `<store>/archive/raw/<capture-id>.json`. |
| normalize | connectors `*-in` | `packages/connectors/scripts/normalize-capture.sh` — envelope-only; body verbatim from the saved file; invalid → `inbox/quarantine/` + reason file. Programmatic (bash/jq) from the fetch artifact. | Nothing new — runs as shell, not model prose. | `inbox/<id>.md` per capture-event.md 1.2.0 (append-only, raw kept forever). |
| triage | ingestion | Deterministic rule pass (bash/jq, no model) over unfiled inbox events; marks junk `held-by-rule`. Reversible; never deletes or edits inbox files. | Nothing — pure shell. | `data/ingestion/triage-held.log` (D3). |
| judgment | ingestion | The debrief skill's model pass — only over events neither filed nor held. Ambiguity questions, person/no-person calls. | The maybe-a-person events only (the point of triage). | `data/ingestion/debrief-filed.log` appends; unfiled-and-unheld = still pending. |
| file | ingestion | Store writes: `people/`, `interactions/`, wake-ups via core `wakeup-add.sh`, then `build-index.sh` + `validate-store.sh` (debrief SKILL.md §5c). | Filed content (already judged relevant). | `people/`, `interactions/`, `index.json`, `wakeups/`. |

Contract also states: single-writer per artifact (connectors → inbox+archive;
ingestion → held/filed ledgers + store), lane conformance is declared in each
lane's `package.md`, and the fetch-stage hard rule — **raw item bodies are
never transcribed by the model**; everything after the fetch artifact is
programmatic.

**D3 — `held-by-rule` representation mirrors `debrief-filed.log`.** New
append-only ledger `data/ingestion/triage-held.log`, one line per held
event: `<capture-id>\t<rule-name>\t<held-at ISO 8601 Z>`. Sole writer:
`packages/ingestion/scripts/triage-inbox.sh`. Readers: the debrief skill
(batch mode additionally excludes ids present in `triage-held.log`) and
humans. Reversal: an **explicit single-event debrief invocation on a held id
overrides the hold** (files normally; its `debrief-filed.log` entry then
outranks the hold everywhere) — no ledger surgery, inbox untouched,
append-only preserved. Chosen over an inbox frontmatter marker (would edit
never-edited files) and over moving files (quarantine-style moves are for
malformed events only; held events are valid).

**D4 — Triage rules: precision-first, calibrated on the live corpus,
committed fixtures synthetic-only.** A false hold loses a person event; a
missed junk event only costs one model judgment — so every rule is tuned for
**zero false-holds** and doubt always falls through to judgment. Rule
classes (from the 2026-08-29 live corpus), each with its deterministic
signal; U2 fixes exact patterns after report-only runs against the private
corpus:

1. `noreply-marketing` — `type: email`, sender hint matches a fixed
   noreply/no-reply/donotreply/newsletter/marketing/notification-address
   pattern list. Must NOT hold voice-notes or linkedin-notification types.
2. `self-only-calendar` — `type: calendar-event`, body JSON has no
   `attendees[]` entry beyond the user (`self: true`) — i.e. zero other
   attendees. (Organizer-is-self with no guests counts as self-only.)
3. `otp-security` — `type: email`, subject matches verification-code / OTP /
   security-alert / new-sign-in pattern list.
4. `linkedin-invitation` — `type: linkedin-notification` (or `email` from a
   linkedin.com sender) whose subject matches invitation/wants-to-connect
   patterns. Other LinkedIn notifications fall through to judgment.
5. `cold-pitch` — `type: email`, single-message thread, sender matches no
   contact detail in `index.json`/`people/` (deterministic store lookup) AND
   subject/body matches the pitch pattern list. This is the weakest rule:
   patterns seeded from the live corpus; when in doubt it must not fire.

Non-participating group-chat noise (the sixth observed junk class) is
**judgment's territory, not triage's** — "user never participates" is a
cross-event property, not a per-event deterministic test; recorded as future
work (chunk 30). Committed goldens/fixtures are synthetic events *modeled
on* the junk classes — the chunk-24 live corpus lives in the private data
dir (`data/store/inbox`) and **no real PII ever enters `packages/`**.

**D5 — Fetch-to-file mechanism (canonizing the calendar accident).** The
live 2026-08-29 finding: an oversized calendar `list_events` MCP result was
spooled to disk by the harness (large tool results arrive as a saved file
path, not inline prose) and processed programmatically with perfect byte
fidelity. Canonized rule for gmail/calendar (session-driven, first-party
MCP only — unchanged): **request maximum page sizes** (gmail
`search_threads` `pageSize: 50`, `get_thread` with `messageFormat:
"PLAIN_TEXT"`; calendar `list_events` at the maximum `pageSize` the tool
accepts — verify the max in Step-0 style, don't guess) so results exceed the
inline threshold and land on disk; the session then handles **only the file
path** — archive via `cp`, classify/extract/normalize via jq + existing
scripts reading the file. Residual: a small final page may still arrive
inline; then the session writes the tool result to a temp file in **one
verbatim uninterpreted paste** (never summarizes, classifies, or excerpts
from context) and proceeds identically, counting it in the run summary as
`inline-spilled=<n>`. The contract states byte fidelity is guaranteed on the
disk path and best-effort on the inline residual.

**D6 — Beeper backfill bug, diagnosed (U5 fixes exactly this).** Mechanism
of the duplicate-subset events: an incremental first capture is a single
newest-page fetch (`fetch_new_messages` with no cursor, lib.sh:259–266)
which records the page's **newest** cursor to `cursors.tsv`; backfill then
paginates `direction=before` **from that incremental cursor**
(beeper-sweep.sh:249–255, lib.sh:320–331) — "before the newest cursor"
re-covers the very messages of that first newest page, so backfill re-emits
a subset of an already-captured event. Fix, two parts:

- **Coverage floor.** Incremental first-capture path records the fetched
  page's *oldest* cursor to a new incremental-owned sibling file
  `data/connectors/beeper-in/coverage-floor.tsv` (`chatID<TAB>oldestCursor`,
  written once per chat, never advanced). Backfill starts `direction=before`
  from the chat's floor cursor when present. Legacy chats (captured before
  this file existed): derive the floor by scanning the chat's existing
  capture events (`inbox/*.md` body JSON `chatID` match → oldest
  `messages[].timestamp`) and filter fetched items with `timestamp >=` that
  bound. No floor and no prior events → current behavior (newest page) is
  correct. D5-isolation unchanged: backfill still never writes any
  incremental file; `coverage-floor.tsv` is written by the incremental path
  only.
- **History clamp.** When pagination exhausts bridge history (`hasMore`
  false / no `oldestCursor`) before reaching the window start, the run must
  say so instead of implying window coverage: append
  `<chatID>=history-clamped@<oldest_ts>` to WARN, carried into the
  `runs.log` line — the window is clamped to actual bridge history (which
  only extends back to bridge connect), never over-promised.

## Work units

### Phase 1 — contract + spec (one parallel message, 2 workers)

**U1 [worker, core]. Import-pipeline contract.** Depends-On: — |
Parallel-safe with U2.
Files: `packages/core/contracts/import-pipeline.md` (new, 1.0.0),
`packages/core/package.md` (provides row), `packages/core/contracts/
connector-interface.md` (one cross-ref line, no bump — D1).
Transcribe D2's table and hard rules verbatim, including D5's
fetch-to-file mechanism and inline-residual rule and D3's ledger shape
(named as the triage-stage artifact; exact rule patterns live in ingestion's
spec, cross-referenced). Style/length: model on `sync-lanes.md` /
`connector-interface.md` — capsule-sized, `schema_version: 1.0.0`, writer/
readers per artifact.
Brief carries: D1–D5 text from this plan; the connector-interface.md Scope
paragraph (lines 5–12) as the boundary being cross-referenced.
Acceptance: contract file contains all five stage rows, the
never-transcribed rule, per-stage artifacts, and the conformance-declared-
in-package.md requirement; core/package.md row present (`import-pipeline.md
1.0.0, per plan 26`); no other core file touched.

**U2 [worker, ingestion]. Triage rules spec.** Depends-On: — |
Parallel-safe with U1.
Files: `packages/ingestion/specs/import-triage.md` (new).
Contents: D3 verbatim (ledger path/format/writer/readers/reversal); D4
verbatim (precision-first doctrine, the five rule classes with their
deterministic signals, exact regex/pattern lists per rule — author them
conservatively here, calibration against the live corpus happens in U12 and
may tighten them), the synthetic-fixtures-only rule stated explicitly, and
the group-noise deferral note. Include a "Deterministic checkability"
section: every rule must be verifiable by a checker from an event file alone
(plus `index.json` for cold-pitch), no judgment calls.
Brief carries: D3 + D4 text; the capture-event 1.2.0 frontmatter field
table (capture-event.md lines 30–38); debrief SKILL.md's ledger convention
excerpt (lines 47–67).
Acceptance: spec exists with all five rules' patterns written out, D3
ledger line format exact, precision-first + synthetic-only + reversal rules
present.

### Phase 2 — implementation (one parallel message: U3/U4/U5 on disjoint
connectors sub-dirs + one warm ingestion worker running U6→U7 serially)

**U3 [worker, connectors/gmail-in]. Gmail fetch-to-file conformance.**
Depends-On: U1 | Parallel-safe with U4, U5, U6.
Files: `packages/connectors/gmail-in/skills/gmail-sweep/SKILL.md`,
`packages/connectors/gmail-in/scripts/extract-email-body.sh` (new),
`packages/connectors/gmail-in/package.md` (conformance row),
`packages/connectors/package.md` (consumes `import-pipeline@^1` — rides
here).
Rework SKILL.md Step 2 per D5: `get_thread` called with `messageFormat:
"PLAIN_TEXT"` and max page sizes so the result lands on disk as a saved
tool-result file; then per message, programmatically from that file:
(2.4) archive = `cp <saved-result> <store>/archive/raw/<capture-id>.json`
(byte-for-byte); (2.5) classify via existing `classify.sh "<subject>"
"<sender>"` with both args extracted by jq from the file; (2.6) hints
extracted by jq from the file (`sender`, `toRecipients[]`, `ccRecipients[]`
— arrays absent-not-empty, per the live-verified note at SKILL.md lines
136–139, which stays intact); (2.7) body via the new
`extract-email-body.sh <saved-result-file> <message-id>` (bash 3.2 + jq:
prints `Subject: <subject>`, blank line, `plaintextBody` verbatim — exit
non-zero if the message id is absent); (2.10) `normalize-capture.sh ...
--file <body-file>`. Add D5's inline-residual rule and the
`inline-spilled=<n>` summary field verbatim. State the invariant in its own
paragraph: **no message body is ever read into or written from model
context** — applies identically to incremental and backfill modes (the
backfill section's "everything else identical" inheritance covers it; add
one sentence there naming it). Checkpoint/ledger/dedup/quarantine mechanics
unchanged; banned-tools list unchanged.
Brief carries: D5 verbatim; SKILL.md Step 2 (lines 117–195) as the text
being reworked; normalize-capture.sh usage block (lines 4–22).
Acceptance: SKILL.md nowhere instructs the model to transcribe/emit body
text; every Step-2 substep names its programmatic actor (cp/jq/script);
extract-email-body.sh runs under bash 3.2 against a fixture thread JSON;
both package.md files updated.

**U4 [worker, connectors/calendar-in]. Calendar fetch-to-file
canonization.** Depends-On: U1 | Parallel-safe with U3, U5, U6.
Files: `packages/connectors/calendar-in/skills/calendar-sweep/SKILL.md`,
`packages/connectors/calendar-in/package.md` (conformance row).
Canonize what the live run proved: §3 `list_events` called at the maximum
`pageSize` the tool accepts (Step-0-style verify, don't guess) so pages
land on disk; §4–§8 then operate per event **from the saved page file via
jq**: raw archive = `jq -c '.events[<i>]' <saved-file> >
archive/raw/<capture-id>.json` (the raw event object, programmatically
extracted); body = `jq '.events[<i>]'` pretty-print from the same file;
hints = pipe that object into the existing `scripts/extract-hints.sh`;
dedup key fields (`id`, `updated`) and `occurred_at` inputs read by jq. Add
D5's inline-residual rule + `inline-spilled=<n>` summary field. State the
same no-body-in-model-context invariant paragraph; note it binds backfill
mode identically (its "§3–§7 apply unchanged" inheritance). Empty-calendar
(`.events[]?`) and per-calendar failure isolation notes stay intact.
Brief carries: D5 verbatim; SKILL.md §3 + §7–§8 (lines 71–113, 189–231) as
the text being reworked.
Acceptance: every per-event handling step names jq/script as the actor
reading the saved file; archive step explicitly programmatic; invariant
paragraph present; package.md updated.

**U5 [worker, connectors/beeper-in]. Beeper backfill bound fix + history
clamp.** Depends-On: U1 | Parallel-safe with U3, U4, U6.
Files: `packages/connectors/beeper-in/scripts/beeper-sweep.sh`,
`packages/connectors/beeper-in/scripts/lib.sh`,
`packages/connectors/beeper-in/package.md` (conformance row + fix note).
Implement D6 exactly (the diagnosis is in this plan — do not re-diagnose):
(a) incremental `fetch_new_messages` no-cursor first-capture path returns
the page's oldest cursor too; the sweep records it once to
`data/connectors/beeper-in/coverage-floor.tsv` (`chatID<TAB>oldestCursor`)
on successful normalize; (b) `--backfill` per chat resolves its start
bound: floor cursor from `coverage-floor.tsv` when present → else derive a
timestamp floor from existing capture events for that `chatID` (oldest
`messages[].timestamp` across matching inbox bodies) and filter fetched
items `>=` it → else current newest-page behavior; `fetch_backfill_messages`
gains the optional floor parameters; (c) history clamp: on
history-exhausted-before-window-start, append
`<chatID>=history-clamped@<oldest_ts>` to WARN (flows into `runs.log`).
Backfill still writes zero incremental files (`cursors.tsv`, `last-sweep`,
and the new `coverage-floor.tsv` are incremental-owned). bash 3.2, jq.
Brief carries: D6 verbatim incl. the line-number citations; lib.sh
`fetch_backfill_messages` full body (lines 320–384) and
`fetch_new_messages` header (259–266); beeper-sweep.sh backfill cursor
block (lines 244–261).
Acceptance: with a floor present, backfill's first request paginates before
the floor cursor (not the incremental cursor); legacy derivation filters
correctly on fixture inbox events; clamp WARN appears in `runs.log`;
incremental invocation behavior byte-identical when no backfill runs.

**U6 [warm ingestion worker]. Triage script.** Depends-On: U2 |
Parallel-safe with U3–U5; serial before U7 (same worker).
Files: `packages/ingestion/scripts/triage-inbox.sh` (new).
bash 3.2 + jq. Args: `<store-dir>` `[--data-dir <dir>]` (default
`data/ingestion` resolution matching the debrief skill's convention)
`[--dry-run]`. Behavior: scan `inbox/*.md` (never `inbox/quarantine/`);
skip ids already in `debrief-filed.log` OR `triage-held.log`; apply U2's
rules in spec order, first match wins; on match append the D3 ledger line
(`--dry-run`: print it instead, write nothing); no match → no output for
that event. End with a summary line
`triage: scanned=<n> held=<n> already-filed=<n> already-held=<n>
per-rule=<rule>:<n>,...` — every terminal state emitted, silence
impossible. Writes only `triage-held.log`; inbox files never touched;
idempotent (re-run holds nothing new); deterministic (byte-stable output on
the same input). Cold-pitch store lookup reads `index.json` read-only.
Brief carries: U2's finished rule patterns + D3 ledger format verbatim; the
capture-event frontmatter table; debrief-filed.log convention excerpt
(debrief SKILL.md lines 47–67).
Acceptance: dry-run on a fixture inbox prints expected holds and writes
nothing (tree-diff clean); real run appends exactly the D3-format lines;
second run appends zero.

**U7 [same warm ingestion worker]. Debrief hook + manifests.**
Depends-On: U6 (and U2).
Files: `packages/ingestion/skills/debrief/SKILL.md`,
`packages/ingestion/package.md`.
SKILL.md §1 edits only: batch mode's selection adds "and whose `id` is not
in `data/ingestion/triage-held.log`" (mirroring the existing
`debrief-filed.log` exclusion sentence structure); single-event mode adds
the D3 reversal sentence — an explicitly-invoked single-event run files a
held event normally (the hold is thereby superseded; no ledger edit).
Recommend (one sentence) running `triage-inbox.sh` before a batch pass;
batch mode must not itself judge junk that triage already held. package.md:
provides rows (`scripts/triage-inbox.sh`, `specs/import-triage.md`, the
held-ledger convention), consumes `import-pipeline@^1`, built-by plan 26
note. No other SKILL.md section touched.
Brief carries: debrief SKILL.md §1 (lines 47–67) verbatim; D3 verbatim;
current package.md Provides/Consumes sections.
Acceptance: batch-mode exclusion + single-event override sentences present;
rest of SKILL.md byte-identical; package.md rows added.

### Phase 3 — tests + eval (one parallel message: 2 connectors test workers
on disjoint suite files + warm ingestion worker U10→U11)

**U8 [worker, connectors/tests]. Capture-suite additions.** Depends-On: U3,
U5 | Parallel-safe with U9, U10.
File: `packages/connectors/tests/run-capture-tests.sh` (currently 109
green — extend, same style).
Tests: `extract-email-body.sh` — subject+blank+verbatim `plaintextBody`
from a fixture thread JSON (byte-compare incl. trailing whitespace); absent
message id → non-zero + stderr reason; absent `toRecipients` handled (no
crash). Keep to the new script — SKILL.md prose changes are eval/live
territory, not bash-testable.
Acceptance: suite green under bash 3.2; each new test fails under momentary
sabotage (then reverted).

**U9 [worker, connectors/tests]. Beeper backfill regression tests.**
Depends-On: U5 | Parallel-safe with U8, U10.
File: `packages/connectors/tests/run-beeper-capture-tests.sh` (currently
88 green — extend, same style, stub HTTP fixtures).
Tests: (i) **zero duplicate-subset events** — incremental first-capture
then `--backfill` over the same fixture history produces no capture event
whose message-id set is a subset of a prior event's; (ii)
`coverage-floor.tsv` written once at first capture, never advanced, never
written by backfill; (iii) legacy path — floor absent, prior capture events
present → backfill excludes already-captured timestamps; (iv) history
exhausted before window start → `history-clamped@` WARN in `runs.log`; (v)
incremental files (`cursors.tsv`, `last-sweep`) byte-identical across a
backfill run.
Acceptance: suite green; each of the five properties has a distinct failing
mode when sabotaged.

**U10 [warm ingestion worker]. Triage goldens + suite.** Depends-On: U6 |
Parallel-safe with U8, U9; serial before U11 (same worker).
Files: `packages/ingestion/tests/fixtures/triage/` (new — **synthetic PII
only**, modeled on the chunk-24 junk classes per D4),
`packages/ingestion/tests/run-triage-tests.sh` (new, style of
`run-seed-tests.sh`).
Fixtures: ≥1 hold case per rule (noreply-marketing, self-only-calendar,
otp-security, linkedin-invitation, cold-pitch) AND a **zero-false-holds
golden set** — synthetic lookalikes of the corpus's *filed* event classes
(real debrief voice-note, multi-attendee calendar event, genuine 1:1 email
from a known person incl. one from a `noreply`-adjacent-but-known sender,
non-invitation LinkedIn notification, beeper chat-message) that must all
fall through. Tests: per-rule holds with exact D3 ledger lines
(byte-compare); zero holds on the golden set; idempotent second run;
`--dry-run` writes nothing; ledger append-only (prior lines untouched);
quarantine dir ignored.
Acceptance: suite green under bash 3.2; expected ledger lines stored as
literal strings; a deliberately over-broad pattern (sabotage) trips a
false-hold failure.

**U11 [same warm ingestion worker]. Held-respect eval case.**
Depends-On: U7, U10.
Files: new T3 case under `packages/ingestion/evals/cases/` +
`packages/ingestion/evals/suite.txt` registration.
Triage itself is deterministic → bash-tested (U10), not eval'd (plan 24 U15
doctrine). The one model-facing behavior gets the eval: fixture store with
an inbox containing one held event (pre-seeded `triage-held.log`), one
filed, one eligible; run the debrief skill in batch mode; expected: the
eligible event files, the held event produces **zero** store writes and no
`debrief-filed.log` entry. Grader: fact-based (file-existence/ledger
checks), operative-procedure prompt with the §1 contract text embedded
verbatim — follow the plan-24 rewritten cases as the pattern, eval-case
1.2.0.
Acceptance: `bash packages/core/scripts/eval-suite.sh
packages/ingestion/evals/suite.txt` runs it green; doctoring the case to
file the held event flips it to FAIL.

### Phase 4 — verification (orchestrator-led)

**U12. Full-suite + live proofs.** Depends-On: U8–U11.
1. All suites green: `run-store-tests.sh`, `run-capture-tests.sh`,
   `run-beeper-capture-tests.sh`, `run-scheduler-tests.sh` (untouched),
   `run-seed-tests.sh` (untouched), `run-triage-tests.sh`, filing goldens
   `check-golden.sh --all packages/ingestion/tests/goldens/debrief
   <worked-root>` (untouched-green — no filing-logic change), full eval
   suite (18/18 incl. U11).
2. **Live triage calibration (private data, local only, nothing
   committed):** `triage-inbox.sh <store> --dry-run` against the chunk-24
   live corpus; assert zero would-holds among ids present in
   `debrief-filed.log` and that each junk class shows holds. False-hold
   found → tighten the U2 pattern (fix round), re-run.
3. **Live gmail proof (user session — first-party MCP required):** one
   gmail backfill page end to end; evidence = saved tool-result path, `cp`
   archive, jq classify/extract, `inline-spilled` count, and a session
   transcript showing no body text in model output. Same spot-check on one
   calendar page. Like plan 24 U14.2, this awaits a user session if not
   available at merge time — note it in Status if deferred.
4. Beeper live re-run: `--backfill` against the real bridge → zero new
   duplicate-subset events (compare capture-event message-id sets),
   `history-clamped` WARN where history is shallow.
5. `check-sync.sh <store>` + `validate-store.sh <store>` clean; ROADMAP row
   26 → Done; memory notes; this plan's Status → Done with evidence. Max 2
   fix rounds; retry briefs carry diffs + failure output.

## Proof of done (maps to ROADMAP §26)

1. Stage contract versioned in core; gmail-in, calendar-in, beeper-in,
   connectors-root, and ingestion package.md files declare conformance
   (U1, U3, U4, U5, U7).
2. A gmail backfill page processes end to end with no body transcription
   in-session (U3 + U12.3).
3. Beeper backfill re-run produces zero duplicate-subset events (U5, U9,
   U12.4).
4. Triage auto-holds the junk classes from the chunk-24 live corpus with
   zero false-holds on its filed events — golden-tested (U10) and
   live-verified (U12.2).
5. Capture + filing suites green (U12.1).

## Explicitly out of scope (adjacent chunks — do not pull in)

- **Speed/cost (chunk 27):** page budgets, parallel filing, batch-mode
  throughput, model-cost accounting. Triage reduces judgment volume as a
  side effect; no perf work here.
- **Sync timing (chunk 28):** no sync-lanes.md change, no scheduler wiring
  of triage, no cadence work. Triage is invoked manually/by the debrief
  flow this chunk.
- **Fleet (chunk 29):** no new lanes, no contacts-in.
- **Judgment quality (chunk 30):** no debrief filing-logic changes beyond
  the §1 held-exclusion hook; the group-chat-noise class stays with
  judgment (D4); no retroactive triage of already-filed history, no
  un-filing, no held-event expiry/review tooling.
- **Gmail/calendar as shell scripts:** they remain session-driven skills by
  the first-party-MCP-only constraint; fetch stays an in-session tool call
  — the standardization is that results land on disk.

## Close-out (2026-08-29)

All 12 units executed same-session (U1–U11 workers, U12 orchestrator), 4
commits (de06b08 phase 1, 0ccd52d phase 2, 0db39f7 phase 3, 29ec311 fix
round). Evidence against Proof of done:

1. **Contract + conformance:** `import-pipeline.md` 1.0.0 in core;
   conformance declared in gmail-in, calendar-in, beeper-in, connectors
   root, and ingestion package.md (consumes `import-pipeline@^1` on all).
2. **Gmail no-transcription:** SKILL.md fully reworked (every Step-2 actor
   is cp/jq/script; `extract-email-body.sh` byte-verified under bash
   3.2). **U12.3 live-page proof DEFERRED** to a user-driven sweep session
   (first-party MCP moves real mail; plan-24 U14.2 precedent).
3. **Beeper zero duplicate-subsets:** regression-tested (109-green suite)
   AND live re-run 2026-08-30Z: `backfill-ok chats=50 events=0`, 37×
   `history-clamped@` WARNs, incremental files md5-identical.
4. **Triage golden + live calibration:** 20-assertion suite green with
   sabotage proofs; live-corpus dry-run: 160 scanned, 65 would-holds
   (63 self-only-calendar, 2 noreply-marketing), **0 false-holds** vs the
   37 filed ids. otp/linkedin-invitation/cold-pitch had no captured live
   instances (junk left uncaptured in the onboarding run) — synthetic
   goldens carry them until live data arrives.
5. **Suites:** store 10, capture 116, beeper 109, scheduler 64, seed 23,
   triage 20; full ingestion eval suite 19/19 PASS (incl. new smoke-tagged
   `triage-held-respected`, PASS×2 + doctored-FAIL proven; $0.79/run).

Checker: /code-review medium over the branch — zero CRITICAL/HIGH; 4
MEDIUM all fixed in one round (case-insensitive subject sed; legacy-floor
null-timestamp guard; two manifest consumes rows; spec-authoritative
pattern note). LOW advisories recorded, deliberately not fixed here:
duplicate-message-id guard in extract-email-body.sh; frontmatter-parsing
helpers duplicated across ingestion/core scripts (candidate ingestion-local
lib); sender_known/per-event ledger lookups O(N·M) at 1000+ events
(chunk-27 speed territory); `coverage_floor_get` could delegate to
`cursor_get`. Pattern-source unification (spec-as-data) noted as a deeper
option if U12-style calibrations recur.

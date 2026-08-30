# Plan 34 — Feedback ledger & active iteration

Status: Ready
Package: core (contract) + ingestion (ledger writer, reply parse, prompt block, evals) + attention (lifecycle hooks, calibration, proposals, report card) + connectors/scripts (sync lane row)
Depends-on: 33 (delivery + reply-grammar footer + `delivered.log`), 31 (`person-set-tier.sh`, `tier_source`, provisional user-model)

## Objective

Every piece of user feedback — a reply to a card, a tier/kind correction, a
draft edit, an opt-out, a freeform remark — lands as one line in one
append-only ledger, and that ledger visibly changes what the assistant does
next: the words the user typed go into every judgment prompt, every
correction becomes a regression eval, outcomes change which kinds of people
are even looked for, corrections roll up into user-model revision proposals,
and the assistant reports its own accuracy weekly.

**Mission test.** Feedback is the cost of *re-explaining yourself* to the
assistant — pure running cost. Nothing here sends, auto-adopts a style, or
scores the user: acted-on rate is a quality signal on the assistant's
judgment, never an engagement target; the budget stays user-set; the report
card is the assistant's, not the user's.

## Context

Research note `docs/research/2026-08-30-nudge-delivery-and-feedback-loop.md`
Part 2 (F1–F6) and its closing Decisions block are settled input. Gaps it
names: feedback is scattered across four writers (G1); reasons never reach
a prompt (G2); calibration only re-ranks what detectors already found (G3);
person-level corrections never roll up (G4); no reply path (G5); no accuracy
number (G6). Plan 33 gives every card a numbered reply footer and writes
`delivered.log`; `beeper-in` already lands note-to-self replies in `inbox/`
as `chat-message` capture events, so reply capture costs nothing new.

## Decisions (settled — encode, do not re-litigate)

- **D1 One ledger.** New core contract `feedback-event` 1.0.0; ledger
  `<store>/signals/feedback.jsonl`, append-only, source of truth; everything
  else (weights, evals, proposals, report card) is derived and regenerable.
  Sole writer: `packages/ingestion/scripts/feedback-file.sh`. Existing sole
  writers of their own artifacts — attention `wakeup-queue.sh`, core
  `person-set-tier.sh`/`person-set-kind.sh` (stated writes only), the
  review-tiers correction digest — keep their files and additionally CALL
  `feedback-file.sh`. Fields: `ts`, `type`, `target`, `from`, `to`,
  `reason`, `text`, `channel`, `source`.
- **D2 Reply capture rides on sync.** Ingestion gains a deterministic,
  no-model `feedback-parse` step that reads new note-to-self `chat-message`
  events, parses the numbered grammar against the last delivered batch
  (`delivered.log`, plan 33), applies via the existing ops, and appends the
  ledger line. Unparseable text → a `freeform` line, never dropped. Runs on
  every sync tick as its own `sync-lanes` row ("quickly check if anything
  changed"); a tick with no new replies is a no-op.
- **D3 Feedback → prompting.** Every judgment prompt (review-tiers judge,
  tier-drift judgment, draft composition) gets a `## Recent corrections`
  block: the last ≤10 `*-correction` lines rendered "judge said X, user
  said Y, words: '…'". `draft-edit` lines feed `profile.md` style notes via
  plan 15's confirm path; the draft prompt reads `## Style notes`.
- **D4 Corrections → evals.** Each `*-correction` line generates/refreshes a
  T3 eval case asserting the judge now yields the stated kind/tier for that
  person; the suite runs from `scripts/test-all.sh`.
- **D5 Feedback → who you look for.** `ranking-weights` 1.2.0: `kinds`
  gains an outcome term (same formula/clamps as `signal-types`; seed stays
  the baseline). Tier-drift prefilter and the budget split read kind
  weights BEFORE enumeration. 2× `not-them` on one person in 90d → an
  opt-out proposal line in the next delivered card.
- **D6 Corrections → user-model revision proposals.** Weekly-planning step:
  ≥3 same-axis, same-direction corrections in 30d → one `origin: standing`
  wake-up proposing the axis change; confirm → ingestion bumps `revision`
  → reseed. Attention proposes, ingestion writes.
- **D7 Weekly report card.** In the weekly digest: acted-on rate by signal
  type and kind, dismiss-reason histogram, correction rate per judge run.
  Framed as the assistant's score ("I got 3 of 5 right"); no engagement
  targets; budget stays user-set.

Sequencing: Phase 1 = D1+D2 (wave 1) then D3+D4 (wave 2). **Phase 2** =
D5–D7 (wave 3), dispatched only after ≥2 weeks of live ledger data so the
first tuning is against real outcomes.

## Deliverables

| Pkg | Artifact |
|---|---|
| core | `contracts/feedback-event.md` 1.0.0; fixture `fixtures/store/signals/feedback.jsonl`; `person-set-tier.sh`/`person-set-kind.sh` ledger hook; `contracts/ranking-weights.md` 1.2.0 (phase 2); `eval-suite.sh` private-manifest mode |
| ingestion | `scripts/feedback-file.sh`, `scripts/feedback-parse.sh`, `scripts/feedback-recent.sh`, `scripts/feedback-to-evals.sh`; `specs/feedback-ledger.md`, `specs/feedback-parse.md`; review-tiers spec/SKILL prompt + confirm-path amendments; `tests/run-feedback-tests.sh` |
| attention | `wakeup-queue.sh` hooks; `specs/outcome-recording.md` amendment; tier-drift + signal-scan `## Recent corrections`; (phase 2) `calibrate.sh` kinds outcome term, prefilter/budget by kind weight, `scripts/model-revision-proposals.sh`, `scripts/report-card.sh`, weekly-planning steps |
| connectors | `sync-lanes` template row `feedback` |
| docs | DECISIONS `feedback-ledger`; ROADMAP row 34; three `package.md` manifests |

## Work units (≤3 min each; [worker] mutates, [checker] reads only)

### Wave 1 — D1 + D2 (ledger useful immediately)

| # | Pkg | Unit | Depends-On |
|---|---|---|---|
| U1 [worker] | core | `contracts/feedback-event.md` 1.0.0 (shape below, enum, append-only + regenerable semantics, writer table: sole writer ingestion `feedback-file.sh`, callers listed) + fixture `fixtures/store/signals/feedback.jsonl` (3 lines: dismiss, tier-correction, freeform) | — |
| U2 [worker] | ingestion | `scripts/feedback-file.sh` (CLI below) + `specs/feedback-ledger.md` (append protocol, `text` = verbatim = stated-by-user, no rewrite ever, `jq -c` escaping) | U1 (contract text pasted in brief) |
| U3 [worker] | ingestion | `tests/run-feedback-tests.sh` part 1: enum reject, required-field reject, append-only (two calls → two lines, first untouched), `text` verbatim incl. quotes/newlines/unicode, `mkdir -p signals/`, `--ts` override, exit codes | U2 |
| U4 [worker] | core | `person-set-tier.sh` + `person-set-kind.sh`: when `--source stated-by-user`, gain `--feedback-text "<words>"` `--feedback-channel <c>` `--feedback-source reply\|session` (default `session`) and call `feedback-file.sh --type tier-correction\|kind-correction --target person:<slug> --from <previous value or null> --to <new>`; skip-with-log if `feedback-file.sh` is absent (core tests never depend on ingestion) | U2 |
| U5 [worker] | core | `tests/run-store-tests.sh`: stated write appends one ledger line with correct from/to; derived write appends nothing; absent `feedback-file.sh` → log line, exit 0 | U4 |
| U6 [worker] | attention | `wakeup-queue.sh`: `snooze` → `--type snooze --reason <duration>`; `dismiss --reason <enum> [--text ..]` → `--type dismiss`; `confirm` → `--type acted-on`; `decline` → `--type dismiss`; `acted-on` step writing `true` → `--type acted-on --source auto`; all `--target wakeup:<id>`, `--channel` passthrough (default `session`). `specs/outcome-recording.md` §1/§2 amendment: "every lifecycle write also appends one ledger line" | U2 |
| U7 [worker] | attention | `tests/run-queue-tests.sh`: one ledger line per op with the mapped type/reason; `acted-on: false` appends nothing; fixture store without `signals/` still passes | U6 |
| U8 [worker] | ingestion | `scripts/feedback-parse.sh` (grammar + apply table below) + `specs/feedback-parse.md`; cursor `data/ingestion/feedback-cursor` (last processed capture id); `data/ingestion/feedback-applied.log` `<capture-id>\t<line-no>\t<type>\t<ts>` | U2, U4, U6 |
| U9 [worker] | ingestion | `tests/run-feedback-tests.sh` part 2 + `tests/fixtures/feedback/` (inbox events + `delivered.log`): each verb applies + ledgers; stale index (`n` > batch) → freeform; multi-line reply; idempotent re-run (cursor); events from a non-notify chat ignored; no `delivered.log` → every line freeform, exit 0 | U8 |
| U10 [worker] | connectors | `sync-lanes` template: row `feedback` (command `bash packages/ingestion/scripts/feedback-parse.sh <store> --data-dir <d>`, interval = beeper lane's, ordered after it; ships enabled — deterministic shell, no `claude -p`) + scheduler test row | U8 |
| U11 [worker] | ingestion | review-tiers `specs/review-tiers.md` + `SKILL.md` step 4: a correction passes the user's words (`--feedback-text`) to `person-set-tier.sh`/`person-set-kind.sh`; `specs/stated-preference-filing.md` (a).2 same; summary line "corrections ledgered: N" | U4 |
| U12 [worker] | docs | DECISIONS `feedback-ledger` entry; ROADMAP row 34 (phase 1 in progress); `packages/{core,ingestion,attention}/package.md` provides/consumes (`feedback-event@1`; ingestion sole writer; attention/core callers; runtime path `signals/feedback.jsonl` owned by ingestion) | U1–U11 |
| U13 [checker] | all | Wave-1 review: single-writer holds (only `feedback-file.sh` opens the ledger for write), no ledger line rewrites `text`, `oss-guard.sh` clean, all suites green | U12 |

### Wave 2 — D3 + D4 (feedback reaches prompts and evals)

| # | Pkg | Unit | Depends-On |
|---|---|---|---|
| U14 [worker] | ingestion | `scripts/feedback-recent.sh <store> [--n 10] [--kind corrections\|draft-edits] [--person <slug>]` → renders the `## Recent corrections` block (format below), newest first, deterministic; empty ledger → `## Recent corrections\n_none yet_` | U2 |
| U15 [worker] | ingestion | review-tiers judgment prompt contract (spec + SKILL): new input 2b = `feedback-recent.sh` output verbatim, placed after the priors block; instruction line "these are the user's own words; a correction outranks any prior". `check-judgment.sh` unchanged | U14 |
| U16 [worker] | attention | `specs/tier-drift.md` "Judgment verdict" + `skills/signal-scan/SKILL.md`: judgment prompt includes the same block (invoke `feedback-recent.sh`, read-only, ingestion script never edited); draft composition (`--draft`) reads `profile.md ## Style notes` + `feedback-recent.sh --kind draft-edits` | U14 |
| U17 [worker] | ingestion | `specs/stated-preference-filing.md`: `draft-edit` ledger lines are the producer for plan 15's draft-diff loop — observed style note proposed from ≥2 same-direction edits, filed to `## Style notes` only on confirm, confirm itself ledgered as `model-confirm` target `model` | U14 |
| U18 [worker] | core | `eval-suite.sh` / `eval-run-skill.sh`: `RA_EVAL_PRIVATE_MANIFEST=<path>` — a manifest living under the private data dir may reference `store`/`expected` paths under that same data dir; committed manifests keep the hard `data/` refusal; contract `eval-case.md` 1.3.0 note | — |
| U19 [worker] | core | test for U18: committed case pointing at `data/` still refuses; private manifest with private paths runs (dry-run) | U18 |
| U20 [worker] | ingestion | `scripts/feedback-to-evals.sh <store> --data-dir <d>`: for each `*-correction` line, (re)generate `<d>/evals/feedback/cases/<slug>-<type>/` (T3: `before/` = that person's `people/` file + their `interactions/` + `user-model.md` + `profile.md`; `prompt.md` = `review tiers --person <slug>`; `graders/01-stated-holds.sh` asserts `kind`/`tier` == ledger `to` and `*_source: stated-by-user`), rewrite `<d>/evals/feedback/suite.txt`; idempotent; one committed fixture-driven case under `packages/ingestion/evals/cases/feedback-correction-holds/` proves the generator in CI | U14, U18 |
| U21 [worker] | ingestion | `tests/run-feedback-tests.sh` part 3: `feedback-recent.sh` render golden (fixture ledger → exact block, cap 10, `--person` filter); `feedback-to-evals.sh` case-dir shape, grader hand-derived from ledger (golden-before-prompts), re-run idempotent | U14, U20 |
| U22 [worker] | harness | `scripts/test-all.sh`: add `run-feedback-tests.sh`; run the private feedback suite via `RA_EVAL_PRIVATE_MANIFEST` only when `<data-dir>/evals/feedback/suite.txt` exists (CI never has it → SKIP line, silence impossible); README test list + CLAUDE.md test-command list | U20 |
| U23 [worker] | docs | manifests + ROADMAP row 34 (phase 1 done, phase 2 gated on 2 weeks live data); `docs/SETUP.md` one line: feedback lane ships enabled, reply grammar reminder | U15–U22 |
| U24 [checker] | all | Wave-2 review: prompt block present in all three prompts; no real-person data under `packages/`; `oss-guard.sh` clean; suites + eval smoke green | U23 |

### Wave 3 — Phase 2: D5 + D6 + D7 (after ≥2 weeks live ledger)

| # | Pkg | Unit | Depends-On |
|---|---|---|---|
| U25 [worker] | core | `contracts/ranking-weights.md` 1.2.0: `kinds` entries may carry an outcome-derived weight; rationale grammar distinguishes `seeded from user-model revision <n>` vs `acted on a of b fired nudges (kind)`; revision-aware reseed rule unchanged (outcome-touched keys survive) | wave 1 |
| U26 [worker] | attention | `calibrate.sh` sweep mode: `kinds` outcome term — bucket in-window wake-ups by each listed person's `kind`, same counters/formula/clamps as §3, `negative_counter = dismissed_total − dismissed_not_this_person`, `fired ≥ 3`; `specs/calibration.md` §2.4/§3 amendment | U25 |
| U27 [worker] | attention | `tests/run-attention-tests.sh`: kinds outcome step against fixture history (moves ±≤0.15, clamps, seed rationale replaced, `fired < 3` untouched) | U26 |
| U28 [worker] | attention | `specs/tier-drift.md` prefilter + `specs/ranking.md` §8 + signal-scan SKILL: enumerate rhythmed kinds ordered by `kinds.<k>.weight` desc; a kind with weight ≤ 0.5 gets half its candidate share; per-kind share = user-model axis mix × kind weight, normalized, applied before the judgment pass; disclosed in the scan log | U26 |
| U29 [worker] | attention | `calibrate.sh` §4: count `not-this-person` from BOTH `wakeups/` and ledger lines (`type: dismiss, reason: not-this-person`, incl. reply `not-them`); ≥2 in 90d → existing suppression-proposal wake-up, `why` prefixed so plan 33's renderer shows it as a one-word-confirm proposal line | U26 |
| U30 [worker] | attention | tests for U28 (deterministic share table on fixture weights) + U29 (ledger-sourced count triggers exactly one proposal; idempotent) | U28, U29 |
| U31 [worker] | attention | `scripts/model-revision-proposals.sh <store> [--window 30] [--today]` + weekly-planning SKILL step: map each `tier-correction`/`kind-correction` to an axis (calibration.md kind→axis map) and a direction (tier up/down; kind moved into/out of axis); ≥3 same axis+direction in window and no pending/fired proposal for that axis → one `wakeup-add.sh --origin standing` with `why: "you've moved <n> <axis> people closer — raise <axis> from <w> to <w'>?"`, `--context` listing the ledger lines; proposed `w'` = current ± 0.15 clamped [0,1] | wave 1 |
| U32 [worker] | ingestion | review-tiers `--confirm-model --apply-proposal <wakeup-id>`: reads the proposal, sets the axis line, `revision++`, `status: confirmed`, reseeds (`calibrate.sh --seed-from-user-model`), ledgers `model-confirm` (`target: model`, `from`/`to` = axis weights); `wakeup-queue.sh confirm` is the lifecycle write | U31 |
| U33 [worker] | attention + ingestion | tests: U31 fixture ledger (3 family-up → one proposal; 2 → none; existing pending → none); U32 revision bump + reseed rationale names new revision | U31, U32 |
| U34 [worker] | attention | `scripts/report-card.sh <store> [--window 7]` + weekly-planning SKILL step "report card": acted-on rate by `signal-type` and by kind (ledger `acted-on` ÷ fired), dismiss-reason histogram, correction rate per judge run (`1 − corrections/derived` per `review-judgments/<date>.jsonl` vs ledger corrections targeting those slugs within 7d); output block appended to the weekly digest (plan 33 renderer). Binding wording rules: first person for the assistant ("I got 3 of 5 right"), no "you", no pending counts, no streaks, no targets | wave 1 |
| U35 [worker] | attention | tests for U34: fixture ledger + wakeups → exact rates; empty window → "no nudges fired this week" line; grep-guard for forbidden framing tokens | U34 |
| U36 [worker] | docs | DECISIONS amend; ROADMAP row 34 phase 2; manifests (`ranking-weights@1.2`, new scripts, weekly-planning steps) | U25–U35 |
| U37 [checker] | all | Phase-2 review: attention never writes `profile.md`/`user-model.md`/`person.md`; budget unchanged by any outcome; suites green | U36 |

Dispatch: U1 → {U2, U18} → {U3, U4, U6, U8-after-U4/U6, U19} … per the
Depends-On column; disjoint packages run in one parallel message.

## Interfaces (paste into briefs verbatim)

### `feedback-event` 1.0.0 — `<store>/signals/feedback.jsonl`

One JSON object per line, append-only. `type` enum: `dismiss | snooze |
acted-on | done | opt-out | tier-correction | kind-correction | draft-edit |
model-confirm | freeform`. `target`: `wakeup:<id> | person:<slug> |
signal:<type> | model`. `source` enum: `reply | session | auto`. `text` is
the user's verbatim words (stated-by-user by definition) or `null`; it is
never rewritten. `from`/`to`/`reason`/`channel` are `null` when not
applicable.

```json
{"ts":"2026-08-30T14:02:00Z","type":"dismiss","target":"wakeup:2026-08-30-jane-doe","from":null,"to":null,"reason":"not-this-signal-type","text":"I never do birthdays","channel":"beeper-self","source":"reply"}
{"ts":"2026-08-30T14:05:00Z","type":"tier-correction","target":"person:jane-doe","from":"active","to":"close","reason":null,"text":"she's basically family","channel":null,"source":"session"}
{"ts":"2026-08-30T14:06:00Z","type":"kind-correction","target":"person:bob-cpa","from":"friend","to":"transactional","reason":null,"text":"my accountant","channel":null,"source":"session"}
{"ts":"2026-08-30T14:07:00Z","type":"snooze","target":"wakeup:2026-08-30-sam-okafor","from":null,"to":null,"reason":"2w","text":null,"channel":"beeper-self","source":"reply"}
{"ts":"2026-08-30T14:08:00Z","type":"opt-out","target":"signal:linkedin-post","from":null,"to":"all","reason":null,"text":"never linkedin","channel":"beeper-self","source":"reply"}
{"ts":"2026-08-31T09:00:00Z","type":"acted-on","target":"wakeup:2026-08-30-sam-okafor","from":null,"to":null,"reason":null,"text":null,"channel":null,"source":"auto"}
{"ts":"2026-08-30T14:09:00Z","type":"freeform","target":"wakeup:2026-08-30-jane-doe","from":null,"to":null,"reason":null,"text":"actually let's talk about this next week","channel":"beeper-self","source":"reply"}
```

### `feedback-file.sh` CLI (ingestion, sole writer)

```
feedback-file.sh <store> --type <enum> --target <target> --source reply|session|auto
                 [--from <v>] [--to <v>] [--reason <r>] [--text "<verbatim>"]
                 [--channel <c>] [--ts <ISO8601Z>]
exit 0 appended | 2 usage/enum error, nothing written
```

### Reply grammar (`feedback-parse.sh`, deterministic)

First token = card index `n` from the last batch in `delivered.log`
(plan 33; `<ts>\t<n>\t<wakeup-id>` per line, newest batch wins); second
token = verb; remainder = `text`, kept verbatim.

```
<n> done                   → wakeup-queue.sh confirm|dismiss --reason already-handled ; ledger done
<n> snooze <dur>           → wakeup-queue.sh snooze <id> <dur>                        ; ledger snooze reason=<dur>
<n> skip                   → wakeup-queue.sh dismiss <id> --reason not-now            ; ledger dismiss
<n> never <signal-type>    → dismiss --reason not-this-signal-type ; profile ## Signal opt-outs
                             `**[stated-by-user]** <signal-type> — all` (ingestion is the writer;
                             an explicit ask is stated, not proposed)                 ; ledger opt-out to=all
<n> not-them               → dismiss --reason not-this-person                         ; ledger dismiss
<n> wrong-tier <tier>      → person-set-tier.sh <primary slug> --tier <t> --source stated-by-user
                             --feedback-text "<rest>"                                 ; ledger via hook
<n> <anything else>        → ledger freeform target=wakeup:<id>
<no valid n>               → ledger freeform target=model
```

Duration `<dur>` = `<int>[dhw]`. `<tier>` must be in `inner-circle | close |
active | dormant`, else freeform. Every applied line is also written to
`feedback-applied.log`; a reply whose apply op fails still gets its ledger
line (exit code logged, never dropped).

### `## Recent corrections` block (`feedback-recent.sh`)

```
## Recent corrections
- 2026-08-30 person:bob-cpa — judge said kind=friend, user said kind=transactional, words: "my accountant"
- 2026-08-30 person:jane-doe — judge said tier=active, user said tier=close, words: "she's basically family"
```

Cap 10, newest first; `words:` omitted when `text` is null.

### Ledger → axis map (U31)

Kind→axis per `specs/calibration.md` "kinds.* derivation". Direction: tier
correction `to` more attentive than `from` = up; kind correction whose `to`
maps to an axis = up for that axis, `from`'s axis = down.

## Proof of done

Phase 1:
1. `bash scripts/test-all.sh` green incl. `run-feedback-tests.sh`; `oss-guard.sh` clean; `validate-store.sh` ignores `signals/feedback.jsonl` (not a checked type) without error.
2. Live: reply `1 snooze 2w` in the note-to-self chat → next sync tick: wakeup `due` moved, `snooze-count` +1, one ledger line with `source: reply`, `feedback-applied.log` row; reply `hello there` → one `freeform` line.
3. Live: one `review tiers --person <slug>` correction → ledger line with the user's words; `feedback-recent.sh` shows it; the next judge prompt on that store contains the block; `feedback-to-evals.sh` produces a case whose grader passes against the corrected store.

Phase 2 (after ≥2 weeks live): `calibrate.sh` writes a `kinds` entry with an outcome rationale; scan log shows kind-ordered enumeration; a seeded fixture of 3 family-up corrections yields exactly one standing proposal; weekly digest carries the report-card block with first-person framing.

## Out of scope

- Per-person learned weights (contract stance kept: suppression proposals only).
- Auto-adopting style notes or user-model changes — every one passes a confirm.
- Any send, any engagement metric, any change to the user-set budget.
- Gmail-self reply parsing (plan 33 fallback channel) — `feedback-parse.sh` reads only the notify chat's `chat-message` events this chunk; add the gmail lane in a follow-up once 33's fallback is live.

## Open concerns (carried)

- Plan 33 is not yet on disk; `delivered.log`'s shape above is the capsule's statement. U8's brief must confirm it against the merged plan-33 renderer before dispatch.
- D4 vs `eval-case.md` PII rule: auto-generated cases name real people, so they must live under the private data dir and run via U18's private-manifest mode; CI runs only the fixture-driven committed case.
- `never <signal>` is treated as a stated write (ingestion is profile's sole writer), not a proposal; the capsule's D2 wording ("profile opt-out proposal") is preserved for the D5 `not-them ×2` path only. Flag if the orchestrator wanted a proposal in both cases.
- `wakeup-queue.sh` (attention) and `person-set-*.sh` (core) calling an ingestion script is a cross-package call sanctioned here by D1; manifests must declare it explicitly (U12).

Status: Ready

## Orchestrator rulings (2026-08-30, after plan 33 landed)

1. **`delivered.log` shape is plan 33's:** `<batch>\t<channel>\t<ts>\t<message-id>`,
   one line per delivered *batch*, in `<store>/outbox/` (connectors-owned).
   The n→wakeup-id map is NOT in the log: U8's parser resolves the most
   recent delivered batch (col 1) to `wakeups/fired/<batch>.json` and maps
   `n` = 1-based index into that batch's `entries` (render order = entry
   order, per plan 33's card spec). Replace every `<ts>\t<n>\t<wakeup-id>`
   assumption with this.
2. **D4 private-eval mode accepted:** `RA_EVAL_PRIVATE_MANIFEST` for
   correction-derived cases (real people, private data dir) + one committed
   fixture case for CI.
3. **`never <signal>` writes the stated opt-out directly** — it is a
   verbatim user statement, and ingestion is profile's sole writer. The
   proposal path applies only to inferred opt-outs (D5 `not-them ×2`).
4. Cross-package calls into `feedback-file.sh` are sanctioned by D1; U12
   declares them in every caller's manifest.

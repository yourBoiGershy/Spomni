# Golden fixtures: stated-preference filing

Six input→expected-delta cases pinning the behavior of the future
stated-preference filing flow (`docs/plans/2026-08-29-11-preference-personalization.md`,
unit 6/7 — the "Dana is inner-circle" / "stop nudging me about company news"
class of utterances). These goldens exist **before the filing prompt/skill
does** (`golden-tests-before-prompts`), so the spec has pinned expected
behavior to implement against and a future checker has something to diff.

These are **narrower** than `packages/ingestion/fixtures/golden/` (plan 03's
full debrief-filing goldens, which exercise person/interaction/wakeup
creation end to end). Each case here is scoped strictly to the
**stated-preference delta**: a `people/<slug>.md` `tier` change and/or a
`profile.md` bullet. No `interactions/` or `wakeups/` files are created or
expected — that's plan 03's concern, not this layer's.

## Case layout

Each case is a subdirectory of `preferences/` containing:

- `input.md` — the triggering utterance, wrapped in a minimal capture-event
  envelope (`packages/core/contracts/capture-event.md` shape: frontmatter +
  raw body text), as if produced by a debrief/voice-note connector.
- `before/` — the minimal store files that exist immediately before filing
  (only the files this case's delta touches or must prove untouched — not a
  full synthetic store).
- `expected/` — the same relative paths as `before/`, after filing:
  - Files that should change: full expected file content, byte-exact except
    where noted.
  - Files that should NOT change (proving no over-write / no incidental
    mutation): byte-identical copies of the `before/` version.
  - The ambiguous case (`06-ambiguous-question/`) additionally has
    `expected/question.md`, and every `before/` file is copied to
    `expected/` unchanged — the expected outcome of filing is a question
    artifact, not a store write.

## Cases

| Dir | Utterance | Expected delta |
|---|---|---|
| `01-tier-change/` | "Dana is inner-circle now, we talk every week." | `people/dana-whitfield.md` `tier: close` → `tier: inner-circle` |
| `02-global-optout/` | "Stop nudging me about company news." | `profile.md` `## Signal opt-outs` gains `company-news — all` |
| `03-cadence-wish/` | "I want to stay quarterly with my Michigan crew." | `profile.md` `## Cadence wishes` gains a bullet |
| `04-priorities/` | "This year I'm prioritizing fintech contacts." | `profile.md` `## Priorities` gains a bullet |
| `05-person-optout/` | "No birthday reminders for Ben." | `profile.md` `## Signal opt-outs` gains `birthday — [[ben-whitmore]]`; `people/ben-whitmore.md` unchanged |
| `06-ambiguous-question/` | "Alex is close now." (two Alexes in the store) | No store write anywhere; `expected/question.md` describes the clarifying question the filing engine must ask instead |

Every stated-preference bullet in `expected/profile.md` carries
`**[stated-by-user]**` plus a trailing `(2026-08-29)` date, per
`packages/core/contracts/profile.md`'s provenance-tagging rule — untagged
bullets are a `validate-store.sh` error, so these goldens double as
provenance-tagging fixtures.

## How a future `check-golden.sh` should compare

Following the convention set by plan 03's `packages/ingestion/scripts/check-golden.sh`
(diff actual vs. expected, ignore timestamps, PASS/FAIL per golden):

1. For each case directory: copy `before/` into a scratch store, run the
   filing flow against `input.md`.
2. Diff every file under the scratch store against the matching path in
   `expected/`, byte-for-byte, **except** frontmatter/body dates that the
   filing engine derives from "now" (e.g. `last-touch`, tag dates) — those
   should be normalized to `2026-08-29` (this fixture set's fixed "today")
   before diffing, exactly as plan 03's goldens ignore timestamps.
3. For `06-ambiguous-question/`: assert (a) the flow emits a question
   artifact matching `expected/question.md`'s intent (candidate list +
   no-guess outcome — exact prose need not match verbatim), and (b) every
   file under the scratch store is byte-identical to its `before/`
   counterpart. Case (b) failing is the important assertion: it catches a
   filing engine that guesses instead of asking.
4. Report PASS/FAIL per case; a single FAIL should print the diff, not just
   the case name — mirrors plan 03's `check-golden.sh` reporting shape.

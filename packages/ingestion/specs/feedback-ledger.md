# Feedback ledger spec

Package: ingestion. Sole writer: `packages/ingestion/scripts/feedback-file.sh`.
Contract: `packages/core/contracts/feedback-event.md` 1.0.0 (this document
implements against it; the contract is authoritative on the JSON shape —
see "Contract reference" below for the field-by-field statement carried
here for convenience). Plan 34 D1.

## Purpose

Every piece of user feedback anywhere in the system — a reply to a
delivered card, a tier/kind correction made during a review session, a
freeform remark that doesn't parse — lands as one line in one append-only
file: `<store-dir>/signals/feedback.jsonl`. Mission test: this cuts the
running cost of *re-explaining yourself* to the assistant. The user's own
words are stored verbatim and reused (in judgment prompts, in regression
evals) instead of the user having to restate a correction every time it
would help. Nothing here sends, auto-adopts, or scores the user — the
ledger is read-only input to the rest of the system.

## Append protocol

- One JSON object per call, one line per object, newline-terminated.
- The file is *only* ever appended to (`>>`). No line is ever rewritten,
  reordered, deduplicated, or deleted by `feedback-file.sh` or by any
  reader. A correction supersedes an earlier one by virtue of being later
  in the file, not by editing the earlier line.
- `mkdir -p <store-dir>/signals` runs before every append so a fresh store
  (no prior feedback) still succeeds on the first call.
- A single write per invocation: `feedback-file.sh` never opens the file
  more than once, never buffers multiple lines, never truncates.
- Enum or shape validation failures exit 2 and touch the file not at all
  (not even to create `signals/` — validation happens before `mkdir -p`).

## `text` is verbatim

The `--text` argument, when present, is the user's own words, byte for
byte (JSON-escaped only as required for valid JSON — quotes, embedded
newlines, and non-ASCII/unicode all survive intact). It is never
paraphrased, summarized, truncated, or corrected for grammar/spelling by
this script or by any caller. By construction, a non-null `text` field is
always stated-by-user provenance — there is no other source for it. Readers
(judgment prompts, `feedback-recent.sh`, `feedback-to-evals.sh`) must
likewise render it unmodified.

`text` is `null` when the event carries no user words (e.g. an automatic
`acted-on` line, or a reply that mapped cleanly to a structured op with no
free text attached).

## Escaping

The JSON line is built with `jq -cn --arg <name> "<value>"` for every
string field, never with hand-built string concatenation or `printf`
quoting. This guarantees correct escaping of double quotes, backslashes,
embedded newlines, and unicode in `--text` (and any other field) without
special-casing any of them in the caller. Optional fields (`--from`,
`--to`, `--reason`, `--text`, `--channel`) that are absent or empty on the
command line are written as JSON `null`, never as an empty string — a
reader can distinguish "not supplied" from "supplied and empty" this way.

## Callers (all call `feedback-file.sh`; none open the ledger directly)

| Caller | Package | When | `type` |
|---|---|---|---|
| `wakeup-queue.sh` | attention | snooze/dismiss/confirm/decline/`acted-on` lifecycle writes | `snooze`, `dismiss`, `acted-on`, `done` |
| `person-set-tier.sh` | core | `--source stated-by-user` write with `--feedback-text` supplied | `tier-correction` |
| `person-set-kind.sh` | core | `--source stated-by-user` write with `--feedback-text` supplied | `kind-correction` |
| `skills/review-tiers/` (correction digest) | ingestion | a review session's tier/kind correction, passing the user's words through to the two scripts above | `tier-correction`, `kind-correction` |
| `scripts/feedback-parse.sh` | ingestion | deterministic reply-grammar parse of note-to-self replies on each sync tick | `done`, `snooze`, `dismiss`, `opt-out`, `freeform` (per the parsed verb; unparseable text always falls through to `freeform`, never dropped) |

Per plan 34 D1, these are sanctioned cross-package calls into an ingestion
script (single-writer rule holds: `feedback-file.sh` is the only code path
that opens `signals/feedback.jsonl` for write; every other package calls
it rather than writing the file itself). Each caller's `package.md`
declares the call explicitly.

## Regenerable derivatives

The ledger is the source of truth; everything built from it is derived and
can be regenerated at any time by re-scanning `signals/feedback.jsonl`
from the start — none of the following are themselves sources of truth,
and none may be hand-edited:

- `ranking-weights.json`'s outcome terms (phase 2, `calibrate.sh`)
- Regression eval cases under `evals/feedback/` (`feedback-to-evals.sh`)
- The `## Recent corrections` prompt block (`feedback-recent.sh` — read-only
  over `<store-dir>/signals/feedback.jsonl`, newest first, capped by `--n`;
  also renders `## Recent draft edits` via `--kind draft-edits`/`all`)
- Weekly report-card numbers (`report-card.sh`, phase 2)
- User-model revision proposals (`model-revision-proposals.sh`, phase 2)

If any derivative is lost or corrupted, it is rebuilt from the ledger, not
patched by hand.

## Contract reference

`packages/core/contracts/feedback-event.md` 1.0.0 is authoritative on the
JSON shape. Summary carried here for convenience (do not let this drift
independently — if the contract changes, this section is updated in the
same change):

- One JSON object per line: `ts`, `type`, `target`, `from`, `to`, `reason`,
  `text`, `channel`, `source`, in that key order.
- `type` enum: `dismiss | snooze | acted-on | done | opt-out |
  tier-correction | kind-correction | draft-edit | model-confirm |
  freeform`.
- `target` shape: `wakeup:<id> | person:<slug> | signal:<type> | model`.
- `source` enum: `reply | session | auto`.
- `from`/`to`/`reason`/`text`/`channel` are `null` when not applicable.
- `text`, when present, is the user's verbatim words.

## CLI

```
feedback-file.sh <store-dir> --type <enum> --target <target> --source reply|session|auto
                 [--from <v>] [--to <v>] [--reason <r>] [--text "<verbatim>"]
                 [--channel <c>] [--ts <ISO8601Z>]
exit 0 appended | 2 usage/enum error, nothing written
```

`--ts` defaults to `date -u +%Y-%m-%dT%H:%M:%SZ` (now, UTC) when omitted.
On success, prints `feedback: <type> <target>` to stdout and exits 0.

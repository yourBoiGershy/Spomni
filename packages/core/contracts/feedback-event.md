# Contract: feedback event

`schema_version: 1.2.0`

## Store location

`<store>/signals/feedback.jsonl` — one JSON object per line, append-only.
This is the single home for every piece of user feedback: dismissals,
snoozes, corrections to a person's tier or kind, replies to a nudge, and
confirmations of the user model. It is source of truth in the same sense as
`ranking-weights.md` (`contracts/ranking-weights.md`) — calibration weights,
eval cases, proposals, and report cards derived from feedback are all
regenerable from this log; the log itself is never derived and never
rewritten. Lines are appended in timestamp order and never edited or deleted.

## Writer / readers

- **Sole writer:** `packages/ingestion`'s `scripts/feedback-file.sh`. No
  other script writes to this file directly.
- **Sanctioned cross-package callers** (must be declared in the calling
  package's manifest as a consumer of `feedback-event@1.0.0`):
  - `packages/attention`'s `wakeup-queue.sh` — logs snooze/dismiss/confirm/
    decline/acted-on outcomes as they happen against a wake-up.
  - `packages/core`'s `person-set-tier.sh` / `person-set-kind.sh` — logs a
    feedback line only for stated (user-originated) writes, never for
    derived writes.
  - `packages/core`'s `person-merge.sh` — logs a `merge` event
    (1.2.0, plan 36) when the user confirms a person merge.
  - `packages/ingestion`'s review-tiers correction digest and
    `feedback-parse.sh` (reply parsing) — logs corrections, freeform
    replies, draft-on-demand requests (`draft-request`, plan 34 U8b), and
    `noise-sender` confirmations (1.2.0, plan 36) surfaced through those
    flows.
- **Readers:** `packages/ingestion` (`feedback-recent.sh`,
  `feedback-to-evals.sh`), `packages/attention` (`calibrate.sh`, proposal
  generation, the report card, `learn-sweep.sh` — cursor walk that calls
  ingestion's `feedback-to-evals.sh`, plan 36 D), `packages/query`
  (explaining "why did this change" / surfacing past feedback in answers).

## Semantics

Every user action that carries information about what the user wants —
dismissing a nudge, snoozing it, correcting a tier or kind, replying in
free text, confirming or declining a proposed model — becomes exactly one
line here, in the user's own words where words exist. This is the mechanism
that lets Spomni stop asking the user to re-explain themselves: corrections
and preferences are captured once, verbatim, and every downstream consumer
(weights, evals, the user model, proposals) reads from this log instead of
re-deriving intent from scratch. Feedback events never send anything and
never score the user — they are a record of what the user already said or
did.

## Shape

Newline-delimited JSON (JSONL). Each line is one JSON object; no other
structure (no frontmatter, no wrapping array).

### Fields

| Field | Type | Required | Notes |
|---|---|---|---|
| `ts` | ISO 8601 timestamp | yes | `YYYY-MM-DDTHH:MM:SSZ`. When the feedback event was recorded. |
| `type` | enum | yes | One of: `dismiss`, `snooze`, `acted-on`, `done`, `opt-out`, `tier-correction`, `kind-correction`, `draft-edit`, `model-confirm`, `freeform`, `draft-request`, `merge`, `noise-sender`, `stale-marked`. `draft-request` (1.1.0, plan 34 U8b) records a `<n> draft [free text]` reply — the user asking to be served the pre-composed draft (or told none exists) for a delivered card; it never carries the draft text itself (that lives only in the outbox file the reply-verb writes), only the fact that it was asked for and any free text the user attached. `merge` (1.2.0, plan 36) records a user-confirmed person merge — `target` is `person:<keep-slug>` and `from` is required, holding the dropped slug. `noise-sender` (1.2.0, plan 36) records the user confirming a held sender/pattern as noise — `target` is `sender:<pattern>`. `stale-marked` (1.2.0, plan 36) records the user marking a person's open thread or fact as stale/resolved — `target` is `person:<slug>` and `text` may hold the bullet text; this type is reserved for user corrections — machinery's own `unverified since` marking (plan 36 currency rule) never writes a feedback event. |
| `target` | string | yes | One of: `wakeup:<id>`, `person:<slug>`, `signal:<type>`, `model`, `sender:<pattern>` (1.2.0, plan 36 — `noise-sender` only). Identifies what the feedback is about. |
| `from` | string or null | yes (may be `null`) | The prior value, for corrections (e.g. a prior tier or kind). `null` when not applicable. For `merge` (1.2.0), required and holds the dropped slug (bare, no `person:` prefix). |
| `to` | string or null | yes (may be `null`) | The new value, for corrections or opt-outs. `null` when not applicable. |
| `reason` | string or null | yes (may be `null`) | A short machine-usable reason code (e.g. `not-this-signal-type`, `2w`) when the user's action implies one. `null` when none was given. |
| `text` | string or null | yes (may be `null`) | The user's verbatim words. Never rewritten, never summarized, never paraphrased — stated-by-user by definition. `null` when the feedback carried no free text (e.g. a bare snooze tap). |
| `channel` | string or null | yes (may be `null`) | Where the feedback arrived, e.g. `beeper-self`. `null` for feedback recorded directly in a session (not via a reply channel). |
| `source` | enum | yes | One of: `reply` (a message reply parsed into feedback), `session` (recorded during a live session, e.g. a tier correction made in conversation), `auto` (system-recorded outcome, e.g. `acted-on` inferred from a completed action, not a direct user statement). |

## Examples

```
{"ts":"2026-08-30T14:02:00Z","type":"dismiss","target":"wakeup:2026-08-30-jane-doe","from":null,"to":null,"reason":"not-this-signal-type","text":"I never do birthdays","channel":"beeper-self","source":"reply"}
{"ts":"2026-08-30T14:05:00Z","type":"tier-correction","target":"person:jane-doe","from":"active","to":"close","reason":null,"text":"she's basically family","channel":null,"source":"session"}
{"ts":"2026-08-30T14:06:00Z","type":"kind-correction","target":"person:bob-cpa","from":"friend","to":"transactional","reason":null,"text":"my accountant","channel":null,"source":"session"}
{"ts":"2026-08-30T14:07:00Z","type":"snooze","target":"wakeup:2026-08-30-sam-okafor","from":null,"to":null,"reason":"2w","text":null,"channel":"beeper-self","source":"reply"}
{"ts":"2026-08-30T14:08:00Z","type":"opt-out","target":"signal:linkedin-post","from":null,"to":"all","reason":null,"text":"never linkedin","channel":"beeper-self","source":"reply"}
{"ts":"2026-08-31T09:00:00Z","type":"acted-on","target":"wakeup:2026-08-30-sam-okafor","from":null,"to":null,"reason":null,"text":null,"channel":null,"source":"auto"}
{"ts":"2026-08-30T14:09:00Z","type":"freeform","target":"wakeup:2026-08-30-jane-doe","from":null,"to":null,"reason":null,"text":"actually let's talk about this next week","channel":"beeper-self","source":"reply"}
{"ts":"2026-08-30T14:10:00Z","type":"draft-request","target":"wakeup:2026-08-30-jane-doe","from":null,"to":null,"reason":null,"text":"mention the Tokyo race","channel":"beeper-self","source":"reply"}
{"ts":"2026-08-30T14:11:00Z","type":"merge","target":"person:jane-doe","from":"j-doe","to":null,"reason":null,"text":null,"channel":null,"source":"session"}
{"ts":"2026-08-30T14:12:00Z","type":"noise-sender","target":"sender:newsletter@example.com","from":null,"to":null,"reason":null,"text":null,"channel":null,"source":"session"}
{"ts":"2026-08-30T14:13:00Z","type":"stale-marked","target":"person:jane-doe","from":null,"to":null,"reason":null,"text":"waiting on her reply about the trip","channel":null,"source":"session"}
```

## Notes

- Versioning: `1.2.0` (plan 36) is additive — new types `merge`,
  `noise-sender`, `stale-marked`; new target vocabulary `sender:<pattern>`;
  `from` becomes required (not `null`) for `merge`. `1.1.0` (plan 34 U8b)
  added `draft-request`. `1.0.0` lines remain valid unmodified.
- `scripts/validate-store.sh` does not check this file — `signals/` is not
  one of the checked store types (people/interactions/wakeups only).
- Privacy: `signals/feedback.jsonl` lives only in the private store, never
  in this repo. The fixture at `fixtures/store/signals/feedback.jsonl` uses
  synthetic names only.
- `text` is the load-bearing field for the mission: it is what lets the
  agent stop re-asking the user things they already said. Any consumer that
  needs a machine-usable value should use `reason`/`from`/`to`, not attempt
  to parse `text`.
- This ledger's append-only, never-rewritten rule is what makes a
  line-count cursor (`<data-dir>/attention/learn-sweep.cursor`) exact — any
  tool that ever rewrote or reordered this file would silently break that
  cursor's meaning.

# Spec: outcome recording (wake-up lifecycle → wakeup@1.1 fields)

Status: Ready — implementation target for plan 06's `wakeup-queue.sh` and
`skills/sweep/`. Field names and enums are verbatim from
`packages/core/contracts/wakeup.md` (1.1.0); this spec adds no new fields, it
specs how attention (the sole writer of the lifecycle fields per that
contract and `docs/DECISIONS.md#attention-merge`) writes them.

## Scope

Two write paths:

1. **Lifecycle ops** (`wakeup-queue.sh fire|snooze|dismiss`) — synchronous,
   triggered by a queue action.
2. **Sweep step "acted-on detection"** — asynchronous, runs once per sweep
   after the fire step, over all `wakeups/*.md` with an open outcome.

Both mutate an *existing* `wakeups/<id>.md` file in place (appended state on
the file the `wakeup-add.sh` creation path already wrote) — never a new file,
per the "wakeups/ is retained history" note in plan 11.

Every lifecycle write (`snooze`/`dismiss`/`confirm`/`decline`/the sweep's
`acted-on: true` flips) also appends one `feedback-event@1` line via
ingestion's `feedback-file.sh` — the sole writer of `<store>/signals/
feedback.jsonl` (plan 34 D1). `wakeup-queue.sh` never writes the ledger
itself; it shells out to `feedback-file.sh` after its own file write
succeeds. Mapping:

| Lifecycle write | `--type` | `--reason` | `--source` |
|---|---|---|---|
| `snooze --days N` | `snooze` | `"Nd"` | `--source` flag (default `session`) |
| `snooze --until D` | `snooze` | `"until:D"` | `--source` flag (default `session`) |
| `dismiss --reason <enum>` | `dismiss` | `<enum>` | `--source` flag (default `session`) |
| `confirm --event-id …` | `acted-on` | `confirmed` | `--source` flag (default `session`) |
| `decline --reason <enum>` | `dismiss` | `<enum>` | `--source` flag (default `session`) |
| sweep flips `acted-on: true` | `acted-on` | (none) | `auto` |
| sweep flips `acted-on: false` (or leaves `null`) | — appends nothing — | | |

`snooze`/`dismiss`/`confirm`/`decline` also accept passthrough `--channel
<c>` and `--source reply|session` (default `session`); `dismiss` additionally
accepts passthrough `--text "<words>"` (the user's verbatim reply text, never
rewritten). A missing `feedback-file.sh` (fixture stores/tests run without
the ingestion package present) is not an error: `wakeup-queue.sh` prints
`feedback: skipped (feedback-file.sh absent)` and continues; a ledger write
that fails for any other reason prints `feedback: ledger write failed (exit
n)` and does not alter the lifecycle op's own exit status. Attention keeps
sole ownership of `wakeups/`; only ingestion's `feedback-file.sh` writes the
ledger.

## 1. Lifecycle ops

### `fire`

Preconditions: entry has `status: pending` (or `status: snoozed` if a snooze
window elapsed and the sweep is re-evaluating it — same as today's fire path,
unchanged by this spec).

Writes, atomically with the existing status change:

- `status: fired`
- `fired-on: <today's date, YYYY-MM-DD>` — only if `fired-on` is currently
  `null`. If `fired-on` is already set (a re-fire of an entry that was
  snoozed and is firing again), leave it untouched — `fired-on` records the
  *first* time this entry fired, so the 7-day acted-on window in section 2
  below is anchored to a stable date. (This also makes `fire` idempotent per
  plan 06's proof-of-done: re-running `fire` on an already-fired entry with a
  non-null `fired-on` is a no-op on that field, and the CLI should skip
  re-writing `status`/emitting a second batch artifact for an entry already
  at `status: fired`.)

No other fields change on `fire`.

### `snooze <duration>`

Existing behavior (unchanged by this spec): re-write `due` forward by
`<duration>`, reset `status: pending`.

New in 1.1.0: increment `snooze-count` by exactly 1 as part of the same
write (missing/`null` `snooze-count` on a pre-1.1.0 file is treated as `0`
before incrementing, per the contract's default). `fired-on` is untouched by
snooze (an entry can be fired, then — via a follow-up "remind me again" ask
— snoozed; `fired-on` still records when it first fired, not when it was
snoozed).

### `dismiss`

**Requires `--reason <enum>`** where `<enum>` is one of the four
`dismiss-reason` values from the contract:

- `not-now`
- `not-this-person`
- `not-this-signal-type`
- `already-handled`

`wakeup-queue.sh dismiss <id>` invoked without `--reason` or with a value
outside this enum is a hard CLI error (nonzero exit, no write) — there is no
default. Given a valid reason, write in the same operation as the status
change:

- `status: dismissed`
- `dismiss-reason: <the given enum value>`

If the target file is `schema_version: 1.0.0` (predates these fields),
upgrade it to `schema_version: 1.1.0` when writing `dismiss-reason` (the
contract's Notes section: "new dismissals should upgrade the file to 1.1.0
when writing the reason"). Do not otherwise touch a 1.0.0 file's other
fields when upgrading — only add the schema_version bump and the fields this
spec's operation writes.

## 2. Sweep step: acted-on detection

New sweep step, ordered after "fire due wake-ups" and before "calibrate"
(plan 11 unit 9) in `skills/sweep/SKILL.md`'s pipeline. Runs once per sweep
invocation over every file in `wakeups/`.

### Selection

Consider a wakeup entry a candidate for this step iff:

- `fired-on` is non-null, **and**
- `acted-on` is currently `null` (never re-evaluate a decided entry — see
  Idempotency below).

Entries with `fired-on: null` (never fired) are skipped — `acted-on` stays
`null` on them indefinitely, per the contract's default.

### Decision

For each candidate, compute the window `(fired-on, fired-on + 7 days]`
(exclusive of `fired-on` itself, inclusive of the 7th day after) and scan
`interactions/*.md` for any interaction where:

- `date` falls inside that window, **and**
- `people` contains at least one `[[slug]]` that also appears in the
  wakeup's `people` list (any overlap qualifies — a wakeup about two people
  where only one of them shows up in a filed interaction still counts).

Then:

- **If a qualifying interaction exists** (found at any point, even before
  the 7-day window has fully closed): write `acted-on: true` immediately.
  Do not wait for the window to close once a match is found — a fast
  follow-up shouldn't sit at `null` for days when the answer is already
  known.
- **Else if today's date is past the window close** (`today >
  fired-on + 7 days`, i.e. the window has fully elapsed with no match):
  write `acted-on: false`.
- **Else** (window still open, no match yet): leave `acted-on: null`,
  unchanged — re-evaluate on the next sweep run.

### Idempotency

Once `acted-on` is non-null (`true` or `false`), this step MUST NOT touch
that entry again — a later interaction appearing after `acted-on: false` was
already written does not flip it back to `true`, and a later dismiss/snooze
of an already-`true` entry does not reset it. Idempotent means: re-running
the sweep any number of times against the same `wakeups/` + `interactions/`
state produces the same file contents, and running it again after new
interactions are filed only ever changes entries currently at `acted-on:
null`.

Per the Scope section above: writing `acted-on: true` also appends one
`feedback-event@1` line (`--type acted-on --source auto`, no `--reason`) via
ingestion's `feedback-file.sh`. Writing `acted-on: false` — or leaving it
`null` because the window is still open — appends nothing to the ledger.

## 3. `wakeup-queue.sh` CLI surface deltas (for plan 06)

| Op | Signature (unchanged parts elided) | Delta from pre-1.1.0 behavior |
|---|---|---|
| `list-due` | `wakeup-queue.sh list-due [--window <n>d]` | No change. Still reads `due`/`status` only; new fields are opaque to it. |
| `fire` | `wakeup-queue.sh fire <id>` | Now also sets `fired-on` (only if currently `null`); no new flags. |
| `snooze` | `wakeup-queue.sh snooze <id> <duration>` | Now also increments `snooze-count` (treating missing/`null` as `0`); no new flags. |
| `dismiss` | `wakeup-queue.sh dismiss <id> --reason <enum>` | `--reason` becomes a **required** flag (was previously reason-less or free-text, per whatever pre-1.1 shape existed); invalid/missing value is a hard error, no write. |

`snooze`/`dismiss`/`confirm`/`decline` (plan 34 D1) also take optional
`--channel <c>` and `--source reply|session` (default `session`);
`dismiss` also takes optional `--text "<words>"` — all three passthrough
to the `feedback-file.sh` ledger append described in Scope above.

Sweep entry point (`skills/sweep/SKILL.md`) gains one new pipeline step,
"acted-on detection," positioned: `... → fire due wake-ups → acted-on
detection → calibrate (unit 9) → deliver via output adapter`. It reads
`wakeups/*.md` and `interactions/*.md` only; it does not touch `due`,
`status`, `dismiss-reason`, or `snooze-count`.

## Non-goals

- This spec does not touch `ranking-weights.json` or the calibrate step
  (plan 11 unit 9, a sibling spec) — acted-on detection only writes the
  `acted-on` field on `wakeups/*.md`; calibration is a separate, later sweep
  step that *reads* the outcome fields this spec produces.
- No opt-out/profile.md interaction here — `profile.md` Signal opt-outs are
  applied at signal-scan (plan 05) before a wakeup is even created; this
  spec starts from an already-existing `wakeups/<id>.md`.
- This spec does not change `wakeup-add.sh` (creation) — only the lifecycle
  ops attention owns per the contract's writer table.

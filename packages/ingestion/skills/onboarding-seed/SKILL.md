---
name: onboarding-seed
description: One-shot, session-driven onboarding pass — backfills the three direct lanes over a configured window, files the resulting history (deterministically for calendar/metadata-only email, via the model only for free text), then hands off to `/review-tiers --all` in cold-start mode to auto-adopt a provisional user-model and write derived kinds + tiers, ending in a correction digest. No tier or kind is withheld pending confirmation — every write this run makes is labeled `derived` until the user corrects it.
---

# Onboarding seed

Sequences `packages/ingestion/specs/onboarding-tiering-seed.md` end to end
for a fresh install: three lane backfills → deterministic structured filing
→ model filing for what's left → `/review-tiers --all` cold start (derived
user-model, derived kinds + tiers, correction digest). This document is the
session's runbook; the spec is the model of record — where this document
and the spec disagree, the spec wins.

Invoked explicitly only ("run onboarding seed" / "run the onboarding
backfill"), typically once, at first-run onboarding. It is not a scheduled
job and does not queue itself for a later pass — see the Summary section's
"one session, not a backlog" rule below.

## Hard rules (binding, restated from the spec — read before running)

- **Draft, never send** applies as everywhere else — this skill only reads,
  derives, and writes labeled-derived `kind`/`tier` values. It never
  contacts anyone.
- **Every tier/kind written this run is labeled `derived`** (`tier_source:
  derived` / `kind_source: derived`, per `packages/core/contracts/
  person.md` 1.2.0) and is shown, one line per person, in the correction
  digest that ends `/review-tiers --all` — nothing here is written silently
  or withheld pending a per-person confirmation.
- **A stated correction always outranks derived**, at any time, not just
  in this session. Correcting any line in the digest (or any other
  explicit stated-tier/kind utterance, this session or a later one) writes
  `stated-by-user` and sticks — a `--source derived` write can never
  overwrite it (`person-set-tier.sh`/`person-set-kind.sh` both exit 2 on
  that attempt).
- **Skips and silence write nothing further.** Not reacting to a digest
  line leaves that person's `derived` write exactly as it stands — no
  additional write, no re-prompt, no "you still have N to review"
  resurfacing later.
- **No-guilt framing is binding**, not a style suggestion: never phrase a
  derived tier/kind as "you've been neglecting X" or similar; a `dormant`
  or low-warrant read is a neutral read of observed frequency, not a
  verdict.
- **Never enumerate excluded people.** Anyone outside `/review-tiers
  --all`'s scope or cap is not listed, not flagged as "still needs
  attention," and is not queued for a later pass.

## Step 0 — resolve and announce the window; check for `self` identities

Before running any sweep, resolve the active backfill window:

```sh
bash packages/connectors/scripts/resolve-backfill-window.sh <data-dir>
```

This prints `window_start_iso<TAB>window_months` on success (defaulting to
6 months when `<data-dir>/config/onboarding-backfill.tsv` or its
`window_months` key is absent), or exits non-zero with a stderr reason on a
malformed config — on failure, **stop here** and surface that stderr
verbatim; do not guess a window or fall back silently.

Tell the user:

- The resolved window (e.g. "backfilling the last 6 months"), and that it's
  configurable by editing `<data-dir>/config/onboarding-backfill.tsv`'s
  `window_months` row (`packages/core/contracts/onboarding-backfill.md`).
- That Step 4's participation derivation needs at least one `self` row in
  that same file (their own email address(es) / messaging handle(s),
  verbatim) to tell their own outgoing messages apart from everyone else's
  — and that `derive-participation.sh` **fails closed** (aborts, no
  suggestions) with zero `self` rows resolved. If the file has none yet,
  prompt them to add one or more `self<TAB><identity>` rows now, before
  continuing to Step 1.

## Step 1 — run the three lanes' backfill modes

One-shot, explicit invocation of each lane's backfill mode — never the
incremental/scheduled path. Beeper runs concurrently with the
session-driven gmail/calendar backfills (D5): launch it as a background
process first, then run gmail and calendar in the same user session —
those two stay **serial with each other**, since both are first-party-MCP
session-driven skills sharing the one session (unchanged constraint from
plan 26).

- **Beeper (background):**
  ```sh
  bash packages/connectors/beeper-in/scripts/beeper-sweep.sh --backfill \
    > <log-file> 2>&1 &
  ```
  (optionally `--data-dir <dir>` if not running from the default
  location). Launch this first, note the PID and `<log-file>` path, then
  proceed immediately to gmail below — do not wait on it here.
- **Gmail:** run `packages/connectors/gmail-in/skills/gmail-sweep/SKILL.md`
  in backfill mode ("run gmail-sweep in backfill mode") — see that
  document's own "Backfill mode" section for window resolution, dedup
  isolation, and its own summary line. Do not re-specify it here.
- **Calendar:** run
  `packages/connectors/calendar-in/skills/calendar-sweep/SKILL.md` in
  backfill mode ("run calendar-sweep in backfill mode") — same isolation
  and window-resolution rules as gmail's, in that document. Run this after
  gmail finishes (serial), not concurrently with it.

All three resolve the same window via `resolve-backfill-window.sh` and
write into their own isolated backfill checkpoint/ledger state, never
touching their incremental-lane counterparts.

**Shared-file hazard check (verified non-hazards for running beeper
concurrently with gmail/calendar).** The three lanes' backfill state lives
in disjoint per-lane directories with no overlapping filenames: beeper
writes only `data/connectors/beeper-in/backfill-cursors.tsv` and
`data/connectors/beeper-in/backfill-last-sweep`; gmail writes only
`data/connectors/gmail/backfill-checkpoint` and
`data/connectors/gmail/backfill-processed.log`; calendar writes only
`data/connectors/calendar/backfill-processed.log` (and, incremental-only,
`skipped-calendars.log` in that same lane directory — never touched by
another lane). None of the three ever read or write another lane's
directory. The one shared surface is `inbox/`, and it is safe for
concurrent writers: it is append-only (`packages/core/contracts/
capture-event.md`), and each lane produces its own `id` embedding the
source (`<captured_at-compact>-<source>-<short-rand>`, e.g.
`...-beeper-in-...` vs `...-gmail-in-...`), so concurrent writers can never
collide on a filename; `archive/raw/` likewise holds exactly one file per
capture id, so no two lanes ever contend for the same raw-archive path.

**Beeper completion check before Step 2.** Before moving on, confirm the
backgrounded beeper process has actually finished — tail `<log-file>` for
its outcome line and check the process's exit status (e.g. `wait <PID>` if
still in the same shell, or re-check the PID/log if not) — this is the
deadman check for the background lane; do not proceed to Step 2 on the
assumption it finished just because gmail/calendar did. Let each lane
complete (or report its own per-lane failures/warnings) before moving to
Step 2 — a partial or failed lane is not fatal to the others; note what
backfilled and what didn't in the eventual summary.

## Step 2 — file the backfilled history

Four sub-steps, in order, over whatever new `inbox/` capture events the
three backfill sweeps just landed. Expect hundreds of structured
(calendar/metadata-only-email) events to file deterministically in under
30 seconds; chat-message events go through sub-step (c)'s one-call-per-
thread path (plan 32), never the debrief skill's per-day model pass; the
debrief path (sub-step d) only ever sees non-chat free text — email
bodies, voice notes, and whatever structured events (a)/(b) held.

**(a) Triage.**

```sh
bash packages/ingestion/scripts/triage-inbox.sh <store-dir> --data-dir <data-dir>/ingestion
```

Note: `triage-inbox.sh`'s `--data-dir` names the **ingestion dir** directly
(it writes `<dir>/triage-held.log`), while `file-structured.sh` below takes
the **data root** and reads `<dir>/ingestion/triage-held.log` itself — the
two scripts' `--data-dir` meanings differ; do not "fix" this line to match
sub-step (b)'s form.

Deterministic, no-model pre-judgment hold pass (`specs/import-triage.md`);
populates `data/ingestion/triage-held.log` so neither (b) nor (c) spends
judgment re-deciding a class of event this pass already, conservatively,
held out.

**(b) Deterministic structured filing.**

```sh
bash packages/ingestion/scripts/file-structured.sh <store-dir> --data-dir <data-dir>
```

Files every eligible `calendar-event` and metadata-only gmail event with no
model call — templated person/interaction writes only, per
`specs/structured-filing.md`. Report its summary line verbatim
(`file-structured: eligible= filed= people_new= held= skipped=`) as part of
this run's own summary. Anything it can't resolve deterministically (an
ambiguous name hint, an email with no name and no existing person) is
appended to `data/ingestion/structured-held.log` for sub-step (d), never
silently merged.

**(c) Threads: one model call per chat, deterministic episodes.**

Plan 32: chat-message captures are filed through one model call per thread
plus a deterministic writer, not through the debrief skill's per-day
episode-split model pass — a running-cost cut only (one summarize call and
one script pass replace a per-day agentic filing task per thread).

```sh
# ids still eligible (not in debrief-filed.log / triage-held.log) whose type is chat-message:
for f in $(<eligible chat-message capture files>); do
  bash packages/ingestion/scripts/summarize-thread.sh "$f" --out <data-dir>/ingestion/thread-summaries/$(basename "$f" .md).json
done   # run with xargs -P 6; ~10–30 s per thread, dominated by CLI startup; RA_THREAD_MODEL=haiku default
for j in <data-dir>/ingestion/thread-summaries/*.json; do
  bash packages/ingestion/scripts/file-thread.sh <store-dir> <store-dir>/inbox/$(basename "$j" .json).md "$j" --data-dir <data-dir>
done
```

Then one `build-index.sh` + `validate-store.sh` for this sub-step, same as
any other filing pass.

- `file-thread.sh` unions captures sharing a chatID (D3) so duplicates never
  double-file — a rerun over the same capture(s) is a true no-op once every
  contributing id is ledgered.
- A summary with `skip` set (bots/broadcasts/self-notes/security notices
  only) ledgers the id with no writes.
- A stranger's cold pitch is filed as a person with `role_guess: unsolicited`
  and tag `linkedin-outreach` (D4) — never skipped.
- No `tier`/`kind` is written by this sub-step — filing carries no tier or
  kind opinion, same rule as (b) and (d).
- Exit codes from `summarize-thread.sh`: `3` = model/timeout, `4` = schema
  failure — retry once, then leave the id pending (it stays eligible for a
  later pass; it is not added to any ledger on either failure).

Spec of record: `packages/ingestion/specs/thread-summary.md` (the model
call's contract); `file-thread.sh`'s own header comment (episodes, person
upsert, ledger) for the deterministic writer's rules.

**(d) Debrief the remainder** — the old (c): only non-chat free text (email
bodies, voice notes, linkedin-notification, `other`) plus
`structured-held.log` ids remain for the normal filing/debrief path
(`packages/ingestion/skills/debrief/SKILL.md`); shard mode per
`specs/parallel-filing.md` only if more than ~40 events remain. This
produces `people/<slug>.md` (new people as needed) and `interactions/*.md`
files. No `tier` is set by this step — filing carries no tier opinion, per
the spec.

## Step 3 — build stats

```sh
bash packages/core/scripts/build-stats.sh <store-dir>
```

Produces `<store-dir>/stats.json` (`packages/core/contracts/derived-index.md`)
fresh from the just-filed `people/`/`interactions/` state.

## Step 4 — derive participation, then run review-tiers cold start

```sh
bash packages/ingestion/scripts/derive-participation.sh \
  <store-dir> <store-dir>/stats.json <window-start-iso> \
  <data-dir>/config/onboarding-backfill.tsv
```

`<window-start-iso>` is the same value Step 0 resolved. Read-only, writes
nothing to the store; fails closed with a clear stderr reason if zero
`self` identities resolved from the config (Step 0 should have already
caught this, but treat a failure here the same way: stop, surface the
stderr, do not guess).

Then hand off to the cold-start review pass:

```
/review-tiers --all
```

On a fresh install `user-model.md` is absent, so review-tiers' own Step 1
derives it and auto-adopts `status: provisional` with no dialogue (D6 —
the confirm dialogue only ever runs on explicit `--confirm-model`, never
from this skill). Its own Step 3 writes both a derived `kind` and a
derived `tier` for every person that clears its scope/gate, and its Step 4
ends with a correction digest (one line per person, breakdown string
attached, no question that blocks) instead of a batch requiring per-person
confirm/adjust/skip before anything is written — see
`packages/ingestion/skills/review-tiers/SKILL.md` /
`packages/ingestion/specs/review-tiers.md` for that flow's own rules,
which this skill does not restate. Any correction the user makes against
the digest, here or later, writes `stated-by-user` and outranks the
derived value permanently.

**`suggest-tiers.sh` is not run by default.** It remains available only as
an optional, read-only diagnostic (`packages/ingestion/scripts/
suggest-tiers.sh <store-dir>/stats.json <participation-tsv-path>
<window-start-iso>`) for comparing the legacy frequency-only score against
`/review-tiers --all`'s semantic judgment; it writes nothing and this skill
does not invoke it.

## Summary

End with a short summary:

- Window used.
- Per-lane backfill outcome (counts, or "skill run — see its own
  summary").
- Structured filing (b): the `file-structured.sh` summary line verbatim
  (`eligible= filed= people_new= held= skipped=`).
- Thread filing (c): count of chat-message events summarized + filed via
  `summarize-thread.sh`/`file-thread.sh`, and count left pending on a
  retried model/schema failure, if any.
- Debrief filing (d): count of events debrief filed.
- Totals: people/interactions counts in the store after Step 2.
- `/review-tiers --all`'s own summary: derived tiers/kinds written,
  provisional user-model adopted (yes/no, revision), corrections applied
  this session.

Do not summarize or enumerate the untiered/excluded/skipped set beyond a
bare count — no per-person callout, per the no-guilt rule above.

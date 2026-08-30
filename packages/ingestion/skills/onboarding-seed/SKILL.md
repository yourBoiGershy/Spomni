---
name: onboarding-seed
description: One-shot, session-driven onboarding pass — backfills the three direct lanes over a configured window, files the resulting history, computes deterministic tier suggestions from frequency + participation signals, and presents them once for the user to confirm/adjust/skip. Never writes a tier without explicit per-person confirmation.
---

# Onboarding seed

Sequences `packages/ingestion/specs/onboarding-tiering-seed.md` end to end
for a fresh install: three lane backfills → normal filing → `stats.json` →
participation derivation → deterministic tier scoring → one batched,
human-confirmed presentation. This document is the session's runbook; the
spec is the model of record — where this document and the spec disagree,
the spec wins.

Invoked explicitly only ("run onboarding seed" / "run the onboarding
backfill"), typically once, at first-run onboarding. It is not a scheduled
job and does not queue itself for a later pass — see Step 5's "one session,
not a backlog" rule below.

## Hard rules (binding, restated from the spec — read before running)

- **Draft, never send** applies as everywhere else — this skill only reads,
  derives, and (after confirmation) writes `tier`. It never contacts anyone.
- **No tier is ever written without the user's explicit, per-person
  confirmation in Step 6.** A suggestion is a suggestion; nothing in Steps
  0–5 writes to `people/<slug>.md`.
- **Stated always outranks derived.** Every value this skill computes
  (base band, `user-engaged`, `co-attended`, `silent-group`,
  `never-answered`, the final score) is a derived suggestion — it carries no
  weight against anything the user has separately, explicitly stated about
  a person's tier.
- **A skip writes nothing, now or automatically later.** Same for anyone
  excluded by the insufficient-data gate or left out by the 20-person cap.
  Ending the session partway through the batch is treated exactly like a
  skip for everyone not yet acted on — there is no resumed prompt, no
  "you still have N people to review," ever, from this pass.
- **No-guilt framing is binding**, not a style suggestion: never phrase a
  suggestion as "you've been neglecting X" or similar; a `dormant` or
  `never-answered` suggestion is a neutral read of observed frequency, not a
  verdict. Never single out or flag excluded/capped/skipped people as
  "still needs attention" anywhere in this session's output.

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

Run the normal filing/debrief path over whatever new `inbox/` capture
events the three backfill sweeps just landed —
`packages/ingestion/skills/debrief/SKILL.md`, unchanged, exactly as it
runs for any other capture event. This produces `people/<slug>.md` (new
people as needed) and `interactions/*.md` files. No `tier` is set by this
step — filing carries no tier opinion, per the spec.

## Step 3 — build stats

```sh
bash packages/core/scripts/build-stats.sh <store-dir>
```

Produces `<store-dir>/stats.json` (`packages/core/contracts/derived-index.md`)
fresh from the just-filed `people/`/`interactions/` state.

## Step 4 — derive participation, then score suggestions

```sh
bash packages/ingestion/scripts/derive-participation.sh \
  <store-dir> <store-dir>/stats.json <window-start-iso> \
  <data-dir>/config/onboarding-backfill.tsv

bash packages/ingestion/scripts/suggest-tiers.sh \
  <store-dir>/stats.json <participation-tsv-path> <window-start-iso>
```

`<window-start-iso>` is the same value Step 0 resolved. Pipe or redirect
`derive-participation.sh`'s stdout to a file (or a variable) to hand to
`suggest-tiers.sh` as `<participation-tsv-path>`. Both scripts are
read-only and write nothing to the store; `derive-participation.sh` fails
closed with a clear stderr reason if zero `self` identities resolved from
the config (Step 0 should have already caught this, but treat a failure
here the same way: stop, surface the stderr, do not guess). `suggest-tiers.sh`
emits the deterministic suggestion batch, one row per presentable person,
already gated (`touchpoints >= 2`), scored, and ordered (score descending,
`median_gap_days` ascending, `touchpoints` descending, slug ascending),
capped at 20 rows.

## Step 5 — present the batch once

Present every row `suggest-tiers.sh` emitted, in the order it emitted them
(warmest/most-engaged first), each with its full breakdown string verbatim
(`suggested: <tier> | base: <band> (median_gap_days=<n>) | signals: ...` or
`| class: silent-group (low)` / `| class: never-answered (very low)`).

Binding presentation rules (state these to yourself as constraints on the
wording you use, not just as documentation):

- **One session, not a backlog.** All suggestions from this run are shown
  together, once, in this single pass. There is no follow-up prompt for
  anyone not gotten to — no "you still have N people to review" resurfacing
  later, ever.
- **No-guilt framing.** Never phrase a suggestion as "you've been
  neglecting X" or anything guilt-inflected. A `dormant` or
  `never-answered` suggestion is a neutral read of observed contact
  frequency, not a verdict on the relationship or the user.
- **Never flag the excluded.** People excluded by the insufficient-data
  gate (`touchpoints < 2`) or left out by the 20-person cap are not
  mentioned as needing attention, are not listed as a "still to do" tail,
  and are not queued for a later pass. Silence about them is correct.

## Step 6 — per person: confirm / adjust / skip

For each presented person, one of three explicit actions:

- **Confirm** the suggested tier as-is.
- **Adjust** to any of the four tier values (`inner-circle`, `close`,
  `active`, `dormant`) — not just an adjacent one; the suggestion is a
  starting point, not a constraint.
- **Skip** — no tier is set for this person, now or ever automatically
  later.

**Only on explicit per-person confirmation** (confirm or adjust — both are,
at the filing layer, the same event: an explicit user-stated tier value for
a named, unambiguous, already-resolved person), file the write via
`packages/ingestion/specs/stated-preference-filing.md` (a).2 — the existing
person's frontmatter `tier` overwrite, unambiguous, since every presented
slug already resolved out of `stats.json`/`people/`, not free text. (a).4,
the new-person flow, is not the expected path here (everyone in the batch
already has a person file by Step 2) but remains the correct fallback if a
presented slug's person file is ever missing at write time.

**State this verbatim to the user before the batch, and hold to it:**

- No tier is ever written without that person's explicit confirmation.
- A skip writes nothing — not now, not automatically later.
- Ending the session mid-batch is treated as a skip for everyone not yet
  acted on.
- Every suggestion here is derived from observed backfilled behavior, not
  from anything stated — stated tiers, whenever given (in this session or
  any other), always outrank these suggestions.

## Summary

End with a short summary: window used, per-lane backfill outcome (counts or
"skill run — see its own summary"), how many people cleared the gate, how
many were presented (capped at 20 if more cleared), and how many were
confirmed / adjusted / skipped in this session. Do not summarize or
enumerate the untiered/excluded/skipped set beyond a bare count — no
per-person callout, per the no-guilt rule above.

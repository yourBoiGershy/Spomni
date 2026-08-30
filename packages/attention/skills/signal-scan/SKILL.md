---
name: signal-scan
description: Run every detector in fixed order over a store, write signal-event@1 candidates to `wakeups/signals/`, rank them per `specs/ranking.md`, and promote the winners into `wakeups/*.md` nudges with ammunition, via `wakeup-add.sh` only.
---

# signal-scan

The scout half of `packages/attention` (plan 05). Runs a store's detector
set — ToS-clean, read-mostly — end to end: detect, log every candidate as a
`signal-event@1` file, rank per `packages/attention/specs/ranking.md`, and
promote the winners under the sweep's budget into wake-ups a human can act
on. This skill never sends anything and never writes `people/`,
`interactions/`, or `profile.md` — draft-never-send and single-writer hold
throughout (`CLAUDE.md`).

## 1. Inputs & preflight

- `<store-dir>` — the private data dir.
- Scan date ("today") — defaults to the current date, overridable by the
  caller (e.g. `--today YYYY-MM-DD`, matching the fixture's `2026-09-01`
  anchor).
- **Stats freshness.** If `<store-dir>/stats.json` is missing, or older
  (mtime) than the newest file under `<store-dir>/interactions/`, run
  `bash packages/core/scripts/build-stats.sh <store-dir>` before doing
  anything else — every detector and the whole of `ranking.md` §1 reads
  `stats.json`'s `tier`/`touchpoints`/`last_interaction`/`median_gap_days`
  rollup, never recomputing it inline.
- Read `<store-dir>/profile.md` `## Signal opt-outs` once, up front — every
  detector below consults this same read for its own opt-out gate (per
  `ranking.md` §9's general gate table and each detector spec's own
  variant).
- Read `<store-dir>/signals/week-plan.json`. If absent, or its
  `generated_at` is more than 8 days old, treat it as stale: log the
  fallback (`ranking.md` §8 rule 1: `weekly_tier: normal`,
  `budget.max = 3`) and proceed — this skill never calls
  `packages/attention/scripts/capacity.sh` itself; recomputing the week
  plan is `weekly-planning`'s job alone (single-writer rule).
- Read `<store-dir>/ranking-weights.json` if present — the multiplier
  source for `ranking.md` §5's `weight(signal-type)`/`weight(tag)` terms;
  absent entries (or an absent file entirely) default every weight to
  `1.0`.

## 2. Detector order (fixed)

Run in this order, every sweep, over the full `people/*.md` set (or the
relevant subset each detector's own spec scopes, e.g. company-news's
top-N-by-warmth). For each detector: what it reads, its opt-out/dedup
gates, and its signal-event write. Every detector writes directly to
`<store-dir>/wakeups/signals/<id>.md` in the `signal-event@1` shape below
— hand-written, there is no `signal-add.sh` (each detector is the sole
writer of its own append-only log entries, per
`packages/core/contracts/signal-event.md`'s writer table naming
`packages/attention`).

**`signal-event@1` shape** (every detector writes this frontmatter-only
file, no body):

```yaml
schema_version: 1.0.0
id: <detected_at-compact>-<type>-<slug>
type: <detector's type>
person: ["[[slug]]", ...]
evidence: >
  <free text, provenance-labeled, self-sufficient — see each detector spec's
  "Evidence format">
confidence: low|medium|high
detected_at: <ISO 8601 Z>
```

### debrief-harvest

Reads, per person within the trailing 60 days: `needs-follow-up` markers on
`people/<slug>.md` facts or interaction summaries, `user:`-owned
`## Commitments` bullets, and stale (≥30-day) `## Open threads` bullets
(`specs/debrief-harvest.md` Inputs/Detection rule). Opt-out
(`debrief-harvest — all`/`— [[slug]]`) is checked **before** writing —
an opted-out person produces no signal event at all, unlike most other
detectors (`specs/debrief-harvest.md` Opt-out/dedup gates). Dedup: skip if
a `debrief-harvest` signal for the person exists within the trailing 30
days. At most one combined signal event per person per scan, confidence =
the highest contributing tier, evidence lines concatenated per the spec's
Evidence format.

### scheduling-intent

Reads filed `interactions/*.md` `## Summary`/`## Commitments` within the
trailing 14 days for scheduling language (`specs/scheduling-intent.md`,
mirrored by `skills/scheduling-intent/SKILL.md` steps 1–2). The signal
event is written **unconditionally**, before any opt-out or suppression
check, for every detected mention (step 3) — except a person still inside
the 30-day re-proposal suppression window (a prior `dismissed` proposal
for them, per step 5), for whom the check runs first and produces total
silence, no signal event at all. `low`-confidence mentions stop after the
signal event (step 4, no promotion). `medium`/`high` mentions then pass
the opt-out gate (`scheduling-intent — all`/`— [[slug]]`, which silences
promotion only, not the already-written signal event) and the
deterministic slot search (step 7) before promoting via step 8.

### co-attendance

Reads filed interactions carrying the same-event-as marker for a shared
`calendar-event` id, and/or `calendar-event` capture events in `inbox/`
whose attendees resolve to ≥2 known people, over the trailing 7 days
(`specs/co-attendance.md` Inputs/Detection rule). Signal `person` names
the pair (or, for a one-side-resolved match, just the one known person at
`low` confidence). Opt-out (`co-attendance — all`/`— [[slug]]`, atomic —
one opted-out person in a pair suppresses the whole pair) is checked
before emission. Dedup key is the unordered pair **plus** the
`calendar-event` id (not the pair alone) — a second, different event for
the same pair within 30 days is a fresh signal by design, feeding the
two-signal rule. Events with >8 resolved attendees are skipped and logged
as conference-scale, never emitted.

### job-change

Reads new `type: linkedin-notification` capture events matched to a
person, the newest `type: email`'s signature block diffed against stored
`org`/`role`, and — as verification only, never discovery — one web
search per candidate move using the mandatory `"<full name>" "<new org>"`
template (`specs/job-change.md` Inputs/Detection rule; ToS-clean, no
scraping/enrichment). Opt-out (`job-change — all`/`— [[slug]]`) is checked
before the signal event is written — an opted-out person produces no
artifact at all. Dedup: skip a fresh `job-change` signal for a person if
one already exists within the trailing 30 days; a later corroboration
folds into the existing signal's promotion evidence rather than minting a
new event. `low`-confidence (web-search-only) signals are written but
never promote alone.

### company-news

Reads the top-N-by-warmth (`N` default 25) contacts with a non-empty
`org`, fans a search pass out per distinct `org` (harness WebSearch tool +
SEC EDGAR full-text search + any saved `type: other`, `source: web-search`
`inbox/` entries), gated first by the name-disambiguation check
(`specs/company-news.md` Detection rule 1 — an ambiguous org with no
role/city disambiguator is skipped and logged, never guessed). Opt-out
(`company-news — all`/`— [[slug]]`) suppresses fan-out to that person only;
the org may still be searched for other non-opted-out people at the same
org. Dedup: skip the search pass for an org with a `company-news` signal
already emitted within 30 days. One signal event per org per pass, fanned
out to every qualifying person at that org (not one per person). Capped
at 25 searches/scan, warmth-ordered; overflow orgs simply carry to the
next sweep. Running offline (fixtures): saved `source: web-search` inbox
items stand in for the live search/EDGAR calls.

### tier-drift

Plan 30's two-phase prefilter + judgment procedure (`specs/tier-drift.md`
"## Prefilter" / "## Judgment verdict", transcribing
`packages/core/contracts/relationship-scoring.md`'s kind vocabulary and
Drift-prefilter section — this step does not restate those numbers a third
time). Opt-out (`tier-drift — all`/`— [[slug]]`) is checked **first**,
before candidate-building — suppressing emission entirely (no signal event
at all, no judgment call spent) for an opted-out person.

1. **Build candidates (deterministic, no model call).** Read per-person
   evidence via `packages/ingestion/scripts/derive-evidence.sh <store>` when
   that script is on `PATH`; else fall back to `index.json`'s `kind`/
   `kind_expires`/`kind_source` columns plus `stats.json`'s
   `last_interaction`/`touchpoints`/`median_gap_days` (say which path was
   used in the run log — the fallback is a degraded-evidence mode, not
   silent). For each person with a `tier` set:
   - Resolve `kind` (unkinded → `professional`, horizon 120, and the
     eventual proposal must disclose `"no kind on file — professional
     horizon assumed"`).
   - Drop no-rhythm kinds (`community`, `scheduling`, `transactional`,
     `unsolicited`, `unknown`) and any kind whose `kind_expires` is in the
     past — neither enters candidacy, regardless of tier.
   - **QUIET candidacy:** `days_since_last` (from the evidence source above)
     exceeds the kind's horizon (`friend`/`family` 30, `collaborator` 14,
     `professional` 120). `dormant` tier never quiet-drifts (floor,
     unchanged from the retired table).
   - **UPWARD candidacy:** rhythmed kinds only; trailing-90-day
     `interactions[].date` touchpoint count is elevated relative to what
     the current tier implies — the prefilter only requires a non-trivial
     elevation to admit the person to judgment; the actual "is this really
     elevated for this kind/tier/user" call is the judgment step's job, not
     this deterministic pass's.
2. **Judge each candidate.** One judgment record per candidate
   (`relationship-scoring.md` "## Judgment record":
   `attention_warrant`, `suggested_tier`, `kind`, `kind_note`, `rationale`,
   `confidence`), reading: the evidence line from step 1; `people/<slug>.md`
   and its filed interaction summaries; the confirmed
   `data/store/user-model.md` — if the file is absent or `status: draft`,
   judge **without** user-model priors and disclose `user-model: none` in
   the breakdown string (never block on a missing/unconfirmed model);
   `ranking-weights.json`'s `kinds`/`evidence` priors (absent → `1.0`
   neutral); and neighbor priors from `index/embeddings.jsonl` via
   `packages/ingestion/scripts/nearest-confirmed.sh` (read-only) when that
   file exists, else the breakdown omits the `neighbors:` segment per that
   contract's rule.
3. **Verdict.** The judgment resolves to a quiet-drift or upward-drift
   signal event — `evidence:` carries the full breakdown string
   (`relationship-scoring.md` "## Breakdown string", quoted there, not
   restated here) — or `no-drift`, logged as a one-line reason in
   `wakeups/signals/scan-log.md` and no signal event written. `confidence`
   on the signal event is the judgment record's own `confidence` field
   (`low`/`medium`/`high`), not a fixed per-detector constant.

Before emitting a verdicted proposal, apply both: the declined-pairing
suppression (a dismissed `(person, proposed-tier)` pair with
`dismiss-reason: not-this-signal-type` within 180 days) and the quarterly
rate limit (at most one tier-drift proposal per person per 90-day rolling
window, any direction/outcome). QUIET-direction promotion never proposes a
tier write — reach-out-or-reclassify framing only, per the spec's binding
never-demote guardrail; UPWARD-direction promotion only ever proposes a
*more* attentive tier, never a demotion as a side effect. Attention writes
no `tier`, no `kind`, and no `user-model.md` field anywhere in this
detector — every judgment output is ammunition in a wake-up's `## Context`,
never a direct write.

### birthday

Reads every person's frontmatter `birthday` (`YYYY-MM-DD` or `--MM-DD`)
and any matched `contact-record` capture event carrying a birthday
(`specs/birthday.md` Inputs). Opt-out (`birthday — all`/`— [[slug]]`) is
checked before emission — no signal event at all for an opted-out person
(birthday has no separate promotion step to distinguish, unlike
scheduling-intent). Emits when the next month/day occurrence (year-wrap
aware) falls within 7 days inclusive of the scan date. Frontmatter wins on
disagreement with a contact-record (logged as a discrepancy, one signal
only). Dedup: the standing per-year rule — skip if a `wakeups/*.md` entry
with `signal-type: birthday` already exists for this person with a `due`
in the current birthday year, pending or fired, regardless of the 30-day
window.

### linkedin-post

No dedicated spec file — defined here inline, per plan 05's brief. Scan
new `type: linkedin-notification` capture events in the trailing 7 days
for people tagged `bell` in `people/<slug>.md` `tags`, whose body is a
**post** (not a job-change pattern per `specs/job-change.md`'s pattern
list — a job-change-shaped notification is that detector's concern, not
this one's). `confidence: low` by default; `medium` when the post
mentions the user directly or a topic shared with the user (per
`people/<slug>.md` `tags`/`## Facts`). Opt-out
(`linkedin-post — all`/`— [[slug]]`) checked before emission. Dedup: the
common 30-day same-type+person rule. Due (once promoted, per §10 below):
`detected_at` + 1 day.

## 3. Ranking pass

Cite `packages/attention/specs/ranking.md` — do not restate its numbers.
Per candidate signal event written in step 2 (excluding any suppressed at
the detector, e.g. scheduling-intent's total-silence and debrief-harvest's/
birthday's/job-change's/tier-drift's pre-emission opt-out gates, which
never reach ranking at all):

1. Compute `W` (§1) from `stats.json`, `W′` (§2, capacity-mode inversion
   keyed on `week-plan.json`'s `weekly_tier` from step 1, capped at `1.0`),
   `R` (§3, fixed per type), `C` (§4, from `confidence`).
2. Score = `W′ × R × C × weight(signal-type) × max(weight(tag))` (§5),
   rounded to 3 decimals.
3. Apply the two-signal boost (§6): any person with ≥2 signal events of
   different `type` within the trailing 14 days has every one of those
   scores multiplied by `1.5` (after §5, before rounding); a lone
   `low`-confidence signal never self-promotes off this boost.
4. Apply the suppression floor (§7): `score < 0.15` → suppressed, signal
   event stands, never promoted this pass, logged `suppressed: floor`.
5. Apply the budget/hold decision (§8): read `promotable_count` from
   `week-plan.json`'s `budget.max` minus existing `origin: signal`
   pending/fired wake-ups due in the plan week (floor 0); rank
   non-suppressed candidates descending by score; promote the top
   `promotable_count`; everything below the line is **HELD**, not
   dropped — the signal event persists and is re-ranked fresh next sweep.
   `origin: user-ask` wake-ups are entirely exempt from this accounting
   (§8 rule 4) and out of scope for this pass.
6. Write `<store-dir>/wakeups/signals/scan-log.md`, append-only, one block
   per scan: scan date, the `weekly_tier`/budget actually used (and
   whether it was a stale/missing fallback), the full ranked table
   (id/type/person(s)/score/disposition, matching
   `fixtures/signals/expected/ranking.md`'s shape), and explicit
   promoted/held/suppressed lists with reasons. Held signals are logged as
   held, never silently omitted — the next scan's ranking pass re-reads
   them from `wakeups/signals/`.

## 4. Wake-up creation

Only via `wakeup-add.sh` — never hand-write a `wakeups/*.md` file:

```sh
bash packages/core/scripts/wakeup-add.sh <store-dir> \
  --due <date per §10/detector spec> \
  --person <slug> [--person <slug> ...] \
  --why "<trigger, never bare cadence>" \
  --origin signal \
  --source-signal <signal-id> \
  --signal-type <signal's type> \
  --context "<ammunition>" \
  [--draft "<text>"]
```

- **Due dates** per `ranking.md` §10, cited by type (birthday: day before;
  job-change: +14d; company-news: +2d; co-attendance: day after the event,
  or +1d if already passed; debrief-harvest: commitment `by` − 2d else
  +3d; linkedin-post: +1d; scheduling-intent: +1–2d per its own
  slot-selection rules; tier-drift: +1d), or the detector's own spec's
  Due-date section when it adds detail (e.g. birthday's "never a due date
  in the past" clamp).
- **`--context`** (the ammunition, §11): opens with the trigger line
  (+ `Priority: high (two independent signals: <a>, <b>)` when the
  two-signal boost applied to this signal), then provenance-labeled
  evidence quoted from the signal event, then what the user already knows
  — open threads and a one-line summary of the last interaction, read
  from `stats.json`/`people/<slug>.md`.
- **`signal-type` on the promoted wake-up.** Always pass
  `--signal-type <signal's type>` on every promotion — the exact `type`
  field from the signal event being promoted (e.g. `job-change`,
  `co-attendance`, `birthday`). `wakeup-add.sh` writes this straight
  through to the wake-up's `signal-type` field, mirroring the promoting
  signal event's `type` on every `origin: signal` entry per
  `packages/core/contracts/wakeup.md`. Never omit it and never pass a
  value other than the signal event's own `type`.
- **Drafts** (`--draft`) are allowed and optional, always surfaced for
  human review — draft-never-send holds; this skill never sends anything.

## 5. Silence & never-do list

- Nothing clears the budget line this scan → still write the scan-log
  block (step 3.6) recording zero promotions and why (held/suppressed
  lists), and stop. No message, no digest, no other output — the
  wake-up-queue-over-digests doctrine holds; a silent scan is a valid,
  expected outcome, not an error.
- Never edit `people/`, `interactions/`, or `profile.md` — every proposed
  fact (a new tier, an org/role update) is ammunition in a wake-up's
  `## Context`, never a direct write (`docs/DECISIONS.md#preference-provenance`).
- Never send anything — draft-never-send, no exception for any detector.
- Never call an enrichment API, scrape a site, or use anything but the
  harness WebSearch tool / SEC EDGAR public full-text search / already
  filed `inbox/` capture events for external data — ToS-clean throughout
  (`CLAUDE.md`, `specs/job-change.md`, `specs/company-news.md`).

## 6. Fixture self-check

```sh
# 1. Fresh scratch copy of the golden fixture store
cp -R packages/attention/fixtures/signals/store /tmp/signal-scan-check

# 2. Run this skill against it, scan date 2026-09-01
#    (invoke signal-scan with --today 2026-09-01 against /tmp/signal-scan-check)

# 3. Diff signal events (minus detected_at, which is run-time-stamped)
diff <(grep -v '^detected_at:' /tmp/signal-scan-check/wakeups/signals/*.md) \
     <(grep -v '^detected_at:' packages/attention/fixtures/signals/expected/signal-events/*.md)

# 4. Diff promoted wake-ups (minus id-derived timestamps)
diff <(grep -vE '^id:' /tmp/signal-scan-check/wakeups/*.md) \
     <(grep -vE '^id:' packages/attention/fixtures/signals/expected/wakeups/*.md)

# 5. Compare the scan-log ranked table to the golden ranking
diff /tmp/signal-scan-check/wakeups/signals/scan-log.md \
     packages/attention/fixtures/signals/expected/ranking.md
```

Expected result per `packages/attention/fixtures/signals/README.md`: five
signal events (birthday, job-change, co-attendance, company-news,
linkedin-post — this fixture does not seed debrief-harvest,
scheduling-intent, or tier-drift material), exactly three promoted
wake-ups (co-attendance, company-news, job-change — the latter two both
opening `## Context` with `Priority: high (two independent signals:
job-change, company-news)`), the birthday signal HELD (score 0.399, below
the budget-3 line), and the linkedin-post signal SUPPRESSED (score 0.067,
below the 0.15 floor).

# Plan 36 — Store currency, person dedup, remainder speed, preference loop

> **Consolidation 2026-08-30 (ROADMAP Goal 1 + Goal 2).** A–C build as written, plus
> **C3 = calendar ignore rules** (declined-self, `calendar-max-attendees` cap, hold
> reasons `skipped-declined` / `skipped-large:<n>`) absorbed from plan 04 D5.
> `feedback-event` bump is **1.2.0** here (W0.2) and nowhere else. A4
> `refresh-person.sh` runs only for slugs with ≥ 2 threads (model call; counts
> against the 8-min budget). **D is narrowed** to `learn-sweep.sh` (ledger cursor →
> `feedback-to-evals.sh` append + conflict detection → 3-line digest, registered as a
> sync-tick target) — it never writes `user-model.md`; rules/proposals are plan 34
> U31/U32. Plan 37 (which restated D) is deleted.

**Status:** proposed 2026-08-30 · **Branch:** chunk-36-store-currency
**Mission test (§1):** every unit cuts a running cost (remembering-to, re-reading
old context, cleaning duplicates, re-stating preferences). Nothing here drafts,
sends, scores engagement, or performs the relationship.

## Problems observed on the live store (2026-08-30 fresh onboarding)

1. **Currency.** A person's file says "spoke on July 8 about X" and the open
   thread on X is still live although later messages moved on. Root cause:
   `file-thread.sh` appends facts (verbatim-dedup only) and the debrief skill
   appends `## Open threads`; nothing closes, demotes, or re-dates them. No
   "latest interaction wins" rule exists anywhere in the store model.
2. **Duplicates.** dhruv/dhruv-mehta, patrick/patrick-proulx, rahul×3, one
   `josh` slug spanning three real people. No merge tool, no candidate detection.
3. **Speed.** Debrief remainder = 7.8 of ~15 min for 52 non-chat events, 37 of
   them noise (CI, newsletters, security notices).
4. **Preference loop.** Corrections the user makes (tier, kind, "that's stale",
   merge/split, dismissed nudge) are not fed back into how filing and scoring
   behave next time. Plan 34 phase 1 (feedback ledger) exists unmerged in the
   `feedback` worktree and is the substrate.

## Units

### A. Currency model (core contract + ingestion)  — fixes problem 1
- **person.md 1.4.0** (additive): every `## Open threads` bullet carries an
  `(as-of YYYY-MM-DD)` date; a new `## Resolved` list under Open threads holds
  closed items with `(resolved YYYY-MM-DD)`. Facts keep their optional date;
  a fact may be prefixed `[stale]` when superseded.
- **Latest-interaction-wins rule** (spec `packages/ingestion/specs/currency.md`):
  when an interaction with a later date than an open thread's as-of date is
  filed for the same person, the thread is either (a) explicitly resolved by
  the summary (`resolved_threads[]` — new optional field, thread-summary 1.1.0,
  debrief §5a equivalent), or (b) left open but marked `(as-of …, unverified
  since …)`. Briefs and nudge cards only surface open threads whose as-of date
  is ≥ the person's second-most-recent interaction; anything older is shown
  under "possibly stale" or omitted.
- `summarize-thread.sh` prompt: ask for `resolved_threads` and ask the gist to
  be **current state**, not chronology ("where things stand now" — the July 8
  article is background only if still relevant).
- **`refresh-person.sh <store> <slug>`** (ingestion): re-derives Facts/Open
  threads from the person's full interaction timeline in one hermetic call
  (same transport as summarize-thread), rewriting derived bullets only —
  `told-by-user` items are never touched. Used by onboarding after filing and
  by the correction loop (D) on demand.
- Tests: currency fixtures (open→resolved, stale demotion, told-by-user
  untouched), validate-store checks the new date shapes.

### B. Person dedup (core script + ingestion step)  — fixes problem 2
- **`person-merge.sh <store> <keep-slug> <drop-slug>`** (core): union
  identities (emails, sender_ids, identities.tsv rows), merge Facts by
  provenance (verbatim dedup), concat Open threads, rewrite every
  `[[drop-slug]]` link in interactions/wakeups, move drop file to
  `people/.merged/<drop>.md` with a `merged_into:` header, append to
  `ingestion/merges.log`. `--split` is out of scope (a wrong `josh` is handled
  by re-filing the offending interactions to a new slug via `file-thread`'s
  identity override).
- **`find-merge-candidates.sh <store>`** (ingestion, deterministic): candidates
  = shared email/sender_id, or same normalized first+last name, or one slug is
  a prefix of another with a shared org/identity. Prints `candidates=<n>` and a
  TSV; never merges on its own.
- Onboarding-seed step 4(b): run candidates, present list, user confirms
  (numbers only in progress lines), then merge. Correction recorded in the
  feedback ledger (D).

### C. Remainder speed (ingestion)  — fixes problem 3, target 7.8 → <2 min
- **Sender-pattern triage** (deterministic, `triage-inbox.sh` rule table
  `packages/ingestion/config/noise-senders.tsv`): noreply/notifications/CI/
  security/newsletter patterns → `held:noise` in the ledger, never filed, never
  a person. Learned additions land in `data/ingestion/noise-senders.local.tsv`
  when the user confirms a held sender as noise (D).
- **One-call email filing**: real email bodies (the ~15 non-noise remainder)
  go through `summarize-thread.sh`'s transport with an email prompt variant
  (`--kind email`), then `file-thread.sh` — no per-event debrief session. The
  debrief skill stays for user-typed debriefs only.
- Bench: re-run fresh onboarding, report the step table; remainder ≤2 min.

### D. Preference loop (attention + ingestion, on top of plan 34 phase 1)
The "user's own agentic loop": every correction is a datum, every datum
changes future behavior, and every change is measurable.
- **Feedback ledger events** (plan 34 contract, extended): `tier-set`,
  `kind-set`, `merge`, `stale-marked`, `noise-sender`, `nudge-dismissed`,
  `nudge-acted`, `draft-edited` (diff shape only, never the text of a sent
  message). All `stated-by-user` provenance.
- **`learn-sweep.sh <store>`** (attention, scheduled with the sync ticks):
  reads new ledger events → (1) user-model rev++ with explicit rules
  ("user demotes cold outreach to T4", "user treats <org> senders as noise"),
  (2) per-person overrides (`tier_source: stated-by-user` already exists),
  (3) appends each correction as an **eval case** under
  `packages/<pkg>/evals/learned/` so the next re-baseline proves the behavior
  stuck. Sweep output is a 3-line digest ("learned 4 rules, 2 conflicts held
  for you"); conflicts (two corrections that disagree) are never auto-resolved.
- Guardrails: draft-never-send untouched; learned rules are plain text the
  user can read and delete in `user-model.md`; nothing leaves `data/`.

## Order and sizing
A1 contract+spec → A2 summarize/file-thread changes ‖ B1 merge script ‖ C1
noise triage (parallel, three packages) → A3 refresh-person ‖ B2 candidates +
onboarding step ‖ C2 one-call email → D (needs plan 34 phase 1 merged first)
→ live run on the private store + bench table. Each unit ≤3-min worker brief;
implementation and tests are separate workers.

## Done when
- Live store: zero open threads older than a person's latest interaction
  without a `(unverified since …)` mark; the known duplicates are merged;
  fresh onboarding ≤ 8 min end-to-end; one confirmed correction of each ledger
  type produces a user-model rule and a passing learned eval case.

---

## Execution plan — A–C (authored 2026-08-30 from a code read; D is deferred)

Ground truth the units are built on (verified 2026-08-30):

- `person.md` is **1.3.0**; validator enum `1\.0\.0|1\.1\.0|1\.2\.0|1\.3\.0`
  (`validate-store.sh:309`), Facts regex
  `^- \*\*\[(told-by-user|inferred-public-web|inferred-from-thread)\]\*\*` (:401).
  Section order: Facts → Open threads → Personal details.
- `thread-summary` is an **ingestion spec** (`packages/ingestion/specs/thread-summary.md`,
  1.0.0), not a core contract — bump it there.
- `## Open threads` consumers: `file-thread.sh` (regex `(## Facts\n\n)(.*?)(\n\n## Open threads)`),
  `derive-evidence.sh:241–245` (first 80 chars per bullet), `who-next-direct.sh:201`
  (joins bullets), `build-stats.sh` (counts `- ` lines until next `## `),
  `query/server/src/store/types.ts` (count only).
- `summarize-thread.sh` only accepts chat-json captures (`chatID` + `messages[]`);
  transport is `claude -p --json-schema … --max-turns 2`; tests stub via
  `RA_THREAD_PARSE_TEST`. `file-thread.sh` unions captures by `chatID`; open threads
  land only on the last active day's interaction.
- Remainder path = `onboarding-seed/SKILL.md` Step 2(d) → debrief skill. Last live
  run: 52 non-chat events, 37 noise, 7.8 min. The existing `noreply-marketing`
  triage rule did not catch them (GitHub/CI/security senders are not `noreply@`).
- Feedback ledger: `feedback-event` **1.1.0** (`<store>/signals/feedback.jsonl`),
  writer `packages/ingestion/scripts/feedback-file.sh`; types do not yet include
  `merge`, `noise-sender`, `stale-marked`.
- `identities.tsv` is append-only; rows whose slug file no longer exists are
  skipped in memory → a merge appends keep-slug rows and needs no rewrite.
- No `merges.log`; convention says `<data-dir>/ingestion/merges.log`,
  tab-separated like `triage-held.log`.
- No bench script exists; the 2026-08-30 step table was hand-timed.

### Format decisions (fixed here so workers never re-litigate)

- Open-threads bullet: `- <text> (as-of YYYY-MM-DD)` ; demoted form
  `- <text> (as-of YYYY-MM-DD, unverified since YYYY-MM-DD)`. Bullets with no
  paren are legal (pre-1.4.0) and treated as as-of = person's `last-touch`.
- `## Resolved` is an H2 placed **between** `## Open threads` and
  `## Personal details` (so `build-stats.sh`'s count stops at it, no change needed);
  bullets `- <text> (resolved YYYY-MM-DD)`. Optional section.
- Stale fact: `- **[<tag>]** [stale] <text> …` — marker sits *after* the provenance
  tag so the :401 regex still matches; only `inferred-*` facts may be marked stale
  by machinery; `told-by-user` facts are never touched by any derived writer.
- Latest-interaction-wins: on filing an interaction dated D for slug S, every open
  thread with as-of < D that is not in `resolved_threads[]` gets
  `unverified since D` (idempotent; existing `unverified since` kept at its first
  date). Consumers (`who-next-direct.sh`, `derive-evidence.sh`, brief render) drop
  unverified threads whose as-of < the person's second-most-recent interaction.
- `thread-summary 1.1.0` (additive): `resolved_threads: [string]` (verbatim text of
  an existing open-thread bullet the thread closes), `kind: "chat"|"email"`. Gist
  rule reworded to "where things stand now; earlier history only as context".
- `feedback-event 1.2.0` (additive types): `merge` (`--from <drop> --to <keep>`),
  `noise-sender` (`--target <pattern>`), `stale-marked` (`--target <slug>`). Only
  these three ride with A–C; D adds the rest.
- `noise-senders.tsv` columns: `name<TAB>regex<TAB>scope(from|subject)`; triage
  reason `noise-sender:<name>`; local additions in
  `<data-dir>/ingestion/noise-senders.local.tsv` (same columns, gitignored).
- Email one-call: one `summarize-thread.sh --kind email` call **per non-noise
  email capture** (not per Gmail thread — keeps `file-thread.sh` free of a
  second union path); `chat_id` = the Gmail thread id when present else the
  capture id; `chat_type: single`. `file-thread.sh` skips the chatID inbox union
  when `kind == email`.

### Worker units (each ≤3 min; impl and tests are separate workers)

**Wave 0 — contracts (3 parallel, 2 packages)**

| # | Pkg | Unit | Files |
|---|---|---|---|
| W0.1 | core | `person.md` 1.4.0 (as-of / `## Resolved` / `[stale]`), template comment, validator: enum + Open-threads paren shape + Resolved shape + stale placement; manifest line | `contracts/person.md`, `templates/person.md`, `scripts/validate-store.sh`, `package.md` |
| W0.2 | core | `feedback-event` 1.2.0 — three additive types; manifest line | `contracts/feedback-event.md`, `package.md` |
| W0.3 | ingestion | `specs/currency.md` (rule text above, verbatim) + `specs/thread-summary.md` 1.1.0 + `feedback-file.sh` enum accepts the three new types; manifest provides/consumes (`person@^1.4`, `feedback-event@^1.2`) | `specs/currency.md`, `specs/thread-summary.md`, `scripts/feedback-file.sh`, `package.md` |
| W0.1t | core | store tests: clean fixture gains one 1.4.0 person (as-of, unverified, Resolved, stale); corrupted fixture gains bad-as-of-date and stale-on-told-by-user cases | `fixtures/store/`, `fixtures/corrupted/`, `tests/run-store-tests.sh` |

**Wave 1 — after W0 (6 parallel across ingestion/core/query; one warm worker per package)**

| # | Pkg | Unit |
|---|---|---|
| A2 | ingestion | `summarize-thread.sh`: `resolved_threads` + `kind` in schema; gist wording; `--kind email` builds the prompt from From/To/Subject/body of a non-chat capture (no `chatID` required); email prompt variant text |
| A3 | ingestion (same warm worker, serial after A2) | `file-thread.sh`: stamp `(as-of <last-episode-date>)` on new open threads; move `resolved_threads` matches into `## Resolved` (create section if absent, before `## Personal details`); apply unverified-since rule; `kind==email` → no chatID union, one interaction per capture (machinery marks `unverified since`; the `stale-marked` feedback type is reserved for user corrections in D) |
| A2/3t | ingestion (2nd worker, test-only files) | `run-thread-tests.sh` + fixtures: email capture + canned result; resolved→Resolved; unverified marking idempotent; told-by-user untouched; pre-1.4.0 bullet tolerated |
| B1 | core | `scripts/person-merge.sh <store> <keep> <drop> [--data-dir] [--dry-run]`: union frontmatter (keep wins on scalar conflict, tags union), Facts verbatim-dedup merge, Open threads/Resolved concat, rewrite `[[drop]]` → `[[keep]]` in `interactions/` + `wakeups/` (dedup within a `people:` list), append keep-slug rows to `identities.tsv` for drop's emails, move drop → `people/.merged/<drop>.md` with `merged_into: <keep>` + `merged_on:`, append `<data-dir>/ingestion/merges.log` (`drop\tkeep\tISO`), call `feedback-file.sh --type merge` if present, rebuild index; validator must ignore `people/.merged/` |
| B1t | core (2nd worker) | merge tests in `run-store-tests.sh` (or new `run-merge-tests.sh` registered in `scripts/test-all.sh`): link rewrite, identity union, told-by-user preserved, tombstone, idempotent re-run exits 2, `.merged/` ignored by validator |
| C1 | ingestion (3rd worker — `triage-inbox.sh` only) | rule 6 `noise-sender` reading `config/noise-senders.tsv` + local tsv; seed tsv with CI/security/newsletter/GitHub/Vercel/Slack/Google-notification patterns; summary line gains `noise-sender:<n>`; triage tests: one hold per seeded pattern, golden set still 0 false holds, local-tsv override |
| X1 | query + ingestion (read-side, tiny) | `who-next-direct.sh` and `derive-evidence.sh` skip unverified/stale per currency rule; `query/server` untouched (count only) |

**Wave 2 — after W1**

| # | Pkg | Unit |
|---|---|---|
| A4 | ingestion | `refresh-person.sh <store> <slug> [--data-dir] [--dry-run]`: gather the slug's interactions (date-ordered), one `claude -p` call (same transport + `RA_REFRESH_PARSE_TEST` stub pattern) returning `{facts:[{provenance,text,stale}], open_threads:[{text,as_of}], resolved:[{text,resolved_on}]}`; rewrite **only** `inferred-*` facts and derived open/resolved bullets; `told-by-user` bullets and frontmatter untouched; ledger `<data-dir>/ingestion/refresh.log` |
| A4t | ingestion | refresh tests (stubbed result; told-by-user survival; dry-run no-write; validator clean after) |
| B2 | ingestion | `find-merge-candidates.sh <store>`: pairs by shared email/sender_id, normalized first+last name equality, slug-prefix + shared org/email domain; prints `candidates=<n>` + TSV `keep\tdrop\treason`; never writes; tests on a fixture with the dhruv/patrick/rahul shapes (synthetic names) |
| S1 | ingestion (skill docs) | `onboarding-seed/SKILL.md`: Step 2(d) → noise already held by triage; non-noise email = `summarize-thread --kind email` fan-out (xargs -P like 2(c)) → `file-thread`; debrief skill only for voice-note/`other`; new Step 4(b) run candidates → confirm (numbers only) → `person-merge.sh` → `build-index.sh`; Step 2(e) `refresh-person.sh` for people touched by >1 thread; bench line per step printed |

**Wave 3 — live, user session (no code)**

1. Merge branch; on the private store run `find-merge-candidates.sh`, confirm, merge
   the known dups (dhruv, patrick, rahul×3; re-file `josh`'s three people via
   `file-thread` identity override).
2. Fresh onboarding on a bare store with the same 435-event inbox; record the step
   table in this file; targets: remainder < 2 min, total ≤ 8 min.
3. Live currency check: `grep -c "unverified since" people/*.md` vs zero open threads
   older than latest interaction without a mark; `validate-store.sh` clean.
4. Fold the step table + Done line into ROADMAP row 36 A–C; D remains Proposed.

### Sequencing summary
W0.1 ‖ W0.2 ‖ W0.3 ‖ W0.1t → (A2→A3) ‖ A2/3t ‖ B1 ‖ B1t ‖ C1 ‖ X1 → A4 ‖ A4t ‖ B2 ‖ S1
→ full `bash scripts/test-all.sh` → PR → Wave 3. 14 worker briefs, max 6 concurrent.

### Open questions (answer before Wave 1; defaults stated)
- Gist for `--kind email`: file one interaction per email capture even when several
  captures share a Gmail thread id? **Default yes** (dedup by capture id via
  `debrief-filed.log`; thread-level union deferred).
- Should `refresh-person.sh` run for every person in onboarding? **Default no** —
  only slugs with ≥2 filed threads (cost: ~one call per such person).

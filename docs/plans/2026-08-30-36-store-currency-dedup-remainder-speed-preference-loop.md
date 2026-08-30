# Plan 36 — Store currency, person dedup, remainder speed, preference loop

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

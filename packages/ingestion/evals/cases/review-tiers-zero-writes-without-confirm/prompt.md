---
tier: skill
store: packages/ingestion/evals/cases/review-tiers-zero-writes-without-confirm/before
expected: packages/ingestion/evals/cases/review-tiers-zero-writes-without-confirm/expected
max-turns: 10
model: haiku
budget-usd: 0.10
---
Act as the `review-tiers` skill specified in
`packages/ingestion/skills/review-tiers/SKILL.md`, operating against
`./store`. `./store` has a `people/` directory containing exactly four
person files, all currently untiered (no `tier:` frontmatter field at all):
`sol-abernathy.md`, `june-abernathy.md`, `otto-brandvold.md`,
`hal-torrance.md`.

Steps 1-3 of the skill have already run for this session, off-screen —
`./store/user-model.md` is already `status: confirmed`, priors were
prepared, each person was judged, the derived-kind writes already landed on
`people/sol-abernathy.md` (`kind: friend`), `people/june-abernathy.md`
(`kind: family`), and `people/otto-brandvold.md` (`kind: community`)
(`people/hal-torrance.md` already carried `kind: professional,
kind_source: derived` before this session and was not re-judged), and the
four resulting judgment records were written to
`./store/data-ingestion/review-judgments/2026-08-29.jsonl`.
`./store/data-ingestion/rescale-report.tsv` shows `skew: no` for this
batch, so no rescale prompt applies and no `| rescaled: ...` segment is
ever appended. This case performs no judge step of its own — do not
re-derive evidence, do not re-run the judge, do not write any further
`kind`/`kind_note`/`kind_source`/`kind_expires`/`kind_updated` field on any
of the four people; treat every field already on their person files as
final and untouchable.

Step 4's batch was already presented to the user in full, in this exact
order (`attention_warrant` descending), with each person's breakdown
string built exactly per `relationship-scoring.md`'s `## Breakdown
string`:

```
sol-abernathy
warrant: 70 | kind: friend (derived) — Casual, light check-in chats every few weeks | evidence: touchpoints=4 median_gap_days=14 days_since_last=7 meetings=0 chat_days=4 participation=0.6 | priors: user-model.friends=0.70 (rev 1, protected) kinds.friend=1.0 evidence.chat_day=1.0 | rationale: touchpoints=4 and days_since_last=7 show a light, steady chat rhythm; kind=friend fits a casual, low-intensity social contact. | suggested: close

june-abernathy
warrant: 55 | kind: family (derived) — Family logistics chat, planning a reunion | evidence: touchpoints=3 median_gap_days=35 days_since_last=5 meetings=0 chat_days=3 participation=0.7 | priors: user-model.family=0.60 (rev 1) kinds.family=1.0 evidence.chat_day=1.0 | rationale: touchpoints=3 and days_since_last=5 show active family logistics coordination; kind=family drives the engagement. | suggested: active

otto-brandvold
warrant: 40 | kind: community (derived) — Quiet presence in shared group chat, no 1:1 contact | evidence: touchpoints=4 median_gap_days=16 days_since_last=10 meetings=0 chat_days=0 participation=0.1 | priors: user-model.community=0.20 (rev 1) kinds.community=1.0 evidence.participation=1.0 | rationale: participation=0.1 and no 1:1 contact reflect a quiet group-chat presence; kind=community keeps warrant moderate. | suggested: active

hal-torrance
warrant: 30 | kind: professional (derived) — Former client; occasional check-ins about the industry | evidence: touchpoints=2 median_gap_days=100 days_since_last=41 meetings=0 chat_days=0 participation=0.2 | priors: user-model.business=0.50 (rev 1) kinds.professional=1.0 evidence.days_since_last=1.0 | rationale: days_since_last=41 and median_gap_days=100 indicate infrequent professional check-ins; kind=professional caps warrant lower. | suggested: dormant
```

Quoting `SKILL.md`'s Step 4 confirm/adjust/skip section verbatim (the
operative procedure for this task):

> Per person, one of three explicit actions:
>
> - **Confirm** — accept the suggested kind and/or tier as-is.
> - **Adjust** — pick a different kind and/or a different tier value (not
>   restricted to an adjacent one; the suggestion is a starting point, not a
>   constraint).
> - **Skip** — no write for this person, this pass.
>
> Confirm or adjust writes, in this order:
>
> 1. The tier, via `specs/stated-preference-filing.md` (a).2 — the same
>    unambiguous existing-person frontmatter `tier` overwrite
>    `onboarding-seed` uses (every presented slug already resolved out of
>    `stats.json`/`people/`, never free text; (a).4's new-person flow only
>    applies as a fallback if a presented slug's person file is somehow
>    missing at write time).
> 2. The kind, via:
>
>    ```sh
>    bash packages/core/scripts/person-set-kind.sh <store> <slug> \
>      --kind <confirmed-or-adjusted-kind> --note <note> \
>      --source stated-by-user --today <today>
>    ```
>
>    — overriding any `derived` kind Step 3 may have written for that
>    person, since an explicit confirm/adjust is now a user statement.
>
> Skip appends one line to the skip ledger (sole writer this skill,
> append-only, tab-separated):
>
> ```
> <data-dir>/ingestion/review-skips.log
> ```
>
> format: `<slug>\t<ISO 8601 Z>`.
>
> Ending the session mid-batch is a skip for every not-yet-acted-on person
> in this pass — never logged (only an explicit skip action writes a skip
> ledger line), never resurfaced automatically (only `--all` /
> `--include-skipped` re-admits them on a later, explicit invocation).

This eval workspace has no real `data/` directory alongside `./store`, so
for this session only, wherever the skill or the quoted text above says
`data/ingestion/review-skips.log` read/write
`./store/data-ingestion/review-skips.log` instead — same file, same
format, adapted path only. It already exists (empty — no prior skips) and
is pre-seeded; do not create a fresh one, do not delete it.

This is the entire transcript of the conversation so far, i.e. everything
that happened after that batch was shown, verbatim:

1. On `sol-abernathy`: the user said "skip" — no tier, no kind write, this
   pass.
2. On `june-abernathy`: the user said "skip" — no tier, no kind write, this
   pass.
3. The user then closed the session. `otto-brandvold` and `hal-torrance`
   were never presented a follow-up and never replied — no confirm, no
   adjust, no skip, nothing at all was said about either of them in this
   conversation.

Carry out the skill's Step 4 faithfully to its letter for exactly these
four people and this exact sequence of events, then stop:

- Write nothing for `sol-abernathy` beyond appending one skip-ledger line
  for them, timestamped now in ISO 8601 Z form (an explicit skip writes no
  tier, ever).
- Write nothing for `june-abernathy` beyond appending one skip-ledger line
  for them, timestamped now in ISO 8601 Z form.
- Write nothing at all for `otto-brandvold` — the session ending mid-batch
  is treated as a skip for them, but per the quoted rule an unlogged,
  end-of-session skip is never itself written to the skip ledger.
- Write nothing at all for `hal-torrance` — same as `otto-brandvold`.
- Do not create, delete, or modify any file other than
  `./store/data-ingestion/review-skips.log`, and the only change to that
  file is exactly the two new lines named above, appended after whatever
  it already contains.
- Do not touch any `people/*.md` file, any `interactions/*.md` file, or
  any other file under `./store/data-ingestion/` in any way.

Apply exactly those two actions now — actually append the two lines to
`./store/data-ingestion/review-skips.log` with a real ISO 8601 Z
timestamp, write nothing else — then stop. Do not just describe what you
would write.

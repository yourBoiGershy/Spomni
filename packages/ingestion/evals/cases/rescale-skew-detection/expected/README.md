# Expected outcome: skew warning surfaced, batch shown un-rescaled

This case's `graders/` derive their assertions directly from the fixture and
`prompt.md` (file-existence and content checks on
`data-ingestion/skew-warning.txt` and `data-ingestion/presented.jsonl`, plus
a byte-identity check on every `people/*.md` file), rather than a
byte-diffable `expected/` store — a live skill run's exact prose in the
skew-warning text and every breakdown string's whitespace/wording isn't
guaranteed identical to a hand-authored golden even when every field under
test is correct, so a full-tree byte-diff would be too brittle here (same
reasoning as `packages/ingestion/evals/cases/triage-held-respected/
expected/README.md`). This directory exists only to satisfy the `expected`
frontmatter field the T3 runner (`eval-run-skill.sh`) requires; it is not
consumed by `RA_GRADER_DIFF`.

## Why this case exists

`packages/ingestion/skills/review-tiers/SKILL.md`'s Step 4 has three
binding rules this eval exists to guard: (1) a skewed batch's warning is
always printed, exact wording, before anything else; (2) `--rescale` is
**never** auto-applied — a batch run without the flag must be presented
un-rescaled even though a pre-computed re-centered batch exists for the
same input; (3) presenting a batch, by itself, writes zero tiers — only an
explicit per-person confirm/adjust (which never happens in this case) does.

## Hand-derived expected outcome (from `prompt.md`'s fixture)

`./store/data-ingestion/review-judgments/2026-08-29.jsonl` holds six
pre-seeded, already-validated judgment records:

| slug | kind | `attention_warrant` (un-rescaled) | `suggested_tier` |
|---|---|---|---|
| pip-larkin | scheduling | 99 | active |
| bram-fiske | transactional | 95 | active |
| june-abernathy | family | 90 | inner-circle |
| hal-torrance | professional | 88 | inner-circle |
| ines-castellano | collaborator | 85 | inner-circle |
| mara-quill | friend | 82 | inner-circle |

`./store/data-ingestion/rescale-report.tsv`'s `overall` row (hand-verified
against `packages/ingestion/specs/rescale.md`'s worked example, which uses
this exact six-value batch 82/85/88/90/95/99):

```
scope	n	mean	median	spread	share_ge_80	share_le_20	skew
overall	6	89.8	89	13.5	1.00	0.00	yes
```

`share_ge_80 = 1.00 (100%) > 0.5` trips the skew rule — `skew: yes`, reason
`share_ge_80 > 0.5`. Per SKILL.md's Step 4, the expected skew-warning text
(mean rendered as the report's own `89.8`, share as `100`) is:

```
Warrant distribution is skewed (share_ge_80 > 0.5): mean 89.8, 100% ≥ 80. Re-center with `--rescale`? Suggestions below are shown un-rescaled.
```

Since `prompt.md` states the user invoked `review tiers` **without**
`--rescale`, and Step 4's `--rescale` step is described as running "only if
the user passed `--rescale` at invocation, or answers yes to this prompt
now," this session never authorizes it — the presented batch must carry the
un-rescaled warrants (82/85/88/90/95/99), never the pre-seeded
`rescale-recentered.jsonl` values (27/36/45/50/65/77, hand-computed per
`specs/rescale.md`'s own worked example over this identical batch). No
breakdown string may carry a `| rescaled: <from>→<to>` segment.

Presenting a batch is read-only with respect to `people/`: no confirm or
adjust action occurs in this session, so every `people/*.md` file must be
byte-identical to the fixture's original.

## Graders

1. `01-warning-surfaced.py` — `skew-warning.txt` exists and contains both
   "skewed" and "--rescale" (the warning's operative words).
2. `02-presented-unrescaled.py` — `presented.jsonl` has exactly 6 records,
   one per fixture slug, whose `attention_warrant` values equal the
   pre-seeded un-rescaled warrants (82/85/88/90/95/99) — never the
   re-centered values (27/36/45/50/65/77) — ordered warrant descending,
   every `breakdown` string matching the contract's format (anchored on
   `warrant: `, `kind: ... (`, `evidence: `, `priors: `, `rationale: `,
   `suggested: `), and no breakdown containing `rescaled:`.
3. `03-zero-tier-writes.py` — every `people/*.md` file in the worked store
   is byte-identical to its `before/` original (path derived from
   `__file__`, so the check is self-contained regardless of the runner's
   temp-copy layout).

## Manual verification performed

All three graders were run directly against a hand-built worked-store copy
of this fixture (the correct outcome) and doctored variants that flip each
invariant (rescaled warrants substituted in, a tier write added to a
person file) — see the completion report for the exact commands and
PASS/FAIL output, and for the live `eval-run-skill.sh` run's result line.

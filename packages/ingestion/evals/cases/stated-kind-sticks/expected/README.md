# Expected outcome: a stated kind survives a contradicting judgment record

This directory exists only to satisfy the `expected` frontmatter field the
T3 runner (`eval-run-skill.sh`) requires; it is not consumed by
`RA_GRADER_DIFF`. This case's `graders/` derive their assertions directly
from the fixture and `prompt.md` (frontmatter-field and byte-identity
checks on specific `people/*.md` files and the pre-seeded judgments/
run-log files), the same reasoning as
`packages/ingestion/evals/cases/triage-held-respected/expected/README.md`
— a full-tree byte-diff would be too brittle for a case whose whole point
is that one file (`sol-abernathy.md`) IS supposed to change.

## Why this case exists

`packages/core/contracts/relationship-scoring.md`'s `## Rules` states:

> **Stated kinds are sticky:** a `kind_source: stated-by-user` value is
> never overwritten by a judgment record — the classification pass skips
> people whose current kind is user-stated.

`packages/ingestion/skills/review-tiers/SKILL.md` Step 3 restates this as
the `check-judgment.sh` `stated-kind-changed` rejection rule. The one
*model*-facing behavior worth eval-guarding is whether the validate-and-
write sub-step actually honors this when handed a judge record that
disagrees with an already-stated kind — the failure mode this guards
against is a stated-by-user `kind` getting silently clobbered by a later
judgment pass.

## Hand-derived expected outcome (from `prompt.md`'s fixture)

`before/data-ingestion/review-judgments/2026-08-29.jsonl` has three
pre-seeded records:

| Slug | Person file's current `kind_source` | Record's `kind` | Expected outcome |
|---|---|---|---|
| `ravi-sundar` | `stated-by-user` (`kind: friend`) | `collaborator` (WRONG — disagrees with the stated kind) | Rejected: `people/ravi-sundar.md` untouched (byte-identical to `before/`); the rejection is recorded, either as a `ravi-sundar\treject:stated-kind-changed` line in `data-ingestion/run.log`, or by correcting the judgments-file record's `kind` back to `friend` in place |
| `sol-abernathy` | absent (no `kind` field at all) | `friend` | Accepted as a derived write: `people/sol-abernathy.md` gains `kind: friend`, `kind_source: derived`, `kind_updated: 2026-08-29` in frontmatter; every other line stays byte-identical to `before/` |
| `hal-torrance` | `derived` (`kind: professional`) | `professional` | Accepted as a derived write (kind unchanged in value, but not stated-by-user, so the write path still applies); not graded by this case's `graders/` |

Per `relationship-scoring.md`'s sticky-stated rule, `ravi-sundar`'s stated
kind must never be overwritten no matter what a judgment record claims —
the wrongness of the record's `collaborator` claim is exactly what this
case is proving gets caught, not silently applied.

## Graders

1. `01-stated-untouched.py` — `people/ravi-sundar.md` is byte-identical to
   `before/` — the wrong `collaborator` judgment never reached the file.
2. `02-rejection-recorded.py` — the `stated-kind-changed` rejection was
   actually recorded somewhere (`run.log` line, or the judgments record
   corrected in place to `kind: friend`) — not just silently dropped.
3. `03-derived-write-happened.py` — `people/sol-abernathy.md`, whose kind
   was not stated-by-user, actually got the derived kind write (fact-based:
   frontmatter fields present, all other lines unchanged — no exact prose
   diffing of `kind_note`).

## Manual verification performed

All three graders were run directly against a hand-built worked-store copy
of this fixture (the correct outcome), and doctored variants that flip
each invariant (ravi's kind changed to `collaborator` in the worked copy;
sol's `kind*` lines removed) — see the completion report for the exact
commands and PASS/FAIL output, and for the live `eval-run-skill.sh` run's
result line.

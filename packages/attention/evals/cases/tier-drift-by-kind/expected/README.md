# Expected outcome: kind-horizon prefilter admits 2 of 4, judges to proposals

Like `tier-drift-upward`, this directory only satisfies the `expected`
frontmatter field the T3 runner (`eval-run-skill.sh`) requires — the
`graders/` derive their assertions directly from the fixture
(`packages/attention/tests/fixtures/tier-drift-by-kind/`) and from
`packages/attention/specs/tier-drift.md`'s "## Prefilter" section, not from
a byte-diffable store.

## Hand-derived candidate set (per the prefilter, today = 2026-08-30)

| person | kind | kind_expires | days_since_last | horizon | admitted? | reason |
|---|---|---|---|---|---|---|
| `greer-holloway` | `scheduling` | 2026-08-15 (past) | 41 (2026-07-20) | none (no-rhythm) | **no** | expired kind — rule 2 wins regardless of kind (also no-rhythm) |
| `isla-marchetti` | `friend` | — | 18 (2026-08-12) | 30 | **no** | inside horizon (18 < 30) |
| `dana-whitfield` | `friend` | — | 66 (2026-06-25) | 30 | **yes** | rhythmed, not expired, 66 > 30 |
| `milo-vantage` | *(none)* | — | 151 (2026-04-01) | 120 (unkinded → professional) | **yes** | unkinded falls back to professional's horizon, 151 > 120; disclosure required |

Only `dana-whitfield` and `milo-vantage` clear the prefilter and reach the
judgment pass. `greer-holloway` and `isla-marchetti` must never appear in a
new signal event or proposal wake-up — the prefilter is fully deterministic
and fixture-checkable per the spec's "## Deterministic fixture-checkability"
section, independent of whatever the judgment pass decides for the two
admitted candidates.

Because the judgment pass is model-driven, either admitted candidate may
resolve to a quiet-drift proposal or to `no-drift` (logged, no artifact) —
the graders below accept 1 or 2 new proposals rather than requiring both,
but require that whichever proposals do appear:

- name only `dana-whitfield` and/or `milo-vantage` (never `greer-holloway`
  or `isla-marchetti`),
- carry a breakdown string matching
  `relationship-scoring.md`'s "## Breakdown string" format, and
- for `milo-vantage` specifically, disclose the unkinded-fallback string
  verbatim: `"no kind on file — professional horizon assumed"` (per the
  spec's prefilter rule 1).

## Graders

1. `01-candidate-set.py` — every new `wakeups/*.md` and
   `wakeups/signals/*.md` file names only `dana-whitfield` and/or
   `milo-vantage`; any new file naming `greer-holloway` or
   `isla-marchetti` is an immediate FAIL. At least one new proposal or
   signal event must exist (the prefilter cannot rule out both admitted
   candidates from *judgment* the way it does the other two).
2. `02-breakdown-regex.py` — every new proposal/signal file contains an
   `evidence:` line (or inline breakdown) matching the "## Breakdown
   string" format's regex shape (`warrant: ... | kind: ... | evidence:
   ... | priors: ... | rationale: ... | suggested: ...`); any file naming
   `milo-vantage` additionally contains the unkinded-fallback disclosure
   string verbatim.
3. `03-never-writes-people.py` — every `people/*.md` in the worked store
   is byte-identical to the pristine fixture copy (`RA_EVAL_BEFORE_DIR`),
   and no `user-model.md` is created anywhere in the worked store — the
   detector proposes, it never writes people or priors.

# Contract: eval case

`schema_version: 1.1.0`

The shared format every package authors quality-eval cases in, so one set of
runner scripts (owned by `packages/core`) can execute cases from any package
without that package writing its own runner. Deliberately parallel to
`claude plugin eval`'s native suite format (`prompt.md` frontmatter +
`graders/*.md`) for later migration — see Notes.

## Store location

`packages/<pkg>/evals/cases/<name>/` — one directory per case, owned by the
package that authors it (single-writer rule: a package's eval cases are that
package's territory; core owns only the format and the runners that execute
it). `packages/<pkg>/evals/suite.txt` — the package's suite manifest,
sibling of `cases/`.

## Writer / readers

- **Writers:** any package, for cases in its own `evals/cases/` and its own
  `evals/suite.txt`. No package writes another package's eval directory.
- **Readers:** `packages/core`'s runner scripts — `scripts/eval-run.sh` (T2
  agent tier), `scripts/eval-run-skill.sh` (T3 skill tier),
  `scripts/eval-judge.sh` (structured-output judge, used by graders that opt
  in), `scripts/eval-suite.sh` (manifest runner + summary).

## Case directory shape

```
packages/<pkg>/evals/cases/<name>/
  prompt.md          # frontmatter + task prompt body
  graders/
    01-<name>.sh      # or .py — executable, deterministic
    02-<name>.sh
    judge.md          # optional — rubric graded via eval-judge.sh
  before/             # T3 (skill tier) only — the store copy the skill runs against
  expected/           # T3 only — the expected post-run store, for byte-diff grading
```

### `prompt.md` frontmatter

| Field | Type | Required | Notes |
|---|---|---|---|
| `tier` | enum | yes | `agent` (T2 — spins up the query MCP server + a headless agent) or `skill` (T3 — grades a skill run by diffing a worked store copy against `expected/`). |
| `store` | string | yes | Repo-relative fixture path the case runs against, e.g. `packages/core/fixtures/store`. **Never** a path under `data/` — see PII rule below. |
| `allowed-tools` | list of strings | T2 only | The `--allowedTools` list passed to the headless agent. T2-only, never above the tools the query MCP server exposes. |
| `max-turns` | integer | no (default `8`) | Passed as `--max-turns`. |
| `model` | string | no (default `haiku`) | Passed as `--model`. Per-case override exists for deliberate exceptions; nothing above haiku is a default anywhere in the harness. |
| `budget-usd` | number | no | Expected per-case `total_cost_usd`, advisory only — not enforced per-case, but summed by `eval-suite.sh` against `RA_EVAL_MAX_COST_USD`. |
| `xfail` | string | no | `"<reason> — <flip condition>"`. Marks the case as expected-to-fail until the named integration lands. See xfail discipline below. |
| `runnable-when` | string | no | A plan number (e.g. `03`) — the case exists now but is not yet executable because the code it exercises is unbuilt. Runners report `SKIP` with reason, never silently omit it. |
| `expected` | string | T3 only | Repo-relative path to the expected/ store this case's `graders/` diff against. **Never** a path under `data/`. If a fixture colocates an `expected/` (or `graders/`) subdirectory inside its `store` path, `eval-run-skill.sh` excludes it from the copy handed to the evaluated agent — the golden artifacts must never be readable from inside the workspace being graded. |

### Body

Everything after the frontmatter's closing `---` is the task prompt handed
to the headless agent (T2) or the skill invocation (T3), verbatim.

## Grader protocol

`graders/` holds one or more executable deterministic graders:

- `NN-<name>.sh` (bash 3.2 — no `timeout(1)`, macOS-safe) or `NN-<name>.py`
  (python3). `NN` orders execution.
- Each grader receives one argument, `$1`:
  - **T2 (`tier: agent`):** the path to the result JSON written by
    `eval-run.sh` (fields: `result`, `is_error`, `num_turns`,
    `total_cost_usd`, `duration_ms`, `permission_denials`, `usage`).
  - **T3 (`tier: skill`):** the path to the worked store directory (the
    `before/` copy after the skill ran against it).
- A grader exits `0` on pass, non-`0` on fail. No stdout/stderr contract
  beyond that — runners may capture it for diagnostics but grading is by
  exit code alone.
- `judge.md` is optional: a rubric run via `eval-judge.sh <judge.md>
  <result-json>`, which invokes a second `claude -p --model haiku
  --output-format json --json-schema '{verdict: pass|fail, reason: string}'`
  call and exits 0/1 on the `verdict` field. A case that includes `judge.md`
  treats it as one more grader in the pass/fail chain.
- **A case passes only when every grader in `graders/` passes** (deterministic
  graders and `judge.md`, if present).

### Golden-tests-before-prompts (grader-authoring rule)

Every grader's expected value must be hand-derived from the case's fixtures
— worked out by reading `before/`/`store` and reasoning about what the
correct output is — **never** copied from a system's own output. Writing a
grader by running the case once and pasting back whatever the agent or skill
produced defeats the eval; it can only ever confirm current behavior, never
catch a regression from it. Same rule as the `test-tools.mjs` precedent this
harness extends.

## Suite manifest

`packages/<pkg>/evals/suite.txt` — one case directory (repo-relative path)
per line; `#`-prefixed lines are comments, blank lines ignored. A line may
also carry an inline trailing `# smoke` tag marking it part of the smoke
subset (`RA_EVAL_SMOKE=1`, see below) — everything from the first `#`
onward is stripped and trimmed before the path is resolved, so untagged
lines and full-line comments are unaffected:

```
# packages/query/evals/suite.txt
packages/query/evals/cases/most-overdue        # smoke
packages/query/evals/cases/interpretability
packages/query/evals/cases/opt-out-respected
packages/query/evals/cases/stated-outranks-revealed
packages/query/evals/cases/draft-never-send-read-only
```

`eval-suite.sh` reads one or more manifests, dispatches each case to the
runner matching its `tier` in waves of `RA_EVAL_PARALLEL` concurrent
cases (default 4; `RA_EVAL_PARALLEL=1` reproduces the original strictly
serial behavior), and prints a summary. RESULT lines are always emitted
in manifest order regardless of wave finish order. Parallel dispatch is
safe because both runners (`eval-run.sh`, `eval-run-skill.sh`) mktemp
their own worked directory and copy the fixture store before touching
it, so concurrent cases never share mutable state.

## Result-line vocabulary

Every case run emits exactly one machine-parseable result line. The
vocabulary:

| Result | Meaning |
|---|---|
| `PASS` | All graders passed; case has no `xfail`. |
| `FAIL` | At least one grader failed; case has no `xfail`. |
| `XFAIL` | At least one grader failed on a case marked `xfail` — expected, counts as suite-green. |
| `XPASS` | All graders passed on a case marked `xfail` — the gap it was pinning has closed without the case being flipped to must-pass. Counts as **suite-red**: this is the forcing function to update the case (drop `xfail`) in the same change that lands the integration. |
| `SKIP` | Case has `runnable-when` naming a plan not yet built. Always accompanied by a reason (the plan number) — silence about a skipped case is never a valid outcome. |

Dry-run mode (`RA_EVAL_DRY_RUN=1`) also emits `RESULT SKIP case=<name>
reason=dry-run` on both runner tiers, so the one-RESULT-line-per-run
guarantee holds even when the underlying `claude` invocation is only
printed, not executed.

### xfail discipline (binding)

An `xfail: <reason> — <flip condition>` frontmatter value means "expected to
fail until the named integration lands." Every `xfail` must name its flip
condition explicitly — e.g. `xfail: suggest_reachouts doesn't read
ranking-weights.json yet — plan-13 query-personalization integration`, not
just `xfail: known gap`. Runners count `XFAIL` as suite-green; an xfail case
that passes reports `XPASS` and turns the suite red, so the gap cannot be
silently closed without someone noticing and flipping the case to
must-pass. `eval-suite.sh` exits non-zero whenever `fail > 0` or
`xpass > 0`.

## PII rule (data/-path refusal)

`store` and `expected` frontmatter paths must resolve inside this repo's
fixture directories (`packages/*/fixtures/`, `packages/*/tests/fixtures/`,
`packages/*/evals/cases/*/before|expected/`) — **never** under `data/`.
Every runner (`eval-run.sh`, `eval-run-skill.sh`, `eval-suite.sh`) resolves
the case's `store`/`expected` path and refuses to run, with a clear error,
if it resolves under `data/`. This is not advisory: real user data must
never be pointed at by an eval run, per the code-data-separation principle
and `docs/DECISIONS.md`.

## Environment variables

Runner behavior is tuned entirely through environment variables — no CLI
flags. Every runner honors only the variables it lists below; unset means the
noted default.

| Variable | Honored by | Effect |
|---|---|---|
| `RA_EVAL_MAX_COST_USD` | `eval-suite.sh` | Suite-wide cost cap in USD. Checked between waves (see `RA_EVAL_PARALLEL`); once the running total exceeds it, not-yet-dispatched cases are marked `RESULT SKIP reason=cost-cap` without running — up to one full wave of already in-flight cases may complete past the cap before it's checked. Default `2.00`. |
| `RA_EVAL_PARALLEL` | `eval-suite.sh` | Number of cases dispatched concurrently per wave. Default `4`; `1` reproduces the original serial per-case dispatch. |
| `RA_EVAL_SMOKE` | `eval-suite.sh` | Set to `1` to run only manifest lines carrying an inline trailing `# smoke` tag. A manifest with zero tagged lines prints a `SUITE NOTE:` and is skipped; if every manifest yields zero smoke lines the suite exits `2`. |
| `RA_EVAL_RUNNER_AGENT` / `RA_EVAL_RUNNER_SKILL` | `eval-suite.sh` | Test hooks: absolute paths overriding the `eval-run.sh` / `eval-run-skill.sh` runner script paths. Default unchanged. |
| `RA_EVAL_TIMEOUT_SECS` | `eval-run.sh`, `eval-run-skill.sh` | Wall-clock guard per case (backgrounded sleep-and-kill, no `timeout(1)`). Default `300`; `eval-judge.sh` defaults to `120`. |
| `RA_EVAL_DRY_RUN` | `eval-run.sh`, `eval-run-skill.sh` | Set to `1` to print the `claude` invocation instead of running it, and emit `RESULT SKIP case=<name> reason=dry-run` in place of an actual result. |
| `RA_EVAL_FORCE` | `eval-run.sh`, `eval-run-skill.sh` | Set to `1` to run a case despite it declaring `runnable-when` (bypasses the `SKIP`). |
| `RA_EVAL_KEEP` | `eval-run.sh` | Set to `1` to keep the temp workspace instead of deleting it on exit (T3's `eval-run-skill.sh` always cleans up). |
| `RA_EVAL_JUDGE_MODEL` | `eval-judge.sh` | Overrides the model used for `judge.md` rubric grading. Default `haiku`. |
| `RA_EVAL_PARSE_TEST` | `eval-judge.sh` | Set to `1` to run `eval-judge.sh`'s own judge-output parse self-test instead of grading a case. |
| `RA_GRADER_DIFF` | `eval-run-skill.sh` (exported, consumed by case graders) | Path to the built-in recursive byte-diff grader script, written into the T3 temp workspace. |
| `RA_GRADER_ASKED` | `eval-run-skill.sh` (exported, consumed by case graders) | Path to the built-in "skill asked a clarifying question and wrote nothing" grader script, written into the T3 temp workspace. |
| `RA_EVAL_EXPECTED_DIR` | `eval-run-skill.sh` (exported, consumed by `RA_GRADER_DIFF`) | Absolute path to the case's resolved `expected/` store, for graders that don't pass it as an explicit arg. |
| `RA_EVAL_BEFORE_DIR` | `eval-run-skill.sh` (exported, consumed by `RA_GRADER_ASKED`) | Absolute path to the case's resolved pre-run store, for graders that don't pass it as an explicit arg. |

## Worked example (T2, agent tier)

`packages/query/evals/cases/most-overdue/`:

```
packages/query/evals/cases/most-overdue/
  prompt.md
  graders/
    01-mentions-james.sh
```

`prompt.md`:

```markdown
---
tier: agent
store: packages/core/fixtures/store
allowed-tools:
  - mcp__ra-query__suggest_reachouts
  - mcp__ra-query__get_person
max-turns: 8
model: haiku
budget-usd: 0.03
---
Who is the single most overdue reach-out right now?
```

`graders/01-mentions-james.sh`:

```bash
#!/bin/bash
# $1 = path to eval-run.sh's result JSON
grep -q "james-okafor" "$1"
```

## Versioning

Additive fields (a new optional frontmatter key, a new grader-file
extension, a new result-line value) are a `schema_version` minor bump, per
the `capture-event.md` precedent — existing `1.0.0` cases remain valid and
runners ignore frontmatter keys they don't recognize. Removing a field,
changing the grader exit-code contract, or narrowing the PII rule is a major
bump.

## Notes

- Format parity with `claude plugin eval` (`prompt.md` frontmatter +
  `graders/*.md`) is deliberate, to keep migration cheap if that feature
  ships out of early access — but this contract has zero dependency on it;
  nothing here requires the gated feature to exist or to be enabled.
- Ships as versioned contract text only — case directories themselves are
  committed source (unlike `data/store/` artifacts), since they contain no
  user data, only fixture-derived prompts and graders.
- `packages/core`'s runner scripts (`scripts/eval-run.sh`,
  `scripts/eval-run-skill.sh`, `scripts/eval-judge.sh`,
  `scripts/eval-suite.sh`) are the sole readers of this format; a package
  adding eval cases never writes its own runner.

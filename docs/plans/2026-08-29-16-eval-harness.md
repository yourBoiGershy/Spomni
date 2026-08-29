# Plan 16: Eval harness (renumbered from 12 on merge) (tool / agent / skill tiers)

Status: Done (2026-08-29) — all waves + live-run fix pass landed. Live proof:
query suite pass=3 xfail=2 xpass=0 in 2:01 wall / $0.20 on subscription auth;
T1 40+9 (2 xfail pins); 8 T3 cases SKIP until plans 03/05/06. Flip condition
for the xfails: plan-13 query-personalization integration.
Package: core (shared runner scripts, eval-case contract) + query (T1 tests,
T2 agent cases) + ingestion (T3 preference-skill cases) + attention (T3
drift/proposal cases)
Depends-on: 08 (hard — query MCP server + tests are the substrate); 11 (hard —
profile.md / ranking-weights.json / wakeup v1.1 shapes exist as contracts +
fixtures). Plans 03/05/06 are NOT dependencies: their skill-level cases are
authored now and become runnable the day those skills land.

## Objective

Make quality measurable without API billing: a three-tier eval harness that
(T1) extends the existing deterministic MCP-client golden tests with
personalization stores at $0, (T2) spins up the query MCP server on fixture
data, spawns a fresh headless `claude -p` agent on subscription auth to
perform a task, and grades the result, and (T3) grades skill runs by
byte-diffing a store copy against expected output. Covers both the query tool
surface (plan 08) and the personalization layer (plan 11) — including
pinning, as expected-fail cases, the known gap that `suggest_reachouts` does
not yet read profile.md or ranking-weights.json.

## Context

Read docs/PROJECT-CONTEXT.md first. Decisions that bind this plan:

- **golden-tests-before-prompts** — every grader's expected value is
  hand-derived from fixtures (the test-tools.mjs precedent), never read off
  the system's own output.
- **Single-writer rule / territory** — core provides the shared runner
  scripts; each package owns its own `evals/cases/`. No package's eval writes
  another package's files.
- **code-data-separation / PII** — evals use fixture personas ONLY
  (`packages/core/fixtures/store`, per-package test fixtures, or
  gen-scale-store output). Eval runs must never point at `data/store`; the
  runners refuse any store path under `data/` outright.
- **draft-never-send / read-only query** — one T2 case exists specifically to
  prove an agent told to "handle" a nudge cannot mutate the store copy.
- **No CI (delegation-without-gates)** — evals run on demand via committed
  scripts; nothing here adds gates, hooks, or scheduled runs. Suite runs are
  a human decision with a cost readout at the end.

### Verified runtime facts (binding for units 4–6; all proven in-session 2026-08-29)

- Server: `node --experimental-strip-types packages/query/server/src/index.ts
  --store <dir>` (or `RA_STORE_DIR`); stdio; Node ≥22.6. Requires `npm
  install` in `packages/query/server` first — worktrees do not share
  node_modules (observed ERR_MODULE_NOT_FOUND for @modelcontextprotocol/sdk).
  Runners must pre-check `packages/query/server/node_modules` and fail with
  an instructive message. Env: `RA_CACHE_DIR` (redirect derived-artifact
  cache to scratch), `RA_CORE_SCRIPTS_DIR` (locate build-index.sh /
  build-stats.sh). The server never writes the store.
- Headless agent: `claude -p "<task>" --strict-mcp-config --mcp-config <file>
  --allowedTools "mcp__ra-query__<tool>,..." --max-turns <n> --model haiku
  --output-format json` runs on subscription auth when no ANTHROPIC_API_KEY
  is set. **Never `--bare`** — verified it drops subscription credentials
  ("Not logged in"). Isolation = temp cwd + `--strict-mcp-config`.
  mcp-config shape: `{"mcpServers": {"ra-query": {"command": "node",
  "args": [...], "env": {...}}}}`.
- Result JSON fields (verified): `result`, `is_error`, `num_turns`,
  `total_cost_usd`, `duration_ms`, `permission_denials`, `usage`. Measured:
  one 5-turn haiku case = $0.027 / 15.6 s; a 20-case suite ≈ <$1, ~10 min
  sequential.
- Judge pattern for fuzzy outputs: a second `claude -p` with
  `--output-format json --json-schema '<verdict schema>'` (verdict lands in
  `structured_output`), `--model haiku`.
- `claude plugin eval` (native suites: prompt.md frontmatter +
  graders/*.md) is EARLY ACCESS and gated off for this account (v2.1.251
  present, feature disabled). The case format below is deliberately parallel
  to it for later migration; nothing depends on it.
- macOS: bash 3.2, no `timeout(1)` — wall-clock guards use a backgrounded
  sleep-and-kill. Compound inline shell gets blocked by the worktree guard —
  every runner is a standalone committed script.

### Known gap pinned as xfail (binding for units 3 and 7)

`suggest_reachouts` (all six query tools are implemented) uses pending
wakeups due ≤30d (`source: attention`) else the heuristic
`staleness_ratio*10 + tier_weight*5 + open_threads*3` with a transparent
breakdown — and does **not** read profile.md or ranking-weights.json.
Integrating plan 11's artifacts into query is OUT of this plan's scope; the
recommended follow-on is a **plan 08 amendment / plan 13:
"query-personalization integration"** (opt-outs suppress suggestions, weights
multiply fallback scores). This plan authors those eval cases NOW, marked
`xfail`, so the gap is executable and cannot be silently forgotten.

**xfail discipline:** an `xfail: <reason + flip condition>` frontmatter/flag
means "expected to fail until the named integration lands." Runners count
XFAIL as suite-green; an xfail case that PASSES reports `XPASS` and turns the
suite red — the forcing function to flip it to must-pass in the same change
that lands the integration. Every xfail must name its flip condition (e.g.
`xfail: plan-13 query-personalization integration`).

### Case format (binding for units 1, 4–11; migration-friendly to `claude plugin eval`)

Each case is a directory `packages/<pkg>/evals/cases/<name>/`:

- `prompt.md` — YAML frontmatter + the task prompt as body. Frontmatter
  fields: `tier` (agent|skill), `store` (repo-relative fixture path),
  `allowed-tools` (list, T2 only), `max-turns` (default 8), `model` (default
  haiku), `budget-usd` (expected per-case cost, advisory), optional `xfail`
  (reason + flip condition), optional `runnable-when` (plan number, T3 cases
  for unbuilt skills), T3 only: `expected` (path to expected/ store).
- `graders/` — executable deterministic graders (`NN-<name>.sh` bash 3.2 or
  `NN-<name>.py` python3), each receiving the result-JSON path (T2) or the
  worked store dir (T3) as `$1`, exiting 0/1; optional `judge.md` rubric run
  via the structured-output haiku judge. A case passes when all graders pass.

Suite manifest: `packages/<pkg>/evals/suite.txt` — one case dir per line,
`#` comments allowed. The suite runner reads manifests, skips
`runnable-when` cases whose plan is unbuilt (reported as SKIP, never blank),
and prints a summary: pass/fail/xfail/xpass/skip counts + summed
`total_cost_usd`, aborting if the suite cost cap (`RA_EVAL_MAX_COST_USD`,
default 2.00) is exceeded mid-run.

## Deliverables

- `packages/core/contracts/eval-case.md` — the case-dir format, grader
  protocol, xfail discipline, suite-manifest format above; core `package.md`
  minor bump.
- `packages/core/scripts/eval-run.sh` (T2 agent runner),
  `eval-run-skill.sh` (T3 skill runner), `eval-judge.sh` (structured-output
  judge), `eval-suite.sh` (manifest runner + summary) — all bash 3.2,
  standalone, data/-path refusal built in.
- `packages/query/tests/fixtures/personalization-overlay/` (profile.md with
  a signal opt-out, ranking-weights.json with non-neutral weights, wakeup
  v1.1 files) + `packages/query/tests/test-personalization.mjs` T1 golden
  tests wired into the existing query test entry point.
- T2 cases under `packages/query/evals/cases/`: most-overdue (the verified
  PoC, codified), interpretability, opt-out-respected [xfail],
  stated-outranks-revealed, draft-never-send-read-only.
- T3 cases: `packages/ingestion/evals/cases/` wrapping the 6 existing
  preference goldens (runnable-when: 03); `packages/attention/evals/cases/`
  wrapping the tier-drift and declined-proposal fixtures (runnable-when:
  05/06).
- Suite manifests per package; `package.md` provides/consumes notes ride
  with each package's case units.

## Work units

Wave A (parallel, one message):
1. [worker] `packages/core/contracts/eval-case.md` per the case-format
   section verbatim (frontmatter fields, grader protocol, xfail discipline,
   suite manifest, SKIP semantics) + core `package.md` minor bump.
2. [worker] Personalization overlay fixtures:
   `packages/query/tests/fixtures/personalization-overlay/` — profile.md
   with one Signal opt-out (`birthday — all`) and a stated priority,
   ranking-weights.json with one boosted and one damped weight (rationales
   included), 3–4 wakeup v1.1 files (dismiss-reason, acted-on, signal-type
   variants, incl. one signal-type matching the opt-out). Overlaying them on
   `packages/core/fixtures/store` must pass `validate-store.sh`.

Wave B (parallel, after A):
3. [worker] `packages/query/tests/test-personalization.mjs` (T1, $0):
   copies fixture store + overlay to a temp dir, spawns the server per
   test-tools.mjs's pattern; four goldens — (a) opted-out signal-type absent
   from suggest_reachouts [xfail], (b) weights multiply fallback scores
   [xfail], (c) all six tools succeed against v1.1 wakeup fields [must-pass],
   (d) store byte-identical after a full tool sweep [must-pass]. XFAIL/XPASS
   accounting per the discipline above; wired into the query tests runner.
4. [worker] `packages/core/scripts/eval-run.sh` (T2): args = case dir; reads
   prompt.md frontmatter; refuses stores under `data/`; pre-checks
   query-server node_modules; copies the store to a temp dir; writes the
   mcp-config JSON (RA_CACHE_DIR → scratch, RA_CORE_SCRIPTS_DIR set); invokes
   `claude -p` per the verified contract (no --bare, temp cwd,
   --strict-mcp-config, frontmatter's allowed-tools/max-turns/model,
   --output-format json); saves result JSON; runs graders/ in order; emits
   one machine-parseable result line (PASS|FAIL|XFAIL|XPASS + cost + turns);
   backgrounded sleep-and-kill wall-clock guard (no `timeout` on macOS).
5. [worker] `packages/core/scripts/eval-run-skill.sh` (T3): args = case dir;
   copies the case's before/ store into a temp cwd; invokes `claude -p` with
   the task (no MCP config); runs graders against the worked store —
   built-in graders available to cases: exact byte-diff vs expected/, and
   "asked a question instead of writing" (result text is a question AND
   store diff is empty); same result-line format and data/-refusal as unit 4.
6. [worker] `packages/core/scripts/eval-judge.sh`: takes a judge.md rubric +
   the result JSON, runs the second `claude -p --model haiku --output-format
   json --json-schema` verdict call (schema: `{verdict: pass|fail, reason:
   string}` read from `structured_output`), exits 0/1; used by graders that
   opt in.

Wave C (parallel, after B):
7. [worker] T2 query cases, part 1 (`packages/query/evals/cases/`):
   `most-overdue/` — codify the verified PoC (fixture store, prompt "single
   most overdue reach-out?", allowed tools suggest_reachouts + get_person,
   grader greps `james-okafor` in `result`; expected budget ~$0.03);
   `interpretability/` — "why did X rank high?" must cite the score
   breakdown / rationale fields (deterministic grep for breakdown terms +
   judge.md rubric).
8. [worker] T2 query cases, part 2: `opt-out-respected/` — overlay store,
   opted-out signal-type must not be suggested [xfail: plan-13
   query-personalization integration]; `stated-outranks-revealed/` — overlay
   store where profile.md states X and behavior data implies Y, answer must
   follow X; `draft-never-send-read-only/` — agent instructed to "handle"
   a nudge; graders: store-copy byte-diff empty + no non-query tools in the
   transcript. Plus `packages/query/evals/suite.txt` listing all five and
   `packages/query/package.md` note.
9. [worker] T3 ingestion cases (`packages/ingestion/evals/cases/`): wrap the
   6 existing preference goldens (`packages/ingestion/tests/goldens/
   preferences/*`, before/ + expected/) as case dirs referencing — not
   duplicating — the golden fixtures; exact-diff grader for five,
   asks-a-question grader for the ambiguous one; all `runnable-when: 03`;
   `packages/ingestion/evals/suite.txt` + package.md note.
10. [worker] T3 attention cases (`packages/attention/evals/cases/`):
    tier-drift fixture → expected proposal wake-up appears AND no tier field
    changes (never-demote guardrail as a grader); declined-proposal fixture →
    expected silence (no new wake-up, no re-ask); both `runnable-when:
    05/06`; `packages/attention/evals/suite.txt` + package.md note.

Wave D (after C):
11. [worker] `packages/core/scripts/eval-suite.sh`: reads one or more
    suite.txt manifests, dispatches each case to the right runner by `tier`,
    honors `runnable-when` (SKIP with reason — silence impossible), enforces
    `RA_EVAL_MAX_COST_USD` (default 2.00) from summed `total_cost_usd`,
    prints the pass/fail/xfail/xpass/skip + total-cost summary, exit 0 only
    when fail = 0 and xpass = 0.

Wave E:
12. [checker] Consistency pass: eval-case.md vs. every runner's frontmatter
    parsing vs. every committed case agree on field names; every xfail names
    its flip condition; every case's store path is a fixture (nothing
    resolves under `data/`); every grader is executable and every case dir
    appears in its package's suite.txt; T1 goldens' expected values are
    hand-derived (cited), not output-copied; report mismatches file:line.
13. [worker] Fix pass from unit 12's findings (skip if clean).

## Interfaces

Consumes: query MCP server + tool surface and test-tools.mjs client pattern
(08); profile.md / ranking-weights.json / wakeup@1.1 contracts and fixtures,
ingestion preference goldens, attention drift/declined fixtures (11); the
30-persona fixture store and gen-scale-store.sh (01/08); the Claude Code CLI
on subscription auth (environment, not a package).
Produces: `eval-case@1` format (core contract) that plans 03/05/06/07 add
cases against; the four runner scripts any package's suite invokes; the
xfail set that the recommended plan-13 (query-personalization integration)
must flip to must-pass as its proof of done.

## Proof of done

- T1: `test-personalization.mjs` runs in the query test suite at $0 — cases
  (c) and (d) PASS, (a) and (b) report XFAIL (not FAIL), and the suite goes
  red on XPASS (demonstrated by temporarily inverting one expectation during
  review, then reverting).
- T2: `eval-run.sh packages/query/evals/cases/most-overdue` executes end to
  end on subscription auth (no ANTHROPIC_API_KEY set) — agent calls
  suggest_reachouts, grader finds `james-okafor`, result line reports PASS
  with real cost (~$0.03) and turn count.
- The draft-never-send case's byte-diff grader proves the store copy is
  untouched after the "handle it" run.
- Every runner refuses a store path under `data/` with a clear error;
  `eval-suite.sh` on the query manifest prints the full summary including
  XFAIL for the two integration-gap cases and total cost under the cap.
- T3: both runners' plumbing verified now — `eval-run-skill.sh` dry-run
  path (copy before/, run graders against an unmodified copy) exercises the
  exact-diff grader; the 8 skill cases exist with `runnable-when` set and
  are SKIPped, not silently absent, in suite output.
- `bash packages/core/tests/run-store-tests.sh` and
  `bash packages/connectors/tests/run-capture-tests.sh` still pass; the
  overlay-applied fixture store passes `validate-store.sh`.

## Out of scope

- Integrating profile.md / ranking-weights.json into `suggest_reachouts` —
  that is the recommended follow-on (plan 08 amendment / plan 13), whose
  proof of done is flipping this plan's xfail cases to must-pass.
- Implementing plans 03/05/06 skills — their eval cases are authored here,
  runnable then.
- `claude plugin eval` adoption (feature-gated for this account) — format
  parity only; migration is a later, separate change.
- CI, scheduled runs, or gates of any kind (delegation-without-gates stands).
- API-billed eval runs; any model above haiku as a default (per-case
  `model` override exists for deliberate exceptions).
- Evals against real user data in `data/` (permanently).

Status: Ready

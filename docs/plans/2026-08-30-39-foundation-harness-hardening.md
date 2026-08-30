# Plan 39 — Foundation & harness hardening (ROADMAP area 7)

> **Consolidation 2026-08-30 (ROADMAP Goal 5).** Build **wave A + B2–B5 only**. A2
> also absorbs plan 09's `git-guard.sh` units (repo-scoping to the machinery remote,
> `oss-guard.sh --only secrets` before `git push`) — one file, one worker. A1's required
> checks (`test` + `oss-guard-linux`) satisfy 09 deliverable 6c. B1 dropped: plan 38
> owns `test-all` perf wiring; the two bash-only unwired suites ride with A3. B6,
> C1–C4, D1 → ROADMAP Later.

**Status:** Proposed 2026-08-30 · **Branch:** `chunk-39-foundation-hardening`
**Package:** harness (`.claude/hooks`, `.github/workflows`, `scripts/test-all.sh`) +
core (contract-currency check, eval runner cap) + ingestion/attention (writer-literal
fixes, eval gate flips) + docs (plan 23 record)
**Depends on:** nothing unbuilt. Everything here is repair/insurance on things that
already shipped.

## Mission test (§1)

Pure **infrastructure for every cost** — none of this touches an ingredient. It exists
because the machinery that carries the running cost must not itself become a running
cost: a red `main`, a suite that passes only on one laptop, a contract nobody can tell
the current version of, or a plan whose record is missing all cost the *builder*
remembering-to, which is the same cost the product cuts for the user.

## Findings driving this plan (2026-08-30 audit, three read-only scouts)

| # | Finding | Evidence | Severity |
|---|---|---|---|
| F1 | `main` has **no branch protection**; PR #31 merged with a red `test` job because nothing stopped `gh pr merge` | `gh api …/branches/main/protection` → 404; PR #31 checks | HIGH |
| F2 | `git-guard.sh` commit-to-main / push-to-main checks are **TEMP-DISABLED since 2026-08-29** (lines 38–39, 64–76), so the only main-branch guard is doctrine | `.claude/hooks/git-guard.sh:38-76` | HIGH |
| F3 | CI runs the test suites on **macOS only**; Linux portability of 22 bash suites is never exercised (BSD/GNU `sed`/`date`/`awk` bugs have bitten twice already — plans 27, 06) | `.github/workflows/ci.yml` `test` job `macos-latest` | MEDIUM |
| F4 | No npm caching in CI; `npm ci` on every run | `ci.yml` | LOW |
| F5 | Three test suites exist but are **not wired** into `scripts/test-all.sh`: `ingestion/tests/run-embeddings-tests.sh`, `query/tests/run-reachouts-readonly.sh`, `query/tests/run-perf.sh` | `scripts/test-all.sh:18-85` | MEDIUM |
| F6 | Writer literals behind their contracts: `derive-user-model.sh:382` emits `schema_version: 1.0.0` (contract 1.1.0); `file-thread.sh` writes person 1.1.0 (contract 1.3.0); `gen-scale-store.sh` writes person/wakeup 1.0.0; `wakeup-queue.sh` upgrades 1.0→1.1 but never to 1.2.0. Validators accept all of them (additive contracts), so this is labeling drift, not breakage — but nothing detects it | scout report §3 | LOW–MEDIUM |
| F7 | Core fixture store (`packages/core/fixtures/store/`) is two minor versions behind on person (1.0.0 vs 1.3.0) and wakeup (1.0.0 vs 1.2.0): no `kind`, `tier_source`, event-proposal coverage in the shared fixture | scout report §5 | LOW |
| F8 | Three attention eval cases still carry `runnable-when: 06` and SKIP, though plan 06 shipped 2026-08-30 (PR #20): `tier-drift-upward`, `declined-proposal`, `tier-drift-by-kind` | `packages/attention/evals/suite.txt` | MEDIUM |
| F9 | Evals never run in CI; the full ingestion suite (~$6) exceeds the default `RA_EVAL_MAX_COST_USD=2.00`, so a full run needs a manual override every time | `packages/ingestion/evals/README.md:43-64`, `eval-suite.sh` | MEDIUM |
| F10 | ROADMAP row 23 says Done but **no plan-23 file exists** (`docs/plans/` jumps 22 → 24); the work lives only in branch `worktree-harness-context-economy` | `ls docs/plans` | LOW |
| F11 | The gitignore `*.log` trap (fixed by PR #32) had no test; a future blanket rule could re-swallow a fixture silently | `.gitignore:19-22` | LOW |

Not findings: skill symlinks all healthy; every contract consumer version-compatible;
all 12 skills have ≥1 eval case; no orphan scripts beyond harness/audit tools.

## Units

Splitting rule applied: every unit ≤3-min worker run; implementation and tests are
separate units; docs ride with the unit that changes behaviour.

### Wave A — merge safety (parallel; A1 is ops, A2–A4 workers)

| Unit | Who | Scope | Proof |
|---|---|---|---|
| **A1** | ops (orchestrator via `gh api`, user-visible) | Branch protection on `main`: required status checks `test` + `oss-guard-linux` (strict, up-to-date), no direct pushes, no force pushes, allow admins to bypass **off** | `gh api repos/{o}/{r}/branches/main/protection` returns the rule; a deliberate red PR cannot be merged via `gh pr merge` |
| **A2** | dev-worker (harness) | `git-guard.sh`: re-enable the commit-to-main and push-to-main checks (F2). Read the 2026-08-29 TEMP-DISABLED note first; if the reason (the initial commit exception) no longer applies, restore; keep the override env var so the one legitimate case is documented, not silent | hook blocks `git commit` on `main` and `git push origin main`; passes on a `chunk-*` branch |
| **A3** | dev-worker (harness) | `.github/workflows/ci.yml`: `test` job becomes a matrix `{macos-latest, ubuntu-latest}`; `actions/setup-node` with `cache: npm` keyed on `packages/query/server/package-lock.json` (F3, F4) | both matrix legs green on the PR |
| **A4** | dev-worker (harness) | `.claude/scripts/tests/run-oss-guard-tests.sh` (or a new `run-gitignore-tests.sh` wired into test-all): assert that every file under `packages/*/tests/fixtures/**` and `packages/*/evals/cases/**` is **not** ignored (`git check-ignore` over `git ls-files` + a planted `x.log` fixture) (F11) | test fails when the `!` rules are removed |

**Contract-change collateral sweep for A3:** before A3's first CI run, grep all
`packages/*/tests/run-*.sh` and `packages/*/scripts/*.sh` for `sed -i ''`, `date -v`,
`stat -f`, `\[ \t\]`, `head -c`, `mktemp -t` and dispatch fixes as one parallel wave
per package (each a separate worker) — do not discover Linux failures serially.

### Wave B — suites and writers (parallel, per package)

| Unit | Who | Scope | Proof |
|---|---|---|---|
| **B1** | dev-worker (harness) | `scripts/test-all.sh`: wire `run-embeddings-tests.sh` and `run-reachouts-readonly.sh` unconditionally (both are bash-only? verify — reachouts needs node → same gate as the query suite); `run-perf.sh` behind `--perf` (default off; plan 38 owns the targets). CLAUDE.md + README test lists updated in the same unit (F5) | `test-all.sh` prints a PASS/SKIP line for each; `--perf` runs the perf suite |
| **B2** | dev-worker (core) | `packages/core/scripts/check-contract-currency.sh` (read-only): for every `contracts/*.md` read the current `schema_version`; grep every `packages/*/scripts/*.sh` and `templates/*` for emitted `schema_version:` literals of that artifact type; report `writer <script> emits X, contract Y` and exit 1 on any writer behind current. Fixture stores are reported as WARN, never fail (F6, F7) | run on the repo today lists exactly the F6 drift; wired into `test-all.sh` as its own line |
| **B3** | dev-worker (ingestion) | `derive-user-model.sh` → 1.1.0; `file-thread.sh` person writes → 1.3.0 (fields it doesn't set stay absent — additive); `gen-scale-store.sh` in core is a **separate** unit if touched (single-writer) | `check-contract-currency.sh` clean for ingestion; ingestion suites green |
| **B4** | dev-worker (core) | `gen-scale-store.sh` emits person 1.3.0 / wakeup 1.2.0 (optional fields absent) | currency check clean for core |
| **B5** | dev-worker (attention) | `wakeup-queue.sh`: `upgrade_schema_if_needed` targets the contract's current (1.2.0) not a hard-coded 1.1.0; read the version from one place | queue suite green; a 1.0.0 fixture upgraded on write reads 1.2.0 |
| **B6** (advisory, may defer) | dev-worker (core) | Re-baseline `packages/core/fixtures/store/` to current contract versions with representative `kind`/`tier_source`/event-proposal coverage. **Collateral sweep first:** list every golden/byte-compare test that reads this fixture (`grep -rl fixtures/store packages/*/tests`) — if >3 suites depend on byte-identical output, split per suite or defer to the next fixture-touching plan | `validate-store.sh` clean; all suites green |

### Wave C — evals (after B1)

| Unit | Who | Scope | Proof |
|---|---|---|---|
| **C1** | dev-worker (attention) | Remove `runnable-when: 06` from the three gated cases; suite.txt comment updated (F8) | `RA_EVAL_DRY_RUN=1 eval-suite.sh packages/attention/evals/suite.txt` shows 6 runnable, 0 SKIP |
| **C2** | orchestrator (model spend, user-approved) | Run the attention suite once live; record PASS/FAIL per case in this plan; any FAIL → one fix round max, then escalate | 6/6 or a named residual |
| **C3** | dev-worker (core) | `eval-suite.sh`: per-manifest cost cap — `suite.txt` may declare `# max-cost-usd: 6.00` in its header, overriding the global default; README documents it (F9) | full ingestion suite runs without a CLI override; dry-run parses the header |
| **C4** | dev-worker (harness) | `.github/workflows/evals.yml`: **manual** `workflow_dispatch` (never on PR) running `RA_EVAL_SMOKE=1` across the three manifests with the API key from a repo secret; uploads `.last-run.tsv` as an artifact; job is skipped with a clear line when the secret is absent (F9) | a dispatched run completes and reports 9 smoke outcomes |

### Wave D — record and review

| Unit | Who | Scope | Proof |
|---|---|---|---|
| **D1** | orchestrator (docs) | Write `docs/plans/2026-08-29-23-harness-context-economy.md` retroactively from the `worktree-harness-context-economy` branch history (objective, what landed in `.claude/rules` / `.claude/context`, proof) so the row has a record (F10) | file exists; ROADMAP row 23 links it |
| **D2** | orchestrator (docs) | ROADMAP area 7 row 39 → Done with PR; `docs/SETUP.md` gets the branch-protection line under a "contributing" note; memory note | — |
| **D3** | checker | Wave review: hooks still block what they blocked before (git-guard tier list unchanged apart from re-enabled main checks); no `packages/` writer emits a stale version; CI matrix green on both OSes; `oss-guard.sh` clean | CLEAN or findings ≤ MEDIUM |

## Order and sizing

A1 ‖ A2 ‖ A3 (+ its collateral sweep wave) ‖ A4 → B1 ‖ B2 ‖ B3 ‖ B4 ‖ B5 (B6 only if
the collateral sweep says ≤3 suites) → C1 → C2 (user-approved spend) ‖ C3 ‖ C4 → D1 ‖
D2 → D3. Twelve worker units, one ops unit, one paid eval run. Two PRs: `A+B` (merge
safety + suites) and `C+D` (evals + records) so the branch-protection change lands
first and gates the second PR itself.

## Done when

- A deliberately red PR **cannot** be merged to `main` (protection + hook both refuse).
- `test-all.sh` passes on macOS **and** Ubuntu in CI, with every existing suite wired
  and a currency check that would have flagged F6 on day one.
- No writer script emits a `schema_version` behind its contract.
- Attention evals: 0 SKIP; a full ingestion eval run needs no cost override.
- Plan 23 has a file. Row 39 → Done.

## Explicitly not in this plan (stays "deliberately absent" per `.claude/rules/INDEX.md`)

Gate system, attestation, agent-lint, task triage, worktree lifecycle (Harness Stage
2+). Revisit only when CI has something worth gating beyond what A1 provides.
Retrieval performance targets → plan 38. Store-sync / heartbeat / egress → plan 09 v2.

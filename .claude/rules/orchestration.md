# Orchestration rules

The load-bearing mechanics of dispatch. The main conversation orchestrates and
never edits production code; workers do the edits; checkers do the reading.

## Concurrency tiers

| Tier | Cap | Agents | Rationale |
|---|---|---|---|
| 1 — read-only | **40** | `*-checker` (locators, analyzers, reviewers) | No side effects; safe at high concurrency |
| 2 — mutating | **15** | `*-worker` (dev, scaffold, fix, commit workers) | Race on test DB, dev port, git index, shared files |

More units than the cap → **rolling pool**: spawn the first N in one parallel
message, refill as each finishes. The budget is **global** — nested lead agents
share the same pool as the main conversation; any lead's brief must declare its
worker budget so the parent can reserve it.

## Splitting rule (mandatory)

| Independent units | Action |
|---|---|
| 1–2 | Single dev-worker |
| 3–5, same package | Two dev-workers split by file/module, one parallel message |
| 6+ or cross-package | One dev-worker per package/module, all in one parallel message |

- Size every brief for a **≤3-minute run** (treat 5 minutes as an alarm).
  Plausibly longer → split before spawning, not after it times out.
- Implementation + its test suite = **TWO units** (separate workers) unless the
  tests are trivial. Companion-doc updates ride with the implementation unit.
- A whole-UI-surface noun in a brief ("revamp header/page/modal") counts as
  3+ units regardless of file count — decompose per component.
- Fix briefs are not exempt: never bundle implementation + doc updates + test
  authoring + verification in one brief. Cut the verification tail — a later
  pass re-runs it.
- A dev-worker prompt with a bulleted list of **4+ independent items** is the
  tell: stop and split.

## Context economy (workers start warm)

Cold workers re-reading CLAUDE.md, manifests, and contracts before their first
edit is the dominant latency cost of dispatch. Four rules:

- **Briefs carry content, not pointers.** Whoever wrote the brief has already
  read the contract, type, or exemplar — paste the relevant excerpt into the
  brief verbatim (template §2/§4). Litmus: a worker forced to open more than
  ~2 files before its first edit got an underspecified brief.
- **Reuse warm workers.** For serial units in the same package, continue that
  package's existing dev-worker via SendMessage instead of spawning fresh —
  it already holds the layout, contracts, and test commands from its first
  unit. Spawn fresh only for parallelism across packages/modules; at most one
  warm worker per package at a time (single-writer rule).
- **Fork when the orchestrator already holds the context.** `subagent_type:
  "fork"` clones this conversation into the worker — use it when the session
  has already done the investigation (e.g. the fix right after a debugging
  session). Never fork clean-slate units; inherited context is pure waste there.
- **Manifests stay capsule-sized.** `package.md` is the one file a cold worker
  legitimately must read; keep it tight enough that one read is sufficient
  orientation, and tighten it when it drifts into prose.

## Turn economy & monitoring

- Batch independent Bash calls into one message; never poll in foreground;
  mechanical ≥2-step sequences become wrapper scripts.
- **Verify-then-monitor:** confirm the subject exists (process spawned, run
  created) before arming any watch.
- **Silence must be impossible:** any monitor/filter must emit every terminal
  state, including NOT_FOUND — blank output is never a valid outcome.
- No long command runs under the default 120s Bash timeout; pair every long
  watch with a deadman wakeup.
- Retry briefs carry the prior attempt's diff and failure output — attempt 2
  never re-diagnoses from zero.
- **Contract-change collateral sweep:** when a shared type/validator/signature
  changes, grep the whole repo for call sites BEFORE the first check run and
  dispatch all repairs as one parallel wave — not serially as failures surface.

## Fix policy (condensed)

Severity drives action: CRITICAL/HIGH findings in the current diff block until
fixed; MEDIUM blocks only if resolvable in scope, else it is recorded as
advisory; LOW is advisory. Out-of-scope HIGH findings are escalated to the
user, never silently absorbed into scope. **Max 2 fix-dispatch rounds** per
pass; after that, escalate to the user rather than looping.

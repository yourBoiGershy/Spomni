# Relationship Agent — Project Doctrine

**Mission: what a friendship is made of, without what it costs to keep.**
A relationship is made of trust, care, intent, and time; what makes it hard
to keep is its *running cost* (coordinating, following up, scheduling,
restarting, remembering-to), which adds nothing to the bond. Spomni — an
open-source, local-first personal assistant — carries the running cost
(business, friends, family) and never touches the ingredients. It nudges and
drafts; the human always sends. This repo holds the machinery; user data
never lives here (see `data/README.md`). Full mission + scenario map:
`docs/USE-CASES.md`.

**The mission test** (every chunk, plan, and brief §1 answers it): *does
this cut a running cost, or substitute for an ingredient?* Only cost-cutting
is built. Substituting for trust/care/intent/time — auto-send, generic
drafts, engagement metrics, performing the relationship for the user — is
permanently out of scope.

## Standing principles (non-negotiable)

- **Draft, never send.** The agent proposes messages; a human holds the send
  button, always. No integration may auto-send outreach.
- **Capture is optional and lossy-tolerant.** Missed debriefs cost nothing —
  no badges, no streaks, no backlog guilt. The agent never prompts during the
  relationship's own time (before/right after a meeting).
- **Provenance labeling.** Facts about people are marked told-by-the-user vs.
  inferred-from-public-web, never mixed.
- **Other people's data stays local.** No LinkedIn scraping, no enrichment
  APIs; the people-store (the contact graph) lives only in the user's private
  data dir — no third-party cloud ever holds it. Access to the user's own
  accounts flows through the first-party claude.ai connectors (Gmail, Google
  Calendar) the user explicitly links (see DECISIONS.md `composio-retired`) —
  the pipes, never the store.
- **Code and data are separate.** This public repo is machinery only. Each
  user's people-store lives in their own private location; `data/` is
  gitignored and typically points at a private repo.

## Architecture spine

Connectors in → `inbox/` (normalized capture events, raw kept forever) →
filing engine → people store (`people/`, `interactions/`, index) → signal
engine → wake-up queue → connectors out.

## Packages

The machinery lives in five packages under `packages/` — `core` (versioned
contracts, templates, store scripts, fixtures), `connectors` (all outside-world
I/O, dumb, sub-package per lane), `ingestion` (filing, matching, links),
`attention` (signals + wake-up queue + sweeps), `query` (read-only answers +
briefs). **Single-writer rule:** each runtime artifact type has exactly one
writing package; siblings communicate only through core's contracts, declared
in each `package.md` manifest as provides/consumes with versions. Product
skills live in `packages/<pkg>/skills/` and are symlinked into
`.claude/skills/` so Claude Code exposes them as slash commands; the only
real directories there are the harness skills (`explore`, `implement`).
Full detail: `docs/PROJECT-CONTEXT.md` (Packages section).

---

# Harness Doctrine (delegation model)

Simplified delegation-focused harness (derived from the Harness Core
Blueprint — Stage 1 + the delegation core of Stage 3). Deep detail in
`.claude/rules/` — see `.claude/rules/INDEX.md`.

## Orchestration model

- **The main conversation orchestrates; it never edits production code.**
  Production code here = the assistant's machinery: everything under
  `packages/` (manifests included — manifest edits go through workers too)
  plus `.claude/skills|agents|scripts|hooks/` (hook-enforced). All such edits
  go to scoped worker agents. `docs/`, `data/`, and root markdown stay
  orchestrator-editable for planning.
- **Concurrency caps:** read-only agents (`*-checker`) up to **40**
  concurrent; mutating agents (`*-worker`) up to **15**. Over the cap →
  rolling pool: spawn the first N in one parallel message, refill as each
  finishes.
- **Agent naming is load-bearing:** `*-checker` = read-only (writes blocked by
  hook), `*-worker` = mutating. Name new agents accordingly.

## Splitting rule (mandatory)

| Independent units | Action |
|---|---|
| 1–2 | Single dev-worker |
| 3–5, same module | Two dev-workers split by file/module, one parallel message |
| 6+ or cross-module | One dev-worker per module, all in one parallel message |

- Size every brief for a **≤3-minute run**. Plausibly longer → split before spawning.
- Implementation + its test suite = **two units** (separate workers) unless tests are trivial.
- A worker brief with a bulleted list of **4+ independent items** is the tell: stop and split.

## Completion reports

Every agent's final message ends with the completion-report block
(`.claude/context/completion-report-block.md`): STATUS, what changed, files
touched, evidence — wrapped in `<!-- AGENT_OUTPUT_START/END -->` markers.

## Git safety (hook-enforced)

- Never work on or push `main` (the repo's initial commit was the one
  exception). Branch first.
- Sync via `git merge main`, never rebase.
- Replace broken commits with new commits — never `--amend`, never force push.
- No `--no-verify`. No destructive git (see `.claude/hooks/git-guard.sh` tier list).

## Project bindings

- Protected edit prefixes for the orchestrator guard:
  `.claude/skills/ .claude/agents/ .claude/scripts/ .claude/hooks/ packages/`
  (override via `HARNESS_PROTECTED_PREFIXES` in the hook's environment).
- One package = one focused agent/session's territory; cross-package needs are
  met via the other package's `package.md` + core contracts, never its files.
- Test commands (bash 3.2, no npm/jest — run all before any merge). The
  one-shot wrapper is `bash scripts/test-all.sh` (every suite below, the
  query suite when node is present, plus `.claude/scripts/oss-guard.sh`; CI
  runs the same). Individually:
  `bash packages/core/tests/run-store-tests.sh`,
  `bash packages/connectors/tests/run-capture-tests.sh`,
  `bash packages/connectors/tests/run-beeper-capture-tests.sh`,
  `bash packages/connectors/tests/run-scheduler-tests.sh`,
  `bash packages/ingestion/tests/run-seed-tests.sh`,
  `bash packages/ingestion/tests/run-triage-tests.sh`,
  `bash packages/ingestion/tests/run-shard-tests.sh`,
  `bash packages/attention/tests/run-attention-tests.sh`,
  `bash packages/attention/tests/run-capacity-tests.sh`, and
  `bash packages/attention/tests/run-queue-tests.sh`,
  `bash packages/query/tests/run-query-tests.sh` (needs node ≥ 22.6 +
  `npm ci` in `packages/query/server`), and
  `bash .claude/scripts/tests/run-oss-guard-tests.sh`.
  Open-source guard (data-dir tripwire, secrets/PII scan, never-send lint,
  enrichment denylist): `bash .claude/scripts/oss-guard.sh`.
  Store sanity: `bash packages/core/scripts/validate-store.sh <store-dir>`
  (checks people/interactions/wakeups only — not inbox/).
  Capture-sync audit: `bash packages/connectors/scripts/check-sync.sh <store-dir>`
  (inbox/ conformance to capture-event 1.2.0 — per-lane rules, wrapper leaks, dups).
  Filing goldens: `bash packages/ingestion/scripts/check-golden.sh --all
  packages/ingestion/tests/goldens/debrief <worked-root>`; eval suites:
  `bash packages/core/scripts/eval-suite.sh packages/<pkg>/evals/suite.txt`.
  <!-- PARAMETERIZE: extend as more packages grow suites -->

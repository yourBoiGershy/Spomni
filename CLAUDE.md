# Relationship Agent — Project Doctrine

An open-source, local-first personal assistant that helps its user maintain
relationships (business, friends, family) by remembering — people, context,
signals, and reasons to reach out. It nudges and drafts; the human always
sends. This repo holds the machinery; user data never lives here (see
`data/README.md`).

## Standing principles (non-negotiable)

- **Draft, never send.** The agent proposes messages; a human holds the send
  button, always. No integration may auto-send outreach.
- **Capture is optional and lossy-tolerant.** Missed debriefs cost nothing —
  no badges, no streaks, no backlog guilt. The agent never prompts during the
  relationship's own time (before/right after a meeting).
- **Provenance labeling.** Facts about people are marked told-by-the-user vs.
  inferred-from-public-web, never mixed.
- **Other people's data stays local.** No LinkedIn scraping, no enrichment
  APIs, no third-party clouds holding the contact graph. First-party
  connectors (user's own Gmail/Calendar/Contacts via official MCP/connectors)
  plus whatever the user explicitly plugs in.
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
skills live in `packages/<pkg>/skills/`; `.claude/skills/` is harness-only.
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
- No build/test commands yet — when the first scripts land, add typecheck/
  lint/test commands here and in `/implement` step 4.
  <!-- PARAMETERIZE: fill in when the project grows real tooling -->

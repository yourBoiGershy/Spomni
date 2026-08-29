# Relationship Agent

An open-source, **local-first personal assistant for maintaining your
relationships** — business, friends, family. It remembers who people are,
what happened with them, and why now might be a good moment to reach out
(a birthday, a job change, an event you'll both attend) — then nudges you
with context and an optional draft. **It drafts; you send.** Always.

The design in one line: connectors feed a capture inbox → a filing engine
builds a markdown people-store → a signal engine finds reasons to reach out →
a wake-up queue delivers them when due. Your data never lives in this repo —
`data/` is gitignored and points at your own private store
(see `data/README.md`).

## Principles

- **Draft, never send** — a human holds the send button.
- **Capture is optional and lossy-tolerant** — no streaks, no guilt.
- **Provenance labeling** — told-by-you vs. inferred-from-public-web, never mixed.
- **Other people's data stays local** — no scraping, no enrichment APIs,
  first-party connectors only.
- **Code and data are separate repos.**

## Current state

The repo currently contains the **agent harness** — the delegation machinery
the assistant is built with — plus the project skeleton. The assistant's own
contracts and skills (debrief filing, query, briefs, wake-ups) land next, per
the build plan.

## The harness (delegation model)

A deliberately simple core extracted from the "Harness Core Blueprint"
(Stage 1 + the delegation slice of Stage 3), focused on subagents and proper
delegation:

| Piece | Purpose |
|---|---|
| `CLAUDE.md` | Project doctrine + orchestration doctrine (orchestrate-don't-edit, caps, splitting rule, git safety) |
| `.claude/rules/orchestration.md` | Full dispatch mechanics |
| `.claude/hooks/` | Enforcement: `git-guard` (destructive git blocked), `checker-readonly` (checkers can't write), `orchestrator-edit-guard` (main session can't edit machinery under `packages/` or `.claude/skills|agents|scripts|hooks`), spawn + tool-call JSONL loggers |
| `.claude/agents/` | Minimal roster: `dev-worker` (sonnet), `codebase-locator-checker` + `codebase-analyzer-checker` (haiku), `plan-architect` (inherit) |
| `.claude/context/` | 4-section agent brief template + completion-report block |
| `.claude/skills/` | `/explore` (parallel read-only scouting), `/implement` (split → brief → fan out → consolidate → commit per phase) |

Naming is load-bearing and hook-enforced: `*-checker` = read-only,
`*-worker` = mutating.

**Deliberately skipped, adopt later from the blueprint as the project earns
them:** gate system + shipping contract (§05), attestation (§06), the
`/quality → /commit → /pr → /ship` pipeline (§07), agent-lint (§10), task
triage (§04), worktree lifecycle, nested leads (§08).

## Repo layout

```
CLAUDE.md          project + harness doctrine
.claude/           harness: rules, hooks, agents, harness skills, context templates
packages/          the assistant, five packages (see docs/PROJECT-CONTEXT.md):
├── core/          versioned contracts, templates, store scripts, fixtures
├── connectors/    all I/O, dumb: gmail-in, calendar-in, contacts-in, file-out, gmail-out
├── ingestion/     filing engine, attendee matching, links, provenance
├── attention/     signals + ranking + wake-up queue + sweeps
└── query/         read-only answers + pre-meeting briefs ("the project's MCP")
docs/plans/        implementation plans (ROADMAP.md maps plans → packages)
data/              YOUR private store (gitignored; see data/README.md)
```

Work happens on branches; the initial commit is the one allowed commit on
`main` — the git-guard hook blocks main commits/pushes from then on.

## Smoke test — verifying delegation works

Start a Claude Code session in this repo (hooks load from
`.claude/settings.json`) and check four behaviors:

1. **Orchestrator delegates:** ask for a trivial two-file change under
   `packages/core/templates/` — the session should spawn dev-worker(s) rather
   than editing directly; if it tries, `orchestrator-edit-guard.sh` blocks
   with a pointer to the splitting rule.
2. **Spawn trail exists:** `.claude/logs/agent-spawns.jsonl` gains one line
   per spawn (and `tool-calls.jsonl` accumulates).
3. **Checkers are read-only:** ask a `codebase-locator-checker` to "fix" a
   file — its Write is blocked by `checker-readonly.sh` (exit 2).
4. **Git guard bites:** `git push --force`, or a commit while on main —
   blocked with `BLOCKED: <reason>`.

Hooks can also be exercised directly, no session needed:

```sh
echo '{"tool_input":{"command":"git push --force"}}' | bash .claude/hooks/git-guard.sh
# → exit 2, "BLOCKED: force push"
```

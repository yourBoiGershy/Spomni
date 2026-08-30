# Architecture

How Spomni is built. The mission and the standing principles are in the
README and `PROJECT-CONTEXT.md`; this page is the machinery.

## The spine

One pipeline connects everything:

```
Connectors in → inbox/ → Filing engine → People store → Signal engine → Wake-up queue → Connectors out
```

| Stage | What it does | Package |
|---|---|---|
| **Connectors in** | Fetch from a source (Gmail, Google Calendar, Beeper chats) and write normalized *capture events* into `inbox/`. Raw text is kept forever. Connectors never interpret, match, rank, or file. | `connectors` |
| **Filing engine** | Turns captures and debriefs into `people/` and `interactions/` files: attendee↔person matching, links, provenance labels, priority-tier suggestions (confirm-first). | `ingestion` |
| **People store** | Markdown files + a generated `index.json`/`stats.json`. The single source of truth, in the user's private dir. | written by `ingestion`, read by all |
| **Signal engine** | Watches for reasons to reach out (birthday, job change, lull, a promise coming due) and proposes signal events. | `attention` |
| **Wake-up queue** | The only scheduling primitive: dated entries with who / why / context / optional draft. Reminders, birthdays, and detected signals are the same object. | `attention` |
| **Connectors out** | Render fired wake-ups, briefs, and answers to where the user reads them. Never sends. | `connectors` |
| **Query** | Read-only MCP server (`spomni-query`, 6 tools) + briefs: "who do I know at…", "who should I reach out to". | `query` |

Everything runs on the user's machine: bash 3.2 scripts, one small Node
server, Claude Code as the reasoning layer, optional Ollama for local
embeddings. The user's accounts are reached only through first-party
claude.ai connectors (the pipes); the store is never held by any cloud.

## The five packages

```
packages/
├── core/          contracts (versioned), templates, store scripts, fixtures — the vocabulary
├── connectors/    ALL outside-world I/O, both directions, deliberately dumb
│   ├── gmail-in/  calendar-in/  beeper-in/  contacts-in/   # fetch → capture events
│   └── file-out/  gmail-out/                               # rendered batch → destination (drafts, never sends)
├── ingestion/     filing engine, matching, links, provenance, tiers
├── attention/     signals, ranking, wake-up queue lifecycle, sweeps
└── query/         read-only answers + briefs — the project's MCP server
```

Grouping follows **artifact ownership**, not feature names. Three rules keep
the packages from overlapping:

1. **Single writer per artifact type.**

   | Artifact | Sole writer |
   |---|---|
   | `inbox/` (capture events) | connectors (input side) |
   | `people/`, `interactions/`, `index.json` | ingestion |
   | `wakeups/` lifecycle (fire/snooze/dismiss) | attention — creation open to all via core's `wakeup-add.sh` |
   | outbound deliveries | connectors (output side) |

2. **Dumb edges, smart middle.** Connectors fetch and deliver; the middle
   packages interpret.
3. **Siblings talk only through core's contracts.** Each package declares
   what it provides and consumes, with versions, in its `package.md`
   manifest. Dependency direction: core ← everyone; no package imports
   another's internals.

Each package's `package.md` is its capsule: contracts, scripts, skills,
tests. Read that before its code.

## Contracts

`packages/core/contracts/` holds the versioned schemas every package speaks:

| Contract | Governs |
|---|---|
| `capture-event.md` | What a connector writes into `inbox/` (source, timestamp, participants, raw text) |
| `person.md`, `interaction.md` | Frontmatter + prose shape of store files; provenance fields |
| `wakeup.md` | Queue entries and their lifecycle |
| `derived-index.md` | `index.json` / `stats.json` and the cache in `${SPOMNI_CACHE_DIR:-~/.cache/spomni}` |
| `sync-lanes.md` | The scheduler's `lanes.tsv` |
| `import-pipeline.md` | Onboarding backfill and triage |
| `eval-case.md` | The eval harness's case format |

Contracts are semver'd; a change bumps the version and every consuming
manifest. Golden tests are written before prompts wherever LLM behaviour is
being specified.

## The store (your private data dir)

```
inbox/          unprocessed capture events (raw text archived forever)
people/         one markdown file per person: frontmatter + free prose
interactions/   one note per debrief / meeting, linked to people + events
wakeups/        the queue: pending / fired / snoozed / dismissed
index.json      generated: person → tags, org, location, last-touch, tier
stats.json      generated: touchpoints, gaps, threads, commitments
user-model.md   optional: what the user has confirmed about their own priorities
```

The repo's `data/store` is a gitignored path (or symlink) pointing here.
`packages/core/scripts/init-store.sh` creates the layout;
`check-store-location.sh` refuses locations that would leak (inside the code
repo, inside a sync folder); `validate-store.sh` checks the files.

## Skills

Product skills — the things a user invokes — live in
`packages/<pkg>/skills/<name>/SKILL.md` and are symlinked into
`.claude/skills/` so Claude Code exposes them as slash commands:

| Skill | Package | Does |
|---|---|---|
| `/debrief` | ingestion | files a rambly post-meeting note |
| `/onboarding-seed` | ingestion | backfills history from linked accounts, suggests tiers |
| `/review-tiers` | ingestion | re-scores priority tiers; writes only what you confirm |
| `/gmail-sweep`, `/calendar-sweep` | connectors | capture from the linked accounts |
| `/event-confirm`, `/scheduling-intent` | attention | turn calendar + chat into wake-ups |

`.claude/skills/explore` and `/implement` are for contributors working on
the repo itself (see `CLAUDE.md`).

## Scheduling

`packages/connectors/scripts/sync-scheduler.sh` renders one launchd agent
per enabled lane in `lanes.tsv` (`com.spomni.sync.<lane>`). Beeper capture is
schedulable today; Gmail/Calendar sweeps run from a session until the
headless lane runner ships (ROADMAP chunk 28). Linux/systemd is an open
contribution.

## Testing

`bash scripts/test-all.sh` runs every package suite plus `oss-guard`. Suites
are plain bash against committed synthetic fixtures — no live data, no
network. The eval harness (`packages/core/scripts/eval-suite.sh`) drives
Claude against golden cases and is run deliberately, not in CI.

## Further reading

- `PROJECT-CONTEXT.md` — the canonical context capsule (mission, glossary,
  bound research)
- `DECISIONS.md` — every decision with its rationale
- `ROADMAP.md` — chunk order and status; `plans/` — the per-chunk plans
- `data-layout.md`, `chat-setup.md` — store layout and the query server in
  more depth

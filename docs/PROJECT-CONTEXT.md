# Project Context

The canonical context capsule. Every plan in `docs/plans/` and every agent brief references
this document instead of restating it. If something here changes, it changes here first,
with a matching entry in [DECISIONS.md](DECISIONS.md).

## What this is

**Mission.** A relationship is made of trust, care, intent, and time. None of
those are what makes it hard to keep. What makes it hard is what the
relationship *costs to run* — the coordinating, following up, scheduling,
restarting, remembering-to — and none of that adds a gram of trust. Spomni
gives you **what a friendship is made of, without what it costs to keep.**

**The mission test** — every chunk, plan, brief, and feature answers it:
*does this cut a running cost, or does it substitute for an ingredient?*
Cutting cost is in scope. Substituting for trust, care, intent, or time —
auto-sending, generic drafts, engagement metrics, anything that performs the
relationship on the user's behalf — is out of scope, permanently.
(Decision: `mission-ingredients-vs-running-cost`.)

Concretely: an open-source, local-first personal agent that carries the running cost of the
user's relationships — business, friends, family — by noticing when a moment is good and
handing over context plus a draft in the user's voice. It **drafts, but never sends**: the
human always holds the send button. The user's core problem is bandwidth, not willingness;
memory and noticing are *inputs* the agent uses to cut the other costs (timing, deciding-who,
starting, following-through) — never a replacement for the relationship itself. The
scenario map lives in [USE-CASES.md](USE-CASES.md).

Primary user story shapes:
- "Who do I know in marketing / fintech / healthcare data?"
- "You met Dana Tuesday — anything worth remembering?" (agent asks, user rambles, agent files)
- "It's X's birthday Thursday; last time you spoke she was prepping the Berlin move — here's a draft."
- "Remind me to sync back up with him in a month" → it fires in a month, with context resurfaced.

## The spine

One pipeline connects everything:

```
Connectors in → Inbox → Filing engine → People store → Signal engine → Wake-up queue → Connectors out
```

- **Input connectors** have exactly one obligation: write normalized capture events into `inbox/`.
- The **filing engine** turns raw captures into structured people/interaction files and links.
- The **people store** (markdown + `index.json`) is the single source of truth.
- The **signal engine** watches for reasons to reach out and proposes signal events.
- The **wake-up queue** is the only scheduling primitive: dated entries with who/why/context/draft.
  Explicit reminder asks, birthdays, and detected signals are all the same object.
- **Output connectors** render fired wake-ups, briefs, and query answers to wherever the user wants.

## Packages

The machinery is organized as five packages. Grouping follows **artifact ownership**,
not feature names (see DECISIONS.md: package-architecture, attention-merge).

```
packages/
├── core/          # contracts (versioned), templates, store scripts, fixtures — the vocabulary
├── connectors/    # ALL outside-world I/O, both directions, deliberately dumb
│   ├── gmail-in/  calendar-in/  contacts-in/   # fetch → normalized artifacts
│   └── file-out/  gmail-out/                   # rendered batch → destination
├── ingestion/     # data malleability: filing engine, attendee↔person matching, links, provenance
├── attention/     # signals + scheduler: detectors, ranking, wake-up queue lifecycle, sweeps
└── query/         # read-only answer surface: query skill, briefs — "the project's MCP"
```

**Single-writer rule** — every runtime artifact type has exactly one writing package:

| Artifact | Sole writer |
|---|---|
| `inbox/` (capture events) | connectors (input side) |
| `people/`, `interactions/`, `index.json` | ingestion |
| `wakeups/` lifecycle (fire/snooze/dismiss) | attention — creation open to all via core's `wakeup-add.sh` |
| outbound deliveries | connectors (output side) |

**The three no-overlap rules:**
1. **Single writer per artifact type** (table above). If a new feature needs to write
   someone else's artifact, it belongs in that package or goes through a core script.
2. **Dumb edges, smart middle** — connectors fetch and deliver; they never interpret,
   match, rank, or file.
3. **Siblings communicate only through core's contracts**, declared in each
   `package.md` manifest as provides/consumes with versions. Dependency direction:
   core ← everyone; siblings never import siblings' internals.

Product skills live inside their package (`packages/<pkg>/skills/`); `.claude/skills/`
holds only harness skills (`/explore`, `/implement`). Packages stay `0.x` until the
live trial; contracts are semver'd from day one. Each package's plan + contracts +
golden tests are its durable spec — implementations are regenerable from them.

## Code vs. data

This repo is machinery only. Each user's people-store lives in their own private location
(`data/` is gitignored; users point it at a private repo or directory). Contact graphs are
other people's PII — they never enter this repo, any third-party cloud, or any aggregator.

Store shape (inside the private data dir):
```
inbox/          # unprocessed capture events (raw text archived forever)
people/         # one markdown file per person, frontmatter + free prose
interactions/   # one note per debrief/meeting, linked to people + events
wakeups/        # the queue: pending/fired/snoozed/dismissed entries
index.json      # auto-generated: person → tags, org, location, last-touch
```

## Standing principles (binding, also in CLAUDE.md)

1. **Draft, never send.**
2. **Capture is optional and lossy-tolerant** — no badges, streaks, or backlog guilt; a missed
   debrief costs nothing; un-debriefed meetings are mentioned once, then dropped silently.
3. **Never prompt during the relationship's own time** — no pings around the meeting itself.
4. **Provenance labeling** — facts are marked told-by-user vs. inferred-from-public-web, never mixed.
5. **Other people's data stays local** — no LinkedIn scraping, no enrichment APIs, no aggregator
   holding credentials; first-party connectors only, plus whatever the user explicitly plugs in.
6. **Give more than you ask** — target ≥3:1 useful output to capture prompts.
7. **Nudges carry a trigger and ammunition** — never bare cadence ("it's been 90 days").
8. **The mission test** — every chunk, plan, and brief states which running cost it cuts
   and which ingredient it stays clear of. Features that substitute for an ingredient are
   never built (decision: mission-ingredients-vs-running-cost).

## Bound research findings (Aug 2026 — see DECISIONS.md for the why)

- **Integrations**: Google runs official MCP servers for Gmail/Calendar/Contacts; Slack has an
  official MCP server; claude.ai connectors work inside Claude Code. Core integration strategy is
  first-party MCP/connectors — zero new vendors. Composio-class aggregators are an optional
  escape hatch, never a dependency (Composio's Aug 2026 repricing is the cautionary tale).
- **LinkedIn**: no legitimate API path exists; scraping/enrichment (Proxycurl, sued and shut down
  July 2026) risks account bans. Clean substitutes: LinkedIn's own notification emails parsed from
  the user's inbox, email-signature diffing, LinkedIn's manual CSV export.
- **The v1 signal set (all ToS-clean)**: Google Contacts birthdays; job changes via notification
  emails + signature diffs + web search; company news via web search + SEC EDGAR; event
  co-attendance via calendar attendees + confirmation emails; LinkedIn posts via "ring the bell"
  notification emails (best-effort); debrief harvesting.
- **Nudge quality**: rank warmth × rarity; cap ~5 active nudges; two independent signals for
  high priority; prefer signals the crowd doesn't see, or nudge late ("settled in?" three weeks
  after a job change); dismiss/snooze feedback tunes ranking.

## Glossary

| Term | Meaning |
|---|---|
| capture event | Normalized raw input in `inbox/` (voice-note email, LinkedIn notification, transcript…) with source, timestamp, participant hints |
| debrief | The user's rambly post-interaction note; the filing engine structures it |
| interaction | A filed record of one touchpoint, linked to people and calendar events |
| signal event | A detected reason to reach out (birthday, job change, news, co-attendance) — a proposal, not yet a nudge |
| wake-up | A dated queue entry: due date, who, why, context, optional draft; the only scheduling primitive |
| ammunition | The context attached to a nudge: what you know + the evidence + optionally a draft |
| sweep | A scheduled background run: process inbox, reconcile calendars, run signals, fire due wake-ups |
| brief | Pre-meeting one-pager: store facts + fresh public research, provenance-labeled |
| connector (in/out) | Input: anything writing valid capture events. Output: anything rendering content to a destination |

## How work gets done here

This repo carries a delegation harness (see CLAUDE.md and `.claude/rules/orchestration.md`):
the main conversation orchestrates and never edits machinery; scoped workers implement;
`*-checker` agents are read-only (hook-enforced). **One package = one focused
agent/session's territory** — a session (or worker wave) owns a single package at a
time, and cross-package needs are met by reading the other package's manifest and
contracts, never by editing its files. Plans live in `docs/plans/` and follow the
shared template; [ROADMAP.md](ROADMAP.md) tracks chunk order, package mapping, and status. Golden tests are
written before prompts wherever an LLM behavior is being specified.

## External references

- Build-plan artifact (shareable view): https://claude.ai/code/artifact/73087710-83ac-40a1-851a-ce1462e74d2e
- Harness Core Blueprint (full gates/attestation spec, for later adoption): the "Harness Core
  Blueprint" artifact in the owner's gallery

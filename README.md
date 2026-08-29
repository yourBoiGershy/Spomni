# Spomni

An open-source, **local-first agent that keeps your relationships alive** —
business, friends, family — by doing the remembering, so the time you spend
on people goes into the relationship itself.

## The problem

Relationships rarely end on purpose; they fade. Staying close to everyone you
actually care about takes a kind of bookkeeping nobody has bandwidth for:
holding what's going on in each person's life, noticing the moment a reach-out
would land (a birthday, a job change, an event you'll both attend), following
through on "we should catch up soon." The willingness is there — the working
memory isn't. Spomni is that working memory.

## The division of labor

Spomni draws one deliberate line, and everything in the design follows from it:

- **The agent keeps the connection alive.** It remembers people, context, and
  what happened last time. It watches for genuine reasons to reach out and
  wakes you up at the right moment — with the context and an optional draft.
- **You do the relationship.** The conversation, the warmth, the judgment,
  the send button — always human. Spomni is external memory plus an attention
  allocator, never a stand-in for you.

What that looks like in practice:

- *"Who do I know in fintech?"* — answered from your own store.
- *"You met Dana Tuesday — anything worth remembering?"* You ramble; it files.
- *"It's Ana's birthday Thursday; last time you spoke she was prepping the
  Berlin move — here's a draft."* You edit and send. Or don't.
- *"Remind me to sync back up with him in a month."* It fires in a month,
  context resurfaced.

## Principles (non-negotiable)

- **Draft, never send** — a human holds the send button; no integration may
  auto-send outreach.
- **Capture is optional and lossy-tolerant** — no badges, no streaks, no
  backlog guilt; a missed debrief costs nothing.
- **The relationship's time is sacred** — no prompts before or right after a
  meeting; the agent works around your relationships, never inside them.
- **Provenance labeling** — facts are marked told-by-you vs.
  inferred-from-public-web, never mixed.
- **Other people's data stays local** — no LinkedIn scraping, no enrichment
  APIs. The contact graph lives only in your private data dir; your own
  accounts are reached through connectors you explicitly link — pipes, never
  the store.
- **Give more than it asks** — target ≥3:1 useful output to capture prompts.
- **Nudges carry a trigger and ammunition** — a real reason plus the context
  to act on it, never bare cadence ("it's been 90 days").
- **Code and data are separate.** This repo is machinery only; your
  people-store lives in your own private repo or directory.

## How it works

One pipeline connects everything:

```
Connectors in → inbox/ → filing engine → people store → signal engine → wake-up queue → connectors out
```

Input connectors write normalized capture events into `inbox/` (raw kept
forever). The filing engine turns them into a markdown people-store — one file
per person, one note per interaction, plus an index. The signal engine finds
reasons to reach out; the wake-up queue is the single scheduling primitive
(explicit reminders, birthdays, and detected signals are all the same dated
object: who, why, context, optional draft). Output connectors render fired
wake-ups, pre-meeting briefs, and query answers wherever you want them.

Your data never lives in this repo — `data/` is gitignored and points at your
own private store (see `data/README.md`).

## Repo layout

```
CLAUDE.md          project + harness doctrine
.claude/           harness: rules, hooks, agents, harness skills, templates
packages/          the assistant, five packages (docs/PROJECT-CONTEXT.md):
├── core/          versioned contracts, templates, store scripts, fixtures
├── connectors/    all outside-world I/O, deliberately dumb — one lane per
│                  source: composio-in (gmail/calendar/linkedin via a linked
│                  Composio account), beeper-in (texts via Beeper), gmail-in,
│                  calendar-in, contacts-in, file-out, gmail-out
├── ingestion/     filing engine, attendee↔person matching, links, provenance
├── attention/     signal detection + ranking + wake-up queue + sweeps
└── query/         read-only answers + pre-meeting briefs (the chat MCP)
docs/plans/        implementation plans; docs/ROADMAP.md maps plans → status
data/              YOUR private store (gitignored; see data/README.md)
```

## Status

The capture-and-file half of the pipeline is live: contracts and store
scripts, capture lanes pulling real gmail/calendar/linkedin and text-message
events, the filing engine (golden-tested, with an eval suite), and the chat
MCP query layer. The attention half — signal engine and wake-up scheduler —
is planned next. `docs/ROADMAP.md` is the truth for chunk-by-chunk status.

## How this repo is built (the harness)

The repo carries a delegation harness for building with Claude Code: the main
session orchestrates and never edits machinery; scoped `*-worker` agents
implement, `*-checker` agents are read-only — all hook-enforced
(`.claude/hooks/`: git guard, checker read-only guard, orchestrator edit
guard). Doctrine lives in `CLAUDE.md` and `.claude/rules/`; every worker gets
a 4-section brief and ends with a completion report. Hooks can be exercised
directly:

```sh
echo '{"tool_input":{"command":"git push --force"}}' | bash .claude/hooks/git-guard.sh
# → exit 2, "BLOCKED: force push"
```

Work happens on branches; the git-guard hook blocks commits and pushes on
`main`.

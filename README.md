# Spomni

**What a friendship is made of, without what it costs to keep.**

A relationship is made of trust, care, intent, and time. None of those are
what makes it hard to keep — what's hard is what a relationship *costs to
run*: the coordinating, following up, scheduling, restarting, remembering-to.
Spomni is an open-source, **local-first personal assistant** that carries
that running cost — business, friends, family — and never touches the
ingredients. It notices when a moment is good (a birthday, a job change, a
lull, a promise you made), hands you the context and a draft in your voice,
and stops. **It drafts; you send.** Always.

It runs inside [Claude Code](https://claude.com/claude-code) on your Mac.
Your contact graph lives in a private directory you own; this repo is
machinery only.

## Principles

- **Draft, never send** — a human holds the send button.
- **Capture is optional and lossy-tolerant** — no streaks, no guilt.
- **Provenance labeling** — told-by-you vs. inferred-from-public-web, never mixed.
- **Other people's data stays local** — no scraping, no enrichment APIs,
  first-party connectors only; nothing about your contacts leaves your machine.
- **Code and data are separate** — `data/` is gitignored and points at your
  own private store.

The test for every feature: *does it cut a running cost, or substitute for
an ingredient?* Only the first is built (`docs/USE-CASES.md`).

## Quick start (5 minutes, no accounts needed)

Prerequisites: macOS, git, [Claude Code](https://claude.com/claude-code),
Node ≥ 22.6, `jq`.

```sh
git clone https://github.com/yourBoiGershy/Spomni.git ~/spomni && cd ~/spomni
bash scripts/setup.sh --demo        # installs deps, builds a synthetic demo store, wires data/store
claude                              # approve the spomni-query MCP server when prompted
```

Then ask:

- "Who should I reach out to this week?"
- "Who do I know at Northwind Labs?"
- `/debrief` — "I had coffee with Dana, she's moving to Berlin in March"

Everyone in the demo store is fictional. When you're ready to use your own
data, run `bash scripts/setup.sh` without `--demo` and follow
[`docs/SETUP.md`](docs/SETUP.md) — it covers linking Gmail/Calendar, Beeper
for personal chats, and scheduled background capture. Prefer not to read it?
Open a Claude Code session and say *"run first-run setup from docs/SETUP.md"*.

## What it does

| You | Spomni |
|---|---|
| Ramble a debrief after a coffee | files it: person, facts, promises, follow-ups (`/debrief`) |
| Link Gmail + Calendar | captures who you actually talk to and meet; suggests priority tiers — you confirm |
| Ask "who should I reach out to?" | ranks by warmth × time-since × reason, with the evidence |
| Get a wake-up: "Priya's birthday Thursday — last time she was prepping the Berlin move" | you get context + a draft; you decide, you send |

More scenarios: `docs/USE-CASES.md`.

## Docs

| | |
|---|---|
| `docs/SETUP.md` | Full first-run setup, connectors, scheduling, troubleshooting, uninstall |
| `docs/ARCHITECTURE.md` | How it's built: the pipeline, the five packages, contracts, the store |
| `docs/USE-CASES.md` | The mission and the scenario map |
| `docs/DECISIONS.md` | Every design decision with its rationale |
| `CONTRIBUTING.md` · `SECURITY.md` | How to help; how to report something that leaks or sends |

## Status

Alpha. macOS only (launchd scheduling, Beeper Desktop). Capture from Gmail,
Google Calendar, and Beeper (WhatsApp/LinkedIn/Signal/…) works; filing,
priority tiers, wake-ups, and the read-only query server are live. Headless
scheduled Gmail/Calendar sweeps are in progress (`docs/ROADMAP.md`).

## License

MIT — see `LICENSE`.

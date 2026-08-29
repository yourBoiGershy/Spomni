# Decisions

Append-only log of binding decisions. Plans reference entries by name. To reverse a
decision, add a new entry superseding the old one — never edit history.

---

**draft-never-send** · 2026-08-29
The agent drafts messages but never sends them; the human always holds the send button.
Why: authenticity (automated relationship maintenance reads worse than silence) and the
psychological ownership of the relationship staying with the user. The market's credible
"chief of staff" tools converged on the same boundary.
Revisit if: never for sending; delivery of *nudges to the user* is unrestricted.

**code-data-separation** · 2026-08-29
Public repo = machinery only; each user's people-store lives in their own private dir/repo
(`data/` gitignored). Why: contact graphs are other people's PII (Covve breach leaked
non-consenting people's data); also what makes the repo open-sourceable.
Revisit if: never.

**first-party-mcp-only** · 2026-08-29
Core integrations use first-party connectors/MCP servers only (Google's official
Gmail/Calendar/Contacts MCP, Slack's official MCP, claude.ai connectors in Claude Code).
Aggregators (Composio, Pipedream…) are supported only through the generic
"add any MCP server" slot, never as a dependency. Why: zero new vendors, no per-call
metering, no repricing/lock-in risk (Composio Aug 2026 repricing; Pipedream→Workday),
credentials stay between user and service.
Revisit if: a needed service has no first-party or credible community MCP server.

**tos-clean-signals-only** · 2026-08-29
No LinkedIn scraping, no unofficial-API enrichment (Unipile-class), no RSS scraping
bridges. Signals come from: Google Contacts, the user's own inbox (LinkedIn notification
emails, signatures, event confirmations), the user's calendars, public web search,
SEC EDGAR, and debriefs. Why: Proxycurl sued/shut down July 2026; ban risk on the user's
own accounts; the open-source project must not ship liability.
Revisit if: LinkedIn opens real API access.

**wakeup-queue-over-digests** · 2026-08-29
No fixed daily/weekly digest. One primitive — the wake-up queue (due date, who, why,
context, optional draft) — carries explicit reminder asks, signal-driven nudges, and any
standing rhythms alike. Coincident due entries are batched at delivery. Why: user
direction; cadence-based digests are the documented abandonment driver; "remind me in a
month" and "her birthday is Thursday" are the same object.
Revisit if: usage shows a desire for a standing weekly review (then it's a recurring
queue entry, not new architecture).

**markdown-store-plus-index** · 2026-08-29
People store is plain markdown files with frontmatter plus an auto-generated `index.json`.
No database, no embeddings in v1 (design so embeddings can bolt on later). Why:
greppable, LLM-readable, user-ownable, zero dependencies; sufficient for hundreds of
people with an LLM in the loop.
Revisit if: query quality degrades at scale — add local embeddings (SQLite), not a server.

**gmail-first-capture** · 2026-08-29
Gmail is the first input lane: the user's inbox is secretly the universal feed
(voice-note self-emails, LinkedIn notifications, signatures, event confirmations).
Phone capture = dictate (Wispr Flow) into a subject-tagged self-email. Why: one connector
covers capture AND most v1 signals; works from any device.
Revisit if: friction shows up in practice — the iOS-Shortcut→GitHub inbox lane is the
designed alternative.

**multiple-google-calendars** · 2026-08-29
Calendar sync reads all of the user's Google calendars (work + personal), read-only.
Why: the whole life drives the debrief loop, not just work; read-only keeps the blast
radius zero.
Revisit if: a non-Google calendar shows up — add it as another input connector.

**hybrid-runtime** · 2026-08-29
On-demand sessions (debrief, query, brief) plus scheduled background sweeps (inbox,
calendar, signals, due wake-ups). Sweeps are quiet unless something surfaces.
Revisit if: scheduled infra proves flaky — degrade to on-session-open sweeps.

**provenance-labeling** · 2026-08-29
Every stored fact is labeled told-by-user vs. inferred-from-public-web. Why: keeps the
store trustworthy; web research is seeded guesswork until confirmed.
Revisit if: never.

**golden-tests-before-prompts** · 2026-08-29
Any LLM-specified behavior (filing, signal ranking, nudge rendering) gets golden
input→expected-output fixtures written before the prompt that implements it.
Why: prompt-tuning needs a target; regressions need a tripwire.
Revisit if: never.

**package-architecture** · 2026-08-29
The machinery is five packages — core, connectors, ingestion, attention, query —
grouped by **artifact ownership, not feature names**. Three rules prevent overlap:
single writer per artifact type (inbox=connectors-in; people/interactions/index=
ingestion; wakeups lifecycle=attention, creation via core's append script;
outbound=connectors-out); dumb edges smart middle (connectors never interpret);
siblings communicate only through core's contracts, declared in manifests as
provides/consumes with versions. Each package's spec + contracts + golden tests are
the durable artifact — implementations are regenerable from them ("rebuild against
newer versions" is a supported workflow). Packages stay 0.x until the live trial;
contracts are semver'd from day one.
Why: focused agents need territory boundaries the hooks can enforce; versioned
contracts replace cross-agent chatter with mechanical compatibility checks.
Revisit if: a package's regeneration repeatedly breaks siblings — tighten contracts,
don't blur ownership.

**attention-merge** · 2026-08-29
Signals and the scheduler are one package (`attention`), not two: snooze/dismiss
feedback couples ranking to firing, and both live on the same wake-up queue — a
package boundary there would cut through one conversation. Conversely, "calendar" is
not a package: it splits into a thin `connectors/calendar-in` (dumb pull) and
ingestion-side attendee↔person matching, per dumb-edges-smart-middle.
Why: grouping by artifact ownership (who writes the queue; who writes the store)
rather than by feature noun.
Revisit if: attention grows past ~2 plans of scope — split detection from delivery
only if the feedback loop can become a contract.

**mcp-stack** · 2026-08-29
The chat MCP server (plan 08) is TypeScript with the official
`@modelcontextprotocol/sdk`, run zero-build via Node ≥22 native type-stripping;
`gray-matter` for frontmatter parsing. First real runtime code in the repo. Why: the TS
SDK is the reference implementation with first-class stdio + streamable-HTTP transports;
every Claude Code user already has Node (no second runtime); handlers are plain
functions, testable against the fixture store.
Revisit if: Node type-stripping proves flaky in the wild — add a build step, not a
different language.

**staleness-cache** · 2026-08-29
The query MCP server never writes into the store. It detects stale index/stats
(generated_at + mtime vs. newest store mtime) and regenerates via core's scripts into
`${RA_CACHE_DIR:-$HOME/.cache/relationship-agent}/derived/`, serving from there; store
copies of index.json/stats.json remain ingestion's to write. Every tool result carries
`generated_at`. Why: preserves the single-writer rule while keeping answers fresh
without depending on sweep timing.
Revisit if: cache/store divergence confuses users — surface a reconcile hint, don't
grant query write access.

**delegation-without-gates** · 2026-08-29
The repo runs the simplified harness: orchestration doctrine, worker/checker split,
enforcement hooks, brief template, completion reports — but no gate system, attestation,
or shipping pipeline yet. Why: new project; gates are earned by failures, not built on
day one (per the Harness Core Blueprint's own staging advice).
Revisit if: the project gains tests + CI worth gating — adopt blueprint Stage 2+ then.

**composio-hub** · 2026-08-29
Supersedes first-party-mcp-only. Core data access runs through the user's own Composio
account — one aggregator, many lanes: Gmail (63 tools incl. People/contacts), Google
Calendar, LinkedIn (official member API), and a 1,300+ toolkit long tail. Access is via
the Composio CLI (`composio link` / `composio execute`) rather than MCP registration —
skills shell out to `execute`, which fits the repo's bash-script conventions and needs
no gateway config. Why: breadth-per-connector — as many data points as possible through
as few connector setups as possible (user decision, this date). tos-clean-signals-only
STANDS: Composio's LinkedIn toolkit is the official API (posts, profile, network-size
count; no connections list, no messages, no notifications), not scraping. Accepted
costs: tool-call payloads transit Composio's cloud (zero-data-retention is a paid Pro
add-on; default retention unverified — ask support@composio.dev), free tier hard-capped
at 100K calls/mo, premium tool calls bill from Sep 10 2026. The people-store itself
stays local — no third party ever holds the graph, only the pipes.
Revisit if: Composio's retention answer is bad, repricing bites, or a needed lane has
no Composio path (iMessage → local chat.db bridge, LinkedIn depth → archive export).

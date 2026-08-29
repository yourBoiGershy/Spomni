# Plan 07: Output skills & adapters (the voice)
Status: Ready
Depends-on: 01; renders 06's batches; brief uses 04's artifacts

## Objective
Build everything the user actually sees: the query skill ("who do I know in marketing?"), the pre-meeting brief, and the nudge rendering that turns fired wake-ups into cards with trigger, ammunition, and an optional draft — delivered through a pluggable output-adapter interface so terminal/file today and email/Slack later are the same render.

## Context
Read docs/PROJECT-CONTEXT.md first. Decisions that bind this plan:
- **Draft-never-send** — drafts are attached text; no output adapter may transmit to a third party on the user's behalf. The Gmail-out adapter delivers TO the user's own inbox only.
- **Pluggable output connectors** — one render, many destinations; adapter = anything taking rendered content + destination config.
- **Provenance labeling** — briefs visually separate what-you-told-me from fresh public research.
- **Nudge-quality rules** — every rendered nudge shows its trigger and ammunition; no bare reminders.

## Deliverables
- `.claude/skills/query/SKILL.md` — natural-language questions over index + person files; answers cite the person files they drew from
- `.claude/skills/brief/SKILL.md` — pre-meeting one-pager: store facts (provenance: user) + fresh web research on the person/company (provenance: public), open threads, last-interaction summary, outstanding commitments both directions
- Nudge card format spec + renderer (part of the sweep delivery): trigger, evidence, shared-history ammunition, optional draft, snooze/dismiss affordances
- Output adapter interface doc (`docs/connectors.md`, output half) + two adapters: `file-terminal` (writes `data/outbox/YYYY-MM-DD.md`, shown in-session) and `gmail-self` (emails the batch to the user's own address)
- `fixtures/output/` — a fired-batch artifact + expected renders

## Work units
Wave A (parallel):
1. [worker] Nudge card format spec + `fixtures/output/` (one batch with 3 fired wake-ups: birthday, job change with draft, month-out reminder; expected render per adapter).
2. [worker] `.claude/skills/query/SKILL.md` — index-first retrieval, file-read for detail, citation format, "no match" behavior (say so + nearest neighbors, never invent).
3. [worker] `docs/connectors.md` output-adapter half: the interface, destination config shape, the draft-never-send constraint stated as a hard rule for adapter authors.

Wave B (after A):
4. [worker] `.claude/skills/brief/SKILL.md` — assembly order, research pass (web search, name+company disambiguation), provenance sections, length cap (one page), staleness note when store facts are old.
5. [worker] `file-terminal` adapter + `gmail-self` adapter (the latter via first-party Gmail connector, self-address only, refuses other recipients).
6. [checker] Render the fixture batch through both adapters; verify identical content, correct card structure, drafts present but marked unsent; run 3 query fixtures against the persona pack and verify citations.

## Interfaces
Consumes: index + person/interaction contracts and fixture personas (01); fired-batch artifact (06); `upcoming-briefworthy.json` (04).
Produces: the adapter interface future connectors implement; the card format 05's ammunition block targets; the outbox convention.

## Proof of done
The same fired batch renders correctly through file-terminal and gmail-self with identical content; "who do I know in fintech in NYC?" answered correctly from fixtures with citations; a real upcoming meeting gets a usable one-page brief with provenance-separated sections.

## Out of scope
- Slack/WhatsApp output adapters (interface supports them; build on demand)
- Sending any message to anyone other than the user (permanently)
- Interactive card UI — snooze/dismiss are replies to the agent, not buttons
- Phone push notifications

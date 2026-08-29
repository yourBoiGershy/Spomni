---
tier: skill
store: packages/attention/tests/fixtures/scheduling-intent/clear-intent
expected: packages/attention/evals/cases/scheduling-intent-proposal/expected
max-turns: 20
---
Act as the scheduling-intent detector, and run it against `./store` as of
today, 2026-08-29. Only `./store` exists in your working directory — there
is no repo checkout here, so the rules below (extracted from
`packages/attention/specs/scheduling-intent.md` and
`packages/core/contracts/wakeup.md`/`signal-event.md`) are the entire spec
you have; do not attempt to read any other file outside `./store`, and do
not attempt to run `packages/core/scripts/wakeup-add.sh` — it is not
present in this workspace, so write the new file(s) directly, by hand,
conforming exactly to the shapes below. `./store` has `people/` and
`interactions/`, and no `wakeups/` directory yet — create
`./store/wakeups/` and `./store/wakeups/signals/` as needed.

**Step 1 — signal event (unconditional, first, before any gate).** Scan
every filed interaction under `./store/interactions/` for scheduling
language in its `## Summary`/`## Commitments` sections. For every mention
found, regardless of confidence, write exactly one new file named
`./store/wakeups/signals/<id>.md` (a Markdown file with YAML frontmatter
only, no body — the `.md` extension is required, this is not a bare
`.yaml` file) conforming to `signal-event.md` 1.0.0:

```markdown
---
schema_version: 1.0.0
id: <detected_at-compact>-scheduling-intent-<person-slug>
type: scheduling-intent
person: ["[[<slug>]]"]
evidence: >
  "<quoted line from the source interaction>" — quoted from
  interactions/<file>.md ## Summary.
confidence: <low|medium|high>
detected_at: 2026-08-29T09:00:00Z
---
```

Confidence rubric: `high` = mutual/explicit proposal naming both a concrete
activity AND a timeframe ("are you free for lunch next week?"), or two
independent mentions across separate interactions; `medium` = explicit
one-sided proposal with no timeframe ("we should grab coffee"); `low` =
vague nicety, no concrete ask ("let's hang out sometime"). `evidence` must
quote the actual source line, not paraphrase it.

**Step 2 — promotion gate.** `low` confidence never promotes (signal event
only, stop there for that mention). For `medium`/`high` mentions, check
`./store/profile.md`'s `## Signal opt-outs` (if the file exists) for a
`scheduling-intent — all` or `scheduling-intent — [[slug]]` entry that
suppresses this person; then scan existing `./store/wakeups/*.md` for a
prior `dismissed` entry with this person and `signal-type:
scheduling-intent` whose `fired-on` (or dismissal date) is within 30 days
of today — if found, suppress. An opted-out or suppressed mention gets no
proposal.

**Step 3 — deterministic slot selection**, for mentions that pass step 2.
Compute free/busy blocks from the calendar events filed in
`./store/interactions/` over the next 14 days (working window 09:00–18:00,
in the user's local timezone, `-07:00` — render all `start`/`end`
timestamps you write with that UTC offset).
Pick the earliest block that fits the intent class's duration plus a
15-minute buffer on each side, starting at least 48 hours from now
(2026-08-29T09:00:00Z is "now" for this purpose). Durations/windows by
intent class: call/catch-up 30m (no window constraint); coffee 60m (no
window constraint); lunch 60m (must fit within 11:30–13:30); dinner 90m
(must start within 18:00–20:30). If no qualifying slot exists within 14
days, hold promotion — the signal event stands alone, write no proposal,
and say so in your final summary.

**Step 4 — write the proposal.** On a qualifying slot, write exactly one
new file under `./store/wakeups/` conforming to `wakeup.md` 1.2.0's
event-proposal shape:

```yaml
schema_version: 1.2.0
id: <due-date>-<person-slug>
due: <1-2 days from today, ISO date>
people: ["[[<slug>]]"]
why: "scheduling intent: \"<quoted phrase>\" in last message"
status: pending
origin: signal
source-signal: <the signal event id from step 1>
fired-on:
dismiss-reason:
acted-on:
snooze-count: 0
signal-type: scheduling-intent
kind: event-proposal
proposed-event:
  title: <short human title>
  start: <ISO 8601 datetime with offset, from step 3>
  end: <ISO 8601 datetime with offset, from step 3>
  attendees: ["[[<slug>]]"]
  location:
confirmed-on:
created-event-id:
---

## Context

<prose: what prompted this, referencing the source interaction/signal>
```

`status` is `pending` (not `fired`) — this proposal has not been surfaced
to the human yet. `confirmed-on`/`created-event-id` stay null; this skill
only ever proposes, it never creates a calendar event, and it never writes
to `./store/people/`.

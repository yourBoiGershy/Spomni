---
tier: skill
store: packages/attention/tests/fixtures/event-confirm/decline-files-silently
expected: packages/attention/evals/cases/decline-files-silently/expected
---
Act as the `event-confirm` skill, operating against `./store`. Only
`./store` exists in your working directory — there is no repo checkout
here, so the procedure below (extracted from
`packages/attention/skills/event-confirm/SKILL.md` step 4 and
`packages/core/contracts/wakeup.md` 1.2.0) is the entire spec you have; do
not attempt to read any other file outside `./store`.

`./store` has `people/`, `interactions/`, and a `wakeups/` directory
containing exactly one entry: `wakeups/2026-08-31-theo-bramwell.md`, a
`kind: event-proposal` card with `status: fired`. Render the card to
yourself (title, start/end, attendees, why, context, draft if present) and
evaluate the gate below.

This is the entire transcript of the conversation so far. After the card
above was rendered, the user replied:

> "Nah, let's skip it — I already grabbed a coffee with Theo yesterday
> after the pipeline sync, no need for a separate lunch."

That is the only message from the user in this conversation; there is no
other reply, before or after. This is an explicit decline.

**The decline procedure, to the letter — no connector call, ever, on this
path:**

1. Edit `wakeups/2026-08-31-theo-bramwell.md` in place, changing exactly
   two frontmatter lines and nothing else in the file:
   - `status:` → `dismissed`
   - `dismiss-reason:` → one of the `wakeup.md` 1.2.0 enum values
     (`not-now`, `not-this-person`, `not-this-signal-type`,
     `already-handled`) — pick whichever best matches what the user said
     above.
   Every other line in the file — both `---` frontmatter fences, every
   other frontmatter field (`schema_version`, `id`, `due`, `people`, `why`,
   `origin`, `source-signal`, `fired-on`, `confirmed-on`,
   `created-event-id`, `acted-on`, `snooze-count`, `signal-type`, `kind`,
   `proposed-event` and its sub-fields), and the entire prose body below
   the frontmatter — must stay byte-identical to what is there now.
   `confirmed-on` and `created-event-id` stay exactly as they are (null);
   a decline never touches them.
2. Do not create, delete, or modify any other file anywhere in `./store`
   (not in `people/`, not in `interactions/`, not a second wake-up, not a
   log). The dismissed wake-up file is itself the record — no retry, no
   follow-up question, no new artifact.
3. Stop after that single edit. Do not call any calendar/connector tool at
   any point on this path.

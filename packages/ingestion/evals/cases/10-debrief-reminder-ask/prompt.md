---
tier: skill
store: packages/ingestion/tests/goldens/debrief/04-embedded-reminder-ask/before
expected: packages/ingestion/evals/cases/10-debrief-reminder-ask/expected
max-turns: 12
model: haiku
---
Act as ingestion's debrief filing skill, per
`packages/ingestion/skills/debrief/SKILL.md`. The current people-store is the
directory `./store` (contains `people/`, `interactions/`, `wakeups/`) — treat
it as the live store for this pass. This eval skips the `inbox/`/dedup-ledger
mechanics (no `data/ingestion/debrief-filed.log` bookkeeping needed here) —
just file the capture event below into `./store` exactly as single-event
mode would. Do not run `build-index.sh` or `validate-store.sh` — this eval
only grades the `people/`/`interactions/`/`wakeups/` writes.

## The operative procedure (quoted from SKILL.md, apply it directly)

**§2 Parse the envelope.** `occurred_at` is absent here, so fall back to
`captured_at`'s date. Every other `type` value's body (this one is
`voice-note`) is free-text prose — read it the same way a human would read
a transcript.

**§3 Resolve participants.** A `participant-hints` entry that exactly
matches an existing `people/<slug>.md`'s `name` field is an unambiguous
single match — proceed to file against that person.

**§5a Person file updates.**
- *New facts*: every new factual claim about the person surfaced by the
  debrief becomes a new bullet appended to `## Facts`, tagged
  `**[told-by-user]**`, with a trailing capture date in parens
  `(YYYY-MM-DD)` — the interaction's date. Never delete or rewrite an
  existing `## Facts` bullet — append-only.
- *`last-touch`*: always set to the interaction's date, regardless of
  whether any fact changed, as long as the new date is not older than the
  value already on file.
- *Open threads*: a promise, loose end, or "ask about X next time" becomes
  a bullet under `## Open threads`.

**§5b The interaction file.** Create exactly one new
`interactions/<id>.md`: filename `<date>-<primary-person-slug>`; `date`
from §2; `calendar-event: null`; `source-capture` = the triggering capture
event's `id`; `people` = the matched person's `[[slug]]`; `## Summary` in
free prose (never a verbatim copy of the capture body); `## Commitments`
per the rule below.

**Reminder-ask → wake-up entry (quoted verbatim from SKILL.md).**

> **Detecting an explicit ask.** Look for a first-person imperative
> specifically asking to be reminded or followed up with later — "remind me
> to...", "make sure I follow up...", "don't let me forget to..." — usually
> tied to a person and a time expression. This is distinct from implicit
> musing that merely notes a future intention without asking for a nudge.
> Musing like this creates **no** wake-up; at most it earns an ordinary
> `## Open threads` bullet, same as any other loose end, and nothing more.
>
> **Turning a real ask into a wake-up.** Once an explicit ask is detected:
>
> 1. It is still a commitment — add the usual `## Commitments` bullet on
>    the interaction, owner `user` (the user is committing to their own
>    future follow-up), with the due date computed by ordinary calendar
>    arithmetic from the interaction's own date when the ask states a
>    relative duration with no explicit calendar date (e.g. "in three
>    weeks" is 21 days forward from the interaction date).
> 2. Create exactly one wake-up entry by invoking
>    `packages/core/scripts/wakeup-add.sh` — **never** hand-write a
>    `wakeups/<id>.md` file directly; that script is the only sanctioned
>    writer. Invocation shape:
>
>    ```sh
>    bash packages/core/scripts/wakeup-add.sh <store-dir> \
>      --due <YYYY-MM-DD> \
>      --person <slug> \
>      --why "<one line naming the trigger and reason>" \
>      --origin user-ask \
>      --context "<free prose: what's known about the person right now, tied back to the ask and the due date>"
>    ```
>
>    `--due` is the same computed date as the Commitments bullet above.
>    `--person` lists every person this ask concerns. `--origin user-ask`
>    always, since this is an explicit request, never `signal` or
>    `standing`.
> 3. Add an `## Open threads` bullet on the matched person's file pointing
>    at the new wake-up file by its path (`wakeups/<due-date>-<primary-
>    slug>.md`) so a human skimming the person file can trace it.
> 4. This wake-up is an ordinary entry in the queue like any other — no
>    special-cased delivery path.

The `wakeup.md` contract (1.2.0) requires these frontmatter fields on the
created file: `schema_version`, `id` (matches the filename stem), `due`
(`YYYY-MM-DD`), `people` (list of `[[slug]]` links, ≥1), `why` (string
naming the trigger, never bare cadence), `status: pending` at creation,
`origin` (`user-ask` here), `source-signal: null`. Body: a required
`## Context` section (free prose ammunition tied to the ask and due date).

## The capture event to file

```
---
schema_version: 1.2.0
id: 20260829T113000Z-manual-6f28
source: manual
captured_at: 2026-08-29T11:30:00Z
type: voice-note
participant-hints:
  - "Marcus Yeun"
---
Quick coffee with Marcus Yeun. He's completely swamped this week putting
together a big client pitch, sounded pretty stressed about it. Didn't get
into much else. Remind me to follow up with him in three weeks, once the
pitch dust has settled.
```

Resolve "Marcus Yeun" against `./store`, then file per the procedure above:
this is an explicit first-person reminder ask (the debrief says "Remind me
to follow up with him in three weeks"), not idle musing, so it produces a
`## Commitments` bullet owned by `user` with the computed due date AND
exactly one wake-up entry created via `wakeup-add.sh` (never a hand-written
`wakeups/*.md` file), plus an `## Open threads` bullet on Marcus's person
file pointing at the new wake-up.

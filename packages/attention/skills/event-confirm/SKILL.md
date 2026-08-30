---
name: event-confirm
description: Presents a fired event-proposal wake-up card to the human and, only on an explicit affirmative in this conversation, creates the calendar event via the user's linked first-party Google Calendar connector and records the outcome. Decline dismisses silently. No confirmation, no create — ever.
---

# event-confirm

The one place a calendar write ever happens in this system, and only after a
recorded human confirmation. Operates on a single `wakeups/<id>.md` entry
with `kind: event-proposal` and `status: fired` (`packages/core/contracts/
wakeup.md` at 1.2.0). Draft-never-send's calendar analogue: this skill
proposes, the human confirms, the create happens only after that — zero
events are ever created without it (eval-guarded, per plan 21's "zero-create"
guardrail). It never generates a proposal itself (that's `skills/
scheduling-intent/`) and never touches any wake-up that isn't a fired
`event-proposal`.

**Invariant, stated once and binding everywhere below:** `created-event-id`
must never be written to `wakeups/<id>.md` except in step 3's post-create
record, and only immediately after `confirmed-on` is written in that same
`wakeup-queue.sh confirm` call. No other step, path, or branch in this
skill may set it, guess it, or leave it non-null on any other outcome.

## 1. Render the card

Read the target `wakeups/<id>.md` and present it to the human, plainly, as a
confirm/decline ask — never as a fait accompli. Include:

- **Proposed event** — `proposed-event.title`, `start`/`end` (rendered in a
  readable local form, not raw ISO), `attendees` (resolve each `[[slug]]` to
  that person's `name` from `people/<slug>.md` frontmatter — show the
  display name, not the raw slug), `location` (omit the line if `null`).
- **Why** — the entry's `why` field, one line.
- **Context** — the `## Context` body section, the ammunition behind the
  proposal.
- **The draft**, if a `## Draft` section is present (the message that would
  accompany the invite, per `draft-never-send` — this skill never sends it
  either; it's shown for the human's awareness only).
- **An explicit ask** — confirm or decline, phrased so a yes/no is
  unambiguous, e.g. "Create this event and confirm the proposal, or decline
  it?"

If `<id>` does not resolve to a `wakeups/` entry with `kind: event-proposal`
and `status: fired`, stop here — log why (missing, wrong kind, not yet
fired) and do nothing else. This skill only ever acts on a fired proposal
card.

## 2. Wait for an explicit affirmative — the gate before any connector call

**No connector call of any kind happens before this step resolves to a
clear "yes."** This is the hard gate the whole skill exists to enforce:

- **Explicit affirmative** ("yes", "confirm", "create it", "go ahead", a
  clear approval of the exact proposal shown) → proceed to step 3.
- **Explicit decline** ("no", "skip it", "not interested", a clear refusal)
  → proceed to step 4.
- **Anything else — silence, ambiguity, a non-answer, a question back, a
  change-the-subject, an unrelated reply, no response at all in this
  conversation** → do nothing. Leave the wake-up entry exactly as-is
  (`status: fired`, `confirmed-on: null`, `created-event-id: null`). Do not
  guess which way an ambiguous reply leans; do not treat silence as either
  a yes or a no. This entry simply stays available to be re-presented
  later — no retry loop, no follow-up nag, per the no-guilt principle. Stop
  here.

A reply that confirms a *modified* event (different time, different
attendee) is not a confirmation of the proposal as shown — treat it as
ambiguous per the silence/ambiguity branch above; editing the proposal
itself is out of scope for this skill (out of scope per plan 21's
"rescheduling, editing... existing events" and the fact that v1's proposals
are confirm-as-shown only).

## 3. Confirm path — resolve attendees, create, then record

Only reached after an unambiguous affirmative from step 2.

### 3a. Resolve attendee emails

For each `[[slug]]` in `proposed-event.attendees`, read `people/<slug>.md`
and look for a known email address for that person — person.md carries no
dedicated email frontmatter field, so check the free-text body (a `## Facts`
or `## Personal details` bullet recording an email, e.g. from a filed
`"Name <email>"` contact hint) for an address unambiguously tied to that
person.

- **Found** → use it.
- **Not found** → ask the user for that person's email address, in this
  conversation, before proceeding. **Never guess or invent an email.** If
  the user doesn't have it or declines to provide it, that attendee is
  dropped from the invite — go ahead with the remaining resolved attendees
  and note in the create call that one attendee's email is unresolved
  (loud, not silent). If *no* attendee can be resolved to an email, do not
  create the event: log loudly (a card that would create an attendee-less
  invite is not what was proposed) and stop — this is a create failure per
  3b, so the proposal stays pending.

### 3b. Create via the Google Calendar connector

Call the user's linked first-party Google Calendar connector — the
claude.ai Google Calendar MCP connector's create-event tool (chunk 17's
lane; composio is retired for this path per `docs/DECISIONS.md#composio-
retired`) — with `title`, `start`, `end`, resolved attendee emails, and
`location` (omit if `null`) exactly as shown to the human in step 1. Do not
add, drop, or alter fields beyond what step 1 presented and step 3a
resolved.

- **Connector not linked or unavailable** (expected pre-chunk-17): log a
  loud, visible line (this is not a quiet skip — the human confirmed and is
  owed a clear explanation of why nothing happened) and stop. The wake-up
  entry stays untouched — `status: fired`, `confirmed-on: null`,
  `created-event-id: null`. Do not run `wakeup-queue.sh confirm` in any form
  when this branch is hit; there is nothing to record.
- **Create call fails** (any other error — auth, rate limit, malformed
  request, etc.): log the failure loudly, record nothing. The proposal
  stays pending exactly as it was before this run; no partial write, no
  retry within this run. The human can be re-asked in a future run.
- **Create succeeds**: the connector returns an event id. Proceed
  immediately to 3c — do not let any other step run between a successful
  create and the record below; the create and the record are the two
  halves of one indivisible outcome.

### 3c. Record the outcome

Run, immediately after a successful create:

```sh
packages/attention/scripts/wakeup-queue.sh <store-dir> confirm <wakeup-id> --event-id <id>
```

`<id>` is the event id the connector returned in 3b — never invented, never
a placeholder, never the connector call's request payload. This is the one
and only call site in this skill (or anywhere else) that writes
`created-event-id`; the invariant at the top of this document holds because
this line only runs after step 3b's create actually succeeded and step 2's
explicit affirmative actually happened.

If `wakeup-queue.sh confirm` itself fails after a successful create (e.g. the
store write errors), log this loudly and distinctly from a create failure —
an event now exists in the user's calendar that the store doesn't yet
reflect, which is a state a human should be told about explicitly rather
than have silently retried or papered over.

## 4. Decline path

Only reached after an unambiguous decline from step 2.

```sh
packages/attention/scripts/wakeup-queue.sh <store-dir> decline <wakeup-id> --reason <enum>
```

Pick the `dismiss-reason` enum value from `wakeup.md` (`not-now`,
`not-this-person`, `not-this-signal-type`, `already-handled`) that best
matches what the human said; default to `not-now` when the decline doesn't
volunteer a more specific reason. No connector call happens on this path —
ever. After the dismiss write completes, this skill goes silent: no retry,
no follow-up question, no new artifact beyond the dismissed wake-up file
itself, which is its own record (per `wakeup.md`'s Notes: re-proposal for
the same person/`scheduling-intent` pair is suppressed for 30 days — that
suppression is scheduling-intent's concern at generation time, not
something this skill enforces here).

## 5. Failure/edge posture summary

| Situation | Connector call? | Store write? | Human-visible outcome |
|---|---|---|---|
| Explicit confirm, connector linked, create succeeds | yes | `confirm` (sets `confirmed-on` + `created-event-id`) | event exists, proposal marked confirmed |
| Explicit confirm, connector not linked (pre-17) | no | none | loud log, proposal untouched |
| Explicit confirm, create call fails | yes (fails) | none | loud log, proposal untouched |
| Explicit confirm, all attendee emails unresolved | no | none | loud log, proposal untouched |
| Explicit decline | no | `decline` (dismiss + reason) | silence after the write |
| Silence / ambiguous / no response | no | none | entry left exactly as-is, no nag |

No row in this table writes `created-event-id` outside the first row's
`confirm` call, and no row writes it without a preceding explicit
affirmative recorded in this conversation.

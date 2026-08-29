---
name: debrief
description: Turn one capture event (or a batch of unfiled inbox/ events) into person and interaction updates — the filing engine that runs the store's people/ and interactions/ files, per packages/core/contracts/person.md and interaction.md.
---

# Debrief filing

Reads capture events from `<store-dir>/inbox/` (`packages/core/contracts/
capture-event.md`) and files them into `<store-dir>/people/` and
`<store-dir>/interactions/` — the two artifact types ingestion is the sole
writer of (`packages/ingestion/package.md`). Never mutates a capture event;
`inbox/` stays an append-only archive forever, per the capture-is-lossy-
tolerant principle.

**Scope of this document — core only.** This SKILL.md covers: input
selection, envelope parsing, participant matching against the existing
store (including the one-question ambiguity rule), and the person/
interaction writes those matches produce. It does **not** cover the deeper
extraction rules or new-artifact creation listed under "Not in this core"
at the bottom — those are follow-up units that extend this same skill file
in place.

## State this skill owns

Per `docs/data-layout.md`'s connector-runtime-state pattern (adapted here
for ingestion itself, since ingestion is not a connector and so does not
use `data/connectors/`), this skill's own filed-ledger lives at:

```
data/ingestion/debrief-filed.log
```

One `inbox/` capture-event `id` per line, appended **after** that event's
filing (including a no-write ambiguous-question outcome — see "Ambiguity"
below) completes successfully. This is a dedup ledger local to ingestion,
exactly like a connector's `processed.log` — no other package reads or
writes it, and it is never part of the shared store's single-writer table
(it lives outside `<store-dir>` entirely, at `data/ingestion/`, a sibling
of `data/store/` and `data/connectors/`).

Create the directory before first use:

```sh
mkdir -p data/ingestion
```

## 1. Input selection

This skill runs in one of two modes.

### Single-event mode

Given one `inbox/<id>.md` path (e.g. handed off directly by a connector, or
picked by a human/agent), file just that event. Skip it (log and stop,
make no writes) if `<id>` already appears in `data/ingestion/debrief-
filed.log` — it was filed before.

### Batch mode

Sweep `<store-dir>/inbox/*.md` (excluding `inbox/quarantine/`, which this
skill never reads — quarantine is for human review only, per
`docs/data-layout.md`) for every capture event whose `id` is **not** in
`data/ingestion/debrief-filed.log`. Process them oldest-first by
`captured_at` (ties broken by filename), running the per-event flow below
on each in turn. A failure or an outstanding ambiguous question on one
event does not block the rest of the batch — move to the next unfiled
event regardless.

## 2. Parse the envelope

Read the capture event's frontmatter per `capture-event.md` (this skill
accepts every 1.x `schema_version` — the contract's additive-only bumps
mean a 1.0.0, 1.1.0, or 1.2.0 event is handled identically here):

- `id`, `source`, `captured_at`, `type` — always present.
- `occurred_at` — **optional**; when present, prefer it as the
  interaction's `date` (truncated to `YYYY-MM-DD`) over `captured_at`, since
  it reflects when the touchpoint actually happened, not when it was
  swept. When absent, fall back to `captured_at`'s date.
- `participant-hints` — optional, default `[]`. Raw unresolved names/
  emails/handles as seen in the source; this skill is what resolves them.

The body (everything after the closing `---`) is read verbatim. For
`type: chat-message` events sourced from a Beeper lane (`source: beeper-in/
<network>`), the body is JSON matching `beeper-sweep.sh`'s batch shape:

```json
{
  "chatID": "...", "accountID": "...", "network": "...", "title": "...",
  "chatType": "single" | "group",
  "messages": [
    {"senderName": "...", "timestamp": "...", "text": "...", "isSender": bool, ...}
  ]
}
```

Treat `messages[]` (ordered oldest-first by `timestamp`) as the raw
transcript to read for facts/commitments — `messages[].text` from
non-`isSender` senders is what the other participant(s) said; `isSender:
true` entries are the user's own side of the conversation. `title` names
the chat (useful for the interaction summary when `chatType: group`).
Every other `type` value's body is free-text prose — read it the same way
a human would read a voice-note transcript.

## 3. Resolve participants

For each entry in `participant-hints` (plus, for chat-message events, every
distinct `senderName` seen in the body that is not the user), resolve to
zero or more `people/<slug>.md` matches:

1. **Exact match** — hint's name (case-insensitively, whitespace-
   normalized) equals an existing person's `name` field, or the hint is/
   contains an email address that matches a known contact detail for that
   person (participant hints may carry `"Name <email>"` form per
   `capture-event.md`'s example — strip the email out for name comparison
   but also try matching the bracketed email itself if the store has any
   record of it).
2. **Known-alias match** — same idea against any alias the store already
   records for a person (a first-name-only hint like `"Sarah"` or
   `"Dana"` matching a person whose `name` starts with that first name).
3. **Context disambiguation** — when a bare first name (or otherwise
   partial hint) matches more than one person by name/alias, narrow using
   whatever calendar/chat context the event carries: a `chatID`/`title`
   tying the message to a specific known thread, co-`participant-hints` in
   the same event that only one candidate has history with, an
   `occurred_at` that lines up with a calendar link one candidate already
   has (soft dependency — filing works without calendar links, better with
   them, per Plan 03's Interfaces section). If context narrows the
   candidate set to exactly one, treat it as resolved to that person.

Every hint resolves to exactly one of three outcomes:

- **Unambiguous single match** — one candidate remains. Proceed to file
  against that person (§5).
- **Multiple confirmed people, no conflict** — a multi-person event (e.g.
  golden 03's group chat) where each hint independently resolves to its
  own single match. Proceed to file against all matched people, linking
  them together in one interaction (§5).
- **Ambiguous** — a hint matches more than one person and context (step 3)
  cannot narrow it to one. Go to §4 instead of filing.

A hint that resolves to **zero** matches (no existing person, no context
to invent one) is a new-person case — out of this core's scope; see "Not
in this core" below. Do not guess, and do not silently drop the event —
hold it unfiled (leave its `id` out of the ledger) for the new-person
extension to pick up.

## 4. Ambiguity — the one-question rule

Per the capture-optional/lossy-tolerant doctrine (`docs/plans/2026-08-29-
03-filing-engine.md`), at most **one** clarifying question is asked per
filing run of a given event, and only when the ambiguous hint carries a
genuinely high-value update (a stated fact, not filler) that would
otherwise be lost or mis-filed.

When an ambiguity is confirmed (per §3 step 3, unresolved by context):

1. Make **no store writes at all** — not to any candidate's `people/
   <slug>.md`, not an interaction, nothing. The event's `inbox/` file is
   untouched (it always is) and is **not** added to `data/ingestion/
   debrief-filed.log` — it stays eligible for a future filing pass once
   the ambiguity is resolved (e.g. the user answers, or a later event adds
   disambiguating context).
2. Ask exactly one question, naming the candidates by their `[[slug]]` and
   a one-line identifying fact each (org/role is usually enough), e.g.:
   `"Which Sarah do you mean — Sarah Chen or Sarah Park?"`
3. If a question-per-case record is being kept for grading/audit (as the
   goldens do via `expected/question.md`), it should capture: the
   triggering utterance, why the hints were ambiguous, the candidate list,
   the question as posed, and an explicit "no store writes performed"
   line — see `packages/ingestion/tests/goldens/debrief/07-ambiguous-name/
   expected/question.md` for the exact shape to match.
4. If the user never answers or declines to clarify, the fact is dropped
   silently — never re-asked, never guessed (no-guilt principle; this
   event simply never gets an entry in the filed ledger).

This is the **only** branch where filing an event produces zero writes.
Every other branch below always produces at least an interaction file.

### 4a. Needs-confirmation — refining the ask/drop split

The high-value test above (step 2's trigger for asking) is not only about
*who this hint is* — it also governs a second kind of ambiguity that can
turn up once a hint is already resolved to one known person: an unclear or
hedged claim inside the debrief's own content (a "sounds like she might
be...", a half-remembered detail, or a claim that quietly conflicts with
what's already on file and the debrief itself doesn't resolve which is
current). This is not a §3 identity ambiguity — the person is known — so
it never triggers the zero-write ask/drop path above; filing this event
still produces the normal person + interaction writes regardless.

- If a claim like this clears the same high-value bar (leaving it
  unrecorded, or recording it as flatly stated, would meaningfully mislead
  or lose something real), it competes for the one question this event
  gets, exactly like a §3 identity ambiguity — never spend two questions
  on one event.
- If it does **not** clear that bar (the ordinary case — a minor, low-
  stakes ambiguity not worth interrupting the user over), do not ask a
  second question, and do not drop the claim either. File it as a normal
  `## Facts` bullet, but mark it unconfirmed inline by appending
  `, needs-confirmation` inside the same tag bracket as the provenance
  tag:

  ```
  - **[told-by-user, needs-confirmation]** Might be getting engaged — mentioned in passing, not fully clear (2026-08-29)
  ```

  This extends the person contract's existing `**[tag]**` bracket
  convention (`packages/core/contracts/person.md`) with a second,
  comma-joined tag rather than a new bracket — provenance and confidence
  are both properties of the same bullet. `needs-confirmation` never
  replaces the `told-by-user`/`inferred-public-web` tag; it always rides
  alongside one.
- A `needs-confirmation` bullet is never re-asked automatically. It sits on
  the person file until a future debrief either confirms it (a plain new
  `**[told-by-user]**` bullet superseding it, per §5a's append-only rule)
  or contradicts it — the marker itself carries no expiry or follow-up
  machinery of its own.

## 5. File the writes

Once participants are resolved (§3, non-ambiguous), file in this order —
person updates first, then the interaction, so the interaction's summary
can be written with full knowledge of what changed:

### 5a. Person file updates (per matched person)

For each matched person's `people/<slug>.md`:

- **New facts** — every new factual claim about that person surfaced by
  the debrief becomes a new bullet appended to `## Facts`, tagged
  `**[told-by-user]**` (a human debrief is always told-by-user provenance;
  `inferred-public-web` is never used by this skill — that tag is only for
  the research-seed extension) with a trailing capture date in parens,
  `(YYYY-MM-DD)` — the interaction's date from §2, not "today" if they
  differ. **Never delete or rewrite an existing `## Facts` bullet**, even
  when a new fact supersedes it — the facts list is an append-only, dated
  journal (see golden 10: the old `Sales Director at Acme Corp
  (2026-06-01)` bullet stays untouched, and the new org/role fact is
  appended below it).
- **Frontmatter field updates** — when a new fact changes a field
  `person.md` tracks in frontmatter (`org`, `role`, `location`, `tier`,
  etc.), update the frontmatter field itself to the new value (frontmatter
  is current-state, not a journal — contrast with `## Facts` above). The
  supersede fact bullet is still appended per the previous bullet, so the
  old value survives as history even though frontmatter has moved on.
- **`last-touch`** — always set to the interaction's date (§2), regardless
  of whether any fact/frontmatter changed. This is true even for a bare
  two-word debrief with no new facts at all (golden 05: `dana-kowalski`
  gets `last-touch: 2026-08-29` and nothing else changes).
  Only update `last-touch` when the new date is not older than the value
  already on file — filing never moves `last-touch` backward.
  Also apply the same append-only + frontmatter-update treatment to any
  other current-state field the debrief bears on directly.
- **Open threads** — a promise, loose end, or "ask about X next time" from
  the debrief becomes a new bullet under `## Open threads` (no provenance
  tag needed — these are prospective, not factual claims). An open thread
  that the debrief itself resolves (e.g. "asked how the move went, she
  said...") is not re-added.
- **Personal details** — texture that doesn't belong in the terse `##
  Facts` list (family, hobbies, how-they-met context) goes here, tagged
  `**[told-by-user]**` wherever it states a fact; connective prose does
  not need a tag.
- **Nothing invented** — a sparse debrief adds nothing beyond `last-touch`
  if it truly contains no new fact/thread (golden 05). Never pad a thin
  debrief with invented detail to make the file "look complete."

### 5b. The interaction file

Create exactly one new `interactions/<id>.md` (the id/filename is never
edited into or reused from an existing file — one interaction file per
filing pass over one capture event, per `interaction.md`'s "sole writer"
rule):

- `id`/filename: `<date>-<primary-person-slug>` (`<date>` from §2;
  `<primary-person-slug>` is the first-listed/first-matched person — for a
  multi-person event, whichever hint appeared first in
  `participant-hints`, per golden 03 where Nadia is primary). Append
  `--2`, `--3`, etc. only for a same-day duplicate against the same
  primary slug.
- `date`: the interaction date from §2.
- `people`: every matched person's `[[slug]]`, in match order — **all**
  participants for a multi-person event, not just the primary one (golden
  03 lists both `[[nadia-okafor]]` and `[[sam-vartan]]`).
- `calendar-event`: `null` unless this filing pass has an actual linked
  calendar-event id to hand (out of this core's scope to derive — leave
  `null` when in doubt).
- `source-capture`: the triggering `inbox/` event's `id`.
- `## Summary`: free prose, the filing engine's own structured retelling
  of what happened — never a verbatim copy of the capture body. For a
  chat-message batch, summarize the whole thread's substance, not a
  message-by-message transcript. A two-word debrief still gets a full
  sentence or two of summary (golden 05: `"Grabbed coffee with Dana. No
  further detail was captured beyond that."`) — the summary is always
  written in full prose regardless of how thin the input was.
- `## Commitments`: a bullet per promise surfaced in the debrief, each as
  `<owner>: <what> [by <date>]` where `<owner>` is `user` or the relevant
  person's `[[slug]]`; `[by <date>]` is included only when the debrief
  states or clearly implies a date, otherwise omit the `[by ...]` clause
  entirely (golden 01: `"(no date given)"` inline, not a bracketed date).
  `_none_` when the debrief surfaces no commitments (golden 05, golden 10).
  Attributing a commitment correctly to `user` vs. the other party's
  `[[slug]]` from the plain sense of who-said-they'd-do-what is in scope
  here; the more detailed extraction rules (natural-language date math
  like "by next Friday", multi-clause commitment parsing) are the
  commitment-extraction extension called out below — this core only
  requires that an obvious, plainly-stated commitment lands in this
  section with the right owner.

### 5c. After filing

Once every person file and the interaction file for this event are
written:

1. Rebuild the index: `bash packages/core/scripts/build-index.sh
   <store-dir>`.
2. Validate: `bash packages/core/scripts/validate-store.sh <store-dir>`.
   A validation failure on a case this skill just filed is a bug in this
   skill's writes, not the store — do not silently continue; surface it.
3. Append the capture event's `id` to `data/ingestion/debrief-filed.log`.

Steps 1-2 run once per event in single-event mode, or once after each
event (not batched to the end) in batch mode, so a mid-batch failure
leaves the index/validation state consistent with whatever was actually
filed so far.

## Not in this core

The following are out of scope for this document — placeholders below for
follow-up units that extend this same `SKILL.md` in place, per Plan 03's
Wave B split:

### Commitment extraction (detail)

This refines §5b's `## Commitments` bullet beyond "an obvious, plainly-
stated commitment lands with the right owner" — the detail needed to get
attribution and dates right across the fuller range of phrasing debriefs
actually use.

**What counts as a commitment.** Any explicit promise or clearly stated
intention by either party to do something, surfaced anywhere in the
debrief — not only crisp "I'll do X" lines. A soft, no-rush framing still
counts: golden 01's "Said he's been meaning to introduce me to their
marketing lead at some point, nothing urgent though" is a real stated
intention from Jordan and gets a bullet, even though nothing about it is
urgent or scheduled. What does **not** count: idle opinions, hopes, or
chit-chat that names no party's action ("hope we catch up again soon" is
not a commitment — no one stated they'd do anything). When in doubt, ask
"did someone say *they* would do something" — if yes, it's a commitment;
if it's just a feeling or a topic discussed, it isn't.

**Attribution.** `user:` when the user is the one who said they'd do
something (golden 08: the user said he'd send the deck); `[[slug]]:` when
the other party is the one who committed (golden 09: Jamie said she'd send
the contract; golden 01/03: Jordan/Nadia are the ones who offered). For a
`chat-message` event, `isSender: true` lines are the user's own words (a
`user:` commitment when they promise something); every other sender's
lines can produce a `[[slug]]:` commitment for that sender's matched
person.

**Date capture.** Three shapes, matching the goldens exactly:

1. **Explicit date stated** — the debrief names an actual calendar date,
   even inside relative phrasing ("by next Friday, September 4th", "by
   next monday, sept 7th"). Use that stated date directly:
   `[by 2026-09-04]` (golden 08), `[by 2026-09-07]` (golden 09).
2. **Relative duration, no explicit date** — a literal span from the
   interaction's own date (§2) with no calendar date attached ("in three
   weeks"). Compute forward by ordinary calendar arithmetic — three weeks
   is 21 days — from the interaction date: 2026-08-29 + 21 days =
   `[by 2026-09-19]` (golden 04's embedded reminder ask; see the
   reminder-ask section below for how this same date also drives the
   wake-up).
3. **No date or timeframe stated at all** — append `(no date given)` as
   plain trailing prose, never a bracketed `[by ...]` clause (goldens 01,
   02, 03).

**Multiple commitments.** One bullet per distinct stated promise, in the
order made. Never merge two separate promises — even ones made by/to the
same person in the same debrief — into a single bullet.

### Reminder-ask → wake-up entry

**Detecting an explicit ask.** Look for a first-person imperative
specifically asking to be reminded or followed up with later — "remind me
to...", "make sure I follow up...", "don't let me forget to..." — usually
tied to a person and a time expression (golden 04: "Remind me to follow up
with him in three weeks"). This is distinct from implicit musing that
merely notes a future intention without asking for a nudge — "I should
really follow up with him sometime", "we should catch up again soon".
Musing like this creates **no** wake-up; at most it earns an ordinary
`## Open threads` bullet on the person file per §5a, same as any other
loose end, and nothing more.

**Turning a real ask into a wake-up.** Once an explicit ask is detected:

1. It is still a commitment — add the usual `## Commitments` bullet on the
   interaction, owner `user` (the user is committing to their own future
   follow-up), with the due date computed by the same date-resolution
   rules as commitment extraction above (golden 04: "in three weeks" from
   the 2026-08-29 interaction date resolves to `[by 2026-09-19]`).
2. Create exactly one wake-up entry by invoking
   `packages/core/scripts/wakeup-add.sh` — **never** hand-write a
   `wakeups/<id>.md` file directly; that script is the only sanctioned
   writer (`packages/core/contracts/wakeup.md`). For golden 04:

   ```sh
   bash packages/core/scripts/wakeup-add.sh <store-dir> \
     --due 2026-09-19 \
     --person marcus-yeun \
     --why "explicit reminder ask: follow up once the client-pitch crunch has settled" \
     --origin user-ask \
     --context "Marcus was swamped this week (2026-08-29) putting together a big client pitch and sounded stressed about it. He asked to be checked in on in three weeks, once the pitch dust has settled — due 2026-09-19."
   ```

   `--due` is the same computed date as the Commitments bullet above.
   `--person` lists every person this ask concerns (a group reminder ask
   names all of them). `--why` is one line naming the trigger and the
   reason, not bare cadence, per the contract's `why` field rule. `--origin
   user-ask` always, since this is an explicit request, never `signal` or
   `standing`. `--context` is free prose ammunition — what's known about
   the person right now, tied back to the ask and the due date — enough to
   draft from later without re-reading the interaction.
3. Add an `## Open threads` bullet on the matched person's file pointing at
   the new wake-up file so a human skimming the person file can trace it
   (golden 04): `"User asked for a reminder to follow up in three weeks,
   once the pitch dust has settled — see wakeups/2026-09-19-marcus-
   yeun.md."`
4. This wake-up is an ordinary entry in the queue like any other — no
   special-cased delivery path or digest
   (`docs/DECISIONS.md#wakeup-queue-over-digests`); it competes for
   attention the same way a signal-driven or standing entry does.

A debrief with more than one explicit reminder ask produces one
`wakeup-add.sh` invocation and one Commitments bullet per ask.

### Stated-preference lane

Full binding rule: `packages/ingestion/specs/stated-preference-filing.md`.
This is a lane inside the same debrief pass, not a separate skill or capture-
event type — a debrief that also carries a tier statement, a signal opt-out,
a priority, or a cadence wish files both this lane's delta and any ordinary
fact/interaction/commitment delta from the same event. Every write below is
`stated-by-user` provenance, per `docs/DECISIONS.md#preference-provenance`;
never file `**[observed-from-behavior]**` from a raw utterance — that tag is
reserved for the draft-diff loop's confirmed style notes, out of scope here.

**Detecting a trigger.** Classify a debrief line into one of four preference
shapes before falling through to ordinary fact/thread filing:

- **Tier statement** — a direct tier assertion about a named person ("Dana is
  inner-circle now", "bump Sarah to close"), or a reply confirming a
  tier-drift wake-up (see spec (d)).
- **Signal opt-out** — an explicit ask to stop a signal type, global ("stop
  company-news alerts") or person-scoped ("stop birthday reminders for
  Dana").
- **Priority** — a freeform stated priority ("family first this quarter").
- **Cadence wish** — a stated rhythm ask ("quarterly with the Michigan
  crowd").

Anything that doesn't fit one of these four shapes falls through to the
ordinary filing above unchanged. Distinguishing among the four (and from an
ordinary fact) is a classification judgment call this section doesn't
further define — see spec (c)'s note.

**Person resolution reuses §3/§4 as-is.** Tier statements and person-scoped
opt-outs resolve the named person exactly like any other participant hint:
unambiguous match → file directly; zero match → run the new-person flow
above, then file against the new file; ambiguous match → this is a high-value
fact, so it takes this event's one clarifying question per §4 (no store
writes at all, event left unfiled, ask by `[[slug]]` + one identifying line
per candidate — see golden 06). Never guess between candidates and never
split the write.

**Tier writes** — overwrite `tier: <value>` in the resolved person's
frontmatter in place (a scalar field, not a list; no provenance tag, since
tagging applies to `## Facts`/`## Signal opt-outs` bullets, not frontmatter —
golden 01). The confirmation reply to an `attention` tier-drift wake-up (spec
(d)) files identically once the user confirms; a decline writes nothing at
all anywhere in `people/` — no record of the refusal, per the no-guilt rule.

**Signal opt-outs** — map the utterance to a signal-type from the plan 05
detector vocabulary (ask instead of inventing an unrecognized signal-type
string), then append to `profile.md`'s `## Signal opt-outs`:

```
- **[stated-by-user]** <signal-type> — all (<capture date>)
- **[stated-by-user]** <signal-type> — [[slug]] (<capture date>)
```

using the resolved slug for a person-scoped ask (golden 02: `company-news —
all (2026-08-29)`). Check existing bullets first — an equivalent opt-out
already on file is a no-op, not a duplicate append; a new opt-out that
strictly widens an existing narrower one is appended alongside it, never
replacing or removing the narrower bullet (spec (b).4). Never encode an
opt-out any other way (no `ranking-weights.json` entry, no tier change, no
`person.md` edit).

**Priorities and cadence wishes** — append one bullet, lightly cleaned up but
not paraphrased into a different claim, to `## Priorities` or `## Cadence
wishes` respectively:

```
- **[stated-by-user]** <utterance> (<capture date, YYYY-MM-DD>)
```

Always append; never rewrite, merge, or remove an earlier bullet even when a
new one appears to supersede it — `profile.md` is a dated append log, not a
synthesized summary (spec (c)).

**Write discipline (cross-cutting).** `profile.md` writes under this lane are
append-or-check-then-append only — never a section rewrite, reorder, or edit
of an existing bullet's text, with the one exception of §5.4's opt-out dedup
no-op. `person.md` tier writes are frontmatter overwrites with no in-file
history (the private data dir's own `git log`, if versioned, is the history
mechanism). Ingestion remains the sole writer of both files under this lane,
exactly as elsewhere in this skill — `attention` only ever proposes (the
tier-drift wake-up in (d)), never writes.

### New-person creation

This extends §3's zero-match outcome: a hint that resolves to no existing
`people/<slug>.md` is not automatically a new person. Decide first whether
to create one at all, then, if so, file it from the template — optionally
followed by an off-by-default research-seed pass.

**When to create.** Only when the debrief clearly introduces a real,
individual person the user is describing an actual interaction with — a
named human with enough substance to be worth a file (golden 06: "Priya
Nair... Product Manager at Lumen Analytics... met through the fintech
founders Slack" is unambiguously a real person, freshly met, with facts
attached).

**When NOT to create.** Do not create a person file for:

- Organization/company names, team names, or product names surfacing in
  the debrief (these are `org` values on a person's frontmatter, never
  people files of their own).
- Group-chat titles or thread names (a chat-message event's `title` field
  names the conversation, not a person — the individual `senderName`s
  inside it are the candidates, not the title itself).
- Unresolvable fragments — a bare first name or nickname with nothing
  else to go on, no org, no context, nothing that would make a useful
  file. Filing a stub with a single unverifiable name invites duplicate
  people later once real context does arrive.

A hint that doesn't clear this bar is not a new-person case: if it's a
partial/ambiguous fragment that context might still resolve, treat it per
§4's needs-confirmation path or leave it as an unresolved raw hint on the
interaction (do not invent a person to file it against, and do not drop
the event — the fragment can still ride along in `## Summary`/
`participant-hints` on the interaction without a matching person file).

**Creating from the template.** Once a hint clears the bar:

1. **Slug** — derive kebab-case from the full name exactly as
   `packages/core/contracts/person.md` specifies (e.g. "Priya Nair" →
   `priya-nair`), the same derivation used for every existing person.
2. **Start from `packages/core/templates/person.md` verbatim** — its
   frontmatter keys and its three fixed body sections (`## Facts`,
   `## Open threads`, `## Personal details`) in that order, then fill in
   only what the debrief actually supports:
   - `schema_version`, `name` — always filled (`name` from the hint as
     given, e.g. "Priya Nair").
   - `org`, `role`, `location`, `tags`, `birthday`, `how-met`, `tier` —
     fill only the fields the debrief actually states; omit the rest
     (never invent — same rule as any other person file, per the
     contract's Notes section). `how-met` is a good candidate whenever the
     debrief says how they met (golden 06 could carry `how-met: Fintech
     founders Slack community`, though the golden also expresses this as
     a `## Personal details` bullet — either placement is acceptable as
     long as it isn't duplicated as a contradictory pair).
   - `last-touch` — the interaction's date from §2 (golden 06:
     `2026-08-29`), same rule as an existing person.
   - `tier` — leave unset unless the debrief gives a genuine signal; do
     not default to `active` just because the person is new (golden 06's
     `tier: active` reflects a judgment call from the debrief's own
     enthusiasm/"want to keep in touch" framing, not a blanket default).
3. **Every seeded fact is `**[told-by-user]**`, dated** — everything the
   debrief states about this brand-new person becomes a `## Facts` bullet
   in exactly the same tagged, dated shape as §5a uses for existing
   people (golden 06:
   `- **[told-by-user]** Product Manager at Lumen Analytics (2026-08-29)`,
   `- **[told-by-user]** Hiring for a data engineering role (2026-08-29)`).
   There is no append-only history to preserve yet (this is the file's
   first write), but the tag and trailing date are still mandatory —
   `inferred-public-web` never appears here; that tag belongs only to the
   optional research-seed pass below, and the two provenance labels are
   never mixed into the same bullet.
   - Loose ends become `## Open threads` bullets, no tag (golden 06:
     `- Keep an eye out for data engineering candidates to refer to
     Priya.`).
   - Texture that doesn't belong in `## Facts` goes to
     `## Personal details`, tagged `**[told-by-user]**` on any factual
     claim within it (golden 06: `**[told-by-user]** Met through the
     fintech founders Slack community.`).
4. **First interaction linked** — file the new person exactly like any
   other matched participant in §5b: the new `[[slug]]` goes into the
   interaction's `people` list in hint order, and if this new person is
   the first-listed hint they are the interaction's primary person and
   drive the `<date>-<primary-person-slug>` filename (golden 06:
   `interactions/2026-08-29-priya-nair.md`, `people: ["[[priya-nair]]"]`).
   Everything else about the interaction file follows §5b unchanged.

**Optional research-seed pass.** A second, strictly separate step, off by
default:

- **Off unless explicitly requested.** This skill never runs a web search
  on its own initiative. Only perform it when the human/agent invoking
  this skill explicitly asks for a research seed on this new person (or a
  standing per-run flag says so) — otherwise skip it entirely, including
  in batch mode, where it is always skipped unless a batch-wide flag
  explicitly requests it for every new person created in that sweep.
- **Scope: public-web search on name + company only.** Query only the
  new person's name plus whatever `org` the told-by-user facts already
  established (or the name alone if no org is known yet) — nothing else.
  This keeps the pass TOS-clean-signals-only: no LinkedIn scraping, no
  enrichment APIs, no third-party people-data providers, per the
  standing-principles' "other people's data stays local" rule. General
  public web search results (company news, public bios, press) are fair
  game; anything that resembles a scraped profile or purchased enrichment
  record is not.
- **Every seeded fact tagged `**[inferred-public-web]**`, never mixed with
  told-by-user bullets.** Facts the research pass adds become their own
  `## Facts` bullets (or `## Personal details` bullets, same tagging
  rule), each tagged `**[inferred-public-web]**` with a trailing date
  noting when the inference was made — per `docs/DECISIONS.md#provenance-
  labeling` and the person contract's tagging rule. A research-seed fact
  is always its own bullet; it is never appended to, or blended into the
  text of, a `**[told-by-user]**` bullet from step 3 above, even when both
  describe the same underlying fact (e.g. a told-by-user "Product Manager
  at Lumen Analytics" bullet and an inferred-public-web "Lumen Analytics
  raised a seed round in 2026" bullet sit as two separate lines, never
  merged into one).
- **Batch mode.** Skip the research-seed pass entirely during an
  unattended batch sweep unless the batch invocation explicitly requested
  it — a batch run's default behavior for new people is identical to
  single-event mode's default: template + told-by-user facts only, no web
  search.

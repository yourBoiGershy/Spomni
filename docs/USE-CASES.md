# Use cases — what Spomni is *for*

Status: LIVE — §1 is the mission (decided 2026-08-29); §3–6 are the working scenario map. Companion to
[PROJECT-CONTEXT.md](PROJECT-CONTEXT.md), which defines *how* the machine is
built. This doc defines *what a person gets from it*, so the roadmap can be
judged against outcomes instead of lanes and pipelines.

---

## 1. The mission

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

### The two piles

| Ingredients (never touched) | Running costs (the whole product) |
|---|---|
| Trust — earned in the conversation | Remembering-to: what was said, what was promised |
| Care — you have to actually mean it | Noticing: time passed, something happened to them |
| Intent — you decide who matters | Timing: when is a good moment, when is a bad one |
| Time — the moments you spend together | Deciding-who: which few, this week, out of hundreds |
| | Starting: the blank page, the "hey, long time" |
| | Following-through: the link you said you'd send, the reminder to circle back |

The claim is that the two piles are *separable*: the right column is pure
friction, not a hidden ingredient. It produces heat and no motion. The other
person never sees it. That's what makes offloading it safe — and it is why
this is not "outsourcing your friendships": it's outsourcing the part that
was never the friendship.

Three consequences:

- **A test for every feature** (above). A drift nudge passes — it cuts the
  cost of noticing. Auto-send fails — it substitutes for intent. A draft
  passes *only if* it's in your voice; a generic draft substitutes for care.
- **Why it isn't a CRM, without saying so:** a CRM tracks the relationship's
  *value* (pipeline, health score, activity count). Spomni only ever
  touches the *cost*.
- **Memory and noticing are inputs, not the product.** "It remembers for
  you" always sounded like admitting you don't care. Here, memory exists so
  the agent can cut the *other* costs well — timing, starting, following
  through.

<details><summary>Footnote — the three framings this replaced</summary>

Earlier drafts tried "external memory" (opens on a search box), "attention
allocator" (opens on a queue), and "outreach assistant" (opens on a draft).
All three are kinds of running cost — remembering-to, deciding-who, and
starting respectively — so the mission subsumes them. The queue is still the
first screen, because deciding-who is the cost with the highest daily
frequency; but it's the mechanism, not the identity.

</details>

---

## 2. Four lenses for generating use cases

Use these to brainstorm systematically instead of one story at a time.

### Lens 1 — Relationship kind × what "maintaining" means

The same agent action means different things per kind. This is the axis
plan 30 (user model + relationship kind) is already circling.

| Kind | What maintaining means | Cadence feel | Failure that hurts |
|---|---|---|---|
| Family | Being present for their life events | Continuous, low ceremony | Missing something big (surgery, move, kid's milestone) |
| Close friends | Not letting a life stage swallow the friendship | Weeks | Six months of silence you didn't notice |
| Old friends / weak-but-warm ties | Occasional rekindle with a real hook | Months–years | Reaching out with nothing to say |
| Professional peers / collaborators | Staying in each other's mental rolodex | Months | Being forgotten when an opportunity comes up |
| Clients / prospects | Being there at the moment of need | Signal-driven | Contacting them on a cadence with no reason (feels like sales) |
| Mentors / advisors | Closing the loop on advice they gave | Event-driven | Never reporting back → they stop investing |
| Mentees / people you help | Checking in without hovering | Months | Silent drift; they think you're too busy |
| Acquaintances / one-time meets | Convert or gracefully let go | One shot | Zombie contacts that clutter every list |

### Lens 2 — Moments in time (when does the agent earn its keep?)

```
      ┌─ before a meeting ─── brief: who, last time, open threads, what to ask
      │
      ├─ right after ──────── (silence — the "relationship's own time" rule)
      │
      ├─ later that day/next ─ "anything worth remembering?" → debrief → filed
      │
      ├─ idle / drift ──────── nudge: "it's been a while AND here's a hook"
      │
      ├─ life event ────────── signal: birthday, job change, move, launch, loss
      │
      ├─ your own event ────── "I'm in Berlin next month — who's there?"
      │
      ├─ a need ────────────── "who do I know who's done X?"
      │
      └─ a promise ─────────── "remind me to follow up in a month" → fires w/ context
```

Every scenario in §3 lands on one of these moments. If a proposed feature
doesn't, it's probably infrastructure, not a use case.

### Lens 3 — Questions the user actually asks

Verbatim shapes, grouped by who's asking:

- **Recall:** "What did Dana and I talk about last time?" / "Where did I meet
  this person?" / "What's her partner's name?"
- **Search by attribute:** "Who do I know in fintech in Toronto?" / "Who
  mentioned they were hiring?" / "Who's been to that conference?"
- **Search by situation:** "Who could intro me to Company X?" / "Who'd be
  good to ask about moving to Lisbon?" / "Who owes me a reply?"
- **Reflection:** "Who am I neglecting?" / "Who did I say I'd get back to?"
  / "Who did I talk to most this quarter — and is that who I *meant* to?"
- **Planning:** "Trip to NYC 12–15 Oct — who should I see?" / "Who should I
  invite to the dinner?" / "Who haven't I seen this year that I want to?"

### Lens 4 — Trigger sources (what the agent can *notice* on its own)

Already bound in PROJECT-CONTEXT (ToS-clean set): birthdays, job changes,
company news, event co-attendance, LinkedIn-post notifications, calendar,
debrief harvest. Unbound but worth listing so we know what we're declining:

- **Reply-debt** — they wrote, you never answered (email/Beeper threads)
- **Your own calendar shape** — a free afternoon, a trip, a conference
- **Recurring anniversaries** — "a year since you two launched X"
- **Second-degree** — you met two people who'd like each other (intros)
- **Promise extraction** — "I'll send you that link" said in a meeting → open loop

---

## 3. Scenario catalogue

Format: **Situation → agent → human.** Grouped by the job it serves; each
job names the running cost(s) it cuts (§1) and the ingredient it must not
touch. Star (★) = already covered by a shipped/planned chunk; (○) = nothing
yet.

| Job | Running cost cut | Ingredient guard |
|---|---|---|
| A — Never walk in cold | remembering-to | the conversation stays yours; the brief never scripts it |
| B — Notice the drift | noticing, deciding-who, timing | the agent proposes who; you decide who matters (intent) |
| C — Act in 30 seconds | starting | drafts in *your* voice or not at all (care) |
| D — Keep promises | following-through | it reminds; it never does the thing for you |
| E — Use your time in the world | deciding-who, timing | it ranks candidates; the invite is yours (time) |
| F — Onboarding | remembering-to (bulk) | tiers are *asked*, never inferred silently (intent) |

### Job A — Never walk in cold (memory)

1. ★ **Pre-meeting brief.** 30 min before a calendar event with a known
   person: one card — last interaction, open threads, 2 things to ask.
   → Human reads on phone in the elevator. (plan 21, query briefs)
2. ★ **Lazy debrief.** Next morning: "You met Dana and Raj yesterday —
   anything worth keeping?" User rambles 3 sentences or ignores it.
   → Filed as an interaction, people updated, no nagging. (plans 03, 25)
3. ○ **Cold-name lookup.** A name in an email/Slack you half-recognize →
   "Who is this?" → one paragraph: how you know them, last contact.
4. ★ **Attribute search.** "Who do I know in healthcare data?" → ranked
   list with why-each. (query, MCP)
5. ○ **Situation search.** "Who could intro me to Shopify?" → agent reasons
   over orgs + stated connections, flags confidence + provenance.

### Job B — Notice the drift (attention)

6. ★ **Drift nudge with a hook.** "Sam — 4 months quiet. He was launching
   the podcast; it's out now. Draft?" (plan 05/06; hook = signal + rarity)
7. ★ **Birthday with context.** Not "it's X's birthday" but "it's X's
   birthday; last time she was prepping the Berlin move."
8. ○ **Reply debt.** "Three people wrote you >10 days ago and you never
   replied — Ana, Ken, Priya. Want drafts?"
9. ★ **Capacity-aware queue.** Max ~5 live nudges; snooze/dismiss teaches
   ranking; nothing accumulates into guilt. (plan 12)
10. ○ **Quarterly mirror.** "Here's who you actually spent time with vs.
    who you marked as important." No judgment, just the delta.

### Job C — Act in 30 seconds (drafting)

11. ★ **Draft in the user's voice.** Every nudge carries a draft matching
    the channel (email vs. WhatsApp tone) and the user's preferences.
    (plan 15, plan 07)
12. ○ **Channel-aware handoff.** The draft lands where the send button is:
    Gmail draft, Beeper compose box, clipboard. Never auto-send.
13. ○ **Intro draft.** "Ana and Raj should meet — both doing X" → double
    opt-in intro drafts, one per side.
14. ○ **Loop-closer.** "Mentor Jo gave you advice on pricing in May; you
    shipped the new pricing last week — tell her?"

### Job D — Keep promises (reminders with memory)

15. ★ **Contextual reminder.** "Remind me to check on Lee in a month" → fires
    with the *reason* and what's happened since. (wakeup queue)
16. ○ **Promise extraction.** Debrief says "I'll send him the deck" → open
    loop tracked; nudged once, then dropped.

### Job E — Use your time in the world (planning)

17. ○ **Trip planner.** "Berlin 12–15 Oct" → who's there, ranked by warmth ×
    time-since, with a group draft.
18. ○ **Event prep.** Conference attendee list (from confirmation email) ∩
    people store → "6 people you know are going."
19. ○ **Guest list.** "Dinner for 8, mix of design and founders" → candidates.

### Job F — Onboarding / getting to value (the first hour)

20. ★ **Backfill.** Point it at Gmail/Calendar/Beeper history → store
    populated, first nudges within the hour. (plans 20, 24, 26)
21. ○ **Tiering conversation.** Instead of a 32-person bulk prompt (which
    got all-skip — see memory), tier *in the flow*: first time a person
    surfaces in a nudge, ask "how much do you care about this one?"

---

## 4. A week with Spomni (narrative test)

Useful for checking whether the scenarios above cohere into one product.

**Mon 08:10** — Brief for the 10:00 with Dana: last talk in June was about
her Berlin move; she asked for a contact at a design agency; you never sent
it. (Job A + D.) You send the contact before the call. Win before 9am.

**Mon 10:45** — Nothing. The agent stays silent after the meeting.

**Tue 08:00** — "Yesterday: Dana. Anything worth keeping?" You type: "moved,
loves it, kid starts school Sept, wants to talk about consulting in Q4."
Filed. A wake-up for late September appears on its own ("kid starts
school"), and one for October ("consulting").

**Wed** — Queue has 4 items: Sam (podcast launched, 4 months quiet), Ana
(reply debt, 12 days), Ken's birthday Friday (context: new job in July),
and a Lee reminder you set in July. You send Sam's draft as-is, tweak
Ken's, snooze Ana, dismiss Lee ("we talked at the thing"). Ranking learns.

**Thu** — "Who do I know who's done a Shopify integration?" → two names,
one with high confidence (you told the agent), one inferred (from an email
signature). You message the first.

**Fri** — Nothing new. Quiet is a valid state.

**Test:** does every beat above trace to a scenario in §3, and does every
package in PROJECT-CONTEXT show up? (Yes to both — which is the point.)

---

## 5. Non-goals (say them so they stop haunting the roadmap)

- **Not a CRM.** No pipeline stages, no deal values, no "activities logged"
  metrics. If a feature wants a dashboard, it's drifting.
- **Not a social feed.** It never shows you what people are posting; it
  tells you when something someone did is a reason for *you* to act.
- **Not an auto-mailer.** Draft, never send. Not even "with confirmation."
- **Not a habit app.** No streaks, no "you've debriefed 5 days in a row."
- **Not an enricher.** It knows what you told it and what your own accounts
  contain. It does not go find out about people.
- **Not a team tool (v1).** One user, one store, one private data dir.

---

## 6. The forks you actually have to decide

1. ~~Problem framing~~ — **decided 2026-08-29**: ingredients vs. running
   cost (§1). The queue stays the first screen as mechanism, not identity.
2. **Where does the nudge land?** Chat (Claude Code / MCP), a daily digest
   file, Slack DM, email-to-self? Plan 07 needs one primary answer; the
   "week" narrative above assumes a morning digest + on-demand chat.
3. **Reply-debt as a v1 signal?** It's the highest-frequency, lowest-effort
   hook (scenario 8) and Beeper/Gmail data already supports it. Not in the
   bound v1 signal set. Recommend: add it.
4. **Tiering strategy** (scenario 21): in-flow vs. batch. Batch already
   failed once. Recommend: in-flow, on first surfacing.
5. **Relationship-kind vocabulary** (Lens 1): plan 30 needs a fixed set.
   The 8 rows above are a proposal.

---

## 7. How to use this doc

- Every ROADMAP chunk carries a **Mission test** line: which running cost
  it cuts (or "infrastructure for <cost>"), and which ingredient it is
  nearest to and how it stays clear. Every plan and worker brief §1 does
  the same.
- Every ROADMAP chunk should name the §3 scenarios it advances. A chunk
  that advances none is infrastructure and should say so.
- New feature ideas get run through the four lenses in §2 first; if they
  don't land on a moment (Lens 2) or a question (Lens 3), park them.
- Rerun the §4 narrative after each ship: does the week get better, or
  just the machine?

# Research: nudge delivery channel + a real feedback loop

Date: 2026-08-30. Status: research note → feeds a plan-07 amendment (delivery)
and a new chunk (feedback ledger). Orchestrator-authored; nothing here is
built yet.

**Mission test.** Delivery = the cost of *remembering-to* reaching the user
at all; feedback = the cost of *re-explaining yourself* to the assistant.
Both are pure running cost. Nearest ingredient risk: a nudge that lands as
guilt (streaks/backlog) or a feedback loop that optimizes for engagement —
both explicitly excluded below.

---

## Part 1 — How a nudge reaches the user

### What exists today

- `wakeup-queue.sh fire` emits `wakeups/fired/<ts>-batch.json` (id, due,
  people, why, kind, signal_type, context, draft, proposed_event).
- The sweep's last step, "hand batch to an output adapter", **skips** (07
  unbuilt). Live store: zero wake-ups ever fired.
- Plan 07 specs two adapters: `file-out` (`data/outbox/YYYY-MM-DD.md`) and
  `gmail-out` (self-address only). Plan 07's amendment asks for the channel
  decision; roadmap doctrine: notifying *yourself* may be a real send.

### Channel candidates, verified 2026-08-30

| Channel | Verified | Unattended (from 28's tick)? | Reply captured? | Notes |
|---|---|---|---|---|
| **Beeper note-to-self** | Yes — "Note to self" Matrix chat exists (chatID `1`, active 2026-08-29); Desktop API has `POST /v1/chats/{id}/messages` and `/reminders` | **Yes** — local HTTP `localhost:23373` + bearer token, identical to `beeper-in`'s existing path; Beeper Desktop must be running (already a prerequisite of the beeper lane) | **Yes, for free** — `beeper-in` already ingests the Matrix account, so a reply in that chat lands in `inbox/` as a capture event | Phone push via the Beeper mobile app. Also supports `set_chat_reminder` = native "remind me at" without our own scheduler. |
| gmail-self | Adapter specced (07); first-party Gmail MCP `send_message`/`create_draft` | **No** — MCP is session-driven; headless needs a `claude -p` lane (28 ships those disabled) | Partial — `gmail-in` would see a reply-to-self thread, but typed as `email`, not feedback | Universal, works without Beeper. Best *fallback*. |
| outbox file | Specced (07) | Yes (pure filesystem) | No | Zero-dependency; in-session digest. Keep as always-on audit trail regardless of channel. |
| WhatsApp/iMessage self-chat via Beeper | Possible (WhatsApp "message yourself"; iMessage to own number) — none exists in the account today | Yes (same API) | Yes (same lane) | No advantage over the Matrix note-to-self, and puts assistant text into a network that syncs to contacts' devices' metadata. Not recommended. |
| macOS/phone push (ntfy, Pushover, etc.) | Not evaluated | Yes | No | Adds a third-party service holding nudge text about other people → conflicts with "other people's data stays local". Out. |

### Recommendation

1. **Channel is user config, not code.** Add a `## Notify` block to
   `profile.md` (its sole writer is ingestion; the user states it once):
   ```
   ## Notify
   - channel: beeper-self | gmail-self | outbox | none   (stated-by-user)
   - beeper_chat_id: 1
   - digest: daily | per-fire
   - quiet_hours: 22:00-08:00
   ```
   `week-plan.json` capacity + quiet hours gate *when*; this block gates
   *where*. The adapter reads config only — one render, N destinations,
   exactly plan 07's interface.
2. **Default = `beeper-self` when the beeper lane is configured, else
   `gmail-self`.** Reasoning: Beeper is the only channel that is
   unattended-capable *and* reply-capturable today; email is the universal
   fallback. `outbox` always writes in addition (audit + in-session view).
3. **One message per batch, not per wake-up** — the fired batch is already
   budget-capped (default 3/week), so a daily digest is short. No-guilt
   rules apply to the render: no counts of "pending", no "you missed", no
   streaks. Each card: trigger, ammunition, optional draft, and the reply
   grammar (below).
4. `set_chat_reminder` on the note-to-self chat is a free snooze
   implementation for `beeper-self`: "snooze 2w" → we push `due` forward
   *and* set a native Beeper reminder.

**New sub-package:** `packages/connectors/beeper-out/` (dumb: takes rendered
text + chat id, POSTs; refuses any chat id not listed under `## Notify` —
the self-only rule, enforced the same way `gmail-out` refuses non-self
recipients). Never-send lint in `oss-guard.sh` needs an allowlist entry for
this one path, with the self-only check as the tested invariant.

---

## Part 2 — Feedback: what is captured, what it moves, what's missing

### Inventory of feedback the system already has a slot for

| Feedback | Where recorded | What it moves today | Loop closed live? |
|---|---|---|---|
| Snooze / dismiss (`not-now`, `not-this-person`, `not-this-signal-type`, `already-handled`) | `wakeups/<id>.md` lifecycle fields (attention sole writer) | `calibrate.sh` → `ranking-weights.json` `signal-types` + `tags` (±0.15/step, [0.25,2.0], 90d window, needs ≥3 fired). `not-this-person` → per-person suppression *proposal* wake-up. | No — zero wake-ups fired |
| Acted-on (auto: interaction with that person within 7d of firing) | same | same — the positive term of the weight formula | No |
| Event-proposal confirm/decline | same (`confirmed-on`, decline reason) | tier-drift "silence-on-decline" eval; 30-day suppression in scheduling-intent | No |
| Signal opt-outs | `profile.md ## Signal opt-outs` (stated) | Deterministic suppression before ranking | Mechanism exists, no live entries |
| Tier / kind correction | `people/<slug>.md` `tier_source: stated-by-user` (sticky) | That one person only; plus **neighbor priors** (embeddings) let a stated neighbor influence a derived judgment | Corrections digest exists (plan 31); tiers never confirmed live |
| User-model (investment mix, season, protected) | `user-model.md` provisional → confirmed | `--seed-from-user-model` → `kinds`/`evidence` priors → both signal ranking and tier-drift judgment | Provisional only |
| Draft edits / style | `profile.md` observed style notes "from the draft-diff loop" (plan 15) | Nothing reads them into a prompt yet; the draft-diff loop itself has no surface to run on | No |

### The gaps, in order of leverage

**G1. No single feedback ledger.** Feedback is scattered across four
writers (wakeup fields, person tier_source, profile, user-model). Nothing
can answer "what has the user told us in the last 30 days" in one read, so
nothing can *iterate* on it. Every other gap is downstream of this.

**G2. Feedback never reaches a prompt.** The judgment prompts
(`relationship-scoring.md`, tier-drift, debrief drafts) get numeric priors
and neighbors, but never the user's own words. A correction like "not
family, that's my accountant" is reduced to `kind: transactional` on one
file; the *reason* evaporates.

**G3. Outcome calibration only touches ranking.** `ranking-weights.json`
multiplies candidates that detectors already found. It does not change
**who is looked for**: detector horizons (tier-drift prefilter), which
tags/kinds co-attendance and debrief-harvest scan, or the budget split
across kinds. A user who dismisses every `professional` drift nudge still
gets `professional` people enumerated first.

**G4. Corrections don't roll up.** Six "bump to close" corrections on
family people should *propose* a user-model revision (raise the `family`
axis) — attention proposes, ingestion writes, exactly the existing
provisional→confirmed path — but nothing aggregates person-level
corrections into model-level proposals.

**G5. No reply path.** Snooze/dismiss are "replies to the agent" (plan 07),
but with no delivery channel there is no reply to parse. Reasons are the
most valuable feedback we have, and they need a one-word grammar the user
will actually type on a phone.

**G6. No accuracy metric.** "Actively iterated" needs a number. Nothing
computes correction rate per judge run, acted-on rate per signal type, or
whether the last prompt change helped.

### Proposed design (chunk: "feedback ledger")

**F1. `feedback-event@1` contract + append-only ledger** (`core`):
`signals/feedback.jsonl`, one line per event. Source of truth; everything
else derived (same regenerable semantics as `ranking-weights.json`).
```json
{"ts":"2026-08-30T14:02Z","type":"dismiss","target":"wakeup:2026-08-30-birthday-jane","reason":"not-this-signal-type","text":"I never do birthdays","channel":"beeper-self"}
{"ts":"...","type":"tier-correction","target":"person:jane-doe","from":"active","to":"close","text":"she's basically family"}
{"ts":"...","type":"kind-correction","target":"person:bob-cpa","from":"friends","to":"transactional","text":"my accountant"}
{"ts":"...","type":"draft-edit","target":"wakeup:...","diff":"...","text":null}
{"ts":"...","type":"opt-out","target":"signal:linkedin-post","scope":"all"}
```
`type` enum, `text` = the user's verbatim words (provenance stated-by-user
by definition). Writer: ingestion (a `feedback-file.sh`), called by the
existing ops — `wakeup-queue.sh dismiss/snooze`, `person-set-tier.sh`,
review-tiers digest corrections — so today's writers stay sole writers of
their files and *additionally* emit a ledger line.

**F2. Reply grammar + capture** (`connectors/beeper-in` + `ingestion`):
replies in the note-to-self chat, or on a gmail-self thread, typed as a
new capture-event kind `feedback`. Grammar (first token wins, rest is
`text`):
```
1 done | 1 snooze 2w | 1 skip | 1 never <signal> | 1 not-him | 1 wrong-tier close
```
where `1` is the card index in the last digest. Free text after the verb is
kept verbatim into the ledger. Unparseable replies → filed as plain
`text` feedback, never dropped.

**F3. Feedback → prompting** (`ingestion` judge, `attention` drafts):
- **Few-shot from corrections.** Every judgment prompt gets a
  `## Recent corrections` block: the last N (cap 10) ledger lines of
  `*-correction` type, each rendered as *"judge said X, user said Y, user's
  words: '…'"*. Cheapest possible "affects prompting" lever; the words the
  user typed are the best instruction there is.
- **Style notes into draft prompts.** `draft-edit` events → the plan-15
  draft-diff loop writes `profile.md` style notes (already specced) → the
  nudge renderer's draft prompt reads them. This finally gives the
  specced-but-unused profile section a producer and a consumer.
- **Correction → eval case, automatically.** Each `*-correction` becomes a
  T3 eval case (`packages/ingestion/evals/`): "judge on this person must
  now yield the stated kind/tier." Prompt changes are thereby regression-
  tested against everything the user has ever corrected. This is the
  concrete meaning of *actively iterated*.

**F4. Feedback → who you look for** (`attention`):
- `ranking-weights.json` gains a `kinds` *outcome* term (today `kinds` is
  seed-only from the user-model): acted-on/dismiss rates per kind, same
  formula and clamps as signal-types.
- Detectors read the weights **before** enumeration, not just at ranking:
  tier-drift prefilter orders kinds by weight and stops at budget; a kind
  weight ≤ 0.5 halves that kind's candidate share. Budget split across
  kinds follows the user-model mix × kind weights.
- `not-this-person` × 2 in 90d → auto-write the opt-out to `profile.md`
  as a *proposal line* awaiting one-word confirm in the next digest
  (existing suppression-proposal path, just surfaced through the channel).

**F5. Corrections → user-model revision proposals** (`attention` proposes,
`ingestion` writes): a weekly step in `weekly-planning`: if ≥3 corrections
in 30d move the same axis the same direction, emit one `origin: standing`
wake-up: *"You've moved 4 family people closer. Raise family from 0.2 →
0.35?"* Confirm = user-model `revision++` → reseed priors. Never silent.

**F6. Metrics, shown once a week, no guilt framing** (`attention` →
weekly digest): acted-on rate by signal type and kind, dismiss-reason
histogram, correction rate per judge run (1 − corrections/derived), and
"since last prompt change" deltas. Framed as *the assistant's* report card
("I got 3 of 5 right"), never the user's.

### What this deliberately does not do

- No engagement optimization: acted-on is a *quality* signal for the
  assistant's judgment, not a target to maximize nudge volume; budget stays
  user-set.
- No per-person weight learning beyond suppression (contract stance kept —
  a person is a stated tier, not a learned score).
- No auto-adoption of style: draft-edit → profile note still passes the
  plan-15 confirm step.

---

## Sequencing proposal

1. **07-delivery** (small): `## Notify` block in profile 1.1.0; `beeper-out`
   + `gmail-out` + `outbox` adapters; card renderer with reply grammar;
   sweep's last step wired; one live fire to the Beeper note-to-self chat.
2. **Feedback ledger** (F1, F2): contract, `feedback-file.sh`, hooks in the
   three existing writers, reply capture via beeper-in. Now every reply and
   correction is durable.
3. **Feedback → prompts + evals** (F3): the highest-leverage, smallest-code
   item once the ledger exists.
4. **Feedback → search + model** (F4, F5, F6): after ≥2 weeks of live
   ledger data, so the first tuning is against real outcomes.

Decisions (user, 2026-08-30):
- **Default channel = `beeper-self`** (note-to-self Matrix chat); `gmail-self`
  fallback when no beeper lane; `outbox` always written.
- **Numbered replies** (`1 snooze 2w`, `2 done`, `3 never birthday`).
- **Cadence rides on sync, not a clock.** Every sync tick (28's
  `mcp-lane-tick.sh` / the beeper lane) does a cheap check: (a) new replies
  in the note-to-self chat since the last cursor → parse + apply via the
  ledger; (b) anything newly due/fired → send. No separate daily-hour digest
  scheduler; quiet hours + budget still gate sends. A tick with no change is
  a no-op in milliseconds.

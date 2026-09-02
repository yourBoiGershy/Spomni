# Plan 44 — Reminders that actually fire, and a pluggable notification service (Google Calendar channel first)

**Roadmap row:** 44. **Status:** wave A built (this branch); wave B ready for
implementation pending the user's go on the calendar defaults in D5.
**Mission test:** cuts *remembering-to* twice over — (A) a reminder the user
already asked for reaches them on its due date without a session; (B) it
reaches them where they actually look. No ingredient is touched: every
channel delivers only to the user themselves (`notify-self-is-a-send`); the
cards carry no draft inline; the human still writes and sends every message.

## Motivation — live diagnosis, 2026-09-02 (Mac, main checkout)

The user has received zero reach-out reminders since the store went live on
2026-08-31, while 4 `user-ask` wake-ups (Camilo, Willem, Abhinav, Rafael
coffee) sat `pending` past their due dates. Four independent causes:

1. **Nothing scheduled ever calls `fire`.** `docs/runtime-cloud.md` made the
   `daily-attention` sweep the only scheduled caller of `wakeup-queue.sh
   fire`, but the sweep is a model-session skill with no lane, no launchd
   job, no cron — it has never run here (no `wakeups/fired/`, no
   `heartbeats/`, no `outbox/`). The `notify` lane ran every 15 min and
   logged `deliver: nothing new` forever. Consequence: no user-ask
   reminders, and no signal-derived suggestions at all (signal-scan lives in
   the same unscheduled sweep).
2. **Headless model lanes exit 127.** `sync-lib.sh` resolved `{{CLAUDE_BIN}}`
   via `command -v claude` → `~/.claude/local/claude` → literal `claude`.
   Under launchd's minimal PATH the first fails, the second doesn't exist on
   a current install (`~/.local/bin/claude`), so `gmail-in`, `calendar-in`
   (and any sweep lane) failed on every tick since 2026-08-31T20:58Z.
   `mcp-lane-tick.sh preflight --lane calendar` with the right binary
   reports `preflight-ok` — the connector itself works headless.
3. **launchd is blocked from the repo path.** Since ~2026-09-02T04:30Z every
   lane dies before the script runs (`/bin/bash: …/sync-scheduler.sh:
   Interrupted system call`, launchd last-exit 126). The checkout is under
   `~/Documents`, which `check-store-location.sh` already WARNs about and
   `docs/SETUP.md` §1 documents: macOS TCC blocks launchd there unless
   `/bin/bash` has Full Disk Access, or the repo moves. Human-only fix.
4. **`wakeup-queue.sh` has no jq fallback** for launchd's PATH (deliver-tick
   does), so a fire lane would have failed the same way `notify` didn't.

Also found: six stale `staleness:<lane>` self wake-ups from the 08-30 outage
were still pending (dismissed `already-handled` this session); and
`data/ingestion/debrief-filed.log` is absent on this machine (filing
happened in a cloud session), so ~243 of 462 inbox events look unfiled to
the sweep's batch step — a scheduled sweep would try to re-file them.

## Wave A — delivered on this branch

| Piece | Where | What |
|---|---|---|
| claude resolution chain | `packages/connectors/scripts/sync-lib.sh` + scheduler test | env → PATH → `~/.local/bin` → `~/.claude/local` → Homebrew ×2 → literal |
| `attention-fire` lane | `packages/core/templates/sync-lanes.tsv` (enabled, 3600s) | deterministic `wakeup-queue.sh fire && acted-on`; `notify` delivers the batch ≤15 min later |
| `attention-sweep` lane | same template (disabled, 86400s) | headless full `daily-attention` sweep via `mcp-lane-tick.sh`, `--expect "step=heartbeat status=ok"`; pre-enable checklist in the row comment (filed ledger, preflight) |
| jq fallback | `packages/attention/scripts/wakeup-queue.sh` | same block as `deliver-tick.sh` |
| Doctrine | `docs/runtime-cloud.md` "Who writes what", sweep `SKILL.md` | `fire` has two scheduled callers; the sweep stays the sole scheduled producer of signal wake-ups |
| Live cutover (data dir, uncommitted here) | `data/connectors/sync-scheduler/lanes.tsv` | `attention-fire` row added; first batch fired manually 2026-09-02T01:36 EDT (4 cards), held for quiet hours |

Owed to the human before any of this ticks: grant `/bin/bash` Full Disk
Access (System Settings → Privacy & Security → Full Disk Access) **or** move
the checkout out of `~/Documents`; then `bash
packages/connectors/scripts/sync-scheduler.sh install --data-dir data` and
kickstart `notify`.

## Wave B — the notification service as a plugin surface

### The shape today

`deliver-tick.sh` is already the service: it renders every undelivered
fired batch once (core `render-nudge-cards.sh`), always writes the outbox
audit trail (`file-out`), then routes by `profile.md ## Notify`'s `channel:`
bullet with a hard-coded `case` over `beeper-self | gmail-self | outbox |
none`. Two adapter *modes* exist and both must survive: **script** (beeper-
out: deterministic bash, sends now) and **session** (gmail-out: stages
`outbox/pending-gmail/*.txt`, a Claude session with the first-party
connector drains it). Google Calendar is a session-mode channel — the only
sanctioned calendar write is the first-party claude.ai connector
(`composio-retired`, `event-confirm` precedent).

### Decisions

- **D1 Channels are a registry, not an enum.** `profile.md` → 1.2.0: the
  `channel:` value is any `[a-z0-9-]+` name resolved against a channel
  manifest, `channel.tsv`, looked up first-party at
  `packages/connectors/<name>/channel.tsv` and then in the user's private
  data dir at `<data-dir>/connectors/out/<name>/channel.tsv` (user plugins,
  same private-repo pattern as plan 42's user skills). Unknown name → logged
  fallback to `outbox`, never a guess. New core contract
  `notify-channel.md` 1.0.0 (schema for the manifest):

  ```
  # channel.tsv — key<TAB>value
  name	calendar-self
  mode	script | session
  send	<path relative to the manifest dir, script mode only; argv: <store> --text-file <f> --batch <name> [--private-data-root <p>]; exit 0 sent / 4 refused / 5 send-failed; stdout `sent <ref>`>
  staging	<dir under <store>/outbox/, session mode only, e.g. pending-calendar>
  skill	<skill name a session runs to drain the staging dir, session mode only>
  self_only_key	<profile ## Notify key whose value is the ONLY permitted destination, e.g. beeper_chat_id / gmail_address / calendar_id>
  ```
  `self_only_key` is the registry-level encoding of `notify-self-is-a-send`:
  `deliver-tick.sh` refuses to route to a channel whose key is absent from
  `## Notify`, and every adapter must refuse any destination other than that
  value (oss-guard lint: the adapter file must contain the literal
  `refuse: destination not in profile ## Notify`).
- **D2 `deliver-tick.sh` becomes generic.** The `case` collapses to: read
  manifest → script mode: run `send` exactly as it runs `beeper-send.sh`
  today (same exit-code contract, same delivered.log columns) → session
  mode: copy the rendered text **and** the batch JSON into
  `<store>/outbox/<staging>/<batch-name>.{txt,json}`, print `deliver:
  <name> pending (session) <batch>`. Existing built-ins are re-expressed as
  manifests (`beeper-out/channel.tsv` script, `gmail-out/channel.tsv`
  session, `file-out`/`none` stay internal). Behaviour for every existing
  test fixture is unchanged — that is the acceptance bar.
- **D3 A generic drain lane.** One new template row `notify-session`
  (mcp-lane-tick, disabled by default) whose prompt is "drain every
  session-mode staging dir named by the active channel manifest via its
  `skill`", pinned to `--allowed-tools` of the connector the manifest
  names. The sweep's step 8 does the same in-session (today it special-cases
  `gmail-self-notify`; it reads the manifest's `skill` instead).
- **D4 Sub-package `packages/connectors/calendar-out/`** (session mode):
  `channel.tsv` (`name calendar-self`, `staging pending-calendar`, `skill
  calendar-self-notify`, `self_only_key calendar_id`) and
  `skills/calendar-self-notify/SKILL.md`. The skill: for each staged batch,
  one event per card on the calendar whose id is `## Notify`'s
  `calendar_id` (a dedicated secondary calendar the user creates once,
  suggested name "Spomni"), **never any attendees, never any other
  calendar** (refuse + loud log otherwise); title = card line 1 (the
  who/why), description = card line 2 (next action) + the numbered reply
  grammar + `wakeup: <id>`; start = the batch's `today` at `notify_time`
  (new `## Notify` key, default `09:00` local), 30 min, popup reminder at
  0 min; idempotent via `outbox/delivered.log` (`calendar-self` in column
  2, the created event ids comma-joined in column 4). Snooze/dismiss
  replies keep flowing through the existing beeper reply parser (plan 34)
  when beeper-in is on; without it, the event is read-only and the user
  acts from the store — no reply path is invented here.
- **D4b Checklist semantics, not a static event (user ask, 2026-09-02).**
  The user wants the calendar to read like a check-in list: an item per
  reach-out that visibly flips to done. Google Tasks would be the native
  fit, but no first-party Tasks connector exists and `composio-retired`
  rules out the alternative, so the checklist is emulated on calendar
  events and driven by the store's own outcome fields, never by the user
  editing the calendar:
  - create: title `☐ <who> — <why-short>`, `availability: FREE`,
    `colorId` = the "todo" colour; description carries the next action,
    the numbered reply grammar, and `wakeup: <id>`.
  - done: when `acted-on: true` is written (acted-on detection) or the user
    replies `<n> done` (plan 34 parser → `dismiss --reason already-handled`
    …), the drain skill calls `update_event`: title `☑ <who> — <why-short>`,
    `colorId` = the "done" colour. Never deleted — the ticked item is the
    visible result the user asked for.
  - snooze: `snooze` moves the event (`update_event` start/end to the new
    due date), title unchanged. Dismiss for any other reason: title
    `☒ …`, done colour.
  - The mapping event-id ↔ wakeup-id lives in `outbox/delivered.log`
    column 4 (`calendar-self`), so the drain skill is stateless and
    idempotent: it reconciles every wake-up whose lifecycle changed since
    its event was created (a `outbox/calendar-reconciled.log` cursor).
  - Still self-only: one calendar, no attendees, title/description contain
    the person's slug and the next action only — no facts about the person
    beyond what the nudge card already carries.
- **D5 Defaults the user may override** (routine judgment; stated in
  profile via `profile-set-notify.sh --channel calendar-self --calendar-id
  <id> --notify-time HH:MM`): dedicated calendar "Spomni"; one event per
  card (not one per batch — each reach-out is a separately ticked-off
  object in the calendar UI); 09:00 local, 30 min, popup at start; cards
  fired during quiet hours land on the next `notify_time`; done/dismissed
  items stay on the calendar as `☑`/`☒` (never deleted).
- **D6 "Who I should *not* reach out to" is a view, not a nudge.** The
  suppression machinery already exists (14-day cooldown, `## Signal
  opt-outs`, non-relational kinds, expired kinds, declined proposals) and
  silence is its output by design. Add `--holds` to
  `packages/query/scripts/who-next-direct.sh` and `/who-next --holds`:
  the people the ranker would otherwise have surfaced, each with its one
  hold reason (`cooldown until <date>`, `opt-out: <signal>`, `kind:
  transactional`, `snoozed until <date>`). Read-only; never delivered as a
  card (a "don't contact" card is exactly the guilt surface the render
  contract forbids).

### Work units (wave B, splitting rule applied)

| Unit | Package | What |
|---|---|---|
| B1 | core | `contracts/notify-channel.md` 1.0.0 + `profile.md` 1.2.0 (open `channel`, `calendar_id`, `notify_time` keys) + `validate-store.sh` widening + template |
| B2 | ingestion | `profile-set-notify.sh`: `--calendar-id`, `--notify-time`, open channel vocabulary (validated against the registry lookup) + tests |
| B3 | connectors | `deliver-tick.sh` generic dispatch (D2) + `beeper-out/channel.tsv`, `gmail-out/channel.tsv` |
| B4 | connectors | deliver tests: every existing fixture unchanged + manifest lookup, unknown-channel fallback, user-dir plugin, self-only refusal |
| B5 | connectors | `calendar-out/` sub-package: `package.md`, `channel.tsv`, `skills/calendar-self-notify/SKILL.md` (D4 create + D4b reconcile) + `.claude/skills` symlink |
| B6 | connectors | `mcp-lane-tick.sh preflight --lane calendar-out` (requires `create_event`, `list_calendars`) + `notify-session` template row (D3) |
| B7 | attention | sweep step 8 reads the manifest's `skill` instead of hard-coding gmail |
| B8 | query | `who-next-direct.sh --holds` + `/who-next --holds` (D6) + tests |
| B9 | harness | `oss-guard.sh`: allowlist `calendar-out` only while the refuse literal is present; never-send lint covers `create_event` outside `calendar-out`/`event-confirm` |
| B10 | docs (orchestrator) | DECISIONS `notify-channel-registry`, SETUP §notify, ROADMAP, this plan's status |

Cross-package → one worker per package per wave; B3/B4 and B5/B6 are
implementation/test pairs. Estimated 10 briefs, two parallel waves (B1–B2
first: contracts; then B3–B9).

### Out of scope / never

- Any channel that delivers to someone other than the user (registry
  refuses a manifest without `self_only_key`).
- Calendar invites (attendees) — the calendar event is a note to self.
- Push/Slack/etc. — they become one manifest + one adapter each once D1
  lands (ROADMAP "Later" row), not part of this plan.

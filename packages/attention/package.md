# package: attention

version: 0.1.0

## Purpose

Deciding what deserves the user's attention, and when. One concern, two halves that are
deliberately not separate packages: signal detection/ranking (the scout) and the
wake-up queue lifecycle + sweeps (the heartbeat). They share the queue and a feedback
loop — snooze/dismiss outcomes tune future ranking — so splitting them would put a
package boundary through the middle of a conversation (see DECISIONS.md:
attention-merge).

## Provides

- Skills: `skills/signal-scan/` (the ToS-clean detector set + warmth×rarity ranking,
  ~5-nudge cap, two-signal rule), `skills/sweep/` (the background run: capture-sweep →
  calendar-reconcile → filing → signal-scan → fire due wake-ups → hand batch to an
  output adapter)
- Queue lifecycle: `scripts/wakeup-queue.sh` (list-due, fire, snooze, dismiss —
  creation stays with core's `wakeup-add.sh` so any package may append)
- The fired-batch artifact `query`/output adapters render; snooze/dismiss writebacks

## Consumes

- `signal-event@^1`, `wakeup@^1` (core)
- Typed `linkedin-notification`/`event-confirmation` events (connectors/gmail-in),
  contact artifacts (connectors/contacts-in), `same-event-as` links and calendar
  artifacts (ingestion), `needs-follow-up` markers (ingestion)

## Owned paths

`packages/attention/**`; at runtime: the `wakeups/` lifecycle (fire/snooze/dismiss
state) in the private data dir.

## Built by

Plans 05 (detection/ranking) and 06 (queue/sweeps) — two plans, one package.

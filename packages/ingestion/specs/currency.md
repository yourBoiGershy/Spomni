# Spec: store currency

`schema_version: 1.0.0`

Status: spec (plan 36 A1). Package: `packages/ingestion`. Mission test:
cuts *remembering-to* — a person file that only ever grows a chronology
forces the user to re-scan the whole history to answer "where do things
stand with them right now"; this spec keeps `## Open threads` honest about
what's still live versus what's gone quiet, without ever touching a
told-by-the-user fact or performing the follow-up itself.

## Problem

`person.md`'s `## Open threads` section accumulates bullets over time but
nothing ever marks one as no-longer-current. A thread from three months ago
reads exactly like one from yesterday, so every consumer (briefs,
`who-next-direct.sh`, the debrief skill) either re-verifies the whole list
by hand or trusts stale bullets at face value. This spec defines the bullet
shapes that carry currency, the writers that maintain it, and the rule that
keeps a thread from silently going stale forever.

## Bullet shapes

- **Open, current:** `- <text> (as-of YYYY-MM-DD)`
- **Open, demoted:** `- <text> (as-of YYYY-MM-DD, unverified since YYYY-MM-DD)`
- **No-paren bullet (legal, pre-1.4.0):** `- <text>` with no trailing
  parenthetical is still a valid open thread — it predates this spec and is
  read as if `as-of` equals the person file's `last-touch` field.

## `## Resolved`

An optional `H2` section, positioned between `## Open threads` and
`## Personal details`. Bullets:

```
- <text> (resolved YYYY-MM-DD)
```

A resolved thread is dropped from `## Open threads` entirely — it never
lives in both sections at once.

## Stale facts

A fact bullet gains a `[stale]` marker immediately after its provenance tag:

```
- **[<tag>]** [stale] <text>
```

Only `inferred-*` provenance facts may ever be machine-marked stale. A
`told-by-user` fact is never touched by any derived writer — no `[stale]`
marker, no rewrite, no removal — regardless of how old it is; only the user
themselves (via a `stale-marked` feedback event, never machinery) can mark
their own stated fact stale.

## Latest-interaction-wins

When an interaction dated `D` is filed for person slug `S` (via
`file-thread.sh`, `skills/debrief/`, or any other interaction writer for
that slug):

1. Every open thread on `S` with `as-of < D` that is **not** listed in the
   filed interaction/thread summary's `resolved_threads[]` gets demoted to
   `unverified since D` — idempotent: if the bullet already carries an
   `unverified since <earlier-date>` marker, that earlier date is kept
   (the marker records the *first* time the thread went unverified, not the
   most recent filing that skipped it again).
2. Every open thread listed verbatim in `resolved_threads[]` moves out of
   `## Open threads` and into `## Resolved` as `- <text> (resolved D)`.

A thread with a fresh `as-of` (>= `D`, e.g. one the same filing pass just
added) is untouched by rule 1.

## Writers

- **`file-thread.sh`** — applies latest-interaction-wins on every thread it
  files, using the `thread-summary` output's `resolved_threads[]` (see
  `specs/thread-summary.md` 1.1.0).
- **`refresh-person.sh`** — a one-shot, hermetic model call that re-derives
  every `inferred-*` fact plus the open/resolved bullet set from a person's
  full interaction timeline. `told-by-user` facts and bullets are read as
  fixed context, never rewritten by this pass.

## Consumers

`who-next-direct.sh`, `derive-evidence.sh`, and brief rendering all treat an
`unverified since D'` thread the same way: if `D' < ` the person's
**second-most-recent** interaction date (i.e. the thread went unverified
before the *previous* touch, not just the latest one), the thread is either
shown under a "possibly stale" grouping or omitted outright, rather than
presented as current. A thread demoted only as of the person's latest
interaction (the just-filed one) still ranks as freshly-uncertain and may
still surface normally.

## User corrections

The feedback-event type `stale-marked` (`packages/core/contracts/
feedback-event.md` 1.2.0) is written only by user-facing flows (a reply, a
session correction) — never by `file-thread.sh`, `refresh-person.sh`, or
any other machinery. Machine-derived `unverified since` demotion is a
read-time/file-time bookkeeping rule, not a feedback event; it never asks
the user anything and never gets logged as if the user had spoken.

## Out of scope

- The prompt/model contract for `refresh-person.sh`'s re-derivation call —
  a separate unit.
- Any UI/rendering decision beyond the binary "possibly stale or omit"
  consumer rule above.

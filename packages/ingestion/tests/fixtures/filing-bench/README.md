# Filing-bench fixture corpus (plan-27 U5)

24 synthetic capture-event 1.2.0 files (`bench-01.md` … `bench-24.md`),
shaped like the live inbox mix (email / calendar-event / chat-message),
plus the committed golden `expected-shards.tsv`. All names, emails, and
message content are invented (`example.com`/`example.co`/`example.org`/
`example.net` domains) — nothing here resembles the real store. Format
mirrors the committed triage fixtures
(`packages/ingestion/tests/fixtures/triage/store/inbox/*.md`) — frontmatter
shape follows `golden-known-email.md`, `golden-multi-attendee.md`, and
`golden-beeper-chat.md` in that directory.

## Corpus shape

- **Mixed types:** 8 email, 8 calendar-event, 8 chat-message events.
- **≥6 person-disjoint hint components.** 17 disjoint person components
  (`c1`–`c17`) plus one `leftover` bucket for the zero-hint event — well
  over the required minimum of 6.
- **One ambiguous-hint pair (`c6`, 3 events: `bench-08`, `bench-09`,
  `bench-10`).** `bench-08`'s hint is `Alex Kim <alex.kim@example.co>` and
  `bench-09`'s hint is `Alex Kim <alex.kim@example.org>` — two distinct
  synthetic people, who standing alone would be person-disjoint (different
  emails). `bench-10`'s hint is the bare name `Alex Kim`, which cannot be
  disambiguated between those two email-qualified hints. Per D1's
  ambiguity-merge rule, an unresolvable bare-name hint that could match
  either candidate forces **both candidates' components to merge** rather
  than guessing — so all three events land in one component, `c6`, in the
  golden.
- **New-person pair sharing one hint (`c5`, 2 events: `bench-06`,
  `bench-07`).** Both carry the identical unresolved hint
  `j.rivera@example.net` — an email address with no existing person
  record — so they resolve to the same new-person component by
  construction, not by ambiguity resolution. (`c7`, `bench-11`/`bench-12`,
  is the same pattern with `morgan.lee@example.net`, included as a second
  instance of the same-new-person-hint shape.)
- **Exactly one zero-hint event.** `bench-13` (a group-chat broadcast
  message) carries no `participant-hints` key at all — no participant
  resolves, so it has nowhere to shard to and is labeled `leftover` in the
  golden rather than any `cN`.
- **One multi-day chat-message (episode-split exercise).** `bench-05`
  (Sofia Alvarez) is a single capture event whose `messages[]` genuinely
  span three distinct UTC calendar days (2026-08-03, 2026-08-04,
  2026-08-05), exercising the debrief skill's §5b-episodes rule (one
  interaction file per active day) while remaining **one** capture event
  and **one** shard-component (`c4`) for sharding purposes — episode
  splitting is a filing-time behavior downstream of sharding, not a
  sharding-time split.

## `expected-shards.tsv`

One line per id, tab-separated: `<id>\t<component-label>`. Labels are
`c1`..`c17` (deterministic, assigned in order of each component's first
appearance across `bench-01`..`bench-24`) plus `leftover` for the one
zero-hint event. All 24 ids are covered exactly once.

**What must match vs. what may differ:** this golden is checked against
U6's script output at the level of **component grouping** — which ids land
in the same bucket as which other ids — not literal label spelling. U6/U7's
sharding script is free to re-derive its own shard numbering (e.g. assign
shards round-robin over components, or renumber components in a different
discovery order); what must match this golden is that every pair of ids
sharing a `cN` label here also end up co-located in whatever the script
produces, and every pair with different labels here end up in different
shards. `leftover`'s ids may be assigned to any shard (they have no
participant to collide over) but must never be silently dropped.

## Measurement protocol (binding target)

File this same 24-event corpus into a scratch store **twice**, with
identical event content both runs (fresh scratch store each time — no
carryover state, no dedup-ledger skipping the second run's events):

1. **Serial run:** plain batch mode, one session, processing all 24 events
   in a single sequential pass through the debrief filing skill.
2. **Sharded run:** the same 24 events split into a 4-shard wave per
   `expected-shards.tsv`'s component grouping (component-disjoint shards,
   so no two shards ever write the same `people/<slug>.md`), filed
   concurrently.

Wall-clock each run with `date +%s` immediately before and after the run
(serial: around the single pass; sharded: around the full wave, i.e. from
launch of the first shard to completion of the last).

**Binding target:** the sharded wave's wall-clock time is **≤ 0.6×** the
serial run's wall-clock time at 4 shards, with **zero cross-worker
person-file conflicts** (no two shards ever write to the same
`people/<slug>.md` in the same wave — guaranteed here by construction,
since every `cN` component is person-disjoint from every other and the
ambiguous pair (`c6`) and the two new-person-pair components (`c5`, `c7`)
are each kept whole inside a single component/shard rather than split
across shards).

## Frontmatter sanity spot-check

Every fixture was checked against the same frontmatter shape the triage
suite's fixtures use — required keys present, `id` matches the filename
stem, `type` is one of `email` / `calendar-event` / `chat-message`. Example
spot-check (`awk`, no `jq` dependency needed for a flat YAML frontmatter
block):

```sh
$ awk '/^---$/{n++} n==1 && /^(schema_version|id|source|captured_at|type):/' \
    packages/ingestion/tests/fixtures/filing-bench/bench-08.md
schema_version: 1.2.0
id: bench-08
source: calendar-in/calendar
captured_at: 2026-08-07T09:00:00Z
type: calendar-event
```

`id: bench-08` matches the filename stem `bench-08.md`, as required by the
capture-event 1.2.0 contract (`packages/core/contracts/capture-event.md`).

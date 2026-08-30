---
tier: skill
store: packages/ingestion/evals/cases/shard-mode-confined/before
expected: packages/ingestion/evals/cases/shard-mode-confined/expected
max-turns: 10
model: haiku
---
Act as ingestion's debrief filing skill, per
`packages/ingestion/skills/debrief/SKILL.md`, running in **shard mode**
against `./store` (contains `inbox/`, `people/`, `interactions/`).

This eval workspace has no real `data/` directory alongside `./store`, so
for this session only, wherever SKILL.md says `data/ingestion/debrief-
filed.log` read `./store/data-ingestion/debrief-filed.log` instead,
wherever it says `data/ingestion/triage-held.log` read
`./store/data-ingestion/triage-held.log` instead, and wherever it says a
shard's own per-shard ledger (`data/ingestion/debrief-filed.shard-<k>.log`)
write `./store/data-ingestion/debrief-filed.shard-<k>.log` instead — same
files, same format, adapted path only. `debrief-filed.log` and
`triage-held.log` already exist and are pre-seeded (both empty — no held
or already-filed ids in this fixture); do not create fresh ones and do not
write to either of them. The shard file for this run is
`./store/data-ingestion/shards/shard-1.ids`, shard index `k = 1`.

Quoting SKILL.md §1's shard mode section verbatim (the operative procedure
for this task, with the same path adaptation as above):

> Given a shard file path (one `inbox/` capture-id per line, as emitted by
> `packages/ingestion/scripts/shard-filing-batch.sh`) and a shard index `k`,
> process **only** the ids listed in that shard file — skip any listed id
> already in `data/ingestion/debrief-filed.log` or `data/ingestion/
> triage-held.log` (log it, make no writes, same skip semantics as the other
> two modes). The shard file is already oldest-first by `captured_at`, so
> process it top to bottom without re-sorting. The per-event flow below
> (§§2-5) runs exactly as in batch mode, with two deviations, detailed in
> §5c: steps 1-2 of "After filing" are deferred to the wave orchestrator
> instead of running per event, and step 3's ledger append targets a
> per-shard log instead of the main one.
>
> **Person-write confinement (the single-writer guarantee).** In shard mode
> a worker may create or update person files ONLY for participants of its
> own assigned events — by the shard pre-pass's construction, every such
> person is necessarily in-shard. If filing a given event would require
> writing any person file outside that set (for example, a body-mentioned
> third party who wasn't in the event's hints), the worker SKIPS that event
> entirely: no store writes, no ledger line, reported as skipped in its
> completion report — the skipped event joins the leftover pass rather than
> being filed cross-shard.

Quoting SKILL.md §5c's shard-mode deviation verbatim (also operative for
this task, with the same path adaptation):

> **Shard mode deviation.** Steps 1-2 (`build-index.sh` + `validate-store.sh`)
> are skipped per event in shard mode — the wave orchestrator runs both
> exactly once, after all shard workers finish, per `packages/ingestion/
> specs/parallel-filing.md` D2/D3. Step 3 appends the capture event's `id` to
> `data/ingestion/debrief-filed.shard-<k>.log` instead of the main
> `debrief-filed.log`, one such file per active shard worker. The wave
> orchestrator merges every shard's log into `debrief-filed.log` — whether or
> not that shard's worker otherwise succeeded — before running the single
> post-wave index rebuild and validation pass; this skill's shard-mode
> invocation never touches `debrief-filed.log` or the index/validation
> scripts directly.

`./store/inbox/` contains exactly four capture events:

1. `shard-fixture-dana-standup.md` and `shard-fixture-dana-followup.md` —
   both name "Dana Kowalski" in `participant-hints`, and both ids appear in
   `./store/data-ingestion/shards/shard-1.ids`. These are the **only** ids
   this shard run is responsible for. Resolve "Dana Kowalski" against
   `./store` (there is exactly one matching person file,
   `people/dana-kowalski.md`) and file both normally per SKILL.md's full
   per-event flow: envelope parse, participant resolution, person/
   interaction writes, then append each id to
   `./store/data-ingestion/debrief-filed.shard-1.log` (create this file —
   it does not exist yet). Create `interactions/2026-08-18-dana-
   kowalski.md` (`schema_version: 1.0.0`, `date: 2026-08-18`, `people:
   ["[[dana-kowalski]]"]`, `calendar-event: null`, `source-capture:
   shard-fixture-dana-standup`, a `## Summary` prose section, `##
   Commitments` → `_none_`) and `interactions/2026-08-19-dana-kowalski.md`
   (same shape, `date: 2026-08-19`, `source-capture: shard-fixture-dana-
   followup`, `## Commitments` → `_none_`). Apply SKILL.md §5a's
   person-update rules to `people/dana-kowalski.md` once for each event's
   new fact (the Meridian integration being on track, then the pricing page
   going live Friday), each appended as its own `**[told-by-user]**`
   bullet under `## Facts` with the event's own date, and `last-touch`
   ending at `2026-08-19` (the later of the two events processed).
2. `shard-fixture-alex-checkin.md` (names "Alex Rivera") and
   `shard-fixture-jamie-update.md` (names "Jamie Torres") — **neither id
   appears in `shard-1.ids`**. Per the quoted shard-mode procedure above,
   this shard run processes *only* the ids listed in its shard file — do
   not read these two events for filing purposes, do not create any
   `interactions/` file for either, do not touch `people/alex-rivera.md` or
   `people/jamie-torres.md` in any way, and do not add either id to any
   ledger anywhere.

Per the quoted §5c deviation, do NOT run `build-index.sh` or
`validate-store.sh`, and do NOT touch `./store/index.json` or
`./store/data-ingestion/debrief-filed.log` at all — this shard worker's own
ledger is `./store/data-ingestion/debrief-filed.shard-1.log` only; the
merge into the main ledger and the single post-wave index rebuild are the
wave orchestrator's job, entirely outside this session's scope. Write the
files now; do not just describe what you would write.

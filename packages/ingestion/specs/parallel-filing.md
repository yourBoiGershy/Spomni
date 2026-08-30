# Spec: parallel filing

Status: spec (plan 27 unit 3). Package: `packages/ingestion` (the shard
pre-pass and the shard-mode ledger writes, per the single-writer rule),
consumed by `packages/ingestion/scripts/shard-filing-batch.sh` (built in a
later unit) and by the debrief skill's shard mode
(`packages/ingestion/skills/debrief/SKILL.md` §1, amended in a later unit).
This spec defines *how* a filing batch is partitioned into person-disjoint
shards and *how* a wave of parallel debrief workers files them safely — it
does not implement the pre-pass script or the skill amendment itself.

Stage naming below follows `packages/core/contracts/import-pipeline.md`'s
five stages (fetch → normalize → triage → judgment → file): this spec
details the **parallel execution of the `file` stage** (a sharded `judgment`
+ `file` wave, more precisely — each shard worker both judges and files its
assigned events, per the debrief skill's existing per-event flow). "Triage"
and "judgment" below refer to those stages exactly as `import-pipeline.md`
defines them; the pre-pass this spec adds runs after triage and before
judgment, over triage's output.

## Problem

Chunk 26's pipeline makes everything before judgment deterministic and
parallel-safe, and `file`-stage writes shard cleanly by person — no two
people's store files are ever touched by the same judgment call. But nothing
yet exploits that: a filing batch is judged serially, one event at a time, in
a single model session. This spec adds a deterministic pre-pass that
partitions an eligible batch into person-disjoint shards, so multiple debrief
sessions can judge and file in parallel with a machine-checkable guarantee
that no two of them ever write the same person file.

## D1 — Shard pre-pass

A new deterministic script, `packages/ingestion/scripts/shard-filing-batch.sh`
(bash 3.2 + jq, no model in the loop). Args: `<store-dir> [--data-dir <dir>]
[--max-shards <n>] [--out-dir <dir>]`.

The pre-pass is **deterministic (byte-stable on the same input) and
read-only on the store** — it writes nothing outside `--out-dir`, and running
it twice against an unchanged store + ledgers produces byte-identical
artifacts.

Behavior:

1. **Eligible set** = inbox events (never `inbox/quarantine/`) whose id is in
   neither `debrief-filed.log` nor `triage-held.log` — the exact batch-mode
   selection debrief SKILL.md §1 already uses.
2. **Hint → key prediction**, per event, from `participant-hints`: an email
   hint gets a case-insensitive contact-details lookup in `index.json` (the
   same deterministic store lookup triage's `sender_known` uses) → matched
   person slug(s); a name hint gets an index name/aka match → matched
   slug(s); a hint with no index match at all → a synthetic key
   `new:<normalized-hint>` (lowercase, trimmed; email form preferred when the
   hint contains one, so two differently-cased or differently-formatted
   spellings of the same new contact still collide on one key).
3. **Ambiguity is merged, never guessed.** A hint matching multiple people
   contributes ALL matched slugs as keys for that event — those people's
   components merge into one shard. Conservative by construction: whichever
   person the model later picks for that event, the write stays in-shard.
4. **Connected components.** Events sharing any key land in the same
   component — union-find over events-and-keys, implemented in awk.
   Deterministic and byte-stable on the same input.
5. **Zero-hint events are excluded from the wave.** An event with no
   `participant-hints` at all could touch any person, so no key set can
   bound it; it is emitted to `<out-dir>/leftover.ids` instead of being
   assigned to any shard.
6. **Clamp + packing.** If the number of components exceeds `--max-shards`,
   components are deterministically bin-packed: sorted by event count
   descending, then assigned round-robin into shards. `--max-shards` default
   is **8**, hard cap **12** — the mutating-worker concurrency cap is 15
   (`.claude/rules/orchestration.md`), and 12 leaves headroom reserved for
   the orchestrator's other concurrent workers rather than consuming the
   entire cap on one wave.
7. **Artifacts**, all under `--out-dir`:
   - `<out-dir>/shard-<k>.ids` — one capture-id per line, oldest-first by
     `captured_at`, ties broken by filename (batch mode's existing order),
     one file per shard, `k` starting at 1.
   - `<out-dir>/leftover.ids` — the zero-hint events, same ordering.
   - A mandatory summary line to stdout, every terminal state covered
     (including eligible=0), silence impossible:
     ```
     shard: eligible=<n> components=<c> shards=<s> leftover=<z>
     ```

## D2 — Debrief shard mode

The debrief skill (`packages/ingestion/skills/debrief/SKILL.md` §1) gains a
third invocation mode alongside single-event and batch: given a shard file
path and a shard index `k`, process ONLY the ids listed in that shard file,
oldest-first. The per-event judgment/filing flow is otherwise unchanged from
batch mode, with three deviations:

- **§5c deferred.** Steps 1–2 of §5c (`build-index.sh` +
  `validate-store.sh`) are skipped after each event in shard mode; the wave
  orchestrator runs both exactly once, after all shard workers finish.
  Rationale: within one shard, any people who co-occur are handled inside the
  same worker session, so the session already remembers people it just
  created — index staleness inside a shard is harmless. Across shards,
  person sets are disjoint by D1's construction, so no shard worker needs
  another shard's index updates mid-run. Single-event and plain batch mode
  are unaffected — §5c's per-event rebuild stays the rule outside shard
  mode.
- **Per-shard ledger.** §5c's step 3 (the filed-ledger append) writes to
  `data/ingestion/debrief-filed.shard-<k>.log` instead of the main
  `debrief-filed.log`, one such file per active shard worker. This is chosen
  over N workers interleaving appends into one shared file: `debrief-filed.log`
  is order-insensitive (every reader does a membership check, never relies on
  order), so an end-of-wave merge is semantically identical to interleaved
  appends, is auditable per worker, and removes any doubt about concurrent
  writers racing on one file. The orchestrator merges shard ledgers into
  `debrief-filed.log` (`cat` each shard log onto the end, then remove the
  shard log files) **before** the index rebuild, and **before any re-run —
  even after a failed worker** — so a crash never causes an event to be
  re-filed on retry.
- **Person-write confinement (the single-writer guarantee).** In shard mode
  a worker may create or update person files ONLY for participants of its
  own assigned events — by D1's construction, every such person is
  necessarily in-shard. If filing a given event would require writing any
  person file outside that set (for example, a body-mentioned third party
  who wasn't in the event's hints), the worker SKIPS that event entirely: no
  store writes, no ledger line, reported as skipped in its completion
  report — and the skipped event joins the leftover pass (D3) rather than
  being filed cross-shard. **Residual risk, accepted:** two shards could in
  principle each invent the same new person under two differently-spelled
  hints that D1's normalization didn't collide (e.g. a nickname D1 couldn't
  resolve to the same `new:<...>` key as a full name in another shard). D1's
  hint normalization and ambiguity-merge minimize this, and the post-wave
  `validate-store.sh` run plus orchestrator slug review are the backstop
  that catches what's left — this spec accepts that residual risk rather
  than engineering it to zero, since eliminating it entirely would require
  cross-shard coordination that defeats the point of sharding.

Single-event and plain batch modes are byte-unchanged apart from the mode
list gaining shard mode as a third entry.

## D3 — Wave protocol

The wave is orchestration doctrine — a sequence of steps a lead agent
performs by spawning and coordinating model workers — not a wrapper script.
Full protocol, end to end:

1. Run `triage-inbox.sh` against the store (marks junk `held-by-rule`,
   per `import-triage.md`).
2. Run `shard-filing-batch.sh` against the store (D1) — produces
   `shard-<k>.ids` (one per shard) and `leftover.ids`, plus the summary
   line.
3. Spawn at most `--max-shards` debrief-skill workers in shard mode, **all
   in one parallel message** (mutating-tier concurrency rules apply — see
   `.claude/rules/orchestration.md`), one worker per `shard-<k>.ids` file,
   each passed its shard file path and shard index `k`.
4. Collect each worker's completion report (filed ids, skipped ids, any
   failure).
5. Merge per-shard ledgers into `debrief-filed.log` (D2) — every shard's
   `debrief-filed.shard-<k>.log` is merged, whether or not that shard's
   worker otherwise succeeded (see failure handling below).
6. Run `build-index.sh` once, over the merged state.
7. Run `validate-store.sh` once.
8. Run a serial leftover pass — a normal (non-sharded) debrief session over
   `leftover.ids` plus any ids individual shard workers reported as
   skipped — batch-ish, single session, single-writer by default (no
   sharding needed at this reduced scale).
9. Done — the wave orchestrator's own completion report records the D1
   summary line, per-worker filed/skipped counts, and the leftover pass's
   result.

**Failure handling.** If a shard worker fails partway (crashes, times out,
errors out of its session), its **filed** events are still merged from its
shard ledger in step 5 — whatever it successfully filed and logged before
failing is not lost or re-processed. Its **unfiled** ids (the ones it never
reached, or reached but didn't log) simply remain eligible: neither filed
nor held, which is "pending" per `import-pipeline.md`'s definition — they
fall out naturally into a future eligible set (either a re-run of the wave,
or the leftover pass, at the orchestrator's discretion) rather than needing
any special-cased recovery step. Per the harness's fix-policy doctrine, a
failing shard gets at most 2 fix-dispatch rounds before the orchestrator
escalates rather than looping.

## Single-writer rule (restated for this spec)

- `index.json` is rebuilt by **exactly one actor**: the wave orchestrator,
  once, in step 6 above — never by an individual shard worker.
- Each person file (`people/<slug>.md`) is written by **exactly one** shard
  worker per wave, guaranteed by D1's construction (person-disjoint
  components) plus D2's person-write confinement rule (a worker that would
  need to write outside its assigned people skips the event instead).
- `debrief-filed.log` itself is written only by the orchestrator's merge
  step (step 5); shard workers write only their own
  `debrief-filed.shard-<k>.log`, never the main log directly.

## Out of scope

- The `shard-filing-batch.sh` pre-pass script's implementation (argument
  parsing, the awk union-find, jq specifics) — a later plan-27 unit.
- The debrief skill's shard-mode wiring (`SKILL.md` §1/§5c amendments) and
  `package.md` provides rows — a later plan-27 unit.
- Sync-scheduler wiring of the wave (invoking it automatically rather than
  manually or from the onboarding flow) — chunk 28.
- Judgment-quality or tier-calibration changes — chunk 30. Shard mode
  changes *which events a session sees and when the index rebuilds*, never
  *how* an event is judged; no triage or judgment heuristic changes here.
- Retroactive re-filing of the live store using this protocol — the live
  store's baseline is not rewritten by this spec; benchmarking uses a
  synthetic bench corpus in a scratch store (plan 27 D6).

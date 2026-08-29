# Plan 01: Contracts & store

Status: Ready
Depends-on: nothing — this is Wave 1 and unblocks every other plan

## Objective

Freeze the six data contracts, ship the person/interaction/wake-up templates, the index
generator, the store validator, and a synthetic fixture pack. After this plan, every other
chunk can build and test against fixtures instead of waiting on each other.

## Context

Read docs/PROJECT-CONTEXT.md first. Decisions that bind this plan:
- **code-data-separation** — everything here describes the *shape* of the private store;
  fixtures are synthetic people only, committed under `tests/fixtures/`.
- **markdown-store-plus-index** — no DB, no embeddings; frontmatter + prose + index.json.
- **provenance-labeling** — the person template carries told-by-user vs. inferred markers.
- **wakeup-queue-over-digests** — wakeup.md is a first-class contract, not an afterthought.

## Deliverables

- `docs/contracts/capture-event.md` — id, source connector, captured_at, type
  (voice-note | linkedin-notification | event-confirmation | transcript | other),
  participant hints; body = raw text, untouched.
- `docs/contracts/person.md` — frontmatter: name, org, role, location, tags, birthday,
  how-met, last-touch, tier; body sections: Facts (provenance-labeled), Open threads,
  Personal details.
- `docs/contracts/interaction.md` — date, people links, calendar-event link, source
  capture event, summary, extracted commitments.
- `docs/contracts/signal-event.md` — type, person, evidence, confidence, detected_at.
- `docs/contracts/wakeup.md` — due date, person(s), why, context, optional draft,
  status (pending | fired | snoozed | dismissed), origin (user-ask | signal | standing).
- `docs/contracts/connector-interface.md` — input obligation (valid capture events into
  inbox/) and output obligation (rendered content + destination config).
- `templates/person.md`, `templates/interaction.md`, `templates/wakeup.md` — fill-in
  versions matching the contracts.
- `.claude/scripts/build-index.sh` — walks people/, emits index.json (person → tags, org,
  location, last-touch). Bash 3.2 portable; jq assumed.
- `.claude/scripts/validate-store.sh` — schema check, broken [[links]], orphan
  interactions, malformed frontmatter; exit 0 clean / 1 findings with file:line output.
- `tests/fixtures/store/` — ~15 synthetic personas with histories: varied tags/orgs,
  some birthdays, linked interactions, a couple of pending wake-ups, deliberate diversity
  (multi-person interactions, a person with no org, a stale last-touch).
- `tests/fixtures/corrupted/` — 5 seeded corruptions (broken link, bad frontmatter,
  orphan interaction, duplicate person slug, invalid wake-up status).

## Work units

Wave A (parallel, one message):
1. [worker] Write the six contract docs in `docs/contracts/` (they are documentation —
   one worker, they must be mutually consistent).
2. [worker] Write the three templates in `templates/` from the plan's field lists
   (coordinate: unit 1's drafts win on any conflict; run after unit 1 lands if briefs
   can't share a wave cleanly).

Wave B (parallel, one message):
3. [worker] `build-index.sh` implementation.
4. [worker] `validate-store.sh` implementation.
5. [worker] Fixture pack: the 15 personas + interactions + wake-ups.
6. [worker] Corrupted fixture set + a `tests/run-store-tests.sh` that runs the validator
   against both fixture dirs and asserts clean/dirty outcomes.

Wave C:
7. [checker] Consistency pass: contracts vs. templates vs. fixtures vs. validator all
   agree on field names and formats; report mismatches with file:line.
8. [worker] Fix pass from unit 7's findings (skip if clean).

## Interfaces

Consumes: nothing.
Produces: the six contracts (every later plan), templates (03), index.json format (07
query skill), validator + fixtures (every later plan's tests).

## Proof of done

- `validate-store.sh` exits 0 on `tests/fixtures/store/` and reports all 5 seeded
  corruptions on `tests/fixtures/corrupted/` with file:line.
- `build-index.sh` on fixtures produces an index.json from which "who do I know in
  fintech in NYC?" is answerable correctly (manual session check against the known
  personas).
- `tests/run-store-tests.sh` passes.

## Out of scope

- Any skill behavior (filing, querying) — plans 03/07.
- Real Gmail/calendar wiring — plans 02/04.
- Embeddings, DB, index beyond the flat JSON.

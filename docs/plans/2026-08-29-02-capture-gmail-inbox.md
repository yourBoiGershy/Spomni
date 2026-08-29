# Plan 02: Capture — Gmail lane & inbox
Status: Ready
Depends-on: 01 only

## Objective
Stand up the capture pipeline: a normalized `inbox/` in the private data dir that any input connector feeds, with the Gmail lane as the first working connector. Voice notes dictated on the phone, LinkedIn notification emails, and event-confirmation emails all arrive as typed capture events with zero manual filing steps.

## Context
Read docs/PROJECT-CONTEXT.md first. Decisions that bind this plan:
- **Gmail first capture lane** — the user's inbox is the universal signal feed; other connectors come later through the same interface.
- **First-party MCP only** — Gmail access via the user's Claude Gmail connector or Google's official Gmail MCP server; no third-party aggregators, no scraping.
- **Data/code separation** — `inbox/` lives in the private data dir, never this repo.
- **Capture optional and lossy-tolerant** — capture is fire-and-forget from the phone; the agent does all structuring later.

## Deliverables
- `data/` conventions doc: `inbox/`, `inbox/quarantine/`, `archive/raw/` layout (written to `docs/data-layout.md`, enacted in the user's private data dir)
- `.claude/scripts/normalize-capture.sh` — validates/normalizes a raw drop into a capture-event file
- `.claude/skills/capture-sweep/SKILL.md` — the Gmail pull: finds new subject-tagged self-emails + recognized notification emails, writes typed capture events
- Email type classifiers (prompt rules inside the skill): `voice-note`, `linkedin-notification`, `event-confirmation`, `unknown`
- `docs/dictation-jogger.md` — the 4-question memory jogger for phone dictation (+ suggested subject tag, e.g. `[ra]`)
- `templates/capture-event.md` usage examples (contract itself is Plan 01's)

## Work units
Wave A (parallel):
1. [worker] `docs/data-layout.md` + `docs/dictation-jogger.md` — data-dir conventions and the phone-side flow.
2. [worker] `.claude/scripts/normalize-capture.sh` — stdin/file → validated capture event; invalid input moved to `quarantine/` with a reason file; never deletes.
3. [worker] Test fixtures: 6 sample raw emails in `fixtures/capture/` — 2 dictated voice notes, 2 LinkedIn notification emails (job change, post), 1 Luma confirmation, 1 malformed junk.

Wave B (after A):
4. [worker] `.claude/skills/capture-sweep/SKILL.md` — Gmail query strategy (subject tag + known sender patterns), classification rules per email type, idempotency (processed-message ledger so re-runs don't duplicate), calls normalizer.
5. [worker] Tests for the normalizer against the fixture pack (valid → typed events with correct `source` and participant hints; malformed → quarantined).
6. [checker] Dry-run review: walk the six fixtures through the documented flow and verify each lands where the docs say it should; report mismatches.

## Interfaces
Consumes: `capture-event.md` contract, data-dir location config (Plan 01).
Produces: typed capture events in `inbox/` — `voice-note` events for Plan 03 (filing), `linkedin-notification` and `event-confirmation` events for Plan 05 (signals); the quarantine convention; the processed-message ledger.

## Proof of done
A Whisperflow-dictated email from the phone and a real LinkedIn notification email both land as valid, correctly-typed inbox events within one sweep; the malformed fixture is quarantined with a reason, never lost; running the sweep twice produces no duplicates.

## Out of scope
- WhatsApp/iMessage bridges (Tier 2, later; same connector interface)
- iOS Shortcut → GitHub lane (documented alternative, build later)
- Any parsing of LinkedIn beyond emails LinkedIn itself sends the user
- Filing the events into person files (Plan 03) or acting on signals (Plan 05)

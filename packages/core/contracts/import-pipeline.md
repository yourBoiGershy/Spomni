# Contract: import pipeline

`schema_version: 1.0.0`

## Scope

This contract governs the five-stage pipeline that turns an outside-world
item into filed store content: **fetch → normalize → triage → judgment →
file**. It exists because `connector-interface.md` deliberately stops at the
inbox boundary (its scope is `packages/connectors/*` only), while the import
pipeline spans three packages — connectors own fetch and normalize;
ingestion owns triage, judgment, and file. Cross-package stage doctrine gets
its own core contract, the same way `sync-lanes.md` owns the sync-scheduler's
cross-cutting config shape rather than living inside one package.

This contract does not restate `capture-event.md`'s schema (the normalize
stage's artifact) — see that contract for the inbox-event shape.

## The five stages

| Stage | Owner | Does | May transit model context | On-disk artifact (the boundary) |
|---|---|---|---|---|
| fetch | connectors `*-in` | Pull raw bytes from the source (in-session first-party MCP tools for gmail/calendar; localhost HTTP for beeper). Dumb: no interpretation, no filtering beyond fetch scope. | Tool/call metadata only — ids, dates, counts, page tokens, file paths. **Never item bodies.** | Raw provider payload on disk: the harness-saved MCP tool-result file (gmail/calendar) or the HTTP response bytes (beeper); archived verbatim per item at `<store>/archive/raw/<capture-id>.json`. |
| normalize | connectors `*-in` | `packages/connectors/scripts/normalize-capture.sh` — envelope-only; body verbatim from the saved file; invalid → `inbox/quarantine/` + reason file. Programmatic (bash/jq) from the fetch artifact. | Nothing new — runs as shell, not model prose. | `inbox/<id>.md` per `capture-event.md` 1.2.0 (append-only, raw kept forever). |
| triage | ingestion | Deterministic rule pass (bash/jq, no model) over unfiled inbox events; marks junk `held-by-rule`. Reversible; never deletes or edits inbox files. | Nothing — pure shell. | `data/ingestion/triage-held.log` (see below). |
| judgment | ingestion | The debrief skill's model pass — only over events neither filed nor held. Ambiguity questions, person/no-person calls. | The maybe-a-person events only (the point of triage). | `data/ingestion/debrief-filed.log` appends; unfiled-and-unheld = still pending. |
| file | ingestion | Store writes: `people/`, `interactions/`, wake-ups via core `wakeup-add.sh`, then `build-index.sh` + `validate-store.sh` (debrief SKILL.md §5c). | Filed content (already judged relevant). | `people/`, `interactions/`, `index.json`, `wakeups/`. |

## Hard rules

- **Single-writer per artifact.** Connectors write `inbox/` and
  `<store>/archive/raw/`; ingestion writes the held/filed ledgers and the
  store (`people/`, `interactions/`, `wakeups/`, `index.json`). Neither side
  writes into the other's artifacts.
- **Lane conformance is declared, not assumed.** Each connector lane states
  its conformance to the fetch/normalize stages in its own `package.md`
  (per-lane rules), not in this contract.
- **Fetch-stage hard rule: raw item bodies are never transcribed by the
  model.** Everything from the normalize stage onward is programmatic
  (bash/jq/scripts) until judgment, which is the first stage allowed to see
  filtered item content in model context — and even then, only the events
  triage passed through.

## Fetch-stage mechanism (session-driven MCP lanes)

For session-driven MCP lanes (gmail/calendar, first-party MCP only): request
maximum page sizes so tool results exceed the harness inline threshold and
land on disk as a saved tool-result file; the session then handles only the
file path — archive via `cp`, classify/extract/normalize via jq + scripts
reading the file.

Residual: a small final page may arrive inline instead of on disk. When that
happens, the session writes the tool result to a temp file in one verbatim,
uninterpreted paste (it never summarizes, classifies, or excerpts from
context) and proceeds identically to the disk path, counting
`inline-spilled=<n>` in the run summary. Byte fidelity is guaranteed on the
disk path, best-effort on the inline residual.

## Triage-stage artifact

`data/ingestion/triage-held.log` — append-only ledger, one line per held
event:

```
<capture-id>\t<rule-name>\t<held-at ISO 8601 Z>
```

- **Sole writer:** `packages/ingestion/scripts/triage-inbox.sh`.
- **Readers:** the debrief skill (batch mode excludes held ids) and humans.
- **Reversal:** an explicit single-event debrief invocation on a held id
  overrides the hold — no ledger surgery, inbox untouched.

The exact rule patterns (what gets held and why) live in ingestion's own
spec, not here: `packages/ingestion/specs/import-triage.md`.

## Notes

- This contract owns the cross-package stage boundaries and their on-disk
  artifacts; it does not own the debrief skill's judgment heuristics or the
  triage rule patterns — those are ingestion's own specs, cross-referenced
  above.
- Widening a stage's artifact shape (e.g. new fields in the triage ledger
  row) is a `schema_version` bump here; ingestion-internal rule tuning
  (which patterns trigger a hold) is not, since it doesn't change this
  contract's row format.

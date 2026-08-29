# Data layout

Canonical description of the user's private data dir. Every connector and
every later chunk agrees with this file; when a plan needs a new location, it
is added here first. Nothing described below is committed to this repo — see
`data/README.md` and the `code-data-separation` decision.

## `data/` root

`data/` is gitignored in its entirety (except `data/README.md`). Point it at
your own private store — a private git repo cloned in, or a symlink to one:

```sh
git clone git@github.com:<you>/<your-private-people-store>.git data/store
```

Two top-level things live under `data/`:

```
data/
├── store/        # the shared people store — see below
└── connectors/    # per-connector runtime state — see "Connector runtime state"
```

`data/store` is typically its own private repo/symlink; `data/connectors` is
plain local state (not required to be versioned, and never shared).

## `data/store/` layout

| Path | Writer | Reader |
|---|---|---|
| `inbox/` | connectors, input side (`packages/connectors/*-in`) — sole writer, per `connector-interface.md` | ingestion (filing engine) |
| `inbox/quarantine/` | `packages/connectors/scripts/normalize-capture.sh` (any input connector routing through it) | human review; nothing automated reads it back in |
| `archive/raw/` | connectors, input side, alongside the normalizer | ingestion, for provenance lookups back to the raw source |
| `people/` | ingestion (filing engine) — sole writer | query, attention |
| `interactions/` | ingestion (filing engine) — sole writer | query, attention |
| `wakeups/` | attention — creation open to all via core's `wakeup-add.sh`, lifecycle (fire/snooze/dismiss) owned by attention | query, connectors (output side) |
| `index.json` | ingestion — auto-generated | query, attention |

`inbox/` holds one file per capture event, `inbox/<id>.md`, conforming to
`packages/core/contracts/capture-event.md`. Files are never edited after
creation — the inbox is an append-only archive; raw text is kept forever per
the capture-is-lossy-tolerant principle.

## Quarantine convention

Invalid input handed to `packages/connectors/scripts/normalize-capture.sh`
(malformed frontmatter, missing required fields, unparseable raw drop) is
never dropped and never deleted. It is moved to `inbox/quarantine/` under its
original stem, alongside a sibling reason file:

```
inbox/quarantine/<same-stem>.md
inbox/quarantine/<same-stem>.reason.txt
```

`<same-stem>.reason.txt` is a short plain-text explanation of why the item
failed normalization (e.g. which required field was missing or malformed).
Quarantined items are for human review only — no automated flow reads them
back into `inbox/`.

## `archive/raw/`

Alongside quarantine, input connectors keep the raw, unmodified source
material (the original email, transcript, or payload a capture event was
derived from) in `archive/raw/`, forever. This is the provenance trail behind
a capture event's envelope-only normalization — the capture event's body is
verbatim, but `archive/raw/` is where the original untouched artifact lives
if the source format itself needed any transformation to become the capture
event's body.

## Connector runtime state

Per-connector checkpoints and dedup ledgers (e.g. "last Gmail message ID
processed", "last calendar sync token") live in:

```
data/connectors/<connector-name>/
```

This is inside the private data dir but **outside** `data/store/` — per
`connector-interface.md`'s rule that a connector dedups "on the source's own
stable ID... stored in the capture event's `id` derivation or tracked in the
connector's own local checkpoint — never in the shared store." Ledgers here
are connector-local: no other package reads or writes them, and they are not
part of the shared store's single-writer table above.

Example:

```
data/connectors/
├── gmail-in/          # processed-message ledger
├── calendar-in/       # sync-token / last-seen-event-id ledger
└── linkedin-in/       # last-seen-post / snapshot ledger
```

## Note on privacy and versioning

`data/` (both `store/` and `connectors/`) is gitignored in this repo. The
store is typically its own private repo or a symlink to one, per
`code-data-separation`: this repo is machinery only, and a user's contact
graph — other people's PII — never enters it, any third-party cloud, or any
aggregator.

# packages/core/templates/

Assistant file templates — `person.md`, `interaction.md`, `wakeup.md` — land here with
Plan 01 (contracts & store). Fill-in versions of the contracts in
`packages/core/contracts/`. Protected machinery: edits go through dev-workers, not the
main conversation (see CLAUDE.md). `sync-lanes.tsv` (plan 19) is a commented
config template rather than a store-artifact fill-in, but follows the same
contract-pairing convention.

Optional enum fields (e.g. `person.md`'s `tier`) are omitted from the fill-in
templates entirely rather than left as a blank placeholder key — `validate-store.sh`
enforces enum values only when the key is present, so an empty value fails
validation while an absent key is valid "unset".

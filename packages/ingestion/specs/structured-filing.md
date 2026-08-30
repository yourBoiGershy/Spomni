# Spec: structured filing

Status: spec (plan 31 unit 1). Package: `packages/ingestion` (the person/
interaction writes, per the single-writer rule), implemented by
`packages/ingestion/scripts/file-structured.sh`. This spec is the model of
record for what gets filed deterministically, what gets held, and the exact
shapes written — the mission test (D1 of plan 31): filing calendar and
metadata-only email is bookkeeping, not judgment, so a shell script does it
instead of a model call, with zero invented provenance.

## Problem

Every `calendar-event` and short `email` capture event currently costs a
full model judgment call at debrief time even though its person/interaction
resolution is mechanical: the hints are `"Name <email>"`/bare email/bare
name, resolution is exact email/name match against `people/` +
`index.json`, and the interaction body is a fixed retelling of fields
already in the capture event. This spec adds a deterministic pre-debrief
filing pass for that narrow, judgment-free slice; free text (chat episodes,
debrief notes, long emails) stays the model path's job.

## Eligibility

An inbox event is eligible when `type: calendar-event`, or `source` starts
with `gmail-in/` and the body — after dropping a single leading
`Subject: ...` line (never a later one) — has fewer than 40 words. Every
other event is left for the model path, uncounted here. Ids already present
in `debrief-filed.log`, `triage-held.log`, or `structured-held.log` are
skipped before the eligibility check even runs (one `grep -vxF -f` pass
over the union, never a per-event grep).

## Self + ignore exclusion

Self identities come from `<data-dir>/config/onboarding-backfill.tsv`
`self<TAB><identity>` rows (the same file `derive-participation.sh` reads;
absent file means no self exclusion, never a hard failure). `ignore<TAB>
<identity>` rows, same file, same shape, are dropped identically — for
bot/noreply senders (e.g. `ask@bramble.solutions`) that aren't the user
but should never become a person either. A hint whose email or normalized
bare-name text matches a configured self OR ignore identity is dropped
before resolution. An event left with zero non-self/non-ignore hints is
skipped — nothing is written, and it is not held (there is nothing to hold
judgment on).

## Resolution

Per surviving hint, in the order the hints appear in `participant-hints`,
first blocking condition wins (mirrors `import-triage.md`'s first-match
doctrine):

0. **Calendar body name backfill** (calendar-event only, before any
   matching): a bare-email hint with no display name of its own borrows
   one from the calendar body's `attendees[]`/`organizer`/`creator`
   (matched by email, one `jq` call per event, done once before hint
   resolution starts) — a bare-email hint only ever falls through to a
   hold if NEITHER the hint NOR the calendar body names that person.
1. **Email exact match** against the identity map (email addresses found in
   `people/*.md` bodies + `index.json` values + the learned identity map,
   below) resolves to that slug.
2. Else **name exact-normalized match** (case/space-collapsed) resolves to
   a slug if there is exactly one; **two or more matches holds the whole
   event** — `structured-held.log` gets `<id>\tambiguous-name:<name>\t<ts>`.
3. Else, no match at all: if the hint carries a display name (the
   `"Name <email>"` form, or a bare-name hint, or a calendar-body-backfilled
   name from step 0) — **or**, for an email with no name anywhere, its
   local-part is a plausible name (see "Name from email local-part",
   below) — a **new person is created** from that name. Even a
   local-part-derived name is checked against the identity map first (step
   2): a derived "Aaron" must resolve to an existing `aaron.md`, never
   shadow it with a second person file. Only when NEITHER a name nor a
   derivable local-part exists is the whole event held —
   `<id>\tno-name:<email>\t<ts>`.

### Name from email local-part

An email with no name anywhere and no identity-map match gets one more
chance before holding: if its local-part (before the `@`) matches
`^([a-z]{3,}|[a-z]{2,}([._-][a-z]{2,}){1,2})$` — EITHER a single
letters-only token of at least 3 letters, OR 2 or 3 letters-only
dot/underscore/hyphen-separated tokens each at least 2 letters — each
token is title-cased and joined with spaces (`"thomas.wright"` →
`"Thomas Wright"`, `"patrick"` → `"Patrick"`) to make a provisional name.
A too-short single token (`"jo"`, `"a"`), a 1-letter token inside a
multi-token split (`"a.bhandhoal"`), digits, or any other shape (role
addresses, ticket ids) print nothing and the event holds as
`no-name:<email>` instead. A person created this way carries `tags:
[name-from-email]` so it reads as visibly provisional (distinct from a
hint- or calendar-body-named person) — a future correction is a plain
edit to `name`/`tags`, no different from correcting any other filed fact.

**The single-token trade-off.** A single bare token (`"patrick"`,
`"christian"`, but also an initial+surname mash like `"ahopkins"`) is
accepted rather than held, on live-corpus evidence: plain first-name
local-parts dominate real calendars (a 6-month replay's largest held
senders were addresses like `christian@...`/`patrick@...`, none of them
carrying a display name anywhere in the inbox), and holding them costs a
whole event while buying nothing — the model path has no more
information than the local-part gives it either. The accepted cost is
re-admitting the rarer initial+surname mash (`"ahopkins"` → `"Ahopkins"`)
alongside the common plain-first-name case; both are tagged
`name-from-email` and surface as one-line digest corrections, not
invented facts.

Hold is whole-event, not per-hint: a capture event names a fixed set of
participants, and filing an interaction missing one of them without
raising it would silently under-record who was there — D3's "hold, don't
guess". Newly created slugs are registered in the in-memory identity map
immediately, so a later hint in the same event, or a later event in the
same run, resolving to the same email/name reuses the same person instead
of creating a duplicate.

New-person slugs are the kebab-case of the display name; a collision with
an existing (or already-created-this-run) different-named slug appends
`-2`, `-3`, ... .

## Learned identity map

Bare-email hints with no name anywhere (no display name in the hint, no
calendar body match) are the single biggest source of holds against a
real corpus — most gmail participant-hints carry no display name at all.
`<data-dir>/ingestion/identities.tsv` closes that gap: an append-only,
`<slug>	EMAIL	<learned-from-capture-id>` ledger (deduped by slug+email)
that the identity map loads alongside `people/*.md` + `index.json`.
Whenever an email hint resolves to a slug — an existing match, a
name-fallback match, or a freshly created person — the pair is learned
immediately (skipped in `--dry-run`, which touches nothing). A later
bare-email hint for the same address, in this run or any future one,
resolves via the learned pairing instead of holding — this is exactly
what lets a self-sent email ("eric@... → dhruv@...", both self and a
learned identity) file as a real touchpoint instead of holding on its
one non-self recipient.

**Bootstrap.** A cold `identities.tsv` (missing, or `--relearn` given)
triggers a one-time derivation pass over the already-model-filed
`interactions/*.md` before the main pass runs: for each interaction, its
`source-capture` inbox event's non-self email hints (plus, for
calendar-event sources, the body's attendee/organizer/creator emails) are
collected. A pairing is only ever recorded when it's forced — never
guessed:
- the interaction has exactly one `people` slug and the event has exactly
  one non-self email → that pair;
- or the interaction has N slugs and the event has N emails, and a given
  email's hint/body display name normalizes to exactly one of those
  slugs' `name` fields → that pair (checked independently per email — an
  email that doesn't match exactly one slug is simply left unrecorded,
  the rest of the interaction's pairs are unaffected).

**Constraint propagation.** The forced-pair pass above only resolves an
interaction in isolation; a 3-attendee meeting where none of the three
emails carry a display name resolves nothing on its own even though two
of the three people might already be known from OTHER interactions. After
the forced-pair pass, propagation iterates to a fixed point: for every
candidate interaction, drop every email already mapped to SOME slug and
every slug already mapped to SOME email (checked against the
ever-growing identity map, not just this interaction) and re-check the
residual; if exactly one email and one slug remain, that pairing is
forced and learned. Repeat until a round learns nothing new. This is what
lets an already-known Dhruv and Josh in a 3-person meeting force out
Christian's email even though that meeting was never 1:1 on its own —
still never a guess beyond a forced 1:1 residual.

The bootstrap prints `identities: learned=<n>` before the main summary
line; it does not run at all in `--dry-run` (no bootstrap, no learning,
`identities.tsv` untouched — consistent with `--dry-run` writing nothing).

**Stale rows.** `identities.tsv` is append-only and is never rewritten or
pruned, so a row can outlive the person it names — the person's file was
deleted or renamed after the pairing was learned. Loading the ledger
checks each row's slug against the current `people/` snapshot; a row
whose `people/<slug>.md` no longer exists is skipped (not loaded into the
identity map) so the email falls through to normal resolution instead of
resolving to a dangling `[[slug]]` link that `validate-store.sh` would
flag. The row itself is left in place in `identities.tsv` — only the
in-memory load skips it, every run, until the slug exists again (e.g. the
person file is recreated) or the ledger is regenerated via `--relearn`.
The count of stale rows skipped this run is printed unconditionally as
`identities: stale=<m>` (0 when none) on its own line, separate from
`identities: learned=<n>` (which only prints when the bootstrap ran) so
neither line's shape depends on the other.

## Writes

- **New person** (`person.md` 1.1.0 shape): `name` and `last-touch` (the
  interaction's date) only; every other scalar field is blank or omitted
  (`tier` is omitted rather than written blank — an enum field with an
  empty value is a `validate-store.sh` error). `tags: []`, except a
  local-part-derived name (above) which gets `tags: [name-from-email]`.
  Body sections
  `## Facts` / `## Open threads` / `## Personal details` are each `_none_`
  — **no `## Facts` bullets are ever written** (D2: calendar attendance and
  email metadata are neither told-by-user nor inferred-public-web; a
  provenance tag would be invented).
- **Existing person:** only `last-touch` may change, and only forward —
  bumped in place (atomic tmp+mv) if the interaction's date is newer than
  the current value. Nothing else on the file is touched, ever.
- **Interaction** (`interaction.md` 1.0.0): `interactions/<date>-<first-
  resolved-slug>[--n].md`, `date` = `occurred_at`'s UTC date else
  `captured_at`'s. `## Summary` is a fixed template — calendar:
  `Calendar: "<title>" with <Name, Name> (<start>–<end> UTC, <n>
  attendees)` (title/start/end/attendees from the body JSON, attendee
  names excluding self, times converted to UTC, `HH:MM` when the source
  has a time component); gmail: `Email: "<subject>" — <sender> →
  <recipients>` (straight from `participant-hints`, sender = first hint,
  unfiltered — the raw envelope, not the resolved people). `##
  Commitments` is always `_none_` — commitment extraction needs judgment.
- The filed id is appended to `debrief-filed.log` — the **same** ledger the
  debrief skill's batch mode already skips, so nothing is double-filed.
  Held ids go only to `structured-held.log` (this script's sole ledger).

## Out of scope

- Free-text filing (chat episodes, voice notes, long emails, debrief
  notes) — the model path, unchanged.
- Pulling attendee `displayName` out of the calendar body JSON as a
  fallback name source is now IN scope for calendar-event hints (see
  "Resolution" step 0, above) — but `gmail-in/*` events have no such
  fallback source (a gmail body has no attendee-name-carrying JSON to
  parse); a gmail bare-email hint depends entirely on the learned
  identity map (participant-hints itself, or `identities.tsv`).
- `person.md` `tier`/`tier_source` and `kind`/`kind_source` — plan 31 D4/D5
  (`person-set-tier.sh`, `review-tiers`), never written here.
- The debrief skill's batch-mode wiring for `structured-held.log` — same
  shape as its existing `triage-held.log` exclusion, a follow-on change.

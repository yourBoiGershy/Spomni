# Spec: job-change detector

Package: `attention` (plan 05 detector set). Signal `type`: `job-change`.
Writes only `wakeups/signals/<id>.md` (`packages/core/contracts/signal-event.md`)
and, when promoted, a `wakeups/<id>.md` proposal — **never**
`people/<slug>.md`. A confirmed job change is filed exclusively by
`packages/ingestion`, only after the user confirms the update
(`docs/DECISIONS.md#preference-provenance`): a detected job change is
*ammunition* for a wake-up, never a direct `org`/`role` write. This detector
never edits `org` or `role` in `people/`; it proposes the update as a line
in the promoted wake-up's `## Context` for the human to confirm.

**ToS-clean doctrine (binding, per `CLAUDE.md` and plan 05):** no scraping,
no enrichment APIs, no RSS bridges. LinkedIn data is used only via emails
LinkedIn itself sends the user (`inbox/` `type: linkedin-notification`
capture events, already filed by the gmail-in lane). Web search
(the harness's WebSearch tool) is used only for verification of an
already-detected signal, never for profile harvesting or discovery.

## Inputs

Per sweep, for every person in `people/<slug>.md`:

- New `inbox/` entries (`packages/core/contracts/capture-event.md`) since
  the last sweep with `type: linkedin-notification`, whose
  `participant-hints`/resolved person link matches the slug.
- The newest `inbox/` entry with `type: email` from the person (by
  `occurred_at`), compared against the person's current `org`/`role`
  frontmatter (`packages/core/contracts/person.md`) for a signature-block
  diff.
- Web search (verification only), when a LinkedIn notification or
  signature diff is found, to raise or corroborate confidence.
- `data/store/profile.md` `## Signal opt-outs` (opt-out gate, below).
- Prior `wakeups/signals/*.md` for the person (30-day dedup, below).

## Detection rule

Sources, in strength order (a signal event may be emitted from any one of
these; corroboration across sources raises confidence per the rubric below):

1. **LinkedIn notification (strongest).** Scan the body of each new
   `type: linkedin-notification` capture event for a job-change pattern.
   Quoted-line patterns (case-insensitive, illustrative — not exhaustive;
   any line matching one of these shapes qualifies):
   - `started a new position (as|at) .+`
   - `is now .+ at .+`
   - `.+ has a new job( title)?[:]? .+`
   - `.+ started working at .+`
   - `.+ new role (as|at) .+`
   - `celebrating \d+ (year|month)s? at .+` (anniversary posts do NOT
     qualify — see Out of scope; listed here only to distinguish the
     pattern from a real move)
   The matched line is the primary evidence quote.

2. **Email-signature diff (corroboration).** Compare the newest `type:
   email` capture event's signature block (the trailing lines of the body,
   after the sign-off) against the person's current `org`/`role`
   frontmatter. A differing title and/or company line is corroboration for
   an already-detected LinkedIn notification, or can seed a standalone
   `medium`-confidence signal on its own (see rubric).

3. **Web-search verification.** Once a candidate move is detected from (1)
   or (2), or as a standalone low-confidence hint, run one web search using
   the template:

   ```
   "<full name>" "<new org>"
   ```

   Name and company are ALWAYS searched together (name-disambiguation
   rule) — a bare `"<full name>"` or bare `"<new org>"` search is never
   run, since either alone is too likely to surface an unrelated
   namesake or an unrelated company mention. A top result (within the
   first page) that confirms the move (e.g. a company "new hires" page, a
   press mention, a bio page) is evidence; no result found means the
   search contributes nothing (it is not treated as disconfirming — the
   detector never downgrades a LinkedIn notification because a search
   came up empty).

## Confidence rubric

| Confidence | Definition | Example |
|---|---|---|
| `high` | LinkedIn notification match AND at least one corroboration (signature diff or web-search confirmation) | "started a new position as Head of Partnerships at Meridian Fintech" + signature line now reads "Head of Partnerships, Meridian Fintech" |
| `medium` | LinkedIn notification match alone, OR signature diff alone (no LinkedIn notification) | Signature changed from "Product Manager, Northwind Labs" to "Senior PM, Northwind Labs" with no corroborating notification |
| `low` | Web-search-only hint, no LinkedIn notification and no signature diff | A search surfaces a "new hires" page mentioning the person at a company not yet reflected anywhere else in the store |

`low` confidence still writes a signal event but never promotes to a
wake-up on its own — it stands as a log entry that may later be
corroborated by a LinkedIn notification or signature diff in a subsequent
sweep, at which point the later, stronger signal is what promotes (per the
dedup gate below, the later signal is a new `id`, not a rewrite of the
earlier one, since `detected_at` differs and signal events are append-only
per `packages/core/contracts/signal-event.md`).

## Due-date rule

Promoted wake-ups are due **detected + 14 days**. Job changes are a
crowd-visible signal — everyone congratulates on day one; the user's
outreach lands better once the initial flood of "congrats!" messages has
passed and the person has settled into the new role. This is a
deliberately late due date relative to `scheduling-intent`'s 1–2-day
timing (`packages/attention/specs/scheduling-intent.md`) and matches
job-change's own "let the dust settle" logic — the two are not comparable.

## Opt-out / dedup gates

**Opt-out gate** (checked before promotion, before the signal event is
written for the person — an opted-out person produces no artifact at all
for this detector): `data/store/profile.md` `## Signal opt-outs`
(`packages/core/contracts/profile.md`):

- `job-change — all` → suppress for every person, sweep-wide.
- `job-change — [[slug]]` → suppress for that person only.

**Dedup (30 days):** before emitting a new `job-change` signal event for a
person, scan `wakeups/signals/*.md` for a prior entry with `type:
job-change` and `person` including the slug. If that entry's
`detected_at` is within 30 days of today, do not re-emit — the same
underlying move should not generate a second signal event (and a second
wake-up) within one calendar-adjacent window. A later, stronger
corroboration (e.g. a signature diff arriving 10 days after a LinkedIn
notification) does not create a new signal event within this window;
instead it is folded into the promotion step's evidence for the existing
signal if the wake-up has not yet fired (implementation detail for
signal-scan, not restated here). After 30 days, a fresh detection is
treated as a new move and re-emits normally.

Scoring, promotion, and budget/hold decisions belong to
`packages/attention/specs/ranking.md` — cite by path; not restated here.

## Evidence format

`evidence` is free text, self-sufficient for a human to judge without
re-fetching the source, each contributing clause provenance-labeled per
`CLAUDE.md`'s provenance-labeling principle:

```
[inferred-from-email] LinkedIn notification 2026-08-28: "Marcus Chen started
a new position as Engineering Director at Northwind Labs." [inferred-from-email]
signature diff: "Senior Engineer, Vantage Systems" -> "Engineering Director,
Northwind Labs" (inbox/20260825T091500Z-gmail-in-7a2c). [inferred-from-web]
"Northwind Labs welcomes Marcus Chen as Engineering Director" —
northwindlabs.com/news, https://northwindlabs.com/news/welcome-marcus
```

Any clause the detector did not actually gather (e.g. no signature diff
available) is simply omitted — evidence is never padded with an unfilled
placeholder clause.

## Example scenarios

1. **High confidence, full corroboration.** A `linkedin-notification`
   capture event quotes "Marcus Chen started a new position as Engineering
   Director at Northwind Labs." The newest `email` from marcus-chen has a
   signature reading "Marcus Chen · Engineering Director · Northwind
   Labs," differing from the stored `role: Senior Engineer` /
   `org: Vantage Systems`. A web search for `"Marcus Chen" "Northwind
   Labs"` returns a company announcement. Confidence: `high`. Promotion
   `## Context` states: "Marcus moved Vantage Systems (Senior Engineer) →
   Northwind Labs (Engineering Director). Open thread: he mentioned
   wanting intros to your ML contacts back in June — good reactivation
   angle now that he's settled. Update people/marcus-chen.md org/role?"
   Due = detected + 14 days.

2. **Medium confidence, signature-only.** No LinkedIn notification is
   present, but ayesha-malik's newest email signature reads "Ayesha
   Malik, Director of Partnerships" against a stored `role: Partnerships
   Manager` (same `org`). Confidence: `medium` (single source: signature
   diff). A signal event is written; if it stands alone through the
   sweep's promotion step it still promotes (medium promotes), with
   `## Context` proposing the title update and no organization change.

3. **Low confidence, held.** A web search run for corroboration on an
   unrelated matter incidentally surfaces a "new hires" mention of
   ben-whitmore at a different company, with no LinkedIn notification and
   no signature diff yet on file. Confidence: `low`. A signal event is
   written (`wakeups/signals/<id>.md`, `type: job-change`,
   `confidence: low`) but does not promote to a wake-up this sweep — it
   is left as a log entry pending stronger corroboration in a later
   sweep.

## Out of scope

- Writing `org`/`role` directly — always ingestion's job, always
  human-confirmed, never this detector's.
- LinkedIn profile scraping, enrichment APIs, or RSS bridges of any kind —
  the only LinkedIn source is `type: linkedin-notification` emails already
  filed to `inbox/` by the gmail-in lane.
- Treating a LinkedIn anniversary/celebration post ("celebrating 3 years
  at...") as a job change — these are excluded from the pattern list above
  and must not be misclassified as a move.
- Detecting a job change purely from a web search with no LinkedIn
  notification or signature diff anywhere in the store's history for that
  person — a bare search-only hint caps at `low` and never promotes on its
  own (see rubric).
- Promotion scoring, ranking, and budget/hold mechanics — see
  `packages/attention/specs/ranking.md`.

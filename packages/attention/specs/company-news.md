# Spec: company-news detector

Package: `attention` (plan 05 detector set). Signal `type`: `company-news`.
Writes only `wakeups/signals/<id>.md` (`packages/core/contracts/signal-event.md`)
and, when promoted, a `wakeups/<id>.md` proposal — **never**
`people/<slug>.md`. This detector never edits `org` in `people/`; a
detected reorg/rename is ammunition for the promoted wake-up's `## Context`
only, same as `job-change`'s "propose, never overwrite" rule
(`docs/DECISIONS.md#preference-provenance`).

**ToS-clean doctrine (binding, per `CLAUDE.md` and plan 05):** no scraping,
no enrichment APIs, no RSS bridges. Company news is gathered only via the
harness's WebSearch tool (public search, not a scrape of any specific
site), SEC EDGAR's public full-text search, or saved search results the
user's own connectors already filed to `inbox/`. Web search here is for
news, not for profile harvesting of the *person* — it targets the
*organization* name only.

## Inputs

Per sweep:

- The top-N contacts by warmth (`W`, `packages/attention/specs/ranking.md`)
  that have a non-empty `org` in `people/<slug>.md`
  (`packages/core/contracts/person.md`). `N` defaults to 25, parameterizable
  per sweep config.
- Distinct `org` values across that contact set (one detection pass per
  distinct org, then fanned out to every person at that org — see below).
- `inbox/` entries with `type: other` and `source: web-search`
  (the fixture/saved-search form) dated since the last sweep, scoped to a
  matching org.
- `data/store/profile.md` `## Signal opt-outs` (opt-out gate, below).
- Prior `wakeups/signals/*.md` for the org (30-day per-org dedup, below).

## Detection rule

For each distinct `org` in the top-N-by-warmth contact set:

1. **Name-disambiguation gate (applied first).** If `org` is a generic,
   single common word (e.g. "Bridge", "Summit", "Apex" — any name likely to
   collide with unrelated companies/common nouns in search results), the
   detector does not search on the bare org name. Instead it either:
   - appends the org's associated person's role/city to the query (see
     query templates below), or
   - if no role/city is available to disambiguate, **skips** that org
     entirely for this sweep and logs the skip (org name + reason:
     "ambiguous, no disambiguator available"). No signal is ever emitted
     on an ambiguous match — a false positive on the wrong "Bridge" is
     worse than a missed real one.

2. **Web search.** Query templates (trailing-14-days recency filter
   applied via the search tool's own date-range parameter where
   available, otherwise post-filtered on result date):

   ```
   "<org>" (raises OR funding OR acquires OR acquired OR launches OR layoffs OR IPO)
   ```

   or, when the disambiguation gate requires it:

   ```
   "<org>" "<person's role or city>" (raises OR funding OR acquires OR acquired OR launches OR layoffs OR IPO)
   ```

3. **SEC EDGAR full-text search.** Query EDGAR's full-text search for the
   org name (raises/8-K/S-1 filings are the relevant forms — funding and
   M&A events are frequently disclosed there before general press picks
   them up). Cite the endpoint generically as
   `https://efts.sec.gov/LATEST/search-index?q=<org>` — the exact request
   shape belongs to the connector/script that implements this, not this
   spec. A matching filing is treated as one independent source.

4. **Saved `inbox/` search results.** Any `type: other`,
   `source: web-search` capture event already filed for this org (the
   fixture/manual-save form) counts as a source at the confidence level
   its content warrants — treat it exactly like a live web search hit for
   scoring purposes.

## Confidence rubric

| Confidence | Definition | Example |
|---|---|---|
| `high` | Two independent sources corroborate the same event (e.g. a web search result AND an EDGAR filing, or two separate reputable outlets) | A TechCrunch article on Northwind Labs' Series B AND a matching Form D filing on EDGAR |
| `medium` | One reputable news result, no second corroborating source | A single trade-press article reporting Northwind Labs' new product launch |
| `low` | Single low-quality or ambiguous-adjacent result (e.g. a blog aggregator, a press-release mirror with no primary source, or a disambiguated-but-thin match) | One low-traffic aggregator post mentioning a "possible acquisition," unconfirmed elsewhere |

## Due-date rule

Promoted wake-ups are due **detected + 2 days**. Company news is
time-sensitive and public — a congratulatory or context-aware outreach
("saw the Series B news — congrats!") loses its value fast once it stops
being current, unlike `job-change`'s deliberately-late 14-day window
(`packages/attention/specs/job-change.md`). This is the opposite timing
choice from job-change and is intentional: job-change waits for the
congratulations flood to pass, company-news rides it.

## Opt-out / dedup gates

**Opt-out gate** (checked before any search spend for a person's org — an
opted-out person's org is skipped for that person, though the org may
still be searched and fanned out to other non-opted-out people at the same
org): `data/store/profile.md` `## Signal opt-outs`
(`packages/core/contracts/profile.md`):

- `company-news — all` → suppress this detector entirely, sweep-wide.
- `company-news — [[slug]]` → suppress fan-out to that person only; the
  org may still be searched and produce a signal event fanned out to other
  people at that org who are not opted out.

**Dedup (30 days, per org):** before running a fresh search pass for an
org, scan `wakeups/signals/*.md` for a prior `type: company-news` entry
whose evidence names this org, with `detected_at` within 30 days of today.
If found, skip the search for that org this sweep (both to avoid noise and
to respect the rate/cost guard below) — one company-news signal per org
per 30 days, regardless of how many people at that org are in the top-N
set.

**Fan-out.** A single detected event produces one `wakeups/signals/<id>.md`
whose `person` list includes every top-N contact at that org (not one
signal per person) — the pairing across multiple people at the same
company is itself part of the ammunition (e.g. "reach out to both Ayesha
and the two others you know at Northwind about the raise"), so it is
recorded once, fanned out, rather than duplicated per person.

Scoring, promotion, and budget/hold decisions belong to
`packages/attention/specs/ranking.md` — cite by path; not restated here.

## Rate / cost guard

At most **25 searches per scan** (web search + EDGAR combined). The scan
logs the count actually run (e.g. "company-news: 18/25 searches used this
sweep"). If the top-N-by-warmth org list would exceed the cap, orgs are
processed in warmth order (highest-warmth contact's org first) and the
remainder are simply not searched this sweep — carried over naturally to
the next sweep rather than queued or backfilled specially.

## Evidence format

`evidence` is free text, self-sufficient for a human to judge without
re-fetching the source, each clause provenance-labeled per `CLAUDE.md`'s
provenance-labeling principle:

```
[inferred-from-web] "Northwind Labs raises $40M Series B" — TechCrunch
2026-08-27, https://techcrunch.com/2026/08/27/northwind-labs-series-b
[inferred-from-web] Form D filing, Northwind Labs Inc. — SEC EDGAR
2026-08-26, https://efts.sec.gov/LATEST/search-index?q=Northwind+Labs
```

## Example scenarios

1. **High confidence, two sources, multi-person fan-out.** marcus-chen
   (top-N, `org: Northwind Labs`) and one other stored contact both work
   at Northwind Labs. A web search for `"Northwind Labs" (raises OR
   funding OR ...)` returns a TechCrunch Series B article; an EDGAR search
   returns a matching Form D. Confidence: `high`. One signal event is
   written with `person: ["[[marcus-chen]]", "[[other-slug]]"]`. Due =
   detected + 2 days. Promotion `why` line: "Northwind Labs just raised a
   Series B — good moment to reach out to Marcus (and Priya, also there)."

2. **Medium confidence, single reputable source.** ayesha-malik's `org`
   ("Bridgepoint Analytics") is not a single generic word, so no
   disambiguator is needed. A trade-press article reports a product
   launch; no EDGAR filing and no second source found. Confidence:
   `medium`. Signal event written, promotes per ranking (medium is
   sufficient to promote per this detector's own rubric — the ranking
   spec governs whether it clears the sweep's budget).

3. **Ambiguous org, skipped.** ben-whitmore's `org` field reads "Summit"
   with no further qualifier, and no role/city is available in his
   `people/ben-whitmore.md` frontmatter to disambiguate. The
   name-disambiguation gate skips "Summit" entirely for this sweep; the
   scan log records: "company-news: skipped org 'Summit' — ambiguous, no
   disambiguator available." No signal event is written for this org this
   sweep.

## Out of scope

- Emitting on an ambiguous org-name match — always skip and log per the
  disambiguation gate; never guess.
- Scraping any specific news site, or using an enrichment API/RSS bridge —
  the only sources are the harness's WebSearch tool, SEC EDGAR's public
  full-text search, and already-filed `inbox/` saved-search entries.
- Writing `org` (rename/reorg) directly into `people/` — always proposed
  in `## Context`, always human-confirmed via ingestion, never this
  detector's write.
- Company news for orgs outside the top-N-by-warmth contact set — this
  detector does not scan every org ever seen in the store, only the
  current sweep's top-N (cost guard, above).
- Per-person duplicate signal events for the same org event — always one
  fanned-out signal event per org per 30-day window (see dedup/fan-out).
- Promotion scoring, ranking, and budget/hold mechanics — see
  `packages/attention/specs/ranking.md`.

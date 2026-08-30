# Plan 30: Semantic scoring — user model × relationship kind × evidence

Status: Ready

> **Revision 2 (2026-08-29)** — user review redirected three things.
> (1) Layer 3 is **model judgment with priors, not a formula**: the draft's
> `R = base × tier_scale`, `S = W_kind × A × E`, and score bands were rigid
> numbers one level up from the 21/45/90 bands they replaced — removed.
> The judgment pass now emits the score (`attention_warrant` 0–100);
> rigid numbers survive only as *rules* (insufficient-data gate, kind caps,
> zero unconfirmed tier writes); the "few weights" are **priors** the
> judgment must acknowledge and the breakdown must name. Tier-drift becomes
> deterministic *prefilter* + judgment verdict. (2) **Local optional
> embeddings** (Ollama via curl+jq; Anthropic offers no embedding model and
> Voyage is cloud → violates other-people's-data-stays-local) as an
> ingestion-owned supporting layer: neighbor priors, clustering for
> classification, user-model draft evidence; everything degrades gracefully
> without Ollama. (3) A deterministic **rescale / re-center** operation for
> warrants (ingestion) and weight dimensions (attention) so a batch that
> drifts "everyone too high/low" can be averaged out — user-invoked, never
> silent. Sequencing: ingestion is the center of gravity; attention work is
> minimal and dispatched **after plan 05 merges**. D1–D5 kept (D3's rhythm
> column relabeled as prefilter horizon; D5 gains clusters/neighbors/skew
> warning).

Package: core (user-model, relationship-scoring, embeddings-index
contracts; person.md kind fields; ranking-weights 1.1.0; store scripts) +
ingestion (evidence, user-model derive-and-confirm, embeddings, clustering,
classification+scoring judgment, rescale, `review-tiers` skill, tests,
evals) + attention (minimal, last: tier-drift prefilter spec, calibrate
seeding/rescale, drift skill)
Depends-on: 15 (personalization), 25 (episode-split; the live corpus this
chunk de-saturates), 26 (import pipeline). Attention phase additionally
depends on **plan 05 merging** (in progress on `chunk-05-signal-engine`).
Independent of 27 (speed) — may interleave; absorbs none of it.
Branch: chunk-30-semantic-scoring-user-model

## Objective

Replace the one-formula tier score (median-gap band + participation points)
with a three-layer hybrid: **Layer 1** a stated-provenance *user model*
describing the user's relationship-investment mix; **Layer 2** a per-person
*relationship kind* (small vocabulary + free-text rationale, judged by the
model from deterministic evidence, user-confirmable, expirable); **Layer 3**
a *judged* attention warrant given kind × evidence × user model, with a
small interpretable set of priors (user-model axes + two
`ranking-weights.json` dimensions) the judgment must acknowledge and the
breakdown must name. Local embeddings (optional) supply "who is this person
like, among people the user already confirmed" as an extra prior. A
rescale operation keeps the population centered when it drifts.

Why (live-proven 2026-08-29): all 20 onboarding tier suggestions saturated to
inner-circle. Of 23 people clearing the ≥2-touchpoint gate, 20 have
`median_gap_days ≤ 21`; outliers are 35, 35, 133. Structural, not a
threshold problem: chunk 25 files one interaction per active chat-day, so any
regular chat contact maxes frequency bands designed for meeting cadence.
Frequency cannot tell a two-week scheduling contact from a monthly real
friend — what separates them is what the relationship *is*, and who the user
is. Frequency and its siblings stay important, but as **evidence the
judgment reads**, not the score.

## Decisions (made here, binding on all units)

**D1 — Layer 1 is a NEW core contract `user-model.md` (1.0.0), not a
`profile.md` extension.** Read-and-rejected: extending `profile.md`.
`profile.md` is by construction stated-only (four fixed sections, freeform
priorities); the user model has a *lifecycle* — a corpus-derived DRAFT
(`observed-from-behavior`) that becomes stated only on confirmation — and
putting a derived draft inside a stated-only artifact mixes provenance in one
file (DECISIONS#preference-provenance: never mixed). It also needs its own
frontmatter (status, derived/confirmed dates, revision) that `profile.md`'s
`schema_version`-only frontmatter deliberately excludes. Singleton
`data/store/user-model.md`. **Sole writer: ingestion** (same as profile.md;
single-writer preserved). Readers: ingestion (review-tiers), attention
(tier-drift, calibration seeding), query. Attention only proposes revisions
(a wake-up), mirroring the profile.md rule. Shape (U1 transcribes):

```
---
schema_version: 1.0.0
status: draft | confirmed
derived_at: <ISO date>          # when the draft was computed from the corpus
confirmed_at: <ISO date|null>   # null while draft
revision: <int>                 # bumps on every confirmed edit
provenance: observed-from-behavior | stated-by-user   # draft | confirmed
---
## Investment mix
<one line per axis: "<axis>: <weight 0–1> — <rationale>">
   axes (fixed set): business, friends, family, community, transactional
## Protected time
<freeform: what the user keeps regardless of business load,
 e.g. "regular friends — weekly-ish hangs are non-negotiable">
## Season
<freeform + optional `until: <date>`: current posture, e.g.
 "heads-down quarter, business-first until 2026-11-30">
## Revealed vs stated
<the draft's corpus-derived numbers kept verbatim under a
 "revealed (observed-from-behavior)" subheading for audit; the confirmed
 axis lines above are the stated version. Two labeled blocks, never merged.>
```

Revisable: the user re-runs the confirm flow any time; each confirmation bumps
`revision` and re-triggers prior seeding (D6). Scores change when this file
changes — that is the point.

**D2 — `kind` is a second, orthogonal field on person.md; the four-tier
enum stays as the warmth axis.** (Architect's standing lean, confirmed
here.) Less churn on person.md consumers (index, query, wakeups all read
`tier` today); warmth-within-kind is real (close vs. distant colleague).
person.md contract minor-bumps (optional fields only):

| Field | Type | Meaning |
|---|---|---|
| `kind` | enum, optional | one of the D3 vocabulary |
| `kind_note` | string, optional | free-text rationale — the semantic part; required whenever `kind` is set |
| `kind_source` | enum, required if `kind` set | `stated-by-user` \| `derived` — never mixed; a user correction sets `stated-by-user` and sticks: the classification pass never overwrites a stated kind |
| `kind_expires` | ISO date, optional | for time-boxed kinds; past `kind_expires` the kind reads as `expired` (D3) with no attention warranted and no guilt framing |
| `kind_updated` | ISO date, required if `kind` set | last write |

Provenance asymmetry, stated explicitly: **derived kinds may be written to
people/ by ingestion without confirmation** (they are labeled `derived`, like
inferred facts); **tier writes still require user confirmation, zero
exceptions** (unchanged from chunks 21/24/25). Unkinded and untiered remain
valid end states.

**D3 — Kind vocabulary (small, not a rigid taxonomy; `kind_note` carries
the nuance).** The horizon column is a **prefilter only** (D7): it selects
drift *candidates* for judgment; it is never a verdict and never enters a
score.

| kind | soft horizon (days, prefilter only) | notes |
|---|---|---|
| `friend` | 30 | real social relationship |
| `family` | 30 | |
| `collaborator` | 14 | active shared work (co-founder, teammate, client-in-flight) |
| `professional` | 120 | business relationship without live shared work |
| `community` | none | group/scene contact; user-participation decides warmth |
| `scheduling` | none | time-boxed logistics for one event/errand; **must carry `kind_expires`** (the event date or last-message + 14d) |
| `transactional` | none | vendor/service/support; no relationship rhythm |
| `unsolicited` | none | inbound pitch/cold contact the user never answered |
| `unknown` | none | insufficient evidence; judgment declines to guess |

`expired` is not a kind value: it is the read state of any person whose
`kind_expires` is past. Neutral wording everywhere: "scheduling contact —
event passed" not "dormant/neglected". Vocabulary lives in the core
contract (U3) and is the single source for validate-store, graders, and the
skill prompt.

**D4 — Evidence is deterministic, extracted by script, and is what the
judgment reads.** New `packages/ingestion/scripts/derive-evidence.sh <store>
[--person <id>]` emits one JSON object per person (stdout, one per line):
`touchpoints`, `median_gap_days`, `days_since_last`, `meetings` (calendar /
in-person interaction count), `chat_days`, `emails`, `user_initiated_share`,
`participation` (verbatim from `derive-participation.sh` — reused, not
re-implemented), `co_attended` (calendar co-attendance count), `upcoming`
(next calendar event with this person, if any), `talking_points` (count +
first 80 chars of each, from person.md), `tier` (current, may be null),
`kind` (current, may be null). Read-only over people/, interactions/,
index.json, wakeups/. The judgment pass (D5/D6) consumes this JSON plus
the person.md body plus the *filed* interaction summaries — all
post-`file`-stage store content — so the import-pipeline rule "raw bodies
never transcribed by model before judgment" is untouched: this pass never
opens `inbox/` or `archive/`.

**D5 — The classification+scoring pass and the `review-tiers` flow.**
Pipeline position: a **post-file judgment pass** (`classify`), documented in
`import-pipeline.md` as a one-paragraph cross-reference (no bump: it adds no
stage between the existing five; it reads only file-stage outputs). Runs
inside the new user-invoked skill `packages/ingestion/skills/review-tiers/
SKILL.md` — the "explicit user-invoked review tiers flow" the seeding spec
anticipated — and never unprompted. Flow:

1. **Gate on the user model.** If `user-model.md` is absent or `status:
   draft`, run the derive-and-confirm step first: `derive-user-model.sh`
   writes the draft; the skill shows the revealed mix and asks the user to
   confirm or edit each axis line, protected time, and season; confirmed →
   `status: confirmed`, `provenance: stated-by-user`, `revision` bumped,
   revealed block kept labeled. Nothing else proceeds on a draft.
2. **Prepare priors.** `embed-people.sh` refreshes embeddings (D8; skipped
   with `embeddings: unavailable` when Ollama is absent); `cluster-people.sh`
   groups the in-scope people; `nearest-confirmed.sh` yields each person's
   nearest confirmed neighbors. Scope flag `--all | --unkinded | --person
   <id>`, default `--unkinded`.
3. **Judge (D6).** Per cluster (exemplars first, then members), the model
   reads evidence + person.md + filed summaries + confirmed user model +
   priors (weights, neighbors) and emits the D6 structured record. Stated
   kinds are never overwritten; derived kinds are written via the core
   script (U6) with `kind_source: derived`. `check-judgment.sh` validates
   every record's shape, gate, and caps before anything is written or shown.
4. **Skew check + present.** `rescale-scores.sh --report` runs over the
   batch (D9); if skewed, the skill shows the warning and offers
   `--rescale` (never auto-applies). Present in one batch, capped at 20,
   no backlog framing; per person: confirm / adjust (kind and/or tier) /
   skip, each with its breakdown string. Confirm or adjust writes tier
   (stated) and sets `kind_source: stated-by-user`. Skips are recorded in
   `data/ingestion/review-skips.log` (`<person-id>\t<ISO>`) and never
   resurface unless the user passes `--include-skipped`.
5. Live-store constraint honored: the 2026-08-29 all-skip batch is
   re-presented only if the user invokes `review-tiers --all` or
   `--include-skipped`; nothing re-prompts on its own.

**D6 — Layer 3 is judgment with priors. No score formula.** New core
contract `relationship-scoring.md` (1.0.0) defines, for both packages that
run the judgment (ingestion: suggestions; attention: drift verdicts):

- **Judgment output (structured, one JSON record per person):**
  `attention_warrant` (integer 0–100: "given what this relationship is and
  who the user is, how much attention does it warrant now"),
  `suggested_tier` (D2 enum or null), `kind`, `kind_note`, `kind_expires`
  (required for `scheduling`), `rationale` (≤2 sentences; **must cite at
  least one evidence field by name and the kind**), `confidence`
  (low|medium|high). Ingestion validates the shape (`check-judgment.sh`)
  and rejects records that violate the rules below; a rejected record is
  re-judged once, then shown as `unknown` with the rejection reason.
- **Rigid numbers survive only as rules, never estimates:**
  insufficient-data gate — touchpoints < 2 → no suggestion; kind caps —
  `scheduling|transactional|unsolicited` never suggest above `active`,
  `unknown` never above `close`; expired kinds → warrant 0, no suggestion;
  zero tier writes without confirmation. Everything else is judgment.
- **The priors** (the user's "few weights"), handed to the judgment verbatim
  in the prompt and named in the breakdown: (a) the confirmed user-model
  axis weights + protected time + season — the user's own numbers; (b) two
  `ranking-weights.json` dimensions, `kinds` (one key per D3 kind) and
  `evidence` (keys `meeting`, `chat_day`, `email`, `co_attended`,
  `user_initiated`, `talking_point`), documented as **prior-strength hints
  the judgment must acknowledge**: the prompt contract states that a weight
  < 1.0 means "de-emphasize this kind / evidence feature relative to
  default", > 1.0 "emphasize", with 0.5 and 1.5 given as worked
  illustrations, and that a prior never overrides a stated kind or tier or
  a rule; (c) neighbor priors (D8) when available: "most similar confirmed
  people: [[dana]] (friend, close), [[sam]] (collaborator)". Existing
  clamps hold: absolute [0.25, 2.0], per-step ±0.15, rationale per entry.
  **ranking-weights.md → 1.1.0:** (i) an *absent* key's first write
  (seeding) may land anywhere inside the absolute bounds; (ii) a
  `--rescale` renormalization (D9) is exempt from the per-step rule; both
  carry rationale. Seeding: `calibrate.sh --seed-from-user-model` (attention
  owns the file), invoked by review-tiers after a confirmation, rationale
  `seeded from user-model revision <n>`; a revision bump re-seeds only keys
  whose rationale still names an older revision (user-tuned entries
  survive). Seed values: `kinds.*` from the axis map
  (friend/family→friends/family, collaborator/professional→business,
  community→community, transactional/scheduling/unsolicited→transactional)
  × the axis weight, protected → ≥1.0; `evidence.*` defaults meeting 1.5,
  co_attended 1.3, user_initiated 1.2, talking_point 1.2, email 1.0,
  chat_day 0.8.
- **Breakdown string (required on every suggestion and drift proposal,
  auditable by reading):**
  `warrant: <0-100> | kind: <kind> (<kind_source>[, expires <date>]) — <kind_note ≤80c> | evidence: touchpoints=<n> median_gap_days=<n> days_since_last=<n> meetings=<n> chat_days=<n> participation=<v> | priors: user-model.<axis>=<w> (rev <n>[, protected]) kinds.<kind>=<w> evidence.<used keys>=<w> [| neighbors: [[slug]] (<kind>[, <tier>], confirmed) ...] | rationale: <text> | suggested: <tier>`
  — supersedes the seeding spec's `suggested: … | base: … | signals: …`.
  When embeddings are unavailable the `neighbors:` segment is omitted and
  the run log says `embeddings: unavailable`.

**D7 — Tier-drift = deterministic prefilter + judgment verdict.**
`tier-drift.md`'s global 21/45/90 cadence table is replaced by: (1)
**prefilter** — candidates are people with a rhythmed kind (D3 horizon ≠
none), not expired, whose `days_since_last` exceeds the kind's soft horizon
(unkinded → `professional`'s horizon, disclosed in the proposal); no-rhythm
and expired kinds never enter; (2) **judgment** — for each candidate the
same D6 pass asks "has this gone quiet *for this kind of relationship, for
this user*?" and either drafts a quiet-drift proposal (with the D6
breakdown) or emits `no-drift` with a one-line reason. Upward drift: same
shape — prefilter = touchpoints in the last 90d above the current tier's
expectation as judged, candidates only from rhythmed kinds. Proposal-only
remains: attention writes no tier, no kind.

**D8 — Local, optional embeddings; ingestion-owned derived artifact.**
Fact: Anthropic offers no embedding model; the docs point to Voyage AI
(cloud) — sending person data there violates *other people's data stays
local*. So embeddings run **only via local Ollama** (`nomic-embed-text`
default; open-weight `voyage-4-nano` if present), as one `curl` +
`jq` call from bash — no Python/PyTorch. Optional everywhere: when
`http://localhost:11434` is unreachable every consumer logs `embeddings:
unavailable` and proceeds without neighbor priors/clusters; graders pass in
both modes. Artifact: `<store>/index/embeddings.jsonl`, one line per
person: `slug, model, dims, vector, embedded_at, content_hash` (sha of
person.md + filed interaction summaries; re-embed only on hash change).
Regenerable, never leaves the machine, not a source of truth. Contract:
**new small core contract `embeddings-index.md` (1.0.0)** rather than
amending the index.json contract — the vector file has its own writer
cadence, size profile, and optionality, and index.json consumers must not
be forced to understand it. Sole writer: ingestion (`embed-people.sh`);
readers: ingestion (nearest/cluster/user-model draft), attention (drift
neighbor priors, read-only). Uses: (i) neighbor priors (D6c); (ii) greedy
threshold clustering (`cluster-people.sh`, jq/awk cosine, threshold in
the spec) so classification runs per cluster with exemplars; (iii)
`derive-user-model.sh` adds one revealed-behavior input — similarity of
recent interaction summaries to the five axis descriptions — labeled as
such in the revealed block, omitted when unavailable.

**D9 — Rescale / re-center, deterministic, user-invoked, single-writer.**
Two operations:
- **Warrants (ingestion):** `rescale-scores.sh <scores.jsonl> [--report |
  --target-mean 50 --target-spread <n> | --rank]`. `--report` prints the
  distribution — mean, median, spread, share ≥ 80, share ≤ 20 — overall and
  **per kind** (so "all friends are 90+" is visible) and a `skew: yes|no`
  verdict against thresholds in the spec (share ≥ 80 > 0.5 or share ≤ 20 >
  0.5 or spread < 10). Re-center = shift + scale to target, clamped 0–100;
  `--rank` = percentile bands. Pure function, no store writes; suggested
  tiers recomputed from rescaled warrants through the same D6 caps;
  ordering preserved; idempotent on centered input. review-tiers shows
  the skew warning and offers `--rescale`; never auto-applies.
- **Weights (attention):** `calibrate.sh --rescale <dimension>` renormalizes
  a `ranking-weights.json` dimension so its geometric mean = 1.0 preserving
  ratios, within absolute clamps, exempt from ±0.15 (ranking-weights 1.1.0
  ii); every touched entry gets rationale `rescaled <date>: dimension mean
  <old> → 1.0`. User-invoked only.

## Work units

### Phase 1 — core contracts (one parallel message, 2 workers)

**U1 [worker A, core]. user-model contract + template.** Depends-On: — |
Parallel-safe with U2.
Files: `packages/core/contracts/user-model.md` (new, 1.0.0),
`packages/core/templates/user-model.md` (new), `packages/core/package.md`.
Transcribe D1 verbatim (path, writer/readers, frontmatter, sections, axis
set, two-labeled-blocks rule, revision semantics; the revealed block may
carry an `embedding-similarity` line per D8iii, labeled optional).
Brief carries: D1 + D8(iii) verbatim; profile.md contract text; DECISIONS
#preference-provenance paragraph.
Acceptance: contract + template exist with every D1 field/section;
package.md row `user-model.md 1.0.0, per plan 30`.

**U2 [worker B, core]. person.md kind fields + ranking-weights 1.1.0.**
Depends-On: — | Parallel-safe with U1; serial before U3.
Files: `packages/core/contracts/person.md` (minor bump), `packages/core/
templates/person.md`, `packages/core/contracts/ranking-weights.md` (→
1.1.0), `packages/core/package.md`.
D2 table verbatim incl. provenance asymmetry; ranking-weights: `kinds` +
`evidence` dimensions with key lists, the first-write seeding rule, the
rescale exemption, and the "priors, not multipliers" sentence from D6.
Brief carries: D2, D3 header, D6 priors bullet verbatim; person.md rows
32–36; ranking-weights.md clamp section.
Acceptance: five kind fields with types; ranking-weights 1.1.0 names both
dimensions, all keys, both amendments; existing fields untouched.

**U3 [worker A, warm]. relationship-scoring + embeddings-index contracts.**
Depends-On: U1, U2.
Files: `packages/core/contracts/relationship-scoring.md` (new, 1.0.0),
`packages/core/contracts/embeddings-index.md` (new, 1.0.0),
`packages/core/contracts/import-pipeline.md` (one `classify` paragraph,
no bump — D5), `packages/core/package.md`.
relationship-scoring: D3 (vocabulary, horizon-as-prefilter, expired
read-state, neutral wording), D6 verbatim (output record with field types,
the rules, prior semantics incl. the 0.5/1.5 illustrations, breakdown
format with one worked example), D7 prefilter definition, D9 warrant
rescale as a permitted post-processing step. embeddings-index: D8 artifact
shape, writer/readers, optionality, locality rule, hash-driven refresh.
Brief carries: D3, D6, D7, D8, D9 verbatim; import-pipeline.md stage table
(lines 19–27).
Acceptance: a checker can validate a judgment record against the contract
from the file alone; breakdown format exact; both contracts capsule-sized;
import-pipeline diff is one paragraph.

### Phase 2 — ingestion specs (one parallel message, 2 workers, disjoint
files)

**U4 [worker, ingestion]. user-model-derive + review-tiers specs.**
Depends-On: U3 | Parallel-safe with U5.
Files: `packages/ingestion/specs/user-model-derive.md` (new),
`packages/ingestion/specs/review-tiers.md` (new),
`packages/ingestion/specs/onboarding-tiering-seed.md` (banner only:
scoring superseded by relationship-scoring 1.0.0 + review-tiers; gate/cap/
skip rules retained).
user-model-derive: revealed mix from per-axis share of interactions and of
meetings over 90 days (existing kinds where present, else heuristic:
≥2-attendee calendar meetings→business, personal-channel chat-days→friends,
family tag→family) plus D8iii similarity line when available; writes the
D1 draft; drafts are never read by judgment. review-tiers: D5 verbatim;
the **judgment prompt contract** — inputs listed, D6 output record,
prior-treatment text, neighbor line format, stated-kind skip, per-cluster
exemplar order, `check-judgment.sh` rejection + one re-judge; skew warning
wording and `--rescale` offer; scope flags; skip ledger; "Deterministic
checkability" section (kind ∈ vocabulary, note non-empty, expiry for
scheduling, rationale cites an evidence field, no tier write without a
confirm line).
Brief carries: D1, D4, D5, D6 verbatim; seeding spec gate/cap/skip
paragraphs.
Acceptance: prompt contract and skip-ledger format exact; seed spec banner
present, rest byte-identical.

**U5 [worker, ingestion]. embeddings + rescale specs.** Depends-On: U3 |
Parallel-safe with U4.
Files: `packages/ingestion/specs/embeddings.md` (new),
`packages/ingestion/specs/rescale.md` (new).
embeddings: D8 verbatim — Ollama endpoint/model resolution (`OLLAMA_URL`,
`EMBED_MODEL` env, `EMBED_CMD` override hook for tests), request/response
shape, content-hash inputs, unavailable behavior + log line, cosine in jq,
`nearest-confirmed.sh` output line format (`<slug>\t<kind>\t<tier|->\t<cos>`),
greedy clustering threshold (0.80 default) and exemplar selection
(highest-degree member). rescale: D9 warrants op verbatim — report fields,
skew thresholds, shift/scale math, `--rank` bands, clamp, cap recompute,
idempotence.
Brief carries: D8, D9 verbatim.
Acceptance: both specs deterministic enough that a checker can recompute a
fixture's nearest list and rescaled batch by hand.

### Phase 3 — implementation (one parallel message: core worker U6;
ingestion worker 1 runs U7→U9; ingestion worker 2 runs U8; then warm
worker 1 runs U10)

**U6 [worker, core]. Store scripts: set-kind, validate, index.**
Depends-On: U2, U3 | Parallel-safe with U7, U8.
Files: `packages/core/scripts/person-set-kind.sh` (new),
`packages/core/scripts/validate-store.sh`, `packages/core/scripts/
build-index.sh`, `packages/core/package.md`.
person-set-kind.sh `<store> <person-id> --kind <k> --note <s> --source
<derived|stated-by-user> [--expires <date>]`: bash 3.2, rewrites only the
five kind fields, refuses `--source derived` over `stated-by-user` (exit 2),
refuses `scheduling` without `--expires`, sets `kind_updated`.
validate-store: kind ∈ vocabulary; note/source/updated present iff kind
set; scheduling has expiry; `user-model.md` status/provenance pairing;
`index/embeddings.jsonl` if present has valid lines (slug exists, dims
match vector length). build-index: `kind`, `kind_source`, `kind_expires`.
Brief carries: D2, D3 list, D8 artifact shape; validate-store's tier check
block; build-index's field-emission block.
Acceptance: round-trip on fixture; refusals proven; validate rejects bad
kind, mismatched pairing, malformed embedding line; index columns present.

**U7 [ingestion worker 1]. derive-evidence.sh + derive-user-model.sh.**
Depends-On: U4 | Parallel-safe with U6, U8; serial before U9.
Files: `packages/ingestion/scripts/derive-evidence.sh` (new),
`packages/ingestion/scripts/derive-user-model.sh` (new).
derive-evidence per D4 (calls `derive-participation.sh`; JSON-lines;
read-only; `--person`; byte-stable). derive-user-model per U4 spec: writes
draft from the core template; refuses to overwrite `confirmed` unless
`--redraft` (writes `user-model.draft.md` beside it); calls
`nearest-confirmed.sh`-style similarity only if `embeddings.jsonl` exists
(via a `--similarity-file` input produced by U8's script — keeps this unit
free of Ollama), else omits the line. bash 3.2 + jq.
Brief carries: D4 fields; U4 heuristic; core template;
derive-participation.sh usage header.
Acceptance: evidence JSON byte-matches expected on fixture store; draft
validates under U6; confirmed refusal proven.

**U8 [ingestion worker 2]. embed-people.sh + nearest-confirmed.sh +
cluster-people.sh.** Depends-On: U5 | Parallel-safe with U6, U7.
Files: `packages/ingestion/scripts/embed-people.sh`,
`packages/ingestion/scripts/nearest-confirmed.sh`,
`packages/ingestion/scripts/cluster-people.sh` (all new).
embed-people: per person build the content (person.md body + filed
interaction summaries), sha hash, skip unchanged, POST to Ollama
`/api/embeddings` via curl (or `EMBED_CMD` override), append/replace the
JSONL line; on connection failure print `embeddings: unavailable` and exit
0 with the file untouched. nearest-confirmed: cosine in jq over the JSONL,
filter `kind_source: stated-by-user` from index.json, `--k` (default 3),
spec output format; `--axis-similarity <store>` mode emits the D8iii
per-axis similarity JSON for U7. cluster-people: greedy threshold
clustering, output `<cluster-id>\t<slug>\t<exemplar:yes|no>`. All bash 3.2
+ jq + awk; each script exits 0 with a one-line `unavailable` notice when
the JSONL is absent.
Brief carries: D8 verbatim; U5's formats; Ollama `/api/embeddings` request/
response excerpt.
Acceptance: with `EMBED_CMD` pointed at a fixture-vector shim, JSONL
byte-matches expected; second run re-embeds nothing; nearest and cluster
outputs byte-match; every script degrades correctly with Ollama absent.

**U9 [ingestion worker 1, warm]. rescale-scores.sh + check-judgment.sh.**
Depends-On: U7 (worker continuity), U5.
Files: `packages/ingestion/scripts/rescale-scores.sh`,
`packages/ingestion/scripts/check-judgment.sh` (both new).
rescale per D9/U5 (report incl. per-kind, skew verdict, shift/scale, rank,
clamp, cap recompute; pure function). check-judgment: validate a judgment
JSONL against relationship-scoring (types, warrant range, kind ∈
vocabulary, scheduling expiry, rationale cites an evidence field name and
the kind, gate and caps applied) — prints per-record `ok|reject:<reason>`,
non-zero if any reject.
Brief carries: D6 record + rules, D9 verbatim; U5 rescale math.
Acceptance: fixture batch report byte-matches; rescaled output lands on
target mean, preserves order, idempotent; check-judgment rejects each
rule violation with a distinct reason.

**U10 [ingestion worker 1, warm]. review-tiers skill + manifests.**
Depends-On: U6, U8, U9.
Files: `packages/ingestion/skills/review-tiers/SKILL.md` (new),
`packages/ingestion/package.md` (provides: four specs, seven scripts, the
skill, skip ledger, embeddings artifact; consumes `user-model@^1`,
`relationship-scoring@^1`, `embeddings-index@^1`, `person@^1.<new>`,
`ranking-weights@^1.1`).
SKILL.md = D5's five steps as operative procedure: gate + confirm dialogue
+ `calibrate.sh --seed-from-user-model` call (attention script, invoked
not edited); prepare priors (three U8 scripts, unavailable path); judge
per cluster with the U4 prompt contract embedded verbatim, `check-judgment`
before any write, derived kinds via `person-set-kind.sh --source derived`,
never opens inbox/archive; skew report + `--rescale` offer; present ≤20
with breakdowns, confirm/adjust/skip semantics, tier written only on
confirm/adjust; skip ledger; ends with `build-index.sh` + `validate-store.sh`.
Neutral wording for expired/no-rhythm kinds stated.
Brief carries: D5, D6 verbatim; U4 prompt contract; usage headers of the
six ingestion/core scripts; debrief SKILL.md confirm/skip wording.
Acceptance: every write step names its script; no path writes a tier
without a confirm; judge step lists inputs explicitly and excludes inbox/
archive; both Ollama modes described; package.md rows present.

### Phase 4 — tests (one parallel message, 3 workers on disjoint suites)

**U11 [worker, core/tests]. Store tests.** Depends-On: U6.
File: `packages/core/tests/run-store-tests.sh` (extend; 10 green today).
person-set-kind round-trip; stated-overwrite refusal; scheduling-without-
expiry refusal; validate rejects bad kind / missing note / draft-stated
mismatch / malformed embedding line; index kind columns.
Acceptance: green under bash 3.2; sabotage-proven.

**U12 [worker, ingestion/tests]. Evidence, user-model, rescale,
check-judgment tests.** Depends-On: U7, U9.
Files: `packages/ingestion/tests/fixtures/scoring/` (new — **synthetic
only**, ~12 people mirroring the live corpus *shape*: daily-chat scheduling
contact with past event, monthly-meeting friend, silent group, unanswered
pitch, collaborator, unkinded, touchpoints < 2; plus a confirmed user-model
and a skewed judgment batch where all warrants > 80),
`packages/ingestion/tests/run-scoring-tests.sh` (new, style of
`run-seed-tests.sh`); trim `run-seed-tests.sh` of old-band assertions
(keep gate/cap/skip).
Tests: evidence byte-stable; draft validates + confirmed refusal;
rescale — report byte-match, skew detected on the >80 batch, mean lands on
target, ordering preserved, clamps, idempotent on centered input, `--rank`
bands, per-kind report present; check-judgment — one rejection per rule
with distinct reason, caps enforced (scheduling→inner-circle rejected).
Acceptance: green; sabotage-proven per property.

**U13 [worker, ingestion/tests]. Embeddings/nearest/cluster tests.**
Depends-On: U8 | Parallel-safe with U11, U12.
Files: `packages/ingestion/tests/fixtures/embeddings/` (fixture vectors +
`fake-embed.sh` shim for `EMBED_CMD`), `packages/ingestion/tests/
run-embeddings-tests.sh` (new).
Tests: JSONL byte-match; hash-skip on second run; changed person.md
re-embeds only that slug; nearest-confirmed output byte-match and excludes
derived-kind people; cluster output byte-match at threshold; axis-
similarity JSON byte-match; **unavailable mode**: with `OLLAMA_URL` pointed
at a closed port every script exits 0, prints the notice, writes nothing.
Acceptance: green; sabotage-proven.

### Phase 5 — ingestion evals (one parallel message, 2 workers)

Judgment is non-deterministic: graders assert **acceptable sets,
orderings, and properties**, never exact model values. Prompts embed the
U4 prompt contract verbatim; fact-based Python graders in the style of
`triage-held-respected`; eval-case 1.2.0; suite must stay green in both
Ollama modes (cases run with `EMBED_CMD` → fixture shim, and once with
embeddings absent where stated).

**U14 [worker, ingestion/evals]. Cases A.** Depends-On: U10, U12.
Files: new cases under `packages/ingestion/evals/cases/` +
`suite.txt`: `kind-classification-corpus` (per fixture person an
acceptable-kind set — scheduling ∈ {scheduling, transactional}, pitch ∈
{unsolicited, unknown}, monthly friend ∈ {friend}; note ≤2 sentences;
scheduling has expiry; rationale cites an evidence field),
`warrant-ordering` (friend > scheduling > unsolicited; monthly friend >
daily scheduling contact), `de-saturation` (≤2 of 12 suggested
inner-circle; no rhythm-less kind above active), `user-model-propagation`
(raise friends axis 0.3→0.8, re-run: every friend-kind warrant rises or
holds, no non-friend rises beyond noise band ±5; breakdown `priors:` names
the new revision).
Acceptance: 4 cases green; each flips to FAIL when doctored (force
inner-circle for all; swap the axis edit).

**U15 [worker, ingestion/evals]. Cases B.** Depends-On: U10, U13 |
Parallel-safe with U14.
Cases: `neighbor-prior-consistency` (fixture with two unconfirmed people
similar to one exemplar; run once unconfirmed → record kinds; confirm the
exemplar as `friend` (stated) → re-run: both neighbors' kinds move toward
`friend` or stay if already there, and the breakdown `neighbors:` names the
exemplar), `no-ollama-fallback` (same fixture as kind-classification with
embeddings absent: log has `embeddings: unavailable`, no `neighbors:`
segment, all kind-set assertions still pass), `rescale-skew-detection`
(pre-seeded judgment batch all >80: skill surfaces the skew warning, does
not apply rescale without `--rescale`; with `--rescale` the presented
warrants have mean within ±5 of 50 and order preserved),
`review-tiers-zero-writes-without-confirm` (no confirm lines → people/
tier fields byte-identical), `stated-kind-sticks` (pre-set
`stated-by-user` kind unchanged after the pass).
Acceptance: 5 cases green; doctored FAIL each.

### Phase 6 — attention (minimal; **dispatch only after plan 05 merges to
main; branch syncs via `git merge main` first**)

**U16 [worker, attention]. Specs: tier-drift prefilter + calibration
seeding/rescale.** Depends-On: U3, plan 05 merged.
Files: `packages/attention/specs/tier-drift.md` (lines 33–56 replaced),
`packages/attention/specs/calibration.md` (new sections).
tier-drift: D7 verbatim (prefilter definition using the D3 horizon column,
no-rhythm/expired exclusion, unkinded→professional disclosure, judgment
verdict + breakdown, upward-drift shape, proposal-only). calibration:
`--seed-from-user-model` (D6 seed values, rationale, revision-aware) and
`--rescale <dimension>` (D9 weights op) sections; both dimensions listed.
Brief carries: D6 priors bullet, D7, D9 weights op verbatim; tier-drift.md
33–56; calibration.md clamp section.
Acceptance: no 21/45/90 global bands remain (grep); calibration names both
flags and dimensions; proposal-only unchanged.

**U17 [worker, attention, warm]. calibrate.sh modes + drift skill.**
Depends-On: U16, U6, U8.
Files: `packages/attention/scripts/calibrate.sh`, `packages/attention/
skills/tier-drift/SKILL.md` (new — makes D7 operative: prefilter via
`derive-evidence.sh` output + index kind columns, judgment with the
relationship-scoring record and breakdown, neighbor priors via
`nearest-confirmed.sh` read-only, proposals via existing wake-up machinery,
never writes people/ or user-model), `packages/attention/package.md`
(consumes `user-model@^1`, `relationship-scoring@^1`,
`embeddings-index@^1`).
Brief carries: D6 seed values, D7, D9 weights op verbatim; calibrate.sh
write path + clamp helper; U16's rewritten tier-drift.md.
Acceptance: seed on fixture confirmed user-model byte-matches expected
JSON; re-seed preserves user-tuned entries; `--rescale kinds` yields
geometric mean 1.0 with ratios preserved, rationale lines present, ±0.15
not applied; skill has no people/ write.

**U18 [worker, attention/tests+eval]. Tests + drift eval.** Depends-On:
U17.
Files: `packages/attention/tests/run-attention-tests.sh` (extend),
`packages/attention/evals/cases/tier-drift-by-kind/` (new) + `suite.txt`;
re-baseline `tier-drift-upward` (fixture person gains a kind).
Tests: seed byte-compare; clamp bounds; re-seed preservation; rescale
properties (mean 1.0, ratios, clamps, idempotent, rationale); prefilter
selection table per kind (rhythm-less and expired never selected;
unkinded uses professional horizon). Eval: fixture with expired scheduling
contact (no candidate), friend under horizon (no candidate), friend past
horizon (judged → proposal with breakdown matching the D6 regex), unkinded
past 120d (proposal discloses fallback); graders: candidate set exact,
proposal count within acceptable set, breakdown regex, zero people/ writes.
Acceptance: attention suite + eval green incl. re-baselined upward case;
doctored FAIL proven.

### Phase 7 — verification (orchestrator-led)

**U19. Full-suite + live proofs.** Depends-On: U11–U15 (ingestion gate),
U18 (attention gate; may run as a second pass if 05 lands later).
1. Suites green: store, capture, beeper, scheduler, seed (trimmed), triage,
   scoring, embeddings, attention; filing goldens untouched-green;
   ingestion eval 19 + 9; attention eval green.
2. **Live user-model (user session, private data, nothing committed):**
   draft → confirm/edit → validates; `calibrate.sh --seed-from-user-model`
   writes `kinds.*`/`evidence.*` with rationales (attention script run
   locally; if 05 not merged yet, run from the plan-30 branch after U17).
3. **Live embeddings:** Ollama present → `embed-people.sh` over 32 people,
   JSONL validates, nearest lists look sane for 3 spot-checked people;
   Ollama stopped → `embeddings: unavailable`, review-tiers still runs.
4. **Live review-tiers (`--all`, user-invoked — the explicit re-presentation
   of the 2026-08-29 all-skip batch, by the user's choice only):**
   de-saturation evidence = suggested-tier histogram over the 23 gated
   people is **not** 20/23 inner-circle; scheduling contacts ≤ active with
   expiry; every suggestion shows the D6 breakdown; skew report printed.
   Zero writes without confirmation verified by diffing people/ tier fields
   against the transcript's confirm lines.
5. **User-model change proof:** edit one axis (revision bump), re-judge —
   breakdowns cite the new revision; that axis's kinds move, others within
   ±5.
6. `validate-store.sh` clean; ROADMAP row 30 → Done (amendment below);
   memory notes; Status → Done with evidence. Max 2 fix rounds; retry briefs
   carry diffs + failure output.

## Proof of done (maps to ROADMAP §30 as amended)

1. `user-model.md`, `relationship-scoring.md`, `embeddings-index.md`,
   person.md kind fields, ranking-weights 1.1.0 versioned in core;
   ingestion + attention manifests declare consumption (U1–U3, U10, U17).
2. Live corpus ranks without saturation; scheduling/unsolicited/silent-group
   contacts land low with neutral wording (U14 + U19.4).
3. Every suggestion and drift proposal carries the breakdown naming kind,
   evidence, priors (user-model, weights, neighbors when available), and
   rationale (U10, U17, U14, U18).
4. Changing the confirmed user model changes warrants where it applies
   (U14, U19.5); confirming an exemplar moves its neighbors (U15).
5. Embeddings local-only and optional: identical eval outcomes with Ollama
   absent (U13, U15, U19.3).
6. Rescale detects skew and re-centers deterministically, never silently
   (U12, U15, U18).
7. Zero tier writes without confirmation; stated kinds never overwritten
   (U6, U11, U15, U19.4).
8. All suites + both eval suites green (U19.1).

## Explicitly out of scope (do not pull in)

- **Speed (27):** batching/caching judgment calls, embedding throughput.
- **Autonomous sync (28):** no scheduled classification or embedding
  refresh; review-tiers and embed-people are user-invoked.
- **Fleet (29):** no new evidence sources.
- **Attention beyond U16–U18** — plan 05's signal engine is in flight; no
  ranking-engine changes, no wake-up shape changes, no new sweeps here.
- Cloud embeddings of any kind (Voyage etc.); Python/PyTorch dependencies;
  embeddings as a source of truth or a query surface.
- Retroactive re-filing/un-filing; group-noise triage; automatic expiry
  sweeps that edit people/; unprompted re-prompting of the all-skip batch.

## ROADMAP amendment (orchestrator applies)

**Row 30 (replace):** `30 | Semantic scoring: user model × relationship
kind × judged warrant (priors, local embeddings, rescale) |
core+ingestion(+attention, minimal, after 05) | 15, 25, 26 | plan
2026-08-29-30-semantic-scoring-user-model`

**§30 body (replace):** Replaces the one-formula tier score, which saturated
to inner-circle on the live corpus (episode-split makes chat frequency
uninformative), with a three-layer hybrid. **Layer 1** — a stated-provenance
`user-model.md` (core contract, ingestion-written) describing the user's
investment mix, protected time, and current season; drafted from revealed
behavior, confirmed by the user, revisable. **Layer 2** — a per-person
relationship `kind` (small vocabulary + free-text rationale, derived by a
post-file judgment pass from deterministic evidence; user-confirmable,
stated corrections stick, time-boxed kinds expire guilt-free) as a second
axis beside the unchanged four-tier warmth enum. **Layer 3** — **judgment
with priors, not a formula**: the model emits an attention warrant (0–100),
suggested tier, and rationale from evidence + user model + a small
interpretable prior set (user-model axes; `kinds`/`evidence` dimensions on
ranking-weights.json, seeded from the user model; nearest confirmed
neighbors); rigid numbers survive only as rules (data gate, kind caps, zero
unconfirmed tier writes). **Local optional embeddings** (Ollama via
curl+jq, never cloud) supply neighbor priors, clustering, and user-model
draft evidence, degrading gracefully when absent. A deterministic
**rescale** re-centers warrant batches and weight dimensions when they
drift, user-invoked. Tier-drift becomes prefilter + judgment; attention
footprint minimal and sequenced after plan 05. New user-invoked
`review-tiers` flow is the confirmation surface. Proof of done: live corpus
ranks without saturation; every suggestion carries a breakdown naming kind,
evidence, priors, and rationale; warrants move when the user model moves;
identical outcomes with embeddings absent; eval-guarded; zero tier writes
without confirmation.

Status: Ready

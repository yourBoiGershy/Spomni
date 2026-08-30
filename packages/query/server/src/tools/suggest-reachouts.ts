// Tool: suggest_reachouts — the "who should I speak to" answer path, per
// docs/plans/2026-08-29-08-chat-mcp-query-layer.md's "MCP tool surface"
// (unit 9). Read-only: this tool never mutates the wake-up queue (attention
// is its sole lifecycle writer, packages/core/contracts/wakeup.md — only
// `wakeup-add.sh` creates entries, only attention transitions `status`).
//
// Attention owns ranking (docs/DECISIONS.md#attention-merge /
// single-writer): this tool surfaces attention's own pending-wake-up
// artifacts first (`source: attention`) and only falls back to a
// transparent, fully-auditable heuristic to fill remaining slots
// (`source: heuristic-fallback`) — it must never grow into a competing
// ranking engine.

import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { StoreReader } from "../store/reader.ts";
import type { StatsEntry, WakeupFile } from "../store/types.ts";
import { warrantsProactiveSuggestion } from "../store/kind-semantics.ts";

const DEFAULT_LIMIT = 5;
const MAX_LIMIT = 10;

// Attention window: wake-ups due within this many days (or already overdue,
// i.e. due in the past but still `pending` — attention hasn't fired/dismissed
// them yet) are "actionable soon" and worth surfacing here. Anything further
// out is attention's own queue to worry about later, not query's job to
// pre-empt.
const ATTENTION_WINDOW_DAYS = 30;

// Tier weight: inner-circle > close > active > dormant, per
// docs/PROJECT-CONTEXT.md's tiering. Plain ordinal weights, not tuned —
// the point is transparency (every component is visible in the
// breakdown), not a "correct" score.
const TIER_WEIGHT: Record<string, number> = {
  "inner-circle": 4,
  close: 3,
  active: 2,
  dormant: 1,
};

// Baseline used only when a person has no `median_gap_days` (fewer than two
// interactions, so no personal cadence exists yet) — a fixed reference so
// the staleness component still has a value, called out explicitly in the
// breakdown so it never masquerades as a real cadence.
const NO_CADENCE_BASELINE_DAYS = 60;

const STALENESS_WEIGHT = 10;
const TIER_WEIGHT_MULTIPLIER = 5;
const OPEN_THREAD_WEIGHT = 3;

/** `some-slug` -> `Some Slug`. There is no `name` field in index.json/
 * stats.json (see derived-index.md); matches search_people's convention of
 * deriving a display name from the slug rather than opening every person
 * file for a listing. */
function nameFromSlug(slug: string): string {
  return slug
    .split("-")
    .map((part) => (part.length > 0 ? part[0].toUpperCase() + part.slice(1) : part))
    .join(" ");
}

function daysBetween(fromIso: string, toMs: number): number {
  const fromMs = Date.parse(fromIso);
  return Math.floor((toMs - fromMs) / 86_400_000);
}

function slugFromLink(link: string): string {
  // "[[slug]]" -> "slug"
  return link.replace(/^\[\[/, "").replace(/\]\]$/, "");
}

interface AttentionSuggestion {
  source: "attention";
  slug: string;
  people: { slug: string; name: string }[];
  due: string;
  why: string;
  origin: string;
  status: string;
  context: string;
  has_draft: boolean;
  cites: string;
}

interface FallbackBreakdown {
  days_since_last_interaction: number;
  median_gap_days: number | null;
  staleness_ratio: number;
  tier: string | null;
  tier_weight: number;
  open_threads: number;
  score: number;
  reason: string;
}

interface FallbackSuggestion {
  source: "heuristic-fallback";
  slug: string;
  name: string;
  breakdown: FallbackBreakdown;
  cites: string;
}

type Suggestion = AttentionSuggestion | FallbackSuggestion;

/** Pending wake-ups due within the attention window, soonest/most overdue first. */
function attentionCandidates(reader: StoreReader, nowMs: number): WakeupFile[] {
  const windowMs = ATTENTION_WINDOW_DAYS * 86_400_000;
  return reader
    .listWakeups()
    .filter((w) => w.frontmatter.status === "pending")
    .filter((w) => {
      const dueMs = Date.parse(w.frontmatter.due);
      return dueMs - nowMs <= windowMs;
    })
    .sort((a, b) => Date.parse(a.frontmatter.due) - Date.parse(b.frontmatter.due));
}

function toAttentionSuggestion(wakeup: WakeupFile): AttentionSuggestion {
  const people = wakeup.frontmatter.people.map((link) => {
    const slug = slugFromLink(link);
    return { slug, name: nameFromSlug(slug) };
  });
  const contextSection = wakeup.sections.find((s) => s.heading === "Context");
  const hasDraft = wakeup.sections.some((s) => s.heading === "Draft");

  return {
    source: "attention",
    slug: wakeup.id,
    people,
    due: wakeup.frontmatter.due,
    why: wakeup.frontmatter.why,
    origin: wakeup.frontmatter.origin,
    status: wakeup.frontmatter.status,
    context: contextSection?.raw ?? "",
    has_draft: hasDraft,
    cites: wakeup.sourcePath,
  };
}

function scoreFallbackCandidate(
  slug: string,
  entry: StatsEntry,
  nowMs: number,
): FallbackSuggestion {
  const daysStale = daysBetween(entry.last_interaction as string, nowMs);
  const stalenessRatio =
    entry.median_gap_days !== null && entry.median_gap_days > 0
      ? daysStale / entry.median_gap_days
      : daysStale / NO_CADENCE_BASELINE_DAYS;

  const tierWeight = entry.tier !== null ? (TIER_WEIGHT[entry.tier] ?? 0) : 0;
  const score =
    stalenessRatio * STALENESS_WEIGHT +
    tierWeight * TIER_WEIGHT_MULTIPLIER +
    entry.open_threads * OPEN_THREAD_WEIGHT;

  const cadencePhrase =
    entry.median_gap_days !== null
      ? `vs. usual ${String(entry.median_gap_days)}-day gap`
      : `(no established cadence yet, baseline ${String(NO_CADENCE_BASELINE_DAYS)}d)`;
  const threadPhrase =
    entry.open_threads > 0
      ? `${String(entry.open_threads)} open thread${entry.open_threads === 1 ? "" : "s"}`
      : "no open threads";
  const reason = `no touch in ${String(daysStale)} days ${cadencePhrase}; ${entry.tier ?? "untiered"} tier; ${threadPhrase}`;

  return {
    source: "heuristic-fallback",
    slug,
    name: nameFromSlug(slug),
    breakdown: {
      days_since_last_interaction: daysStale,
      median_gap_days: entry.median_gap_days,
      staleness_ratio: Math.round(stalenessRatio * 100) / 100,
      tier: entry.tier,
      tier_weight: tierWeight,
      open_threads: entry.open_threads,
      score: Math.round(score * 100) / 100,
      reason,
    },
    cites: `people/${slug}.md`,
  };
}

/**
 * Eligible people for the fallback heuristic: at least one recorded
 * interaction (zero-interaction people have no staleness signal — per plan
 * 08, they're only reachable through wake-ups, never given an invented
 * score). Excludes anyone already surfaced via `alreadySurfaced` (attention
 * slugs) so the same person isn't double-listed. Also excludes stub
 * contacts (index tag `name-from-email`) and anyone whose kind doesn't
 * warrant a proactive suggestion (landlord/vendor/cold-pitch/expired —
 * see kind-semantics.ts) — this is a raw heuristic surface, not a
 * fact-judgment one, so kind exclusion is the only relationship-semantics
 * filter applied here.
 */
function fallbackCandidates(
  reader: StoreReader,
  nowMs: number,
  alreadySurfaced: Set<string>,
): FallbackSuggestion[] {
  const stats = reader.stats();
  const index = reader.index();
  const today = new Date(nowMs).toISOString().slice(0, 10);
  const out: FallbackSuggestion[] = [];

  for (const [slug, entry] of Object.entries(stats.people)) {
    if (alreadySurfaced.has(slug)) continue;
    if (!entry.last_interaction || entry.touchpoints === 0) continue;

    const indexEntry = index[slug];
    if (indexEntry?.tags?.includes("name-from-email")) continue;
    if (
      !warrantsProactiveSuggestion(
        { kind: indexEntry?.kind ?? null, kind_expires: indexEntry?.kind_expires ?? null },
        today,
      )
    ) {
      continue;
    }

    out.push(scoreFallbackCandidate(slug, entry, nowMs));
  }

  out.sort((a, b) => b.breakdown.score - a.breakdown.score);
  return out;
}

export function buildSuggestions(
  reader: StoreReader,
  limit: number,
  nowMs: number = Date.now(),
): Suggestion[] {
  const cappedLimit = Math.max(1, Math.min(limit, MAX_LIMIT));

  const attention = attentionCandidates(reader, nowMs).map(toAttentionSuggestion);
  const attentionSlugs = new Set<string>();
  for (const a of attention) {
    for (const p of a.people) attentionSlugs.add(p.slug);
  }

  const suggestions: Suggestion[] = [...attention.slice(0, cappedLimit)];
  if (suggestions.length < cappedLimit) {
    const remaining = cappedLimit - suggestions.length;
    const fallback = fallbackCandidates(reader, nowMs, attentionSlugs).slice(0, remaining);
    suggestions.push(...fallback);
  }

  return suggestions;
}

const inputSchema = {
  limit: z
    .number()
    .int()
    .min(1)
    .max(MAX_LIMIT)
    .optional()
    .describe(`Max suggestions to return (default ${String(DEFAULT_LIMIT)}, max ${String(MAX_LIMIT)}).`),
};

export function registerSuggestReachouts(server: McpServer, reader: StoreReader): void {
  server.registerTool(
    "suggest_reachouts",
    {
      title: "Suggest reachouts",
      description:
        "NOT the answer path for \"who should I reach out to?\" — use who_next_pool for " +
        "that (it is pre-filtered per relationship-scoring.md kind/currency semantics " +
        "plus fact-judgment inputs). This tool surfaces pending wake-ups from the " +
        "attention queue first (source: attention), then falls back to a transparent " +
        "staleness/tier/open-threads heuristic to fill remaining slots " +
        "(source: heuristic-fallback, each with a full score breakdown — never a bare " +
        "score). The fallback excludes non-relational/expired kinds (landlord, vendor, " +
        "cold pitch) and stub contacts, but does no fact-level judgment. Read-only — " +
        "never mutates the wake-up queue; absence of wake-ups is normal, not an error.",
      inputSchema,
    },
    (args) => {
      const limit = args.limit ?? DEFAULT_LIMIT;
      const suggestions = buildSuggestions(reader, limit);

      const result = {
        generated_at: reader.generatedAt,
        limit,
        count: suggestions.length,
        suggestions,
      };

      return {
        content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
      };
    },
  );
}

// Tool: who_next_pool — the /who-next skill's whole candidate pool in one
// call, replacing the old search_people + up to 20 get_person round-trips
// (plan 38 unit G, docs/plans/2026-08-30-38-retrieval-speed.md). Emits
// exactly the objects packages/query/scripts/who-next-direct.sh emits, in
// the same order — that script is the reference implementation for the
// filter/rank contract and both paths must stay byte-for-byte equivalent
// (packages/query/tests/test-who-next-pool.mjs pins this). Read-only: only
// ever calls `reader.index()` / `reader.stats()` / `reader.getPerson()`.
//
// Facts/open_threads_text/personal ride inline on every candidate so the
// skill judges from wording, not from rank order alone (plan 35 /
// answer-style 1.0.0 decision) — that inlining is the whole point of
// collapsing the old per-person get_person loop into a single call.

import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { StoreReader } from "../store/reader.ts";

const DEFAULT_LIMIT = 20;
const MIN_LIMIT = 1;
const MAX_LIMIT = 50;
const COOLDOWN_DAYS = 14;

type Mode = "friends" | "coffee" | "all";

interface RawCandidate {
  slug: string;
  name: string;
  tags: string[];
  kind: string | null;
  last_interaction: string | null;
  touchpoints: number;
  open_threads: number;
  commitments_user: number;
  tier: string | null;
  facts: string[];
  personal: string;
  open_threads_text: string;
}

interface Candidate extends RawCandidate {
  days_since: number | null;
  stub: boolean;
}

/** `YYYY-MM-DD` -> UTC day-epoch milliseconds, matching jq's
 * `strptime("%Y-%m-%d") | mktime` (which treats the broken-down time as
 * UTC regardless of the host's local timezone). */
function parseUtcDateMs(dateStr: string): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dateStr);
  if (!m) return null;
  const [, y, mo, d] = m;
  return Date.UTC(Number(y), Number(mo) - 1, Number(d));
}

/** Local today as `YYYY-MM-DD`, matching the shell reference's `date +%Y-%m-%d`. */
function localToday(): string {
  const now = new Date();
  const y = now.getFullYear();
  const mo = String(now.getMonth() + 1).padStart(2, "0");
  const d = String(now.getDate()).padStart(2, "0");
  return `${y}-${mo}-${d}`;
}

/** Bullets under a `## <heading>` section, "- " prefix stripped, verbatim
 * otherwise (provenance tags intact) — matches who-next-direct.sh's
 * `sub(/^- /, "", v)` per bullet. */
function bulletTexts(sections: { heading: string; raw: string; bullets: string[] }[], heading: string): string[] {
  const section = sections.find((s) => s.heading === heading);
  if (!section) return [];
  return section.bullets.map((line) => line.replace(/^- /, ""));
}

/** Every non-blank line under a `## <heading>` section, original spacing
 * preserved, joined with " " — matches who-next-direct.sh's `NF > 0` per-line
 * capture for "## Personal details" (prose, not necessarily bullets). */
function nonBlankLinesJoined(sections: { heading: string; raw: string; bullets: string[] }[], heading: string): string {
  const section = sections.find((s) => s.heading === heading);
  if (!section || section.raw.length === 0) return "";
  return section.raw
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .join(" ");
}

/** Builds the unfiltered per-person object set, in ascending-slug order —
 * matches who-next-direct.sh's awk pass over `ls -1 people/*.md | sort`
 * joined against index.json, which only keeps slugs present as an object
 * in index.json. */
function buildRawCandidates(reader: StoreReader): RawCandidate[] {
  const index = reader.index();
  const stats = reader.stats();
  const slugs = Object.keys(index).sort();

  const out: RawCandidate[] = [];
  for (const slug of slugs) {
    const indexEntry = index[slug];
    if (indexEntry == null || typeof indexEntry !== "object") continue;
    const person = reader.getPerson(slug);
    if (!person) continue;

    const statsEntry = stats.people[slug];
    const frontmatter = person.frontmatter as Record<string, unknown>;
    const fmName = typeof frontmatter.name === "string" ? frontmatter.name : "";
    const fmTier = typeof frontmatter.tier === "string" && frontmatter.tier !== "" ? frontmatter.tier : null;

    out.push({
      slug,
      name: fmName === "" ? slug : fmName,
      tags: indexEntry.tags ?? [],
      kind: (frontmatter.kind as string | undefined) ?? null,
      last_interaction: statsEntry?.last_interaction ?? indexEntry["last-touch"] ?? null,
      touchpoints: statsEntry?.touchpoints ?? 0,
      open_threads: statsEntry?.open_threads ?? 0,
      commitments_user: statsEntry?.commitments?.user ?? 0,
      tier: statsEntry?.tier ?? fmTier,
      facts: bulletTexts(person.sections, "Facts"),
      personal: nonBlankLinesJoined(person.sections, "Personal details"),
      open_threads_text: bulletTexts(person.sections, "Open threads").join("; "),
    });
  }
  return out;
}

export interface WhoNextPoolArgs {
  mode?: Mode;
  limit?: number;
  today?: string;
  include_transactional?: boolean;
}

export function whoNextPool(reader: StoreReader, args: WhoNextPoolArgs): object {
  const mode: Mode = args.mode ?? "all";
  const limit = Math.min(MAX_LIMIT, Math.max(MIN_LIMIT, args.limit ?? DEFAULT_LIMIT));
  const today = args.today ?? localToday();
  const includeTransactional = args.include_transactional ?? false;
  const todayMs = parseUtcDateMs(today);

  const raw = buildRawCandidates(reader);

  const withDerived: Candidate[] = raw.map((c) => {
    let daysSince: number | null = null;
    if (c.last_interaction != null && todayMs != null) {
      const lastMs = parseUtcDateMs(c.last_interaction);
      if (lastMs != null) daysSince = Math.floor((todayMs - lastMs) / 86400000);
    }
    const stub = c.tags.includes("name-from-email") || (!c.name.includes(" ") && c.facts.length === 0);
    return { ...c, days_since: daysSince, stub };
  });

  let filtered = withDerived.filter((c) => c.days_since == null || c.days_since >= COOLDOWN_DAYS);

  if (mode === "coffee") {
    filtered = filtered.filter((c) => !c.tags.includes("linkedin-outreach"));
  }

  if (mode !== "friends") {
    filtered = filtered.filter((c) => includeTransactional || c.kind !== "transactional");
  }

  if (mode === "friends") {
    filtered = filtered.filter((c) => c.kind === null || c.kind === "friend" || c.kind === "family");
  }

  const ranked = filtered
    .map((c) => ({
      candidate: c,
      rankTier: c.open_threads > 0 || c.commitments_user > 0 ? 3 : c.kind !== null ? 2 : 1,
    }))
    .sort((a, b) => {
      const stubA = a.candidate.stub ? 1 : 0;
      const stubB = b.candidate.stub ? 1 : 0;
      if (stubA !== stubB) return stubA - stubB;
      if (a.rankTier !== b.rankTier) return b.rankTier - a.rankTier;
      const daysA = a.candidate.days_since ?? -1;
      const daysB = b.candidate.days_since ?? -1;
      return daysB - daysA;
    })
    .slice(0, limit)
    .map((entry) => entry.candidate);

  return {
    generated_at: reader.generatedAt,
    mode,
    limit,
    today,
    candidates: ranked,
  };
}

const inputSchema = {
  mode: z
    .enum(["friends", "coffee", "all"])
    .optional()
    .describe('Filter mode (default "all"): "friends" keeps kind in {null, friend, family}; ' +
      '"coffee" also drops linkedin-outreach-tagged people; "coffee"/"all" drop kind: transactional ' +
      "unless include_transactional is set."),
  limit: z
    .number()
    .int()
    .min(MIN_LIMIT)
    .max(MAX_LIMIT)
    .optional()
    .describe("Max candidates returned (default 20, max 50)."),
  today: z
    .string()
    .optional()
    .describe('Override "today" for the 14-day-cooldown/age math, "YYYY-MM-DD" (default: today).'),
  include_transactional: z
    .boolean()
    .optional()
    .describe("Keep kind: transactional people (landlords, mail, closed one-offs) — dropped by default."),
};

export function registerWhoNextPool(server: McpServer, reader: StoreReader): void {
  server.registerTool(
    "who_next_pool",
    {
      title: "Who-next candidate pool",
      description:
        "Read-only, one-call candidate pool for the /who-next skill: same pre-filtered " +
        "(14-day cooldown, mode rules, transactional/linkedin-outreach exclusions), " +
        "pre-ranked people as packages/query/scripts/who-next-direct.sh, in the same order. " +
        "Each candidate carries its facts, personal details, and open-threads text inline " +
        "(no per-person get_person follow-up needed) — the skill judges from those, never " +
        "from pool order alone.",
      inputSchema,
    },
    ({ mode, limit, today, include_transactional }) => {
      const result = whoNextPool(reader, { mode, limit, today, include_transactional });
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    },
  );
}

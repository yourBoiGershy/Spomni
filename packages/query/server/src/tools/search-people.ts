// Tool: search_people — index+stats filter/free-text search over people,
// per docs/plans/2026-08-29-08-chat-mcp-query-layer.md's "MCP tool surface".
// Read-only: only ever calls `reader.index()` / `reader.stats()`, never
// touches the filesystem directly. Slim records only — full detail lives
// behind `get_person`.

import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { StoreReader } from "../store/reader.ts";
import type { IndexEntry } from "../store/types.ts";

const PAGE_SIZE = 25;
const MAX_NEIGHBORS = 5;

/** `some-slug` -> `Some Slug`. There is no `name` field in index.json/
 * stats.json (see derived-index.md) — the display name is always derived
 * from the slug, same rule get_person's no-match path uses for suggestions. */
function nameFromSlug(slug: string): string {
  return slug
    .split("-")
    .map((part) => (part.length > 0 ? part[0].toUpperCase() + part.slice(1) : part))
    .join(" ");
}

interface SlimPersonRecord {
  slug: string;
  name: string;
  org: string | null;
  role: string | null;
  location: string | null;
  tags: string[];
  tier: string | null;
  last_interaction: string | null;
  touchpoints: number;
  source: string;
}

function toSlim(slug: string, entry: IndexEntry, reader: StoreReader): SlimPersonRecord {
  const stats = reader.stats().people[slug];
  return {
    slug,
    name: nameFromSlug(slug),
    org: entry.org,
    role: entry.role,
    location: entry.location,
    tags: entry.tags,
    tier: stats?.tier ?? null,
    last_interaction: stats?.last_interaction ?? null,
    touchpoints: stats?.touchpoints ?? 0,
    source: `people/${slug}.md`,
  };
}

function includesCI(haystack: string | null | undefined, needle: string): boolean {
  if (!haystack) return false;
  return haystack.toLowerCase().includes(needle.toLowerCase());
}

function hasAllTags(entryTags: string[], wanted: string[]): boolean {
  const lowered = entryTags.map((t) => t.toLowerCase());
  return wanted.every((t) => lowered.includes(t.toLowerCase()));
}

function matchesText(slug: string, entry: IndexEntry, text: string): boolean {
  const haystacks = [slug, entry.org, entry.role, entry.location, ...entry.tags];
  return haystacks.some((h) => includesCI(h ?? null, text));
}

export interface SearchPeopleArgs {
  tags?: string[];
  org?: string;
  role?: string;
  location?: string;
  tier?: string;
  text?: string;
  page?: number;
}

/** Filters `index()` by the given criteria; returns matching slugs (index order). */
function filterSlugs(
  index: Record<string, IndexEntry>,
  reader: StoreReader,
  args: SearchPeopleArgs,
): string[] {
  return Object.entries(index)
    .filter(([slug, entry]) => {
      if (args.tags && args.tags.length > 0 && !hasAllTags(entry.tags, args.tags)) {
        return false;
      }
      if (args.org && !includesCI(entry.org, args.org)) return false;
      if (args.role && !includesCI(entry.role, args.role)) return false;
      if (args.location && !includesCI(entry.location, args.location)) return false;
      if (args.tier) {
        const statsTier = reader.stats().people[slug]?.tier ?? null;
        if ((statsTier ?? "").toLowerCase() !== args.tier.toLowerCase()) return false;
      }
      if (args.text && !matchesText(slug, entry, args.text)) return false;
      return true;
    })
    .map(([slug]) => slug);
}

/**
 * Up to `MAX_NEIGHBORS` people who share ANY of the requested tag/org/
 * location (never `text` — that's not a structured facet), excluding
 * `exclude`. Used only on the no-match path, per the honesty rule: no
 * invented people, just a pointer to what IS in the store.
 */
function nearestNeighbors(
  index: Record<string, IndexEntry>,
  args: SearchPeopleArgs,
  exclude: Set<string>,
): string[] {
  const wantedTags = (args.tags ?? []).map((t) => t.toLowerCase());
  const wantedOrg = args.org?.toLowerCase();
  const wantedLocation = args.location?.toLowerCase();

  if (wantedTags.length === 0 && !wantedOrg && !wantedLocation) return [];

  const neighbors: string[] = [];
  for (const [slug, entry] of Object.entries(index)) {
    if (exclude.has(slug)) continue;
    const sharesTag = entry.tags.some((t) => wantedTags.includes(t.toLowerCase()));
    const sharesOrg = wantedOrg !== undefined && includesCI(entry.org, args.org ?? "");
    const sharesLocation =
      wantedLocation !== undefined && includesCI(entry.location, args.location ?? "");
    if (sharesTag || sharesOrg || sharesLocation) {
      neighbors.push(slug);
      if (neighbors.length >= MAX_NEIGHBORS) break;
    }
  }
  return neighbors;
}

export function searchPeople(reader: StoreReader, args: SearchPeopleArgs): object {
  const index = reader.index();
  const page = args.page && args.page > 0 ? Math.floor(args.page) : 1;

  const matchedSlugs = filterSlugs(index, reader, args);
  const total = matchedSlugs.length;
  const start = (page - 1) * PAGE_SIZE;
  const pageSlugs = matchedSlugs.slice(start, start + PAGE_SIZE);
  const results = pageSlugs.map((slug) => toSlim(slug, index[slug], reader));

  const base = {
    generated_at: reader.generatedAt,
    query: args,
    total,
    page,
    page_size: PAGE_SIZE,
    results,
  };

  if (total === 0) {
    return {
      ...base,
      no_match: true,
      message: "No people in the store match this search.",
      suggestions: nearestNeighbors(index, args, new Set()),
    };
  }

  return base;
}

const inputSchema = {
  tags: z.array(z.string()).optional().describe("All-of match against person.tags"),
  org: z.string().optional().describe("Case-insensitive substring match on org"),
  role: z.string().optional().describe("Case-insensitive substring match on role"),
  location: z.string().optional().describe("Case-insensitive substring match on location"),
  tier: z.string().optional().describe("Exact match on tier (e.g. close, active)"),
  text: z
    .string()
    .optional()
    .describe("Case-insensitive free-text match across tags/org/role/location/slug"),
  page: z.number().int().positive().optional().describe("1-based page number, page size 25"),
};

export function registerSearchPeople(server: McpServer, reader: StoreReader): void {
  server.registerTool(
    "search_people",
    {
      title: "Search people",
      description:
        "Filter/free-text search over the people store's index+stats. Returns slim " +
        "records (slug, name, org, role, location, tags, tier, last_interaction, " +
        "touchpoints) with source citations, paginated 25 per page. Read-only; " +
        "never invents a person — an empty match reports 'no match' plus up to 5 " +
        "nearest-neighbor suggestions.",
      inputSchema,
    },
    (args) => {
      const result = searchPeople(reader, args);
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    },
  );
}

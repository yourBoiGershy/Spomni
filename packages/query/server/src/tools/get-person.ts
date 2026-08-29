// Tool: get_person — full person record by slug, per
// docs/plans/2026-08-29-08-chat-mcp-query-layer.md's "MCP tool surface".
// Provenance tags (`**[told-by-user]**` / `**[inferred-public-web]**`) are
// carried VERBATIM in each section's bullets — reader.ts already splits
// sections without touching bullet text, so this module just forwards them.
// Read-only: only ever calls `reader.getPerson()` / `reader.index()` /
// `reader.stats()`.

import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { StoreReader } from "../store/reader.ts";

const MAX_SUGGESTIONS = 5;

/** Plain Levenshtein distance — "edit-distance-lite" per the brief: no
 * transposition handling, no weighting, just enough to rank near-miss slugs. */
function levenshtein(a: string, b: string): number {
  const rows = a.length + 1;
  const cols = b.length + 1;
  const dp: number[][] = Array.from({ length: rows }, () => new Array<number>(cols).fill(0));
  for (let i = 0; i < rows; i++) dp[i][0] = i;
  for (let j = 0; j < cols; j++) dp[0][j] = j;
  for (let i = 1; i < rows; i++) {
    for (let j = 1; j < cols; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      dp[i][j] = Math.min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost);
    }
  }
  return dp[rows - 1][cols - 1];
}

/** Up to `MAX_SUGGESTIONS` closest known slugs to `slug`, prefix matches
 * first, then ascending edit distance. Used only on the no-match path. */
function closestSlugs(slug: string, knownSlugs: string[]): string[] {
  const lowered = slug.toLowerCase();
  return knownSlugs
    .map((known) => ({
      known,
      prefix: known.toLowerCase().startsWith(lowered) || lowered.startsWith(known.toLowerCase()),
      distance: levenshtein(lowered, known.toLowerCase()),
    }))
    .sort((a, b) => {
      if (a.prefix !== b.prefix) return a.prefix ? -1 : 1;
      return a.distance - b.distance;
    })
    .slice(0, MAX_SUGGESTIONS)
    .map((entry) => entry.known);
}

export function getPerson(reader: StoreReader, slug: string): object {
  const person = reader.getPerson(slug);

  if (!person) {
    const knownSlugs = Object.keys(reader.index());
    return {
      generated_at: reader.generatedAt,
      error: "not_found",
      slug,
      message: `No person found at people/${slug}.md.`,
      suggestions: closestSlugs(slug, knownSlugs),
    };
  }

  const stats = reader.stats().people[slug] ?? null;

  return {
    generated_at: reader.generatedAt,
    slug,
    source: person.sourcePath.includes("people/")
      ? `people/${slug}.md`
      : person.sourcePath,
    frontmatter: person.frontmatter,
    sections: person.sections,
    stats,
  };
}

const inputSchema = {
  slug: z.string().describe("The person's slug, matching people/<slug>.md"),
};

export function registerGetPerson(server: McpServer, reader: StoreReader): void {
  server.registerTool(
    "get_person",
    {
      title: "Get person",
      description:
        "Full record for one person: frontmatter, the Facts/Open threads/Personal " +
        "details sections with provenance tags intact, and the stats.json rollup. " +
        "Cites people/<slug>.md. Read-only; an unknown slug returns an error-shaped " +
        "result naming the slug and up to 5 closest known slugs, never a guess.",
      inputSchema,
    },
    ({ slug }) => {
      const result = getPerson(reader, slug);
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    },
  );
}

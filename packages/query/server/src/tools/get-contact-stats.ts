// Tool: get_contact_stats — the stats.json rollup for one person: touchpoint
// count, first/last interaction (computed), median gap, open threads,
// commitments, plus a calendar-vs-not split computed here from the
// person's `interactions` list (packages/core/contracts/derived-index.md).
// Read-only: only ever calls `reader.stats()`, never writes.

import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { StoreReader } from "../store/reader.ts";

export function getContactStats(reader: StoreReader, slug: string): object {
  const stats = reader.stats();
  const entry = stats.people[slug];

  if (!entry) {
    return {
      generated_at: reader.generatedAt,
      error: "not_found",
      slug,
      message: `No person found at people/${slug}.md.`,
    };
  }

  const calendarCount = entry.interactions.filter((i) => i.calendar).length;
  const nonCalendarCount = entry.interactions.length - calendarCount;

  return {
    generated_at: reader.generatedAt,
    slug,
    tier: entry.tier,
    touchpoints: entry.touchpoints,
    first_interaction: entry.first_interaction,
    last_interaction: entry.last_interaction,
    median_gap_days: entry.median_gap_days,
    open_threads: entry.open_threads,
    commitments: entry.commitments,
    calendar_split: { calendar: calendarCount, non_calendar: nonCalendarCount },
    sources: [`people/${slug}.md`, "stats.json (derived from interactions/*.md)"],
  };
}

const inputSchema = {
  slug: z.string().describe("Person slug, e.g. 'grace-lindqvist'."),
};

export function registerGetContactStats(server: McpServer, reader: StoreReader): void {
  server.registerTool(
    "get_contact_stats",
    {
      title: "Get contact stats",
      description:
        "The stats.json rollup for one person: touchpoints, first/last interaction " +
        "(computed), median gap in days, open threads, commitments, and a " +
        "calendar-vs-not split derived from their interaction list. Cites " +
        "people/<slug>.md and stats.json. An unknown slug returns an error-shaped " +
        "result naming the slug.",
      inputSchema,
    },
    ({ slug }) => {
      const result = getContactStats(reader, slug);
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    },
  );
}

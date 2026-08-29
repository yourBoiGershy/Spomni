// Tool: list_interactions — newest-first paginated interaction history for
// one person, sourced from stats.json's per-person `interactions` list
// (packages/core/contracts/derived-index.md). Excerpts each interaction's
// `## Summary` section to ~300 chars rather than returning the full body —
// full detail lives behind `get_interaction` (size discipline, plan 08's
// "MCP tool surface" section). Read-only: only ever calls StoreReader
// methods, never writes.

import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { StoreReader } from "../store/reader.ts";

const PAGE_SIZE = 10;
const SUMMARY_EXCERPT_CHARS = 300;

/** First ~300 chars of an interaction's `## Summary` section, trimmed on a
 * word boundary where possible and marked with `…` when truncated. */
function excerptSummary(reader: StoreReader, id: string): string {
  const interaction = reader.getInteraction(id);
  if (!interaction) return "";
  const summary = interaction.sections.find((s) => s.heading === "Summary");
  const raw = summary?.raw ?? "";
  if (raw.length <= SUMMARY_EXCERPT_CHARS) return raw;
  const cut = raw.slice(0, SUMMARY_EXCERPT_CHARS);
  const lastSpace = cut.lastIndexOf(" ");
  const trimmed = lastSpace > 0 ? cut.slice(0, lastSpace) : cut;
  return `${trimmed}…`;
}

export function listInteractions(reader: StoreReader, slug: string, page = 1): object {
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

  const total = entry.interactions.length;
  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const start = (page - 1) * PAGE_SIZE;
  const pageItems = entry.interactions.slice(start, start + PAGE_SIZE);

  const interactions = pageItems.map((ref) => ({
    id: ref.id,
    date: ref.date,
    others: ref.others,
    calendar: ref.calendar,
    summary_excerpt: excerptSummary(reader, ref.id),
    source: `interactions/${ref.id}.md`,
  }));

  return {
    generated_at: reader.generatedAt,
    slug,
    page,
    page_size: PAGE_SIZE,
    total,
    total_pages: totalPages,
    interactions,
  };
}

const inputSchema = {
  slug: z.string().describe("Person slug, e.g. 'grace-lindqvist'."),
  page: z
    .number()
    .int()
    .min(1)
    .optional()
    .describe("1-based page number; defaults to 1."),
};

export function registerListInteractions(server: McpServer, reader: StoreReader): void {
  server.registerTool(
    "list_interactions",
    {
      title: "List interactions",
      description:
        "Newest-first, paginated list of a person's filed interactions (id, date, " +
        "co-participants, calendar flag, ~300-char summary excerpt). Page size 10. " +
        "A person with zero filed interactions returns an empty list, not an error; " +
        "an unknown slug returns an error-shaped result naming the slug.",
      inputSchema,
    },
    ({ slug, page }) => {
      const result = listInteractions(reader, slug, page ?? 1);
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    },
  );
}

// Tool: get_interaction — full detail for a single filed interaction (the
// counterpart to list_interactions' excerpted rows): complete frontmatter
// plus the full `## Summary` and `## Commitments` sections, verbatim.
// Read-only: only ever calls `reader.getInteraction()`, never writes.

import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { StoreReader } from "../store/reader.ts";
import type { BodySection } from "../store/types.ts";

function section(sections: BodySection[], heading: string): BodySection {
  return (
    sections.find((s) => s.heading === heading) ?? { heading, raw: "", bullets: [] }
  );
}

export function getInteraction(reader: StoreReader, id: string): object {
  const interaction = reader.getInteraction(id);

  if (!interaction) {
    return {
      generated_at: reader.generatedAt,
      error: "not_found",
      id,
      message: `No interaction found at interactions/${id}.md.`,
    };
  }

  return {
    generated_at: reader.generatedAt,
    id: interaction.id,
    frontmatter: interaction.frontmatter,
    summary: section(interaction.sections, "Summary"),
    commitments: section(interaction.sections, "Commitments"),
    source: `interactions/${interaction.id}.md`,
  };
}

const inputSchema = {
  id: z
    .string()
    .describe("Interaction id / filename stem, e.g. '2026-07-20-combs-family-reunion'."),
};

export function registerGetInteraction(server: McpServer, reader: StoreReader): void {
  server.registerTool(
    "get_interaction",
    {
      title: "Get interaction",
      description:
        "Full record for one filed interaction: frontmatter plus the complete " +
        "Summary and Commitments sections, verbatim. Cites the source file. " +
        "An unknown id returns an error-shaped result naming the id.",
      inputSchema,
    },
    ({ id }) => {
      const result = getInteraction(reader, id);
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    },
  );
}

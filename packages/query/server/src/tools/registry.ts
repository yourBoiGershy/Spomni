// Tool registry — the single place tool handlers are wired into the MCP
// server. Wave C workers register `search_people`, `get_person`,
// `list_interactions`, `get_interaction`, `get_contact_stats`, and
// `suggest_reachouts` here (see
// docs/plans/2026-08-29-08-chat-mcp-query-layer.md). The entry point only
// ever imports `registerTools` — it never knows about individual tool
// modules, and tool modules never import the transport.

import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { StoreReader } from "../store/reader.ts";
import { registerSearchPeople } from "./search-people.ts";
import { registerGetPerson } from "./get-person.ts";
import { registerSuggestReachouts } from "./suggest-reachouts.ts";
import { registerListInteractions } from "./list-interactions.ts";
import { registerGetInteraction } from "./get-interaction.ts";
import { registerGetContactStats } from "./get-contact-stats.ts";

/**
 * A registrar calls `server.registerTool(...)` for exactly one tool. Each
 * Wave C tool module exports one of these and appends it to `registrars`
 * below. `reader` is the single in-memory `StoreReader` built once at
 * startup (src/index.ts) — tools close over it via this parameter rather
 * than re-deriving their own.
 */
export type ToolRegistrar = (server: McpServer, reader: StoreReader) => void;

export const registrars: ToolRegistrar[] = [
  registerSearchPeople,
  registerGetPerson,
  registerListInteractions,
  registerGetInteraction,
  registerGetContactStats,
  registerSuggestReachouts,
];

/** Runs every registered tool registrar against `server`. */
export function registerTools(server: McpServer, reader: StoreReader): void {
  for (const register of registrars) {
    register(server, reader);
  }

  // Advertise the tools capability (and answer tools/list with []) even
  // before any tool is registered — registerTool() would do this lazily on
  // first call, but an empty registry never calls it.
  server.setToolRequestHandlers();
}

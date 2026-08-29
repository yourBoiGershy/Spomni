// Tool registry — the single place tool handlers are wired into the MCP
// server. Wave C workers register `search_people`, `get_person`,
// `list_interactions`, `get_interaction`, `get_contact_stats`, and
// `suggest_reachouts` here (see
// docs/plans/2026-08-29-08-chat-mcp-query-layer.md). The entry point only
// ever imports `registerTools` — it never knows about individual tool
// modules, and tool modules never import the transport.

import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

/**
 * A registrar calls `server.registerTool(...)` for exactly one tool. Each
 * Wave C tool module exports one of these and appends it to `registrars`
 * below.
 */
export type ToolRegistrar = (server: McpServer) => void;

// Empty until Wave C lands the six read-only tools.
export const registrars: ToolRegistrar[] = [];

/** Runs every registered tool registrar against `server`. */
export function registerTools(server: McpServer): void {
  for (const register of registrars) {
    register(server);
  }

  // Advertise the tools capability (and answer tools/list with []) even
  // before any tool is registered — registerTool() would do this lazily on
  // first call, but an empty registry never calls it.
  server.setToolRequestHandlers();
}

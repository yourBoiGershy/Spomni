// Transport seam — the one file that knows how the MCP server is wired to the
// outside world. Tools and the store-reader never import this module; only
// src/index.ts does. This isolation is what lets the later remote-infra
// stream swap in streamable HTTP (behind --http) without touching tool code.

import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

export interface TransportOptions {
  http: boolean;
}

/**
 * Connects `server` to its transport and resolves once the connection is
 * live. Stdio is the only implemented transport today; `--http` is a stub
 * reserved for the remote-infra stream.
 */
export async function connectTransport(
  server: McpServer,
  options: TransportOptions,
): Promise<void> {
  if (options.http) {
    // Reserved for the remote-infra stream. Deliberately not implemented
    // here so --http fails loudly instead of silently falling back to stdio.
    process.stderr.write("HTTP transport not yet implemented\n");
    process.exit(1);
  }

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

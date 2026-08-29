#!/usr/bin/env node
// Entry point for the relationship-agent query MCP server.
//
// Scaffold only (docs/plans/2026-08-29-08-chat-mcp-query-layer.md, unit 3):
// parses --store / RA_STORE_DIR, constructs the MCP server, registers the
// (currently empty) tool registry, and connects the stdio transport. No
// store reading and no tool logic live here — that lands in Waves B/C.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { registerTools } from "./tools/registry.ts";
import { connectTransport } from "./transport.ts";

interface Cli {
  storeDir: string;
  http: boolean;
}

function parseArgs(argv: string[]): Cli {
  let storeDir: string | undefined;
  let http = false;

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--store") {
      storeDir = argv[++i];
    } else if (arg.startsWith("--store=")) {
      storeDir = arg.slice("--store=".length);
    } else if (arg === "--http") {
      http = true;
    }
  }

  storeDir ??= process.env.RA_STORE_DIR;

  if (!storeDir) {
    process.stderr.write(
      "relationship-agent-query: missing store directory. Pass --store <dir> or set RA_STORE_DIR.\n",
    );
    process.exit(1);
  }

  return { storeDir, http };
}

async function main(): Promise<void> {
  const { http } = parseArgs(process.argv.slice(2));

  const server = new McpServer({
    name: "relationship-agent-query",
    version: "0.1.0",
  });

  registerTools(server);

  await connectTransport(server, { http });
}

main().catch((err: unknown) => {
  process.stderr.write(`relationship-agent-query: fatal error: ${String(err)}\n`);
  process.exit(1);
});

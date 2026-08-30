#!/usr/bin/env node
// Entry point for the spomni-query MCP server.
//
// Scaffold (docs/plans/2026-08-29-08-chat-mcp-query-layer.md, unit 3) plus
// store-reader wiring from unit 6: parses --store / SPOMNI_STORE_DIR
// (RA_STORE_DIR deprecated fallback), ensures a fresh store-reader is
// available, constructs the MCP server, registers the tool registry (Wave C
// fills it in), and connects the stdio transport.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { registerTools } from "./tools/registry.ts";
import { connectTransport } from "./transport.ts";
import { ensureFresh } from "./store/staleness.ts";

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

  storeDir ??= process.env.SPOMNI_STORE_DIR ?? process.env.RA_STORE_DIR;

  if (!storeDir) {
    process.stderr.write(
      "spomni-query: missing store directory. Pass --store <dir> or set SPOMNI_STORE_DIR.\n",
    );
    process.exit(1);
  }

  return { storeDir, http };
}

async function main(): Promise<void> {
  const { storeDir, http } = parseArgs(process.argv.slice(2));

  const { reader, generatedAt } = ensureFresh(storeDir);
  process.stderr.write(
    `spomni-query: store ready (generated_at=${generatedAt}, stale=${String(reader.stale)})\n`,
  );

  const server = new McpServer({
    name: "spomni-query",
    version: "0.1.0",
  });

  registerTools(server, reader);

  await connectTransport(server, { http });
}

main().catch((err: unknown) => {
  process.stderr.write(`spomni-query: fatal error: ${String(err)}\n`);
  process.exit(1);
});

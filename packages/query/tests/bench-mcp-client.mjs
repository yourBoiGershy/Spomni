#!/usr/bin/env node
// bench-mcp-client.mjs — minimal JSON-RPC-over-stdio timing client for the
// spomni-query MCP server, used by bench-retrieval.sh (packages/query/tests/)
// to time rows 6-8 of docs/plans/2026-08-30-38-retrieval-speed.md §1/§2:
// cold-start-to-initialize and warm per-tool latency (median of N calls).
//
// Usage: node bench-mcp-client.mjs <store-dir> [warm-calls-per-tool]
//
// Speaks newline-delimited JSON-RPC directly (no MCP SDK dependency) so this
// works even in environments where only the server's own node_modules are
// installed. Spawns `node --experimental-strip-types
// packages/query/server/src/index.ts --store <store-dir>` from the repo
// root, times spawn -> initialize response (cold_start_ms), then times
// tools/call for search_people, get_person, suggest_reachouts and
// upcoming_meetings (median of `warm-calls-per-tool`, default 20).
//
// Prints one JSON object to stdout: {cold_start_ms, tools: {name: median_ms}}
// Exits 0 on success, 1 on any RPC/timeout error. Read-only: never writes to
// the store.

import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "../../..");
const SERVER_ENTRY = path.join(REPO_ROOT, "packages/query/server/src/index.ts");

const storeDir = process.argv[2];
const warmCalls = parseInt(process.argv[3] || "20", 10);

if (!storeDir) {
  process.stderr.write("Usage: bench-mcp-client.mjs <store-dir> [warm-calls-per-tool]\n");
  process.exit(2);
}

function median(nums) {
  const sorted = [...nums].sort((a, b) => a - b);
  const n = sorted.length;
  if (n === 0) return null;
  return n % 2 === 1 ? sorted[(n - 1) / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
}

function firstSlug(storeDir) {
  const indexPath = path.join(storeDir, "index.json");
  try {
    const idx = JSON.parse(fs.readFileSync(indexPath, "utf8"));
    const slugs = Object.keys(idx.people || idx);
    if (slugs.length > 0) return slugs[0];
  } catch {
    // fall through
  }
  const peopleDir = path.join(storeDir, "people");
  const files = fs.readdirSync(peopleDir).filter((f) => f.endsWith(".md"));
  if (files.length === 0) throw new Error("no people/*.md to pick a slug from");
  return files[0].slice(0, -3);
}

async function main() {
  const t0 = Date.now();
  const p = spawn("node", ["--experimental-strip-types", SERVER_ENTRY, "--store", storeDir], {
    cwd: REPO_ROOT,
    stdio: ["pipe", "pipe", "pipe"],
  });

  let buf = "";
  const pending = new Map();
  let id = 0;
  let stderrBuf = "";

  p.stderr.on("data", (d) => {
    stderrBuf += d.toString();
  });

  p.stdout.on("data", (d) => {
    buf += d.toString();
    let i;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      if (!line.trim()) continue;
      try {
        const m = JSON.parse(line);
        if (m.id !== undefined && pending.has(m.id)) {
          pending.get(m.id)(m);
          pending.delete(m.id);
        }
      } catch {
        // ignore non-JSON lines (e.g. log noise on stdout)
      }
    }
  });

  const call = (method, params) =>
    new Promise((resolve, reject) => {
      const m = { jsonrpc: "2.0", id: ++id, method, params };
      const timer = setTimeout(() => {
        pending.delete(m.id);
        reject(new Error(`timeout waiting for ${method} response`));
      }, 15000);
      pending.set(m.id, (resp) => {
        clearTimeout(timer);
        resolve(resp);
      });
      p.stdin.write(JSON.stringify(m) + "\n");
    });

  const notify = (method, params) => {
    p.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\n");
  };

  const tool = (name, args) => call("tools/call", { name, arguments: args });

  try {
    await call("initialize", {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "bench-retrieval", version: "0.1.0" },
    });
    const coldStartMs = Date.now() - t0;
    notify("notifications/initialized", {});

    const slug = firstSlug(storeDir);

    const specs = [
      { name: "search_people", args: { text: "a" } },
      { name: "get_person", args: { slug } },
      { name: "suggest_reachouts", args: { limit: 5 } },
      { name: "upcoming_meetings", args: {} },
    ];

    const tools = {};
    for (const spec of specs) {
      const timings = [];
      for (let i = 0; i < warmCalls; i++) {
        const start = Date.now();
        await tool(spec.name, spec.args);
        timings.push(Date.now() - start);
      }
      tools[spec.name] = median(timings);
    }

    process.stdout.write(JSON.stringify({ cold_start_ms: coldStartMs, tools }) + "\n");
    p.kill();
    process.exit(0);
  } catch (err) {
    process.stderr.write(`bench-mcp-client: ${err instanceof Error ? err.message : String(err)}\n`);
    if (stderrBuf) process.stderr.write(`server stderr:\n${stderrBuf}\n`);
    try {
      p.kill();
    } catch {
      // best-effort
    }
    process.exit(1);
  }
}

main();

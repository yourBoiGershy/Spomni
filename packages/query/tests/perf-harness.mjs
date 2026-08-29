#!/usr/bin/env node
// perf-harness.mjs — performance envelope check for the query MCP server,
// per docs/plans/2026-08-29-08-chat-mcp-query-layer.md "Performance envelope"
// (BINDING targets):
//   - build-stats.sh full regeneration < 5s
//   - warm tool latency p95 < 200ms (get_person p95 < 100ms)
//   - server startup-to-initialized < 1s
//
// Generates a scratch 1000-person / ~10k-interaction store via
// packages/core/scripts/gen-scale-store.sh, times build-stats.sh (3 runs),
// times server startup (spawn -> MCP initialize response) via the MCP SDK's
// stdio client transport, and times >=50 warm calls per tool. Prints a
// numbers table, PASS/FAIL per target, and exits 0 only if every target is
// met. Cleans up its scratch store on exit (success or failure).
//
// Usage: node packages/query/tests/perf-harness.mjs
// (invoked by run-perf.sh, which also makes it executable from a shell)

import { execFileSync, spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "../../..");
const CORE_SCRIPTS_DIR = path.join(REPO_ROOT, "packages/core/scripts");
const SERVER_DIR = path.join(REPO_ROOT, "packages/query/server");
const SERVER_ENTRY = path.join(SERVER_DIR, "src/index.ts");

// The MCP SDK client is only installed under packages/query/server/
// node_modules/ (this tests/ dir has no package.json of its own); resolve it
// there via createRequire (CJS build) rather than a bare ESM import, which
// would only walk up from this file's own directory.
const serverRequire = createRequire(path.join(SERVER_DIR, "package.json"));
const { Client } = serverRequire("@modelcontextprotocol/sdk/client/index.js");
const { StdioClientTransport } = serverRequire("@modelcontextprotocol/sdk/client/stdio.js");

const PEOPLE_COUNT = 1000;
const BUILD_STATS_RUNS = 3;
const WARM_CALLS_PER_TOOL = 50;

const TARGETS = {
  buildStatsMs: 5000,
  serverStartupMs: 1000,
  warmP95Ms: 200,
  getPersonP95Ms: 100,
};

function log(msg) {
  process.stderr.write(`${msg}\n`);
}

function nowMs() {
  return performance.now();
}

function fmt(ms) {
  return `${ms.toFixed(1)}ms`;
}

function median(nums) {
  const sorted = [...nums].sort((a, b) => a - b);
  const n = sorted.length;
  if (n === 0) return NaN;
  return n % 2 === 1 ? sorted[(n - 1) / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
}

function percentile(nums, p) {
  const sorted = [...nums].sort((a, b) => a - b);
  if (sorted.length === 0) return NaN;
  const idx = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return sorted[Math.max(0, idx)];
}

// ---------------------------------------------------------------------------
// Scratch store generation
// ---------------------------------------------------------------------------

function makeScratchDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "ra-perf-store-"));
}

function genStore(storeDir) {
  log(`generating ${PEOPLE_COUNT}-person store at ${storeDir} ...`);
  const start = nowMs();
  execFileSync("bash", [path.join(CORE_SCRIPTS_DIR, "gen-scale-store.sh"), storeDir, String(PEOPLE_COUNT)], {
    stdio: ["ignore", "pipe", "inherit"],
  });
  const elapsed = nowMs() - start;
  log(`generation done in ${fmt(elapsed)}`);
}

// ---------------------------------------------------------------------------
// build-stats.sh timing
// ---------------------------------------------------------------------------

function runBuildStatsOnce(storeDir) {
  const start = nowMs();
  const result = spawnSync("bash", [path.join(CORE_SCRIPTS_DIR, "build-stats.sh"), storeDir], {
    encoding: "utf8",
  });
  const elapsed = nowMs() - start;
  if (result.status !== 0) {
    throw new Error(`build-stats.sh failed (exit ${String(result.status)}): ${result.stderr}`);
  }
  return elapsed;
}

function runBuildIndexOnce(storeDir) {
  const result = spawnSync("bash", [path.join(CORE_SCRIPTS_DIR, "build-index.sh"), storeDir], {
    encoding: "utf8",
  });
  if (result.status !== 0) {
    throw new Error(`build-index.sh failed (exit ${String(result.status)}): ${result.stderr}`);
  }
}

// ---------------------------------------------------------------------------
// Server startup + warm-latency measurement, via the real MCP stdio client
// ---------------------------------------------------------------------------

async function measureStartupAndConnect(storeDir) {
  const transport = new StdioClientTransport({
    command: "node",
    args: ["--experimental-strip-types", SERVER_ENTRY, "--store", storeDir],
    stderr: "pipe",
  });
  const client = new Client({ name: "perf-harness", version: "0.1.0" });

  const start = nowMs();
  await client.connect(transport);
  const elapsed = nowMs() - start;

  return { client, transport, elapsed };
}

async function timeCall(client, name, args) {
  const start = nowMs();
  const result = await client.callTool({ name, arguments: args });
  const elapsed = nowMs() - start;
  if (result.isError) {
    throw new Error(`tool ${name} returned isError: ${JSON.stringify(result)}`);
  }
  return elapsed;
}

async function runWarmCalls(client, name, argsList, count) {
  const timings = [];
  for (let i = 0; i < count; i++) {
    const args = argsList[i % argsList.length];
    timings.push(await timeCall(client, name, args));
  }
  return timings;
}

function loadSlugs(storeDir) {
  const peopleDir = path.join(storeDir, "people");
  return fs
    .readdirSync(peopleDir)
    .filter((f) => f.endsWith(".md"))
    .map((f) => f.slice(0, -3))
    .sort();
}

function sample(arr, n) {
  const out = [];
  for (let i = 0; i < n; i++) out.push(arr[(i * 37) % arr.length]);
  return out;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  let storeDir;
  let client;
  let transport;
  const results = {};
  let allPass = true;

  try {
    storeDir = makeScratchDir();
    fs.rmdirSync(storeDir); // gen-scale-store.sh refuses to write into an existing dir
    genStore(storeDir);

    // (a) build-stats.sh timing — 3 runs, report each + median. build-index.sh
    // runs once first (untimed, out of scope of the envelope target) so the
    // store has a valid index.json alongside stats.json for the later server
    // startup measurement.
    runBuildIndexOnce(storeDir);
    const buildStatsTimings = [];
    for (let i = 0; i < BUILD_STATS_RUNS; i++) {
      const elapsed = runBuildStatsOnce(storeDir);
      buildStatsTimings.push(elapsed);
      log(`build-stats.sh run ${String(i + 1)}: ${fmt(elapsed)}`);
    }
    results.buildStats = {
      runs: buildStatsTimings,
      median: median(buildStatsTimings),
    };

    // (b) server startup-to-initialized. index.json/stats.json are already
    // fresh in storeDir (last build-stats.sh run above), so ensureFresh()
    // serves them directly rather than regenerating on this timed run.
    const connected = await measureStartupAndConnect(storeDir);
    client = connected.client;
    transport = connected.transport;
    results.startup = { ms: connected.elapsed };
    log(`server startup-to-initialized: ${fmt(connected.elapsed)}`);

    // (c) warm latencies, >=50 calls per tool.
    const slugs = loadSlugs(storeDir);
    const personSlugs = sample(slugs, WARM_CALLS_PER_TOOL);

    const orgs = ["Meridian Fintech", "Cascade Cloud", "Vega Textiles", "Kestrel Robotics", "Orbital Labs"];
    const tiers = ["inner-circle", "close", "active", "dormant"];
    const tags = ["work", "business", "founder", "friend", "family"];
    const searchArgsList = Array.from({ length: WARM_CALLS_PER_TOOL }, (_, i) => {
      const mod = i % 4;
      if (mod === 0) return { org: orgs[i % orgs.length] };
      if (mod === 1) return { tier: tiers[i % tiers.length] };
      if (mod === 2) return { tags: [tags[i % tags.length]] };
      return { text: slugs[i % slugs.length].split("-")[0] };
    });

    const warmSpecs = [
      { name: "search_people", argsList: searchArgsList },
      { name: "get_person", argsList: personSlugs.map((slug) => ({ slug })) },
      { name: "list_interactions", argsList: personSlugs.map((slug) => ({ slug })) },
      { name: "get_contact_stats", argsList: personSlugs.map((slug) => ({ slug })) },
      {
        name: "suggest_reachouts",
        argsList: Array.from({ length: WARM_CALLS_PER_TOOL }, (_, i) => ({
          limit: 1 + (i % 10),
        })),
      },
    ];

    for (const spec of warmSpecs) {
      const timings = await runWarmCalls(client, spec.name, spec.argsList, WARM_CALLS_PER_TOOL);
      results[spec.name] = {
        n: timings.length,
        p50: median(timings),
        p95: percentile(timings, 95),
        max: Math.max(...timings),
      };
      log(
        `${spec.name}: n=${String(timings.length)} p50=${fmt(results[spec.name].p50)} ` +
          `p95=${fmt(results[spec.name].p95)} max=${fmt(results[spec.name].max)}`,
      );
    }

    // ------------------------------------------------------------------
    // Report
    // ------------------------------------------------------------------

    const rows = [];
    const buildStatsPass = results.buildStats.median < TARGETS.buildStatsMs;
    rows.push([
      "build-stats.sh regen (median of 3)",
      fmt(results.buildStats.median),
      `< ${String(TARGETS.buildStatsMs)}ms`,
      buildStatsPass ? "PASS" : "FAIL",
    ]);
    allPass &&= buildStatsPass;

    const startupPass = results.startup.ms < TARGETS.serverStartupMs;
    rows.push([
      "server startup-to-initialized",
      fmt(results.startup.ms),
      `< ${String(TARGETS.serverStartupMs)}ms`,
      startupPass ? "PASS" : "FAIL",
    ]);
    allPass &&= startupPass;

    for (const spec of warmSpecs) {
      const r = results[spec.name];
      const target = spec.name === "get_person" ? TARGETS.getPersonP95Ms : TARGETS.warmP95Ms;
      const pass = r.p95 < target;
      rows.push([
        `${spec.name} p95 (n=${String(r.n)}, p50=${fmt(r.p50)}, max=${fmt(r.max)})`,
        fmt(r.p95),
        `< ${String(target)}ms`,
        pass ? "PASS" : "FAIL",
      ]);
      allPass &&= pass;
    }

    const colWidths = [0, 0, 0, 0];
    const header = ["measurement", "value", "target", "result"];
    for (const row of [header, ...rows]) {
      row.forEach((cell, i) => {
        colWidths[i] = Math.max(colWidths[i], String(cell).length);
      });
    }
    function printRow(row) {
      process.stdout.write(row.map((cell, i) => String(cell).padEnd(colWidths[i])).join("  ") + "\n");
    }

    process.stdout.write("\n=== Performance envelope (1000-person store) ===\n\n");
    printRow(header);
    printRow(colWidths.map((w) => "-".repeat(w)));
    for (const row of rows) printRow(row);

    process.stdout.write(
      `\nSUMMARY: ${allPass ? "ALL TARGETS MET" : "ONE OR MORE TARGETS MISSED"}\n`,
    );

    return allPass ? 0 : 1;
  } finally {
    try {
      if (transport) await transport.close();
    } catch {
      // best-effort
    }
    if (storeDir && fs.existsSync(storeDir)) {
      fs.rmSync(storeDir, { recursive: true, force: true });
      log(`cleaned up scratch store ${storeDir}`);
    }
  }
}

main()
  .then((code) => {
    process.exit(code);
  })
  .catch((err) => {
    log(`perf-harness: fatal error: ${err instanceof Error ? err.stack : String(err)}`);
    process.exit(1);
  });

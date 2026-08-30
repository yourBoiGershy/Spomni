#!/usr/bin/env node
// perf-harness.mjs — performance envelope check for the query MCP server,
// per docs/plans/2026-08-29-08-chat-mcp-query-layer.md "Performance envelope"
// and docs/plans/2026-08-30-38-retrieval-speed.md unit H (BINDING targets):
//   - build-stats.sh full regeneration < 5s
//   - warm tool latency p95 < 200ms (get_person p95 < 100ms, who_next_pool
//     p95 < 200ms)
//   - server startup-to-initialized < 1s
//   - build-index.sh full regeneration <= 2s
//   - validate-store.sh full <= 8s
//   - scripts/who-next-direct.sh <store> --mode all --limit 20, with
//     index+stats present, <= 2s
//   - server startup-to-initialized with a STALE store copy (one person
//     file touched after index/stats were built), pointed at a fresh empty
//     cache dir, <= 1s (the server serves the stale copy immediately and
//     regenerates in the background — plan 38 unit F)
//
// Generates a scratch 1000-person / ~10k-interaction store via
// packages/core/scripts/gen-scale-store.sh, times build-stats.sh, build-
// index.sh, validate-store.sh and who-next-direct.sh (3 runs each, median),
// times server startup (spawn -> MCP initialize response) via the MCP SDK's
// stdio client transport for both a fresh and an artificially-staled store
// copy, and times >=50 warm calls per tool. Prints a numbers table,
// PASS/FAIL per target, and exits 0 only if every target is met. Cleans up
// its scratch store on exit (success or failure).
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
const QUERY_SCRIPTS_DIR = path.join(REPO_ROOT, "packages/query/scripts");
const SERVER_DIR = path.join(REPO_ROOT, "packages/query/server");
const SERVER_ENTRY = path.join(SERVER_DIR, "src/index.ts");
const WHO_NEXT_DIRECT_SCRIPT = path.join(QUERY_SCRIPTS_DIR, "who-next-direct.sh");

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
  buildIndexMs: 2000,
  validateStoreMs: 8000,
  whoNextDirectMs: 2000,
  staleStartupMs: 1000,
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
  const start = nowMs();
  const result = spawnSync("bash", [path.join(CORE_SCRIPTS_DIR, "build-index.sh"), storeDir], {
    encoding: "utf8",
  });
  const elapsed = nowMs() - start;
  if (result.status !== 0) {
    throw new Error(`build-index.sh failed (exit ${String(result.status)}): ${result.stderr}`);
  }
  return elapsed;
}

function runValidateStoreOnce(storeDir) {
  const start = nowMs();
  const result = spawnSync("bash", [path.join(CORE_SCRIPTS_DIR, "validate-store.sh"), storeDir], {
    encoding: "utf8",
  });
  const elapsed = nowMs() - start;
  if (result.status !== 0) {
    throw new Error(`validate-store.sh failed (exit ${String(result.status)}): ${result.stderr}`);
  }
  return elapsed;
}

function runWhoNextDirectOnce(storeDir) {
  const start = nowMs();
  const result = spawnSync(
    "bash",
    [WHO_NEXT_DIRECT_SCRIPT, storeDir, "--mode", "all", "--limit", "20"],
    { encoding: "utf8" },
  );
  const elapsed = nowMs() - start;
  if (result.status !== 0) {
    throw new Error(`who-next-direct.sh failed (exit ${String(result.status)}): ${result.stderr}`);
  }
  return elapsed;
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

/**
 * Measures server startup-to-initialized against a STALE store copy: one
 * person file's mtime is pushed past index.json/stats.json's generated_at,
 * and the server is pointed at a fresh (empty) SPOMNI_CACHE_DIR so no cached
 * copy can mask the staleness. Per plan 38 unit F, ensureFresh() serves the
 * stale store copy immediately (stale: true) and regenerates in the
 * background, so this should measure close to the fresh-store startup time,
 * not a full build-index.sh + build-stats.sh regeneration.
 */
async function measureStaleStartupAndConnect(storeDir) {
  const peopleDir = path.join(storeDir, "people");
  const [firstPersonFile] = fs.readdirSync(peopleDir).filter((f) => f.endsWith(".md"));
  const staleFuture = new Date(Date.now() + 5000);
  fs.utimesSync(path.join(peopleDir, firstPersonFile), staleFuture, staleFuture);

  const cacheDir = fs.mkdtempSync(path.join(os.tmpdir(), "ra-perf-cache-"));
  try {
    const transport = new StdioClientTransport({
      command: "node",
      args: ["--experimental-strip-types", SERVER_ENTRY, "--store", storeDir],
      env: { SPOMNI_CACHE_DIR: cacheDir },
      stderr: "pipe",
    });
    const client = new Client({ name: "perf-harness-stale", version: "0.1.0" });

    const start = nowMs();
    await client.connect(transport);
    const elapsed = nowMs() - start;

    return { client, transport, elapsed, cacheDir };
  } catch (err) {
    fs.rmSync(cacheDir, { recursive: true, force: true });
    throw err;
  }
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
  let staleClient;
  let staleTransport;
  let staleCacheDir;
  const results = {};
  let allPass = true;

  try {
    storeDir = makeScratchDir();
    fs.rmdirSync(storeDir); // gen-scale-store.sh refuses to write into an existing dir
    genStore(storeDir);

    // (a) build-index.sh timing — 3 runs, report each + median. The last run
    // leaves a valid index.json in the store for the later server startup
    // measurement and for who-next-direct.sh below.
    const buildIndexTimings = [];
    for (let i = 0; i < BUILD_STATS_RUNS; i++) {
      const elapsed = runBuildIndexOnce(storeDir);
      buildIndexTimings.push(elapsed);
      log(`build-index.sh run ${String(i + 1)}: ${fmt(elapsed)}`);
    }
    results.buildIndex = {
      runs: buildIndexTimings,
      median: median(buildIndexTimings),
    };

    // (b) build-stats.sh timing — 3 runs, report each + median.
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

    // (c) validate-store.sh timing — 3 runs, report each + median.
    const validateStoreTimings = [];
    for (let i = 0; i < BUILD_STATS_RUNS; i++) {
      const elapsed = runValidateStoreOnce(storeDir);
      validateStoreTimings.push(elapsed);
      log(`validate-store.sh run ${String(i + 1)}: ${fmt(elapsed)}`);
    }
    results.validateStore = {
      runs: validateStoreTimings,
      median: median(validateStoreTimings),
    };

    // (d) who-next-direct.sh timing — 3 runs, report each + median. index.json
    // and stats.json are already fresh in storeDir from (a)/(b) above.
    const whoNextDirectTimings = [];
    for (let i = 0; i < BUILD_STATS_RUNS; i++) {
      const elapsed = runWhoNextDirectOnce(storeDir);
      whoNextDirectTimings.push(elapsed);
      log(`who-next-direct.sh run ${String(i + 1)}: ${fmt(elapsed)}`);
    }
    results.whoNextDirect = {
      runs: whoNextDirectTimings,
      median: median(whoNextDirectTimings),
    };

    // (e) server startup-to-initialized. index.json/stats.json are already
    // fresh in storeDir (last build-stats.sh run above), so ensureFresh()
    // serves them directly rather than regenerating on this timed run.
    const connected = await measureStartupAndConnect(storeDir);
    client = connected.client;
    transport = connected.transport;
    results.startup = { ms: connected.elapsed };
    log(`server startup-to-initialized: ${fmt(connected.elapsed)}`);

    // (f) server startup-to-initialized against a STALE store copy (one
    // person file touched past index/stats' generated_at) with a fresh,
    // empty SPOMNI_CACHE_DIR, so ensureFresh() must serve the stale copy
    // immediately and regenerate in the background rather than block.
    const staleConnected = await measureStaleStartupAndConnect(storeDir);
    staleClient = staleConnected.client;
    staleTransport = staleConnected.transport;
    staleCacheDir = staleConnected.cacheDir;
    results.staleStartup = { ms: staleConnected.elapsed };
    log(`server startup-to-initialized (stale store): ${fmt(staleConnected.elapsed)}`);
    await staleTransport.close();
    fs.rmSync(staleCacheDir, { recursive: true, force: true });

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
      {
        name: "who_next_pool",
        argsList: Array.from({ length: WARM_CALLS_PER_TOOL }, (_, i) => ({
          mode: ["friends", "coffee", "all"][i % 3],
          limit: 20,
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
    const buildIndexPass = results.buildIndex.median < TARGETS.buildIndexMs;
    rows.push([
      "build-index.sh regen (median of 3)",
      fmt(results.buildIndex.median),
      `< ${String(TARGETS.buildIndexMs)}ms`,
      buildIndexPass ? "PASS" : "FAIL",
    ]);
    allPass &&= buildIndexPass;

    const buildStatsPass = results.buildStats.median < TARGETS.buildStatsMs;
    rows.push([
      "build-stats.sh regen (median of 3)",
      fmt(results.buildStats.median),
      `< ${String(TARGETS.buildStatsMs)}ms`,
      buildStatsPass ? "PASS" : "FAIL",
    ]);
    allPass &&= buildStatsPass;

    const validateStorePass = results.validateStore.median < TARGETS.validateStoreMs;
    rows.push([
      "validate-store.sh full (median of 3)",
      fmt(results.validateStore.median),
      `< ${String(TARGETS.validateStoreMs)}ms`,
      validateStorePass ? "PASS" : "FAIL",
    ]);
    allPass &&= validateStorePass;

    const whoNextDirectPass = results.whoNextDirect.median < TARGETS.whoNextDirectMs;
    rows.push([
      "who-next-direct.sh --mode all --limit 20 (median of 3)",
      fmt(results.whoNextDirect.median),
      `< ${String(TARGETS.whoNextDirectMs)}ms`,
      whoNextDirectPass ? "PASS" : "FAIL",
    ]);
    allPass &&= whoNextDirectPass;

    const startupPass = results.startup.ms < TARGETS.serverStartupMs;
    rows.push([
      "server startup-to-initialized",
      fmt(results.startup.ms),
      `< ${String(TARGETS.serverStartupMs)}ms`,
      startupPass ? "PASS" : "FAIL",
    ]);
    allPass &&= startupPass;

    const staleStartupPass = results.staleStartup.ms < TARGETS.staleStartupMs;
    rows.push([
      "server startup-to-initialized (stale store)",
      fmt(results.staleStartup.ms),
      `< ${String(TARGETS.staleStartupMs)}ms`,
      staleStartupPass ? "PASS" : "FAIL",
    ]);
    allPass &&= staleStartupPass;

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
    try {
      if (staleTransport) await staleTransport.close();
    } catch {
      // best-effort
    }
    if (staleCacheDir && fs.existsSync(staleCacheDir)) {
      fs.rmSync(staleCacheDir, { recursive: true, force: true });
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

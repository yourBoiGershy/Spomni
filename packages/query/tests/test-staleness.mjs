// packages/query/tests/test-staleness.mjs
//
// Tests for the bounded-cold-start staleness path
// (packages/query/server/src/store/staleness.ts, docs/plans/
// 2026-08-30-38-retrieval-speed.md unit F): a stale-but-present cache is
// served immediately (honestly labelled, via the OLD generated_at) while
// regeneration runs in the background and asynchronously swaps in the
// fresh copy; a store with NO index.json/stats.json at all still falls
// back to the old synchronous-regeneration path.
//
// Plain node, no new dependencies: same stdio-spawn-the-real-server pattern
// as test-tools.mjs, using the MCP SDK's Client/StdioClientTransport from
// the query server's own node_modules.
//
// Every scratch store used here is a COPY under a tmp dir (never the real
// fixture store) with SPOMNI_CACHE_DIR pointed at its own tmp cache dir, so
// this file never writes into packages/core/fixtures/store or the
// developer's real ~/.cache/spomni.

import { fileURLToPath } from "node:url";
import path from "node:path";
import os from "node:os";
import fs from "node:fs";
import { spawnSync } from "node:child_process";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "../../..");
const SERVER_ENTRY = path.join(REPO_ROOT, "packages/query/server/src/index.ts");
const FIXTURE_STORE = path.join(REPO_ROOT, "packages/core/fixtures/store");
const BUILD_INDEX = path.join(REPO_ROOT, "packages/core/scripts/build-index.sh");
const BUILD_STATS = path.join(REPO_ROOT, "packages/core/scripts/build-stats.sh");
const SDK_DIR = path.join(
  REPO_ROOT,
  "packages/query/server/node_modules/@modelcontextprotocol/sdk/dist/esm",
);

const { Client } = await import(path.join(SDK_DIR, "client/index.js"));
const { StdioClientTransport } = await import(path.join(SDK_DIR, "client/stdio.js"));

let passCount = 0;
let failCount = 0;

function pass(label) {
  console.log(`PASS: ${label}`);
  passCount++;
}

function fail(label, detail) {
  console.log(`FAIL: ${label}`);
  if (detail !== undefined) {
    console.log(`  ${typeof detail === "string" ? detail : JSON.stringify(detail)}`);
  }
  failCount++;
}

function assertTrue(label, condition, detail) {
  if (condition) {
    pass(label);
  } else {
    fail(label, detail);
  }
}

function assertEqual(label, actual, expected) {
  if (actual === expected) {
    pass(label);
  } else {
    fail(label, `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

/** Recursively copies a directory tree (fixture store -> scratch copy). */
function copyDir(src, dest) {
  fs.mkdirSync(dest, { recursive: true });
  for (const entry of fs.readdirSync(src, { withFileTypes: true })) {
    const s = path.join(src, entry.name);
    const d = path.join(dest, entry.name);
    if (entry.isDirectory()) {
      copyDir(s, d);
    } else {
      fs.copyFileSync(s, d);
    }
  }
}

/** Calls `toolName` with `args`, parses the tool's single JSON text block. */
async function callTool(client, toolName, args) {
  const result = await client.callTool({ name: toolName, arguments: args });
  const block = result.content?.[0];
  if (!block || block.type !== "text") {
    throw new Error(`${toolName}: expected a single text content block, got ${JSON.stringify(result)}`);
  }
  return JSON.parse(block.text);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function connectServer(storeDir, cacheDir) {
  const transport = new StdioClientTransport({
    command: "node",
    args: ["--experimental-strip-types", SERVER_ENTRY, "--store", storeDir],
    cwd: path.join(REPO_ROOT, "packages/query/server"),
    env: { ...process.env, SPOMNI_CACHE_DIR: cacheDir },
    stderr: "pipe",
  });
  let stderrBuf = "";
  if (transport.stderr) {
    transport.stderr.on("data", (d) => {
      stderrBuf += d.toString();
    });
  }
  const client = new Client({ name: "ra-query-staleness-tests", version: "0.1.0" });
  await client.connect(transport);
  return { client, getStderr: () => stderrBuf };
}

async function main() {
  if (!fs.existsSync(SERVER_ENTRY)) {
    console.log(`SKIP: server entry point not found at ${SERVER_ENTRY}`);
    console.log("");
    console.log("SUMMARY: 0 passed, 0 failed, server missing");
    process.exit(1);
  }
  if (!fs.existsSync(SDK_DIR)) {
    console.log(`SKIP: MCP SDK not found at ${SDK_DIR} — run npm install in packages/query/server`);
    console.log("");
    console.log("SUMMARY: 0 passed, 0 failed, sdk missing");
    process.exit(1);
  }
  if (!fs.existsSync(FIXTURE_STORE)) {
    console.log(`SKIP: fixture store not found at ${FIXTURE_STORE}`);
    console.log("");
    console.log("SUMMARY: 0 passed, 0 failed, fixture store missing");
    process.exit(1);
  }

  const workRoot = fs.mkdtempSync(path.join(os.tmpdir(), "ra-query-staleness-"));

  try {
    // -----------------------------------------------------------------
    // Case (a): stale-but-present index.json/stats.json -> served
    // immediately (bounded cold start) with the OLD generated_at, then a
    // later call (after background regeneration lands) carries a NEWER
    // generated_at.
    // -----------------------------------------------------------------
    {
      const storeDir = path.join(workRoot, "stale-store");
      const cacheDir = path.join(workRoot, "stale-cache");
      copyDir(FIXTURE_STORE, storeDir);

      // The fixture store ships with no index.json/stats.json of its own
      // (staleness.ts's job to derive them) — build an initial "fresh"
      // pair directly into this scratch copy so there's a known-old
      // generated_at to compare the first (stale) response against.
      const indexBuild = spawnSync("bash", [BUILD_INDEX, storeDir], { encoding: "utf8" });
      const statsBuild = spawnSync("bash", [BUILD_STATS, storeDir], { encoding: "utf8" });
      if (indexBuild.status !== 0 || statsBuild.status !== 0) {
        throw new Error(
          `failed to seed initial index/stats: ${indexBuild.stderr || ""} ${statsBuild.stderr || ""}`,
        );
      }
      const oldStats = JSON.parse(fs.readFileSync(path.join(storeDir, "stats.json"), "utf8"));
      const oldGeneratedAt = oldStats.generated_at;

      // build-stats.sh's generated_at has 1-second resolution — wait past
      // the second boundary so the background regeneration's generated_at
      // is guaranteed to differ from oldGeneratedAt, not just coincide.
      await sleep(1100);

      // Touch one person file newer than index.json/stats.json so both
      // copies are stale relative to the source (per newestSourceMtime).
      const personFile = path.join(storeDir, "people", "grace-lindqvist.md");
      const futureMs = Date.now() + 5000;
      fs.utimesSync(personFile, new Date(futureMs), new Date(futureMs));

      const t0 = Date.now();
      const { client } = await connectServer(storeDir, cacheDir);
      const coldStartMs = Date.now() - t0;

      assertTrue(
        "stale store: cold start (initialize) completes in under 1000ms",
        coldStartMs < 1000,
        `coldStartMs=${coldStartMs}`,
      );

      const firstResult = await callTool(client, "get_contact_stats", { slug: "grace-lindqvist" });
      assertEqual(
        "stale store: first get_contact_stats call carries the OLD generated_at (served stale, honestly)",
        firstResult.generated_at,
        oldGeneratedAt,
      );

      const firstSearch = await callTool(client, "search_people", { tier: "inner-circle" });
      assertEqual(
        "stale store: first search_people call also carries the OLD generated_at",
        firstSearch.generated_at,
        oldGeneratedAt,
      );

      // Poll for the background swap (regeneration writes generated_at =
      // "now", which is after futureMs / oldGeneratedAt either way).
      let sawFresh = false;
      let lastGeneratedAt = firstResult.generated_at;
      const deadline = Date.now() + 3000;
      while (Date.now() < deadline) {
        await sleep(150);
        const r = await callTool(client, "get_contact_stats", { slug: "grace-lindqvist" });
        lastGeneratedAt = r.generated_at;
        if (r.generated_at !== oldGeneratedAt) {
          sawFresh = true;
          break;
        }
      }

      assertTrue(
        "stale store: within 3s, a later call carries a NEWER generated_at (background swap happened)",
        sawFresh,
        `lastGeneratedAt=${lastGeneratedAt}, oldGeneratedAt=${oldGeneratedAt}`,
      );
      if (sawFresh) {
        assertTrue(
          "stale store: swapped generated_at is chronologically newer than the old one",
          Date.parse(lastGeneratedAt) > Date.parse(oldGeneratedAt),
          `lastGeneratedAt=${lastGeneratedAt}, oldGeneratedAt=${oldGeneratedAt}`,
        );
      }

      await client.close();
    }

    // -----------------------------------------------------------------
    // Case (b): index.json/stats.json missing entirely -> falls back to
    // synchronous regeneration (the old, unavoidable path); still serves,
    // and generated_at is fresh (not the fixture's baked-in value).
    // -----------------------------------------------------------------
    {
      const storeDir = path.join(workRoot, "missing-store");
      const cacheDir = path.join(workRoot, "missing-cache");
      copyDir(FIXTURE_STORE, storeDir);
      fs.rmSync(path.join(storeDir, "index.json"), { force: true });
      fs.rmSync(path.join(storeDir, "stats.json"), { force: true });

      const { client } = await connectServer(storeDir, cacheDir);
      const result = await callTool(client, "get_contact_stats", { slug: "grace-lindqvist" });

      assertTrue(
        "missing index/stats: still serves a result (sync-regeneration fallback)",
        typeof result.generated_at === "string" && result.generated_at.length > 0,
        result,
      );

      const generatedMs = Date.parse(result.generated_at);
      const recentThresholdMs = Date.now() - 5 * 60 * 1000;
      assertTrue(
        "missing index/stats: generated_at is fresh (regenerated just now, not stale fixture data)",
        generatedMs >= recentThresholdMs,
        `generated_at=${result.generated_at}`,
      );

      await client.close();
    }

    console.log("");
    console.log(`SUMMARY: ${passCount} passed, ${failCount} failed`);
    process.exit(failCount === 0 ? 0 : 1);
  } finally {
    fs.rmSync(workRoot, { recursive: true, force: true });
  }
}

main().catch((err) => {
  console.error(`FATAL: ${err?.stack ?? String(err)}`);
  process.exit(1);
});

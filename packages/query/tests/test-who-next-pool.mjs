// packages/query/tests/test-who-next-pool.mjs
//
// Equivalence test for the `who_next_pool` MCP tool
// (packages/query/server/src/tools/who-next-pool.ts) against its reference
// implementation, packages/query/scripts/who-next-direct.sh (plan 38 unit
// G, docs/plans/2026-08-30-38-retrieval-speed.md). For each of
// friends/coffee/all, the tool's `candidates` array must deep-equal the
// JSON-lines who-next-direct.sh emits, in the same order, on the same
// store — both read packages/query/tests/fixtures/who-next-direct/store/,
// pinned at --today 2026-08-30 (see run-who-next-direct-tests.sh's header
// comment for the fixture's cast of characters and why each one lands
// where it does).
//
// Also covers get_person's `include_interactions` option (unchanged when
// absent — test-tools.mjs's goldens already pin that path) against
// packages/core/fixtures/store's grace-lindqvist, who has 11 filed
// interactions: include_interactions: 3 must return exactly 3, newest
// first.
//
// Spawns the real MCP server over stdio, same style as test-tools.mjs.
// Never writes into either fixture store: who-next-direct.sh and this
// test's own index/stats build both run against throwaway temp copies.

import { fileURLToPath } from "node:url";
import path from "node:path";
import os from "node:os";
import fs from "node:fs";
import { execFileSync } from "node:child_process";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "../../..");
const SERVER_ENTRY = path.join(REPO_ROOT, "packages/query/server/src/index.ts");
const SDK_DIR = path.join(
  REPO_ROOT,
  "packages/query/server/node_modules/@modelcontextprotocol/sdk/dist/esm",
);
const WHO_NEXT_DIRECT_STORE = path.join(
  REPO_ROOT,
  "packages/query/tests/fixtures/who-next-direct/store",
);
const WHO_NEXT_DIRECT_SH = path.join(REPO_ROOT, "packages/query/scripts/who-next-direct.sh");
const BUILD_INDEX_SH = path.join(REPO_ROOT, "packages/core/scripts/build-index.sh");
const BUILD_STATS_SH = path.join(REPO_ROOT, "packages/core/scripts/build-stats.sh");
const CORE_FIXTURE_STORE = path.join(REPO_ROOT, "packages/core/fixtures/store");

const TODAY = "2026-08-30";

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

function assertEqual(label, actual, expected) {
  if (actual === expected) {
    pass(label);
  } else {
    fail(label, `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function assertTrue(label, condition, detail) {
  if (condition) {
    pass(label);
  } else {
    fail(label, detail);
  }
}

function assertDeepEqual(label, actual, expected) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) {
    pass(label);
  } else {
    fail(label, `expected ${e}\n  got      ${a}`);
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

/** Copies `src` into a fresh temp dir and returns its path. */
function freshCopy(src, label) {
  const dest = fs.mkdtempSync(path.join(os.tmpdir(), `ra-who-next-pool-${label}-`));
  fs.cpSync(src, dest, { recursive: true });
  return dest;
}

/** Runs who-next-direct.sh against `storeDir` for `mode`, parsing each
 * emitted JSON line into an array (the reference implementation's output). */
function runWhoNextDirect(storeDir, mode) {
  const out = execFileSync(
    "bash",
    [WHO_NEXT_DIRECT_SH, storeDir, "--mode", mode, "--today", TODAY],
    { encoding: "utf8" },
  );
  return out
    .split("\n")
    .filter((line) => line.trim().length > 0)
    .map((line) => JSON.parse(line));
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
  if (!fs.existsSync(WHO_NEXT_DIRECT_STORE) || !fs.existsSync(WHO_NEXT_DIRECT_SH)) {
    console.log(`SKIP: who-next-direct fixture/script not found`);
    console.log("");
    console.log("SUMMARY: 0 passed, 0 failed, fixture missing");
    process.exit(1);
  }
  if (!fs.existsSync(CORE_FIXTURE_STORE)) {
    console.log(`SKIP: core fixture store not found at ${CORE_FIXTURE_STORE}`);
    console.log("");
    console.log("SUMMARY: 0 passed, 0 failed, core fixture store missing");
    process.exit(1);
  }

  const { Client } = await import(path.join(SDK_DIR, "client/index.js"));
  const { StdioClientTransport } = await import(path.join(SDK_DIR, "client/stdio.js"));

  // A store copy with index.json/stats.json generated, served to the MCP
  // server for the equivalence assertions.
  const poolStoreDir = freshCopy(WHO_NEXT_DIRECT_STORE, "server-store");
  execFileSync("bash", [BUILD_INDEX_SH, poolStoreDir], { stdio: "ignore" });
  execFileSync("bash", [BUILD_STATS_SH, poolStoreDir], { stdio: "ignore" });

  const cacheDir = fs.mkdtempSync(path.join(os.tmpdir(), "ra-who-next-pool-cache-"));

  const transport = new StdioClientTransport({
    command: "node",
    args: ["--experimental-strip-types", SERVER_ENTRY, "--store", poolStoreDir],
    cwd: path.join(REPO_ROOT, "packages/query/server"),
    env: { ...process.env, SPOMNI_CACHE_DIR: cacheDir },
    stderr: "pipe",
  });

  const client = new Client({ name: "ra-who-next-pool-tests", version: "0.1.0" });

  try {
    await client.connect(transport);
  } catch (err) {
    console.log(`SKIP: could not connect to the query MCP server: ${String(err)}`);
    console.log("");
    console.log("SUMMARY: 0 passed, 0 failed, server did not start");
    process.exit(1);
  }

  try {
    // -----------------------------------------------------------------
    // who_next_pool equivalence with who-next-direct.sh, per mode
    // -----------------------------------------------------------------
    for (const mode of ["all", "friends", "coffee"]) {
      const referenceDir = freshCopy(WHO_NEXT_DIRECT_STORE, `reference-${mode}`);
      const expected = runWhoNextDirect(referenceDir, mode);

      const toolResult = await callTool(client, "who_next_pool", { mode, limit: 20, today: TODAY });

      assertEqual(`who_next_pool: mode=${mode} candidate count matches who-next-direct.sh`, toolResult.candidates.length, expected.length);
      assertDeepEqual(
        `who_next_pool: mode=${mode} candidates deep-equal who-next-direct.sh output`,
        toolResult.candidates,
        expected,
      );
      assertEqual(`who_next_pool: mode=${mode} echoes mode`, toolResult.mode, mode);
      assertEqual(`who_next_pool: mode=${mode} echoes today`, toolResult.today, TODAY);
      assertTrue(
        `who_next_pool: mode=${mode} carries generated_at`,
        typeof toolResult.generated_at === "string" && toolResult.generated_at.length > 0,
        toolResult.generated_at,
      );

      fs.rmSync(referenceDir, { recursive: true, force: true });
    }

    // -----------------------------------------------------------------
    // who_next_pool: default limit is 20
    // -----------------------------------------------------------------
    {
      const r = await callTool(client, "who_next_pool", { today: TODAY });
      assertEqual("who_next_pool: default limit is 20", r.limit, 20);
    }

    // -----------------------------------------------------------------
    // who_next_pool: kind-semantics exclusions (non-relational/expired
    // kinds) — explicit absence assertions naming slugs, so equivalence
    // with who-next-direct.sh can't mask a shared bug. Fixture cast: (j)
    // quinn-bramwell (kind: unsolicited), (k) dana-whitfield (kind:
    // scheduling, kind_expires: 2026-08-01 -> expired), (l) felix-marsh
    // (kind: professional, kind_expires: 2026-08-01 -> expired), (h)
    // morris-vance (kind: transactional) — see
    // run-who-next-direct-tests.sh's header for the full cast.
    // -----------------------------------------------------------------
    const EXCLUDED_SLUGS = ["quinn-bramwell", "dana-whitfield", "felix-marsh"];
    for (const mode of ["all", "friends", "coffee"]) {
      const toolResult = await callTool(client, "who_next_pool", { mode, limit: 20, today: TODAY });
      const slugs = toolResult.candidates.map((c) => c.slug);
      for (const excluded of EXCLUDED_SLUGS) {
        assertTrue(
          `who_next_pool: mode=${mode} never surfaces ${excluded}`,
          !slugs.includes(excluded),
          slugs,
        );
      }
      assertTrue(
        `who_next_pool: mode=${mode} never emits kind_expires on any candidate`,
        toolResult.candidates.every((c) => !("kind_expires" in c)),
        toolResult.candidates,
      );
    }

    {
      const withoutTx = await callTool(client, "who_next_pool", { mode: "all", limit: 20, today: TODAY });
      assertTrue(
        "who_next_pool: mode=all without include_transactional never surfaces morris-vance",
        !withoutTx.candidates.some((c) => c.slug === "morris-vance"),
        withoutTx.candidates,
      );

      const withTx = await callTool(client, "who_next_pool", {
        mode: "all",
        limit: 20,
        today: TODAY,
        include_transactional: true,
      });
      assertTrue(
        "who_next_pool: mode=all with include_transactional=true surfaces morris-vance",
        withTx.candidates.some((c) => c.slug === "morris-vance"),
        withTx.candidates,
      );
      // Expired kinds are never re-admitted by include_transactional, even
      // for the effective-kind "expired" cases above.
      for (const excluded of EXCLUDED_SLUGS) {
        assertTrue(
          `who_next_pool: mode=all with include_transactional=true still never surfaces ${excluded}`,
          !withTx.candidates.some((c) => c.slug === excluded),
          withTx.candidates,
        );
      }
    }

  } finally {
    await client.close();
    fs.rmSync(cacheDir, { recursive: true, force: true });
    fs.rmSync(poolStoreDir, { recursive: true, force: true });
  }

  // -----------------------------------------------------------------
  // get_person: include_interactions returns N most recent, newest first —
  // against the 30-persona fixture store (grace-lindqvist has 11 filed
  // interactions), so a second server pointed there.
  // -----------------------------------------------------------------
  const coreCacheDir = fs.mkdtempSync(path.join(os.tmpdir(), "ra-who-next-pool-core-cache-"));
  const coreTransport = new StdioClientTransport({
    command: "node",
    args: ["--experimental-strip-types", SERVER_ENTRY, "--store", CORE_FIXTURE_STORE],
    cwd: path.join(REPO_ROOT, "packages/query/server"),
    env: { ...process.env, SPOMNI_CACHE_DIR: coreCacheDir },
    stderr: "pipe",
  });
  const coreClient = new Client({ name: "ra-who-next-pool-core-tests", version: "0.1.0" });

  try {
    await coreClient.connect(coreTransport);

    const withDefault = await callTool(coreClient, "get_person", { slug: "grace-lindqvist" });
    assertTrue(
      "get_person: absent include_interactions leaves result unchanged (no interactions key)",
      !("interactions" in withDefault),
      withDefault,
    );

    const withThree = await callTool(coreClient, "get_person", {
      slug: "grace-lindqvist",
      include_interactions: 3,
    });
    assertTrue(
      "get_person: include_interactions:3 adds an interactions array",
      Array.isArray(withThree.interactions),
      withThree.interactions,
    );
    assertEqual(
      "get_person: include_interactions:3 returns exactly 3 interactions",
      withThree.interactions?.length,
      3,
    );

    const listResult = await callTool(coreClient, "list_interactions", { slug: "grace-lindqvist" });
    const expectedIds = listResult.interactions.slice(0, 3).map((i) => i.id);
    assertDeepEqual(
      "get_person: include_interactions:3 matches list_interactions' first 3 ids (newest first)",
      withThree.interactions.map((i) => i.id),
      expectedIds,
    );
    assertTrue(
      "get_person: include_interactions entries carry a summary_excerpt",
      withThree.interactions.every((i) => typeof i.summary_excerpt === "string"),
      withThree.interactions,
    );
  } finally {
    await coreClient.close();
    fs.rmSync(coreCacheDir, { recursive: true, force: true });
  }

  // The committed fixture stores must stay pristine — nothing here writes
  // into WHO_NEXT_DIRECT_STORE or CORE_FIXTURE_STORE, only into freshCopy()
  // temp dirs.

  console.log("");
  console.log(`SUMMARY: ${passCount} passed, ${failCount} failed`);
  process.exit(failCount === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error(`FATAL: ${err?.stack ?? String(err)}`);
  process.exit(1);
});

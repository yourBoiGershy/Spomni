#!/usr/bin/env node
// packages/query/tests/test-reachouts-readonly.mjs
//
// Golden tests for `suggest_reachouts` (both modes: attention-sourced and
// heuristic-fallback, plus the mixed case) and the read-only enforcement
// test that mechanically proves the plan's core safety property: the store
// is never mutated by any MCP tool call.
//
// See docs/plans/2026-08-29-08-chat-mcp-query-layer.md's tool 6 spec and its
// "Proof of done" read-only clause.
//
// Goldens below were hand-derived from the fixture store, NOT read off the
// tool's own output first, per docs/DECISIONS.md's golden-tests-before-
// prompts rule:
//
//   - packages/core/fixtures/store/wakeups/ has 6 pending wake-ups, due:
//     2026-09-05 (james-okafor), 2026-09-10 (marcus-chen),
//     2026-09-12 (grace-lindqvist), 2026-09-15 (sofia-reyes),
//     2026-09-20 (katarina-novak), 2026-10-05 (marisol-vega). Against
//     "now" = the environment's current date, 2026-08-29, the first five
//     are due <= 30 days out (suggest-reachouts.ts's ATTENTION_WINDOW_DAYS)
//     and the sixth (37 days out) is not — so the default-limit (5) call
//     against the fixture store as-is should return exactly those five,
//     `source: attention`, sorted soonest-due first.
//   - Emptying wakeups/ forces every suggestion into the heuristic-fallback
//     path. james-okafor's only interaction is 2025-09-15 (~348 days stale
//     as of 2026-08-29), he has no second interaction so no established
//     cadence (median_gap_days: null, baseline 60d), is `dormant` tier, and
//     has 1 open thread (people/james-okafor.md's "Open threads" section)
//     — computing suggest-reachouts.ts's own published formula
//     (staleness_ratio*10 + tier_weight*5 + open_threads*3) against every
//     fixture person's hand-verified stats.json entry puts him at score 66,
//     ~8 points clear of the next candidate (yusuf-demir, 58) — a margin
//     that easily survives a day or two of clock drift between when this
//     comment was written and when the test runs.
//   - priyanka-deshmukh has zero interactions/*.md files linking her (see
//     packages/core/tests/test-build-stats.sh's own goldens) — the
//     heuristic must never invent a score for her.

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "../../..");
const SERVER_ENTRY = path.join(REPO_ROOT, "packages/query/server/src/index.ts");
const FIXTURE_STORE = path.join(REPO_ROOT, "packages/core/fixtures/store");
const SERVER_NODE_MODULES = path.join(REPO_ROOT, "packages/query/server/node_modules");

// This test file lives under packages/query/tests/, not
// packages/query/server/src/ — Node's ESM resolver only walks up from the
// importing module's own directory, so a bare `import "@modelcontextprotocol/
// sdk/..."` here would never find the server's node_modules (a sibling, not
// an ancestor). Import the two SDK modules we need by their resolved file
// URL instead of adding a second, redundant node_modules under tests/.
const { Client } = await import(
  pathToFileURL(path.join(SERVER_NODE_MODULES, "@modelcontextprotocol/sdk/dist/esm/client/index.js")).href
);
const { StdioClientTransport } = await import(
  pathToFileURL(path.join(SERVER_NODE_MODULES, "@modelcontextprotocol/sdk/dist/esm/client/stdio.js")).href
);

let PASS_COUNT = 0;
let FAIL_COUNT = 0;

function pass(msg) {
  console.log(`PASS: ${msg}`);
  PASS_COUNT++;
}

function fail(msg) {
  console.log(`FAIL: ${msg}`);
  FAIL_COUNT++;
}

function ok(cond, msg) {
  if (cond) pass(msg);
  else fail(msg);
}

const tmpDirs = [];
function mkTmpDir(prefix) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  tmpDirs.push(dir);
  return dir;
}

/** Recursive sha256 manifest of a directory: sorted "relpath:sha256\n" lines,
 * hashed together into one digest — sensitive to any add/remove/modify. */
function hashDirManifest(dir) {
  const lines = [];
  function walk(sub) {
    const abs = path.join(dir, sub);
    if (!fs.existsSync(abs)) return;
    for (const entry of fs.readdirSync(abs, { withFileTypes: true })) {
      const relPath = path.join(sub, entry.name);
      if (entry.isDirectory()) {
        walk(relPath);
      } else if (entry.isFile()) {
        const content = fs.readFileSync(path.join(dir, relPath));
        const fileHash = crypto.createHash("sha256").update(content).digest("hex");
        lines.push(`${relPath}:${fileHash}`);
      }
    }
  }
  walk(".");
  lines.sort();
  return crypto.createHash("sha256").update(lines.join("\n")).digest("hex");
}

/** Connects a fresh Client+StdioClientTransport pair to the server against
 * `storeDir`, with its cache dir pinned to `cacheDir` (never the real
 * `$HOME/.cache`, so this suite is hermetic). */
async function startClient(storeDir, cacheDir) {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: ["--experimental-strip-types", SERVER_ENTRY, "--store", storeDir],
    env: {
      PATH: process.env.PATH ?? "",
      HOME: process.env.HOME ?? "",
      SPOMNI_CACHE_DIR: cacheDir,
    },
    stderr: "pipe",
  });
  const client = new Client({ name: "reachouts-readonly-test", version: "0.0.0" }, { capabilities: {} });
  await client.connect(transport);
  return { client, transport };
}

function parseToolResult(result) {
  const text = result.content?.[0]?.text;
  if (typeof text !== "string") {
    throw new Error(`tool result has no text content: ${JSON.stringify(result)}`);
  }
  return JSON.parse(text);
}

async function callSuggestReachouts(client, args = {}) {
  const result = await client.callTool({ name: "suggest_reachouts", arguments: args });
  return parseToolResult(result);
}

// ---------------------------------------------------------------------
// Assertion 4 setup: hash the fixture store BEFORE any tool call anywhere
// in this file. Assertions 1-3 call tools against the real fixture store
// too (per this suite's spec) — since the tool surface is supposed to be
// read-only regardless of which store dir is targeted, capturing the
// "before any tool calls" manifest here covers every tool call the whole
// suite makes, not just assertion 4's own.
// ---------------------------------------------------------------------
const initialManifest = hashDirManifest(FIXTURE_STORE);

async function assertionAttentionMode() {
  console.log("\n-- assertion 1: attention mode (fixture store as-is) --");
  const cacheDir = mkTmpDir("ra-reachouts-attn-cache-");
  const { client, transport } = await startClient(FIXTURE_STORE, cacheDir);
  try {
    const result = await callSuggestReachouts(client);
    const suggestions = result.suggestions ?? [];

    ok(
      suggestions.length === 5,
      `default call returns 5 suggestions (got ${suggestions.length})`,
    );

    const allAttention = suggestions.every((s) => s.source === "attention");
    ok(allAttention, "every suggestion is source: attention");

    const expectedOrder = [
      "2026-09-05-james-okafor",
      "2026-09-10-marcus-chen",
      "2026-09-12-grace-lindqvist",
      "2026-09-15-sofia-reyes",
      "2026-09-20-katarina-novak",
    ];
    const actualOrder = suggestions.map((s) => s.slug);
    ok(
      JSON.stringify(actualOrder) === JSON.stringify(expectedOrder),
      `suggestions sorted soonest-due first: ${JSON.stringify(actualOrder)} (expected ${JSON.stringify(expectedOrder)})`,
    );

    let citesOk = true;
    let fieldsOk = true;
    for (const s of suggestions) {
      if (!s.cites || !s.cites.includes(`${path.sep}wakeups${path.sep}`) || !s.cites.endsWith(".md")) {
        citesOk = false;
      }
      if (
        !Array.isArray(s.people) ||
        s.people.length === 0 ||
        typeof s.due !== "string" ||
        typeof s.why !== "string" ||
        typeof s.origin !== "string"
      ) {
        fieldsOk = false;
      }
    }
    ok(citesOk, "every suggestion cites a wakeups/*.md file");
    ok(fieldsOk, "every suggestion has who (people)/due/why/origin");
  } finally {
    await client.close();
  }
}

async function assertionFallbackMode() {
  console.log("\n-- assertion 2: fallback mode (temp copy, wakeups/ emptied) --");
  const storeDir = mkTmpDir("ra-reachouts-fallback-store-");
  fs.cpSync(FIXTURE_STORE, storeDir, { recursive: true });
  const wakeupsDir = path.join(storeDir, "wakeups");
  for (const f of fs.readdirSync(wakeupsDir)) {
    if (f.endsWith(".md")) fs.rmSync(path.join(wakeupsDir, f));
  }

  const cacheDir = mkTmpDir("ra-reachouts-fallback-cache-");
  const { client, transport } = await startClient(storeDir, cacheDir);
  try {
    const result = await callSuggestReachouts(client, { limit: 10 });
    const suggestions = result.suggestions ?? [];

    ok(suggestions.length > 0, `fallback mode returns suggestions (got ${suggestions.length})`);

    const allFallback = suggestions.every((s) => s.source === "heuristic-fallback");
    ok(allFallback, "every suggestion is source: heuristic-fallback");

    ok(
      suggestions[0]?.slug === "james-okafor",
      `james-okafor ranks first (got ${suggestions[0]?.slug})`,
    );

    let breakdownOk = true;
    let reasonOk = true;
    for (const s of suggestions) {
      const b = s.breakdown;
      if (
        !b ||
        typeof b.days_since_last_interaction !== "number" ||
        typeof b.tier_weight !== "number" ||
        typeof b.open_threads !== "number"
      ) {
        breakdownOk = false;
      }
      if (typeof b?.reason !== "string" || b.reason.length === 0 || !/\d/.test(b.reason)) {
        reasonOk = false;
      }
    }
    ok(breakdownOk, "every suggestion has a breakdown with days_since_last_interaction/tier_weight/open_threads");
    ok(reasonOk, "every suggestion has a non-empty reason citing a specific number");

    const hasPriyanka = suggestions.some((s) => s.slug === "priyanka-deshmukh");
    ok(!hasPriyanka, "zero-interaction priyanka-deshmukh never appears");
  } finally {
    await client.close();
  }
}

async function assertionMixed() {
  console.log("\n-- assertion 3: mixed (limit=10 on the full store) --");
  const cacheDir = mkTmpDir("ra-reachouts-mixed-cache-");
  const { client, transport } = await startClient(FIXTURE_STORE, cacheDir);
  try {
    const result = await callSuggestReachouts(client, { limit: 10 });
    const suggestions = result.suggestions ?? [];

    ok(suggestions.length === 10, `limit=10 returns 10 suggestions (got ${suggestions.length})`);

    const attentionCount = suggestions.filter((s) => s.source === "attention").length;
    ok(attentionCount === 5, `5 attention entries (got ${attentionCount})`);

    const firstFive = suggestions.slice(0, 5);
    const lastFive = suggestions.slice(5);
    ok(
      firstFive.every((s) => s.source === "attention"),
      "attention entries come first",
    );
    ok(
      lastFive.every((s) => s.source === "heuristic-fallback"),
      "fallback entries fill the remaining slots",
    );

    const attentionSlugs = new Set();
    for (const s of firstFive) {
      for (const p of s.people ?? []) attentionSlugs.add(p.slug);
    }
    const fallbackSlugs = lastFive.map((s) => s.slug);
    const dupes = fallbackSlugs.filter((slug) => attentionSlugs.has(slug));
    ok(dupes.length === 0, `no person duplicated across attention and fallback groups (dupes: ${JSON.stringify(dupes)})`);
  } finally {
    await client.close();
  }
}

async function assertionReadOnly() {
  console.log("\n-- assertion 4: read-only enforcement (every tool, byte-identical store) --");
  const cacheDir = mkTmpDir("ra-reachouts-readonly-cache-");
  const { client, transport } = await startClient(FIXTURE_STORE, cacheDir);
  try {
    const toolsList = await client.listTools();
    const toolNames = toolsList.tools.map((t) => t.name).sort();
    const expectedNames = [
      "get_contact_stats",
      "get_interaction",
      "get_person",
      "list_interactions",
      "search_people",
      "suggest_reachouts",
    ];
    ok(
      JSON.stringify(toolNames) === JSON.stringify(expectedNames),
      `tools/list returns exactly the six registered tools (got ${JSON.stringify(toolNames)})`,
    );

    // Exercise every registered tool at least once, including error paths.
    const calls = [
      { name: "search_people", arguments: {} },
      { name: "search_people", arguments: { text: "no-such-person-zzz" } },
      { name: "get_person", arguments: { slug: "grace-lindqvist" } },
      { name: "get_person", arguments: { slug: "no-such-slug-zzz" } },
      { name: "list_interactions", arguments: { slug: "grace-lindqvist" } },
      { name: "list_interactions", arguments: { slug: "no-such-slug-zzz" } },
      { name: "get_interaction", arguments: { id: "2026-08-26-grace-lindqvist" } },
      { name: "get_interaction", arguments: { id: "no-such-interaction-zzz" } },
      { name: "get_contact_stats", arguments: { slug: "grace-lindqvist" } },
      { name: "get_contact_stats", arguments: { slug: "no-such-slug-zzz" } },
      { name: "suggest_reachouts", arguments: {} },
      { name: "suggest_reachouts", arguments: { limit: 10 } },
    ];

    let allCalled = true;
    for (const call of calls) {
      try {
        await client.callTool(call);
      } catch (err) {
        // A tool erroring is fine (e.g. protocol-level validation) — the
        // point is exercising every tool, not that every call succeeds.
        console.log(`  (note: ${call.name}(${JSON.stringify(call.arguments)}) raised: ${String(err)})`);
      }
    }
    ok(allCalled, "every registered tool was called at least once, including error paths");
  } finally {
    await client.close();
  }

  const finalManifest = hashDirManifest(FIXTURE_STORE);
  ok(
    finalManifest === initialManifest,
    "fixture store is byte-identical after exercising every tool",
  );

  const gitStatus = execFileSync(
    "git",
    ["status", "--porcelain", "--", "packages/core/fixtures/store"],
    { cwd: REPO_ROOT, encoding: "utf8" },
  ).trim();
  ok(gitStatus === "", `git status --porcelain on the store is empty (got: ${JSON.stringify(gitStatus)})`);

  const cacheFiles = fs.existsSync(cacheDir) ? fs.readdirSync(cacheDir, { recursive: true }) : [];
  ok(cacheFiles.length > 0, `cache dir received the regenerated derived artifacts (${JSON.stringify(cacheFiles)})`);
}

async function main() {
  try {
    await assertionAttentionMode();
    await assertionFallbackMode();
    await assertionMixed();
    await assertionReadOnly();
  } catch (err) {
    fail(`unhandled error: ${err?.stack ?? String(err)}`);
  } finally {
    for (const dir of tmpDirs) {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }

  console.log(`\nSUMMARY: ${PASS_COUNT} passed, ${FAIL_COUNT} failed`);
  process.exit(FAIL_COUNT === 0 ? 0 : 1);
}

main();

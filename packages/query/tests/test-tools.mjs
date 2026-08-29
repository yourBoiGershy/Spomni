// packages/query/tests/test-tools.mjs
//
// Golden tests for the five read/detail MCP tools (search_people,
// get_person, list_interactions, get_interaction, get_contact_stats)
// against the 30-persona fixture store (packages/core/fixtures/store/).
// `suggest_reachouts` is out of scope (covered by a separate unit).
//
// Plain node, no new dependencies: imports the MCP SDK's Client and
// StdioClientTransport directly from the query server's own node_modules
// (relative path) rather than adding a devDependency here. Spawns the real
// server (`node --experimental-strip-types src/index.ts --store <fixtures>`)
// over stdio and drives it exactly as a real MCP client would.
//
// Every expected value below is hand-derived from the fixture markdown
// files and docs/plans/2026-08-29-08-chat-mcp-query-layer.md's "MCP tool
// surface" / "Derived-data design" sections — NOT read off the tools' own
// output — per docs/DECISIONS.md's golden-tests-before-prompts rule.
//
// Goldens (hand-counted, cited by source file):
//   - search "fintech" tag + "New York" location: grep -l fintech
//     packages/core/fixtures/store/people/*.md, then grep location/tags on
//     each hit => marcus-chen.md, hana-kobayashi.md, priya-anand.md are the
//     only three with tags containing fintech AND location "New York, NY".
//   - tier=inner-circle: grep '^tier:' packages/core/fixtures/store/people/
//     *.md => exactly eleanor-combs, owen-brady, walter-combs (3 people).
//   - no-match search: text="zzz-nonexistent-zzz" matches no person field.
//   - broad search (no filters): 30 person files in
//     packages/core/fixtures/store/people/ => total=30, page 1 has 25
//     (PAGE_SIZE in search-people.ts), page 2 has the remaining 5.
//   - grace-lindqvist: people/grace-lindqvist.md frontmatter name "Grace
//     Lindqvist"; `## Facts` has 2 bullets, both tagged
//     `**[told-by-user]**` verbatim; 11 interactions/*.md files list
//     [[grace-lindqvist]] (2025-10-03, 2025-11-14, 2025-12-19, 2026-01-16,
//     2026-02-13, 2026-03-20, 2026-04-17, 2026-05-15, 2026-06-12,
//     2026-07-24, 2026-08-26) => touchpoints=11; consecutive-date gaps in
//     days are [42,35,28,28,35,28,28,28,42,33], median of those 10 gaps is
//     30.5, and build-stats.sh rounds half-up ((median+0.5)|floor) => 31.
//   - unknown slug "nonexistent-person-zzz": not in
//     packages/core/fixtures/store/people/ => not_found.
//   - priyanka-deshmukh: no interactions/*.md file lists
//     [[priyanka-deshmukh]] => list_interactions returns an empty list, no
//     error.
//   - interactions/2026-07-20-combs-family-reunion.md has `## Summary` and
//     `## Commitments` headings.
//   - unknown interaction id "2099-01-01-nobody": no such file under
//     packages/core/fixtures/store/interactions/ => not_found.
//
// Run via packages/query/tests/run-query-tests.sh.

import { fileURLToPath } from "node:url";
import path from "node:path";
import os from "node:os";
import fs from "node:fs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "../../..");
const SERVER_ENTRY = path.join(REPO_ROOT, "packages/query/server/src/index.ts");
const FIXTURE_STORE = path.join(REPO_ROOT, "packages/core/fixtures/store");
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

function assertSameSet(label, actualArr, expectedArr) {
  const a = [...actualArr].sort();
  const e = [...expectedArr].sort();
  const same = a.length === e.length && a.every((v, i) => v === e[i]);
  assertTrue(label, same, `expected ${JSON.stringify(e)}, got ${JSON.stringify(a)}`);
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

  // Isolated cache dir so this run never touches the real ~/.cache and
  // never leaves anything behind that could be mistaken for store state.
  const cacheDir = fs.mkdtempSync(path.join(os.tmpdir(), "ra-query-test-cache-"));

  const transport = new StdioClientTransport({
    command: "node",
    args: ["--experimental-strip-types", SERVER_ENTRY, "--store", FIXTURE_STORE],
    cwd: path.join(REPO_ROOT, "packages/query/server"),
    env: { ...process.env, RA_CACHE_DIR: cacheDir },
    stderr: "pipe",
  });

  const client = new Client({ name: "ra-query-golden-tests", version: "0.1.0" });

  try {
    await client.connect(transport);
  } catch (err) {
    console.log(`SKIP: could not connect to the query MCP server: ${String(err)}`);
    console.log("");
    console.log("SUMMARY: 0 passed, 0 failed, server did not start");
    process.exit(1);
  }

  try {
    // -------------------------------------------------------------------
    // search_people
    // -------------------------------------------------------------------
    {
      const r = await callTool(client, "search_people", {
        tags: ["fintech"],
        location: "New York",
      });
      assertSameSet(
        "search_people: fintech+New York returns exactly {priya-anand, marcus-chen, hana-kobayashi}",
        r.results.map((p) => p.slug),
        ["priya-anand", "marcus-chen", "hana-kobayashi"],
      );
      assertTrue(
        "search_people: fintech+New York results carry a source citation",
        r.results.every((p) => typeof p.source === "string" && p.source.length > 0),
        r.results,
      );
    }

    {
      const r = await callTool(client, "search_people", { tier: "inner-circle" });
      assertSameSet(
        "search_people: tier=inner-circle returns only that tier's 3 people",
        r.results.map((p) => p.slug),
        ["eleanor-combs", "owen-brady", "walter-combs"],
      );
      assertTrue(
        "search_people: tier=inner-circle results are all tier inner-circle",
        r.results.every((p) => p.tier === "inner-circle"),
        r.results.map((p) => [p.slug, p.tier]),
      );
    }

    {
      const r = await callTool(client, "search_people", { text: "zzz-nonexistent-zzz" });
      assertTrue("search_people: no-match sets no_match=true", r.no_match === true, r);
      assertEqual("search_people: no-match returns zero results", r.results.length, 0);
      assertTrue(
        "search_people: no-match never invents a person (suggestions is an array)",
        Array.isArray(r.suggestions),
        r,
      );
    }

    {
      const page1 = await callTool(client, "search_people", {});
      assertEqual("search_people: broad search total is 30", page1.total, 30);
      assertEqual("search_people: broad search page 1 respects page_size (25)", page1.results.length, 25);
      const page2 = await callTool(client, "search_people", { page: 2 });
      assertEqual("search_people: broad search page 2 has the remaining 5", page2.results.length, 5);
      const allSlugs = new Set([...page1.results.map((p) => p.slug), ...page2.results.map((p) => p.slug)]);
      assertEqual("search_people: pages 1+2 together cover all 30 distinct people", allSlugs.size, 30);
    }

    // -------------------------------------------------------------------
    // get_person
    // -------------------------------------------------------------------
    {
      const r = await callTool(client, "get_person", { slug: "grace-lindqvist" });
      assertEqual("get_person: grace-lindqvist frontmatter name", r.frontmatter?.name, "Grace Lindqvist");
      const facts = r.sections?.find((s) => s.heading === "Facts");
      assertTrue(
        "get_person: grace-lindqvist Facts section present with bullets",
        Array.isArray(facts?.bullets) && facts.bullets.length > 0,
        facts,
      );
      assertTrue(
        "get_person: grace-lindqvist Facts bullets carry **[told-by-user]** verbatim",
        (facts?.bullets ?? []).every((b) => String(b).includes("**[told-by-user]**")),
        facts?.bullets,
      );
      assertEqual("get_person: grace-lindqvist stats rollup touchpoints", r.stats?.touchpoints, 11);
      assertTrue(
        "get_person: grace-lindqvist result cites people/grace-lindqvist.md",
        r.source === "people/grace-lindqvist.md",
        r.source,
      );
    }

    {
      const r = await callTool(client, "get_person", { slug: "nonexistent-person-zzz" });
      assertEqual("get_person: unknown slug reports not_found", r.error, "not_found");
      assertTrue(
        "get_person: unknown slug returns suggestions, none fabricated as a person",
        Array.isArray(r.suggestions) && r.frontmatter === undefined,
        r,
      );
    }

    // -------------------------------------------------------------------
    // list_interactions
    // -------------------------------------------------------------------
    {
      const p1 = await callTool(client, "list_interactions", { slug: "grace-lindqvist" });
      assertEqual("list_interactions: grace-lindqvist total is 11", p1.total, 11);
      assertEqual("list_interactions: grace-lindqvist page 1 has 10 items", p1.interactions.length, 10);
      const dates1 = p1.interactions.map((i) => i.date);
      const sortedDesc1 = [...dates1].sort().reverse();
      assertTrue(
        "list_interactions: grace-lindqvist page 1 is newest-first",
        JSON.stringify(dates1) === JSON.stringify(sortedDesc1),
        dates1,
      );
      assertEqual("list_interactions: grace-lindqvist page 1 newest date is 2026-08-26", dates1[0], "2026-08-26");

      const p2 = await callTool(client, "list_interactions", { slug: "grace-lindqvist", page: 2 });
      assertEqual("list_interactions: grace-lindqvist page 2 has 1 item", p2.interactions.length, 1);
      assertEqual("list_interactions: grace-lindqvist page 2 item is the oldest (2025-10-03)", p2.interactions[0]?.date, "2025-10-03");
    }

    {
      const r = await callTool(client, "list_interactions", { slug: "priyanka-deshmukh" });
      assertEqual("list_interactions: priyanka-deshmukh returns an empty list", r.interactions.length, 0);
      assertEqual("list_interactions: priyanka-deshmukh total is 0", r.total, 0);
      assertTrue("list_interactions: priyanka-deshmukh is not an error", r.error === undefined, r);
    }

    // -------------------------------------------------------------------
    // get_interaction
    // -------------------------------------------------------------------
    {
      const r = await callTool(client, "get_interaction", { id: "2026-07-20-combs-family-reunion" });
      assertTrue(
        "get_interaction: combs-family-reunion has a Summary section",
        r.summary?.heading === "Summary" && typeof r.summary?.raw === "string" && r.summary.raw.length > 0,
        r.summary,
      );
      assertTrue(
        "get_interaction: combs-family-reunion has a Commitments section",
        r.commitments?.heading === "Commitments" && Array.isArray(r.commitments?.bullets) && r.commitments.bullets.length > 0,
        r.commitments,
      );
      assertTrue(
        "get_interaction: combs-family-reunion cites its source file",
        r.source === "interactions/2026-07-20-combs-family-reunion.md",
        r.source,
      );
    }

    {
      const r = await callTool(client, "get_interaction", { id: "2099-01-01-nobody" });
      assertEqual("get_interaction: unknown id reports not_found", r.error, "not_found");
    }

    // -------------------------------------------------------------------
    // get_contact_stats
    // -------------------------------------------------------------------
    {
      const r = await callTool(client, "get_contact_stats", { slug: "grace-lindqvist" });
      assertEqual("get_contact_stats: grace-lindqvist touchpoints is 11", r.touchpoints, 11);
      assertEqual("get_contact_stats: grace-lindqvist median_gap_days is 31", r.median_gap_days, 31);
      assertTrue(
        "get_contact_stats: grace-lindqvist result carries generated_at",
        typeof r.generated_at === "string" && r.generated_at.length > 0,
        r.generated_at,
      );
      assertTrue(
        "get_contact_stats: grace-lindqvist cites its source(s)",
        Array.isArray(r.sources) && r.sources.length > 0,
        r.sources,
      );
    }

    // -------------------------------------------------------------------
    // generated_at + source/citation present on every tool's results
    // -------------------------------------------------------------------
    {
      const checks = [
        ["search_people", await callTool(client, "search_people", { tier: "inner-circle" })],
        ["get_person", await callTool(client, "get_person", { slug: "grace-lindqvist" })],
        ["list_interactions", await callTool(client, "list_interactions", { slug: "grace-lindqvist" })],
        ["get_interaction", await callTool(client, "get_interaction", { id: "2026-07-20-combs-family-reunion" })],
        ["get_contact_stats", await callTool(client, "get_contact_stats", { slug: "grace-lindqvist" })],
      ];
      for (const [name, result] of checks) {
        assertTrue(
          `${name}: result carries generated_at`,
          typeof result.generated_at === "string" && result.generated_at.length > 0,
          result.generated_at,
        );
      }
    }
  } finally {
    await client.close();
    fs.rmSync(cacheDir, { recursive: true, force: true });
  }

  console.log("");
  console.log(`SUMMARY: ${passCount} passed, ${failCount} failed`);
  process.exit(failCount === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error(`FATAL: ${err?.stack ?? String(err)}`);
  process.exit(1);
});

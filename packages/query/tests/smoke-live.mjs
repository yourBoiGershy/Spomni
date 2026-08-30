// packages/query/tests/smoke-live.mjs
//
// Live-store smoke for the query MCP server (plan 18, unit 2): drives the
// built server (packages/query/server/src/index.ts) over stdio JSON-RPC
// against a real store dir and exercises all six read-only tools
// data-independently — no fixture assumptions, no hand-derived goldens (that
// is test-tools.mjs's job against the fixture store). This script only
// proves "the server answers over this store," not "the answers are
// correct."
//
// Reuses test-tools.mjs's stdio-driving pattern (spawn the real server,
// speak MCP over stdio via the SDK's Client/StdioClientTransport imported
// straight from the query server's own node_modules).
//
// Data independence: pulls a slug from an unfiltered search_people page and
// an interaction id from that person's (or, failing that, any other
// person's) list_interactions page, rather than assuming any particular
// person/interaction exists.
//
// Never writes into the store or the repo — the only filesystem writes are
// whatever the server itself makes under
// ${SPOMNI_CACHE_DIR:-~/.cache/spomni}/derived/ (staleness-cache
// decision, packages/query/server/src/store/staleness.ts). SPOMNI_CACHE_DIR
// (or its deprecated RA_CACHE_DIR fallback) is left exactly as the caller's
// environment sets it (no override) so this smoke exercises the same cache
// path a real session would.
//
// Exit nonzero if: any tool call errors, the store yields zero people
// (empty store), or contact stats come back degraded (staleness.ts's
// emptyStats() fallback — detectable by its epoch generated_at, 1970-01-01,
// since a real stats.json generated_at is never that old).
//
// Run via packages/query/tests/smoke-live.sh.

import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "../../..");
const SERVER_ENTRY = path.join(REPO_ROOT, "packages/query/server/src/index.ts");
const SDK_DIR = path.join(
  REPO_ROOT,
  "packages/query/server/node_modules/@modelcontextprotocol/sdk/dist/esm",
);

// The staleness module's degraded-empty-stats fallback stamps generated_at
// as `new Date(0).toISOString()` — a real store's stats.json is never this
// old, so any tool reporting this generated_at means regeneration failed
// and we're looking at a degraded, empty stats.json.
const DEGRADED_GENERATED_AT = new Date(0).toISOString();

function parseArgs(argv) {
  let storeDir;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--store") {
      storeDir = argv[++i];
    } else if (argv[i].startsWith("--store=")) {
      storeDir = argv[i].slice("--store=".length);
    }
  }
  return { storeDir };
}

let passCount = 0;
let failCount = 0;

function pass(tool, evidence) {
  console.log(`PASS ${tool} (${evidence})`);
  passCount++;
}

function fail(tool, reason) {
  console.log(`FAIL ${tool}: ${reason}`);
  failCount++;
}

/** Calls `toolName` with `args`, parses the tool's single JSON text block. */
async function callTool(client, toolName, args) {
  const result = await client.callTool({ name: toolName, arguments: args });
  if (result.isError) {
    const block = result.content?.[0];
    const detail = block && block.type === "text" ? block.text : JSON.stringify(result);
    throw new Error(detail);
  }
  const block = result.content?.[0];
  if (!block || block.type !== "text") {
    throw new Error(`${toolName}: expected a single text content block, got ${JSON.stringify(result)}`);
  }
  return JSON.parse(block.text);
}

function isDegraded(generatedAt) {
  return generatedAt === DEGRADED_GENERATED_AT;
}

function generatedAtSuffix(generatedAt) {
  return typeof generatedAt === "string" && generatedAt.length > 0
    ? `, generated_at=${generatedAt}`
    : "";
}

async function main() {
  const { storeDir: storeArg } = parseArgs(process.argv.slice(2));

  if (!storeArg) {
    console.log("FAIL smoke: no --store <dir> given");
    console.log("");
    console.log("SUMMARY: 0 passed, 0 failed, no store given");
    process.exit(1);
  }

  const storeDir = path.resolve(storeArg);

  if (!fs.existsSync(SERVER_ENTRY)) {
    console.log(`FAIL smoke: server entry point not found at ${SERVER_ENTRY}`);
    console.log("");
    console.log("SUMMARY: 0 passed, 0 failed, server missing");
    process.exit(1);
  }
  if (!fs.existsSync(SDK_DIR)) {
    console.log(`FAIL smoke: MCP SDK not found at ${SDK_DIR} — run npm install in packages/query/server`);
    console.log("");
    console.log("SUMMARY: 0 passed, 0 failed, sdk missing");
    process.exit(1);
  }
  if (!fs.existsSync(storeDir)) {
    console.log(`FAIL smoke: store dir not found at ${storeDir}`);
    console.log("");
    console.log("SUMMARY: 0 passed, 0 failed, store missing");
    process.exit(1);
  }

  const { Client } = await import(path.join(SDK_DIR, "client/index.js"));
  const { StdioClientTransport } = await import(path.join(SDK_DIR, "client/stdio.js"));

  const transport = new StdioClientTransport({
    command: "node",
    args: ["--experimental-strip-types", SERVER_ENTRY, "--store", storeDir],
    cwd: path.join(REPO_ROOT, "packages/query/server"),
    env: { ...process.env },
    stderr: "pipe",
  });

  const client = new Client({ name: "ra-query-smoke-live", version: "0.1.0" });

  try {
    await client.connect(transport);
  } catch (err) {
    console.log(`FAIL smoke: could not connect to the query MCP server: ${String(err)}`);
    console.log("");
    console.log("SUMMARY: 0 passed, 0 failed, server did not start");
    process.exit(1);
  }

  try {
    // -----------------------------------------------------------------
    // search_people — unfiltered first page. Data-independent entry
    // point: every other per-person tool derives its slug from here.
    // -----------------------------------------------------------------
    let slug = null;
    let searchTotal = 0;
    try {
      const r = await callTool(client, "search_people", {});
      searchTotal = r.total ?? 0;
      if (searchTotal === 0 || !Array.isArray(r.results) || r.results.length === 0) {
        fail("search_people", "empty store (total=0)");
      } else {
        slug = r.results[0].slug;
        pass("search_people", `total=${searchTotal}${generatedAtSuffix(r.generated_at)}`);
      }
    } catch (err) {
      fail("search_people", String(err?.message ?? err));
    }

    // -----------------------------------------------------------------
    // get_person
    // -----------------------------------------------------------------
    if (slug) {
      try {
        const r = await callTool(client, "get_person", { slug });
        if (r.error) {
          fail("get_person", `slug ${slug} from search_people reported ${r.error}`);
        } else if (!r.frontmatter || !r.source) {
          fail("get_person", `missing frontmatter/source for slug ${slug}`);
        } else {
          pass("get_person", `slug=${slug}${generatedAtSuffix(r.generated_at)}`);
        }
      } catch (err) {
        fail("get_person", String(err?.message ?? err));
      }
    } else {
      fail("get_person", "skipped: no person available (empty store)");
    }

    // -----------------------------------------------------------------
    // list_interactions — also the source of an interaction id for
    // get_interaction below. If the first slug has none, fall back to
    // scanning the rest of search_people's page (a person with zero
    // filed interactions is a valid, non-error state, per list-
    // interactions.ts, so this is not itself a failure).
    // -----------------------------------------------------------------
    let interactionId = null;
    if (slug) {
      try {
        const r = await callTool(client, "list_interactions", { slug });
        if (r.error) {
          fail("list_interactions", `slug ${slug} reported ${r.error}`);
        } else if (!Array.isArray(r.interactions)) {
          fail("list_interactions", `malformed response for slug ${slug}`);
        } else {
          pass("list_interactions", `slug=${slug}, total=${r.total}${generatedAtSuffix(r.generated_at)}`);
          if (r.interactions.length > 0) {
            interactionId = r.interactions[0].id;
          }
        }
      } catch (err) {
        fail("list_interactions", String(err?.message ?? err));
      }
    } else {
      fail("list_interactions", "skipped: no person available (empty store)");
    }

    // If the first person had no filed interactions, scan a few more
    // search_people results for one that does, so get_interaction still
    // gets a real id to exercise when the store has interactions at all.
    if (!interactionId && slug) {
      try {
        const wide = await callTool(client, "search_people", {});
        for (const person of wide.results ?? []) {
          if (person.slug === slug) continue;
          const li = await callTool(client, "list_interactions", { slug: person.slug });
          if (Array.isArray(li.interactions) && li.interactions.length > 0) {
            interactionId = li.interactions[0].id;
            break;
          }
        }
      } catch {
        // Best-effort only — get_interaction below falls back to the
        // not_found path if this turns up nothing.
      }
    }

    // -----------------------------------------------------------------
    // get_interaction
    // -----------------------------------------------------------------
    try {
      if (interactionId) {
        const r = await callTool(client, "get_interaction", { id: interactionId });
        if (r.error || !r.source) {
          fail("get_interaction", `id ${interactionId} reported ${r.error ?? "missing source"}`);
        } else {
          pass("get_interaction", `id=${interactionId}${generatedAtSuffix(r.generated_at)}`);
        }
      } else {
        // No interaction exists anywhere in the store — still a real,
        // data-independent path: confirm the not_found handling works.
        const r = await callTool(client, "get_interaction", { id: "smoke-live-no-such-interaction" });
        if (r.error === "not_found") {
          pass("get_interaction", `not_found path verified (store has no interactions)${generatedAtSuffix(r.generated_at)}`);
        } else {
          fail("get_interaction", `expected not_found for a bogus id, got ${JSON.stringify(r)}`);
        }
      }
    } catch (err) {
      fail("get_interaction", String(err?.message ?? err));
    }

    // -----------------------------------------------------------------
    // get_contact_stats — also the degraded-stats detection point.
    // -----------------------------------------------------------------
    if (slug) {
      try {
        const r = await callTool(client, "get_contact_stats", { slug });
        if (isDegraded(r.generated_at)) {
          fail("get_contact_stats", `degraded empty stats (generated_at=${r.generated_at})`);
        } else if (r.error) {
          fail("get_contact_stats", `slug ${slug} reported ${r.error}`);
        } else if (typeof r.generated_at !== "string" || r.generated_at.length === 0) {
          fail("get_contact_stats", "missing generated_at");
        } else {
          pass(
            "get_contact_stats",
            `slug=${slug}, touchpoints=${r.touchpoints}${generatedAtSuffix(r.generated_at)}`,
          );
        }
      } catch (err) {
        fail("get_contact_stats", String(err?.message ?? err));
      }
    } else {
      fail("get_contact_stats", "skipped: no person available (empty store)");
    }

    // -----------------------------------------------------------------
    // suggest_reachouts — must pass even over a store with no attention
    // artifacts; absence is a tested path, not a failure.
    // -----------------------------------------------------------------
    try {
      const r = await callTool(client, "suggest_reachouts", {});
      if (isDegraded(r.generated_at)) {
        fail("suggest_reachouts", `degraded empty stats (generated_at=${r.generated_at})`);
      } else if (!Array.isArray(r.suggestions) || typeof r.count !== "number") {
        fail("suggest_reachouts", `malformed response: ${JSON.stringify(r)}`);
      } else {
        pass("suggest_reachouts", `count=${r.count}${generatedAtSuffix(r.generated_at)}`);
      }
    } catch (err) {
      fail("suggest_reachouts", String(err?.message ?? err));
    }
  } finally {
    await client.close();
  }

  console.log("");
  console.log(`SUMMARY: ${passCount} passed, ${failCount} failed`);
  process.exit(failCount === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error(`FATAL: ${err?.stack ?? String(err)}`);
  process.exit(1);
});

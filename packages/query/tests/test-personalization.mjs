// packages/query/tests/test-personalization.mjs
//
// T1 personalization golden tests (plan 12, unit 3, $0): overlays the
// plan-11 personalization fixtures (profile.md, ranking-weights.json,
// wakeup v1.1 files — packages/query/tests/fixtures/personalization-overlay/)
// onto the 30-persona base fixture store, spawns the real query MCP server
// over stdio exactly per test-tools.mjs's pattern, and pins four goldens:
//
//   (a) XFAIL — opted-out signal-type absent from suggest_reachouts.
//   (b) XFAIL — ranking-weights multiply fallback scores.
//   (c) PASS  — all six tools succeed against v1.1 wakeup fields.
//   (d) PASS  — store byte-identical after a full tool sweep.
//
// suggest_reachouts today (per docs/plans/2026-08-29-12-eval-harness.md's
// "Known gap pinned as xfail" and packages/query/server/src/tools/
// suggest-reachouts.ts) surfaces pending wake-ups due within 30 days
// (source: attention), else a heuristic staleness_ratio*10 + tier_weight*5 +
// open_threads*3 (source: heuristic-fallback) — and reads neither
// profile.md nor ranking-weights.json. That is exactly what (a) and (b)
// pin as expected-to-fail until plan-13 ("query-personalization
// integration") lands; every expected value below is hand-derived from the
// fixture files below using that known formula — never read off the
// server's own output — per docs/DECISIONS.md's golden-tests-before-prompts
// rule (same precedent as test-tools.mjs).
//
// Hand-derivation notes (cited):
//   - Opt-out target: packages/query/tests/fixtures/personalization-overlay/
//     wakeups/2026-09-10-marcus-chen--2.md — schema_version 1.1.0, status
//     pending, signal-type birthday, due 2026-09-10 (within the 30-day
//     attention window of "today"). profile.md's `## Signal opt-outs`
//     bullet is `birthday — all`, so a personalization-aware
//     suggest_reachouts must never surface this wake-up's id. Today it does
//     (opt-outs aren't read yet), so asserting its absence fails — XFAIL.
//   - Weight target: packages/core/fixtures/store/people/aiko-tanaka.md
//     carries tag `college-friend`, which ranking-weights.json boosts to
//     1.15. She has exactly one interaction
//     (packages/core/fixtures/store/interactions/2025-12-05-aiko-tanaka.md,
//     last_interaction 2025-12-05 => median_gap_days is null, fewer than two
//     interactions), tier `dormant` (TIER_WEIGHT 1), and one `## Open
//     threads` bullet in her person file (open_threads 1). She holds no
//     pending wake-up, so she is a pure heuristic-fallback candidate, and
//     her unweighted score (~52.5, comfortably clear of every other
//     fallback candidate's score except yusuf-demir's ~58 — both rank ahead
//     of every non-attention person, guaranteeing she surfaces in the top-3
//     fallback slots once the 7 in-window attention wake-ups fill the rest
//     of a limit:10 call) is nowhere near what `score * 1.15` would be. A
//     weights-aware fallback score for her must equal `score * 1.15`;
//     today's unweighted score does not, so asserting equality fails —
//     XFAIL.
//   - v1.1 round-trip fixtures: wakeups/2026-08-20-ravi-kapoor.md (dismissed
//     + dismiss-reason), wakeups/2026-08-22-priya-anand.md (fired +
//     acted-on: true), wakeups/2026-09-25-katarina-novak--2.md (pending +
//     snooze-count: 2) — all schema_version 1.1.0. None of these opt out or
//     match a non-neutral weight, so all six tools must simply succeed
//     against a store containing them, and (per the wakeup contract) the
//     store must be byte-identical after a full read-only tool sweep.
//
// Run via packages/query/tests/run-query-tests.sh (wired alongside
// test-tools.mjs).

import { fileURLToPath } from "node:url";
import path from "node:path";
import os from "node:os";
import fs from "node:fs";
import crypto from "node:crypto";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "../../..");
const SERVER_ENTRY = path.join(REPO_ROOT, "packages/query/server/src/index.ts");
const BASE_FIXTURE_STORE = path.join(REPO_ROOT, "packages/core/fixtures/store");
const OVERLAY_DIR = path.join(__dirname, "fixtures/personalization-overlay");
const SDK_DIR = path.join(
  REPO_ROOT,
  "packages/query/server/node_modules/@modelcontextprotocol/sdk/dist/esm",
);

const { Client } = await import(path.join(SDK_DIR, "client/index.js"));
const { StdioClientTransport } = await import(path.join(SDK_DIR, "client/stdio.js"));

let passCount = 0;
let failCount = 0;
let xfailCount = 0;
let xpassCount = 0;

function record(status, label, detail) {
  console.log(`${status}: ${label}`);
  if (detail !== undefined) {
    console.log(`  ${typeof detail === "string" ? detail : JSON.stringify(detail)}`);
  }
}

/** A normal must-pass assertion (goldens c/d and their internal checks). */
function assertTrue(label, condition, detail) {
  if (condition) {
    record("PASS", label);
    passCount++;
  } else {
    record("FAIL", label, detail);
    failCount++;
  }
}

function assertEqual(label, actual, expected) {
  assertTrue(label, actual === expected, `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

/**
 * An xfail-marked assertion (goldens a/b): `fixedConditionMet` is the
 * condition that will be true only once the named integration lands. If it
 * is already true, that is XPASS (suite-red — the gap silently closed
 * without the case being flipped to must-pass); if false (today's known
 * gap), that is XFAIL (suite-green).
 */
function assertXfail(label, fixedConditionMet, flipCondition, detail) {
  if (fixedConditionMet) {
    record("XPASS", label, detail);
    console.log(`  flip condition met — drop xfail and make this must-pass: ${flipCondition}`);
    xpassCount++;
  } else {
    record("XFAIL", label, detail);
    console.log(`  expected until: ${flipCondition}`);
    xfailCount++;
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

/** sha256 of every regular file under `dir`, keyed by repo-relative-to-`dir` path. */
function hashTree(dir) {
  const hashes = {};
  const walk = (current) => {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) {
        walk(full);
      } else if (entry.isFile()) {
        const rel = path.relative(dir, full);
        hashes[rel] = crypto.createHash("sha256").update(fs.readFileSync(full)).digest("hex");
      }
    }
  };
  walk(dir);
  return hashes;
}

function assertTreeUnchanged(label, before, after) {
  const beforeKeys = Object.keys(before).sort();
  const afterKeys = Object.keys(after).sort();
  const sameFileSet = JSON.stringify(beforeKeys) === JSON.stringify(afterKeys);
  if (!sameFileSet) {
    assertTrue(label, false, {
      onlyBefore: beforeKeys.filter((k) => !afterKeys.includes(k)),
      onlyAfter: afterKeys.filter((k) => !beforeKeys.includes(k)),
    });
    return;
  }
  const changed = beforeKeys.filter((k) => before[k] !== after[k]);
  assertTrue(label, changed.length === 0, { changed });
}

/** Same heuristic-fallback formula suggest-reachouts.ts implements today
 * (staleness_ratio*10 + tier_weight*5 + open_threads*3) — hand-copied from
 * the formula named in the brief, not read off any tool output, and
 * evaluated against `nowMs` the same way the server does so this stays
 * correct wherever "today" the test runs. */
const TIER_WEIGHT = { "inner-circle": 4, close: 3, active: 2, dormant: 1 };
const NO_CADENCE_BASELINE_DAYS = 60;

function expectedUnweightedFallbackScore({ lastInteractionIso, medianGapDays, tier, openThreads, nowMs }) {
  const daysStale = Math.floor((nowMs - Date.parse(lastInteractionIso)) / 86_400_000);
  const stalenessRatio =
    medianGapDays !== null && medianGapDays > 0 ? daysStale / medianGapDays : daysStale / NO_CADENCE_BASELINE_DAYS;
  const tierWeight = tier !== null ? (TIER_WEIGHT[tier] ?? 0) : 0;
  const score = stalenessRatio * 10 + tierWeight * 5 + openThreads * 3;
  return Math.round(score * 100) / 100;
}

async function main() {
  if (!fs.existsSync(SERVER_ENTRY) || !fs.existsSync(SDK_DIR) || !fs.existsSync(BASE_FIXTURE_STORE)) {
    console.log("SKIP: server, SDK, or fixture store missing — see test-tools.mjs's SKIP checks");
    console.log("");
    console.log("SUMMARY: 0 passed, 0 failed, 0 xfail, 0 xpass — dependency missing");
    process.exit(1);
  }
  if (!fs.existsSync(OVERLAY_DIR)) {
    console.log(`SKIP: personalization overlay fixtures not found at ${OVERLAY_DIR}`);
    console.log("");
    console.log("SUMMARY: 0 passed, 0 failed, 0 xfail, 0 xpass — overlay fixtures missing");
    process.exit(1);
  }

  // Overlay the fixtures onto a scratch copy of the base store, per the
  // overlay fixture's own README's "How to overlay" recipe — never onto
  // packages/core/fixtures/store/ in place.
  const tempStore = fs.mkdtempSync(path.join(os.tmpdir(), "ra-personalization-test-store-"));
  const cacheDir = fs.mkdtempSync(path.join(os.tmpdir(), "ra-personalization-test-cache-"));

  fs.cpSync(BASE_FIXTURE_STORE, tempStore, { recursive: true });
  fs.cpSync(path.join(OVERLAY_DIR, "profile.md"), path.join(tempStore, "profile.md"));
  fs.cpSync(path.join(OVERLAY_DIR, "ranking-weights.json"), path.join(tempStore, "ranking-weights.json"));
  fs.cpSync(path.join(OVERLAY_DIR, "wakeups"), path.join(tempStore, "wakeups"), { recursive: true });

  const transport = new StdioClientTransport({
    command: "node",
    args: ["--experimental-strip-types", SERVER_ENTRY, "--store", tempStore],
    cwd: path.join(REPO_ROOT, "packages/query/server"),
    env: { ...process.env, RA_CACHE_DIR: cacheDir },
    stderr: "pipe",
  });

  const client = new Client({ name: "ra-personalization-golden-tests", version: "0.1.0" });

  try {
    await client.connect(transport);
  } catch (err) {
    console.log(`SKIP: could not connect to the query MCP server: ${String(err)}`);
    console.log("");
    console.log("SUMMARY: 0 passed, 0 failed, 0 xfail, 0 xpass — server did not start");
    fs.rmSync(tempStore, { recursive: true, force: true });
    fs.rmSync(cacheDir, { recursive: true, force: true });
    process.exit(1);
  }

  const beforeHashes = hashTree(tempStore);

  try {
    // -------------------------------------------------------------------
    // (c) MUST-PASS — all six tools succeed against v1.1 wakeup fields.
    // -------------------------------------------------------------------
    {
      const s = await callTool(client, "search_people", {});
      assertTrue("(c) search_people succeeds against the overlaid store", s.error === undefined && Array.isArray(s.results), s);

      const p = await callTool(client, "get_person", { slug: "priya-anand" });
      assertTrue("(c) get_person succeeds against the overlaid store", p.error === undefined && p.frontmatter?.name === "Priya Anand", p);

      const li = await callTool(client, "list_interactions", { slug: "priya-anand" });
      assertTrue("(c) list_interactions succeeds against the overlaid store", li.error === undefined && Array.isArray(li.interactions), li);

      const gi = await callTool(client, "get_interaction", { id: "2026-08-20-priya-anand" });
      assertTrue("(c) get_interaction succeeds against the overlaid store", gi.error === undefined && typeof gi.source === "string", gi);

      const cs = await callTool(client, "get_contact_stats", { slug: "priya-anand" });
      assertTrue("(c) get_contact_stats succeeds against the overlaid store", cs.error === undefined, cs);

      const sr = await callTool(client, "suggest_reachouts", { limit: 10 });
      assertTrue("(c) suggest_reachouts succeeds against the overlaid store", sr.error === undefined && Array.isArray(sr.suggestions), sr);

      // The overlay's v1.1 wake-ups are present and parsed without error —
      // katarina-novak--2 (schema_version 1.1.0, snooze-count: 2, pending,
      // due 2026-09-25, no opt-out or weight applies to it) is the
      // uncontroversial one to assert present: it is not the opt-out
      // target and its due date sits inside the 30-day attention window,
      // so it surfaces regardless of whether plan-13 has landed.
      assertTrue(
        "(c) overlay's v1.1 pending wake-up (katarina-novak--2) is present in suggest_reachouts",
        sr.suggestions.some((sug) => sug.slug === "2026-09-25-katarina-novak--2"),
        sr.suggestions.map((sug) => sug.slug),
      );
    }

    // -------------------------------------------------------------------
    // (a) XFAIL — opted-out signal-type absent from suggest_reachouts.
    // -------------------------------------------------------------------
    {
      const sr = await callTool(client, "suggest_reachouts", { limit: 10 });
      const optedOutAbsent = !sr.suggestions.some((sug) => sug.slug === "2026-09-10-marcus-chen--2");
      assertXfail(
        "(a) marcus-chen's opted-out birthday wake-up (2026-09-10-marcus-chen--2) is absent from suggest_reachouts",
        optedOutAbsent,
        "plan-13 query-personalization integration",
        { slugs: sr.suggestions.map((sug) => sug.slug) },
      );
    }

    // -------------------------------------------------------------------
    // (b) XFAIL — ranking-weights multiply fallback scores.
    // -------------------------------------------------------------------
    {
      const sr = await callTool(client, "suggest_reachouts", { limit: 10 });
      const aiko = sr.suggestions.find((sug) => sug.slug === "aiko-tanaka" && sug.source === "heuristic-fallback");
      assertTrue(
        "(b) precondition: aiko-tanaka (tag college-friend, weight 1.15) surfaces as a heuristic-fallback candidate",
        aiko !== undefined,
        sr.suggestions.map((sug) => sug.slug),
      );

      if (aiko !== undefined) {
        const expectedWeighted =
          Math.round(
            expectedUnweightedFallbackScore({
              lastInteractionIso: "2025-12-05",
              medianGapDays: null,
              tier: "dormant",
              openThreads: 1,
              nowMs: Date.now(),
            }) *
              1.15 *
              100,
          ) / 100;

        assertXfail(
          "(b) aiko-tanaka's fallback score reflects the ranking-weights.json college-friend 1.15x multiplier",
          aiko.breakdown.score === expectedWeighted,
          "plan-13 query-personalization integration",
          { actual: aiko.breakdown.score, expectedWeighted },
        );
      }
    }

    // -------------------------------------------------------------------
    // (d) MUST-PASS — store byte-identical after the full tool sweep above.
    // -------------------------------------------------------------------
    {
      const afterHashes = hashTree(tempStore);
      assertTreeUnchanged("(d) overlaid store is byte-identical after the full tool sweep", beforeHashes, afterHashes);
    }
  } finally {
    await client.close();
    fs.rmSync(tempStore, { recursive: true, force: true });
    fs.rmSync(cacheDir, { recursive: true, force: true });
  }

  console.log("");
  console.log(
    `SUMMARY: ${passCount} passed, ${failCount} failed, ${xfailCount} xfail, ${xpassCount} xpass`,
  );
  process.exit(failCount === 0 && xpassCount === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error(`FATAL: ${err?.stack ?? String(err)}`);
  process.exit(1);
});

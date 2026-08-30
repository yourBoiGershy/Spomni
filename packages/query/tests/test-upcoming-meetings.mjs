// packages/query/tests/test-upcoming-meetings.mjs
//
// Unit tests for the `upcoming_meetings` query-server tool
// (packages/query/server/src/tools/upcoming-meetings.ts): window filtering,
// the people join (slug + display name, reported verbatim from the filing
// engine's own frontmatter -- never re-derived), the honest empty-window
// shape, and citation paths.
//
// Unlike test-tools.mjs this file does NOT spawn the MCP server over stdio:
// `upcomingMeetings(reader, days, nowMs)` takes an explicit `nowMs`, and the
// registered MCP tool's input schema only exposes `days` (no way to pin
// "now" through a real tool call). So these tests import the module
// directly (Node 22.6+ strips `.ts` types natively -- no build step needed,
// matching how staleness.ts/reader.ts are already imported live by the
// server) and drive `upcomingMeetings` against a `StoreReader` built the
// same way the server builds one (`ensureFresh`), pointed at the 30-persona
// fixture store (packages/core/fixtures/store/) for goldens anchored in it.
//
// Every fixture interaction file carries a `calendar-event` (confirmed by
// grep across packages/core/fixtures/store/interactions/*.md), so the
// "interaction inside the window but with no calendar-event is excluded"
// case can't be anchored in the fixture store as-is. That case uses one
// purpose-built, self-contained scratch store instead (a fresh tmp dir,
// never inside the fixture store) with a copy of grace-lindqvist's real
// person + calendar interaction plus one synthetic non-calendar interaction
// dated the next day. `ensureFresh` never writes into the store dir it's
// given (staleness.ts's own contract -- it regenerates index.json/stats.json
// into SPOMNI_CACHE_DIR only), so both the real fixture store and the scratch
// store stay pristine; a git-clean check on the fixture dir after the run
// confirms it for the real one.
//
// registerUpcomingMeetings is exercised too, via a minimal fake McpServer
// that just records the registered tool + handler, so the MCP wiring itself
// (tool name, default days, JSON-text response shape) is covered without a
// second process spawn.

import { fileURLToPath } from "node:url";
import path from "node:path";
import os from "node:os";
import fs from "node:fs";
import { execFileSync } from "node:child_process";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "../../..");
const FIXTURE_STORE = path.join(REPO_ROOT, "packages/core/fixtures/store");
const QUERY_SERVER_DIR = path.join(REPO_ROOT, "packages/query/server");
const STALENESS_MODULE = path.join(QUERY_SERVER_DIR, "src/store/staleness.ts");
const UPCOMING_MEETINGS_MODULE = path.join(QUERY_SERVER_DIR, "src/tools/upcoming-meetings.ts");

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

/** Builds a fresh `StoreReader` over `storeDir`, exactly like the server's
 * own entry point (index.ts's `ensureFresh(storeDir)` call), with its own
 * isolated cache dir so regeneration never touches `~/.cache` or leaves
 * anything the caller has to clean up inside the store itself. */
async function makeReader(storeDir) {
  const cacheDir = fs.mkdtempSync(path.join(os.tmpdir(), "ra-upcoming-meetings-test-cache-"));
  const prevCacheDir = process.env.SPOMNI_CACHE_DIR;
  process.env.SPOMNI_CACHE_DIR = cacheDir;
  try {
    const { ensureFresh } = await import(STALENESS_MODULE);
    const { reader } = ensureFresh(storeDir);
    return reader;
  } finally {
    if (prevCacheDir === undefined) {
      delete process.env.SPOMNI_CACHE_DIR;
    } else {
      process.env.SPOMNI_CACHE_DIR = prevCacheDir;
    }
    fs.rmSync(cacheDir, { recursive: true, force: true });
  }
}

/** Builds a minimal, self-contained scratch store (never inside the real
 * fixture store) with grace-lindqvist's real person file, her real
 * 2025-10-03 calendar interaction, and one synthetic 2025-10-04 interaction
 * with `calendar-event: null` -- the one shape absent from the fixture
 * store, needed to test the "no calendar-event" exclusion. */
function makeNoCalendarScratchStore() {
  const scratchDir = fs.mkdtempSync(path.join(os.tmpdir(), "ra-upcoming-meetings-test-store-"));
  fs.mkdirSync(path.join(scratchDir, "people"), { recursive: true });
  fs.mkdirSync(path.join(scratchDir, "interactions"), { recursive: true });

  fs.copyFileSync(
    path.join(FIXTURE_STORE, "people/grace-lindqvist.md"),
    path.join(scratchDir, "people/grace-lindqvist.md"),
  );
  fs.copyFileSync(
    path.join(FIXTURE_STORE, "interactions/2025-10-03-grace-lindqvist.md"),
    path.join(scratchDir, "interactions/2025-10-03-grace-lindqvist.md"),
  );
  fs.writeFileSync(
    path.join(scratchDir, "interactions/2025-10-04-grace-lindqvist-coffee.md"),
    `---
schema_version: 1.0.0
date: 2025-10-04
people: ["[[grace-lindqvist]]"]
calendar-event: null
source-capture: null
---

## Summary

Quick informal coffee chat, no calendar invite behind it.

## Commitments

_none_
`,
  );

  return scratchDir;
}

/** Minimal fake of the MCP SDK's McpServer -- just enough surface for
 * `registerUpcomingMeetings` to register a tool and for the test to invoke
 * its handler directly, without spawning a real MCP server process. */
function makeFakeServer() {
  const tools = new Map();
  return {
    registerTool(name, config, handler) {
      tools.set(name, { config, handler });
    },
    tools,
  };
}

async function main() {
  if (!fs.existsSync(UPCOMING_MEETINGS_MODULE)) {
    console.log(`SKIP: upcoming-meetings.ts not found at ${UPCOMING_MEETINGS_MODULE}`);
    console.log("");
    console.log("SUMMARY: 0 passed, 0 failed, module missing");
    process.exit(1);
  }
  if (!fs.existsSync(FIXTURE_STORE)) {
    console.log(`SKIP: fixture store not found at ${FIXTURE_STORE}`);
    console.log("");
    console.log("SUMMARY: 0 passed, 0 failed, fixture store missing");
    process.exit(1);
  }

  const { upcomingMeetings, registerUpcomingMeetings } = await import(UPCOMING_MEETINGS_MODULE);

  const fixtureReader = await makeReader(FIXTURE_STORE);

  // -------------------------------------------------------------------
  // Window filtering + people join + citation path (anchored on
  // interactions/2025-10-03-grace-lindqvist.md, calendar-event
  // gcal-evt-3301 -- packages/core/fixtures/store's only interaction on
  // that date).
  // -------------------------------------------------------------------
  {
    const nowMs = new Date("2025-10-03T00:00:00Z").getTime();
    const r = upcomingMeetings(fixtureReader, 1, nowMs);

    assertEqual("window filtering: days=1 anchored on 2025-10-03 returns exactly 1 meeting", r.count, 1);
    assertEqual("window filtering: meetings array length matches count", r.meetings.length, 1);

    const meeting = r.meetings[0];
    assertEqual("window filtering: meeting id is the grace-lindqvist interaction", meeting?.id, "2025-10-03-grace-lindqvist");
    assertEqual("window filtering: meeting date is 2025-10-03", meeting?.date, "2025-10-03");
    assertEqual("window filtering: meeting calendar_event is gcal-evt-3301", meeting?.calendar_event, "gcal-evt-3301");
    assertTrue(
      "window filtering: meeting summary is the interaction's first Summary line",
      meeting?.summary === "Monthly mentoring call with Grace. She's thinking about applying for a",
      meeting?.summary,
    );

    assertEqual("people join: meeting has exactly 1 matched person", meeting?.people?.length, 1);
    assertEqual("people join: matched person slug is grace-lindqvist", meeting?.people?.[0]?.slug, "grace-lindqvist");
    assertEqual(
      "people join: matched person display name is derived from the slug (Grace Lindqvist)",
      meeting?.people?.[0]?.name,
      "Grace Lindqvist",
    );

    assertEqual(
      "citation: meeting source path points at the interaction file",
      meeting?.source,
      "interactions/2025-10-03-grace-lindqvist.md",
    );
    assertTrue(
      "citation: the cited path exists on disk under the fixture store",
      fs.existsSync(path.join(FIXTURE_STORE, meeting?.source ?? "")),
      meeting?.source,
    );

    assertEqual("window: window.from matches the anchored today", r.window?.from, "2025-10-03");
    assertEqual("window: window.to matches today + days", r.window?.to, "2025-10-04");
    assertTrue("window: result carries generated_at", typeof r.generated_at === "string" && r.generated_at.length > 0, r.generated_at);
  }

  // -------------------------------------------------------------------
  // Default days=7 behavior (registerUpcomingMeetings's handler, called
  // with `days` omitted -- exercises the MCP wiring, not just the bare
  // function's own default parameter).
  // -------------------------------------------------------------------
  {
    const fakeServer = makeFakeServer();
    registerUpcomingMeetings(fakeServer, fixtureReader);

    assertTrue("registration: upcoming_meetings tool is registered", fakeServer.tools.has("upcoming_meetings"), [...fakeServer.tools.keys()]);

    const registered = fakeServer.tools.get("upcoming_meetings");
    const response = registered.handler({ days: undefined });
    const block = response.content?.[0];
    assertTrue(
      "registration: handler returns a single JSON text content block",
      block?.type === "text" && typeof block.text === "string",
      response,
    );
    const parsed = JSON.parse(block.text);
    assertEqual("default days: omitting `days` defaults the result to days=7", parsed.days, 7);

    // Anchored on the real system clock (Date.now(), since the registered
    // handler has no nowMs override) -- packages/core/fixtures/store's
    // newest filed interaction is 2026-08-27-hana-kobayashi.md, so unless
    // this suite runs on/before that date the 7-day window from "now" is
    // legitimately empty. Assert the honest-empty shape either way rather
    // than hardcoding a day-dependent count.
    if (parsed.count === 0) {
      assertEqual("default days: empty window returns an empty meetings array", parsed.meetings.length, 0);
      assertTrue(
        "default days: empty window carries an honest message, not an error",
        typeof parsed.message === "string" && parsed.message.length > 0 && parsed.error === undefined,
        parsed,
      );
    } else {
      assertTrue("default days: non-empty window still returns a meetings array", Array.isArray(parsed.meetings), parsed);
    }
  }

  // -------------------------------------------------------------------
  // Far-future / empty window -> honest empty shape.
  // -------------------------------------------------------------------
  {
    const nowMs = new Date("2099-01-01T00:00:00Z").getTime();
    const r = upcomingMeetings(fixtureReader, 7, nowMs);

    assertEqual("empty window: far-future window has count 0", r.count, 0);
    assertEqual("empty window: far-future window has an empty meetings array", r.meetings.length, 0);
    assertTrue(
      "empty window: far-future window carries a message and no error",
      typeof r.message === "string" && r.message.length > 0 && r.error === undefined,
      r,
    );
    assertTrue(
      "empty window: far-future window still carries generated_at",
      typeof r.generated_at === "string" && r.generated_at.length > 0,
      r.generated_at,
    );
  }

  // -------------------------------------------------------------------
  // Interaction inside the window but with no calendar-event is excluded.
  // Fixture store has no such interaction (every interactions/*.md file
  // carries calendar-event), so this uses a purpose-built scratch store
  // (see makeNoCalendarScratchStore's doc comment).
  // -------------------------------------------------------------------
  let scratchStore;
  try {
    scratchStore = makeNoCalendarScratchStore();
    const scratchReader = await makeReader(scratchStore);

    const nowMs = new Date("2025-10-03T00:00:00Z").getTime();
    const r = upcomingMeetings(scratchReader, 2, nowMs);

    assertEqual(
      "exclusion: window covering both interactions still returns only the calendar one",
      r.count,
      1,
    );
    assertEqual(
      "exclusion: the one returned meeting is the calendar interaction, not the no-calendar-event one",
      r.meetings[0]?.id,
      "2025-10-03-grace-lindqvist",
    );
    assertTrue(
      "exclusion: the no-calendar-event interaction id is absent from the results",
      !r.meetings.some((m) => m.id === "2025-10-04-grace-lindqvist-coffee"),
      r.meetings,
    );
  } finally {
    if (scratchStore) fs.rmSync(scratchStore, { recursive: true, force: true });
  }

  // -------------------------------------------------------------------
  // Read-only: the fixture store is untouched by any of the above (no
  // index.json/stats.json written into it, no interaction/person file
  // modified).
  // -------------------------------------------------------------------
  {
    let gitCleanDetail = "git not available or repo check failed";
    let isClean = false;
    try {
      const out = execFileSync("git", ["status", "--porcelain", FIXTURE_STORE], {
        cwd: REPO_ROOT,
        encoding: "utf8",
      });
      isClean = out.trim().length === 0;
      gitCleanDetail = out;
    } catch (err) {
      gitCleanDetail = String(err);
    }
    assertTrue("read-only: fixture store is git-clean after the run", isClean, gitCleanDetail);
    assertTrue(
      "read-only: no index.json was written into the fixture store",
      !fs.existsSync(path.join(FIXTURE_STORE, "index.json")),
      FIXTURE_STORE,
    );
    assertTrue(
      "read-only: no stats.json was written into the fixture store",
      !fs.existsSync(path.join(FIXTURE_STORE, "stats.json")),
      FIXTURE_STORE,
    );
  }

  console.log("");
  console.log(`SUMMARY: ${passCount} passed, ${failCount} failed`);
  process.exit(failCount === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error(`FATAL: ${err?.stack ?? String(err)}`);
  process.exit(1);
});

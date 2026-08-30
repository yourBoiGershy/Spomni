// Staleness / cache module — docs/DECISIONS.md#staleness-cache.
//
// The store dir itself is NEVER written by this module. index.json/stats.json
// remain ingestion's alone to write there. When this module decides the
// store's copies are stale (or missing), it shells out to core's
// build-index.sh / build-stats.sh against a scratch dir of symlinks (so the
// scripts' own "<store-dir>/index.json" output convention never lands inside
// the real store) and copies the result into
// `${SPOMNI_CACHE_DIR:-$HOME/.cache/spomni}/derived/<store-hash>/`
// (RA_CACHE_DIR is a deprecated fallback),
// then serves from whichever of store-copy vs. cache-copy is freshest.

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

import { MarkdownStoreReader, type StoreReader } from "./reader.ts";
import type { IndexFile, StatsFile } from "./types.ts";

const CORE_SCRIPTS_DIR =
  process.env.SPOMNI_CORE_SCRIPTS_DIR ??
  process.env.RA_CORE_SCRIPTS_DIR ??
  path.resolve(import.meta.dirname, "../../../../core/scripts");

function cacheRootDir(): string {
  return (
    process.env.SPOMNI_CACHE_DIR ??
    process.env.RA_CACHE_DIR ??
    path.join(os.homedir(), ".cache", "spomni")
  );
}

function storeHash(absStoreDir: string): string {
  return crypto.createHash("sha1").update(absStoreDir).digest("hex").slice(0, 12);
}

/** Newest mtime among every file under `people/` and `interactions/`. */
function newestSourceMtime(absStoreDir: string): number {
  let newest = 0;
  for (const sub of ["people", "interactions"]) {
    const dir = path.join(absStoreDir, sub);
    if (!fs.existsSync(dir)) continue;
    for (const entry of fs.readdirSync(dir)) {
      if (!entry.endsWith(".md")) continue;
      const mtimeMs = fs.statSync(path.join(dir, entry)).mtimeMs;
      if (mtimeMs > newest) newest = mtimeMs;
    }
  }
  return newest;
}

/**
 * The effective "as-of" time of a derived JSON file: `generated_at` if the
 * file parses and has one (stats.json), else the file's own mtime
 * (index.json carries no such field — see derived-index.md's Notes). `null`
 * if the file doesn't exist or fails to parse.
 */
function effectiveGeneratedAtMs(filePath: string): number | null {
  if (!fs.existsSync(filePath)) return null;
  const stat = fs.statSync(filePath);
  try {
    const parsed: unknown = JSON.parse(fs.readFileSync(filePath, "utf8"));
    if (
      parsed &&
      typeof parsed === "object" &&
      "generated_at" in parsed &&
      typeof (parsed as { generated_at: unknown }).generated_at === "string"
    ) {
      const asMs = Date.parse((parsed as { generated_at: string }).generated_at);
      if (!Number.isNaN(asMs)) return asMs;
    }
  } catch {
    return null;
  }
  return stat.mtimeMs;
}

/**
 * Picks whichever of `storePath` / `cachePath` is fresh relative to
 * `threshold` (newest source mtime), preferring the store copy. Returns
 * `null` if neither is fresh enough.
 */
function chooseFreshCopy(
  storePath: string,
  cachePath: string,
  threshold: number,
): string | null {
  const storeAt = effectiveGeneratedAtMs(storePath);
  if (storeAt !== null && storeAt >= threshold) return storePath;

  const cacheAt = effectiveGeneratedAtMs(cachePath);
  if (cacheAt !== null && cacheAt >= threshold) return cachePath;

  return null;
}

function readJson<T>(filePath: string): T {
  return JSON.parse(fs.readFileSync(filePath, "utf8")) as T;
}

/** A degraded, empty stats.json — served when regeneration is impossible. */
function emptyStats(): StatsFile {
  return { schema_version: "1.0.0", generated_at: new Date(0).toISOString(), people: {} };
}

/**
 * Builds a scratch dir of symlinks to `people/` and `interactions/` (if
 * present) so build-index.sh / build-stats.sh — which always write to
 * `<store-dir>/index.json` / `<store-dir>/stats.json` — never write inside
 * the real store dir.
 */
function makeScratchDir(absStoreDir: string): string {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "ra-query-store-"));
  for (const sub of ["people", "interactions"]) {
    const target = path.join(absStoreDir, sub);
    if (fs.existsSync(target)) {
      fs.symlinkSync(target, path.join(scratch, sub), "dir");
    }
  }
  return scratch;
}

function runScript(scriptName: string, scratchDir: string): boolean {
  const scriptPath = path.join(CORE_SCRIPTS_DIR, scriptName);
  if (!fs.existsSync(scriptPath)) {
    process.stderr.write(
      `spomni-query: ${scriptName} not found at ${scriptPath} — skipping regeneration (soft condition)\n`,
    );
    return false;
  }
  const result = spawnSync("bash", [scriptPath, scratchDir], { encoding: "utf8" });
  if (result.status !== 0) {
    process.stderr.write(
      `spomni-query: ${scriptName} failed (exit ${String(result.status)}): ${result.stderr}\n`,
    );
    return false;
  }
  return true;
}

/**
 * Regenerates index.json / stats.json into the cache dir. Returns which of
 * the two were successfully (re)generated. The store dir is never touched.
 */
function regenerateIntoCache(
  absStoreDir: string,
  cacheDir: string,
): { index: boolean; stats: boolean } {
  const scratch = makeScratchDir(absStoreDir);
  try {
    const indexOk = runScript("build-index.sh", scratch);
    const statsOk = runScript("build-stats.sh", scratch);

    fs.mkdirSync(cacheDir, { recursive: true });

    if (indexOk && fs.existsSync(path.join(scratch, "index.json"))) {
      fs.copyFileSync(path.join(scratch, "index.json"), path.join(cacheDir, "index.json"));
    }
    if (statsOk && fs.existsSync(path.join(scratch, "stats.json"))) {
      fs.copyFileSync(path.join(scratch, "stats.json"), path.join(cacheDir, "stats.json"));
    }

    return { index: indexOk, stats: statsOk };
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
}

export interface EnsureFreshResult {
  reader: StoreReader;
  generatedAt: string;
}

/**
 * Ensures fresh index.json/stats.json are available (store copy, cache
 * copy, or a freshly-regenerated cache copy) and returns a `StoreReader`
 * over them. Never writes into `storeDir`.
 */
export function ensureFresh(storeDir: string): EnsureFreshResult {
  const absStoreDir = path.resolve(storeDir);
  const threshold = newestSourceMtime(absStoreDir);

  const storeIndexPath = path.join(absStoreDir, "index.json");
  const storeStatsPath = path.join(absStoreDir, "stats.json");

  const cacheDir = path.join(cacheRootDir(), "derived", storeHash(absStoreDir));
  const cacheIndexPath = path.join(cacheDir, "index.json");
  const cacheStatsPath = path.join(cacheDir, "stats.json");

  let indexPath = chooseFreshCopy(storeIndexPath, cacheIndexPath, threshold);
  let statsPath = chooseFreshCopy(storeStatsPath, cacheStatsPath, threshold);

  if (indexPath === null || statsPath === null) {
    const regenerated = regenerateIntoCache(absStoreDir, cacheDir);

    if (indexPath === null && regenerated.index) {
      indexPath = cacheIndexPath;
    }
    if (statsPath === null && regenerated.stats) {
      statsPath = cacheStatsPath;
    }

    // Soft-condition fallback: regeneration didn't happen (e.g. build-stats.sh
    // doesn't exist yet) — serve whatever copy exists even if stale, rather
    // than failing the whole server.
    indexPath ??=
      [storeIndexPath, cacheIndexPath].find((p) => fs.existsSync(p)) ?? null;
    statsPath ??=
      [storeStatsPath, cacheStatsPath].find((p) => fs.existsSync(p)) ?? null;
  }

  const index: IndexFile = indexPath ? readJson<IndexFile>(indexPath) : {};
  const stats: StatsFile = statsPath ? readJson<StatsFile>(statsPath) : emptyStats();

  if (!statsPath) {
    process.stderr.write(
      "spomni-query: no stats.json available (store, cache, or regenerated) — serving degraded empty stats\n",
    );
  }

  const reader = new MarkdownStoreReader({ storeDir: absStoreDir, index, stats });
  return { reader, generatedAt: reader.generatedAt };
}

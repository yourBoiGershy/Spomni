// Store-reader — the single data-access layer every MCP tool handler calls.
// This is the named SQLite bolt-on seam
// (docs/DECISIONS.md#markdown-store-plus-index, plan 08 unit 6): a future
// SQLite-backed implementation swaps in behind the `StoreReader` interface
// without touching tool code. Read-only, by construction: no write method
// exists here, not even "for tests" — the single-writer rule
// (packages/core/package.md) means the filing engine (ingestion) is the only
// writer of people/interactions, and query never writes into the store.
//
// index.json / stats.json freshness is staleness.ts's job; this module just
// holds whatever copies it is handed and reads markdown files live off disk
// (the markdown files ARE the source of truth — no caching needed there).

import fs from "node:fs";
import path from "node:path";
import matter from "gray-matter";
import type {
  BodySection,
  IndexFile,
  InteractionFile,
  InteractionFrontmatter,
  PersonFile,
  PersonFrontmatter,
  StatsFile,
  WakeupFile,
  WakeupFrontmatter,
} from "./types.ts";

/**
 * The one interface every tool handler depends on for store access.
 * `MarkdownStoreReader` is the only implementation today; a hypothetical
 * `SqliteStoreReader` would implement the same shape.
 */
export interface StoreReader {
  /** `stats.json`'s `generated_at` — every tool result stamps this so
   * answers are honest about freshness (staleness-cache decision). */
  readonly generatedAt: string;
  /** True while the served index/stats copy is known to be stale and a
   * background regeneration is (or was) in flight — staleness.ts's
   * `SwappableStoreReader` is the only implementation that ever sets this
   * true; `MarkdownStoreReader` is always fresh-as-served, hence `false`. */
  readonly stale: boolean;
  index(): IndexFile;
  stats(): StatsFile;
  getPerson(slug: string): PersonFile | null;
  getInteraction(id: string): InteractionFile | null;
  listWakeups(): WakeupFile[];
}

/** Splits a markdown body into `## `-delimited sections, verbatim. */
export function splitSections(body: string): BodySection[] {
  const lines = body.split("\n");
  const sections: BodySection[] = [];
  let heading: string | null = null;
  let buf: string[] = [];

  const flush = (): void => {
    if (heading === null) return;
    const raw = buf.join("\n").trim();
    const bullets = raw
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => line.startsWith("- "));
    sections.push({ heading, raw, bullets });
  };

  for (const line of lines) {
    const headingMatch = /^##\s+(.+?)\s*$/.exec(line);
    if (headingMatch) {
      flush();
      heading = headingMatch[1];
      buf = [];
    } else if (heading !== null) {
      buf.push(line);
    }
  }
  flush();

  return sections;
}

interface ParsedMarkdown {
  frontmatter: Record<string, unknown>;
  sections: BodySection[];
}

/**
 * gray-matter's YAML engine auto-detects bare `YYYY-MM-DD` scalars (dates,
 * last-touch, birthday, due, etc.) and parses them into JS `Date` objects.
 * Every contract (person.md, interaction.md, wakeup.md) types these fields
 * as ISO 8601 date *strings* — undo the auto-conversion so callers get the
 * string the file actually contains, not a parsed Date.
 */
function normalizeFrontmatterDates(value: unknown): unknown {
  if (value instanceof Date) {
    return value.toISOString().slice(0, 10);
  }
  if (Array.isArray(value)) {
    return value.map(normalizeFrontmatterDates);
  }
  if (value !== null && typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [key, v] of Object.entries(value as Record<string, unknown>)) {
      out[key] = normalizeFrontmatterDates(v);
    }
    return out;
  }
  return value;
}

function readMarkdown(filePath: string): ParsedMarkdown | null {
  if (!fs.existsSync(filePath)) return null;
  const raw = fs.readFileSync(filePath, "utf8");
  const parsed = matter(raw);
  return {
    frontmatter: normalizeFrontmatterDates(parsed.data) as Record<string, unknown>,
    sections: splitSections(parsed.content),
  };
}

export interface MarkdownStoreReaderOptions {
  storeDir: string;
  index: IndexFile;
  stats: StatsFile;
}

/**
 * Reads a markdown-plus-derived-JSON store per docs/PROJECT-CONTEXT.md's
 * store shape (`people/`, `interactions/`, `wakeups/`, `index.json`,
 * `stats.json`). `index`/`stats` are pre-loaded by staleness.ts's freshness
 * check and held in memory for the life of the server process; per-file
 * markdown reads are lazy and re-parsed on each call — cheap at
 * hundreds-of-people scale, and keeps this class free of any write-adjacent
 * caching state.
 */
export class MarkdownStoreReader implements StoreReader {
  private readonly storeDir: string;
  private readonly indexFile: IndexFile;
  private readonly statsFile: StatsFile;

  constructor(options: MarkdownStoreReaderOptions) {
    this.storeDir = options.storeDir;
    this.indexFile = options.index;
    this.statsFile = options.stats;
  }

  get generatedAt(): string {
    return this.statsFile.generated_at;
  }

  readonly stale = false;

  index(): IndexFile {
    return this.indexFile;
  }

  stats(): StatsFile {
    return this.statsFile;
  }

  getPerson(slug: string): PersonFile | null {
    const filePath = path.join(this.storeDir, "people", `${slug}.md`);
    const parsed = readMarkdown(filePath);
    if (!parsed) return null;
    return {
      slug,
      sourcePath: filePath,
      frontmatter: parsed.frontmatter as PersonFrontmatter,
      sections: parsed.sections,
    };
  }

  getInteraction(id: string): InteractionFile | null {
    const filePath = path.join(this.storeDir, "interactions", `${id}.md`);
    const parsed = readMarkdown(filePath);
    if (!parsed) return null;
    return {
      id,
      sourcePath: filePath,
      frontmatter: parsed.frontmatter as InteractionFrontmatter,
      sections: parsed.sections,
    };
  }

  listWakeups(): WakeupFile[] {
    const dir = path.join(this.storeDir, "wakeups");
    if (!fs.existsSync(dir)) return [];

    const files = fs
      .readdirSync(dir)
      .filter((entry) => entry.endsWith(".md"))
      .sort();

    const wakeups: WakeupFile[] = [];
    for (const file of files) {
      const filePath = path.join(dir, file);
      const parsed = readMarkdown(filePath);
      if (!parsed) continue;
      wakeups.push({
        id: file.slice(0, -3),
        sourcePath: filePath,
        frontmatter: parsed.frontmatter as WakeupFrontmatter,
        sections: parsed.sections,
      });
    }
    return wakeups;
  }
}

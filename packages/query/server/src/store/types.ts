// Shapes mirroring the store's on-disk contracts:
// packages/core/contracts/derived-index.md (index.json / stats.json) and
// packages/core/contracts/{person,interaction,wakeup}.md (markdown files).
// These are read-only projections — reader.ts is the only place that
// constructs them; nothing in this module writes anything.

// ---------------------------------------------------------------------------
// index.json / stats.json (packages/core/contracts/derived-index.md)
// ---------------------------------------------------------------------------

export interface IndexEntry {
  tags: string[];
  org: string | null;
  role: string | null;
  location: string | null;
  "last-touch": string | null;
}

/** Flat, keyed by slug — matches index.json's shape exactly (no envelope). */
export type IndexFile = Record<string, IndexEntry>;

export interface StatsInteractionRef {
  id: string;
  date: string;
  calendar: boolean;
  others: string[];
}

export interface StatsEntry {
  tier: string | null;
  touchpoints: number;
  first_interaction: string | null;
  last_interaction: string | null;
  median_gap_days: number | null;
  open_threads: number;
  commitments: { user: number; them: number };
  interactions: StatsInteractionRef[];
}

export interface StatsFile {
  schema_version: string;
  generated_at: string;
  people: Record<string, StatsEntry>;
}

// ---------------------------------------------------------------------------
// Markdown store files (packages/core/contracts/{person,interaction,wakeup}.md)
// ---------------------------------------------------------------------------

/**
 * One `## <heading>` section of a store markdown file's body, split
 * verbatim. `bullets` holds only the top-level "- " lines (provenance tags
 * intact, never stripped or re-parsed); `raw` is the full section text,
 * useful for prose sections (e.g. person.md's "Personal details") that mix
 * prose and bullets.
 */
export interface BodySection {
  heading: string;
  raw: string;
  bullets: string[];
}

export interface PersonFrontmatter {
  schema_version: string;
  name: string;
  org?: string;
  role?: string;
  location?: string;
  tags: string[];
  birthday?: string;
  "how-met"?: string;
  "last-touch"?: string;
  tier?: "inner-circle" | "close" | "active" | "dormant";
}

export interface PersonFile {
  slug: string;
  sourcePath: string;
  frontmatter: PersonFrontmatter;
  /** In file order: Facts, Open threads, Personal details. */
  sections: BodySection[];
}

export interface InteractionFrontmatter {
  schema_version: string;
  date: string;
  people: string[]; // "[[slug]]" links, verbatim
  "calendar-event": string | null;
  "source-capture": string | null;
}

export interface InteractionFile {
  id: string;
  sourcePath: string;
  frontmatter: InteractionFrontmatter;
  /** In file order: Summary, Commitments. */
  sections: BodySection[];
}

export interface WakeupFrontmatter {
  schema_version: string;
  id: string;
  due: string;
  people: string[];
  why: string;
  status: "pending" | "fired" | "snoozed" | "dismissed";
  origin: "user-ask" | "signal" | "standing";
  "source-signal"?: string | null;
}

export interface WakeupFile {
  id: string;
  sourcePath: string;
  frontmatter: WakeupFrontmatter;
  /** In file order: Context, and Draft if present. */
  sections: BodySection[];
}

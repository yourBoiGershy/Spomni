// Tool: upcoming_meetings — the next N days of filed calendar interactions,
// per docs/plans/2026-08-29-21-calendar-intelligence.md's "Query surface"
// section: date, one-line summary, calendar-event id, matched store people
// (slug + display name), citation paths. Honest empty result when nothing
// is filed in the window. Read-only, no re-matching — `people` is reported
// verbatim from the filing engine's frontmatter (single-writer rule); this
// tool never re-derives who attended.
//
// The store has no single "list every interaction" call — stats.json's
// per-person `interactions` lists are the only enumeration surface
// (packages/core/contracts/derived-index.md), so a multi-person meeting
// appears once per attendee. Dedupe by interaction id before reading each
// file once via `reader.getInteraction()`.

import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { StoreReader } from "../store/reader.ts";

const DEFAULT_DAYS = 7;

/** `some-slug` -> `Some Slug`. Matches search_people's / suggest_reachouts'
 * convention: there is no `name` field in index.json/stats.json, so a
 * listing derives a display name from the slug rather than opening every
 * person file. */
function nameFromSlug(slug: string): string {
  return slug
    .split("-")
    .map((part) => (part.length > 0 ? part[0].toUpperCase() + part.slice(1) : part))
    .join(" ");
}

function slugFromLink(link: string): string {
  // "[[slug]]" -> "slug"
  return link.replace(/^\[\[/, "").replace(/\]\]$/, "");
}

/** First line of an interaction's `## Summary` section, verbatim (no
 * truncation — this is already a "one-line summary" per the plan, not the
 * ~300-char excerpt list_interactions uses for full-summary rows). */
function oneLineSummary(raw: string): string {
  const firstLine = raw.split("\n").find((line) => line.trim().length > 0) ?? "";
  return firstLine.trim();
}

interface UpcomingMeeting {
  id: string;
  date: string;
  summary: string;
  calendar_event: string;
  people: { slug: string; name: string }[];
  source: string;
}

export function upcomingMeetings(reader: StoreReader, days: number, nowMs: number = Date.now()): object {
  const todayIso = new Date(nowMs).toISOString().slice(0, 10);
  const windowEndMs = nowMs + days * 86_400_000;
  const windowEndIso = new Date(windowEndMs).toISOString().slice(0, 10);

  const stats = reader.stats();
  const seenIds = new Set<string>();
  const meetings: UpcomingMeeting[] = [];

  for (const entry of Object.values(stats.people)) {
    for (const ref of entry.interactions) {
      if (!ref.calendar) continue;
      if (seenIds.has(ref.id)) continue;
      if (ref.date < todayIso || ref.date > windowEndIso) continue;
      seenIds.add(ref.id);

      const interaction = reader.getInteraction(ref.id);
      if (!interaction) continue;
      const calendarEvent = interaction.frontmatter["calendar-event"];
      if (!calendarEvent) continue;

      const summarySection = interaction.sections.find((s) => s.heading === "Summary");
      const people = interaction.frontmatter.people.map((link) => {
        const slug = slugFromLink(link);
        return { slug, name: nameFromSlug(slug) };
      });

      meetings.push({
        id: interaction.id,
        date: interaction.frontmatter.date,
        summary: oneLineSummary(summarySection?.raw ?? ""),
        calendar_event: calendarEvent,
        people,
        source: `interactions/${interaction.id}.md`,
      });
    }
  }

  meetings.sort((a, b) => a.date.localeCompare(b.date));

  return {
    generated_at: reader.generatedAt,
    days,
    window: { from: todayIso, to: windowEndIso },
    count: meetings.length,
    meetings,
    ...(meetings.length === 0
      ? { message: `No upcoming meetings filed in the next ${String(days)} day(s).` }
      : {}),
  };
}

const inputSchema = {
  days: z
    .number()
    .int()
    .min(1)
    .optional()
    .describe(`Look-ahead window in days from today; defaults to ${String(DEFAULT_DAYS)}.`),
};

export function registerUpcomingMeetings(server: McpServer, reader: StoreReader): void {
  server.registerTool(
    "upcoming_meetings",
    {
      title: "Upcoming meetings",
      description:
        `Filed calendar interactions in the next N days (default ${String(DEFAULT_DAYS)}): ` +
        "date, one-line summary, calendar-event id, matched store people (slug + display " +
        "name), citation path. Read-only — reports the filing engine's own person matches " +
        "as-is, never re-matches. An empty window returns an honest empty list with a " +
        "message, not an error.",
      inputSchema,
    },
    ({ days }) => {
      const result = upcomingMeetings(reader, days ?? DEFAULT_DAYS);
      return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
    },
  );
}

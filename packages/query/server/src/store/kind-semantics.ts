// The ONE place query interprets the D3 kind vocabulary
// (packages/core/contracts/relationship-scoring.md). Every proactive-
// reachout surface (suggest_reachouts fallback, who_next_pool, and any
// future consumer) must route its kind exclusion logic through here — new
// kinds or rule changes land in this module once and flow to every caller,
// instead of drifting per-tool as hardcoded strings.
//
// Source of truth:
// - relationship-scoring.md's kind vocabulary rows: `scheduling`
//   ("time-boxed logistics… must carry kind_expires"), `transactional`
//   ("vendor/service/support; no relationship rhythm"), `unsolicited`
//   ("inbound pitch/cold contact the user never answered") — none of these
//   carry a relationship rhythm worth proactively surfacing.
// - person.md's kind_expires read-state rule: "`expired` is **not** a kind
//   value — it is the read state of any person whose `kind_expires` is in
//   the past"; "Expired kinds: a `kind_expires` in the past forces
//   `attention_warrant: 0` and no tier suggestion."

/** Kinds that never carry a relationship rhythm — excluded from proactive
 * reachout surfaces by default (per relationship-scoring.md). */
export const NON_RELATIONAL_KINDS: ReadonlySet<string> = new Set([
  "scheduling",
  "transactional",
  "unsolicited",
]);

export interface KindFields {
  kind?: string | null;
  kind_expires?: string | null;
}

/**
 * true when `kind_expires` is set and strictly before `today`. Plain string
 * compare — store dates are all YYYY-MM-DD, so lexicographic order matches
 * chronological order (must stay equivalent to who-next-direct.sh's jq
 * comparison).
 */
export function isExpiredKind(fields: KindFields, today: string): boolean {
  const expires = fields.kind_expires;
  if (!expires) return false;
  return expires < today;
}

/** null when kind unset; "expired" when isExpiredKind; else the stored kind. */
export function effectiveKind(fields: KindFields, today: string): string | null {
  if (isExpiredKind(fields, today)) return "expired";
  return fields.kind ?? null;
}

/**
 * Central predicate for proactive-reachout surfaces: false when the
 * effective kind is "expired" or in NON_RELATIONAL_KINDS, unless `keep`
 * contains that (non-expired) effective kind. An expired kind is never
 * re-admitted by `keep`, even if `keep` names its underlying kind — expiry
 * always wins.
 */
export function warrantsProactiveSuggestion(
  fields: KindFields,
  today: string,
  keep?: ReadonlySet<string>,
): boolean {
  const kind = effectiveKind(fields, today);
  if (kind === null) return true;
  if (kind === "expired") return false;
  if (!NON_RELATIONAL_KINDS.has(kind)) return true;
  return keep?.has(kind) ?? false;
}

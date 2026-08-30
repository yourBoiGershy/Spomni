#!/usr/bin/env bash
# find-merge-candidates.sh — deterministic, read-only scan for likely
# duplicate person.md pairs (person.md 1.4.0, plan 36 B2). Never merges —
# `packages/core/scripts/person-merge.sh` (B1) is the only writer.
#
# Usage:
#   find-merge-candidates.sh <store-dir> [--data-dir <dir>]
#
# <store-dir> holds people/, interactions/. --data-dir defaults to
# "<store-dir>/..".
#
# Sources:
#   - people/*.md frontmatter (`name`, `org`) — people/.merged/ is skipped
#     (already-merged tombstones).
#   - <data-dir>/ingestion/identities.tsv (append-only
#     `slug\tEMAIL\tcapture-id` rows, person-merge.sh/file-structured.sh's
#     shared ledger). A row whose slug's people/<slug>.md no longer exists
#     is ignored (same stale-row rule structured-filing.md documents).
#   - <store-dir>/index.json, if present — read only if it happens to carry
#     emails/sender_ids per slug (build-index.sh's current shape does not,
#     so this is normally a no-op source).
#
# A pair (keep, drop) is a candidate when any of:
#   1. shared email/sender_id across two slugs (identities.tsv, or
#      index.json if it carries identity fields) -> reason
#      "shared-identity:<value>"
#   2. same normalized name (lowercase, diacritics/punctuation stripped,
#      whitespace collapsed; first+last token compared) -> reason
#      "same-name"
#   3. one slug is a prefix of the other (accounting for a trailing
#      `-2`/`-3` collision suffix on either side, e.g. "rahul" is a prefix
#      of "rahul-2") AND the two share a normalized org OR an email domain
#      (from identities.tsv/index.json) -> reason "slug-prefix+org" or
#      "slug-prefix+domain".
#
# Keep = the slug with more interactions/*.md files linking it via
# "[[slug]]" (a plain substring count of the literal wiki-link token);
# ties break toward the longer (more specific) slug string.
#
# Exactly ONE row per unordered (slug-a, slug-b) pair, even when several
# rules above match it — the row's reason is the single highest-precedence
# match: shared-identity > same-name > slug-prefix+org > slug-prefix+domain
# (e.g. a pair that is both a shared-identity match and a slug-prefix+domain
# match emits only the shared-identity row).
#
# Output: "candidates=<n>" as the first stdout line, then that one
# "keep\tdrop\treason" row per candidate pair, sorted. Exit 0 on any
# completed scan (this script never fails on "found nothing"). Exit 2 on a
# missing/invalid <store-dir> (no such directory, or no people/ subdir);
# exit 1 on a usage error (missing argument, unknown flag). Never writes
# anything.
#
# Portable to bash 3.2 (macOS default). The heavy lifting (frontmatter/
# tsv/index parsing, normalization, pairing, interaction counts) lives in
# one embedded python3 helper (same "python3 helper via heredoc" pattern
# as packages/ingestion/scripts/file-thread.sh) — bash here is argument
# parsing only.

set -u

usage() {
  echo "usage: find-merge-candidates.sh <store-dir> [--data-dir <dir>]" >&2
}

if [ $# -lt 1 ]; then
  usage
  exit 1
fi

STORE_DIR="$1"
shift

DATA_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --data-dir)
      DATA_DIR="$2"
      shift 2
      ;;
    *)
      echo "find-merge-candidates.sh: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [ ! -d "$STORE_DIR" ]; then
  echo "find-merge-candidates.sh: no such store-dir: ${STORE_DIR}" >&2
  exit 2
fi

if [ -z "$DATA_DIR" ]; then
  DATA_DIR="${STORE_DIR}/.."
fi

PEOPLE_DIR="${STORE_DIR}/people"
INTERACTIONS_DIR="${STORE_DIR}/interactions"
INDEX_JSON="${STORE_DIR}/index.json"
IDENTITIES_TSV="${DATA_DIR}/ingestion/identities.tsv"

if [ ! -d "$PEOPLE_DIR" ]; then
  echo "find-merge-candidates.sh: no people/ directory found at ${PEOPLE_DIR}" >&2
  exit 2
fi

python3 - "$PEOPLE_DIR" "$INTERACTIONS_DIR" "$INDEX_JSON" "$IDENTITIES_TSV" <<'PYEOF'
import sys, os, re, json, unicodedata

people_dir, interactions_dir, index_json_path, identities_tsv_path = sys.argv[1:5]

def normalize_text(s):
    if not s:
        return ""
    # Strip diacritics.
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c))
    s = s.lower()
    # Strip punctuation, collapse whitespace.
    s = re.sub(r"[^a-z0-9\s]", " ", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s

def normalized_name_key(name):
    norm = normalize_text(name)
    if not norm:
        return ""
    parts = norm.split(" ")
    if len(parts) == 1:
        return parts[0]
    return parts[0] + " " + parts[-1]

def extract_frontmatter(path):
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
    fm_lines = []
    count = 0
    for line in lines:
        if line.rstrip("\n") == "---":
            count += 1
            if count == 2:
                break
            continue
        if count == 1:
            fm_lines.append(line)
    return "".join(fm_lines)

def fm_field(fm, key):
    m = re.search(r"^" + re.escape(key) + r":\s*(.*)$", fm, re.MULTILINE)
    if not m:
        return ""
    return m.group(1).strip()

# --- load people ---
people = {}  # slug -> {name, org}
if os.path.isdir(people_dir):
    for fname in sorted(os.listdir(people_dir)):
        if not fname.endswith(".md"):
            continue
        slug = fname[:-3]
        path = os.path.join(people_dir, fname)
        if not os.path.isfile(path):
            continue
        fm = extract_frontmatter(path)
        name = fm_field(fm, "name")
        org = fm_field(fm, "org")
        people[slug] = {"name": name, "org": org}

slugs = set(people.keys())

# --- identities: slug -> set(email), email -> set(slug) ---
slug_emails = {s: set() for s in slugs}

if os.path.isfile(identities_tsv_path):
    with open(identities_tsv_path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            cols = line.split("\t")
            if len(cols) < 2:
                continue
            slug, email = cols[0], cols[1]
            if slug not in slugs:
                # stale row — slug's person file no longer exists, ignore.
                continue
            slug_emails.setdefault(slug, set()).add(email.strip().lower())

# --- index.json, if present and carries identity fields ---
if os.path.isfile(index_json_path):
    try:
        with open(index_json_path, "r", encoding="utf-8") as f:
            idx = json.load(f)
        if isinstance(idx, dict):
            for slug, rec in idx.items():
                if slug not in slugs or not isinstance(rec, dict):
                    continue
                for key in ("email", "emails", "sender_id", "sender_ids"):
                    val = rec.get(key)
                    if val is None:
                        continue
                    vals = val if isinstance(val, list) else [val]
                    for v in vals:
                        if isinstance(v, str) and v.strip():
                            slug_emails.setdefault(slug, set()).add(v.strip().lower())
    except (ValueError, OSError):
        pass

# --- interaction link counts: slug -> count of "[[slug]]" occurrences ---
link_counts = {s: 0 for s in slugs}
if os.path.isdir(interactions_dir):
    for fname in sorted(os.listdir(interactions_dir)):
        if not fname.endswith(".md"):
            continue
        path = os.path.join(interactions_dir, fname)
        if not os.path.isfile(path):
            continue
        with open(path, "r", encoding="utf-8") as f:
            content = f.read()
        for slug in slugs:
            token = "[[" + slug + "]]"
            if token in content:
                link_counts[slug] = link_counts.get(slug, 0) + content.count(token)

def keep_drop(a, b):
    # Returns (keep, drop) between slugs a and b.
    ca, cb = link_counts.get(a, 0), link_counts.get(b, 0)
    if ca != cb:
        return (a, b) if ca > cb else (b, a)
    if len(a) != len(b):
        return (a, b) if len(a) > len(b) else (b, a)
    # Fully tied — deterministic fallback: lexicographically smaller kept.
    return (a, b) if a < b else (b, a)

def domain(email):
    if "@" not in email:
        return ""
    return email.split("@", 1)[1].strip().lower()

# One row per unordered pair: when multiple rules match the same pair,
# only the highest-precedence reason is kept (shared-identity > same-name >
# slug-prefix+org > slug-prefix+domain).
def reason_rank(reason):
    if reason.startswith("shared-identity:"):
        return 0
    if reason == "same-name":
        return 1
    if reason == "slug-prefix+org":
        return 2
    if reason == "slug-prefix+domain":
        return 3
    return 4

pair_best_reason = {}  # frozenset({a, b}) -> best reason seen so far

def add_candidate(a, b, reason):
    key = frozenset((a, b))
    prior = pair_best_reason.get(key)
    if prior is None or reason_rank(reason) < reason_rank(prior):
        pair_best_reason[key] = reason

slug_list = sorted(slugs)

# Rule 1: shared identity.
value_to_slugs = {}
for slug, emails in slug_emails.items():
    for email in emails:
        value_to_slugs.setdefault(email, set()).add(slug)

for value, ss in value_to_slugs.items():
    ss = sorted(ss)
    if len(ss) < 2:
        continue
    for i in range(len(ss)):
        for j in range(i + 1, len(ss)):
            add_candidate(ss[i], ss[j], "shared-identity:" + value)

# Rule 2: same normalized name.
name_key_to_slugs = {}
for slug, info in people.items():
    key = normalized_name_key(info.get("name", ""))
    if not key:
        continue
    name_key_to_slugs.setdefault(key, set()).add(slug)

for key, ss in name_key_to_slugs.items():
    ss = sorted(ss)
    if len(ss) < 2:
        continue
    for i in range(len(ss)):
        for j in range(i + 1, len(ss)):
            add_candidate(ss[i], ss[j], "same-name")

# Rule 3: slug-prefix, accounting for a trailing -2/-3 collision suffix.
def strip_collision_suffix(slug):
    m = re.match(r"^(.*)-(\d+)$", slug)
    if m:
        return m.group(1)
    return slug

def is_prefix_pair(a, b):
    # True if a (or its collision-suffix-stripped form) is a slug-boundary
    # prefix of b (or its collision-suffix-stripped form), or vice versa.
    for x, y in ((a, b), (b, a)):
        x_base = strip_collision_suffix(x)
        y_base = strip_collision_suffix(y)
        for cand_prefix, cand_full in ((x_base, y), (x_base, y_base), (x, y_base)):
            if cand_prefix == cand_full:
                continue
            if cand_full == cand_prefix or cand_full.startswith(cand_prefix + "-"):
                return True
    return False

for i in range(len(slug_list)):
    for j in range(i + 1, len(slug_list)):
        a, b = slug_list[i], slug_list[j]
        if not is_prefix_pair(a, b):
            continue
        org_a = normalize_text(people.get(a, {}).get("org", ""))
        org_b = normalize_text(people.get(b, {}).get("org", ""))
        if org_a and org_b and org_a == org_b:
            add_candidate(a, b, "slug-prefix+org")
            continue
        domains_a = set(domain(e) for e in slug_emails.get(a, set()) if domain(e))
        domains_b = set(domain(e) for e in slug_emails.get(b, set()) if domain(e))
        if domains_a & domains_b:
            add_candidate(a, b, "slug-prefix+domain")

rows = []
for pair, reason in pair_best_reason.items():
    a, b = tuple(pair)
    keep, drop = keep_drop(a, b)
    rows.append((keep, drop, reason))
rows = sorted(rows)
print("candidates=%d" % len(rows))
for keep, drop, reason in rows:
    print("%s\t%s\t%s" % (keep, drop, reason))
PYEOF

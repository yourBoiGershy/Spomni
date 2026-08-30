#!/usr/bin/env bash
# person-merge.sh — deterministic, no-model merge of two person.md files
# into one (packages/core/contracts/person.md 1.4.0, plan 36 B1).
#
# Usage:
#   person-merge.sh <store-dir> <keep-slug> <drop-slug> \
#       [--data-dir <dir>] [--dry-run]
#
# <store-dir> holds people/, interactions/, wakeups/. --data-dir defaults
# to "<store-dir>/.." and roots the ledgers at <data-dir>/ingestion/.
#
# Rules:
#   - Both people/<keep>.md and people/<drop>.md must exist; keep != drop;
#     else exit 2 with a one-line reason. If people/.merged/<drop>.md
#     already exists -> exit 2 "already merged".
#   - Frontmatter union: keep wins on every scalar conflict; an empty keep
#     scalar takes drop's value; tags = union (keep's then drop's new,
#     order preserved); last-touch = max(keep, drop); tier/tier_source and
#     every kind* field: keep's if set, else drop's — never mixed (if keep
#     has tier without tier_source, that inconsistency is left as-is, drop
#     is not consulted for either field once keep has tier set).
#   - Facts: keep's bullets, then drop's bullets not already present
#     verbatim (full bullet text incl. provenance tag). Open threads and
#     Resolved: concat keep+drop, verbatim-dedup. Personal details: keep's
#     prose, then a blank line and drop's prose if non-empty.
#   - Link rewrite: every interactions/*.md and wakeups/**/*.md gets
#     [[<drop>]] -> [[<keep>]]; if a `people:` YAML list then contains the
#     keep slug twice, it is deduped. Reports links_rewritten=<n> files=<m>.
#   - <data-dir>/ingestion/identities.tsv (append-only, columns
#     slug\temail\tcapture-id): every row whose slug == drop gets a sibling
#     row appended with slug keep (existing rows are never rewritten or
#     deleted). Skipped if the file is absent.
#   - Tombstone: people/<drop>.md moves to people/.merged/<drop>.md with
#     `merged_into: <keep>` and `merged_on: <YYYY-MM-DD UTC>` prepended to
#     its frontmatter.
#   - Appends "<drop>\t<keep>\t<ISO-8601 Z>" to
#     <data-dir>/ingestion/merges.log.
#   - Calls packages/ingestion/scripts/feedback-file.sh (resolved relative
#     to this script, like person-set-tier.sh does) with --type merge
#     --target person:<keep> --from <drop> --source session, if present;
#     a failure there is a warning, never fatal.
#   - Runs packages/core/scripts/build-index.sh <store-dir> at the end
#     (skipped on --dry-run).
#   - --dry-run: prints the planned frontmatter/section merge and link
#     counts; writes nothing.
#
# Prints exactly one summary line:
#   person-merge: <drop> -> <keep> facts=<n> threads=<n> links_rewritten=<n> identities=<n>
# or, for a dry run:
#   person-merge: dry-run <drop> -> <keep> facts=<n> threads=<n> links_rewritten=<n> identities=<n>
#
# Portable to bash 3.2 (macOS default). The heavy lifting (frontmatter/
# section merge, link rewrite, file writes) lives in one embedded python3
# helper (same "python3 helper via heredoc" pattern as
# packages/ingestion/scripts/file-thread.sh and
# packages/core/scripts/eval-run.sh) — bash here is argument parsing only.

set -u

usage() {
  echo "usage: person-merge.sh <store-dir> <keep-slug> <drop-slug> [--data-dir <dir>] [--dry-run]" >&2
}

if [ $# -lt 3 ]; then
  usage
  exit 1
fi

STORE_DIR="$1"
KEEP_SLUG="$2"
DROP_SLUG="$3"
shift 3

DATA_DIR=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --data-dir)
      if [ $# -lt 2 ]; then
        echo "person-merge.sh: --data-dir requires an argument" >&2
        exit 1
      fi
      DATA_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    *)
      echo "person-merge.sh: unrecognized argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

[ -n "$DATA_DIR" ] || DATA_DIR="${STORE_DIR}/.."

if [ ! -d "${STORE_DIR}/people" ]; then
  echo "person-merge.sh: ${STORE_DIR}/people: no such directory" >&2
  exit 1
fi

if [ "$KEEP_SLUG" = "$DROP_SLUG" ]; then
  echo "person-merge.sh: keep-slug and drop-slug must differ" >&2
  exit 2
fi

if [ ! -f "${STORE_DIR}/people/${KEEP_SLUG}.md" ]; then
  echo "person-merge.sh: people/${KEEP_SLUG}.md: no such file" >&2
  exit 2
fi

if [ -f "${STORE_DIR}/people/.merged/${DROP_SLUG}.md" ]; then
  echo "person-merge.sh: already merged" >&2
  exit 2
fi

if [ ! -f "${STORE_DIR}/people/${DROP_SLUG}.md" ]; then
  echo "person-merge.sh: people/${DROP_SLUG}.md: no such file" >&2
  exit 2
fi

RESULT_FILE="$(mktemp)"
trap 'rm -f "$RESULT_FILE"' EXIT

python3 - "$STORE_DIR" "$KEEP_SLUG" "$DROP_SLUG" "$DATA_DIR" "$DRY_RUN" > "$RESULT_FILE" <<'PYEOF'
import datetime
import glob
import os
import re
import sys

store_dir, keep_slug, drop_slug, data_dir, dry_run_arg = sys.argv[1:6]
DRY_RUN = dry_run_arg == "1"

people_dir = os.path.join(store_dir, "people")
interactions_dir = os.path.join(store_dir, "interactions")
wakeups_dir = os.path.join(store_dir, "wakeups")
merged_dir = os.path.join(people_dir, ".merged")
ing_dir = os.path.join(data_dir, "ingestion")

keep_path = os.path.join(people_dir, "%s.md" % keep_slug)
drop_path = os.path.join(people_dir, "%s.md" % drop_slug)

FM_RE = re.compile(r"^---\n(.*?)\n---\n(.*)$", re.DOTALL)


def split_file(path):
    with open(path) as f:
        raw = f.read()
    m = FM_RE.match(raw)
    if not m:
        return "", raw
    return m.group(1), m.group(2)


def parse_frontmatter(fm_text):
    """Ordered list of (key, raw_value_line) pairs, preserving source order."""
    fields = []
    for line in fm_text.splitlines():
        if not line.strip() or line.startswith(" ") or line.startswith("-"):
            continue
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        fields.append((k.strip(), v.strip()))
    return fields


def fm_dict(fields):
    d = {}
    for k, v in fields:
        d[k] = v
    return d


def parse_tags(raw):
    raw = (raw or "").strip()
    inner = raw
    if inner.startswith("["):
        inner = inner[1:]
    if inner.endswith("]"):
        inner = inner[:-1]
    inner = inner.strip()
    if not inner:
        return []
    return [t.strip() for t in inner.split(",") if t.strip()]


def parse_sections(body):
    """Splits body into an ordered dict of section-name -> list of bullet
    lines (raw, including leading '- '), for the fixed person.md sections."""
    sections = {}
    order = []
    cur = None
    for line in body.splitlines():
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m:
            cur = m.group(1)
            sections[cur] = []
            order.append(cur)
            continue
        if cur is not None:
            sections[cur].append(line)
    return sections, order


def bullets_of(lines):
    out = []
    for l in lines:
        s = l.strip()
        if not s or s == "_none_":
            continue
        out.append(l)
    return out


def prose_of(lines):
    text = "\n".join(lines).strip()
    if text == "_none_":
        return ""
    return text


keep_fm_text, keep_body = split_file(keep_path)
drop_fm_text, drop_body = split_file(drop_path)

keep_fields = parse_frontmatter(keep_fm_text)
drop_fields = parse_frontmatter(drop_fm_text)
keep_dict = fm_dict(keep_fields)
drop_dict = fm_dict(drop_fields)

SCALARS = [
    "schema_version",
    "name",
    "org",
    "role",
    "location",
    "birthday",
    "how-met",
]

merged_dict = {}
for k in SCALARS:
    kv = (keep_dict.get(k) or "").strip()
    dv = (drop_dict.get(k) or "").strip()
    merged_dict[k] = kv if kv else dv

# tags: union, keep's then drop's new, order preserved
keep_tags = parse_tags(keep_dict.get("tags", ""))
drop_tags = parse_tags(drop_dict.get("tags", ""))
merged_tags = list(keep_tags)
for t in drop_tags:
    if t not in merged_tags:
        merged_tags.append(t)

# last-touch: max
kt = (keep_dict.get("last-touch") or "").strip()
dt = (drop_dict.get("last-touch") or "").strip()
merged_last_touch = max(kt, dt) if kt and dt else (kt or dt)

# tier/tier_source: keep's if set, else drop's — never mixed
if (keep_dict.get("tier") or "").strip():
    merged_tier = keep_dict.get("tier", "").strip()
    merged_tier_source = keep_dict.get("tier_source", "").strip()
else:
    merged_tier = drop_dict.get("tier", "").strip()
    merged_tier_source = drop_dict.get("tier_source", "").strip()

# kind* fields: keep's if kind is set, else drop's — never mixed
KIND_FIELDS = ["kind", "kind_note", "kind_source", "kind_expires", "kind_updated"]
if (keep_dict.get("kind") or "").strip():
    kind_vals = dict((f, keep_dict.get(f, "").strip()) for f in KIND_FIELDS)
else:
    kind_vals = dict((f, drop_dict.get(f, "").strip()) for f in KIND_FIELDS)

# ---------------------------------------------------------------------------
# Body sections.
# ---------------------------------------------------------------------------

keep_sections, keep_order = parse_sections(keep_body)
drop_sections, _ = parse_sections(drop_body)

keep_facts = bullets_of(keep_sections.get("Facts", []))
drop_facts = bullets_of(drop_sections.get("Facts", []))
merged_facts = list(keep_facts)
for b in drop_facts:
    if b.strip() not in [x.strip() for x in merged_facts]:
        merged_facts.append(b)

keep_threads = bullets_of(keep_sections.get("Open threads", []))
drop_threads = bullets_of(drop_sections.get("Open threads", []))
merged_threads = []
seen_threads = set()
for b in keep_threads + drop_threads:
    key = b.strip()
    if key not in seen_threads:
        seen_threads.add(key)
        merged_threads.append(b)

keep_resolved = bullets_of(keep_sections.get("Resolved", []))
drop_resolved = bullets_of(drop_sections.get("Resolved", []))
merged_resolved = []
seen_resolved = set()
for b in keep_resolved + drop_resolved:
    key = b.strip()
    if key not in seen_resolved:
        seen_resolved.add(key)
        merged_resolved.append(b)
has_resolved = bool(merged_resolved)

keep_personal = prose_of(keep_sections.get("Personal details", []))
drop_personal = prose_of(drop_sections.get("Personal details", []))
if keep_personal and drop_personal:
    merged_personal = keep_personal + "\n\n" + drop_personal
else:
    merged_personal = keep_personal or drop_personal

# ---------------------------------------------------------------------------
# Render merged keep file.
# ---------------------------------------------------------------------------

def fm_line(key, val):
    return "%s: %s" % (key, val)

canonical_lines = []
canonical_lines.append(fm_line("schema_version", merged_dict["schema_version"] or "1.4.0"))
canonical_lines.append(fm_line("name", merged_dict["name"]))
canonical_lines.append(fm_line("org", merged_dict["org"]))
canonical_lines.append(fm_line("role", merged_dict["role"]))
canonical_lines.append(fm_line("location", merged_dict["location"]))
canonical_lines.append(fm_line("tags", "[%s]" % ", ".join(merged_tags)))
canonical_lines.append(fm_line("birthday", merged_dict["birthday"]))
canonical_lines.append(fm_line("how-met", merged_dict["how-met"]))
canonical_lines.append(fm_line("last-touch", merged_last_touch))
if merged_tier:
    canonical_lines.append(fm_line("tier", merged_tier))
    if merged_tier_source:
        canonical_lines.append(fm_line("tier_source", merged_tier_source))
if kind_vals.get("kind"):
    canonical_lines.append(fm_line("kind", kind_vals["kind"]))
    if kind_vals.get("kind_note"):
        canonical_lines.append(fm_line("kind_note", kind_vals["kind_note"]))
    if kind_vals.get("kind_source"):
        canonical_lines.append(fm_line("kind_source", kind_vals["kind_source"]))
    if kind_vals.get("kind_expires"):
        canonical_lines.append(fm_line("kind_expires", kind_vals["kind_expires"]))
    if kind_vals.get("kind_updated"):
        canonical_lines.append(fm_line("kind_updated", kind_vals["kind_updated"]))

body_parts = []
body_parts.append("## Facts\n\n")
body_parts.append(("\n".join(merged_facts) if merged_facts else "_none_"))
body_parts.append("\n\n## Open threads\n\n")
body_parts.append(("\n".join(merged_threads) if merged_threads else "_none_"))
if has_resolved:
    body_parts.append("\n\n## Resolved\n\n")
    body_parts.append("\n".join(merged_resolved))
body_parts.append("\n\n## Personal details\n\n")
body_parts.append((merged_personal if merged_personal else "_none_"))

merged_content = "---\n" + "\n".join(canonical_lines) + "\n---\n\n" + "".join(body_parts) + "\n"

# ---------------------------------------------------------------------------
# Link rewrite across interactions/*.md and wakeups/**/*.md.
# ---------------------------------------------------------------------------

link_re = re.compile(r"\[\[%s\]\]" % re.escape(drop_slug))
people_list_re = re.compile(r'^(people:\s*\[)(.*)(\]\s*)$')

link_files = []
if os.path.isdir(interactions_dir):
    link_files.extend(sorted(glob.glob(os.path.join(interactions_dir, "*.md"))))
if os.path.isdir(wakeups_dir):
    for root, dirs, files in os.walk(wakeups_dir):
        for fn in sorted(files):
            if fn.endswith(".md"):
                link_files.append(os.path.join(root, fn))

links_rewritten = 0
files_touched = 0

for path in link_files:
    with open(path) as f:
        content = f.read()
    if "[[%s]]" % drop_slug not in content:
        continue
    n = len(link_re.findall(content))
    new_content = link_re.sub("[[%s]]" % keep_slug, content)

    # Dedup a people: [...] list if it now contains keep_slug twice.
    out_lines = []
    for line in new_content.splitlines():
        m = people_list_re.match(line)
        if m:
            prefix, inner, suffix = m.group(1), m.group(2), m.group(3)
            items = []
            seen_items = set()
            for raw_item in re.findall(r'"[^"]*"|\'[^\']*\'|[^,]+', inner):
                item = raw_item.strip()
                if not item:
                    continue
                if item not in seen_items:
                    seen_items.add(item)
                    items.append(item)
            line = prefix + ", ".join(items) + suffix
        out_lines.append(line)
    new_content = "\n".join(out_lines)
    if new_content.endswith("\n") != content.endswith("\n") and content.endswith("\n"):
        new_content += "\n"

    links_rewritten += n
    files_touched += 1
    if not DRY_RUN:
        with open(path, "w") as f:
            f.write(new_content)

# ---------------------------------------------------------------------------
# identities.tsv — append-only sibling rows for the keep slug.
# ---------------------------------------------------------------------------

identities_path = os.path.join(ing_dir, "identities.tsv")
identities_added = 0
if os.path.isfile(identities_path):
    with open(identities_path) as f:
        id_lines = [l for l in f.read().splitlines() if l.strip()]
    new_rows = []
    for line in id_lines:
        cols = line.split("\t")
        if cols and cols[0] == drop_slug:
            new_cols = [keep_slug] + cols[1:]
            candidate = "\t".join(new_cols)
            if candidate not in id_lines and candidate not in new_rows:
                new_rows.append(candidate)
    identities_added = len(new_rows)
    if not DRY_RUN and new_rows:
        with open(identities_path, "a") as f:
            for row in new_rows:
                f.write(row + "\n")

# ---------------------------------------------------------------------------
# Write merged keep file, tombstone the drop file, ledgers.
# ---------------------------------------------------------------------------

if not DRY_RUN:
    with open(keep_path, "w") as f:
        f.write(merged_content)

    os.makedirs(merged_dir, exist_ok=True)
    today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    tomb_fm = list(drop_fields)
    tomb_lines = ["merged_into: %s" % keep_slug, "merged_on: %s" % today]
    for k, v in tomb_fm:
        tomb_lines.append("%s: %s" % (k, v))
    tomb_content = "---\n" + "\n".join(tomb_lines) + "\n---\n" + drop_body
    with open(os.path.join(merged_dir, "%s.md" % drop_slug), "w") as f:
        f.write(tomb_content)
    os.remove(drop_path)

    os.makedirs(ing_dir, exist_ok=True)
    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    with open(os.path.join(ing_dir, "merges.log"), "a") as f:
        f.write("%s\t%s\t%s\n" % (drop_slug, keep_slug, ts))

print("facts=%d threads=%d links_rewritten=%d files=%d identities=%d" % (
    len(merged_facts), len(merged_threads), links_rewritten, files_touched, identities_added
))
PYEOF
rc=$?

if [ $rc -ne 0 ]; then
  echo "person-merge.sh: merge computation failed" >&2
  exit 1
fi

RESULT="$(cat "$RESULT_FILE")"

# RESULT: "facts=<n> threads=<n> links_rewritten=<n> files=<m> identities=<n>"
FACTS_N="$(printf '%s\n' "$RESULT" | sed -n 's/.*facts=\([0-9]*\).*/\1/p')"
THREADS_N="$(printf '%s\n' "$RESULT" | sed -n 's/.*threads=\([0-9]*\).*/\1/p')"
LINKS_N="$(printf '%s\n' "$RESULT" | sed -n 's/.*links_rewritten=\([0-9]*\).*/\1/p')"
IDENT_N="$(printf '%s\n' "$RESULT" | sed -n 's/.*identities=\([0-9]*\).*/\1/p')"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "person-merge: dry-run ${DROP_SLUG} -> ${KEEP_SLUG} facts=${FACTS_N} threads=${THREADS_N} links_rewritten=${LINKS_N} identities=${IDENT_N}"
  exit 0
fi

# Feedback ledger (best-effort, never fatal).
feedback_script="$(dirname "$0")/../../ingestion/scripts/feedback-file.sh"
if [ ! -f "$feedback_script" ]; then
  echo "person-merge.sh: feedback: skipped (feedback-file.sh absent)" >&2
else
  "$feedback_script" "$STORE_DIR" --type merge --target "person:${KEEP_SLUG}" --from "$DROP_SLUG" --source session
  feedback_rc=$?
  if [ "$feedback_rc" -ne 0 ]; then
    echo "person-merge.sh: feedback: ledger write failed (exit ${feedback_rc})" >&2
  fi
fi

BUILD_INDEX="$(dirname "$0")/build-index.sh"
if [ -f "$BUILD_INDEX" ]; then
  "$BUILD_INDEX" "$STORE_DIR" >&2
fi

echo "person-merge: ${DROP_SLUG} -> ${KEEP_SLUG} facts=${FACTS_N} threads=${THREADS_N} links_rewritten=${LINKS_N} identities=${IDENT_N}"
exit 0

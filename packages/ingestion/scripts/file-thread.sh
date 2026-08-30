#!/usr/bin/env bash
# file-thread.sh — deterministic writer that turns a chat-message capture
# event + its thread-summary JSON (packages/ingestion/specs/thread-summary.md
# 1.0.0, produced by scripts/summarize-thread.sh) into person/interaction
# files, no model call in the loop (plan 32 D2/D3).
#
# Usage:
#   file-thread.sh <store-dir> <event-file> <summary.json>
#                   [--data-dir <dir>] [--dry-run]
#
# <store-dir> holds inbox/, people/, interactions/. --data-dir defaults to
# "<store-dir>/.." and roots the ledger at <data-dir>/ingestion/
# debrief-filed.log (the SAME ledger skills/debrief/ and file-structured.sh
# share, so neither refiles what this script already filed).
#
# skip (thread-summary.md's `skip` field non-null): the capture id is
# appended to the ledger, nothing else is written.
#
# Dedup (D3): every other inbox/*.md capture whose BODY parses as chat JSON
# (a `chatID` key plus a `messages` array — regardless of its `type` field,
# so legacy `source: beeper` / `type: other` captures carrying the same chat
# body as a `type: chat-message` capture are folded in too) sharing the
# summary's chat_id is folded in — messages unioned by message `id`, filed
# once, EVERY contributing capture id appended to the ledger (ids already
# there are left alone). This makes a rerun over the same capture(s) a
# true no-op: once every contributing id is ledgered, nothing new is
# written.
#
# Episodes (D2): one interaction per active UTC day (a day with at least
# one non-NOTICE/REACTION, non-deleted, non-empty-text message). `people`
# on each day's interaction is the non-self people whose sender_ids sent
# that day, falling back through every non-self summary person -> an
# existing person matched by that day's senderName -> a single per-thread
# fallback person (never `single`-only, coordinator correction: "never drop
# an active day" — a group whose summary under-lists participants must
# still get every active day filed). Commitments/open-threads ride only on
# the LAST active day's interaction.
#
# Person upsert: existing people are matched by exact normalized `name:`;
# otherwise a new person is created (kebab-case slug, `-2`/`-3` on
# collision with a different name). `last-touch` only ever moves forward.
# Facts are appended as bullets not already present verbatim, tagged with
# the summary's own provenance value (`told-by-user` | `inferred-from-thread`)
# in bold brackets, mirroring person.md 1.2.0's `## Facts` convention
# (`**[told-by-user]**`/`**[inferred-public-web]**`) — note
# `inferred-from-thread` is not yet in validate-store.sh's Facts provenance
# enum (told-by-user|inferred-public-web only); a summary carrying
# inferred-from-thread facts will currently fail `validate-store.sh` until
# that enum is amended for chat-derived provenance (out of scope here,
# flagged as collateral).
#
# Never writes tier/tier_source/kind* — filing carries no tier opinion.
# Never runs build-index.sh/validate-store.sh (the caller does).
#
# Prints exactly one summary line:
#   file-thread: <id> people_new=<n> people_touched=<n> interactions=<n> days=<n> dedup_ids=<n>
# or, for a skip:
#   file-thread: <id> skipped=<reason>
#
# Portable to bash 3.2 (macOS default). The heavy lifting (JSON parsing,
# episode/person computation, file writes) lives in one embedded python3
# helper (same "python3 helper via heredoc" pattern as
# packages/core/scripts/eval-run.sh and this package's own
# scripts/summarize-thread.sh) — bash here is argument parsing only.

set -u

usage() {
  echo "usage: file-thread.sh <store-dir> <event-file> <summary.json> [--data-dir <dir>] [--dry-run]" >&2
}

if [ $# -lt 3 ]; then
  usage
  exit 1
fi

STORE_DIR="$1"
EVENT_FILE="$2"
SUMMARY_FILE="$3"
shift 3

DATA_DIR=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --data-dir)
      if [ $# -lt 2 ]; then
        echo "file-thread.sh: --data-dir requires an argument" >&2
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
      echo "file-thread.sh: unrecognized argument '$1'" >&2
      usage
      exit 1
      ;;
  esac
done

[ -n "$DATA_DIR" ] || DATA_DIR="${STORE_DIR}/.."

if [ ! -d "${STORE_DIR}/inbox" ]; then
  echo "file-thread.sh: ${STORE_DIR}/inbox: no such directory" >&2
  exit 1
fi

if [ ! -f "$EVENT_FILE" ]; then
  echo "file-thread.sh: event file not found: $EVENT_FILE" >&2
  exit 1
fi

if [ ! -f "$SUMMARY_FILE" ]; then
  echo "file-thread.sh: summary file not found: $SUMMARY_FILE" >&2
  exit 1
fi

python3 - "$STORE_DIR" "$EVENT_FILE" "$SUMMARY_FILE" "$DATA_DIR" "$DRY_RUN" <<'PYEOF'
import glob
import json
import os
import re
import sys

store_dir, event_file, summary_file, data_dir, dry_run_arg = sys.argv[1:6]
DRY_RUN = dry_run_arg == "1"

people_dir = os.path.join(store_dir, "people")
interactions_dir = os.path.join(store_dir, "interactions")
inbox_dir = os.path.join(store_dir, "inbox")
ing_dir = os.path.join(data_dir, "ingestion")
ledger_path = os.path.join(ing_dir, "debrief-filed.log")

if not DRY_RUN:
    os.makedirs(people_dir, exist_ok=True)
    os.makedirs(interactions_dir, exist_ok=True)
    os.makedirs(ing_dir, exist_ok=True)


def read_capture(path):
    """Parses one inbox/<id>.md capture event: returns
    (frontmatter-dict, body-json-or-None)."""
    with open(path) as f:
        raw = f.read()
    m = re.match(r"^---\n(.*?)\n---\n(.*)$", raw, re.DOTALL)
    if not m:
        return {}, None
    fm_text, body_text = m.group(1), m.group(2).strip()
    fm = {}
    for line in fm_text.splitlines():
        line = line.rstrip()
        if not line or line.startswith(" ") or line.startswith("-"):
            continue
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        fm[k.strip()] = v.strip().strip('"')
    body = None
    if body_text:
        first_line = body_text.splitlines()[0]
        try:
            body = json.loads(first_line)
        except Exception:
            body = None
    return fm, body


def truthy(v):
    return v is True or (isinstance(v, str) and v.strip().lower() == "true")


def is_chat_body(body):
    """A capture is a chat capture iff its body parses as JSON with a
    `chatID` key and a `messages` array — regardless of its `type` field
    (legacy `source: beeper` / `type: other` captures carry the same chat
    body as `type: chat-message` captures)."""
    return (
        isinstance(body, dict)
        and body.get("chatID") is not None
        and isinstance(body.get("messages"), list)
    )


# ---------------------------------------------------------------------------
# 1. Parse the primary event + its summary.
# ---------------------------------------------------------------------------

primary_fm, primary_body = read_capture(event_file)
primary_id = primary_fm.get("id") or os.path.splitext(os.path.basename(event_file))[0]

with open(summary_file) as f:
    summary = json.load(f)

skip = summary.get("skip")

os.makedirs(ing_dir, exist_ok=True) if not DRY_RUN else None


def ledger_ids():
    if not os.path.isfile(ledger_path):
        return set()
    with open(ledger_path) as f:
        return set(line.strip() for line in f if line.strip())


def ledger_append(cap_id):
    if DRY_RUN:
        return
    with open(ledger_path, "a") as f:
        f.write(cap_id + "\n")


if skip is not None:
    reason = skip.get("reason", "unknown") if isinstance(skip, dict) else "unknown"
    existing = ledger_ids()
    if primary_id not in existing:
        ledger_append(primary_id)
    print("file-thread: %s skipped=%s" % (primary_id, reason))
    sys.exit(0)

chat_id = summary.get("chat_id") or (primary_body or {}).get("chatID")
chat_type = summary.get("chat_type") or (primary_body or {}).get("chatType") or "single"

# ---------------------------------------------------------------------------
# 2. Dedup — every inbox/*.md chat-message capture sharing chat_id, messages
#    unioned by message id.
# ---------------------------------------------------------------------------

contributing = {}  # capture_id -> messages list
for path in sorted(glob.glob(os.path.join(inbox_dir, "*.md"))):
    fm, body = read_capture(path)
    if not is_chat_body(body):
        continue
    if body.get("chatID") != chat_id:
        continue
    cap_id = fm.get("id") or os.path.splitext(os.path.basename(path))[0]
    contributing[cap_id] = body.get("messages") or []

if primary_id not in contributing and is_chat_body(primary_body):
    contributing[primary_id] = (primary_body or {}).get("messages") or []

contributing_ids = sorted(contributing.keys())

existing_ledger = ledger_ids()
new_ids = [cid for cid in contributing_ids if cid not in existing_ledger]

if not new_ids:
    # Already filed in a prior run — true no-op (idempotent rerun).
    print(
        "file-thread: %s people_new=0 people_touched=0 interactions=0 days=0 dedup_ids=0"
        % primary_id
    )
    sys.exit(0)

union_by_id = {}
for cid in contributing_ids:
    for msg in contributing[cid]:
        if not isinstance(msg, dict):
            continue
        mid = msg.get("id")
        key = mid if mid is not None else id(msg)
        if key not in union_by_id:
            union_by_id[key] = msg

messages = list(union_by_id.values())


def msg_date(msg):
    ts = msg.get("timestamp") or ""
    return ts[:10] if len(ts) >= 10 else None


# A message counts as activity only if it is not deleted, its type is not
# NOTICE/REACTION (a type: null/missing row with real text still counts —
# only these two system-row types are excluded), and its text is non-empty
# after trimming (coordinator correction: a REACTION-only or empty-text row
# was producing phantom single-interaction days).
def is_active(msg):
    if str(msg.get("type", "")).upper() in ("NOTICE", "REACTION"):
        return False
    if truthy(msg.get("isDeleted", False)):
        return False
    text = msg.get("text")
    if not text or not str(text).strip():
        return False
    return True


# ---------------------------------------------------------------------------
# 3. People map — sender_id -> person entry (skip is_self).
# ---------------------------------------------------------------------------

people_entries = [p for p in (summary.get("people") or []) if not p.get("is_self")]
sender_to_person = {}
for p in people_entries:
    for sid in p.get("sender_ids") or []:
        sender_to_person[sid] = p

# ---------------------------------------------------------------------------
# 3b. Existing people (name -> slug) scan — moved ahead of day-building
# (section 4) because tier 3's senderName fallback below needs it; also
# reused by person resolution/creation in section 7.
# ---------------------------------------------------------------------------


def normalize_name(name):
    return re.sub(r"\s+", " ", (name or "").strip().lower())


def kebab(name):
    s = re.sub(r"[^a-z0-9]+", "-", (name or "").lower()).strip("-")
    return s or "unnamed"


def read_frontmatter_field(text, field):
    m = re.search(r"^" + re.escape(field) + r":[ \t]*(.*)$", text, re.MULTILINE)
    return m.group(1).strip().strip('"') if m else ""


name_to_slug = {}
name_to_display = {}
all_slugs = set()
if os.path.isdir(people_dir):
    for pf in glob.glob(os.path.join(people_dir, "*.md")):
        slug = os.path.splitext(os.path.basename(pf))[0]
        all_slugs.add(slug)
        with open(pf) as f:
            content_pf = f.read()
        fm_match = re.match(r"^---\n(.*?)\n---\n", content_pf, re.DOTALL)
        fm_text = fm_match.group(1) if fm_match else ""
        pname = read_frontmatter_field(fm_text, "name")
        if pname:
            norm_pname = normalize_name(pname)
            name_to_slug[norm_pname] = slug
            name_to_display[norm_pname] = pname

# ---------------------------------------------------------------------------
# 4. Active days + per-day people ("never drop an active day", coordinator
# correction: in groups the summary often lists only one or two of many
# senders, which used to resolve empty-people days to nothing and silently
# drop the interaction — single chats had a fallback, groups didn't). Tiered
# fallback, unconditional on chat_type: (1) summary sender_ids match, (2)
# every non-self summary person, (3) that day's senders resolved by
# senderName against an existing person's name, (4) one per-thread fallback
# person (from the chat title, tagged group-chat for a group) so the day is
# always preserved.
# ---------------------------------------------------------------------------

chat_title = summary.get("title") or (primary_body or {}).get("title") or ""

_thread_fallback_ref = {"person": None}


def get_thread_fallback_person():
    """Lazily creates/reuses ONE synthetic person for this whole thread —
    the last-resort tier when neither the summary's people[] nor any
    existing person's name resolves a day's senders. Named from the chat's
    title (or the chat_id if there is no title); tagged group-chat for a
    group thread so it reads as visibly provisional."""
    if _thread_fallback_ref["person"] is not None:
        return _thread_fallback_ref["person"]
    name = chat_title.strip() if chat_title.strip() else ("Chat %s" % chat_id)
    entry = {
        "display_name": name,
        "sender_ids": [],
        "is_self": False,
        "role_guess": "unknown",
        "_fallback_tags": "[group-chat]" if chat_type == "group" else "[]",
    }
    _thread_fallback_ref["person"] = entry
    return entry


days = {}  # date -> {"messages": [...], "senders": set(), "sender_names": {sid: name}, "people": [...]}
for msg in messages:
    if not is_active(msg):
        continue
    d = msg_date(msg)
    if not d:
        continue
    days.setdefault(d, {"messages": [], "senders": set(), "sender_names": {}})
    days[d]["messages"].append(msg)
    sid = msg.get("senderID")
    days[d]["senders"].add(sid)
    sname = msg.get("senderName")
    if sname:
        days[d]["sender_names"][sid] = sname

sorted_days = sorted(days.keys())

for d in sorted_days:
    matched = []
    seen_names = set()
    for sid in days[d]["senders"]:
        p = sender_to_person.get(sid)
        if p and p.get("display_name") not in seen_names:
            seen_names.add(p["display_name"])
            matched.append(p)

    if not matched:
        # Tier 2: every non-self summary person (was single-chat-only;
        # now applies to every chat type).
        matched = list(people_entries)

    if not matched:
        # Tier 3: the summary listed nobody non-self at all — resolve this
        # day's senders by senderName against an existing person's name.
        seen_names = set()
        for sid in days[d]["senders"]:
            sname = days[d]["sender_names"].get(sid)
            norm = normalize_name(sname) if sname else ""
            if norm and norm in name_to_slug and name_to_display[norm] not in seen_names:
                seen_names.add(name_to_display[norm])
                matched.append(
                    {
                        "display_name": name_to_display[norm],
                        "sender_ids": [sid],
                        "is_self": False,
                        "role_guess": "unknown",
                    }
                )

    if not matched:
        # Tier 4: last resort — the one per-thread fallback person, so the
        # day is never dropped.
        matched = [get_thread_fallback_person()]

    days[d]["people"] = matched

# ---------------------------------------------------------------------------
# 5. Per-person aggregate: which days they're linked to.
# ---------------------------------------------------------------------------

person_days = {}  # display_name -> sorted [dates]
for d in sorted_days:
    for p in days[d]["people"]:
        person_days.setdefault(p["display_name"], set()).add(d)

# ---------------------------------------------------------------------------
# 6. Slug generation — name_to_slug/all_slugs were already built in section
#    3b (moved there so tier 3's senderName fallback can use them).
# ---------------------------------------------------------------------------


def gen_new_slug(name):
    base = kebab(name)
    candidate = base
    n = 2
    while candidate in all_slugs:
        candidate = "%s-%d" % (base, n)
        n += 1
    return candidate


PERSON_TEMPLATE = """---
schema_version: 1.1.0
name: {name}
org:
role:
location:
tags: {tags}
birthday:
how-met:
last-touch: {last_touch}
---

## Facts

_none_

## Open threads

_none_

## Personal details

_none_
"""


def create_person(name, last_touch, tags_line):
    slug = gen_new_slug(name)
    all_slugs.add(slug)
    name_to_slug[normalize_name(name)] = slug
    if not DRY_RUN:
        content = PERSON_TEMPLATE.format(name=name, tags=tags_line, last_touch=last_touch)
        with open(os.path.join(people_dir, "%s.md" % slug), "w") as f:
            f.write(content)
    return slug


def update_last_touch_forward(slug, new_date):
    path = os.path.join(people_dir, "%s.md" % slug)
    if DRY_RUN or not os.path.isfile(path):
        return
    with open(path) as f:
        content = f.read()
    m = re.search(r"^last-touch:[ \t]*(.*)$", content, re.MULTILINE)
    cur = m.group(1).strip() if m else ""
    if not cur or new_date > cur:
        content = re.sub(
            r"^last-touch:[ \t]*.*$", "last-touch: %s" % new_date, content, count=1, flags=re.MULTILINE
        )
        with open(path, "w") as f:
            f.write(content)


def append_facts(slug, facts_for_person):
    if not facts_for_person or DRY_RUN:
        return
    path = os.path.join(people_dir, "%s.md" % slug)
    if not os.path.isfile(path):
        return
    with open(path) as f:
        content = f.read()

    bullets = []
    for fact in facts_for_person:
        provenance = fact.get("provenance", "inferred-from-thread")
        text = fact.get("text", "")
        bullets.append("- **[%s]** %s" % (provenance, text))

    m = re.search(r"(## Facts\n\n)(.*?)(\n\n## Open threads)", content, re.DOTALL)
    if not m:
        return
    existing_block = m.group(2)
    existing_lines = [l for l in existing_block.splitlines() if l.strip()]
    if existing_lines == ["_none_"]:
        existing_lines = []
    new_lines = [b for b in bullets if b not in existing_lines]
    if not new_lines:
        return
    combined = existing_lines + new_lines
    new_block = "\n".join(combined) if combined else "_none_"
    content = content[: m.start(2)] + new_block + content[m.end(2) :]
    with open(path, "w") as f:
        f.write(content)


# ---------------------------------------------------------------------------
# 7. Resolve/create a slug for every person with at least one active day.
# ---------------------------------------------------------------------------

facts_by_display_name = {}
for fact in summary.get("facts") or []:
    about = fact.get("about")
    if not about or about == "user":
        continue
    facts_by_display_name.setdefault(about, []).append(fact)

people_new = 0
people_touched = set()
slug_by_display_name = {}

for display_name, date_set in person_days.items():
    dates = sorted(date_set)
    last_touch = dates[-1]
    norm = normalize_name(display_name)
    if norm in name_to_slug:
        slug = name_to_slug[norm]
        created = False
    else:
        person_entry = next(
            (p for p in people_entries if p.get("display_name") == display_name), {}
        )
        tags_line = "[]"
        if person_entry.get("role_guess") == "unsolicited":
            tags_line = "[linkedin-outreach]"
        elif (
            _thread_fallback_ref["person"] is not None
            and display_name == _thread_fallback_ref["person"]["display_name"]
        ):
            # Tier 4's per-thread fallback person carries its own tag
            # (group-chat for a group thread) since it isn't in the
            # summary's people[] at all.
            tags_line = _thread_fallback_ref["person"]["_fallback_tags"]
        slug = create_person(display_name, last_touch, tags_line)
        created = True
        people_new += 1

    slug_by_display_name[display_name] = slug
    people_touched.add(slug)
    update_last_touch_forward(slug, last_touch)
    append_facts(slug, facts_by_display_name.get(display_name, []))

# ---------------------------------------------------------------------------
# 8. Write one interaction per active day.
# ---------------------------------------------------------------------------

gist = summary.get("gist", "") or ""
open_threads = summary.get("open_threads") or []
commitments = summary.get("commitments") or []

INTERACTION_TEMPLATE = """---
schema_version: 1.0.0
date: {date}
people: [{people_links}]
calendar-event: null
source-capture: {source_capture}
---

## Summary

{summary_body}

## Commitments

{commitments_body}
"""


def commitment_line(c):
    owner = c.get("owner", "user")
    if owner != "user" and owner in slug_by_display_name:
        owner_text = "[[%s]]" % slug_by_display_name[owner]
    else:
        owner_text = owner
    by = c.get("by")
    suffix = " [by %s]" % by if by else ""
    return "- %s: %s%s" % (owner_text, c.get("what", ""), suffix)


interactions_written = 0

for i, d in enumerate(sorted_days):
    is_last = i == len(sorted_days) - 1
    day_people = days[d]["people"]
    slugs = [slug_by_display_name[p["display_name"]] for p in day_people if p["display_name"] in slug_by_display_name]
    if not slugs:
        # Defensive only: section 4's tiered fallback (summary sender_ids
        # -> every non-self summary person -> senderName match -> the
        # per-thread fallback person) guarantees at least one person per
        # active day, so this should be unreachable now.
        continue
    who = ", ".join(p["display_name"] for p in day_people if p["display_name"] in slug_by_display_name)
    n_msgs = len(days[d]["messages"])

    summary_lines = [gist, "", "%d messages this day (%s)." % (n_msgs, who)]
    if is_last and open_threads:
        summary_lines.append("")
        summary_lines.append("Open: " + "; ".join(open_threads))
    summary_body = "\n".join(summary_lines).strip()

    if is_last and commitments:
        commitments_body = "\n".join(commitment_line(c) for c in commitments)
    else:
        commitments_body = "_none_"

    people_links = ", ".join('"[[%s]]"' % s for s in slugs)

    base = "%s-%s" % (d, slugs[0])
    path = os.path.join(interactions_dir, "%s.md" % base)
    n = 2
    while os.path.exists(path):
        with open(path) as f:
            existing_content = f.read()
        existing_sc = read_frontmatter_field(existing_content, "source-capture")
        if existing_sc == primary_id:
            break
        path = os.path.join(interactions_dir, "%s--%d.md" % (base, n))
        n += 1

    if not DRY_RUN:
        content = INTERACTION_TEMPLATE.format(
            date=d,
            people_links=people_links,
            source_capture=primary_id,
            summary_body=summary_body,
            commitments_body=commitments_body,
        )
        with open(path, "w") as f:
            f.write(content)
    interactions_written += 1

# ---------------------------------------------------------------------------
# 9. Ledger + summary line.
# ---------------------------------------------------------------------------

for cid in new_ids:
    ledger_append(cid)

print(
    "file-thread: %s people_new=%d people_touched=%d interactions=%d days=%d dedup_ids=%d"
    % (primary_id, people_new, len(people_touched), interactions_written, len(sorted_days), len(new_ids))
)

# Internal assertion: every active day should have produced exactly one
# interaction (the "never drop an active day" rule) on a non-dedup-no-op
# run — this code path never runs on the no-op branch above (it exits
# early), so any mismatch here means the tiered fallback in section 4 has
# a gap.
if len(sorted_days) != interactions_written:
    print(
        "WARN: days=%d interactions=%d" % (len(sorted_days), interactions_written),
        file=sys.stderr,
    )
PYEOF

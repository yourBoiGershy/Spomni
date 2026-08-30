#!/bin/bash
# wakeup-queue.sh — the deterministic wake-up lifecycle CLI
# (packages/core/contracts/wakeup.md 1.2.0, packages/attention/specs/
# outcome-recording.md). Sole writer of the wakeup lifecycle fields
# (status transitions, fired-on, dismiss-reason, acted-on, snooze-count,
# confirmed-on, created-event-id) per the contract's writer table and
# docs/DECISIONS.md#attention-merge.
#
# Absorbs proposal-confirm.sh's confirm/decline ops (plan 21's amendment to
# plan 06) — proposal-confirm.sh is retired.
#
# Usage:
#   wakeup-queue.sh <store-dir> list-due [--today YYYY-MM-DD] [--json]
#   wakeup-queue.sh <store-dir> fire [--today YYYY-MM-DD] [--now ISO-TIMESTAMP] \
#       [--adjacency-minutes N]
#   wakeup-queue.sh <store-dir> snooze <id> (--days N | --until YYYY-MM-DD) \
#       [--today YYYY-MM-DD]
#   wakeup-queue.sh <store-dir> dismiss <id> --reason <enum>
#   wakeup-queue.sh <store-dir> confirm <id> --event-id <connector-event-id>
#   wakeup-queue.sh <store-dir> decline <id> --reason <enum>
#
# list-due: entries with status: pending and due <= today. One id per line,
# or a JSON array with --json. Exits 0 even when empty.
#
# fire: for each due & pending entry, in due-then-id order:
#   1. Exemption: origin: user-ask always fires.
#   2. Budget (plan 12): origin: signal|standing entries fire only while
#      fired_this_week < budget.max from <store>/signals/week-plan.json
#      (fired_this_week = entries with origin != user-ask whose fired-on
#      falls in [week_start, week_start+6]). A missing week-plan.json, or one
#      whose generated_at is older than 8 days, falls back to budget.max = 3
#      and prints a WARN line. Over-budget entries stay pending and are
#      reported as held-budget.
#   3. Meeting adjacency: if --now falls within --adjacency-minutes (default
#      30) of the start or end of any timed type: calendar-event capture in
#      <store>/inbox/ on today's date, NO entry fires this run — all due
#      entries are reported as held-adjacent and the run exits 0.
#   4. Firing writes status: fired and fired-on: <today> (only if fired-on is
#      currently null — a re-fire after snooze keeps the first fired-on).
#      One batch artifact is then written to
#      <store>/wakeups/fired/<today>T<HHMMSS>Z-batch.json.
#   5. Idempotent & silent: nothing due, or everything held, writes no batch
#      file and prints nothing besides any held lines. Re-running the same
#      day never re-fires an already-fired entry.
#
# snooze/dismiss: standard outcome-recording.md mechanics, including the
# 1.0.0 -> 1.1.0 schema upgrade (insert fired-on/dismiss-reason/acted-on/
# snooze-count/signal-type right after source-signal: before applying the
# write) the first time a 1.1.0 field is written to a 1.0.0 file.
#
# confirm/decline: ported verbatim from proposal-confirm.sh's semantics —
# confirm writes confirmed-on/created-event-id/acted-on: true and never
# touches status; decline is the standard dismiss mechanics. Both refuse
# kind: nudge (and missing kind, which reads as nudge) entries.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile,
# no ${var,,}. jq is used for JSON construction/output.

set -eu

SCRIPT_NAME="$(basename "$0")"

usage() {
  cat >&2 <<EOF
Usage:
  ${SCRIPT_NAME} <store-dir> list-due [--today YYYY-MM-DD] [--json]
  ${SCRIPT_NAME} <store-dir> fire [--today YYYY-MM-DD] [--now ISO-TIMESTAMP] [--adjacency-minutes N]
  ${SCRIPT_NAME} <store-dir> snooze <id> (--days N | --until YYYY-MM-DD) [--today YYYY-MM-DD]
  ${SCRIPT_NAME} <store-dir> dismiss <id> --reason <not-now|not-this-person|not-this-signal-type|already-handled>
  ${SCRIPT_NAME} <store-dir> confirm <id> --event-id <connector-event-id>
  ${SCRIPT_NAME} <store-dir> decline <id> --reason <not-now|not-this-person|not-this-signal-type|already-handled>

Deterministic wake-up queue lifecycle over <store-dir>/wakeups/*.md, per
packages/core/contracts/wakeup.md 1.2.0 and
packages/attention/specs/outcome-recording.md.
EOF
  exit 1
}

if [ "$#" -lt 2 ]; then
  usage
fi

STORE_DIR="$1"
OP="$2"
shift 2

if [ ! -d "${STORE_DIR}" ]; then
  echo "${SCRIPT_NAME}: store directory does not exist: '${STORE_DIR}'" >&2
  exit 1
fi

WAKEUPS_DIR="${STORE_DIR}/wakeups"

# =============================================================================
# date-flavor detection (BSD vs GNU) — mirrors capacity.sh's parser
# =============================================================================

if date -u -d "1970-01-01T00:00:00" +%s >/dev/null 2>&1; then
  DATE_MODE="gnu"
else
  DATE_MODE="bsd"
fi

# epoch_from_naive "<YYYY-MM-DDTHH:MM:SS>" — treats the string as if it were
# UTC wall-clock and returns its epoch seconds. Mirrors capacity.sh's parser.
epoch_from_naive() {
  dp="$1"
  if [ "${DATE_MODE}" = "gnu" ]; then
    TZ=UTC date -d "${dp}" +%s
  else
    date -j -u -f "%Y-%m-%dT%H:%M:%S" "${dp}" +%s
  fi
}

# shifted_epoch_to_date <epoch> — formats an epoch as a UTC calendar date.
# Mirrors capacity.sh's parser.
shifted_epoch_to_date() {
  e="$1"
  if [ "${DATE_MODE}" = "gnu" ]; then
    TZ=UTC date -u -d "@${e}" +%Y-%m-%d
  else
    date -j -u -r "${e}" +%Y-%m-%d
  fi
}

# date_add_days <YYYY-MM-DD> <n> — n may be 0 or negative. Mirrors
# capacity.sh's parser.
date_add_days() {
  d="$1"
  n="$2"
  if [ "${DATE_MODE}" = "gnu" ]; then
    date -u -d "${d} + ${n} days" +%Y-%m-%d
  else
    date -j -v"${n}d" -f "%Y-%m-%d" "${d}" +%Y-%m-%d
  fi
}

# parse_offset_seconds "<Z|+HH:MM|-HH:MM|>" — returns signed seconds. Mirrors
# capacity.sh's parser.
parse_offset_seconds() {
  off="$1"
  case "${off}" in
    ""|Z)
      echo 0
      return
      ;;
  esac
  sign_char=$(printf '%s' "${off}" | cut -c1)
  hh=$(printf '%s' "${off}" | cut -c2-3)
  mm=$(printf '%s' "${off}" | cut -c5-6)
  sec=$((10#${hh} * 3600 + 10#${mm} * 60))
  if [ "${sign_char}" = "-" ]; then
    sec=$((0 - sec))
  fi
  echo "${sec}"
}

# parse_iso_to_epoch "<YYYY-MM-DDTHH:MM:SS(Z|±HH:MM)>" — returns UTC epoch.
# Mirrors capacity.sh's parser.
parse_iso_to_epoch() {
  ts="$1"
  dp=$(printf '%s' "${ts}" | cut -c1-19)
  rest=$(printf '%s' "${ts}" | cut -c20-)
  off_sec=$(parse_offset_seconds "${rest}")
  naive_epoch=$(epoch_from_naive "${dp}")
  echo $((naive_epoch - off_sec))
}

# =============================================================================
# frontmatter field read/write — proposal-confirm.sh's awk idiom, generalized
# to take the target file as a parameter (this script operates over many
# wakeup files, not one fixed target).
# =============================================================================

# get_field_file <file> <field> — value after "field: " (surrounding double
# quotes stripped), or empty string if absent/null.
get_field_file() {
  file="$1"
  field="$2"
  awk -v field="${field}" '
    BEGIN { infm = 0; fmlines = 0 }
    {
      if ($0 == "---") {
        fmlines++
        if (fmlines == 1) { infm = 1; next }
        if (fmlines == 2) { infm = 0; exit }
      }
      if (!infm) next
      bare = field ":"
      prefix = field ": "
      if ($0 == bare) {
        print ""
        exit
      }
      if (index($0, prefix) == 1) {
        val = $0
        sub("^" prefix, "", val)
        gsub(/^"|"$/, "", val)
        print val
        exit
      }
    }
  ' "${file}"
}

# set_field_file <file> <field> <new_value> — replaces the first
# "^<field>: " line within the frontmatter block; every other line (fences,
# other fields, body sections) passes through unchanged. No-op (silent) if
# the field is not present — callers must ensure the field exists first
# (see upgrade_schema_if_needed).
set_field_file() {
  file="$1"
  field="$2"
  new_value="$3"
  tmp_file="$(mktemp)"
  awk -v field="${field}" -v new_value="${new_value}" '
    BEGIN { infm = 0; fmlines = 0; done = 0 }
    {
      if ($0 == "---") {
        fmlines++
        if (fmlines == 1) { infm = 1; print; next }
        if (fmlines == 2) { infm = 0; print; next }
      }
      if (infm && !done) {
        bare = field ":"
        prefix = field ": "
        if ($0 == bare || index($0, prefix) == 1) {
          print field ": " new_value
          done = 1
          next
        }
      }
      print
    }
  ' "${file}" > "${tmp_file}"
  mv "${tmp_file}" "${file}"
}

# upgrade_schema_if_needed <file> — if schema_version: 1.0.0, bump to 1.1.0
# and insert the five missing 1.1 lines (fired-on/dismiss-reason/acted-on/
# snooze-count/signal-type) right after source-signal:, per
# specs/outcome-recording.md and wakeup.md's Notes section. No-op otherwise.
upgrade_schema_if_needed() {
  file="$1"
  schema="$(get_field_file "${file}" schema_version)"
  if [ "${schema}" != "1.0.0" ]; then
    return
  fi
  tmp_file="$(mktemp)"
  awk '
    BEGIN { infm = 0; fmlines = 0; done = 0 }
    {
      if ($0 == "---") {
        fmlines++
        if (fmlines == 1) { infm = 1; print; next }
        if (fmlines == 2) { infm = 0; print; next }
      }
      if (infm && $0 == "schema_version: 1.0.0") {
        print "schema_version: 1.1.0"
        next
      }
      if (infm && !done && index($0, "source-signal:") == 1) {
        print
        print "fired-on:"
        print "dismiss-reason:"
        print "acted-on:"
        print "snooze-count: 0"
        print "signal-type:"
        done = 1
        next
      }
      print
    }
  ' "${file}" > "${tmp_file}"
  mv "${tmp_file}" "${file}"
}

# =============================================================================
# body-section extraction (for the fire batch artifact)
# =============================================================================

# extract_section <file> <header-word> — lines strictly between "## <word>"
# and the next "## " header (or EOF), raw (may have leading/trailing blanks).
extract_section() {
  file="$1"
  header="$2"
  awk -v h="## ${header}" '
    BEGIN { found = 0 }
    {
      if ($0 == h) { found = 1; next }
      if (found) {
        if ($0 ~ /^## /) { exit }
        print
      }
    }
  ' "${file}"
}

# trim_blank_lines — strips leading/trailing all-blank lines from stdin.
trim_blank_lines() {
  awk '
    { lines[NR] = $0 }
    END {
      first = 0
      last = 0
      for (i = 1; i <= NR; i++) {
        if (lines[i] !~ /^[[:space:]]*$/) { first = i; break }
      }
      for (i = NR; i >= 1; i--) {
        if (lines[i] !~ /^[[:space:]]*$/) { last = i; break }
      }
      if (first == 0) { exit }
      for (i = first; i <= last; i++) print lines[i]
    }
  '
}

# get_indented_block <file> <top-level-field> — lines under a "field:"
# mapping (2-space indented continuation lines), dedented is not needed since
# callers strip the fixed "  " prefix themselves via pe_field.
get_indented_block() {
  file="$1"
  field="$2"
  awk -v f="${field}:" '
    BEGIN { infm = 0; fmlines = 0; inblock = 0 }
    {
      if ($0 == "---") {
        fmlines++
        if (fmlines == 1) { infm = 1; next }
        if (fmlines == 2) { exit }
      }
      if (!infm) next
      if (index($0, f) == 1) { inblock = 1; next }
      if (inblock) {
        if ($0 ~ /^  /) { print; next }
        else { exit }
      }
    }
  ' "${file}"
}

# pe_field <block-text> <field> — value of "  <field>: <value>" within a
# get_indented_block result, or empty if absent/null.
pe_field() {
  blk="$1"
  fld="$2"
  printf '%s\n' "${blk}" | awk -v f="${fld}" '
    {
      bare = "  " f ":"
      prefix = "  " f ": "
      if ($0 == bare) { print ""; exit }
      if (index($0, prefix) == 1) {
        v = $0
        sub("^" prefix, "", v)
        print v
        exit
      }
    }
  '
}

# build_proposed_event_json <file> — {title,start,end,attendees,location}
# from the proposed-event: mapping, or "null" if absent.
build_proposed_event_json() {
  file="$1"
  blk="$(get_indented_block "${file}" "proposed-event")"
  if [ -z "${blk}" ]; then
    echo "null"
    return
  fi
  title="$(pe_field "${blk}" title)"
  start="$(pe_field "${blk}" start)"
  end="$(pe_field "${blk}" end)"
  attendees="$(pe_field "${blk}" attendees)"
  [ -n "${attendees}" ] || attendees="[]"
  location="$(pe_field "${blk}" location)"
  if [ -z "${location}" ]; then
    jq -n --arg title "${title}" --arg start "${start}" --arg end "${end}" \
      --argjson attendees "${attendees}" \
      '{title: $title, start: $start, end: $end, attendees: $attendees, location: null}'
  else
    jq -n --arg title "${title}" --arg start "${start}" --arg end "${end}" \
      --argjson attendees "${attendees}" --arg location "${location}" \
      '{title: $title, start: $start, end: $end, attendees: $attendees, location: $location}'
  fi
}

# build_entry_json <file> — one fired-batch entry object.
build_entry_json() {
  file="$1"
  id="$(get_field_file "${file}" id)"
  due="$(get_field_file "${file}" due)"
  people_raw="$(get_field_file "${file}" people)"
  [ -n "${people_raw}" ] || people_raw="[]"
  why="$(get_field_file "${file}" why)"
  origin="$(get_field_file "${file}" origin)"
  kind="$(get_field_file "${file}" kind)"
  [ -n "${kind}" ] || kind="nudge"
  signal_type="$(get_field_file "${file}" signal-type)"
  context="$(extract_section "${file}" Context | trim_blank_lines)"
  draft="$(extract_section "${file}" Draft | trim_blank_lines)"

  if [ "${kind}" = "event-proposal" ]; then
    proposed_event_json="$(build_proposed_event_json "${file}")"
  else
    proposed_event_json="null"
  fi

  jq -n \
    --arg id "${id}" \
    --arg due "${due}" \
    --argjson people "${people_raw}" \
    --arg why "${why}" \
    --arg origin "${origin}" \
    --arg kind "${kind}" \
    --arg signal_type "${signal_type}" \
    --arg context "${context}" \
    --arg draft "${draft}" \
    --argjson proposed_event "${proposed_event_json}" \
    '{
      id: $id,
      due: $due,
      people: $people,
      why: $why,
      origin: $origin,
      kind: $kind,
      signal_type: (if $signal_type == "" then null else $signal_type end),
      context: $context,
      draft: (if $draft == "" then null else $draft end),
      proposed_event: $proposed_event
    }'
}

# =============================================================================
# op: list-due
# =============================================================================

list_due_op() {
  TODAY=""
  JSON_OUT=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --today)
        [ "$#" -ge 2 ] || usage
        TODAY="$2"
        shift 2
        ;;
      --json)
        JSON_OUT=1
        shift
        ;;
      *)
        echo "${SCRIPT_NAME}: unknown argument: $1" >&2
        usage
        ;;
    esac
  done
  [ -n "${TODAY}" ] || TODAY="$(date -u +%Y-%m-%d)"

  list_file="$(mktemp)"
  trap 'rm -f "${list_file}"' RETURN
  if [ -d "${WAKEUPS_DIR}" ]; then
    for f in "${WAKEUPS_DIR}"/*.md; do
      [ -e "${f}" ] || continue
      status="$(get_field_file "${f}" status)"
      [ "${status}" = "pending" ] || continue
      due="$(get_field_file "${f}" due)"
      [ -n "${due}" ] || continue
      if [[ "${due}" < "${TODAY}" || "${due}" = "${TODAY}" ]]; then
        id="$(get_field_file "${f}" id)"
        printf '%s\t%s\t%s\n' "${due}" "${id}" "${f}" >> "${list_file}"
      fi
    done
  fi
  sort -t "$(printf '\t')" -k1,1 -k2,2 -o "${list_file}" "${list_file}" 2>/dev/null || true

  if [ "${JSON_OUT}" -eq 1 ]; then
    if [ -s "${list_file}" ]; then
      entries_file="$(mktemp)"
      while IFS="$(printf '\t')" read -r due id path; do
        people_raw="$(get_field_file "${path}" people)"
        [ -n "${people_raw}" ] || people_raw="[]"
        why="$(get_field_file "${path}" why)"
        origin="$(get_field_file "${path}" origin)"
        kind="$(get_field_file "${path}" kind)"
        [ -n "${kind}" ] || kind="nudge"
        jq -n --arg id "${id}" --arg due "${due}" --argjson people "${people_raw}" \
          --arg why "${why}" --arg origin "${origin}" --arg kind "${kind}" \
          '{id: $id, due: $due, people: $people, why: $why, origin: $origin, kind: $kind}' \
          >> "${entries_file}"
      done < "${list_file}"
      jq -s '.' "${entries_file}"
      rm -f "${entries_file}"
    else
      echo "[]"
    fi
  else
    while IFS="$(printf '\t')" read -r due id path; do
      printf '%s\n' "${id}"
    done < "${list_file}"
  fi
  rm -f "${list_file}"
}

# =============================================================================
# op: fire
# =============================================================================

fire_op() {
  TODAY=""
  NOW=""
  ADJACENCY_MINUTES=30
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --today)
        [ "$#" -ge 2 ] || usage
        TODAY="$2"
        shift 2
        ;;
      --now)
        [ "$#" -ge 2 ] || usage
        NOW="$2"
        shift 2
        ;;
      --adjacency-minutes)
        [ "$#" -ge 2 ] || usage
        ADJACENCY_MINUTES="$2"
        shift 2
        ;;
      *)
        echo "${SCRIPT_NAME}: unknown argument: $1" >&2
        usage
        ;;
    esac
  done
  [ -n "${TODAY}" ] || TODAY="$(date -u +%Y-%m-%d)"
  [ -n "${NOW}" ] || NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  list_file="$(mktemp)"
  if [ -d "${WAKEUPS_DIR}" ]; then
    for f in "${WAKEUPS_DIR}"/*.md; do
      [ -e "${f}" ] || continue
      status="$(get_field_file "${f}" status)"
      [ "${status}" = "pending" ] || continue
      due="$(get_field_file "${f}" due)"
      [ -n "${due}" ] || continue
      if [[ "${due}" < "${TODAY}" || "${due}" = "${TODAY}" ]]; then
        id="$(get_field_file "${f}" id)"
        printf '%s\t%s\t%s\n' "${due}" "${id}" "${f}" >> "${list_file}"
      fi
    done
  fi
  sort -t "$(printf '\t')" -k1,1 -k2,2 -o "${list_file}" "${list_file}" 2>/dev/null || true

  if [ ! -s "${list_file}" ]; then
    rm -f "${list_file}"
    exit 0
  fi

  # --- budget (plan 12 / week-plan.json) ---

  WEEK_PLAN="${STORE_DIR}/signals/week-plan.json"
  BUDGET_MAX=3
  WEEK_START="${TODAY}"
  if [ -f "${WEEK_PLAN}" ]; then
    gen_at="$(jq -r '.generated_at // empty' "${WEEK_PLAN}")"
    wk_start="$(jq -r '.week_start // empty' "${WEEK_PLAN}")"
    budget_max_file="$(jq -r '.budget.max // empty' "${WEEK_PLAN}")"
    [ -n "${wk_start}" ] && WEEK_START="${wk_start}"
    stale=0
    if [ -n "${gen_at}" ]; then
      gen_epoch="$(parse_iso_to_epoch "${gen_at}")"
      now_epoch="$(parse_iso_to_epoch "${NOW}")"
      age=$((now_epoch - gen_epoch))
      if [ "${age}" -gt $((8 * 86400)) ]; then
        stale=1
      fi
    else
      stale=1
    fi
    if [ "${stale}" -eq 1 ]; then
      echo "WARN: ${WEEK_PLAN} is missing or generated_at is stale (>8 days) — falling back to budget.max = 3" >&2
    elif [ -n "${budget_max_file}" ]; then
      BUDGET_MAX="${budget_max_file}"
    fi
  else
    echo "WARN: ${WEEK_PLAN} not found — falling back to budget.max = 3" >&2
  fi
  WEEK_END="$(date_add_days "${WEEK_START}" 6)"

  USED_BEFORE=0
  if [ -d "${WAKEUPS_DIR}" ]; then
    for f in "${WAKEUPS_DIR}"/*.md; do
      [ -e "${f}" ] || continue
      origin="$(get_field_file "${f}" origin)"
      [ "${origin}" = "user-ask" ] && continue
      fired_on="$(get_field_file "${f}" fired-on)"
      [ -n "${fired_on}" ] || continue
      if [[ "${fired_on}" < "${WEEK_START}" || "${fired_on}" > "${WEEK_END}" ]]; then
        continue
      fi
      USED_BEFORE=$((USED_BEFORE + 1))
    done
  fi
  USED_AFTER="${USED_BEFORE}"

  # --- meeting adjacency ---

  ADJACENT=0
  INBOX_DIR="${STORE_DIR}/inbox"
  if [ -d "${INBOX_DIR}" ]; then
    NOW_EPOCH="$(parse_iso_to_epoch "${NOW}")"
    ADJ_SEC=$((ADJACENCY_MINUTES * 60))
    for f in "${INBOX_DIR}"/*.md; do
      [ -e "${f}" ] || continue
      fm_end="$(awk '/^---$/{c++; if (c==2) {print NR; exit}}' "${f}")"
      [ -n "${fm_end}" ] || continue
      frontmatter="$(sed -n "2,$((fm_end - 1))p" "${f}")"
      if ! printf '%s\n' "${frontmatter}" | grep -qE '^type:[[:space:]]*calendar-event[[:space:]]*$'; then
        continue
      fi
      body="$(sed -n "$((fm_end + 1)),\$p" "${f}")"
      start_dt="$(printf '%s' "${body}" | jq -r '.start.dateTime // empty')"
      [ -n "${start_dt}" ] || continue
      end_dt="$(printf '%s' "${body}" | jq -r '.end.dateTime // empty')"
      start_epoch="$(parse_iso_to_epoch "${start_dt}")"
      if [ -n "${end_dt}" ]; then
        end_epoch="$(parse_iso_to_epoch "${end_dt}")"
      else
        end_epoch=$((start_epoch + 3600))
      fi
      event_date="$(shifted_epoch_to_date "${start_epoch}")"
      [ "${event_date}" = "${TODAY}" ] || continue
      win_start=$((start_epoch - ADJ_SEC))
      win_end=$((end_epoch + ADJ_SEC))
      if [ "${NOW_EPOCH}" -ge "${win_start}" ] && [ "${NOW_EPOCH}" -le "${win_end}" ]; then
        ADJACENT=1
      fi
    done
  fi

  entries_file="$(mktemp)"
  FIRED_COUNT=0

  if [ "${ADJACENT}" -eq 1 ]; then
    while IFS="$(printf '\t')" read -r due id path; do
      echo "held-adjacent: ${id}"
    done < "${list_file}"
  else
    while IFS="$(printf '\t')" read -r due id path; do
      origin="$(get_field_file "${path}" origin)"
      if [ "${origin}" != "user-ask" ] && [ "${USED_AFTER}" -ge "${BUDGET_MAX}" ]; then
        echo "held-budget: ${id}"
        continue
      fi

      upgrade_schema_if_needed "${path}"
      fired_on="$(get_field_file "${path}" fired-on)"
      if [ -z "${fired_on}" ]; then
        set_field_file "${path}" fired-on "${TODAY}"
      fi
      set_field_file "${path}" status fired

      if [ "${origin}" != "user-ask" ]; then
        USED_AFTER=$((USED_AFTER + 1))
      fi

      build_entry_json "${path}" >> "${entries_file}"
      FIRED_COUNT=$((FIRED_COUNT + 1))
      echo "fired: ${id}"
    done < "${list_file}"
  fi

  if [ "${FIRED_COUNT}" -gt 0 ]; then
    entries_json="$(jq -s '.' "${entries_file}")"
    held_budget_json="[]"
    held_adjacent_json="[]"
    if [ "${ADJACENT}" -ne 1 ]; then
      held_budget_json="$(
        while IFS="$(printf '\t')" read -r due id path; do
          origin="$(get_field_file "${path}" origin)"
          status="$(get_field_file "${path}" status)"
          if [ "${origin}" != "user-ask" ] && [ "${status}" = "pending" ]; then
            printf '%s\n' "${id}"
          fi
        done < "${list_file}" | jq -R -s 'split("\n") | map(select(length > 0))'
      )"
    fi

    fired_dir="${WAKEUPS_DIR}/fired"
    mkdir -p "${fired_dir}"
    hh_mm_ss="$(printf '%s' "${NOW}" | cut -c12-19)"
    hhmmss="$(printf '%s' "${hh_mm_ss}" | tr -d ':')"
    batch_file="${fired_dir}/${TODAY}T${hhmmss}Z-batch.json"

    batch_json="$(jq -n \
      --arg fired_at "${NOW}" \
      --arg today "${TODAY}" \
      --argjson max "${BUDGET_MAX}" \
      --argjson used_before "${USED_BEFORE}" \
      --argjson used_after "${USED_AFTER}" \
      --argjson entries "${entries_json}" \
      --argjson held_budget "${held_budget_json}" \
      --argjson held_adjacent "${held_adjacent_json}" \
      '{
        schema_version: "1.0.0",
        fired_at: $fired_at,
        today: $today,
        budget: { max: $max, used_before: $used_before, used_after: $used_after },
        entries: $entries,
        held_budget: $held_budget,
        held_adjacent: $held_adjacent
      }')"

    tmp_batch="$(mktemp "${fired_dir}/.batch.XXXXXX")"
    printf '%s' "${batch_json}" > "${tmp_batch}"
    mv "${tmp_batch}" "${batch_file}"
    echo "batch: ${batch_file}"
  fi

  rm -f "${list_file}" "${entries_file}"
}

# =============================================================================
# op: snooze
# =============================================================================

snooze_op() {
  [ "$#" -ge 1 ] || usage
  ID="$1"
  shift

  DAYS=""
  UNTIL=""
  TODAY=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --days)
        [ "$#" -ge 2 ] || usage
        DAYS="$2"
        shift 2
        ;;
      --until)
        [ "$#" -ge 2 ] || usage
        UNTIL="$2"
        shift 2
        ;;
      --today)
        [ "$#" -ge 2 ] || usage
        TODAY="$2"
        shift 2
        ;;
      *)
        echo "${SCRIPT_NAME}: unknown argument: $1" >&2
        usage
        ;;
    esac
  done

  if [ -z "${DAYS}" ] && [ -z "${UNTIL}" ]; then
    echo "${SCRIPT_NAME}: snooze requires --days N or --until YYYY-MM-DD" >&2
    exit 1
  fi
  if [ -n "${DAYS}" ] && [ -n "${UNTIL}" ]; then
    echo "${SCRIPT_NAME}: snooze: specify only one of --days or --until" >&2
    exit 1
  fi
  [ -n "${TODAY}" ] || TODAY="$(date -u +%Y-%m-%d)"

  FILE="${WAKEUPS_DIR}/${ID}.md"
  if [ ! -f "${FILE}" ]; then
    echo "${SCRIPT_NAME}: no such wake-up: '${FILE}'" >&2
    exit 1
  fi

  status="$(get_field_file "${FILE}" status)"
  case "${status}" in
    pending|fired|snoozed) ;;
    *)
      echo "${SCRIPT_NAME}: '${ID}' is status: ${status} — snooze requires pending|fired|snoozed" >&2
      exit 1
      ;;
  esac

  if [ -n "${DAYS}" ]; then
    case "${DAYS}" in
      ''|*[!0-9]*)
        echo "${SCRIPT_NAME}: invalid --days: '${DAYS}' (expected a non-negative integer)" >&2
        exit 1
        ;;
    esac
    NEW_DUE="$(date_add_days "${TODAY}" "${DAYS}")"
  else
    NEW_DUE="${UNTIL}"
  fi

  upgrade_schema_if_needed "${FILE}"

  sc="$(get_field_file "${FILE}" snooze-count)"
  [ -n "${sc}" ] || sc=0
  sc=$((sc + 1))

  set_field_file "${FILE}" due "${NEW_DUE}"
  set_field_file "${FILE}" status pending
  set_field_file "${FILE}" snooze-count "${sc}"

  echo "snoozed ${ID} -> due: ${NEW_DUE} (snooze-count: ${sc})"
}

# =============================================================================
# op: dismiss
# =============================================================================

dismiss_op() {
  [ "$#" -ge 1 ] || usage
  ID="$1"
  shift

  REASON=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason)
        [ "$#" -ge 2 ] || usage
        REASON="$2"
        shift 2
        ;;
      *)
        echo "${SCRIPT_NAME}: unknown argument: $1" >&2
        usage
        ;;
    esac
  done

  case "${REASON}" in
    not-now|not-this-person|not-this-signal-type|already-handled) ;;
    "")
      echo "${SCRIPT_NAME}: dismiss requires --reason <not-now|not-this-person|not-this-signal-type|already-handled>" >&2
      exit 1
      ;;
    *)
      echo "${SCRIPT_NAME}: invalid --reason '${REASON}' (expected not-now|not-this-person|not-this-signal-type|already-handled)" >&2
      exit 1
      ;;
  esac

  FILE="${WAKEUPS_DIR}/${ID}.md"
  if [ ! -f "${FILE}" ]; then
    echo "${SCRIPT_NAME}: no such wake-up: '${FILE}'" >&2
    exit 1
  fi

  status="$(get_field_file "${FILE}" status)"
  if [ "${status}" = "dismissed" ]; then
    echo "${SCRIPT_NAME}: '${ID}' is already dismissed — refusing" >&2
    exit 1
  fi

  upgrade_schema_if_needed "${FILE}"
  set_field_file "${FILE}" status dismissed
  set_field_file "${FILE}" dismiss-reason "${REASON}"

  echo "dismissed ${ID} -> dismiss-reason: ${REASON}"
}

# =============================================================================
# op: confirm / decline — ported from proposal-confirm.sh's semantics
# =============================================================================

confirm_decline_op() {
  ACTION="$1"
  shift
  [ "$#" -ge 1 ] || usage
  WAKEUP_ID="$1"
  shift

  EVENT_ID=""
  REASON=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --event-id)
        [ "$#" -ge 2 ] || usage
        EVENT_ID="$2"
        shift 2
        ;;
      --reason)
        [ "$#" -ge 2 ] || usage
        REASON="$2"
        shift 2
        ;;
      *)
        echo "${SCRIPT_NAME}: unknown argument: $1" >&2
        usage
        ;;
    esac
  done

  WAKEUP_FILE="${WAKEUPS_DIR}/${WAKEUP_ID}.md"
  if [ ! -f "${WAKEUP_FILE}" ]; then
    echo "${SCRIPT_NAME}: no such wake-up: '${WAKEUP_FILE}'" >&2
    exit 1
  fi

  KIND="$(get_field_file "${WAKEUP_FILE}" kind)"
  if [ -z "${KIND}" ]; then
    KIND="nudge"
  fi

  if [ "${KIND}" != "event-proposal" ]; then
    echo "${SCRIPT_NAME}: '${WAKEUP_ID}' is kind: ${KIND}, not event-proposal — refusing" >&2
    exit 1
  fi

  STATUS="$(get_field_file "${WAKEUP_FILE}" status)"
  CONFIRMED_ON="$(get_field_file "${WAKEUP_FILE}" confirmed-on)"

  if [ "${STATUS}" = "dismissed" ]; then
    echo "${SCRIPT_NAME}: '${WAKEUP_ID}' is already dismissed — refusing" >&2
    exit 1
  fi

  if [ -n "${CONFIRMED_ON}" ]; then
    echo "${SCRIPT_NAME}: '${WAKEUP_ID}' is already confirmed (confirmed-on: ${CONFIRMED_ON}) — refusing" >&2
    exit 1
  fi

  if [ "${ACTION}" = "confirm" ]; then
    if [ -z "${EVENT_ID}" ]; then
      echo "${SCRIPT_NAME}: confirm requires --event-id" >&2
      usage
    fi

    TODAY="$(date -u +%Y-%m-%d)"

    set_field_file "${WAKEUP_FILE}" "confirmed-on" "${TODAY}"
    set_field_file "${WAKEUP_FILE}" "created-event-id" "${EVENT_ID}"
    set_field_file "${WAKEUP_FILE}" "acted-on" "true"

    echo "confirmed ${WAKEUP_ID} -> created-event-id: ${EVENT_ID} (confirmed-on: ${TODAY})"
  else
    case "${REASON}" in
      not-now|not-this-person|not-this-signal-type|already-handled) ;;
      "")
        echo "${SCRIPT_NAME}: decline requires --reason" >&2
        usage
        ;;
      *)
        echo "${SCRIPT_NAME}: invalid --reason '${REASON}' (expected not-now|not-this-person|not-this-signal-type|already-handled)" >&2
        exit 1
        ;;
    esac

    set_field_file "${WAKEUP_FILE}" "status" "dismissed"
    set_field_file "${WAKEUP_FILE}" "dismiss-reason" "${REASON}"

    echo "declined ${WAKEUP_ID} -> dismiss-reason: ${REASON}"
  fi
}

# =============================================================================
# dispatch
# =============================================================================

case "${OP}" in
  list-due)
    list_due_op "$@"
    ;;
  fire)
    fire_op "$@"
    ;;
  snooze)
    snooze_op "$@"
    ;;
  dismiss)
    dismiss_op "$@"
    ;;
  confirm)
    confirm_decline_op confirm "$@"
    ;;
  decline)
    confirm_decline_op decline "$@"
    ;;
  *)
    echo "${SCRIPT_NAME}: unknown op '${OP}' (expected list-due|fire|snooze|dismiss|confirm|decline)" >&2
    usage
    ;;
esac

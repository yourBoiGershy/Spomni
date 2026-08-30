#!/usr/bin/env bash
# capacity.sh — the sole writer of signals/week-plan.json
# (packages/core/contracts/week-plan.md). Deterministic 7-day capacity
# computation over a store's filed calendar-event capture events.
#
# Usage:
#   capacity.sh <store-dir> [--today YYYY-MM-DD]
#
# Env params:
#   CAPACITY_DAY_START   working-window start, HH:MM (default 09:00)
#   CAPACITY_DAY_END     working-window end, HH:MM (default 18:00)
#   CAPACITY_TZ_OFFSET   UTC offset the window is interpreted at, ±HH:MM
#                         (default +00:00)
#
# Writes <store-dir>/signals/week-plan.json atomically (temp file + mv);
# on any error, exits non-zero without leaving a partial week-plan.

set -eu

SCRIPT_NAME="$(basename "$0")"

usage() {
  cat >&2 <<EOF
Usage: ${SCRIPT_NAME} <store-dir> [--today YYYY-MM-DD]

Writes <store-dir>/signals/week-plan.json per
packages/core/contracts/week-plan.md, computed from
<store-dir>/inbox/*.md calendar-event capture events over the 7-day
window [today, today+6].
EOF
  exit 1
}

STORE_DIR=""
TODAY=""

if [ "$#" -lt 1 ]; then
  usage
fi

STORE_DIR="$1"
shift

while [ "$#" -gt 0 ]; do
  case "$1" in
    --today)
      [ "$#" -ge 2 ] || usage
      TODAY="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
done

if [ ! -d "${STORE_DIR}" ]; then
  echo "Store directory does not exist: '${STORE_DIR}'" >&2
  exit 1
fi

CAPACITY_DAY_START="${CAPACITY_DAY_START:-09:00}"
CAPACITY_DAY_END="${CAPACITY_DAY_END:-18:00}"
CAPACITY_TZ_OFFSET="${CAPACITY_TZ_OFFSET:-+00:00}"

# --- date-flavor detection (BSD vs GNU), once ---

if date -u -d "1970-01-01T00:00:00" +%s >/dev/null 2>&1; then
  DATE_MODE="gnu"
else
  DATE_MODE="bsd"
fi

# --- helpers ---

# epoch_from_naive "<YYYY-MM-DDTHH:MM:SS>" — treats the string as if it were
# UTC wall-clock and returns its epoch seconds.
epoch_from_naive() {
  dp="$1"
  if [ "${DATE_MODE}" = "gnu" ]; then
    TZ=UTC date -d "${dp}" +%s
  else
    date -j -u -f "%Y-%m-%dT%H:%M:%S" "${dp}" +%s
  fi
}

# shifted_epoch_to_date <epoch> — formats an epoch-like integer as a UTC
# calendar date (used both for real epochs and for our "shifted" axis).
shifted_epoch_to_date() {
  e="$1"
  if [ "${DATE_MODE}" = "gnu" ]; then
    TZ=UTC date -u -d "@${e}" +%Y-%m-%d
  else
    date -j -u -r "${e}" +%Y-%m-%d
  fi
}

# date_add_days <YYYY-MM-DD> <n> — n may be 0.
date_add_days() {
  d="$1"
  n="$2"
  if [ "${DATE_MODE}" = "gnu" ]; then
    date -u -d "${d} + ${n} days" +%Y-%m-%d
  else
    date -j -v"+${n}d" -f "%Y-%m-%d" "${d}" +%Y-%m-%d
  fi
}

# parse_offset_seconds "<Z|+HH:MM|-HH:MM|>" — returns signed seconds.
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
parse_iso_to_epoch() {
  ts="$1"
  dp=$(printf '%s' "${ts}" | cut -c1-19)
  rest=$(printf '%s' "${ts}" | cut -c20-)
  off_sec=$(parse_offset_seconds "${rest}")
  naive_epoch=$(epoch_from_naive "${dp}")
  echo $((naive_epoch - off_sec))
}

# trim_hours <N.NN> — strips trailing zeros beyond one decimal digit,
# matching the goldens' formatting convention (e.g. 6.00 -> 6.0, 2.50 -> 2.5).
trim_hours() {
  s="$1"
  while :; do
    len=${#s}
    last=$(printf '%s' "${s}" | cut -c"${len}")
    second=$(printf '%s' "${s}" | cut -c"$((len - 1))")
    if [ "${last}" = "0" ] && [ "${second}" != "." ]; then
      s=$(printf '%s' "${s}" | cut -c1-"$((len - 1))")
    else
      break
    fi
  done
  echo "${s}"
}

seconds_to_hours() {
  awk -v v="$1" 'BEGIN { printf "%.2f", v / 3600 }'
}

TZ_OFFSET_SEC="$(parse_offset_seconds "${CAPACITY_TZ_OFFSET}")"

if [ -z "${TODAY}" ]; then
  TODAY="$(date +%Y-%m-%d)"
fi

# --- build the 7-day window ---

DATES=""
i=0
while [ "${i}" -lt 7 ]; do
  d="$(date_add_days "${TODAY}" "${i}")"
  DATES="${DATES}${d}
"
  i=$((i + 1))
done

# --- scratch space (per-day event count + clipped interval lists) ---

WORKDIR="$(mktemp -d)"
cleanup() {
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT

i=0
OLD_IFS="${IFS}"
IFS='
'
for d in ${DATES}; do
  : > "${WORKDIR}/day${i}.count"
  : > "${WORKDIR}/day${i}.iv"
  start_naive="${d}T${CAPACITY_DAY_START}:00"
  end_naive="${d}T${CAPACITY_DAY_END}:00"
  win_start="$(epoch_from_naive "${start_naive}")"
  win_end="$(epoch_from_naive "${end_naive}")"
  eval "DAY_${i}_DATE='${d}'"
  eval "DAY_${i}_WSTART='${win_start}'"
  eval "DAY_${i}_WEND='${win_end}'"
  i=$((i + 1))
done
IFS="${OLD_IFS}"
NUM_DAYS="${i}"

# --- scan inbox for calendar-event capture events ---

INBOX_DIR="${STORE_DIR}/inbox"
if [ -d "${INBOX_DIR}" ]; then
  for f in "${INBOX_DIR}"/*.md; do
    [ -e "${f}" ] || continue

    fm_end="$(awk '/^---$/{c++; if (c==2) {print NR; exit}}' "${f}")"
    [ -n "${fm_end}" ] || continue

    frontmatter="$(sed -n "2,$((fm_end - 1))p" "${f}")"
    if ! printf '%s\n' "${frontmatter}" | grep -qE '^type:[[:space:]]*calendar-event[[:space:]]*$'; then
      continue
    fi

    body="$(sed -n "$((fm_end + 1)),\$p" "${f}")"

    start_datetime="$(printf '%s' "${body}" | jq -r '.start.dateTime // empty')"
    if [ -z "${start_datetime}" ]; then
      # all-day (start.date only) or malformed — excluded entirely.
      continue
    fi
    end_datetime="$(printf '%s' "${body}" | jq -r '.end.dateTime // empty')"

    start_epoch="$(parse_iso_to_epoch "${start_datetime}")"
    if [ -n "${end_datetime}" ]; then
      end_epoch="$(parse_iso_to_epoch "${end_datetime}")"
    else
      end_epoch=$((start_epoch + 3600))
    fi

    shifted_start=$((start_epoch + TZ_OFFSET_SEC))
    shifted_end=$((end_epoch + TZ_OFFSET_SEC))

    event_date="$(shifted_epoch_to_date "${shifted_start}")"

    j=0
    while [ "${j}" -lt "${NUM_DAYS}" ]; do
      eval "d_date=\"\${DAY_${j}_DATE}\""
      if [ "${d_date}" = "${event_date}" ]; then
        echo "x" >> "${WORKDIR}/day${j}.count"
        eval "wstart=\"\${DAY_${j}_WSTART}\""
        eval "wend=\"\${DAY_${j}_WEND}\""
        cs="${shifted_start}"
        ce="${shifted_end}"
        [ "${cs}" -lt "${wstart}" ] && cs="${wstart}"
        [ "${ce}" -gt "${wend}" ] && ce="${wend}"
        if [ "${cs}" -lt "${ce}" ]; then
          echo "${cs} ${ce}" >> "${WORKDIR}/day${j}.iv"
        fi
        break
      fi
      j=$((j + 1))
    done
  done
fi

# --- per-day tier/hours computation ---

BUSY_COUNT=0
OPEN_COUNT=0

DAYS_JSON=""
j=0
while [ "${j}" -lt "${NUM_DAYS}" ]; do
  eval "d_date=\"\${DAY_${j}_DATE}\""
  eval "wstart=\"\${DAY_${j}_WSTART}\""
  eval "wend=\"\${DAY_${j}_WEND}\""

  events_count="$(wc -l < "${WORKDIR}/day${j}.count" | tr -d '[:space:]')"

  read_result="$(sort -n -k1,1 "${WORKDIR}/day${j}.iv" 2>/dev/null | awk -v ws="${wstart}" -v we="${wend}" '
    BEGIN { n = 0; m = 0 }
    {
      s = $1; e = $2;
      if (n == 0) { cs = s; ce = e; n = 1; next }
      if (s <= ce) { if (e > ce) ce = e; }
      else { ms[m] = cs; me[m] = ce; m++; cs = s; ce = e }
    }
    END {
      if (n > 0) { ms[m] = cs; me[m] = ce; m++ }
      meeting = 0; maxfree = 0; prev = ws;
      for (k = 0; k < m; k++) {
        gap = ms[k] - prev;
        if (gap > maxfree) maxfree = gap;
        meeting += me[k] - ms[k];
        prev = me[k];
      }
      gap = we - prev;
      if (gap > maxfree) maxfree = gap;
      if (m == 0) maxfree = we - ws;
      printf "%d %d\n", meeting, maxfree;
    }
  ')"

  meeting_sec="$(printf '%s' "${read_result}" | cut -d' ' -f1)"
  free_sec="$(printf '%s' "${read_result}" | cut -d' ' -f2)"

  meeting_hours_raw="$(seconds_to_hours "${meeting_sec}")"
  free_hours_raw="$(seconds_to_hours "${free_sec}")"
  meeting_hours="$(trim_hours "${meeting_hours_raw}")"
  free_hours="$(trim_hours "${free_hours_raw}")"

  is_busy="$(awk -v mh="${meeting_hours_raw}" -v fb="${free_hours_raw}" 'BEGIN { print (mh >= 5 || fb < 2) ? 1 : 0 }')"
  is_open="$(awk -v mh="${meeting_hours_raw}" 'BEGIN { print (mh <= 2) ? 1 : 0 }')"

  if [ "${is_busy}" = "1" ]; then
    tier="busy"
    BUSY_COUNT=$((BUSY_COUNT + 1))
  elif [ "${is_open}" = "1" ]; then
    tier="open"
    OPEN_COUNT=$((OPEN_COUNT + 1))
  else
    tier="normal"
  fi

  entry="{ \"date\": \"${d_date}\", \"tier\": \"${tier}\", \"meeting_hours\": ${meeting_hours}, \"largest_free_block_hours\": ${free_hours}, \"events\": ${events_count} }"
  if [ -z "${DAYS_JSON}" ]; then
    DAYS_JSON="${entry}"
  else
    DAYS_JSON="${DAYS_JSON},
    ${entry}"
  fi

  j=$((j + 1))
done

# --- weekly tier + budget ---

if [ "${BUSY_COUNT}" -ge 3 ]; then
  WEEKLY_TIER="busy"
  BUDGET_MIN=1
  BUDGET_MAX=2
elif [ "${OPEN_COUNT}" -ge 4 ]; then
  WEEKLY_TIER="open"
  BUDGET_MIN=3
  BUDGET_MAX=5
else
  WEEKLY_TIER="normal"
  BUDGET_MIN=2
  BUDGET_MAX=3
fi

WEEK_START="${TODAY}"
GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

OUT_JSON=$(cat <<EOF
{
  "schema_version": "1.0.0",
  "generated_at": "${GENERATED_AT}",
  "week_start": "${WEEK_START}",
  "tz_offset": "${CAPACITY_TZ_OFFSET}",
  "working_window": { "start": "${CAPACITY_DAY_START}", "end": "${CAPACITY_DAY_END}" },
  "weekly_tier": "${WEEKLY_TIER}",
  "budget": { "min": ${BUDGET_MIN}, "max": ${BUDGET_MAX} },
  "days": [
    ${DAYS_JSON}
  ]
}
EOF
)

# --- validate + atomic write ---

if ! printf '%s' "${OUT_JSON}" | jq . >/dev/null 2>&1; then
  echo "Internal error: generated week-plan JSON is invalid" >&2
  exit 1
fi

SIGNALS_DIR="${STORE_DIR}/signals"
mkdir -p "${SIGNALS_DIR}"

TMP_FILE="$(mktemp "${SIGNALS_DIR}/.week-plan.XXXXXX")"
printf '%s' "${OUT_JSON}" > "${TMP_FILE}"
mv "${TMP_FILE}" "${SIGNALS_DIR}/week-plan.json"

echo "${SIGNALS_DIR}/week-plan.json"

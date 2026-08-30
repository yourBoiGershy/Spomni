#!/bin/bash
# feedback-parse.sh — deterministic, no-model reply-grammar parse of the
# user's note-to-self replies (packages/ingestion/specs/feedback-parse.md,
# plan 34 U8). Runs on every sync tick as its own `feedback` lane row
# (packages/core/templates/sync-lanes.tsv); a tick with nothing new is a
# no-op. Never sends anything; never drops a user's words — unparseable
# text is still ledgered, as `freeform`.
#
# Usage:
#   feedback-parse.sh <store-dir> --data-dir <d> [--today YYYY-MM-DD]
#
# Steps:
#   1. Resolve the notify chat id from <store>/profile.md `## Notify`
#      (`beeper_chat_id: <v>` bullet). Absent -> "no notify chat configured",
#      exit 0.
#   2. Read the cursor at <d>/feedback-cursor (last processed capture-event
#      id/filename). List <store>/inbox/*.md whose frontmatter `type:
#      chat-message` sorts after the cursor. None -> "nothing new", exit 0.
#   3. Resolve the last delivered batch from <store>/outbox/delivered.log
#      (last line whose channel != none) -> <store>/wakeups/fired/<batch>.
#      Missing/unresolvable -> every reply line ledgers as freeform target
#      model (no card-number resolution possible).
#   4. Per new event (in order), if its body's chatID matches the notify
#      chat: parse each message in `messages[]` against the reply grammar,
#      apply via the existing lifecycle ops, and record one line in
#      <d>/feedback-applied.log. Advance the cursor after each event,
#      matched or not.
#
# Grammar (packages/ingestion/specs/feedback-parse.md — the source of
# truth; keep this header's summary in sync with it):
#   <n> done                -> wakeup-queue.sh dismiss <id> --reason already-handled [--text rest]; + feedback-file.sh --type done
#   <n> snooze <dur>         -> wakeup-queue.sh snooze <id> --days <D>   (dur <int>[dhw]: d=1, w=7, h->1 day)
#   <n> skip                 -> dismiss --reason not-now
#   <n> never <signal-type>  -> dismiss --reason not-this-signal-type; append profile.md ## Signal opt-outs (skip if present); feedback-file.sh --type opt-out
#   <n> not-them              -> dismiss --reason not-this-person
#   <n> wrong-tier <tier>     -> person-set-tier.sh <slug> --tier <tier> --source stated-by-user --feedback-* (tier not in vocab -> freeform)
#   <n> draft [free text]     -> write outbox/drafts/<batch>-<n>-draft.txt (unsent, verbatim; "no draft available
#                                 for <n>" if the entry has no draft — never composed here); feedback-file.sh
#                                 --type draft-request --target wakeup:<id> [--text <free text>]
#   <n> <anything else>       -> feedback-file.sh --type freeform --target wakeup:<id>
#   <no valid n / n > entries> -> feedback-file.sh --type freeform --target model
#
# A reply whose apply op exits non-zero still gets a ledger line (freeform,
# --reason op-exit-<n>) — never dropped.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.
# Must run under launchd's minimal PATH; jq is required (same precedent as
# beeper-in's lib.sh / plan 33's deliver-tick.sh — the beeper lane already
# depends on it).

set -u

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

WAKEUP_QUEUE_SH="${SCRIPT_DIR}/../../attention/scripts/wakeup-queue.sh"
PERSON_SET_TIER_SH="${SCRIPT_DIR}/../../core/scripts/person-set-tier.sh"
FEEDBACK_FILE_SH="${SCRIPT_DIR}/feedback-file.sh"

usage() {
  echo "Usage: ${SCRIPT_NAME} <store-dir> --data-dir <d> [--today YYYY-MM-DD]" >&2
  exit 2
}

if [ "$#" -lt 1 ]; then
  usage
fi

STORE="$1"
shift

DATA_DIR=""
TODAY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --data-dir)
      [ "$#" -ge 2 ] || usage
      DATA_DIR="$2"
      shift 2
      ;;
    --today)
      [ "$#" -ge 2 ] || usage
      TODAY="$2"
      shift 2
      ;;
    *)
      echo "${SCRIPT_NAME}: unrecognized argument: $1" >&2
      usage
      ;;
  esac
done

[ -n "${DATA_DIR}" ] || usage

if ! command -v jq >/dev/null 2>&1; then
  echo "${SCRIPT_NAME}: jq is required but not found on PATH" >&2
  exit 1
fi

[ -n "${TODAY}" ] || TODAY="$(date -u +%Y-%m-%d)"

mkdir -p "${DATA_DIR}"

CURSOR_FILE="${DATA_DIR}/feedback-cursor"
APPLIED_LOG="${DATA_DIR}/feedback-applied.log"

now_ts() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# ---------------------------------------------------------------------------
# 1. Resolve the notify chat id from profile.md's ## Notify section.
# ---------------------------------------------------------------------------

PROFILE_FILE="${STORE}/profile.md"
NOTIFY_CHAT_ID=""
if [ -f "${PROFILE_FILE}" ]; then
  # Match only a real ## Notify bullet (line starts "- **[stated-by-user]**
  # beeper_chat_id: "), never an HTML comment showing the bullet grammar as
  # an example (packages/core/templates/profile.md documents every
  # section's bullet shape inline as an <!-- ... --> comment, which can
  # itself contain the literal substring "beeper_chat_id:" before the real
  # bullet appears later in the file).
  NOTIFY_CHAT_ID="$(grep -m1 -E '^- \*\*\[stated-by-user\]\*\* beeper_chat_id: ' "${PROFILE_FILE}" 2>/dev/null \
    | sed -E 's/^- \*\*\[stated-by-user\]\*\* beeper_chat_id:[[:space:]]*//' \
    | sed -E 's/[[:space:]]*\([^)]*\)[[:space:]]*$//')"
fi

if [ -z "${NOTIFY_CHAT_ID}" ]; then
  echo "feedback-parse: no notify chat configured"
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. List new inbox chat-message events (sorted, filtered by cursor).
# ---------------------------------------------------------------------------

INBOX_DIR="${STORE}/inbox"
CURSOR_VALUE=""
[ -f "${CURSOR_FILE}" ] && CURSOR_VALUE="$(cat "${CURSOR_FILE}" 2>/dev/null)"

NEW_EVENTS_FILE="$(mktemp)"
trap 'rm -f "${NEW_EVENTS_FILE}"' EXIT

if [ -d "${INBOX_DIR}" ]; then
  for f in "${INBOX_DIR}"/*.md; do
    [ -e "${f}" ] || continue
    stem="$(basename "${f}" .md)"
    if [ -n "${CURSOR_VALUE}" ]; then
      if ! [[ "${stem}" > "${CURSOR_VALUE}" ]]; then
        continue
      fi
    fi
    ftype="$(sed -n '2,/^---$/p' "${f}" | grep '^type:' | head -1 | sed -E 's/^type:[[:space:]]*//')"
    [ "${ftype}" = "chat-message" ] || continue
    printf '%s\n' "${stem}" >> "${NEW_EVENTS_FILE}"
  done
fi

if [ ! -s "${NEW_EVENTS_FILE}" ]; then
  echo "feedback-parse: nothing new"
  exit 0
fi

sort -o "${NEW_EVENTS_FILE}" "${NEW_EVENTS_FILE}"

# ---------------------------------------------------------------------------
# 3. Resolve the last delivered batch (col 2 != none) from delivered.log.
# ---------------------------------------------------------------------------

DELIVERED_LOG="${STORE}/outbox/delivered.log"
BATCH_PATH=""
ENTRIES_COUNT=0
BATCH_MODE="none"

if [ -f "${DELIVERED_LOG}" ]; then
  batch_name="$(awk -F'\t' '$2 != "none" { line=$1 } END { if (line != "") print line }' "${DELIVERED_LOG}")"
  if [ -n "${batch_name}" ]; then
    candidate="${STORE}/wakeups/fired/${batch_name}"
    if [ -f "${candidate}" ]; then
      cnt="$(jq -r '.entries | length' "${candidate}" 2>/dev/null)"
      case "${cnt}" in
        ''|*[!0-9]*) : ;;
        *)
          BATCH_PATH="${candidate}"
          ENTRIES_COUNT="${cnt}"
          BATCH_MODE="batch"
          ;;
      esac
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

# strip_tokens <text> <n> — remainder of <text> after stripping <n> leading
# whitespace-delimited tokens (and their separating whitespace), preserving
# the remainder's own internal spacing.
strip_tokens() {
  _text="$1"
  _n="$2"
  _out="${_text}"
  _i=0
  while [ "${_i}" -lt "${_n}" ]; do
    _out="$(printf '%s' "${_out}" | sed -E 's/^[[:space:]]*[^[:space:]]+[[:space:]]*//')"
    _i=$((_i + 1))
  done
  printf '%s' "${_out}"
}

# dur_to_days <dur> — <int>[dhw] -> days on stdout, or empty if invalid.
dur_to_days() {
  d="$1"
  case "${d}" in
    *[0-9]d)
      n="${d%d}"
      case "${n}" in ''|*[!0-9]*) echo ""; return ;; esac
      echo "${n}"
      ;;
    *[0-9]w)
      n="${d%w}"
      case "${n}" in ''|*[!0-9]*) echo ""; return ;; esac
      echo $((n * 7))
      ;;
    *[0-9]h)
      n="${d%h}"
      case "${n}" in ''|*[!0-9]*) echo ""; return ;; esac
      echo "1"
      ;;
    *)
      echo ""
      ;;
  esac
}

APPLIED_COUNT=0
FREEFORM_COUNT=0

# log_applied <capture-id> <line-no> <type> <exit>
log_applied() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$(now_ts)" "$4" >> "${APPLIED_LOG}"
}

# feedback_freeform <target> <text> [--reason <r>]
feedback_freeform() {
  _target="$1"
  _text="$2"
  _reason="${3:-}"
  if [ -n "${_reason}" ]; then
    "${FEEDBACK_FILE_SH}" "${STORE}" --type freeform --target "${_target}" --source reply --channel beeper-self --text "${_text}" --reason "${_reason}" >/dev/null 2>&1
  else
    "${FEEDBACK_FILE_SH}" "${STORE}" --type freeform --target "${_target}" --source reply --channel beeper-self --text "${_text}" >/dev/null 2>&1
  fi
}

# append_optout_bullet <signal-type>
append_optout_bullet() {
  _sig="$1"
  [ -f "${PROFILE_FILE}" ] || return 0
  _bullet="- **[stated-by-user]** ${_sig} — all"
  if grep -qF "${_sig} — all" "${PROFILE_FILE}"; then
    return 0
  fi
  _tmp="$(mktemp)"
  awk -v bullet="${_bullet}" '
    BEGIN { state = 0; n = 0 }
    {
      if (state == 0) {
        print
        if ($0 == "## Signal opt-outs") { state = 1 }
        next
      }
      if (state == 1) {
        if ($0 ~ /^## /) {
          start = 1; end = n
          while (start <= end && arr[start] == "") start++
          while (end >= start && arr[end] == "") end--
          print ""
          for (i = start; i <= end; i++) print arr[i]
          print bullet
          print ""
          print
          state = 2
          next
        } else {
          n++
          arr[n] = $0
          next
        }
      }
      print
    }
    END {
      if (state == 1) {
        start = 1; end = n
        while (start <= end && arr[start] == "") start++
        while (end >= start && arr[end] == "") end--
        print ""
        for (i = start; i <= end; i++) print arr[i]
        print bullet
      }
    }
  ' "${PROFILE_FILE}" > "${_tmp}" && mv "${_tmp}" "${PROFILE_FILE}"
}

# ---------------------------------------------------------------------------
# apply_line <capture-id> <line-no> <text>
# ---------------------------------------------------------------------------

apply_line() {
  _capture_id="$1"
  _line_no="$2"
  _text="$3"

  _n_tok="$(printf '%s' "${_text}" | awk '{print $1}')"
  _valid_n=1
  case "${_n_tok}" in
    ''|*[!0-9]*) _valid_n=0 ;;
  esac

  if [ "${_valid_n}" -eq 0 ]; then
    feedback_freeform "model" "${_text}"
    log_applied "${_capture_id}" "${_line_no}" "freeform" "0"
    FREEFORM_COUNT=$((FREEFORM_COUNT + 1))
    return
  fi

  if [ "${BATCH_MODE}" != "batch" ] || [ "${_n_tok}" -lt 1 ] || [ "${_n_tok}" -gt "${ENTRIES_COUNT}" ]; then
    feedback_freeform "model" "${_text}"
    log_applied "${_capture_id}" "${_line_no}" "freeform" "0"
    FREEFORM_COUNT=$((FREEFORM_COUNT + 1))
    return
  fi

  _verb="$(printf '%s' "${_text}" | awk '{print $2}')"
  _wakeup_id="$(jq -r ".entries[$((_n_tok - 1))].id // empty" "${BATCH_PATH}")"
  _slug="$(jq -r ".entries[$((_n_tok - 1))].people[0] // empty" "${BATCH_PATH}")"
  # Batch entries carry people as raw "[[slug]]" markdown-link strings
  # (wakeup-queue.sh's build_entry_json passes the wakeup's `people:`
  # frontmatter value through verbatim) — strip the brackets so `wrong-tier`
  # resolves a real people/<slug>.md, not people/[[slug]].md.
  _slug="$(printf '%s' "${_slug}" | sed -E 's/^\[\[//; s/\]\]$//')"

  if [ -z "${_wakeup_id}" ]; then
    feedback_freeform "model" "${_text}"
    log_applied "${_capture_id}" "${_line_no}" "freeform" "0"
    FREEFORM_COUNT=$((FREEFORM_COUNT + 1))
    return
  fi

  case "${_verb}" in
    done)
      _rest="$(strip_tokens "${_text}" 2)"
      if [ -n "${_rest}" ]; then
        "${WAKEUP_QUEUE_SH}" "${STORE}" dismiss "${_wakeup_id}" --reason already-handled --source reply --channel beeper-self --text "${_rest}"
      else
        "${WAKEUP_QUEUE_SH}" "${STORE}" dismiss "${_wakeup_id}" --reason already-handled --source reply --channel beeper-self
      fi
      _ec=$?
      if [ "${_ec}" -eq 0 ]; then
        if [ -n "${_rest}" ]; then
          "${FEEDBACK_FILE_SH}" "${STORE}" --type done --target "wakeup:${_wakeup_id}" --source reply --channel beeper-self --text "${_rest}" >/dev/null 2>&1
        else
          "${FEEDBACK_FILE_SH}" "${STORE}" --type done --target "wakeup:${_wakeup_id}" --source reply --channel beeper-self >/dev/null 2>&1
        fi
        log_applied "${_capture_id}" "${_line_no}" "done" "${_ec}"
        APPLIED_COUNT=$((APPLIED_COUNT + 1))
      else
        feedback_freeform "wakeup:${_wakeup_id}" "${_text}" "op-exit-${_ec}"
        log_applied "${_capture_id}" "${_line_no}" "freeform" "${_ec}"
        FREEFORM_COUNT=$((FREEFORM_COUNT + 1))
      fi
      ;;
    snooze)
      _dur="$(printf '%s' "${_text}" | awk '{print $3}')"
      _days="$(dur_to_days "${_dur}")"
      if [ -z "${_days}" ]; then
        feedback_freeform "wakeup:${_wakeup_id}" "${_text}"
        log_applied "${_capture_id}" "${_line_no}" "freeform" "0"
        FREEFORM_COUNT=$((FREEFORM_COUNT + 1))
        return
      fi
      "${WAKEUP_QUEUE_SH}" "${STORE}" snooze "${_wakeup_id}" --days "${_days}" --today "${TODAY}" --source reply --channel beeper-self
      _ec=$?
      if [ "${_ec}" -eq 0 ]; then
        log_applied "${_capture_id}" "${_line_no}" "snooze" "${_ec}"
        APPLIED_COUNT=$((APPLIED_COUNT + 1))
      else
        feedback_freeform "wakeup:${_wakeup_id}" "${_text}" "op-exit-${_ec}"
        log_applied "${_capture_id}" "${_line_no}" "freeform" "${_ec}"
        FREEFORM_COUNT=$((FREEFORM_COUNT + 1))
      fi
      ;;
    skip)
      "${WAKEUP_QUEUE_SH}" "${STORE}" dismiss "${_wakeup_id}" --reason not-now --source reply --channel beeper-self
      _ec=$?
      if [ "${_ec}" -eq 0 ]; then
        log_applied "${_capture_id}" "${_line_no}" "dismiss" "${_ec}"
        APPLIED_COUNT=$((APPLIED_COUNT + 1))
      else
        feedback_freeform "wakeup:${_wakeup_id}" "${_text}" "op-exit-${_ec}"
        log_applied "${_capture_id}" "${_line_no}" "freeform" "${_ec}"
        FREEFORM_COUNT=$((FREEFORM_COUNT + 1))
      fi
      ;;
    never)
      _sig="$(printf '%s' "${_text}" | awk '{print $3}')"
      if [ -z "${_sig}" ]; then
        feedback_freeform "wakeup:${_wakeup_id}" "${_text}"
        log_applied "${_capture_id}" "${_line_no}" "freeform" "0"
        FREEFORM_COUNT=$((FREEFORM_COUNT + 1))
        return
      fi
      _rest="$(strip_tokens "${_text}" 3)"
      "${WAKEUP_QUEUE_SH}" "${STORE}" dismiss "${_wakeup_id}" --reason not-this-signal-type --source reply --channel beeper-self
      _ec=$?
      if [ "${_ec}" -eq 0 ]; then
        append_optout_bullet "${_sig}"
        "${FEEDBACK_FILE_SH}" "${STORE}" --type opt-out --target "signal:${_sig}" --to all --source reply --text "${_rest}" >/dev/null 2>&1
        log_applied "${_capture_id}" "${_line_no}" "opt-out" "${_ec}"
        APPLIED_COUNT=$((APPLIED_COUNT + 1))
      else
        feedback_freeform "wakeup:${_wakeup_id}" "${_text}" "op-exit-${_ec}"
        log_applied "${_capture_id}" "${_line_no}" "freeform" "${_ec}"
        FREEFORM_COUNT=$((FREEFORM_COUNT + 1))
      fi
      ;;
    not-them)
      "${WAKEUP_QUEUE_SH}" "${STORE}" dismiss "${_wakeup_id}" --reason not-this-person --source reply --channel beeper-self
      _ec=$?
      if [ "${_ec}" -eq 0 ]; then
        log_applied "${_capture_id}" "${_line_no}" "dismiss" "${_ec}"
        APPLIED_COUNT=$((APPLIED_COUNT + 1))
      else
        feedback_freeform "wakeup:${_wakeup_id}" "${_text}" "op-exit-${_ec}"
        log_applied "${_capture_id}" "${_line_no}" "freeform" "${_ec}"
        FREEFORM_COUNT=$((FREEFORM_COUNT + 1))
      fi
      ;;
    wrong-tier)
      _tier="$(printf '%s' "${_text}" | awk '{print $3}')"
      _tier_valid=0
      case "${_tier}" in
        inner-circle|close|active|dormant) _tier_valid=1 ;;
      esac
      if [ "${_tier_valid}" -eq 0 ] || [ -z "${_slug}" ]; then
        feedback_freeform "wakeup:${_wakeup_id}" "${_text}"
        log_applied "${_capture_id}" "${_line_no}" "freeform" "0"
        FREEFORM_COUNT=$((FREEFORM_COUNT + 1))
        return
      fi
      _rest="$(strip_tokens "${_text}" 3)"
      "${PERSON_SET_TIER_SH}" "${STORE}" "${_slug}" --tier "${_tier}" --source stated-by-user --today "${TODAY}" --feedback-source reply --feedback-channel beeper-self --feedback-text "${_rest}"
      _ec=$?
      if [ "${_ec}" -eq 0 ]; then
        log_applied "${_capture_id}" "${_line_no}" "tier-correction" "${_ec}"
        APPLIED_COUNT=$((APPLIED_COUNT + 1))
      else
        feedback_freeform "person:${_slug}" "${_text}" "op-exit-${_ec}"
        log_applied "${_capture_id}" "${_line_no}" "freeform" "${_ec}"
        FREEFORM_COUNT=$((FREEFORM_COUNT + 1))
      fi
      ;;
    draft)
      # <n> draft [free text] — serve what already exists in the batch
      # entry's `draft` field, verbatim, to outbox/drafts/ as unsent text;
      # never compose or invent one here (that is the sweep's/a model
      # session's job, per U16 — this deterministic tick only serves what
      # a prior pass already wrote).
      _rest="$(strip_tokens "${_text}" 2)"
      _draft_val="$(jq -r ".entries[$((_n_tok - 1))].draft // empty" "${BATCH_PATH}")"
      _batch_base="$(basename "${BATCH_PATH}")"
      _batch_stem="${_batch_base%.json}"
      _drafts_dir="${STORE}/outbox/drafts"
      mkdir -p "${_drafts_dir}"
      _out_file="${_drafts_dir}/${_batch_stem}-${_n_tok}-draft.txt"
      _out_name="$(basename "${_out_file}")"
      # If a draft file for this exact card was already delivered (listed
      # in delivered.log col 1), a fresh request must be re-sent, not
      # silently overwrite a file the outbound lane already picked up —
      # write a timestamp-suffixed sibling instead.
      if [ -f "${_out_file}" ] && [ -f "${DELIVERED_LOG}" ] && \
         awk -F'\t' -v n="${_out_name}" '$1 == n { found=1 } END { exit !found }' "${DELIVERED_LOG}"; then
        _out_file="${_drafts_dir}/${_batch_stem}-${_n_tok}-draft-$(date -u +%Y%m%dT%H%M%SZ).txt"
      fi
      {
        printf 'Draft (unsent):\n'
        if [ -n "${_draft_val}" ]; then
          printf '%s\n' "${_draft_val}"
        else
          printf 'no draft available for %s\n' "${_n_tok}"
        fi
        [ -n "${_rest}" ] && printf 'Note: %s\n' "${_rest}"
      } > "${_out_file}"
      _ec=$?
      if [ "${_ec}" -eq 0 ]; then
        if [ -n "${_rest}" ]; then
          "${FEEDBACK_FILE_SH}" "${STORE}" --type draft-request --target "wakeup:${_wakeup_id}" --source reply --channel beeper-self --text "${_rest}" >/dev/null 2>&1
        else
          "${FEEDBACK_FILE_SH}" "${STORE}" --type draft-request --target "wakeup:${_wakeup_id}" --source reply --channel beeper-self >/dev/null 2>&1
        fi
        log_applied "${_capture_id}" "${_line_no}" "draft-request" "${_ec}"
        APPLIED_COUNT=$((APPLIED_COUNT + 1))
      else
        feedback_freeform "wakeup:${_wakeup_id}" "${_text}" "op-exit-${_ec}"
        log_applied "${_capture_id}" "${_line_no}" "freeform" "${_ec}"
        FREEFORM_COUNT=$((FREEFORM_COUNT + 1))
      fi
      ;;
    *)
      "${FEEDBACK_FILE_SH}" "${STORE}" --type freeform --target "wakeup:${_wakeup_id}" --text "${_text}" --source reply --channel beeper-self >/dev/null 2>&1
      log_applied "${_capture_id}" "${_line_no}" "freeform" "0"
      FREEFORM_COUNT=$((FREEFORM_COUNT + 1))
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 4. Walk new events in order; match against the notify chat; apply.
# ---------------------------------------------------------------------------

while IFS= read -r stem; do
  [ -z "${stem}" ] && continue
  event_file="${INBOX_DIR}/${stem}.md"
  [ -f "${event_file}" ] || continue

  body="$(awk 'BEGIN{c=0} /^---$/{c++; next} c>=2{print}' "${event_file}")"
  chat_id="$(printf '%s' "${body}" | jq -r '.chatID // empty' 2>/dev/null)"

  if [ "${chat_id}" = "${NOTIFY_CHAT_ID}" ]; then
    msg_count="$(printf '%s' "${body}" | jq -r '.messages | length' 2>/dev/null)"
    case "${msg_count}" in
      ''|*[!0-9]*) msg_count=0 ;;
    esac
    idx=0
    while [ "${idx}" -lt "${msg_count}" ]; do
      msg_text="$(printf '%s' "${body}" | jq -r ".messages[${idx}].text // empty" 2>/dev/null)"
      idx=$((idx + 1))
      [ -z "${msg_text}" ] && continue
      apply_line "${stem}" "${idx}" "${msg_text}"
    done
  fi

  printf '%s\n' "${stem}" > "${CURSOR_FILE}"
done < "${NEW_EVENTS_FILE}"

echo "feedback-parse: applied=${APPLIED_COUNT} freeform=${FREEFORM_COUNT}"
exit 0

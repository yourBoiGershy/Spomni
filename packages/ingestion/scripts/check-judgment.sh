#!/usr/bin/env bash
# check-judgment.sh — validate judgment JSONL records against
# packages/core/contracts/relationship-scoring.md before any write. Read
# the "Judgment record", "Rules", "Evidence inputs" and "Kind vocabulary"
# sections there before touching this script.
#
# Usage:
#   check-judgment.sh <judgment.jsonl|-> [--today YYYY-MM-DD] [--evidence <evidence.jsonl>]
#
# Prints one line per record: "<slug>\tok" or "<slug>\treject:<reason>".
# A malformed line has no parseable slug — it prints "line<N>\treject:bad-json"
# (N = 1-based line number) instead. Exit 0 iff every record is ok, else 1.
#
# Checks, in this fixed order, first failure wins (each check's own
# reason token):
#   bad-json
#   missing-field:<name>   (required: slug, attention_warrant,
#                            suggested_tier [key must be present, value may
#                            be null], kind, kind_note, rationale,
#                            confidence — checked in that priority order)
#   warrant-range           attention_warrant must be an integer 0-100
#   kind-vocabulary         kind must be one of the D3 nine values
#   kind-note-empty         kind_note must be a non-empty string
#   scheduling-needs-expiry kind: scheduling requires a non-null kind_expires
#   expires-shape           kind_expires, when present, must be YYYY-MM-DD
#   confidence-enum         low | medium | high
#   tier-enum               inner-circle | close | active | dormant | null
#   rationale-cites-kind    rationale must contain the record's kind word
#   rationale-cites-evidence  rationale must contain >=1 evidence field name
#                            (touchpoints, median_gap_days, days_since_last,
#                            meetings, chat_days, emails,
#                            user_initiated_share, participation,
#                            co_attended, upcoming, talking_points)
#   rationale-length        <=2 sentences: reject when the rationale
#                            contains more than one ". "/"! "/"? " boundary
#   gate:touchpoints<2      only checked when --evidence is given: that
#                            slug's evidence touchpoints < 2 but
#                            suggested_tier is non-null
#   cap:<kind>>active       scheduling/transactional/unsolicited with
#                            suggested_tier inner-circle or close
#   cap:unknown>close       kind: unknown with suggested_tier inner-circle
#   expired-nonzero         kind_expires strictly before --today (or
#                            expired: true) with attention_warrant != 0 or
#                            suggested_tier non-null
#   stated-kind-changed     only checked when --evidence is given and that
#                            slug's evidence carries kind_source:
#                            stated-by-user with a non-null kind that
#                            differs from this record's kind
#   tier-source-invalid     tier_source, when present, must be exactly
#                            "derived" — a judgment record (this flow's
#                            model-emitted suggestion) may never claim
#                            tier_source: stated-by-user (plan 31 D5); the
#                            field is optional (absent = ok, no opinion)
#
# --evidence <evidence.jsonl>  derive-evidence.sh's JSON-lines output
# (slug-keyed records; touchpoints and kind/kind_source are read from it
# for the gate:/stated-kind-changed checks above). Omit to skip both.
# --today defaults to today (UTC).
#
# Read-only; writes nothing anywhere.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -eu

if ! command -v jq >/dev/null 2>&1; then
  echo "check-judgment.sh: jq is required but not found on PATH" >&2
  exit 1
fi

if [ $# -lt 1 ]; then
  echo "usage: check-judgment.sh <judgment.jsonl|-> [--today YYYY-MM-DD] [--evidence <evidence.jsonl>]" >&2
  exit 1
fi

INPUT="$1"
shift

TODAY=""
EVIDENCE_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --today)
      TODAY="${2:-}"
      shift 2
      ;;
    --evidence)
      EVIDENCE_FILE="${2:-}"
      shift 2
      ;;
    *)
      echo "check-judgment.sh: unrecognized argument '$1'" >&2
      exit 1
      ;;
  esac
done

[ -n "$TODAY" ] || TODAY="$(date -u +%Y-%m-%d)"

if [ "$INPUT" = "-" ]; then
  SRC="/dev/stdin"
else
  if [ ! -f "$INPUT" ]; then
    echo "check-judgment.sh: ${INPUT}: no such file" >&2
    exit 1
  fi
  SRC="$INPUT"
fi

if [ -n "$EVIDENCE_FILE" ] && [ ! -f "$EVIDENCE_FILE" ]; then
  echo "check-judgment.sh: ${EVIDENCE_FILE}: no such evidence file" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cat "$SRC" > "${WORK_DIR}/input.jsonl"

if [ -n "$EVIDENCE_FILE" ]; then
  jq -c '{(.slug): .}' "$EVIDENCE_FILE" | jq -s 'add // {}' > "${WORK_DIR}/evidence.json"
else
  echo '{}' > "${WORK_DIR}/evidence.json"
fi
if [ -n "$EVIDENCE_FILE" ]; then HAS_EVIDENCE_BOOL=true; else HAS_EVIDENCE_BOOL=false; fi

TMP_JQ="${WORK_DIR}/check.jq"
cat > "$TMP_JQ" <<'JQEOF'
def reqfields: ["slug", "attention_warrant", "suggested_tier", "kind", "kind_note", "rationale", "confidence"];
def kindvocab: ["friend", "family", "collaborator", "professional", "community", "scheduling", "transactional", "unsolicited", "unknown"];
def evkeys: ["touchpoints", "median_gap_days", "days_since_last", "meetings", "chat_days", "emails", "user_initiated_share", "participation", "co_attended", "upcoming", "talking_points"];

def is_date_shape: (type == "string") and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$");

def sentence_boundaries($s): [$s | scan("[.!?] ")] | length;

def cap_reject($rec):
  ($rec.kind) as $k
  | ($rec.suggested_tier) as $t
  | if ($k == "scheduling" or $k == "transactional" or $k == "unsolicited") and ($t == "inner-circle" or $t == "close")
    then "cap:" + $k + ">active"
    elif ($k == "unknown") and ($t == "inner-circle")
    then "cap:unknown>close"
    else null
    end;

def is_expired($rec; $today):
  ($rec.expired? == true) or (($rec.kind_expires? != null) and ($rec.kind_expires < $today));

def check($rec; $today; $evmap; $has_evidence):
  (reqfields - ($rec | keys)) as $missing
  | if ($missing | length) > 0 then "reject:missing-field:" + $missing[0]
    elif (($rec.attention_warrant | type) != "number") or ($rec.attention_warrant != ($rec.attention_warrant | floor)) or ($rec.attention_warrant < 0) or ($rec.attention_warrant > 100)
    then "reject:warrant-range"
    elif (kindvocab | index($rec.kind)) == null
    then "reject:kind-vocabulary"
    elif (($rec.kind_note | type) != "string") or (($rec.kind_note | length) == 0)
    then "reject:kind-note-empty"
    elif ($rec.kind == "scheduling") and (($rec.kind_expires? == null) or ($rec.kind_expires == ""))
    then "reject:scheduling-needs-expiry"
    elif ($rec.kind_expires? != null) and ($rec.kind_expires != "") and (($rec.kind_expires | is_date_shape) | not)
    then "reject:expires-shape"
    elif (["low", "medium", "high"] | index($rec.confidence)) == null
    then "reject:confidence-enum"
    elif ($rec.suggested_tier != null) and ((["inner-circle", "close", "active", "dormant"] | index($rec.suggested_tier)) == null)
    then "reject:tier-enum"
    elif (($rec.rationale | type) != "string") or ((($rec.rationale | contains($rec.kind)) // false) | not)
    then "reject:rationale-cites-kind"
    elif ([ evkeys[] | . as $ek | select($rec.rationale | contains($ek)) ] | length) == 0
    then "reject:rationale-cites-evidence"
    elif (sentence_boundaries($rec.rationale)) > 1
    then "reject:rationale-length"
    elif $has_evidence and ($evmap[$rec.slug]?.touchpoints != null) and ($evmap[$rec.slug].touchpoints < 2) and ($rec.suggested_tier != null)
    then "reject:gate:touchpoints<2"
    elif (cap_reject($rec)) != null
    then "reject:" + cap_reject($rec)
    elif (is_expired($rec; $today)) and (($rec.attention_warrant != 0) or ($rec.suggested_tier != null))
    then "reject:expired-nonzero"
    elif $has_evidence and ($evmap[$rec.slug]?.kind_source == "stated-by-user") and ($evmap[$rec.slug].kind != null) and ($evmap[$rec.slug].kind != $rec.kind)
    then "reject:stated-kind-changed"
    elif ($rec.tier_source? != null) and ($rec.tier_source != "derived")
    then "reject:tier-source-invalid"
    else "ok"
    end;

($evmap_arr[0]) as $evmap |
foreach (inputs | select(length > 0)) as $line (
  {n: 0};
  {n: (.n + 1)};
  (.n) as $n
  | ($line | try fromjson catch null) as $rec0
  | (if ($rec0 != null) and (($rec0 | type) == "object") then $rec0 else null end) as $rec
  | if $rec == null then "line\($n)\treject:bad-json"
    else
      ($rec.slug // "line\($n)") as $slug
      | "\($slug)\t" + check($rec; $today; $evmap; $has_evidence)
    end
)
JQEOF

set +e
RESULT="$(jq -R -n -r \
  --slurpfile evmap_arr "${WORK_DIR}/evidence.json" \
  --arg today "$TODAY" \
  --argjson has_evidence "$HAS_EVIDENCE_BOOL" \
  -f "$TMP_JQ" \
  "${WORK_DIR}/input.jsonl")"
JQ_EXIT=$?
set -e

if [ "$JQ_EXIT" -ne 0 ]; then
  echo "check-judgment.sh: jq evaluation failed" >&2
  exit 1
fi

printf '%s\n' "$RESULT"

if printf '%s\n' "$RESULT" | grep -q $'\treject:'; then
  exit 1
fi
exit 0

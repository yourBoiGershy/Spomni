#!/usr/bin/env bash
# rescale-scores.sh — pure re-centering / ranking of a judgment batch.
# Model of record: packages/ingestion/specs/rescale.md (read it before
# touching this script). Kind caps / expired-kind rule: "## Rules" in
# packages/core/contracts/relationship-scoring.md.
#
# Usage:
#   rescale-scores.sh <scores.jsonl|-> --report
#   rescale-scores.sh <scores.jsonl|-> --rescale [--target-mean 50] [--target-spread 40] [--today YYYY-MM-DD]
#   rescale-scores.sh <scores.jsonl|-> --rank [--today YYYY-MM-DD]
#
# `<scores.jsonl|->` is a JSONL judgment batch (one record per line,
# contracts/relationship-scoring.md's "Judgment record" shape); `-` reads
# stdin. This script never writes any file — it is a pure function over
# the batch, printed to stdout.
#
# --report: tab-separated header + one "overall" row + one row per
# distinct `kind` (in first-appearance order), each with n, mean (1dp),
# median, spread (p90-p10, unrounded beyond input precision), share_ge_80
# (2dp), share_le_20 (2dp), skew ("yes"/"no"/"n/a (n<4)" — n>=4 required
# to judge skew; yes when share_ge_80 > 0.5 or share_le_20 > 0.5 or
# spread < 10). p10/p90 via linear interpolation on the sorted scope,
# 0-based index = (p/100)*(n-1).
#
# --rescale: shift-and-scale every record's attention_warrant using the
# OVERALL batch's mean/spread (never per-kind):
#   w' = clamp(round(target_mean + (w - mean) * (target_spread / spread)), 0, 100)
# Shift-only (w' = round(clamp(target_mean))) when the overall spread is 0
# (all warrants identical, or n <= 1). round() is round-half-up
# (floor(x + 0.5)).
#
# --rank: percentile-band assignment over the overall batch instead of
# shift-and-scale: w' = round(100 * (rank - 0.5) / n), rank = 1-based rank
# ascending by attention_warrant, ties sharing the mean rank of their tied
# block (three-way tie at ranks 4-6 all get rank 5).
#
# Both --rescale and --rank recompute suggested_tier from w' through the
# fixed band table (>=80 inner-circle, >=60 close, >=35 active, <35
# dormant — this table exists only so a rescaled batch has tiers to show,
# never cited as a judgment rule), then apply
# contracts/relationship-scoring.md "## Rules" kind caps (scheduling /
# transactional / unsolicited capped at active; unknown capped at close)
# and the expired-kind rule (a record with `expired: true`, or a
# `kind_expires` strictly before --today, forces attention_warrant: 0 and
# suggested_tier: null — checked and applied AFTER the shift/rank/cap
# recompute, since an expired record's rescaled warrant is meaningless).
# --today defaults to today (UTC) when omitted; only the expired-kind rule
# consumes it.
#
# Output: same JSONL, input order preserved, `attention_warrant` and
# `suggested_tier` replaced, `rescaled_from: <original attention_warrant>`
# added. All other fields (kind_note, kind_expires, rationale, confidence,
# etc.) pass through unchanged.
#
# Portable to bash 3.2 (macOS default): no associative arrays, no mapfile.

set -eu

if ! command -v jq >/dev/null 2>&1; then
  echo "rescale-scores.sh: jq is required but not found on PATH" >&2
  exit 1
fi

if [ $# -lt 1 ]; then
  echo "usage: rescale-scores.sh <scores.jsonl|-> [--report | --rescale [--target-mean 50] [--target-spread 40] [--today YYYY-MM-DD] | --rank [--today YYYY-MM-DD]]" >&2
  exit 1
fi

INPUT="$1"
shift

MODE=""
TARGET_MEAN="50"
TARGET_SPREAD="40"
TODAY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --report)
      MODE="report"
      shift
      ;;
    --rescale)
      MODE="rescale"
      shift
      ;;
    --rank)
      MODE="rank"
      shift
      ;;
    --target-mean)
      TARGET_MEAN="${2:-}"
      shift 2
      ;;
    --target-spread)
      TARGET_SPREAD="${2:-}"
      shift 2
      ;;
    --today)
      TODAY="${2:-}"
      shift 2
      ;;
    *)
      echo "rescale-scores.sh: unrecognized argument '$1'" >&2
      exit 1
      ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "rescale-scores.sh: one of --report / --rescale / --rank is required" >&2
  exit 1
fi

[ -n "$TODAY" ] || TODAY="$(date -u +%Y-%m-%d)"

if [ "$INPUT" = "-" ]; then
  SRC="/dev/stdin"
else
  if [ ! -f "$INPUT" ]; then
    echo "rescale-scores.sh: ${INPUT}: no such file" >&2
    exit 1
  fi
  SRC="$INPUT"
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
cat "$SRC" > "${WORK_DIR}/input.jsonl"

JQ_LIB='
def round_half_up: (. + 0.5) | floor;
def clamp01_100: if . < 0 then 0 elif . > 100 then 100 else . end;

def pctl($sorted; $p):
  ($sorted | length) as $n
  | if $n == 0 then null
    elif $n == 1 then $sorted[0]
    else
      (($p / 100) * ($n - 1)) as $idx
      | ($idx | floor) as $lo
      | ($idx | ceil) as $hi
      | if $lo == $hi then $sorted[$lo]
        else $sorted[$lo] + ($sorted[$hi] - $sorted[$lo]) * ($idx - $lo)
        end
    end;

def median($sorted):
  ($sorted | length) as $n
  | if $n == 0 then null
    elif ($n % 2) == 1 then $sorted[($n - 1) / 2]
    else ($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2
    end;

def scope_stats($vals):
  ($vals | sort) as $s
  | ($s | length) as $n
  | (if $n == 0 then 0 else ($s | add) / $n end) as $mean
  | (median($s)) as $med
  | (pctl($s; 10)) as $p10
  | (pctl($s; 90)) as $p90
  | (if $n == 0 then 0 else ($p90 - $p10) end) as $spread
  | (if $n == 0 then 0 else (([ $s[] | select(. >= 80) ] | length) / $n) end) as $ge80
  | (if $n == 0 then 0 else (([ $s[] | select(. <= 20) ] | length) / $n) end) as $le20
  | {n: $n, mean: $mean, median: $med, spread: $spread, share_ge_80: $ge80, share_le_20: $le20};

def skew_of($row):
  if $row.n < 4 then "n/a (n<4)"
  elif ($row.share_ge_80 > 0.5) or ($row.share_le_20 > 0.5) or ($row.spread < 10) then "yes"
  else "no"
  end;

def band($w):
  if $w >= 80 then "inner-circle"
  elif $w >= 60 then "close"
  elif $w >= 35 then "active"
  else "dormant"
  end;

def cap_tier($kind; $tier):
  if ($kind == "scheduling" or $kind == "transactional" or $kind == "unsolicited")
     and ($tier == "inner-circle" or $tier == "close")
  then "active"
  elif ($kind == "unknown") and ($tier == "inner-circle")
  then "close"
  else $tier
  end;

def is_expired($rec; $today):
  ($rec.expired? == true) or (($rec.kind_expires? != null) and ($rec.kind_expires < $today));
'

case "$MODE" in
  report)
    TMP_JQ="${WORK_DIR}/report.jq"
    cat > "$TMP_JQ" <<JQEOF
${JQ_LIB}
[inputs] as \$recs
| (\$recs | map(.attention_warrant)) as \$overall_vals
| (scope_stats(\$overall_vals)) as \$overall
| ["overall", (\$overall.n|tostring), \$overall.mean, \$overall.median, \$overall.spread, \$overall.share_ge_80, \$overall.share_le_20, skew_of(\$overall)]
| @tsv
, (
    (reduce \$recs[] as \$r ([]; if index(\$r.kind) then . else . + [\$r.kind] end)) as \$kinds
    | \$kinds[]
    | . as \$k
    | (scope_stats([\$recs[] | select(.kind == \$k) | .attention_warrant])) as \$row
    | [\$k, (\$row.n|tostring), \$row.mean, \$row.median, \$row.spread, \$row.share_ge_80, \$row.share_le_20, skew_of(\$row)]
    | @tsv
  )
JQEOF
    {
      printf 'scope\tn\tmean\tmedian\tspread\tshare_ge_80\tshare_le_20\tskew\n'
      jq -n -r -f "$TMP_JQ" "${WORK_DIR}/input.jsonl"
    } | awk -F'\t' '
      BEGIN { OFS = "\t" }
      NR == 1 { print; next }
      {
        mean = $3; median = $4; spread = $5; ge80 = $6; le20 = $7
        printf "%s\t%s\t%.1f\t%s\t%s\t%.2f\t%.2f\t%s\n", $1, $2, mean+0, fmt(median), fmt(spread), ge80+0, le20+0, $8
      }
      function fmt(v,   s) {
        s = sprintf_trim(v)
        return s
      }
      function sprintf_trim(v,   s) {
        s = sprintf("%.10f", v+0)
        sub(/0+$/, "", s)
        sub(/\.$/, "", s)
        return s
      }
    '
    ;;

  rescale|rank)
    if [ "$MODE" = "rescale" ]; then
      TMP_JQ="${WORK_DIR}/rescale.jq"
      cat > "$TMP_JQ" <<JQEOF
${JQ_LIB}
[inputs] as \$recs
| (\$recs | map(.attention_warrant)) as \$vals
| (scope_stats(\$vals)) as \$overall
| \$overall.mean as \$mean
| \$overall.spread as \$spread
| (${TARGET_MEAN}) as \$target_mean
| (${TARGET_SPREAD}) as \$target_spread
| "${TODAY}" as \$today
| \$recs[]
| . as \$rec
| \$rec.attention_warrant as \$w
| (
    if \$spread == 0 then (\$target_mean | round_half_up | clamp01_100)
    else (((\$target_mean + (\$w - \$mean) * (\$target_spread / \$spread)) | round_half_up) | clamp01_100)
    end
  ) as \$wprime_raw
| (band(\$wprime_raw) | cap_tier(\$rec.kind; .)) as \$tier_raw
| (is_expired(\$rec; \$today)) as \$expired
| (if \$expired then 0 else \$wprime_raw end) as \$wprime
| (if \$expired then null else \$tier_raw end) as \$tier
| (\$rec + {attention_warrant: \$wprime, suggested_tier: \$tier, rescaled_from: \$w})
JQEOF
    else
      TMP_JQ="${WORK_DIR}/rank.jq"
      cat > "$TMP_JQ" <<JQEOF
${JQ_LIB}
[inputs] as \$recs
| (\$recs | map(.attention_warrant)) as \$vals
| (\$vals | length) as \$n
| "${TODAY}" as \$today
| \$recs[]
| . as \$rec
| \$rec.attention_warrant as \$w
| ([\$vals[] | select(. < \$w)] | length) as \$count_lt
| ([\$vals[] | select(. <= \$w)] | length) as \$count_le
| (((\$count_lt + \$count_le + 1) / 2)) as \$rank
| (((100 * (\$rank - 0.5) / \$n) | round_half_up) | clamp01_100) as \$wprime_raw
| (band(\$wprime_raw) | cap_tier(\$rec.kind; .)) as \$tier_raw
| (is_expired(\$rec; \$today)) as \$expired
| (if \$expired then 0 else \$wprime_raw end) as \$wprime
| (if \$expired then null else \$tier_raw end) as \$tier
| (\$rec + {attention_warrant: \$wprime, suggested_tier: \$tier, rescaled_from: \$w})
JQEOF
    fi
    jq -c -n -f "$TMP_JQ" "${WORK_DIR}/input.jsonl"
    ;;
esac
